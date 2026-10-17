#!/usr/bin/env node
// parse-crash.mjs —— 解析 iOS .ips 崩溃报告（第一行元数据 JSON，第二行负载 JSON），
// 打印我们关心的：异常类型 / 终止原因 / 崩溃线程栈 / 镜像里有没有我们的 dylib 与 NodeMobile。
//
// 用法：node tools/parse-crash.mjs [--dir .work/crash] [--file <某个 .ips>] [--frames 30]

import { readdirSync, readFileSync, statSync, existsSync } from 'node:fs'
import path from 'node:path'

const ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1')), '..')
const args = Object.fromEntries(process.argv.slice(2).map(a => {
  const m = a.match(/^--([^=]+)(?:=(.*))?$/); return m ? [m[1], m[2] === undefined ? true : m[2]] : [a.replace(/^--/, ''), true]
}))
const DIR = path.resolve(String(args.dir || path.join(ROOT, '.work', 'crash')))
const FRAMES = Number(args.frames || 30)

function listFiles () {
  if (args.file) return [path.resolve(String(args.file))]
  if (!existsSync(DIR)) return []
  return readdirSync(DIR).filter(f => f.endsWith('.ips'))
    .map(f => path.join(DIR, f))
    .sort((a, b) => statSync(b).mtimeMs - statSync(a).mtimeMs)
}

function parseOne (file) {
  const raw = readFileSync(file, 'utf8')
  const nl = raw.indexOf('\n')
  const head = JSON.parse(nl < 0 ? raw : raw.slice(0, nl))
  let body = {}
  if (nl >= 0) {
    try { body = JSON.parse(raw.slice(nl + 1)) } catch (e) { body = { _parseError: String(e.message) } }
  }
  return { file, head, body }
}

function imageName (body, idx) {
  const imgs = body?.usedImages || []
  const img = imgs[idx]
  if (!img) return `#${idx} (未知镜像)`
  return img.name || img.path || `#${idx}`
}

const files = listFiles()
if (!files.length) { console.log('没有找到 .ips 文件（先跑 tools/pull-crashes.sh）'); process.exit(0) }

for (const f of files) {
  let c
  try { c = parseOne(f) } catch (e) { console.log(`\n=== ${path.basename(f)} ===\n  解析失败：${e.message}`); continue }
  const { head, body } = c
  console.log(`\n=== ${path.basename(f)} ===`)
  console.log(`  App        ${head.app_name || '?'} ${head.app_version || ''} (${head.bundleID || '?'})`)
  console.log(`  时间       ${head.timestamp || '?'}   OS ${head.os_version || '?'}   ${head.device || ''}`)
  const ex = body.exception || {}
  console.log(`  异常       ${ex.type || '?'} ${ex.signal || ''} ${ex.subtype || ''} ${ex.codes || ''}`)
  if (ex.description) console.log(`  描述       ${ex.description}`)
  if (body.termination) console.log(`  终止       ${JSON.stringify(body.termination)}`)
  if (body.vmRegionInfo) console.log(`  VM         ${JSON.stringify(body.vmRegionInfo)}`)
  if (body.asi) console.log(`  ASI        ${JSON.stringify(body.asi)}`)
  if (body.lastExceptionBacktrace) console.log(`  上次异常栈 ${body.lastExceptionBacktrace}`)

  const threads = body.threads || []
  const faulting = threads.find(t => t.triggered) || threads[0]
  if (faulting) {
    console.log(`  崩溃线程   ${faulting.name || faulting.queue || `#${faulting.id ?? 0}`}`)
    for (const fr of (faulting.frames || []).slice(0, FRAMES)) {
      const img = imageName(body, fr.imageIndex)
      const sym = fr.symbol || fr.symbolLocation || ''
      console.log(`      ${String(img).padEnd(38)} ${sym} ${fr.imageOffset !== undefined ? '+0x' + Number(fr.imageOffset).toString(16) : ''} ${fr.sourceFile ? `(${fr.sourceFile}:${fr.sourceLine})` : ''}`)
    }
  }
  const ours = (body.usedImages || []).filter(i => /SpCnEmbedded|NodeMobile|SpCnRuntime/i.test(i.name || i.path || ''))
  console.log(`  我们的镜像 ${ours.length ? ours.map(i => `${i.name || i.path}${i.base !== undefined ? ' base=0x' + Number(i.base).toString(16) : ''}`).join(' / ') : '(崩溃报告里没有 → 说明崩在加载我们之前，或根本没加载)'}`)
}
