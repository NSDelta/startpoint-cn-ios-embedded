#!/usr/bin/env node
// patch-single-player.mjs —— 把「公共服才有」的账号绑定相关物从服务端 bundle 里摘掉（按上游
// DontBeAlarmed/startpoint-cn：上游没有账号绑定这套东西）。
//
// 摘的是什么（都是我们这套 fork/launcher bundle 额外加的）：
//   1. iOS 公告弹窗里的「服务器绑定验证码」—— 单机版根本不需要绑定，弹这个只会让人困惑；
//   2. 绑定闸门（BIND_GATE）—— 即使环境里误设 BIND_GATE_ENABLED=1 也强制恒开（放行）；
//   3. 后台绑定 API（/api/bindings 那 7 条路由）—— 全部下线，返回 410。
// 保留不动：游戏本体 API、/sp-auth 登录（客户端不依赖它，但删了会牵连 admin 账号逻辑）。
//
// 幂等：文件里出现 SP_SINGLE_PLAYER_PATCH 标记就跳过该文件。
// 用法：node tools/patch-single-player.mjs [--runtime=runtime/SpCnRuntime] [--dry-run]

import { existsSync, readFileSync, writeFileSync, statSync } from 'node:fs'
import path from 'node:path'

const args = Object.fromEntries(process.argv.slice(2).map(a => {
  const m = a.match(/^--([^=]+)(?:=(.*))?$/); return m ? [m[1], m[2] === undefined ? true : m[2]] : [a.replace(/^--/, ''), true]
}))
const ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1')), '..')
const RUNTIME = path.resolve(args.runtime ? String(args.runtime) : path.join(ROOT, 'runtime', 'SpCnRuntime'))
const BUNDLE = path.join(RUNTIME, 'server-bundle')
const DRY = args['dry-run'] === true
const MARK = 'SP_SINGLE_PLAYER_PATCH'

const st = (p) => { try { return statSync(p) } catch { return null } }
const say = (s) => console.log(s)
const die = (s) => { console.error('ERROR ' + s); process.exit(1) }

if (!existsSync(path.join(BUNDLE, 'server-manifest.json'))) die('找不到 server-bundle：' + BUNDLE)

let changed = 0, skipped = 0
function patchFile(rel, edits) {
  const file = path.join(BUNDLE, rel)
  if (!st(file)) die('缺文件：' + file)
  const before = readFileSync(file, 'utf8')
  if (before.includes(MARK)) { say(`  = ${rel}（已打过补丁）`); skipped++; return }
  let text = before
  const report = []
  for (const e of edits) {
    if (typeof e.find === 'string') {
      if (!text.includes(e.find)) { report.push(`✗ 找不到锚点：${e.what}`); continue }
      text = text.replace(e.find, e.replace)
      report.push(`✓ ${e.what}`)
    } else if (e.find instanceof RegExp) {
      if (!e.find.test(text)) { report.push(`✗ 找不到锚点（正则）：${e.what}`); continue }
      text = text.replace(e.find, e.replace)
      report.push(`✓ ${e.what}`)
    }
  }
  const head = `/* ${MARK}: 单机版（按上游无账号绑定）—— 本文件被 tools/patch-single-player.mjs 改过 */\n`
  const out = head + text
  say(`  ${rel}`)
  for (const r of report) say(`    ${r}`)
  if (report.some(r => r.startsWith('✗'))) die(`${rel} 有锚点未命中，拒绝写入（上游结构可能变了）`)
  if (!DRY) writeFileSync(file, out)
  changed++
}

// ① iOS 公告：不再注入绑定验证码（provideCode）
patchFile('out/cn-server.js', [{
  what: 'cn-server.js 去掉 notice.provideCode 注入',
  find: 'notice: { provideCode: (0, ios_notice_code_1.createIosNoticeCodeProvider)() },',
  replace: `notice: { /* ${MARK}: 单机版不给绑定验证码 */ },`,
}])

// ② 公告文案 + 标题：中性化（原文案让人去 QQ 群 /bind）
patchFile('out/routes/cn/ios-leiting.js', [
  {
    what: '公告标题改为「公告」',
    find: 'const IOS_NOTICE_TITLE = "服务器绑定验证码";',
    replace: 'const IOS_NOTICE_TITLE = "公告";',
  },
  {
    what: '公告正文改为中性文案',
    find: `function buildIosNoticeContent(code, ttlMinutes) {
    if (code) {
        return \`服务器绑定验证码：\${code}\\n\${ttlMinutes} 分钟内有效。\\n把它发给 QQ 群里的 bot（/bind \${code}）即完成绑定；\\n过期就在游戏里重新打开本公告即可刷新。\`;
    }
    return "请先在 QQ 群里向 bot 发送 /bind 获取绑定流程，或联系服主人工绑定。";
}`,
    replace: `function buildIosNoticeContent(code, ttlMinutes) {
    // ${MARK}: 单机版没有账号绑定，公告只留一句中性提示
    return "单机版：无需绑定账号，直接进入游戏即可。";
}`,
  },
])

// ③ 绑定闸门恒开（放行）
patchFile('out/lib/bind-gate.js', [
  {
    what: 'evaluateBindGate 强制 enabled=false',
    find: `    const config = (_a = input.config) !== null && _a !== void 0 ? _a : resolveBindGateConfig((_b = input.env) !== null && _b !== void 0 ? _b : process.env);`,
    replace: `    const config = (_a = input.config) !== null && _a !== void 0 ? _a : resolveBindGateConfig((_b = input.env) !== null && _b !== void 0 ? _b : process.env);
    // ${MARK}: 单机版（按上游）绑定闸门恒关 —— 就算环境里写了 BIND_GATE_ENABLED=1 也不拦人
    if (config && typeof config === "object") { config.enabled = false; }`,
  },
  {
    what: '关闭横幅去掉「生产环境必须设为 1」的公共服建议',
    find: `"生产环境必须设为 1，否则绑定流程形同虚设");`,
    replace: `"（${MARK}: 单机版已移除账号绑定，无需开启）");`,
  },
])

// ④ 后台绑定 API 全部下线
const bindingRel = 'out/routes/web_api/binding.js'
const bindingFile = path.join(BUNDLE, bindingRel)
if (st(bindingFile)) {
  const cur = readFileSync(bindingFile, 'utf8')
  if (cur.includes(MARK)) { say(`  = ${bindingRel}（已打过补丁）`); skipped++ }
  else {
    const stub = `/* ${MARK}: 单机版（按上游无账号绑定）—— 绑定 API 全部下线，只回 410 */
"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
const GONE = { error: "单机版已移除账号绑定功能（上游无此功能）" };
const routes = async function removedBindingRoutes(fastify) {
    const gone = async (request, reply) => { reply.status(410).send(GONE); };
    fastify.get("/", gone);
    fastify.get("/codes", gone);
    fastify.post("/codes", gone);
    fastify.post("/codes/:id/revoke", gone);
    fastify.post("/", gone);
    fastify.post("/:id/primary", gone);
    fastify.delete("/:id", gone);
};
exports.default = routes;
`
    say(`  ${bindingRel}（整文件替换为 410 桩）`)
    if (!DRY) writeFileSync(bindingFile, stub)
    changed++
  }
} else {
  say('  ! 没有 web_api/binding.js（跳过）')
}

say('')
say(`OK  改动 ${changed} 个文件，跳过 ${skipped} 个${DRY ? '（--dry-run 未写盘）' : ''}`)
if (changed && !DRY) {
  say('    下一步：把 server-bundle 推送/重打进交付物，然后重启游戏让服务端重新加载。')
}
