#!/usr/bin/env node
// publish-release.mjs —— 用 GitHub REST API 建 release 并上传附件（不依赖 gh CLI）。
//
// token 从环境变量 GH_TOKEN 读（不要写进命令行/文件；PowerShell 里从凭据存储取：
//   $o = "protocol=https`nhost=github.com`nusername=NSDelta`n`n" | git credential fill
//   $env:GH_TOKEN = ($o | Where-Object {$_ -like 'password=*'}).Substring(9)
// ）
//
// 用法：
//   node tools/publish-release.mjs --repo=NSDelta/startpoint-cn-ios-embedded --tag=v0.2.0 \
//        --name="..." --notes-file=docs/RELEASE-v0.2.0.md --assets=dist/a.deb,dist/b.dylib
//   加 --dry-run 只打印将要做什么。
import { createReadStream, existsSync, readFileSync, statSync } from 'node:fs'
import https from 'node:https'
import path from 'node:path'

const args = Object.fromEntries(process.argv.slice(2).map(a => {
  const m = a.match(/^--([^=]+)(?:=(.*))?$/); return m ? [m[1], m[2] === undefined ? true : m[2]] : [a.replace(/^--/, ''), true]
}))
const REPO = String(args.repo || 'NSDelta/startpoint-cn-ios-embedded')
const TAG = String(args.tag || 'v0.2.0')
const NAME = String(args.name || TAG)
const NOTES = args['notes-file'] ? readFileSync(String(args['notes-file']), 'utf8') : String(args.notes || '')
const TARGET = String(args.target || 'main')
const ASSETS = String(args.assets || '').split(',').map(s => s.trim()).filter(Boolean)
const DRY = args['dry-run'] === true
const TOKEN = process.env.GH_TOKEN || ''
if (!TOKEN) { console.log('✗ 缺少 GH_TOKEN 环境变量'); process.exit(1) }

const API = 'api.github.com'
const UPLOAD = 'uploads.github.com'

function req (host, method, p, body, extraHeaders = {}) {
  return new Promise((resolve, reject) => {
    const payload = body === undefined || body === null ? null : (Buffer.isBuffer(body) ? body : Buffer.from(JSON.stringify(body)))
    const headers = Object.assign({
      Authorization: `Bearer ${TOKEN}`,
      'User-Agent': 'spcn-release',
      Accept: 'application/vnd.github+json',
      'X-GitHub-Api-Version': '2022-11-28',
    }, payload ? { 'Content-Type': 'application/json', 'Content-Length': payload.length } : {}, extraHeaders)
    const r = https.request({ host, method, path: p, headers }, (res) => {
      const chunks = []
      res.on('data', c => chunks.push(c))
      res.on('end', () => {
        const text = Buffer.concat(chunks).toString('utf8')
        let json = null
        try { json = text ? JSON.parse(text) : null } catch { }
        if (res.statusCode >= 200 && res.statusCode < 300) resolve({ status: res.statusCode, json, text })
        else reject(new Error(`${method} ${host}${p} → ${res.statusCode} ${text.slice(0, 400)}`))
      })
    })
    r.on('error', reject)
    if (payload) r.write(payload)
    r.end()
  })
}

function uploadAsset (uploadUrl, file) {
  const base = uploadUrl.replace(/\{.*\}$/, '')
  const name = path.basename(file)
  const size = statSync(file).size
  const q = `?name=${encodeURIComponent(name)}&label=${encodeURIComponent(name)}`
  return new Promise((resolve, reject) => {
    const r = https.request({
      host: UPLOAD, method: 'POST', path: new URL(base).pathname + q,
      headers: {
        Authorization: `Bearer ${TOKEN}`, 'User-Agent': 'spcn-release',
        Accept: 'application/vnd.github+json', 'Content-Type': 'application/octet-stream',
        'Content-Length': size,
      },
    }, (res) => {
      const chunks = []
      res.on('data', c => chunks.push(c))
      res.on('end', () => {
        const text = Buffer.concat(chunks).toString('utf8')
        if (res.statusCode >= 200 && res.statusCode < 300) {
          let st = null
          try { st = JSON.parse(text).state } catch { }
          resolve({ name, status: res.statusCode, state: st, size })
        } else reject(new Error(`upload ${name} → ${res.statusCode} ${text.slice(0, 300)}`))
      })
    })
    r.on('error', reject)
    createReadStream(file).pipe(r)
  })
}

const mb = n => (n / 1048576).toFixed(1) + ' MB'
const missing = ASSETS.filter(f => !existsSync(f))
if (missing.length) { console.log('✗ 附件不存在：' + missing.join(', ')); process.exit(1) }
console.log(`仓库 ${REPO}  tag ${TAG}  附件 ${ASSETS.length} 个（${mb(ASSETS.reduce((s, f) => s + statSync(f).size, 0))}）`)
for (const f of ASSETS) console.log(`  ${String(statSync(f).size).padStart(10)}  ${f}`)
if (DRY) { console.log('（--dry-run：不调用 API）'); process.exit(0) }

// 1) 建/取 release
let rel = null
try {
  rel = (await req(API, 'GET', `/repos/${REPO}/releases/tags/${TAG}`)).json
  console.log(`✓ 已有 release id=${rel.id}（复用）`)
} catch (e) {
  if (!/→ 404/.test(e.message)) throw e
  rel = (await req(API, 'POST', `/repos/${REPO}/releases`, {
    tag_name: TAG, target_commitish: TARGET, name: NAME, body: NOTES, draft: false, prerelease: false,
  })).json
  console.log(`✓ 已创建 release id=${rel.id}  ${rel.html_url}`)
}

// 2) 逐个上传（同名先删，保证幂等）
const existing = new Set(((await req(API, 'GET', `/repos/${REPO}/releases/${rel.id}/assets?per_page=100`)).json || []).map(a => a.name))
for (const file of ASSETS) {
  const name = path.basename(file)
  if (existing.has(name)) {
    const list = (await req(API, 'GET', `/repos/${REPO}/releases/${rel.id}/assets?per_page=100`)).json
    const a = list.find(x => x.name === name)
    await req(API, 'DELETE', `/repos/${REPO}/releases/assets/${a.id}`)
    console.log(`  - 删掉同名旧附件 ${name}`)
  }
  const t0 = Date.now()
  const r = await uploadAsset(rel.upload_url, file)
  console.log(`  ✓ ${r.name}  ${mb(r.size)}  ${r.state}  ${((Date.now() - t0) / 1000).toFixed(1)}s`)
}
console.log('')
console.log(`OK  ${rel.html_url}`)
