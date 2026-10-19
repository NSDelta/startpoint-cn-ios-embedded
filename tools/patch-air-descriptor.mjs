#!/usr/bin/env node
// patch-air-descriptor.mjs —— 把 AIR 描述符 `META-INF/AIR/application.xml` 里的应用 id 改成新的 bundle id。
//
// 为什么必须改（真机踩出来的）：AIR 的 iOS 运行时在启动时会把描述符里的 `<id>` 与 `CFBundleIdentifier` 对账
// （代码路径：sub_100012194 → sub_100011B94，失败就走 setjmp 兜底打
//  `AdobeAIR: application packaging error` 然后**根本不加载内容**）。表现是黑屏、不联网、不崩溃。
// 只改 Info.plist 的 CFBundleIdentifier 而不改这里 ⇒ 必黑屏。
//
// 用法：node tools/patch-air-descriptor.mjs --ipa=<输入 ipa> --bundle-id=com.testdj.wf [--out=<输出 ipa>]
//        （省略 --out 时原地重写 --ipa）

import { readFileSync, writeFileSync, copyFileSync } from 'node:fs'
import { readZipEntries, writeZipEntries, readEntryData, replaceEntryData } from './vendor/lib/zip-ipa.mjs'

const args = Object.fromEntries(process.argv.slice(2).map(a => {
  const m = a.match(/^--([^=]+)(?:=(.*))?$/); return m ? [m[1], m[2] === undefined ? true : m[2]] : [a.replace(/^--/, ''), true]
}))
const IPA = args.ipa ? String(args.ipa) : ''
const BUNDLE_ID = args['bundle-id'] ? String(args['bundle-id']) : ''
const OUT = args.out ? String(args.out) : IPA
if (!IPA || !BUNDLE_ID) { console.log('用法：node tools/patch-air-descriptor.mjs --ipa=<ipa> --bundle-id=com.testdj.wf [--out=<ipa>]'); process.exit(1) }

const entries = readZipEntries(readFileSync(IPA))
const appEntry = entries.find(e => /^Payload\/[^/]+\.app\/Info\.plist$/.test(e.name))
if (!appEntry) { console.log('ERROR 找不到 Payload/*.app/Info.plist'); process.exit(1) }
const app = appEntry.name.split('/').slice(0, 2).join('/')

// 当前 Info.plist 里的 bundle id（作为「旧 id」，用来定位要替换的描述符 id）
const plistText = readEntryData(entries.find(e => e.name === `${app}/Info.plist`)).toString('utf8')
const curId = (plistText.match(/<key>CFBundleIdentifier<\/key>\s*<string>([^<]+)<\/string>/) || [])[1]
if (!curId) { console.log('ERROR Info.plist 里读不到 CFBundleIdentifier'); process.exit(1) }

const descEntry = entries.find(e => e.name === `${app}/META-INF/AIR/application.xml`)
if (!descEntry) { console.log('ERROR 找不到 META-INF/AIR/application.xml'); process.exit(1) }
const xml = readEntryData(descEntry).toString('utf8')
const idBefore = (xml.match(/<id>([^<]+)<\/id>/) || [])[1]
if (!idBefore) { console.log('ERROR 描述符里没有 <id>'); process.exit(1) }

console.log(`── AIR 描述符 ${descEntry.name}`)
console.log(`   当前 <id> = ${idBefore}   Info.plist CFBundleIdentifier = ${curId}`)

if (idBefore === BUNDLE_ID) {
  console.log(`   ✓ 已经是目标 id（${BUNDLE_ID}），无需修改`)
  process.exit(0)
}
if (idBefore !== curId) {
  console.log(`   ⚠️ 描述符 id 与 Info.plist 当前不一致（${idBefore} vs ${curId}）——按 Info.plist 的当前值继续替换`)
}

// 只替换 <id> 元素（不要碰 CFBundleURLName / 礼包 SKU 之类同名文本）
let out = xml.replace(/(<id>)([^<]+)(<\/id>)/, `$1${BUNDLE_ID}$3`)
// InfoAdditions CDATA 里的 CFBundleURLName 也跟着改：它是 URL type 的名字，
// 与 Info.plist 的 CFBundleURLTypes 对应；保持两份一致更安全（不影响 URL scheme 本身）。
out = out.replace(/(<key>CFBundleURLName<\/key>\s*<string>)([^<]+)(<\/string>)/, `$1${BUNDLE_ID}$3`)
if (out === xml) { console.log('ERROR 替换没生效（<id> 结构可能不是预期形状）'); process.exit(1) }

const newId = (out.match(/<id>([^<]+)<\/id>/) || [])[1]
if (newId !== BUNDLE_ID) { console.log(`ERROR 替换后 <id> = ${newId}，不是 ${BUNDLE_ID}`); process.exit(1) }

replaceEntryData(entries, descEntry.name, Buffer.from(out, 'utf8'))
if (OUT !== IPA) copyFileSync(IPA, OUT)
writeFileSync(OUT, writeZipEntries(entries))

// 自校验：回读产物
const back = readZipEntries(readFileSync(OUT))
const backXml = readEntryData(back.find(e => e.name === `${app}/META-INF/AIR/application.xml`)).toString('utf8')
const backId = (backXml.match(/<id>([^<]+)<\/id>/) || [])[1]
const ok = backId === BUNDLE_ID && back.length === entries.length
console.log(`   替换：<id> ${idBefore} → ${newId}（${xml.length} → ${out.length} 字符）`)
console.log(`   ${ok ? '✓' : '✗'} 回读产物：<id> = ${backId}，条目数 ${back.length}`)
if (!ok) process.exit(1)
console.log(`OK  ${OUT}`)
