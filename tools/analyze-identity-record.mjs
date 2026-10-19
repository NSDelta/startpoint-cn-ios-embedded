#!/usr/bin/env node
// analyze-identity-record.mjs —— 解剖主二进制里那两条「app id + team id + 32 字节」身份记录：
//   1) 找到所有 `com.leiting.wf\0RUH384Q4E8\0` 偏移，打印记录体（含前后的长度字段）十六进制；
//   2) 用一批候选输入（身份字符串 + 包内文件字节）算 md5/sha1/sha256/sha512，看能否在记录体里找到 ——
//      若 32 字节就是某个可复算的摘要，那我们就能为新的 app id **重算**它，从而让 AIR/DRM 接受新身份。
//
// 用法: node tools/analyze-identity-record.mjs --ipa=dist/spcn-ios-standalone-testdj.ipa [--app-id=com.leiting.wf] [--team=RUH384Q4E8]
import { readFileSync } from 'node:fs'
import path from 'node:path'
import crypto from 'node:crypto'
import { readZipEntries, readEntryData } from './vendor/lib/zip-ipa.mjs'

const args = Object.fromEntries(process.argv.slice(2).map(a => {
  const m = a.match(/^--([^=]+)(?:=(.*))?$/); return m ? [m[1], m[2] === undefined ? true : m[2]] : [a, true]
}))
if (!args.ipa) { console.log('需要 --ipa='); process.exit(1) }
const APP_ID = String(args['app-id'] || 'com.leiting.wf')
const TEAM = String(args.team || 'RUH384Q4E8')
const entries = readZipEntries(readFileSync(String(args.ipa)))
const appDir = entries.find(e => /^Payload\/[^/]+\.app\/Info\.plist$/.test(e.name)).name.split('/').slice(0, 2).join('/')
const binEntry = entries.find(e => e.name === `${appDir}/${path.posix.basename(appDir).replace(/\.app$/, '')}`)
if (!binEntry) { console.log('找不到主二进制'); process.exit(1) }
const bin = readEntryData(binEntry)
console.log(`主二进制 ${binEntry.name}  ${bin.length} B`)
const hexOf = (b, n) => [...b.subarray(0, n)].map(x => x.toString(16).padStart(2, '0')).join(' ')

// ── 1. 找身份记录 ──
const pattern = Buffer.from(`${APP_ID}\0${TEAM}\0`, 'latin1')
const offs = []
for (let i = 0; (i = bin.indexOf(pattern, i)) !== -1; i++) offs.push(i)
console.log(`\n模式 ${JSON.stringify(pattern.toString('latin1'))} 命中 ${offs.length} 处：${offs.map(o => '0x' + o.toString(16)).join(', ')}`)

const bodies = []
for (const off of offs) {
  const start = Math.max(0, off - 24), end = Math.min(bin.length, off + 128)
  console.log(`\n== 记录 @0x${off.toString(16)}（含前 24 字节）==`)
  for (let p = start; p < end; p += 16) {
    const row = bin.subarray(p, Math.min(p + 16, end))
    const asc = [...row].map(b => (b >= 0x20 && b < 0x7f) ? String.fromCharCode(b) : '.').join('')
    console.log(`  ${p.toString(16).padStart(8, '0')}  ${hexOf(row, row.length).padEnd(47)}  |${asc}|`)
  }
  bodies.push(bin.subarray(off, off + 160))
}

// ── 2. 候选输入的摘要，是否出现在记录体里 ──
const cands = []
const strCands = [
  APP_ID,
  `${TEAM}.${APP_ID}`,
  `${APP_ID}.${TEAM}`,
  `${APP_ID}${TEAM}`,
  TEAM,
  `<id>${APP_ID}</id>`,
  `${APP_ID}\0${TEAM}\0`,
]
for (const s of strCands) cands.push([`str:${JSON.stringify(s)}`, Buffer.from(s, 'latin1')])

for (const rel of [`${appDir}/META-INF/AIR/__swf__`, `${appDir}/META-INF/AIR/license.txt`,
                   `${appDir}/META-INF/AIR/application.xml`, `${appDir}/worldflipper_ios_release.swf`,
                   `${appDir}/Info.plist`]) {
  const e = entries.find(x => x.name === rel)
  if (!e) { console.log(`（包内没有 ${rel}）`); continue }
  const d = readEntryData(e)
  cands.push([`file:${path.posix.basename(rel)}(${d.length}B)`, d])
}

const algs = ['md5', 'sha1', 'sha256', 'sha512']
let hit = 0
for (const [label, buf] of cands) {
  for (const alg of algs) {
    const dig = crypto.createHash(alg).update(buf).digest()
    for (let bi = 0; bi < bodies.length; bi++) {
      const at = bodies[bi].indexOf(dig)
      if (at >= 0) { console.log(`★ 命中：${alg}(${label}) 出现在记录 #${bi} 内偏移 +${at}（长度 ${dig.length}）`); hit++ }
    }
  }
}
if (!hit) console.log('\n没有任何候选摘要出现在记录体里（⇒ 那 32 字节不是这些输入的 md5/sha1/sha256/sha512）')

// ── 3. 记录体里可疑的「32 字节块」清单（供人工比对）──
for (let bi = 0; bi < bodies.length; bi++) {
  const b = bodies[bi]
  for (let at = 26; at + 32 <= b.length; at += 1) {
    // 找高熵块：32 字节里没有明显的 0 或 ASCII 重复
    const chunk = b.subarray(at, at + 32)
    const zeros = [...chunk].filter(x => x === 0).length
    if (zeros > 2) continue
    const printable = [...chunk].filter(x => x >= 0x20 && x < 0x7f).length
    if (printable > 24) continue
    if (at % 1 === 0) {
      console.log(`记录 #${bi} +${at}: ${hexOf(chunk, 32)}`)
      break   // 每个记录只报第一个最高熵块，避免刷屏
    }
  }
}
