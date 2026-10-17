#!/usr/bin/env node
// serve-dist.mjs —— 在 PC 上起一个「只读静态文件服务」，让手机浏览器直接下载 dist/ 里的包。
//
// 为什么需要它：越狱线上机要把 deb（49.6 MB）和补丁 IPA（129 MB）弄到手机里。
// 走这条最省事：手机 Safari 打开 http://<PC 局域网 IP>:8088/ → 点文件名下载 →
//   ① .deb 用 Filza 打开（或 Sileo 的「从文件安装」）
//   ② .ipa 用 TrollStore / Sideloadly / Filza 装
//
// 安全边界（刻意做小）：
//   · 只服务 dist/ 这一层目录，不做子目录遍历（路径里出现 / 或 .. 直接 404）
//   · 只允许 GET/HEAD
//   · 默认绑定 0.0.0.0（手机才能访问）；只想本机用就 --host=127.0.0.1
//   · 不带任何写操作、不带 UI、不记录内容，只记一行访问日志
//
// 用法：node tools/serve-dist.mjs [--port=8088] [--host=0.0.0.0] [--dir=dist]
import { createServer } from 'node:http'
import { createReadStream, existsSync, readdirSync, statSync } from 'node:fs'
import { networkInterfaces } from 'node:os'
import path from 'node:path'

const args = Object.fromEntries(process.argv.slice(2).map(a => {
  const m = a.match(/^--([^=]+)(?:=(.*))?$/); return m ? [m[1], m[2] === undefined ? true : m[2]] : [a.replace(/^--/, ''), true]
}))
const PORT = Number(args.port || 8088)
const HOST = String(args.host || '0.0.0.0')
const ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1')), '..', String(args.dir || 'dist'))

const TYPES = { '.deb': 'application/vnd.debian.binary-package', '.ipa': 'application/octet-stream',
  '.gz': 'application/gzip', '.json': 'application/json', '.md': 'text/markdown; charset=utf-8',
  '.txt': 'text/plain; charset=utf-8', '.dylib': 'application/octet-stream', '.html': 'text/html; charset=utf-8' }
const human = (n) => n > 1048576 ? (n / 1048576).toFixed(1) + ' MB' : (n / 1024).toFixed(1) + ' KB'

function lanAddrs () {
  const out = []
  for (const list of Object.values(networkInterfaces())) {
    for (const i of list || []) if (i.family === 'IPv4' && !i.internal) out.push(i.address)
  }
  return out
}

const server = createServer((req, res) => {
  const url = decodeURIComponent((req.url || '/').split('?')[0])
  if (req.method !== 'GET' && req.method !== 'HEAD') { res.writeHead(405).end('method not allowed'); return }
  if (url.includes('..')) { res.writeHead(404).end('not found'); return }

  // 目录索引（只有 ROOT 这一层；子目录一律 404，避免变成通用文件服务器）
  if (url === '/' || url === '') {
    const files = readdirSync(ROOT).filter(f => statSync(path.join(ROOT, f)).isFile())
    const rows = files.map(f => {
      const st = statSync(path.join(ROOT, f))
      return `<li><a href="/${encodeURIComponent(f)}">${f}</a> <span style="color:#888">${human(st.size)} · ${st.mtime.toISOString().slice(0, 19).replace('T', ' ')}</span></li>`
    }).join('\n')
    const html = `<!doctype html><meta name="viewport" content="width=device-width,initial-scale=1">
<body style="font:15px -apple-system,sans-serif;margin:24px"><h3>SpCn 单机服务端 · 交付包</h3>
<p style="color:#666">点文件名下载到手机。deb 用 Filza/Sileo 安装；ipa 用 TrollStore / Sideloadly 安装。</p>
<ul>${rows}</ul></body>`
    res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' }).end(html)
    console.log(`[200] /  （${files.length} 个文件）`)
    return
  }

  const name = path.basename(url)
  const file = path.join(ROOT, name)
  if (!existsSync(file) || !statSync(file).isFile()) { res.writeHead(404).end('not found'); return }
  const st = statSync(file)
  console.log(`[200] ${name}  ${human(st.size)}`)
  res.writeHead(200, {
    'content-type': TYPES[path.extname(name).toLowerCase()] || 'application/octet-stream',
    'content-length': st.size,
    'content-disposition': `attachment; filename="${name}"`,
  })
  if (req.method === 'HEAD') return res.end()
  createReadStream(file).pipe(res)
})

server.listen(PORT, HOST, () => {
  console.log(`dist 目录 ${ROOT}`)
  console.log(`监听 http://${HOST}:${PORT}`)
  for (const a of lanAddrs()) console.log(`  手机浏览器打开： http://${a}:${PORT}/`)
  console.log('（Ctrl+C 停止）')
})
