#!/usr/bin/env node
// gh-whoami.mjs —— 用 GH_TOKEN 试一下 GitHub API 能不能通（不打印 token）。
import https from 'node:https'
const TOKEN = process.env.GH_TOKEN || ''
if (!TOKEN) { console.log('✗ 没有 GH_TOKEN'); process.exit(1) }
const t0 = Date.now()
const r = https.request({
  host: 'api.github.com', path: '/user', method: 'GET',
  headers: { Authorization: `Bearer ${TOKEN}`, 'User-Agent': 'spcn-whoami', Accept: 'application/vnd.github+json' },
  timeout: 15000,
}, (res) => {
  let b = ''
  res.on('data', c => { b += c })
  res.on('end', () => {
    console.log(`status=${res.statusCode}  ${((Date.now() - t0) / 1000).toFixed(1)}s`)
    console.log('scopes=[' + (res.headers['x-oauth-scopes'] || '') + ']')
    try { const j = JSON.parse(b); console.log('login=' + j.login + '  type=' + j.type) } catch { console.log(b.slice(0, 200)) }
  })
})
r.on('timeout', () => { console.log('✗ 超时（api.github.com 不可达？试试代理）'); r.destroy() })
r.on('error', e => console.log('✗ ' + e.message))
r.end()
