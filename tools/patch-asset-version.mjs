#!/usr/bin/env node
// patch-asset-version.mjs —— 让服务端接受 1.4.54–1.4.57 这一段资源目录版本（上游只认死 1.4.54）。
//
// 背景：`out/runtime/release-contract.js` 里对 assets/server_release_contract.json 的
// `bundledCdnCatalogVersion` 做了 requireFixed(…, "1.4.54") 硬校验；而我们的 CDN 已经推进到
// 1.4.57（`.cdn/patches/1.4.55|1.4.56|1.4.57`）。这里把硬校验放宽成白名单，并把契约里的版本改成
// 目标版本（默认 1.4.57），这样 local 模式 / 内容同步 / 客户端拿到的 assetVersion 都与 CDN 一致。
//
// 幂等：文件里出现 SP_ASSET_VERSION_PATCH 就跳过。
// 用法：node tools/patch-asset-version.mjs [--runtime=runtime/SpCnRuntime] [--version=1.4.57] [--dry-run]

import { existsSync, readFileSync, writeFileSync } from 'node:fs'
import path from 'node:path'

const args = Object.fromEntries(process.argv.slice(2).map(a => {
  const m = a.match(/^--([^=]+)(?:=(.*))?$/); return m ? [m[1], m[2] === undefined ? true : m[2]] : [a.replace(/^--/, ''), true]
}))
const ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1')), '..')
const RUNTIME = path.resolve(args.runtime ? String(args.runtime) : path.join(ROOT, 'runtime', 'SpCnRuntime'))
const BUNDLE = path.join(RUNTIME, 'server-bundle')
const VERSION = String(args.version || '1.4.57')
const RANGE = ['1.4.54', '1.4.55', '1.4.56', '1.4.57']
const DRY = args['dry-run'] === true
const MARK = 'SP_ASSET_VERSION_PATCH'

if (!RANGE.includes(VERSION)) { console.error(`ERROR --version 必须是 ${RANGE.join('/')} 之一`); process.exit(1) }
const say = (s) => console.log(s)

// ① 放宽 hard-coded 1.4.54 校验
const relFile = path.join(BUNDLE, 'out/runtime/release-contract.js')
if (!existsSync(relFile)) { console.error('ERROR 缺文件：' + relFile); process.exit(1) }
let rel = readFileSync(relFile, 'utf8')
const anchor = '    requireFixed(requireVersion(contract.bundledCdnCatalogVersion, "bundledCdnCatalogVersion"), "1.4.54", "bundledCdnCatalogVersion");'
if (rel.includes(MARK)) {
  say('  = out/runtime/release-contract.js（已打过补丁）')
} else if (!rel.includes(anchor)) {
  console.error('ERROR 找不到 bundledCdnCatalogVersion 的 requireFixed 锚点（上游结构可能变了）')
  process.exit(1)
} else {
  const replacement = [
    `    /* ${MARK}: 允许 ${RANGE[0]}–${RANGE[RANGE.length - 1]} 的资源目录版本（上游只认死 ${RANGE[0]}） */`,
    `    {`,
    `        const assetCatalogVersion = requireVersion(contract.bundledCdnCatalogVersion, "bundledCdnCatalogVersion");`,
    `        const supportedCatalogVersions = ${JSON.stringify(RANGE)};`,
    `        if (!supportedCatalogVersions.includes(assetCatalogVersion)) {`,
    `            throw new Error('bundledCdnCatalogVersion must be one of ' + supportedCatalogVersions.join(','));`,
    `        }`,
    `    }`,
  ].join('\n')
  rel = rel.replace(anchor, replacement)
  say('  out/runtime/release-contract.js')
  say(`    ✓ bundledCdnCatalogVersion 放宽为 ${RANGE[0]}–${RANGE[RANGE.length - 1]}`)
  if (!DRY) writeFileSync(relFile, rel)
}

// ② 契约里的版本改成目标版本
const contractFile = path.join(BUNDLE, 'assets/server_release_contract.json')
if (!existsSync(contractFile)) { console.error('ERROR 缺文件：' + contractFile); process.exit(1) }
const raw = readFileSync(contractFile, 'utf8')
const contract = JSON.parse(raw)
const before = contract.bundledCdnCatalogVersion
if (before === VERSION) {
  say(`  = assets/server_release_contract.json（bundledCdnCatalogVersion 已是 ${VERSION}）`)
} else {
  contract.bundledCdnCatalogVersion = VERSION
  say('  assets/server_release_contract.json')
  say(`    ✓ bundledCdnCatalogVersion ${before} → ${VERSION}`)
  if (!DRY) writeFileSync(contractFile, JSON.stringify(contract, null, 2) + '\n')
}

// ③ 客户端清单里的最低资源版本保持 1.4.54（minClientAssetVersion 是下限，1.4.57 客户端自然满足）
const manifestFile = path.join(BUNDLE, 'server-manifest.json')
if (existsSync(manifestFile)) {
  const manifest = JSON.parse(readFileSync(manifestFile, 'utf8'))
  const min = manifest.assets && manifest.assets.minClientAssetVersion
  say(`  server-manifest.json：assets.minClientAssetVersion = ${min}（下限，不动）`)
}

say('')
say(`OK  ${DRY ? '（--dry-run 未写盘）' : '已写入'}；目标资源版本 ${VERSION}`)
