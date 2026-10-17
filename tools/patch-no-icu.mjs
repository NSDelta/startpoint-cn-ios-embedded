#!/usr/bin/env node
// patch-no-icu.mjs —— 给运行时里的服务端产物打「无 ICU」补丁。
//
// 背景：进程内后端用的 NodeMobile.framework（nodejs-mobile）是 --with-intl=none 编的，
// `new TextDecoder("utf-8", { fatal: true })` 会抛 ERR_NO_ICU，一个模块加载失败就整个服务端起不来
// （真机首跑就是死在 out/content/sync/ordered-map.js:6）。
// 独立 node 二进制有 ICU，走 try 分支行为不变。
//
// 幂等：已经打过（文件里出现 _spcnNoIcu 标记）就跳过。每次重新组装运行时后跑一遍即可。
//
// 用法：node tools/patch-no-icu.mjs [--runtime=runtime/SpCnRuntime] [--dry-run]

import { readdirSync, readFileSync, statSync, writeFileSync, existsSync } from 'node:fs'
import path from 'node:path'

const ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1')), '..')
const args = Object.fromEntries(process.argv.slice(2).map(a => {
  const m = a.match(/^--([^=]+)(?:=(.*))?$/); return m ? [m[1], m[2] === undefined ? true : m[2]] : [a.replace(/^--/, ''), true]
}))
const RUNTIME = path.resolve(String(args.runtime || path.join(ROOT, 'runtime', 'SpCnRuntime')))
const DRY = args['dry-run'] === true

const RE = /new\s+([A-Za-z_$][\w$]*)\.TextDecoder\(\s*(["'])utf-8\2\s*,\s*\{\s*fatal\s*:\s*true\s*\}\s*\)/g

function walk (dir, out = []) {
  for (const e of readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name)
    if (e.isDirectory()) { if (e.name !== 'node_modules') walk(p, out) }
    else if (e.name.endsWith('.js')) out.push(p)
  }
  return out
}

const bundle = path.join(RUNTIME, 'server-bundle')
if (!existsSync(bundle)) { console.log('ERROR 找不到 ' + bundle); process.exit(1) }

let files = 0, sites = 0, skipped = 0
for (const f of walk(bundle)) {
  const src = readFileSync(f, 'utf8')
  if (!RE.test(src)) continue
  RE.lastIndex = 0
  if (src.includes('_spcnNoIcu')) { skipped++; continue }
  const dst = src.replace(RE, (m, ns, q) =>
    `(() => { try { return new ${ns}.TextDecoder(${q}utf-8${q}, { fatal: true }); } catch (_spcnNoIcu) { return new ${ns}.TextDecoder(${q}utf-8${q}); } })()`)
  const n = (src.match(RE) || []).length
  files++; sites += n
  if (!DRY) writeFileSync(f, dst)
  console.log(`  ${DRY ? '(dry-run) ' : ''}${path.relative(ROOT, f)}  站点 ${n}  ${statSync(f).size} B`)
}
console.log(`\n${DRY ? 'DRY ' : 'OK '}文件 ${files}、站点 ${sites}、已打过跳过 ${skipped}`)
