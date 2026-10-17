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

try {
  require(entry)
  console.log('[spcn] 服务端模块已加载（监听由它自己完成）')
} catch (e) {
  console.error('[spcn] 服务端加载失败：', (e && e.stack) || e)
}
