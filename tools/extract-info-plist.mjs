#!/usr/bin/env node
// extract-info-plist.mjs —— 从 IPA 里取出主 App 的 Info.plist，按需改 CFBundleIdentifier / CFBundleURLName，写到文件。
// 用途：设备侧做「身份一致性」实验时，从主机推一份精确构造的 plist 过去（设备上没有 plutil / 也没有靠谱的 plist 编辑器）。
//
// 用法：node tools/extract-info-plist.mjs --ipa=dist/x.ipa --out=.work/Info.plist [--bundle-id=com.x] [--url-name=com.x]
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import path from 'node:path'
import { readZipEntries, readEntryData } from './vendor/lib/zip-ipa.mjs'

const args = Object.fromEntries(process.argv.slice(2).map(a => {
  const m = a.match(/^--([^=]+)(?:=(.*))?$/); return m ? [m[1], m[2] === undefined ? true : m[2]] : [a, true]
}))
const IPA = path.resolve(String(args.ipa || ''))
const OUT = path.resolve(String(args.out || '.work/Info.plist'))
if (!IPA) { console.log('需要 --ipa='); process.exit(1) }

const entries = readZipEntries(readFileSync(IPA))
const appDir = (() => {
  if (args.app) return `Payload/${String(args.app).replace(/\.app$/, '')}.app`
  const e = entries.find(x => /^Payload\/[^/]+\.app\/Info\.plist$/.test(x.name))
  if (!e) { console.log('IPA 里找不到主 App 的 Info.plist'); process.exit(1) }
  return e.name.split('/').slice(0, 2).join('/')
})()
const entry = entries.find(x => x.name === `${appDir}/Info.plist`)
let text = readEntryData(entry).toString('utf8')
if (!text.startsWith('<?xml')) { console.log('Info.plist 不是 XML（是二进制 plist）⇒ 本工具不支持'); process.exit(1) }

const before = text
const sub = (key, value) => {
  const re = new RegExp(`(<key>${key}</key>\\s*<string>)([^<]*)(</string>)`)
  if (!re.test(text)) { console.log(`  ! 没找到 <key>${key}</key>`); return false }
  text = text.replace(re, `$1${value}$3`)
  return true
}
if (args['bundle-id']) { console.log(`CFBundleIdentifier → ${args['bundle-id']}  ${sub('CFBundleIdentifier', args['bundle-id']) ? 'ok' : 'fail'}`) }
if (args['url-name']) { console.log(`CFBundleURLName → ${args['url-name']}  ${sub('CFBundleURLName', args['url-name']) ? 'ok' : 'fail'}`) }
if (args['display-name']) { console.log(`CFBundleDisplayName → ${args['display-name']}  ${sub('CFBundleDisplayName', args['display-name']) ? 'ok' : 'fail'}`) }
if (text === before) console.log('  （内容未变）')

mkdirSync(path.dirname(OUT), { recursive: true })
writeFileSync(OUT, text)
// 回读自校验
const rb = readFileSync(OUT, 'utf8')
for (const [k, want] of [['CFBundleIdentifier', args['bundle-id']], ['CFBundleURLName', args['url-name']], ['CFBundleDisplayName', args['display-name']]]) {
  if (!want) continue
  const m = rb.match(new RegExp(`<key>${k}</key>\\s*<string>([^<]*)</string>`))
  console.log(`  回读 ${k} = ${m ? m[1] : '(缺失)'} ${m && m[1] === want ? '✅' : '❌'}`)
}
console.log(`写出 ${OUT}  ${Buffer.byteLength(rb)} B  （App 目录 ${appDir}）`)
