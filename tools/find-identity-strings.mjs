#!/usr/bin/env node
// find-identity-strings.mjs —— 主二进制里找「应用身份」字符串（AIR 的 application id / bundle id 等）。
//
// 背景：真机实测黑屏时 stdout 里只有一行 `AdobeAIR: application packaging error`（didFinishLaunching 后 150 ms）。
// AIR iOS 会拿烧进二进制的应用身份与包的 CFBundleIdentifier 对照 ⇒ 我们改了 Info.plist 的 bundle id
// （com.leiting.wf → com.testdj.wf）就可能是它报错的原因。这个脚本把二进制的候选身份串全列出来，
// 并给出「等长改写」的可行性判断。
//
// 用法：node tools/find-identity-strings.mjs --ipa=<ipa> [--patterns=com.leiting.wf,com.testdj.wf] [--context=64]

import { readFileSync } from 'node:fs'
import { readZipEntries, readEntryData } from './vendor/lib/zip-ipa.mjs'

const args = Object.fromEntries(process.argv.slice(2).map(a => {
  const m = a.match(/^--([^=]+)(?:=(.*))?$/); return m ? [m[1], m[2] === undefined ? true : m[2]] : [a.replace(/^--/, ''), true]
}))
const IPA = args.ipa ? String(args.ipa) : ''
if (!IPA) { console.log('用法：node tools/find-identity-strings.mjs --ipa=<ipa> [--patterns=a,b] [--context=64]'); process.exit(1) }
const CTX = Number(args.context || 64)
const PATTERNS = String(args.patterns || 'com.leiting.wf,com.testdj.wf,leiting,worldflipper,AIRApplication,applicationId').split(',')

const entries = readZipEntries(readFileSync(IPA))
const app = entries.find(e => /^Payload\/[^/]+\.app\/Info\.plist$/.test(e.name)).name.split('/').slice(0, 2).join('/')
const exeName = app.split('/')[1].replace(/\.app$/, '')
const exe = entries.find(e => e.name === `${app}/${exeName}`)
if (!exe) { console.log('找不到主二进制'); process.exit(1) }
const buf = readEntryData(exe)
console.log(`主二进制 ${exe.name}  ${buf.length} B  (usize ${exe.usize})`)
console.log('')

for (const pat of PATTERNS) {
  const needle = Buffer.from(pat, 'latin1')
  const hits = []
  let off = buf.indexOf(needle)
  while (off !== -1 && hits.length < 200) { hits.push(off); off = buf.indexOf(needle, off + 1) }
  if (!hits.length) { console.log(`── "${pat}" 0 处`); continue }
  console.log(`── "${pat}" ${hits.length} 处${hits.length >= 200 ? '（截断到 200）' : ''}`)
  for (const h of hits.slice(0, 12)) {
    const a = Math.max(0, h - CTX), b = Math.min(buf.length, h + needle.length + CTX)
    const ctx = buf.subarray(a, b).toString('latin1').replace(/[^\x20-\x7e]/g, '.')
    console.log(`   0x${h.toString(16)}  …${ctx}…`)
  }
  if (hits.length > 12) console.log(`   …另有 ${hits.length - 12} 处`)
  console.log('')
}

console.log('── 结论提示 ──')
console.log('· 若 com.leiting.wf 在二进制里出现（尤其旁边就是 AIR 的应用身份字段），说明 AIR 的 application id 是烧死的：')
console.log('  改 CFBundleIdentifier 必须**同时等长改写**这个串 —— 所以新 bundle id 要挑**与 com.leiting.wf 同为 14 字符**的。')
console.log('· 若二进制里根本没有 com.leiting.wf，则 packaging error 与身份无关，去查签名方式（AppSync 直装未真签）。')
