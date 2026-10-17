#!/usr/bin/env node
// inspect-ipa.mjs —— 输入 IPA 体检（打补丁前的「这包能不能用」门禁）。
//
// 为什么需要：patch-ipa.mjs 的站点补丁是**绝对文件偏移**，只有官方 1.8.4 解密 dump 的主二进制才对齐
// （基线 108,757,200 B）。拿被第三方改过的包当输入，站点补丁会静默 skip、URL 改写数也会是 0 —— 结果
// 是一个「看起来打了补丁、其实没打」的废包。本工具把这件事在动手前说清楚。
//
// 用法：node tools/inspect-ipa.mjs --ipa=<x.ipa> [--expect-bytes=108757200]

import { readFileSync, statSync } from 'node:fs'
import { inflateRawSync } from 'node:zlib'
import { readZipEntries, madeByHost, unixMode } from './vendor/lib/zip-ipa.mjs'

const args = Object.fromEntries(process.argv.slice(2).map(a => {
  const m = a.match(/^--([^=]+)(?:=(.*))?$/); return m ? [m[1], m[2] === undefined ? true : m[2]] : [a.replace(/^--/, ''), true]
}))
const IPA = args.ipa
if (!IPA) { console.log('用法：node tools/inspect-ipa.mjs --ipa=<x.ipa>'); process.exit(1) }
const EXPECT = args['expect-bytes'] ? Number(args['expect-bytes']) : 108757200

const buf = readFileSync(IPA)
const entries = readZipEntries(buf)
const app = entries.find(e => /^Payload\/[^/]+\.app\/Info\.plist$/.test(e.name)).name.split('/').slice(0, 2).join('/')
const exe = entries.find(e => e.name === `${app}/${app.split('/')[1].replace(/\.app$/, '')}`)
const data = exe.method === 8 ? inflateRawSync(exe.raw) : Buffer.from(exe.raw)

console.log(`IPA        ${IPA}  ${(statSync(IPA).size / 1048576).toFixed(1)} MB / ${entries.length} 条目`)
console.log(`App        ${app}`)
console.log(`主二进制   ${exe.name}  ${data.length} B  mode=${unixMode(exe).toString(8)} 宿主=${madeByHost(exe)}`)
console.log(`           基线期望 ${EXPECT} B  ⇒ ${data.length === EXPECT ? '✅ 一致' : '❌ 不一致（不是官方 1.8.4 dump）'}`)

// cryptid：LC_ENCRYPTION_INFO_64 (0x2C)。0 = 已解密（可改）
const magic = data.readUInt32LE(0)
const ncmds = data.readUInt32LE(16)
let off = 32, cryptid = null, minos = null
for (let i = 0; i < ncmds; i++) {
  const cmd = data.readUInt32LE(off), size = data.readUInt32LE(off + 4)
  // LC_ENCRYPTION_INFO_64 (0x2C): cmd, cmdsize, cryptoff, cryptsize, cryptid(!!), pad  ⇒ cryptid 在 +16
  if (cmd === 0x2C) cryptid = data.readUInt32LE(off + 16)
  // LC_BUILD_VERSION (0x32): cmd, cmdsize, platform, minos(X.Y.Z packed), sdk, ntools ⇒ minos 在 +12
  if (cmd === 0x32) { const v = data.readUInt32LE(off + 12); minos = `${v >>> 16}.${(v >>> 8) & 0xff}` }
  off += size
}
console.log(`Mach-O     magic=0x${magic.toString(16)} ncmds=${ncmds} cryptid=${cryptid} minOS=${minos}  ${cryptid === 0 ? '✅ 已解密' : '❌ 仍是加密包（改不动/装了也跑不了）'}`)

// 站点签名预检（与 pack-ipa.mjs 里的期望值一一对应）
const sites = [
  ['实名提示 shouldShowFirstLoginTip @0x6ae0dc', 0x6ae0dc, 0xa9bd57f6],
  ['登录弹窗分支 #1 @0x68e878', 0x68e878, 0xb4000820],
  ['登录弹窗分支 #2 @0x68e898', 0x68e898, 0xb40006a0],
  ['登录弹窗分支 #3 @0x68e8d8', 0x68e8d8, 0x35000538],
  ['欢迎横幅 showWelcomeView: @0x6adb14', 0x6adb14, 0xd10143ff],
  ['欢迎横幅 LTWelcomeView @0x64b238', 0x64b238, 0xd10703ff],
  ['欢迎横幅调用点 @0x634890', 0x634890, 0x9546daf4],
  ['EULA 门 @0x6c6cfc', 0x6c6cfc, 0x37000700],
  ['隐私门 needShowPrivacy @0x698990', 0x698990, 0xa9be4ff4],
  ['隐私门 GDPRManage @0x60f15c', 0x60f15c, 0xa9be4ff4],
  ['bundleId 校验 @0x312230', 0x312230, 0xa9bd6ffc],
  ['启动 guard @0xb00c', 0xb00c, 0xb9000109],
]
let ok = 0
for (const [label, o, want] of sites) {
  const got = data.readUInt32LE(o)
  const hit = got === want
  if (hit) ok++
  console.log(`  ${hit ? '✅' : '❌'} ${label}  期望 0x${want.toString(16)} 实得 0x${got.toString(16)}`)
}
console.log(`站点预检   ${ok}/${sites.length} 命中`)

// 端点站点统计（AIR 常量池等长改写的可改数量）
const HOST_RE = /https?:\/\/[A-Za-z0-9.-]+\.(?:leiting\.com|roguelike\.com|cl2009\.com)(?::\d+)?/g
const s = data.toString('latin1')
const auths = [...new Set(s.match(HOST_RE) || [])]
const tooShort = auths.filter(a => a.length < `http://127.0.0.1:8001`.length)
console.log(`端点站点   ${(s.match(HOST_RE) || []).length} 处 / ${auths.length} 个不同 authority；` +
            `其中 ${tooShort.length} 个短于 http://127.0.0.1:8001(18) 会被跳过：${tooShort.slice(0, 6).join(', ')}`)
const already = s.includes('127.0.0.1:8001') || /127\.0\.0\.1:\d+/.test(s)
console.log(`回环现状   ${already ? '⚠️ 包里已出现回环端点（可能是被别人改过的包）' : '✅ 未见回环端点（像原始包）'}`)
console.log('')
const verdict = data.length === EXPECT && cryptid === 0 && ok >= 10 && !already
console.log(verdict ? 'VERDICT ✅ 可作为输入' : 'VERDICT ❌ 不建议作为输入（见上面 ❌/⚠️）')
