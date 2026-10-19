#!/usr/bin/env node
// builds-json.mjs —— 单独重算 dist/BUILDS.json（build-all 的第 ⑦ 步做到一半会因 2 GiB 分片炸掉时的补救）。
import { createReadStream, readdirSync, statSync, writeFileSync } from 'node:fs'
import crypto from 'node:crypto'
import path from 'node:path'

const ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1')), '..')
const DIST = path.join(ROOT, 'dist')
const shaAsync = (p) => new Promise((res, rej) => {
  const h = crypto.createHash('sha256')
  createReadStream(p).on('data', d => h.update(d)).on('end', () => res(h.digest('hex'))).on('error', rej)
})
const mb = n => (n / 1048576).toFixed(1) + ' MB'

const files = readdirSync(DIST).filter(f => statSync(path.join(DIST, f)).isFile() && f !== 'BUILDS.json').sort()
const rows = []
for (const f of files) {
  const fp = path.join(DIST, f)
  const st = statSync(fp)
  rows.push({
    file: f, bytes: st.size,
    sha256: st.size > 1073741824 ? 'skipped(>1GiB)' : await shaAsync(fp),
    mtime: st.mtime.toISOString(),
  })
}
writeFileSync(path.join(DIST, 'BUILDS.json'), JSON.stringify({ generatedAt: new Date().toISOString(), files: rows }, null, 2) + '\n')
for (const r of rows) console.log(`  ${String(r.bytes).padStart(12)}  ${String(r.sha256).slice(0, 16)}  ${r.file}   ${mb(r.bytes)}`)
console.log(`OK dist/BUILDS.json（${rows.length} 个文件）`)
