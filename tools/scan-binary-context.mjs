#!/usr/bin/env node
// scan-binary-context.mjs —— 在 Mach-O 里看某文件偏移附近的字节 / 找字符串偏移。
// 用途：AIR 的 `application packaging error` 到底在跟哪一份身份对账（二进制里烧死的 app id 副本）。
//
// 用法：
//   node tools/scan-binary-context.mjs --bin=D:\wfspcn\worldflipper --offsets=0x6521ffc,0x661f106 [--before=64] [--after=160]
//   node tools/scan-binary-context.mjs --bin=... --find=META-INF/AIR [--find=SC_Info] [--ascii-min=6]
//
// 说明：iOS 可执行文件的 __TEXT 段 vmaddr=0x100000000、fileoff=0 ⇒ 文件偏移 = 虚拟地址 - 0x100000000。
import { readFileSync, statSync } from 'node:fs'
import crypto from 'node:crypto'

const args = Object.fromEntries(process.argv.slice(2).map(a => {
  const m = a.match(/^--([^=]+)(?:=(.*))?$/); return m ? [m[1], m[2] === undefined ? true : m[2]] : [a, true]
}))
const BIN = String(args.bin || '')
if (!BIN) { console.log('用法见文件头注释'); process.exit(1) }
const buf = readFileSync(BIN)
console.log(`文件 ${BIN}  ${statSync(BIN).size} B  sha256 ${crypto.createHash('sha256').update(buf).digest('hex').slice(0, 16)}…`)

const printable = (b) => (b >= 0x20 && b < 0x7f) ? String.fromCharCode(b) : '.'

function hexdump (off, len) {
  const start = Math.max(0, off)
  const end = Math.min(buf.length, off + len)
  for (let p = start; p < end; p += 16) {
    const row = buf.subarray(p, Math.min(p + 16, end))
    const hex = [...row].map(b => b.toString(16).padStart(2, '0')).join(' ')
    const asc = [...row].map(printable).join('')
    console.log(`  ${p.toString(16).padStart(9, '0')}  ${hex.padEnd(47)}  |${asc}|`)
  }
}

if (args.offsets) {
  const before = Number(args.before ?? 64), after = Number(args.after ?? 160)
  for (const s of String(args.offsets).split(',')) {
    const off = Number(s.trim())
    if (!Number.isFinite(off)) continue
    console.log(`\n== 偏移 0x${off.toString(16)}（±${before}/${after}）==`)
    hexdump(off - before, before + after)
  }
}

if (args.find) {
  const pats = Array.isArray(args.find) ? args.find : [args.find]
  const min = Number(args['ascii-min'] ?? 6)
  // 扫描所有可打印串（长度 >= min），再按 pattern 过滤
  const strings = []
  let run = []
  for (let i = 0; i < buf.length; i++) {
    const b = buf[i]
    if (b >= 0x20 && b < 0x7f) { run.push(b); continue }
    if (run.length >= min) strings.push({ off: i - run.length, s: Buffer.from(run).toString('latin1') })
    run = []
  }
  if (run.length >= min) strings.push({ off: buf.length - run.length, s: Buffer.from(run).toString('latin1') })
  console.log(`\n== 可打印串 ${strings.length} 条（长度 ≥${min}）==`)
  for (const p of pats) {
    const hits = strings.filter(x => x.s.includes(p))
    console.log(`\n-- "${p}"：${hits.length} 命中 --`)
    for (const h of hits.slice(0, 40)) {
      console.log(`  0x${h.off.toString(16).padStart(8, '0')}  va=0x${(h.off + 0x100000000).toString(16)}  ${h.s.slice(0, 300)}`)
    }
    if (hits.length > 40) console.log(`  … 还有 ${hits.length - 40} 条`)
  }
}
