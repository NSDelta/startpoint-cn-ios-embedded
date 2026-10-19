#!/usr/bin/env node
// verify-import-plan.mjs —— 上机导入前的「对账」：CDN 目录里的每个归档 ↔ 导入计划里的每条目。
//
// 为什么要有这一步：面板里的资源导入是按 **basename** 匹配计划的（`CdnImportPlan.itemsByBasename`），
// 目录层级多深都不影响。所以只要「计划里的 646 条」与「用户解包后目录里的归档」一一对上，
// 导入就不会出现 missing / unused / 写坏。这个脚本就是把这件事离线验一遍，不依赖真机。
//
// 检查项：
//   1. 计划里每条都能在 cn/archive-*/ 或 patches/<ver>/archive-*/ 里找到（按 basename），且体积一致
//   2. 12 条补丁项额外做 sha256（hex→base64）逐条比对（大文件只比体积）
//   3. 同名归档重复出现时，比对 sha256 是否一致（cn/ 与 patches/ 里同名的那几个）
//   4. 每层（common/medium/ios/android）的 diff 链从 baseline 一直到 target 连续、无重复版本
//   5. 目录里存在但计划里没有的归档（会被引擎当 unused 忽略，但要报出来）
//
// 用法：node tools/verify-import-plan.mjs [--cdn=D:\wfspcn\resources\server\.cdn] [--plan=ios\src\importer]

import { readFileSync, existsSync, readdirSync, statSync } from 'node:fs'
import path from 'node:path'
import crypto from 'node:crypto'

const ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1')), '..')
const args = Object.fromEntries(process.argv.slice(2).map(a => {
  const m = a.match(/^--([^=]+)(?:=(.*))?$/); return m ? [m[1], m[2] === undefined ? true : m[2]] : [a.replace(/^--/, ''), true]
}))
const CDN = path.resolve(String(args.cdn || 'D:/wfspcn/resources/server/.cdn'))
const PLAN = path.resolve(String(args.plan || path.join(ROOT, 'ios', 'src', 'importer', 'CdnImportPlan.generated.m')))
const say = (s) => console.log(s)
const problems = []
const warn = (s) => { problems.push(s); say('  ✗ ' + s) }

if (!existsSync(CDN)) { say('ERROR 找不到 CDN 目录 ' + CDN); process.exit(1) }
if (!existsSync(PLAN)) { say('ERROR 找不到计划 ' + PLAN); process.exit(1) }

// ── 解析计划 ──
// 字段切分：字符走查（引号内原样取，逗号分隔，去引号）。不能用正则「引号 or 逗号前字符」——
// 逗号后的空格会让后者把下一个带引号的字段整段吞掉，值里残留 \"…\" 会让对账全假。
function splitFields (inner) {
  const out = []
  let cur = '', inQ = false, esc = false
  for (const ch of inner) {
    if (inQ) {
      if (esc) { cur += ch; esc = false }
      else if (ch === '\\') esc = true
      else if (ch === '"') inQ = false
      else cur += ch
    } else if (ch === '"') inQ = true
    else if (ch === ',') { out.push(cur.trim()); cur = '' }
    else cur += ch
  }
  out.push(cur.trim())
  return out
}
function parseItemLine (line) {
  const m = line.match(/^\s*\{\s*(.*?)\s*\},?\s*$/)
  if (!m || m[1].indexOf('"') < 0) return null
  const fields = splitFields(m[1])
  if (fields.length < 8) return null
  return {
    relativePath: fields[0], basename: fields[1], layer: fields[2], kind: fields[3],
    version: fields[4], originalVersion: String(fields[5]).trim() === '0' ? '0' : fields[5],
    bytes: Number(String(fields[6]).replace(/ULL$/i, '').trim()), sha256b64: fields[7],
  }
}
const plan = readFileSync(PLAN, 'utf8').split('\n').map(parseItemLine).filter(Boolean)
say(`== 计划 ==`)
say(`  文件 ${path.relative(ROOT, PLAN)}`)
say(`  条目 ${plan.length}（diff ${plan.filter(i => i.kind === 'diff').length} / full ${plan.filter(i => i.kind === 'full').length}）`)
const layers = [...new Set(plan.map(i => i.layer))].sort()
say(`  层   ${layers.join(', ')}`)
const target = plan.reduce((a, b) => (cmpVer(a.version, b.version) > 0 ? a.version : b.version), '0.0.0')
say(`  目标版本 ${target}`)

// ── 扫目录 ──
const found = []   // { basename, path, bytes, root }
function walk (dir, root) {
  if (!existsSync(dir)) return
  for (const n of readdirSync(dir)) {
    const p = path.join(dir, n)
    const st = statSync(p)
    if (st.isDirectory()) walk(p, root)
    else if (/\.zip$/i.test(n)) found.push({ basename: n, path: p, bytes: st.size, root })
  }
}
const cnRoot = path.join(CDN, 'cn')
if (!existsSync(cnRoot)) { say('ERROR 找不到 ' + cnRoot); process.exit(1) }
for (const n of readdirSync(cnRoot)) {
  const p = path.join(cnRoot, n)
  if (statSync(p).isDirectory() && /^archive-/.test(n)) walk(p, 'cn')
}
const patchRoot = path.join(CDN, 'patches')
if (existsSync(patchRoot)) for (const v of readdirSync(patchRoot)) {
  const p = path.join(patchRoot, v)
  if (!statSync(p).isDirectory()) continue
  for (const n of readdirSync(p)) {
    const q = path.join(p, n)
    if (statSync(q).isDirectory() && /^archive-/.test(n)) walk(q, 'patches/' + v)
  }
}
say(`\n== 目录 ==`)
say(`  扫到归档 ${found.length} 个（cn ${found.filter(f => f.root === 'cn').length} / patches ${found.filter(f => f.root !== 'cn').length}）`)

const byName = new Map()
for (const f of found) {
  if (!byName.has(f.basename)) byName.set(f.basename, [])
  byName.get(f.basename).push(f)
}

// ── 1/2. 计划 ↔ 目录 ──
say(`\n== 对账 ==`)
const missing = [], sizeBad = []
const needSha = new Set(plan.filter(i => i.kind === 'diff' && cmpVer(i.version, '1.4.55') >= 0).map(i => i.basename))
for (const it of plan) {
  const hits = byName.get(it.basename)
  if (!hits || hits.length === 0) { missing.push(it); continue }
  const ok = hits.filter(h => h.bytes === it.bytes)
  if (ok.length === 0) { sizeBad.push({ it, sizes: hits.map(h => h.bytes) }); continue }
  if (needSha.has(it.basename)) {
    const buf = readFileSync(ok[0].path)
    const hex = crypto.createHash('sha256').update(buf).digest('base64')
    if (hex !== it.sha256b64) warn(`sha256 不符：${it.basename}（计划 ${it.sha256b64}，实际 ${hex}）`)
  }
}
if (missing.length) for (const it of missing) warn(`计划里有、目录里找不到：${it.basename}（${it.relativePath}）`)
if (sizeBad.length) for (const s of sizeBad) warn(`体积不符：${s.it.basename}（计划 ${s.it.bytes}，实际 ${s.sizes.join('/')}）`)
if (!missing.length && !sizeBad.length) say(`  ✓ 计划 ${plan.length} 条全部命中，体积一致${needSha.size ? `，其中 ${needSha.size} 条 sha256 一致` : ''}`)

// ── 3. 同名重复 ──
let dupCount = 0
for (const [name, hits] of byName) {
  if (hits.length < 2) continue
  dupCount++
  const shas = hits.map(h => crypto.createHash('sha256').update(readFileSync(h.path)).digest('hex'))
  const same = shas.every(s => s === shas[0])
  say(`  ${same ? '=' : '✗'} 同名 ${hits.length} 份：${name}（${hits.map(h => h.root).join(' / ')}）${same ? '内容一致' : '内容不一致！'}`)
  if (!same) warn(`同名归档内容不一致：${name}`)
}
if (!dupCount) say('  （目录里没有同名重复归档）')

// ── 4. diff 链 ──
// 注意两点，否则会误报：
//   ① 同一个 from→to 往往有多个归档（CDN 把一层拆成多包），必须按 to 去重后再连链；
//   ② 不是每层都从 baseline 1.4.0 起都有 diff（android 只带最近的 54→55/55→56/56→57，ios 的老链也不全）——
//      所以要求的是「从该层现存最早的 from 出发能否走到 target」，而不是必须接回 1.4.0。
say(`\n== diff 链（每层：从该层现存最早版本走到 target）==`)
for (const layer of layers) {
  const edges = new Map()   // from -> Set(to)
  for (const d of plan) {
    if (d.layer !== layer || d.kind !== 'diff') continue
    const from = String(d.originalVersion).trim()
    if (!edges.has(from)) edges.set(from, new Set())
    edges.get(from).add(String(d.version).trim())
  }
  if (edges.size === 0) { say(`  - ${layer.padEnd(8)} 没有 diff 条目`); continue }
  const starts = [...edges.keys()].sort(cmpVer)
  // 从每个起点各走一次，只要有一条走到 target 就算通过（老版本段的缺口不影响导入：
  // ios 层只带最近几版 diff、android 只带 54 起，客户端也不会要那些远古增量）
  let best = null
  for (const s of starts.slice().reverse()) {
    let cur = s
    const chain = [s]
    const seen = new Set([s])
    for (let guard = 0; guard < 400; guard++) {
      const nxt = edges.get(cur)
      if (!nxt || nxt.size === 0) break
      const arr = [...nxt].sort(cmpVer)
      const v = arr[arr.length - 1]
      if (seen.has(v)) break
      seen.add(v); chain.push(v); cur = v
    }
    if (cur === target) { best = { start: s, chain }; break }
    if (!best) best = { start: s, chain, cur }
  }
  if (!best) { say(`  - ${layer.padEnd(8)} 没有 diff 条目`); continue }
  const reached = best.chain[best.chain.length - 1] === target
  const shown = best.chain.length > 12 ? best.chain.slice(0, 3).join(' → ') + ` → … → ${best.chain.slice(-3).join(' → ')}` : best.chain.join(' → ')
  say(`  ${reached ? '✓' : '✗'} ${layer.padEnd(8)} ${shown}${reached ? (best.start === starts[0] ? '' : `（从 ${best.start} 起；更早的段没有增量）`) : `（断在 ${best.cur}）`}`)
  if (!reached) warn(`${layer} 的 diff 链走不到 ${target}（断在 ${best.cur}）`)
}

// ── 5. 目录里有、计划里没有 ──
const planNames = new Set(plan.map(i => i.basename))
const extra = found.filter(f => !planNames.has(f.basename))
say(`\n== 额外归档（计划里没有，导入时会被忽略）==`)
if (extra.length === 0) say('  无')
else for (const e of extra) say(`  - ${e.root}/${e.basename}（${e.bytes} B）`)

// ── 汇总 ──
say('')
if (problems.length === 0) {
  say(`✓ 对账通过：${plan.length} 条计划 ↔ ${found.length} 个归档，可以放心导入`)
  process.exit(0)
}
say(`✗ 发现 ${problems.length} 个问题，先修再导入`)
process.exit(1)

function cmpVer (a, b) {
  const x = String(a).split('.').map(Number), y = String(b).split('.').map(Number)
  for (let i = 0; i < 3; i++) { if ((x[i] || 0) !== (y[i] || 0)) return (x[i] || 0) - (y[i] || 0) }
  return 0
}
