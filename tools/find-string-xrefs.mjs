#!/usr/bin/env node
// find-string-xrefs.mjs —— 在 arm64 Mach-O 里找「引用某个字符串的代码」（ADRP+ADD 配对扫描）。
//
// 为什么：真机黑屏根因是 AIR 运行时自检失败，只留下一行 `AdobeAIR: application packaging error`。
// 要弄清它到底在比对什么（entitlements 副本？bundle id？签名？），必须找到引用这个字符串的函数。
// 手上没有针对本二进制的 IDA 库，但 arm64 的「取字符串地址」只有一种常见写法：
//     ADRP Xn, page          ; 0x90000000 掩码 0x9F000000
//     ADD  Xn, Xn, #lo12     ; 0x91000000 掩码 0xFF800000（也接受 LDR 的 0xF9400000 形式）
// 本脚本扫 __TEXT,__text，找出目标地址被 ADRP(+ADD) 构造出来的所有位置，打印前后若干条指令的原始编码。
//
// 用法：node tools/find-string-xrefs.mjs --ipa=<ipa> --string="AdobeAIR: application packaging error"
//        [--limit=20] [--words=24]

import { readFileSync } from 'node:fs'
import { readZipEntries, readEntryData } from './vendor/lib/zip-ipa.mjs'

const args = Object.fromEntries(process.argv.slice(2).map(a => {
  const m = a.match(/^--([^=]+)(?:=(.*))?$/); return m ? [m[1], m[2] === undefined ? true : m[2]] : [a.replace(/^--/, ''), true]
}))
const IPA = String(args.ipa || '')
const NEEDLE = String(args.string || '')
if (!IPA || !NEEDLE) { console.log('用法：node tools/find-string-xrefs.mjs --ipa=<ipa> --string="..." [--limit=20] [--words=24]'); process.exit(1) }
const LIMIT = Number(args.limit || 20), WORDS = Number(args.words || 24)

const entries = readZipEntries(readFileSync(IPA))
const app = entries.find(e => /^Payload\/[^/]+\.app\/Info\.plist$/.test(e.name)).name.split('/').slice(0, 2).join('/')
const exeName = app.split('/')[1].replace(/\.app$/, '')
const buf = readEntryData(entries.find(e => e.name === `${app}/${exeName}`))

// ── Mach-O 头部/段表 ──
const le = buf.readUInt32LE(0) === 0xfeedfacf
const u32 = (o) => (le ? buf.readUInt32LE(o) : buf.readUInt32BE(o))
const ncmds = u32(16)
let off = 32, text = null
for (let i = 0; i < ncmds; i++) {
  const cmd = u32(off), size = u32(off + 4)
  if (cmd === 0x19) { // LC_SEGMENT_64
    const segname = buf.subarray(off + 8, off + 24).toString('latin1').replace(/\0.*$/, '')
    const fileoff = Number(buf.readBigUInt64LE(off + 40)), filesize = Number(buf.readBigUInt64LE(off + 48))
    const nsects = u32(off + 64)
    for (let s = 0; s < nsects; s++) {
      const so = off + 72 + s * 80
      const sect = buf.subarray(so, so + 16).toString('latin1').replace(/\0.*$/, '')
      const addr = Number(buf.readBigUInt64LE(so + 32))
      const size2 = Number(buf.readBigUInt64LE(so + 40))
      const soff = u32(so + 48)
      if (segname === '__TEXT' && (sect === '__text' || sect === '__cstring' || sect === '__const')) {
        console.log(`段区 ${segname},${sect}  vmaddr=0x${addr.toString(16)}  size=0x${size2.toString(16)}  fileoff=0x${soff.toString(16)}`)
      }
      if (segname === '__TEXT' && sect === '__text') text = { addr, size: size2, fileoff: soff }
    }
    void fileoff; void filesize
  }
  off += size
}
if (!text) { console.log('没找到 __TEXT,__text'); process.exit(1) }

// ── 字符串表里的偏移（收集所有出现）──
const needle = Buffer.from(NEEDLE, 'latin1')
const strOffsets = []
let p = buf.indexOf(needle)
while (p !== -1) { strOffsets.push(p); p = buf.indexOf(needle, p + 1) }
console.log(`\n字符串 "${NEEDLE}" 出现 ${strOffsets.length} 处：${strOffsets.map(o => '0x' + o.toString(16)).join(', ')}`)

// ── 扫 __TEXT,__text 找 ADRP ──
const targets = new Set(strOffsets)
const code = text.fileoff, end = text.fileoff + text.size
let found = 0
const hits = []
for (let o = code; o + 8 <= end; o += 4) {
  const w = buf.readUInt32LE(o)
  if ((w & 0x9f000000) !== 0x90000000) continue   // ADRP
  const rd = w & 0x1f
  const immlo = (w >>> 29) & 0x3
  const immhi = (w >>> 5) & 0x7ffff
  let imm = (immhi << 2) | immlo
  if (imm & (1 << 20)) imm -= (1 << 21)           // 符号扩展 21 位
  const pcAddr = text.addr + (o - code)
  const page = (pcAddr & ~0xfffn) + (imm << 12)
  // 紧跟的若干条里找 ADD/LDR 带上目标低 12 位
  for (let k = 1; k <= 4 && o + 4 * k + 4 <= end; k++) {
    const w2 = buf.readUInt32LE(o + 4 * k)
    const isADD = (w2 & 0xff800000) === 0x91000000
    const isLDR = (w2 & 0xffc00000) === 0xf9400000
    if (!isADD && !isLDR) continue
    const imm12 = (w2 >>> 10) & 0xfff
    const shift = (w2 >>> 22) & 0x3
    const lo = shift === 1 ? imm12 << 12 : imm12
    const rn = (w2 >>> 5) & 0x1f
    if (rn !== rd) continue
    const target = page + lo
    if (!targets.has(target)) continue
    found++
    if (hits.length < LIMIT) hits.push({ at: pcAddr, target, o })
  }
}
console.log(`\nADRP(+ADD/LDR) 命中 ${found} 处（打印前 ${hits.length}）`)
for (const h of hits) {
  console.log(`\n── 0x${h.at.toString(16)} → 0x${h.target.toString(16)}（'${NEEDLE.slice(0, 40)}'）`)
  const start = Math.max(code, h.o - WORDS * 4), stop = Math.min(end, h.o + WORDS * 4)
  for (let o = start; o < stop; o += 4) {
    const mark = o === h.o ? '>>' : '  '
    console.log(`   ${mark} 0x${(text.addr + (o - code)).toString(16)}  ${buf.readUInt32LE(o).toString(16).padStart(8, '0')}`)
  }
}
