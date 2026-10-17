#!/usr/bin/env node
// embed-runtime.mjs —— 把 SpCnRuntime（ios-arm64 node + server-bundle + node_modules）塞进 IPA 的
// `Payload/<App>.app/SpCnRuntime/**`，让「服务端运行时」跟着 IPA 一起装进手机（非越狱线的唯一可行位置：
// 容器里后来写进去的可执行文件不会被侧载工具签名 ⇒ 只有 .app 包内、由侧载工具一并签名的 node 才能 exec）。
//
// 为什么单独一个阶段（而不是并进 patch-ipa.mjs）：
//   · patch-ipa.mjs 只碰主二进制的 Mach-O（并断言 ncmds/sizeofcmds 不变）；本工具**完全不碰 Mach-O**，
//     只往 zip 里追加条目 ⇒ 两者互不影响，谁先谁后都对（但整体顺序是 patch → inject-dylib → 本工具，
//     因为 inject-dylib 要求自己是最后一个动主二进制的人）。
//   · 逐条流式读取 + 只常驻「压缩后」字节，避免 167 MB 明文 + 200 MB 输出同时在内存里。
//
// 产物语义（与 ios/src/SpCnConfig.m 的探测顺序严格对齐）：
//   1) 新增条目名 = `Payload/<App>.app/SpCnRuntime/<相对路径>`（正斜杠）
//   2) node 可执行条目必须带 Unix 可执行位：externalAttr = 0o100755 << 16（与主二进制同一个 versionMadeBy，
//      宿主 = OSX/Unix 时该高位才有意义 —— 这是「能不能 exec」的关键，jar uf0 那套会把权限位丢掉）
//   3) 其余文件 0o100644
//   4) 已存在的同名条目默认跳过（幂等），--force 才覆盖
//
// 用法：
//   node tools/embed-runtime.mjs --ipa=in.ipa --runtime=runtime/SpCnRuntime --out=out.ipa
//   [--app=Payload/worldflipper.app] [--level=6] [--force] [--dry-run] [--quiet]

import { readFileSync, writeFileSync, readdirSync, statSync, existsSync } from 'node:fs'
import path from 'node:path'
import crypto from 'node:crypto'
import { deflateRawSync, inflateRawSync } from 'node:zlib'

import { readZipEntries, writeZipEntries, crc32, madeByHost } from './vendor/lib/zip-ipa.mjs'

const RUNTIME_REL = 'SpCnRuntime'
const EXEC_REL = 'node-ios-arm64/node'          // 唯一需要可执行位的文件
const MARKER = 'spcn-embed-report.json'

function parseArgs(argv) {
  const out = { level: 6, force: false, dryRun: false, quiet: false, app: '', ipa: '', runtime: '', out: '' }
  for (const a of argv) {
    const m = a.match(/^--([^=]+)(?:=(.*))?$/)
    if (!m) continue
    const [, k, v] = m
    if (k === 'force') out.force = true
    else if (k === 'dry-run') out.dryRun = true
    else if (k === 'quiet') out.quiet = true
    else if (k === 'level') out.level = Number(v)
    else if (k === 'app') out.app = v
    else if (k === 'ipa') out.ipa = v
    else if (k === 'runtime') out.runtime = v
    else if (k === 'out') out.out = v
  }
  return out
}

const say = (s) => { if (!process.env.SPCN_QUIET) console.log(s) }
const die = (s) => { console.log('ERROR ' + s); process.exit(1) }
const sha256 = (b) => crypto.createHash('sha256').update(b).digest('hex')
const toPosix = (p) => p.split(path.sep).join('/')

/** 递归列出目录下全部普通文件（返回相对于 root 的 posix 相对路径，已排序 ⇒ 产物可复现）。 */
function walk(root) {
  const files = []
  const rec = (dir, rel) => {
    for (const ent of readdirSync(dir, { withFileTypes: true })) {
      if (ent.name === '.DS_Store' || ent.name === 'Thumbs.db') continue
      const abs = path.join(dir, ent.name)
      const r = rel ? `${rel}/${ent.name}` : ent.name
      if (ent.isDirectory()) rec(abs, r)
      else if (ent.isFile()) files.push({ abs, rel: r })
      else if (ent.isSymbolicLink()) say(`  (跳过符号链接：${r})`)
    }
  }
  rec(root, '')
  files.sort((a, b) => (a.rel < b.rel ? -1 : a.rel > b.rel ? 1 : 0))
  return files
}

/** 从 zip 条目里定位 App 目录：Payload/<X>.app/Info.plist。 */
function findAppDir(entries) {
  const hit = entries.find((e) => /^Payload\/[^/]+\.app\/Info\.plist$/.test(e.name))
  return hit ? hit.name.replace(/\/Info\.plist$/, '') : ''
}

function main() {
  const opt = parseArgs(process.argv.slice(2))
  if (!opt.ipa || !opt.runtime || !opt.out) die('需要 --ipa --runtime --out')
  if (!existsSync(opt.ipa)) die('找不到 IPA：' + opt.ipa)
  if (!existsSync(opt.runtime)) die('找不到运行时目录：' + opt.runtime)

  say('== 把运行时塞进 IPA ==')
  const ipaBuf = readFileSync(opt.ipa)
  say(`  IPA        ${opt.ipa}  ${(ipaBuf.length / 1048576).toFixed(1)} MB`)
  const entries = readZipEntries(ipaBuf)
  const appDir = opt.app || findAppDir(entries)
  if (!appDir) die('IPA 里找不到 Payload/<X>.app/Info.plist —— 用 --app 指定')
  const appName = path.posix.basename(appDir)
  const exeName = appName.replace(/\.app$/, '')
  const mainEntry = entries.find((e) => e.name === `${appDir}/${exeName}`)
  if (!mainEntry) die(`找不到主二进制条目 ${appDir}/${exeName}`)
  const host = madeByHost(mainEntry)
  say(`  App        ${appDir}（主二进制 ${(mainEntry.usize / 1048576).toFixed(1)} MB，mode ${(mainEntry.externalAttr >>> 16).toString(8)}，宿主 ${host}${host === 19 ? '=OSX' : host === 3 ? '=Unix' : '=⚠️非 Unix，可执行位可能不被尊重'}）`)
  if (host !== 3 && host !== 19) die('主二进制版本宿主不是 Unix/OSX ⇒ 追加的可执行位不可靠，拒绝继续')

  // ── 收集要加的文件 ──
  const srcFiles = walk(opt.runtime)
  const nodeSrc = srcFiles.find((f) => f.rel === EXEC_REL)
  if (!nodeSrc) die(`运行时目录里没有 ${EXEC_REL}（node 可执行）`)
  for (const need of ['spcn-runtime.json', `${path.posix.join('server-bundle', 'server-manifest.json')}`,
                      'node_modules/better-sqlite3/build/Release/better_sqlite3.node']) {
    if (!srcFiles.some((f) => f.rel === need)) die(`运行时目录缺件：${need}（先跑 tools/assemble-runtime.mjs）`)
  }
  const existing = new Set(entries.map((e) => e.name))
  const added = []
  let skipped = 0
  for (const f of srcFiles) {
    const name = `${appDir}/${RUNTIME_REL}/${f.rel}`
    if (existing.has(name) && !opt.force) { skipped++; continue }
    added.push({ ...f, name })
  }
  say(`  运行时     ${srcFiles.length} 文件 / ${(srcFiles.reduce((n, f) => n + statSync(f.abs).size, 0) / 1048576).toFixed(1)} MB 明文`)
  say(`  新增条目   ${added.length}${skipped ? `（跳过已存在 ${skipped}）` : ''}${opt.force ? ' [--force 覆盖]' : ''}`)
  if (!added.length) { say('  没有需要新增的条目 ⇒ 直接写出去（等同于复制）'); }

  // ── 压缩并组装新条目 ──
  let rawTotal = 0, defTotal = 0
  const newEntries = []
  for (const f of added) {
    const data = readFileSync(f.abs)
    const raw = deflateRawSync(data, { level: opt.level })
    const exec = f.rel === EXEC_REL
    newEntries.push({
      name: f.name, method: 8, flags: 0,
      mtime: mainEntry.mtime, mdate: mainEntry.mdate,
      crc: crc32(data), csize: raw.length, usize: data.length,
      versionMadeBy: mainEntry.versionMadeBy,
      externalAttr: (((exec ? 0o100755 : 0o100644) << 16) | (exec ? 0 : 0)) >>> 0,
      raw,
    })
    rawTotal += data.length; defTotal += raw.length
  }
  say(`  压缩       ${(rawTotal / 1048576).toFixed(1)} MB → ${(defTotal / 1048576).toFixed(1)} MB（level ${opt.level}）`)

  // 构建报告（随包一起带进去，装机后可自证版本）
  const report = {
    tool: 'tools/embed-runtime.mjs', schemaVersion: 1, generatedAt: new Date().toISOString(),
    app: appDir, runtimeDir: `${appDir}/${RUNTIME_REL}`,
    files: srcFiles.length, added: added.length, skippedExisting: skipped,
    rawBytes: rawTotal, deflatedBytes: defTotal,
    node: { rel: EXEC_REL, bytes: statSync(nodeSrc.abs).size, sha256: sha256(readFileSync(nodeSrc.abs)), mode: '0755' },
  }
  const reportName = `${appDir}/${MARKER}`
  if (!existing.has(reportName)) {
    const data = Buffer.from(JSON.stringify(report, null, 2) + '\n', 'utf8')
    const raw = deflateRawSync(data, { level: 9 })
    newEntries.push({
      name: reportName, method: 8, flags: 0, mtime: mainEntry.mtime, mdate: mainEntry.mdate,
      crc: crc32(data), csize: raw.length, usize: data.length,
      versionMadeBy: mainEntry.versionMadeBy, externalAttr: (0o100644 << 16) >>> 0, raw,
    })
  }

  if (opt.dryRun) { say('  --dry-run ⇒ 不写文件'); say('OK  dry-run 完成'); return }

  // ── 写盘（未改动条目原样搬运） ──
  const outEntries = entries.map((e) => {
    const repl = newEntries.find((n) => n.name === e.name)
    return repl || e
  })
  const keptNames = new Set(entries.map((e) => e.name))
  for (const n of newEntries) if (!keptNames.has(n.name)) outEntries.push(n)

  const outBuf = writeZipEntries(outEntries)
  writeFileSync(opt.out, outBuf)
  say(`  写出       ${opt.out}  ${(outBuf.length / 1048576).toFixed(1)} MB（${outEntries.length} 条目）`)

  // ── 自校验：重读产物，逐条比对「未改动条目」的 crc/长度，并真解压 node 条目核对 sha256 ──
  say('  ── 自校验 ──')
  const back = readZipEntries(readFileSync(opt.out))
  const bad = []
  if (back.length !== outEntries.length) bad.push(`条目数 ${outEntries.length} → ${back.length}`)
  for (const e of entries) {
    const b = back.find((x) => x.name === e.name)
    if (!b) { bad.push(`丢条目 ${e.name}`); continue }
    if (b.crc !== e.crc || b.usize !== e.usize || b.externalAttr !== e.externalAttr ||
        b.versionMadeBy !== e.versionMadeBy || b.method !== e.method || !b.raw.equals(e.raw)) {
      bad.push(`条目被改动 ${e.name}`)
    }
  }
  const nodeBack = back.find((x) => x.name === `${appDir}/${RUNTIME_REL}/${EXEC_REL}`)
  if (!nodeBack) bad.push('新增的 node 条目不见了')
  else {
    const mode = (nodeBack.externalAttr >>> 16) & 0xffff
    if (mode !== 0o100755) bad.push(`node 条目权限 ${mode.toString(8)} ≠ 755`)
    const data = nodeBack.method === 8 ? inflateRawSync(nodeBack.raw) : Buffer.from(nodeBack.raw)
    if (sha256(data) !== report.node.sha256) bad.push('node 条目解压后 sha256 与源文件不一致')
    say(`  node 条目  ${(nodeBack.usize / 1048576).toFixed(1)} MB  mode=${mode.toString(8)}  sha256=${sha256(data).slice(0, 16)}…`)
  }
  const dupe = back.length !== new Set(back.map((e) => e.name)).size
  if (dupe) bad.push('存在重名条目')
  if (bad.length) { for (const b of bad) console.log('  ✗ ' + b); die(`自校验失败（${bad.length} 项）`) }
  say(`  ✓ ${entries.length} 条原条目逐字节不变，新增 ${back.length - entries.length} 条，node 可执行位 + 内容一致`)
  say(`OK  ${opt.out}`)
}

main()
