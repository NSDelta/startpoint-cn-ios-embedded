#!/usr/bin/env node
// patch-info-plist.mjs —— 改 Payload/<App>.app/Info.plist 里的 CFBundleIdentifier（可选 CFBundleDisplayName）。
//
// 为什么需要：**和原版共存**要做第二份安装。原版 bundle id = com.leiting.wf；换一个新 id（例如
// com.testdj.wf）后 iOS 就当成另一个 App 装（图标/容器/存档全独立）。客户端里对 bundle id 的校验
// 由 pack-ipa.mjs 的 patchBundleIdCheck（0x312230 → return 0）打桩掉，所以换 id 不会被拦。
//
// ⚠️ 换了 bundle id ⇒ 数据容器是全新的 ⇒ 那 9.8 GB 资源（Library/Application Support/<id>/Local Store）
//    不会自动跟着过来：要么用面板的「资源」导入，要么从旧容器整目录拷（见 docs/INSTALL-*.md）。
//
// 用法：
//   node tools/patch-info-plist.mjs --ipa=in.ipa --out=out.ipa --bundle-id=com.testdj.wf [--display-name=名字] [--app=<App 名>]

import { readFileSync, writeFileSync, statSync } from 'node:fs'
import path from 'node:path'
import crypto from 'node:crypto'
import { readZipEntries, writeZipEntries, replaceEntryData, readEntryData } from './vendor/lib/zip-ipa.mjs'

const args = Object.fromEntries(process.argv.slice(2).map(a => {
  const m = a.match(/^--([^=]+)(?:=(.*))?$/); return m ? [m[1], m[2] === undefined ? true : m[2]] : [a.replace(/^--/, ''), true]
}))
const say = (s) => console.log(s)
const die = (s) => { console.log('ERROR ' + s); process.exit(1) }
const sha = (b) => crypto.createHash('sha256').update(b).digest('hex')
const mb = (n) => (n / 1048576).toFixed(1) + ' MB'
const opt = (k, d) => (args[k] === undefined ? d : String(args[k]))

const IPA = args.ipa ? path.resolve(String(args.ipa)) : ''
const OUT = path.resolve(opt('out', IPA.replace(/\.ipa$/i, '') + '.plist.ipa'))
const BUNDLE_ID = opt('bundle-id', '')
const DISPLAY_NAME = opt('display-name', '')
const APP_ARG = opt('app', '')

if (!IPA) die('需要 --ipa=<输入 IPA>')
if (!BUNDLE_ID && !DISPLAY_NAME) die('至少要给一个 --bundle-id 或 --display-name')

const buf = readFileSync(IPA)
const entries = readZipEntries(buf)
const plistEntry0 = entries.find(e => /^Payload\/[^/]+\.app\/Info\.plist$/.test(e.name))
if (!plistEntry0 && !APP_ARG) die('IPA 里找不到 Payload/<App>.app/Info.plist')
const appDir = APP_ARG ? `Payload/${APP_ARG}` : plistEntry0.name.split('/').slice(0, 2).join('/')
const rel = `${appDir}/Info.plist`
const entry = entries.find(e => e.name === rel)
if (!entry) die('IPA 里没有 ' + rel)

const before = readEntryData(entry).toString('utf8')
if (!before.replace(/^\uFEFF/, '').trimStart().startsWith('<?xml')) {
  die('这个 Info.plist 不是 XML（可能是二进制 plist），本工具不支持：' + rel)
}
const current = (xml, key) => {
  const m = xml.match(new RegExp(`<key>${key}</key>\\s*<string>([^<]*)</string>`))
  return m ? m[1] : null
}
const setValue = (xml, key, value) => {
  const re = new RegExp(`(<key>${key}</key>\\s*<string>)([^<]*)(</string>)`)
  if (!re.test(xml)) return null
  return xml.replace(re, (_m, a, _old, c) => a + value + c)
}

say(`══ 改 Info.plist ══`)
say(`  输入   ${IPA}  ${mb(statSync(IPA).size)}`)
say(`  条目   ${rel}`)

let after = before
const changes = []
if (BUNDLE_ID) {
  const old = current(after, 'CFBundleIdentifier')
  if (!old) die('Info.plist 里没有 CFBundleIdentifier')
  const r = setValue(after, 'CFBundleIdentifier', BUNDLE_ID)
  after = r
  changes.push(`CFBundleIdentifier: ${old} → ${BUNDLE_ID}`)
}
if (DISPLAY_NAME) {
  const old = current(after, 'CFBundleDisplayName')
  const r = setValue(after, 'CFBundleDisplayName', DISPLAY_NAME)
  if (r) { after = r; changes.push(`CFBundleDisplayName: ${old} → ${DISPLAY_NAME}`) }
  else say(`  ⚠️ 没有 CFBundleDisplayName 键 ⇒ 跳过改名（主屏名字由 CFBundleName=${current(after, 'CFBundleName')} 决定）`)
}
if (after === before) die('没有发生任何改动')
for (const c of changes) say('  · ' + c)

// 未改动条目必须逐字节不变 ⇒ 先记下原始 CRC，写完再逐条比对
const origCrc = new Map(entries.map(e => [e.name, e.crc]))
const newData = Buffer.from(after, 'utf8')
const res = replaceEntryData(entries, rel, newData)
const outBuf = writeZipEntries(entries)
writeFileSync(OUT, outBuf)

// ── 自校验 ──
const v = readZipEntries(readFileSync(OUT))
if (v.length !== entries.length) die(`自校验失败：条目数变了 ${entries.length} → ${v.length}`)
const mismatched = v.filter(e => e.name !== rel && origCrc.get(e.name) !== e.crc).map(e => e.name)
if (mismatched.length) die(`自校验失败：有 ${mismatched.length} 个未改动条目 CRC 变了，例如 ${mismatched.slice(0, 3).join(', ')}`)
const vxml = readEntryData(v.find(e => e.name === rel)).toString('utf8')
if (BUNDLE_ID && current(vxml, 'CFBundleIdentifier') !== BUNDLE_ID) die('自校验失败：产物里的 bundle id 不是 ' + BUNDLE_ID)
if (DISPLAY_NAME && current(vxml, 'CFBundleDisplayName') === DISPLAY_NAME && current(vxml, 'CFBundleDisplayName') !== current(before, 'CFBundleDisplayName')) { /* ok */ }

say(`  ✓ ${rel}  ${entry.usize} → ${newData.length} B（压缩 ${res.compressedBytes} B，method ${res.method}）`)
say(`  ✓ ${v.length} 个条目：未改动的 ${v.length - 1} 个 CRC 全一致`)
say(`  ✓ 产物 ${mb(statSync(OUT).size)}  sha256 ${sha(outBuf)}`)
say('OK  ' + OUT)
