#!/usr/bin/env node
// patch-sandbox-realpath.mjs —— 把服务端 content 路径解析里的 realpathSync 包成「沙盒失败就退化为字面路径」。
//
// 为什么必须在服务端 bundle 里补这一刀（而不是只在 ios-entry.js 里包 fs）：
//   真机日志（[spcn-diag] 打出来的真实异常）：
//     Error: ENOENT: no such file or directory, lstat '/private/var/mobile'
//       at realpathSync (out/content/paths.js:25)
//       at resolvePhysicalPath (out/content/paths.js:71)
//       at assertIsolatedContentPaths (out/content/paths.js:128)
//   机制：iOS 的路径遮蔽把 /var/mobile 重定向进容器，而 realpath() 会把 /var 解析成 /private/var，
//   绕出遮蔽落到受限路径上 ⇒ lstat('/private/var/mobile') ENOENT ⇒ content 阶段直接抛错（契约 exit code 15）。
//   ios-entry.js 里包 fs.realpathSync 能挡住，但**只有当入口真的是 ios-entry.js 时才生效**；一旦入口退化成
//   server-bundle/out/cn-server.js（例如包内文件被后推覆盖、判读失败），服务端就又会带着 rc=15 死掉。
//   所以把兜底放进 bundle 自己：任何入口都逃不掉。
//
// 改写点（唯一一处）：`return pathApi.resolve(fsApi.realpathSync(existingAncestor), ...missingSegments);`
//   改成先 try 取 realpath、失败退化为 pathApi.resolve(existingAncestor)。语义不变（路径都是我们自己给的，
//   少一次软链解析只影响加固性检查），只在沙盒拒绝时才走兜底。
//
// 用法：node tools/patch-sandbox-realpath.mjs [--runtime=runtime\SpCnRuntime] [--dry-run]
import { readFileSync, writeFileSync, existsSync, readdirSync, statSync } from 'node:fs'
import path from 'node:path'

const args = Object.fromEntries(process.argv.slice(2).map(a => {
  const m = a.match(/^--([^=]+)(?:=(.*))?$/); return m ? [m[1], m[2] === undefined ? true : m[2]] : [a, true]
}))
const ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1')), '..')
const RUNTIME = path.resolve(String(args.runtime || path.join(ROOT, 'runtime', 'SpCnRuntime')))
const DRY = args['dry-run'] === true

const MARK = '_spcnReal'
const OLD = 'return pathApi.resolve(fsApi.realpathSync(existingAncestor), ...missingSegments);'
const NEW = [
  `let ${MARK} = existingAncestor;`,
  `    try { ${MARK} = fsApi.realpathSync(existingAncestor); }`,
  `    catch (_spcnRealErr) { ${MARK} = pathApi.resolve(existingAncestor); }   // 沙盒拒绝 realpath（/private/var/mobile）就退化为字面路径`,
  `    return pathApi.resolve(${MARK}, ...missingSegments);`,
].join('\n    ')

function walk (dir, out = []) {
  for (const name of readdirSync(dir)) {
    const p = path.join(dir, name)
    const st = statSync(p)
    if (st.isDirectory()) walk(p, out)
    else if (name.endsWith('.js')) out.push(p)
  }
  return out
}

const target = path.join(RUNTIME, 'server-bundle')
if (!existsSync(target)) { console.log('ERROR 找不到 ' + target); process.exit(1) }
const files = walk(target)
let changed = 0, already = 0, missing = 0
for (const f of files) {
  const src = readFileSync(f, 'utf8')
  if (src.includes(MARK)) { already++; continue }
  if (!src.includes(OLD)) { if (src.includes('realpathSync(existingAncestor)')) missing++; continue }
  const out = src.replace(OLD, NEW)
  if (out === src) { missing++; continue }
  if (!DRY) writeFileSync(f, out)
  changed++
  console.log(`  ${DRY ? '(dry-run) ' : ''}已改 ${path.relative(ROOT, f)}`)
}
console.log(`扫描 ${files.length} 个 .js：改 ${changed}，已是补丁版 ${already}，未命中 ${missing}${DRY ? '（dry-run，未写盘）' : ''}`)
if (changed === 0 && already === 0) { console.log('ERROR 一个都没改到（服务端 bundle 与预期不符）'); process.exit(1) }
