#!/usr/bin/env node
// build-ipa.mjs —— 单机集成 IPA 总装线（Windows 侧一条命令出未签名 IPA）。
//
// 三个阶段，顺序是**硬约束**（每个阶段都有自校验，任一失败即停，不产出坏包）：
//
//   ① tools/pack-ipa.mjs           主二进制：AIR 常量池等长改写端点 → http://<pad>@127.0.0.1:8001
//                                  + 6 处站点补丁（实名提示 / 登录弹窗 / 欢迎横幅 / 协议门 / bundleId / guard NOP）
//                                  + sohu 外联阻断（死回环，保证零外部流量）
//   ② tools/vendor/inject-dylib.mjs 往主二进制插一条 LC_LOAD_DYLIB（@executable_path/Frameworks/SpCnEmbedded.dylib）
//                                  + 把 dylib 放进 .app/Frameworks/，16 项不变量断言（ncmds +1 / sizeofcmds +cmdsz /
//                                  所有 section 偏移不变 / 命令区余量 / dylib 回读 sha256 一致）
//                                  ⚠️ 必须最后动主二进制 ⇒ 只能是第 ② 步
//                                  ⚠️ 越狱线（deb 负责装 dylib）要加 --no-dylib，否则同一个进程里会有两份同名类
//                                      dylib（两套悬浮球 + 两个 node 抢 8001）
//   ③ tools/embed-runtime.mjs       把 SpCnRuntime 塞进 .app/SpCnRuntime/**（node 条目带 0755 = 能不能 exec 的关键）、
//                                  NodeMobile.framework 放进 .app/Frameworks/**（侧载重签只递归签嵌套代码），
//                                  并逐条校验未改动条目字节不变 + node/framework 解压后 sha256 一致
//
// 产物：未签名 IPA（必须由侧载工具重签：Sideloadly / AltStore / zsign；越狱机用 TrollStore 或 AppSync）。
//
// 用法：
//   node tools/build-ipa.mjs --ipa=D:\...\iOS-1.8.4.ipa --out=dist\spcn-ios-standalone.ipa
//   [--dylib=dist\SpCnEmbedded-rootless.dylib] [--runtime=runtime\SpCnRuntime]
//   [--work=.work\ipa] [--host=127.0.0.1] [--port=8001] [--force] [--keep-work]
//   [--no-runtime] [--no-dylib] [--install-name=@executable_path/Frameworks/SpCnEmbedded.dylib]

import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync, statSync } from 'node:fs'
import { spawnSync } from 'node:child_process'
import path from 'node:path'
import crypto from 'node:crypto'

const ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1')), '..')
const args = Object.fromEntries(process.argv.slice(2).map(a => {
  const m = a.match(/^--([^=]+)(?:=(.*))?$/); return m ? [m[1], m[2] === undefined ? true : m[2]] : [a.replace(/^--/, ''), true]
}))
const say = (s) => console.log(s)
const die = (s) => { console.log('ERROR ' + s); process.exit(1) }
const mb = (n) => (n / 1048576).toFixed(1) + ' MB'
const sha = (p) => crypto.createHash('sha256').update(readFileSync(p)).digest('hex')
const opt = (k, d) => (args[k] === undefined ? d : String(args[k]))

const IPA = args.ipa ? path.resolve(String(args.ipa)) : ''
const OUT = path.resolve(opt('out', path.join(ROOT, 'dist', 'spcn-ios-standalone.ipa')))
const RUNTIME = path.resolve(opt('runtime', path.join(ROOT, 'runtime', 'SpCnRuntime')))
const DYLIB = path.resolve(opt('dylib', path.join(ROOT, 'dist', 'SpCnEmbedded-rootless.dylib')))
const WORK = path.resolve(opt('work', path.join(ROOT, '.work', 'ipa')))
const HOST = opt('host', '127.0.0.1'), PORT = opt('port', '8001')
const INSTALL_NAME = opt('install-name', '@executable_path/Frameworks/SpCnEmbedded.dylib')
const WITH_RUNTIME = args['no-runtime'] !== true
const WITH_DYLIB = args['no-dylib'] !== true      // 越狱线：deb 装 dylib ⇒ 这里只做端点补丁（--no-dylib）
const BUNDLE_ID = opt('bundle-id', '')            // 例如 com.testdj.wf ⇒ 与原版共存（第二份安装）
const DISPLAY_NAME = opt('display-name', '')

if (!IPA) die('需要 --ipa=<官方/解密 IPA 路径>')
if (!existsSync(IPA)) die('找不到输入 IPA：' + IPA)
if (WITH_DYLIB && !existsSync(DYLIB)) die('找不到 dylib：' + DYLIB + '（只想出纯补丁 IPA 就加 --no-dylib）')
if (WITH_RUNTIME && !existsSync(path.join(RUNTIME, 'spcn-runtime.json'))) die('运行时没组装好（缺 spcn-runtime.json）：' + RUNTIME + ' —— 先跑 tools/assemble-runtime.mjs')
if (existsSync(OUT) && !args.force) die('产物已存在（加 --force 覆盖）：' + OUT)

mkdirSync(path.dirname(OUT), { recursive: true })
mkdirSync(WORK, { recursive: true })
const t0 = Date.now()
say('══ 单机 IPA 总装 ══')
say(`  输入 IPA   ${IPA}  ${mb(statSync(IPA).size)}`)
say(`  运行时     ${WITH_RUNTIME ? RUNTIME : '(跳过：--no-runtime)'}`)
say(`  dylib      ${WITH_DYLIB ? `${DYLIB}  ${mb(statSync(DYLIB).size)}` : '(跳过：--no-dylib ⇒ 纯补丁 IPA，dylib 由 deb 提供)'}`)
say(`  端点       http://${HOST}:${PORT}   install-name ${INSTALL_NAME}`)
say(`  bundle id  ${BUNDLE_ID || '(不改，保持原版 com.leiting.wf)'}${DISPLAY_NAME ? '   显示名 ' + DISPLAY_NAME : ''}`)
say(`  工作目录   ${WORK}`)

function run(label, argv) {
  say('')
  say(`── ${label} ──`)
  const r = spawnSync(process.execPath, argv, { stdio: 'inherit', cwd: ROOT })
  if (r.status !== 0) die(`${label} 失败（exit ${r.status}）`)
}

const s1 = path.join(WORK, '1-patched.ipa')
const s2 = path.join(WORK, '2-injected.ipa')

run('① 主二进制补丁（端点 + 站点 + guard）', [
  path.join(ROOT, 'tools', 'pack-ipa.mjs'),
  `--ipa=${IPA}`, `--out=${s1}`, `--host=${HOST}`, `--port=${PORT}`,
])

let cur = s1
if (BUNDLE_ID || DISPLAY_NAME) {
  const s1b = path.join(WORK, '1b-plist.ipa')
  run(`①.5 改 Info.plist（${BUNDLE_ID || DISPLAY_NAME}）`, [
    path.join(ROOT, 'tools', 'patch-info-plist.mjs'),
    `--ipa=${s1}`, `--out=${s1b}`,
    ...(BUNDLE_ID ? [`--bundle-id=${BUNDLE_ID}`] : []),
    ...(DISPLAY_NAME ? [`--display-name=${DISPLAY_NAME}`] : []),
  ])
  cur = s1b
}
if (WITH_DYLIB) {
  run('② 注入 dylib（LC_LOAD_DYLIB + Frameworks/）', [
    path.join(ROOT, 'tools', 'vendor', 'inject-dylib.mjs'),
    `--ipa=${cur}`, `--dylib=${DYLIB}`, `--out=${s2}`, `--install-name=${INSTALL_NAME}`,
    `--report=${path.join(WORK, 'inject-report.json')}`,
  ])
  cur = s2
}

if (WITH_RUNTIME) {
  run('③ 塞入运行时（.app/SpCnRuntime + Frameworks/NodeMobile.framework）', [
    path.join(ROOT, 'tools', 'embed-runtime.mjs'),
    `--ipa=${cur}`, `--runtime=${RUNTIME}`, `--out=${OUT}`,
  ])
} else {
  writeFileSync(OUT, readFileSync(cur))
}

// ── 终检 ──
say('')
say('── 终检 ──')
const { readZipEntries, madeByHost, readEntryData } = await import('./vendor/lib/zip-ipa.mjs')
const entries = readZipEntries(readFileSync(OUT))
const app = entries.find(e => /^Payload\/[^/]+\.app\/Info\.plist$/.test(e.name)).name.split('/').slice(0, 2).join('/')
const exe = entries.find(e => e.name === `${app}/${path.posix.basename(app).replace(/\.app$/, '')}`)
const dylibEntry = entries.find(e => e.name.endsWith('Frameworks/SpCnEmbedded.dylib'))
const nodeEntry = entries.find(e => e.name === `${app}/SpCnRuntime/node-ios-arm64/node`)
const fwEntry = entries.find(e => e.name === `${app}/Frameworks/NodeMobile.framework/NodeMobile`)
const bad = []
if (!exe) bad.push('主二进制条目不在')
if (WITH_DYLIB && !dylibEntry) bad.push('Frameworks/SpCnEmbedded.dylib 不在')
if (WITH_RUNTIME && !nodeEntry) bad.push('SpCnRuntime/node 不在')
if (nodeEntry && ((nodeEntry.externalAttr >>> 16) & 0xffff) !== 0o100755) bad.push('node 没有 0755')
if (dylibEntry && ((dylibEntry.externalAttr >>> 16) & 0xffff) !== 0o100755) bad.push('dylib 没有 0755')
if (exe && ((exe.externalAttr >>> 16) & 0xffff) !== 0o100755) bad.push('主二进制丢了可执行位（装不上！）')
if (BUNDLE_ID) {
  const pe = entries.find(e => e.name === `${app}/Info.plist`)
  const xml = pe ? readEntryData(pe).toString('utf8') : ''
  if (!xml.includes(`<key>CFBundleIdentifier</key>`)) bad.push('产物里没有 CFBundleIdentifier')
  else if (!new RegExp(`<key>CFBundleIdentifier</key>\\s*<string>${BUNDLE_ID.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}</string>`).test(xml)) bad.push('bundle id 没改成 ' + BUNDLE_ID)
}
if (bad.length) { for (const b of bad) say('  ✗ ' + b); die('终检失败') }

const report = {
  tool: 'tools/build-ipa.mjs', generatedAt: new Date().toISOString(),
  input: { ipa: IPA, bytes: statSync(IPA).size, sha256: sha(IPA) },
  output: { ipa: OUT, bytes: statSync(OUT).size, sha256: sha(OUT), entries: entries.length },
  endpoint: { host: HOST, port: PORT }, installName: INSTALL_NAME,
  bundleId: BUNDLE_ID || null, displayName: DISPLAY_NAME || null,
  dylib: WITH_DYLIB ? { path: DYLIB, bytes: statSync(DYLIB).size } : null,
  runtime: WITH_RUNTIME ? { dir: RUNTIME, entries: entries.filter(e => e.name.startsWith(`${app}/SpCnRuntime/`)).length } : null,
  framework: fwEntry ? { name: fwEntry.name, bytes: fwEntry.usize } : null,
  app, executable: exe.name,
  modes: { executable: (exe.externalAttr >>> 16).toString(8),
           dylib: dylibEntry ? (dylibEntry.externalAttr >>> 16).toString(8) : null,
           node: nodeEntry ? (nodeEntry.externalAttr >>> 16).toString(8) : null },
  hostKinds: { exe: madeByHost(exe), dylib: dylibEntry ? madeByHost(dylibEntry) : null },
  seconds: Number(((Date.now() - t0) / 1000).toFixed(1)),
}
const reportPath = OUT.replace(/\.ipa$/i, '') + '.report.json'
writeFileSync(reportPath, JSON.stringify(report, null, 2) + '\n')

say(`  ✓ ${exe.name} mode=${report.modes.executable}` +
    (dylibEntry ? ` / ${dylibEntry.name} mode=${report.modes.dylib}` : ' / (无 dylib：--no-dylib)') +
    (nodeEntry ? ` / node mode=${report.modes.node}` : ''))
say(`  ✓ 条目 ${entries.length}，产物 ${mb(statSync(OUT).size)}`)
say(`  ✓ sha256 ${report.output.sha256}`)
say('')
say(`OK  ${OUT}   (${report.seconds}s)`)
say(`    报告 ${reportPath}`)
say(WITH_DYLIB
  ? '    安装：Sideloadly/AltStore 侧载（会重签整包，含 node 与 dylib）；越狱机可 TrollStore 直装。'
  : '    安装：纯补丁 IPA（不含 dylib/运行时）⇒ 配越狱 deb（SpCnEmbedded-full-*.deb）一起用，游戏侧载即可。')
if (!args['keep-work']) { try { rmSync(WORK, { recursive: true, force: true }) } catch { } }
