// 从任意 IPA 里抽出进程内 Node 运行时（NodeMobile.framework），供非越狱线「把 node 集成进 dylib」用。
// 只读取 IPA、只写本机 runtime/ —— 不联网、不改设备。二进制不进仓库（.gitignore）。
//   node tools/fetch-nodemobile.mjs --ipa "C:\...\StarPointCN-iOS-Server.ipa"
// 产物：runtime/NodeMobile.framework/** + runtime/NodeMobile.framework.json（含 sha256/版本/ABI/provenance）
import { readZipEntries, readEntryData } from './vendor/lib/zip-ipa.mjs'
import { readFileSync, writeFileSync, mkdirSync, existsSync, chmodSync, rmSync } from 'node:fs'
import { join, dirname, basename } from 'node:path'
import { createHash } from 'node:crypto'

const arg = (k, d) => { const h = process.argv.find(a => a.startsWith(`--${k}=`)); return h ? h.slice(k.length + 3) : d }
const IPA = arg('ipa', '')
if (!IPA) { console.error('用法: node tools/fetch-nodemobile.mjs --ipa=<x.ipa> [--app=<App 名>] [--out=runtime/NodeMobile.framework]'); process.exit(2) }
const OUT = arg('out', 'runtime/NodeMobile.framework')
const MANIFEST = arg('manifest', 'runtime/NodeMobile.framework.json')
let APP = arg('app', '')

const sha256 = b => createHash('sha256').update(b).digest('hex')
const entries = readZipEntries(readFileSync(IPA))
console.log(`IPA：${IPA}（${entries.length} 条目 / ${readFileSync(IPA).length} B）`)

// 1. 定位 framework
if (!APP) {
  const hit = entries.find(e => /^Payload\/[^/]+\.app\/Frameworks\/NodeMobile\.framework\/NodeMobile$/.test(e.name))
  if (!hit) { console.error('❌ 这个 IPA 里没有 Frameworks/NodeMobile.framework/NodeMobile'); process.exit(1) }
  APP = hit.name.split('/')[1]
}
const PREFIX = `Payload/${APP}/Frameworks/NodeMobile.framework/`
const fw = entries.filter(e => e.name.startsWith(PREFIX) && !e.name.endsWith('/'))
console.log(`框架：${PREFIX} → ${fw.length} 个条目`)

// 2. 落盘（保留 mode；主二进制强制 0755）
rmSync(OUT, { recursive: true, force: true })
let mainBuf = null
for (const e of fw) {
  const rel = e.name.slice(PREFIX.length)
  if (rel.includes('..')) continue
  const dst = join(OUT, rel)
  mkdirSync(dirname(dst), { recursive: true })
  const data = readEntryData(e)
  writeFileSync(dst, data, { mode: rel === 'NodeMobile' ? 0o755 : 0o644 })
  chmodSync(dst, rel === 'NodeMobile' ? 0o755 : 0o644)
  if (rel === 'NodeMobile') mainBuf = data
}
if (!mainBuf) { console.error('❌ framework 里没有可执行体 NodeMobile'); process.exit(1) }

// 3. 校验：Mach-O 类型 / Node 版本 / ABI / 签名目录
const magic = mainBuf.readUInt32LE(0)
const isThin64 = magic === 0xfeedfacf
const isFat = magic === 0xcafebabe || magic === 0xbebafeca
const text = mainBuf.toString('latin1')
const has = s => text.includes(s)
const verM = text.match(/\b(v?1[0-9]\.\d{1,2}\.\d{1,2})\x00/)
const abiM = text.match(/node_register_module_v(\d+)/)
const ncmds = isThin64 ? mainBuf.readUInt32LE(16) : null
const plistPath = join(OUT, 'Info.plist')
const plistText = existsSync(plistPath) ? readFileSync(plistPath).toString('latin1') : ''
const plistScan = k => { const m = plistText.match(new RegExp(k + '[^\\x20-\\x7e]{0,10}([\\x20-\\x7e]{1,16})')); return m ? m[1].trim() : '?' }
const codeRes = fw.find(e => /_CodeSignature\/CodeResources$/.test(e.name))

console.log('\n=== 体检 ===')
console.log(`  主二进制：${mainBuf.length} B  sha256 ${sha256(mainBuf)}`)
console.log(`  Mach-O：${isThin64 ? '瘦 64 位（arm64）' : isFat ? 'FAT 多架构' : '未知 magic 0x' + magic.toString(16)}${ncmds ? ` ncmds=${ncmds}` : ''}`)
console.log(`  Node 版本串：${verM ? verM[1] : '未找到'}    ABI：${abiM ? abiM[1] : '未找到'}`)
console.log(`  nodejs-mobile 标记：${has('nodejs-mobile') ? '有' : '无'}    node_start 符号：${has('node_start') ? '有' : '无'}`)
console.log(`  Info.plist：CFBundleIdentifier≈${plistScan('CFBundleIdentifier')} MinimumOSVersion≈${plistScan('MinimumOSVersion')} CFBundleExecutable≈${plistScan('CFBundleExecutable')}`)
console.log(`  _CodeSignature/CodeResources：${codeRes ? `有（${codeRes.usize} B）` : '无'}`)

const ok = isThin64 && verM && abiM && has('node_start')
const manifest = {
  schemaVersion: 1,
  kind: 'NodeMobile.framework',
  source: { ipa: IPA, ipaBytes: readFileSync(IPA).length, appPrefix: PREFIX, provenance: '第三方产物抽取（非本仓库构建）' },
  binary: { path: 'NodeMobile', bytes: mainBuf.length, sha256: sha256(mainBuf), macho: isThin64 ? 'thin-arm64' : 'fat', ncmds },
  node: { version: verM ? verM[1] : null, abi: abiM ? Number(abiM[1]) : null },
  files: fw.length,
  entrypoints: ['node_start'],
  fetchedAt: new Date().toISOString(),
  usable: !!ok,
}
writeFileSync(MANIFEST, JSON.stringify(manifest, null, 2) + '\n')
console.log(`\n${ok ? '✅ 可用' : '❌ 不可用（缺版本/ABI/node_start）'} → ${OUT}`)
console.log(`   清单：${MANIFEST}`)
console.log('   注意：这是从第三方 IPA 抽的二进制，仓库不含它；正式发布前建议自建（见 docs/DELIVERY-standalone.md §7）。')
