// 进程内后端（NodeMobile.framework）的入口脚本 —— 由 dylib 以 argv[1] 传给 node_start。
//
// 与「独立进程后端」的差别只有一件事：**绝不能让服务端把游戏带走**。
// 独立进程里 process.exit(code) 是契约的一部分（10/11/12/13/14 各有含义，Supervisor 据此退避重启）；
// 但在进程内，process.exit 会直接杀掉世界弹射物语 ⇒ 这里把它拦下来，改成抛错 + 记日志。
// 用法：node_start(2, ["node", "<runtime>/ios-entry.js"])，cwd = runtime 根。
'use strict'

const path = require('path')

const root = process.env.SPCN_RUNTIME_ROOT || process.cwd()
const entry = path.join(root, 'server-bundle', 'out', 'cn-server.js')

console.log(`[spcn] 进程内后端 node ${process.version} abi=${process.versions.modules} pid=${process.pid}`)
console.log(`[spcn] runtime=${root}`)
console.log(`[spcn] entry=${entry}`)
console.log(`[spcn] DATA_DIR=${process.env.DATA_DIR || '(未设)'}`)

// ① 拦截退出：任何一个 exit 都不能杀游戏
const realExit = process.exit.bind(process)
process.exit = function spcnGuardedExit (code) {
  console.error(`[spcn] 服务端请求 process.exit(${code}) —— 进程内后端拦下，游戏继续跑`)
  const err = new Error(`spcn-guarded-exit-${code}`)
  err.spcnExitCode = code
  throw err
}
process.reallyExit = process.exit
if (typeof process.abort === 'function') {
  const realAbort = process.abort.bind(process)
  process.abort = function spcnGuardedAbort () {
    console.error('[spcn] 服务端请求 process.abort() —— 拦下（真实 abort 会 SIGABRT 掉整个游戏）')
    throw new Error('spcn-guarded-abort')
  }
  void realAbort
}

// ② 兜住未捕获异常：默认行为是打印 + 退出进程，同样会带走游戏
process.on('uncaughtException', (e) => {
  console.error('[spcn] uncaughtException（已忽略，游戏继续跑）：', (e && e.stack) || e)
})
process.on('unhandledRejection', (e) => {
  console.error('[spcn] unhandledRejection（已忽略）：', (e && e.stack) || e)
})

// ③ 没有 ICU 的 Node 会抛 ERR_NO_ICU：NodeMobile.framework（nodejs-mobile）是 --with-intl=none 编的，
//    而服务端 out/content/sync/ordered-map.js:6 正好用了 `new TextDecoder("utf-8", { fatal: true })`，
//    一个模块加载失败就整个服务端起不来。这里在 require 服务端之前把 fatal/ignoreBOM 降级掉。
//    （实测：App 包里那个独立 node 二进制有 ICU 不需要这层；framework 需要。）
;(function installNoIcuShim () {
  var util
  try { util = require('util') } catch (e) { return }
  const Real = (util && util.TextDecoder) || globalThis.TextDecoder
  if (typeof Real !== 'function') return
  try {
    new Real('utf-8', { fatal: true })
    return // 有 ICU，原样不动
  } catch (e) {
    if (!e || e.code !== 'ERR_NO_ICU') return
  }
  const Patched = function TextDecoder (label, options) {
    const o = options ? Object.assign({}, options) : undefined
    if (o) { delete o.fatal; delete o.ignoreBOM }
    return new Real(label, o)
  }
  Patched.prototype = Real.prototype
  try { util.TextDecoder = Patched } catch (e) { console.error('[spcn] util.TextDecoder 不可写：', e.message) }
  try { globalThis.TextDecoder = Patched } catch (e) { /* 只读就算了 */ }
  console.error('[spcn] 本 Node 没有 ICU ⇒ TextDecoder 的 fatal/ignoreBOM 已降级（非法 UTF-8 退化为 U+FFFD）')
})()

// ④ 沙盒里 realpath 会炸：iOS App 沙盒对 /private/var/mobile 这类祖先路径做 lstat 时返回 ENOENT，
//    于是 fs.realpathSync() 沿路径逐段解析时直接抛错。服务端 out/content/paths.js:71 的
//    resolvePhysicalPath() 正是这么用的 ⇒ content 阶段一上来就失败（真机 `[spcn-diag] stage=content
//    error=ENOENT lstat '/private/var/mobile'`，node_start 返回 rc=15 = 内容快照初始化失败）。
//    这里把 realpath 包一层：被沙盒拒绝就退化为字面绝对路径 —— 路径都是我们自己给的，
//    少一次符号链接解析只影响加固性检查，不影响功能。
;(function installSandboxSafeRealpath () {
  const fs = require('fs')
  const nodePath = require('path')
  const denied = (e) => !!e && (e.code === 'ENOENT' || e.code === 'ENOTDIR' || e.code === 'EPERM' || e.code === 'EACCES')
  const literalOf = (p) => (typeof p === 'string' ? nodePath.resolve(p) : String(p))
  const wrap = (real) => function spcnSafeRealpath (p, options) {
    try {
      return real.call(fs, p, options)
    } catch (e) {
      if (!denied(e)) throw e
      const literal = literalOf(p)
      console.error(`[spcn] realpath 被沙盒拒绝（${e.code}）⇒ 退化为字面路径：${literal}`)
      return literal
    }
  }
  try {
    const real = fs.realpathSync
    fs.realpathSync = wrap(real)
    if (typeof real.native === 'function') fs.realpathSync.native = wrap(real.native)
    console.error('[spcn] 已装上「沙盒安全 realpath」兜底')
  } catch (e) { console.error('[spcn] fs.realpathSync 不可写：', e.message) }
  try {
    if (fs.promises && typeof fs.promises.realpath === 'function') {
      const rp = fs.promises.realpath.bind(fs.promises)
      fs.promises.realpath = async (p, options) => {
        try { return await rp(p, options) } catch (e) { if (!denied(e)) throw e; return literalOf(p) }
      }
    }
  } catch (e) { /* 不可写就算了 */ }
})()

try {
  require(entry)
  console.log('[spcn] 服务端模块已加载（监听由它自己完成）')
} catch (e) {
  console.error('[spcn] 服务端加载失败：', (e && e.stack) || e)
}
