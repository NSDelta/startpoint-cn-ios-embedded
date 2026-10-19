#!/usr/bin/env node
// compare-info-plist.mjs —— 逐行比对两个 IPA 里的 Info.plist（确认我们改 bundle id 时没改坏 plist）。
//
// 背景：真机黑屏时 AIR 只打 `AdobeAIR: application packaging error`。改 bundle id 是我们对 Info.plist
// 唯一的动作（正则替换 <key>CFBundleIdentifier</key> 后的 <string>）—— 这个脚本证明改完之后 plist
// 依然逐行合法、只有预期的那几行不同。
//
// 用法：node tools/compare-info-plist.mjs --a=<原始 ipa> --b=<我们出的 ipa> [--app-name=worldflipper]

import { readFileSync } from 'node:fs'
import { readZipEntries, readEntryData } from './vendor/lib/zip-ipa.mjs'

const args = Object.fromEntries(process.argv.slice(2).map(a => {
  const m = a.match(/^--([^=]+)(?:=(.*))?$/); return m ? [m[1], m[2] === undefined ? true : m[2]] : [a.replace(/^--/, ''), true]
}))
if (!args.a || !args.b) { console.log('用法：node tools/compare-info-plist.mjs --a=<ipa> --b=<ipa>'); process.exit(1) }

function plistText (ipa) {
  const entries = readZipEntries(readFileSync(String(ipa)))
  const e = entries.find(x => /^Payload\/[^/]+\.app\/Info\.plist$/.test(x.name))
  if (!e) throw new Error('找不到 Info.plist：' + ipa)
  return { name: e.name, text: readEntryData(e).toString('utf8') }
}

const A = plistText(args.a), B = plistText(args.b)
console.log(`A ${args.a}  → ${A.name}  ${A.text.length} 字符`)
console.log(`B ${args.b}  → ${B.name}  ${B.text.length} 字符`)
console.log('')

const la = A.text.split('\n'), lb = B.text.split('\n')
if (la.length !== lb.length) console.log(`⚠️ 行数不同：${la.length} vs ${lb.length}`)
let diff = 0
const n = Math.max(la.length, lb.length)
for (let i = 0; i < n; i++) {
  const x = la[i], y = lb[i]
  if (x === y) continue
  diff++
  console.log(`行 ${i + 1}:`)
  console.log(`  A: ${(x ?? '(缺)').trim()}`)
  console.log(`  B: ${(y ?? '(缺)').trim()}`)
}
console.log('')
console.log(diff === 0 ? '两处 Info.plist 完全一致' : `共 ${diff} 行不同（应仅为 CFBundleIdentifier / CFBundleDisplayName）`)
