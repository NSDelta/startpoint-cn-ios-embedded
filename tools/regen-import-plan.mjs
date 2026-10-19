#!/usr/bin/env node
// regen-import-plan.mjs —— 把 CDN 增量补丁（1.4.55 / 1.4.56 / 1.4.57）追加进 iOS 资源导入计划。
//
// 背景：`ios/src/importer/CdnImportPlan.generated.{h,m}` 是 `ios/importer/tools/verify-plan.mjs --emit`
// 生成的 634 条「1.4.54 全量 + diff 链」条目（originalVersion/version/size/sha256 全带了），
// 但补丁版本 1.4.55–57 的归档不在里面 ⇒ 面板导入只能到 1.4.54。本脚本按 patch-manifest.json
// 把这三版共 12 个归档追加成 diff 条目（顺序即写入顺序，后写覆盖先写），并同步改头文件的
// COUNT / TARGET_VERSION / TOTAL_BYTES / TOTAL_FILES。
//
// 幂等：每次都以「剔除本脚本追加过的条目（version >= 1.4.55）」后的计划为基准重算。
//
// 用法：
//   node tools/regen-import-plan.mjs [--patches=D:\wfspcn\resources\server\.cdn\patches]
//                                    [--plan=ios\src\importer] [--dry-run]

import { readFileSync, writeFileSync, existsSync, readdirSync, statSync } from 'node:fs'
import path from 'node:path'

const ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1')), '..')
const args = Object.fromEntries(process.argv.slice(2).map(a => {
  const m = a.match(/^--([^=]+)(?:=(.*))?$/); return m ? [m[1], m[2] === undefined ? true : m[2]] : [a.replace(/^--/, ''), true]
}))
const PATCHES = path.resolve(String(args.patches || 'D:/wfspcn/resources/server/.cdn/patches'))
const PLAN_DIR = path.resolve(String(args.plan || path.join(ROOT, 'ios', 'src', 'importer')))
const H = path.join(PLAN_DIR, 'CdnImportPlan.generated.h')
const M = path.join(PLAN_DIR, 'CdnImportPlan.generated.m')
const DRY = args['dry-run'] === true
const say = (s) => console.log(s)
const die = (s) => { console.log('ERROR ' + s); process.exit(1) }

for (const f of [H, M]) if (!existsSync(f)) die('找不到 ' + f)
if (!existsSync(PATCHES)) die('找不到补丁目录 ' + PATCHES)

const hSrc = readFileSync(H, 'utf8')
const mSrc = readFileSync(M, 'utf8')

// ── 解析现有条目 ──
// 字段切分用字符走查（不能用「引号 or 逗号前所有字符」的正则：逗号后的空格会让后者把下一个带引号字段整段吞掉，
// 于是值里会残留 \"…\" 这种字面引号，写回 C 源码后字符串就多了一对引号 —— 真机上导入就匹配不上）。
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
  const bytes = Number(String(fields[6]).replace(/ULL$/i, '').trim())
  return {
    relativePath: fields[0], basename: fields[1], layer: fields[2], kind: fields[3],
    version: fields[4], originalVersion: String(fields[5]).trim() === '0' ? '0' : fields[5],
    bytes: Number.isFinite(bytes) ? bytes : 0, sha256b64: fields[7], appended: false,
  }
}
const items = []
for (const line of mSrc.split('\n')) {
  if (line.indexOf('archive-') < 0) continue
  const it = parseItemLine(line)
  if (it) items.push(it)
}
if (items.length === 0) die('一条现有条目都没解析出来（格式变了？）')
const baseCount = Number((hSrc.match(/#define CDN_IMPORT_PLAN_COUNT\s+(\d+)U/) || [])[1] || 0)
say(`现有条目 ${items.length}（头文件 COUNT=${baseCount}）`)

// ── 读补丁清单 ──
const versions = readdirSync(PATCHES).filter(n => /^\d+\.\d+\.\d+$/.test(n)).sort(byVersion)
function byVersion (a, b) { return cmpVer(a, b) }
function cmpVer (a, b) { const x = a.split('.').map(Number), y = b.split('.').map(Number); for (let i = 0; i < 3; i++) if (x[i] !== y[i]) return x[i] - y[i]; return 0 }

const patchItems = []
for (const v of versions) {
  const mf = path.join(PATCHES, v, 'patch-manifest.json')
  if (!existsSync(mf)) { say(`  - ${v}: 无 patch-manifest.json，跳过`); continue }
  const man = JSON.parse(readFileSync(mf, 'utf8'))
  const target = String(man.targetVersion || v)
  const base = String(man.baseVersion || '')
  const arch = (man.archives || []).slice().sort((x, y) => String(x.relativePath).localeCompare(String(y.relativePath)))
  let n = 0
  for (const a of arch) {
    const rel = String(a.relativePath)
    // 归档文件本身必须存在（打包时已 merge 进 cn/，这里只做存在性提示）
    const onDisk = path.join(PATCHES, v, rel)
    if (!existsSync(onDisk)) { say(`  ! ${v}/${rel} 不存在，跳过`); continue }
    const bytes = Number(a.bytes || 0) || statSync(onDisk).size
    const b64 = /^[0-9a-f]{64}$/i.test(String(a.sha256 || '')) ? Buffer.from(a.sha256, 'hex').toString('base64') : ''
    if (!b64) die(`${v}/${rel} 的 sha256 不是 hex`)
    patchItems.push({ relativePath: rel, basename: path.posix.basename(rel), layer: String(a.layer || ''), kind: /diff/i.test(rel) ? 'diff' : 'full', version: target, originalVersion: base, bytes, sha256b64: b64, appended: true })
    n++
  }
  say(`  + ${v}: ${n} 个归档（${base || '?'} → ${target}，合计 ${(arch.reduce((s, a) => s + Number(a.bytes || 0), 0) / 1048576).toFixed(1)} MB）`)
}
if (patchItems.length === 0) die('没有可追加的补丁条目')

// ── 合并（剔除旧的追加项 + 去重）──
const kept = items.filter(it => it.appended === false && !isPatchVersion(it.version))
function isPatchVersion (v) { return versions.some(p => cmpVer(String(v), p) >= 0) }
const seen = new Set(kept.map(i => i.relativePath))
const added = []
for (const it of patchItems) { if (seen.has(it.relativePath)) continue; seen.add(it.relativePath); added.push(it) }
const all = kept.concat(added)
say(`合并后 ${all.length} 条（原有 ${kept.length} + 追加 ${added.length}）`)

const badBytes = all.filter(i => !Number.isFinite(i.bytes)).length
if (badBytes) say(`  ! 有 ${badBytes} 条 bytes 解析不出来（按 0 计）`)
const totalBytes = all.reduce((s, i) => s + (Number.isFinite(i.bytes) ? i.bytes : 0), 0)
// 文件数：基准 137820 + 补丁归档里「新增」的唯一名字数（近似；引擎会逐条 CRC 校验，这里的总数只用于自检展示）
let extraFiles = 0
const nameSet = new Set()
for (const it of added) {
  const p = findArchive(it.relativePath)
  if (!p) continue
  try {
    const names = listZipNames(p)
    for (const n of names) if (!nameSet.has(n)) { nameSet.add(n); extraFiles++ }
  } catch (e) { say(`  ! 读 ${it.relativePath} 条目失败：${e.message}`) }
}
const baseFiles = Number((hSrc.match(/#define CDN_IMPORT_PLAN_TOTAL_FILES\s+(\d+)U/) || [])[1] || 137820)
const totalFiles = baseFiles + extraFiles
say(`大小合计 ${(totalBytes / 1073741824).toFixed(2)} GB；文件数 ${baseFiles}（1.4.54 基准）+ ${extraFiles}（补丁内唯一新名，近似）= ${totalFiles}`)

// ── 生成 ──
const q = (s) => `"${String(s).replace(/\\/g, '\\\\').replace(/"/g, '\\"')}"`
const hOut = hSrc
  .replace(/#define CDN_IMPORT_PLAN_TARGET_VERSION "[^"]*"/, `#define CDN_IMPORT_PLAN_TARGET_VERSION "${versions[versions.length - 1]}"`)
  .replace(/#define CDN_IMPORT_PLAN_COUNT\s+\d+U/, `#define CDN_IMPORT_PLAN_COUNT ${all.length}U`)
  .replace(/#define CDN_IMPORT_PLAN_TOTAL_BYTES\s+\d+ULL/, `#define CDN_IMPORT_PLAN_TOTAL_BYTES ${totalBytes}ULL`)
  .replace(/#define CDN_IMPORT_PLAN_TOTAL_FILES\s+\d+U/, `#define CDN_IMPORT_PLAN_TOTAL_FILES ${totalFiles}U`)

const mHead = mSrc.slice(0, mSrc.indexOf('const CdnImportPlanEntry gCdnImportPlan'))
const split = mHead.indexOf('#include')
const head = split >= 0 ? mHead.slice(0, split) : ''
const body = all.map(it => `    { ${q(it.relativePath)}, ${q(it.basename)}, ${q(it.layer)}, ${q(it.kind)}, ${q(it.version)}, ${it.originalVersion === '0' ? '0' : q(it.originalVersion)}, ${it.bytes}ULL, ${q(it.sha256b64)} },`).join('\n')
const mOut = `${head}#include "CdnImportPlan.generated.h"\n\nconst CdnImportPlanEntry gCdnImportPlan[CDN_IMPORT_PLAN_COUNT] = {\n${body}\n};\n`

if (DRY) { say('\n--dry-run：不写文件'); process.exit(0) }
writeFileSync(H, hOut)
writeFileSync(M, mOut)
say(`\nOK  已写入 ${path.relative(ROOT, H)} / ${path.relative(ROOT, M)}`)
say(`    COUNT=${all.length}  TARGET=${versions[versions.length - 1]}  TOTAL_BYTES=${totalBytes}  TOTAL_FILES=${totalFiles}`)

// ── 工具 ──
function findArchive (rel) {
  for (const v of versions) { const p = path.join(PATCHES, v, rel); if (existsSync(p)) return p }
  return ''
}
function listZipNames (file) {
  const buf = readFileSync(file)
  let eocd = -1
  for (let i = buf.length - 22; i >= 0 && i > buf.length - 66000; i--) if (buf.readUInt32LE(i) === 0x06054b50) { eocd = i; break }
  if (eocd < 0) throw new Error('不是 zip（找不到 EOCD）')
  const total = buf.readUInt16LE(eocd + 10), cdSize = buf.readUInt32LE(eocd + 12), cdOff = buf.readUInt32LE(eocd + 16)
  if (cdOff === 0xffffffff) throw new Error('zip64 不受支持')
  const names = []
  let p = cdOff
  for (let i = 0; i < total; i++) {
    if (buf.readUInt32LE(p) !== 0x02014b50) break
    const nLen = buf.readUInt16LE(p + 28), eLen = buf.readUInt16LE(p + 30), cLen = buf.readUInt16LE(p + 32)
    const name = buf.slice(p + 46, p + 46 + nLen).toString('utf8')
    if (!name.endsWith('/')) names.push(name)
    p += 46 + nLen + eLen + cLen
  }
  return names
}
