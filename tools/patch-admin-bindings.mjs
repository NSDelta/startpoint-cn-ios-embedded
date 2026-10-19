#!/usr/bin/env node
// patch-admin-bindings.mjs —— 把「账号绑定」从后台管理页彻底摘掉（单机版不需要它）。
//
// 后台 SPA 是上游打包好的 minified React 产物（web/dist/assets/index-*.js），没有源码可改，
// 于是做三处**纯字符串替换**（每处都要求恰好命中 1 次，形状是完整对象/属性，删掉不破坏语法）：
//   ① 侧边栏菜单项：{key:"/bindings",icon:P.jsx(zae,{size:18}),label:"账号绑定"},   → 删掉
//   ② 路由标题表："/bindings":"账号绑定",                                          → 删掉
//   ③ React 路由：P.jsx(Lo,{path:"/bindings",element:P.jsx(Kie,{})}),               → 改成重定向到首页
// 页面组件 Kie 本体保留（变成死代码，不打包进任何可达路由），接口侧另有 410 桩兜底。
//
// 用法：node tools/patch-admin-bindings.mjs [--runtime=runtime/SpCnRuntime] [--dry-run]
import { readdirSync, readFileSync, writeFileSync, copyFileSync, mkdirSync } from 'node:fs'
import path from 'node:path'

const ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1')), '..')
const args = Object.fromEntries(process.argv.slice(2).map(a => {
  const m = a.match(/^--([^=]+)(?:=(.*))?$/); return m ? [m[1], m[2] === undefined ? true : m[2]] : [a.replace(/^--/, ''), true]
}))
const RUNTIME = path.resolve(String(args.runtime || path.join(ROOT, 'runtime', 'SpCnRuntime')))
const ASSETS = path.join(RUNTIME, 'server-bundle', 'web', 'dist', 'assets')
const DRY = args['dry-run'] === true

const files = readdirSync(ASSETS).filter(f => /^index-.*\.js$/.test(f))
if (files.length !== 1) { console.log(`✗ 期望 assets 里恰好 1 个 index-*.js，实际 ${files.length}`); process.exit(1) }
const file = path.join(ASSETS, files[0])
let js = readFileSync(file, 'utf8')

const MENU = '{key:"/bindings",icon:P.jsx(zae,{size:18}),label:"账号绑定"},'
const TITLE = '"/bindings":"账号绑定",'
const ROUTE = 'P.jsx(Lo,{path:"/bindings",element:P.jsx(Kie,{})}),'
const ROUTE_NEW = 'P.jsx(Lo,{path:"/bindings",element:P.jsx(sz,{to:"/",replace:!0})}),'

const count = (s, sub) => s.split(sub).length - 1
const menuHits = count(js, MENU)
const titleHits = count(js, TITLE)
const routeHits = count(js, ROUTE)

console.log(`文件 ${file}  ${js.length} 字符`)
console.log(`  菜单项命中 ${menuHits} / 标题命中 ${titleHits} / 路由命中 ${routeHits}`)

if (menuHits === 0 && titleHits === 0 && routeHits === 0) { console.log('✓ 已经是摘掉的状态（幂等跳过）'); process.exit(0) }
if (menuHits !== 1 || titleHits !== 1 || routeHits !== 1) {
  console.log('✗ 三处必须各命中 1 次才动手（避免改到别的同名串）')
  process.exit(1)
}

js = js.replace(MENU, '').replace(TITLE, '').replace(ROUTE, ROUTE_NEW)
const left = count(js, '"/bindings"')
if (left !== 1) { console.log(`✗ 后置校验失败：剩余 "/bindings" 应为 1（那条重定向），实际 ${left}`); process.exit(1) }

if (DRY) { console.log('（--dry-run：不写盘）'); process.exit(0) }

const bakDir = path.join(ROOT, '.work', 'admin-bak')
mkdirSync(bakDir, { recursive: true })
copyFileSync(file, path.join(bakDir, files[0] + '.orig'))
writeFileSync(file, js)
console.log(`✓ 已改写：菜单项已删、标题表已删、/bindings 路由改为重定向到 "/"（备份在 .work/admin-bak/）`)
console.log(`  体积 ${js.length} 字符；剩余 "/bindings" ${count(js, '"/bindings"')} 处（重定向路由）`)
