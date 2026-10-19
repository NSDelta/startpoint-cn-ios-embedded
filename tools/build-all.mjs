#!/usr/bin/env node
// build-all.mjs —— 一键重建全部交付物（Windows 侧驱动，WSL 出 theos 那部分）。
//
// 为什么要有它：交付物之间有硬依赖，顺序错了就会拿到「dylib 是新版、deb 里是旧版」这种半新半旧的包：
//   ① assemble-runtime  运行时清单（node 版本/ABI/原生模块/framework 校验 → spcn-runtime.json）
//   ② build-wsl package tweak → dist/SpCnEmbedded-{rootless,rootful}.{deb,dylib}
//   ③ build-wsl runtime 运行时打包 → dist/SpCnRuntime.tar.gz（tar 里 node 带可执行位）
//   ④ build-runtime-deb 一键 deb（dylib + plist + 运行时）—— 必须在 ②③ 之后
//   ⑤ build-ipa 一体 IPA（补丁 + 注入 dylib + 塞运行时 + framework）—— 必须用 ② 的新 dylib
//   ⑥ build-ipa --no-dylib --no-runtime 纯补丁 IPA（越狱线配 ④ 用）
//   ⑦ 汇总 sha256 → dist/BUILDS.json + 打印表
//
// 用法：
//   node tools/build-all.mjs [--ipa=<官方 iOS-1.8.4.ipa>] [--distro=Ubuntu-24.04]
//                            [--skip-runtime] [--skip-ipa] [--keep-work]
import { existsSync, readdirSync, readFileSync, statSync, writeFileSync } from 'node:fs'
import { spawnSync } from 'node:child_process'
import path from 'node:path'
import crypto from 'node:crypto'

const ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1')), '..')
const args = Object.fromEntries(process.argv.slice(2).map(a => {
  const m = a.match(/^--([^=]+)(?:=(.*))?$/); return m ? [m[1], m[2] === undefined ? true : m[2]] : [a.replace(/^--/, ''), true]
}))
const DISTRO = String(args.distro || 'Ubuntu-24.04')
const BASE_IPA = path.resolve(String(args.ipa || 'C:/Users/relea/Downloads/iOS-1.8.4.ipa'))
const DIST = path.join(ROOT, 'dist')
const say = (s) => console.log(s)
const mb = (n) => (n / 1048576).toFixed(1) + ' MB'
const sha = (p) => crypto.createHash('sha256').update(readFileSync(p)).digest('hex')

function step (n, title, cmd, cmdArgs, opts = {}) {
  say('')
  say(`════ ${n} ${title} ════`)
  const t = Date.now()
  const r = spawnSync(cmd, cmdArgs, { stdio: 'inherit', cwd: ROOT })
  if (r.status !== 0) { say(`✗ ${title} 失败（exit ${r.status}）`); process.exit(r.status || 1) }
  say(`✓ ${title}  ${((Date.now() - t) / 1000).toFixed(1)}s`)
}
const WSL = (script, ...extra) => ['-d', DISTRO, '-u', 'ubuntu', '--', 'bash', `/mnt/d/spcntweak/tools/${script}`, ...extra]

if (!existsSync(BASE_IPA)) { say(`✗ 找不到官方基线 IPA：${BASE_IPA}（用 --ipa= 指定）`); process.exit(1) }

// ⓪ 运行时补丁（三个脚本都是幂等的、都带标记串，可以反复跑）。
//    必须在 ①assemble-runtime 之前跑：它读的就是 runtime/SpCnRuntime/server-bundle 这份树。
const RUNTIME_DIR = path.join(ROOT, 'runtime', 'SpCnRuntime')
for (const [title, script] of [
  ['去 ICU（TextDecoder fatal 站点）', 'patch-no-icu.mjs'],
  ['放宽资源版本白名单 1.4.54–1.57', 'patch-asset-version.mjs'],
  ['移除账号绑定（后台 410 + 公告中性化 + 闸门恒关）', 'patch-single-player.mjs'],
]) {
  step('⓪', title, process.execPath, [path.join(ROOT, 'tools', script), `--runtime=${RUNTIME_DIR}`])
}

step('①', '组装运行时（校验 node/ABI/原生模块/framework）', process.execPath, [
  path.join(ROOT, 'tools', 'assemble-runtime.mjs'),
  `--node=${path.join(ROOT, 'runtime', 'node-ios-arm64', 'node')}`,
  `--bundle=${path.join(ROOT, 'runtime', 'SpCnRuntime', 'server-bundle')}`,
  `--modules=${path.join(ROOT, 'runtime', 'SpCnRuntime', 'node_modules')}`,
  `--out=${path.join(ROOT, 'runtime', 'SpCnRuntime')}`,
])

step('②', 'theos 构建 tweak（rootless + rootful deb/dylib）', 'wsl', WSL('build-wsl.sh', 'package'))

if (!args['no-runtime']) {
  step('③', '运行时打包（SpCnRuntime.tar.gz）', 'wsl', WSL('build-wsl.sh', 'runtime'))
  step('④', '一键 deb（dylib + plist + 完整运行时）', 'wsl', WSL('build-runtime-deb.sh', 'both'))
}

const IPA_ARGS = [
  path.join(ROOT, 'tools', 'build-ipa.mjs'),
  `--ipa=${BASE_IPA}`, '--force',
]
if (!args['keep-work']) IPA_ARGS.push('--keep-work')   // 保留 work 便于排查；产物不受影响

step('⑤', '一体 IPA（补丁 + 注入 dylib + 运行时 + framework）', process.execPath,
  IPA_ARGS.concat([`--out=${path.join(DIST, 'spcn-ios-standalone.ipa')}`]))

step('⑥', '纯补丁 IPA（越狱线配 deb 用）', process.execPath,
  IPA_ARGS.concat(['--no-dylib', '--no-runtime', `--out=${path.join(DIST, 'spcn-ios-patched-only.ipa')}`]))

// ── ⑦ 汇总 ──
say('')
say('════ ⑦ 汇总 ════')
const files = readdirSync(DIST).filter(f => statSync(path.join(DIST, f)).isFile()).sort()
const rows = files.map(f => ({ file: f, bytes: statSync(path.join(DIST, f)).size, sha256: sha(path.join(DIST, f)),
                               mtime: statSync(path.join(DIST, f)).mtime.toISOString() }))
writeFileSync(path.join(DIST, 'BUILDS.json'), JSON.stringify({ generatedAt: new Date().toISOString(), baseIpa: BASE_IPA, files: rows }, null, 2) + '\n')
for (const r of rows) say(`  ${String(r.bytes).padStart(12)}  ${r.sha256.slice(0, 16)}  ${r.file}   ${mb(r.bytes)}`)
say('')
say(`OK  dist/BUILDS.json 已更新（${rows.length} 个文件）`)
say('    手机取包： node tools/serve-dist.mjs --port=8088  →  http://192.168.0.105:8088/')
