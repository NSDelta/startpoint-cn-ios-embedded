#!/usr/bin/env node
// extract-framework.mjs —— 从既有「iOS 单机服务端 App」IPA 里抽出 NodeMobile.framework，
// 落地到 runtime/node-framework-ios-arm64/NodeMobile.framework/，供 SpCnRuntime 一起进 IPA。
//
// 为什么直接复用而不是自建：
//   这个 framework 是 nodejs-mobile 系的 **Node 18.20.4（ABI 108）** 镜像 —— 与我们交叉编译的
//   better_sqlite3.node（ABI 108）精确匹配；自建 iOS framework 需要 macOS + Xcode，
//   本机只有 Windows + WSL theos，性价比完全不同。抽出来的每个字节都留 sha256 存证。
//
// 用法：
//   node tools/extract-framework.mjs --ipa "C:\...\StarPointCN-iOS-Server.ipa" --out runtime/node-framework-ios-arm64 [--force]

import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { readZipEntries, readEntryData } from './vendor/lib/zip-ipa.mjs';

const argv = process.argv.slice(2);
const args = {};
for (let i = 0; i < argv.length; i++) {
  const m = /^--([^=]+)(?:=(.*))?$/.exec(argv[i]);
  if (!m) continue;
  if (m[2] !== undefined) args[m[1]] = m[2];
  else if (argv[i + 1] && !argv[i + 1].startsWith('--')) args[m[1]] = argv[++i];
  else args[m[1]] = true;
}
const fail = (m) => { console.log('ERROR ' + m); process.exit(1); };
const log = (...a) => console.log(...a);
const sha256 = (b) => createHash('sha256').update(b).digest('hex');

if (!args.ipa) fail('需要 --ipa <源 IPA>');
if (!args.out) fail('需要 --out <目标目录>');
const IPA = path.resolve(args.ipa);
const OUT = path.resolve(args.out);
const FORCE = !!args.force;

if (!existsSync(IPA)) fail(`找不到 IPA：${IPA}`);
const fwRoot = path.join(OUT, 'NodeMobile.framework');
if (existsSync(fwRoot) && !FORCE) fail(`目标已存在：${fwRoot}（要覆盖加 --force）`);

const ipaBuf = readFileSync(IPA);
log(`== 源 IPA ==`);
log(`  ${IPA}`);
log(`  ${ipaBuf.length} B  sha256=${sha256(ipaBuf).slice(0, 16)}…`);

const entries = readZipEntries(ipaBuf);
const FW_RE = /^Payload\/([^/]+)\.app\/Frameworks\/NodeMobile\.framework\/(.+)$/;
const hits = [];
for (const e of entries) {
  const m = FW_RE.exec(e.name);
  if (m && !e.name.endsWith('/')) hits.push({ app: m[1], rel: m[2], e });
}
if (!hits.length) fail('这个 IPA 里没有 Payload/<App>.app/Frameworks/NodeMobile.framework/*');
const apps = [...new Set(hits.map(h => h.app))];
if (apps.length > 1) fail(`命中多个 App：${apps.join(', ')}`);

// ── 主二进制体检：必须是 arm64 Mach-O dylib，且带 node_start ──
const main = hits.find(h => h.rel === 'NodeMobile');
if (!main) fail('framework 里没有 NodeMobile 主二进制');
const bin = readEntryData(main.e);
if (bin.length < 32) fail('NodeMobile 太小');
const magic = bin.readUInt32LE(0), cputype = bin.readUInt32LE(4), filetype = bin.readUInt32LE(12);
if (magic !== 0xfeedfacf) fail(`NodeMobile 不是 64 位 Mach-O（magic=0x${magic.toString(16)}）`);
if (cputype !== 0x0100000c) fail(`NodeMobile 不是 arm64（cputype=0x${cputype.toString(16)}）`);
if (filetype !== 6) fail(`NodeMobile 不是 MH_DYLIB（filetype=${filetype}）`);
const latin = bin.toString('latin1');
if (!latin.includes('node_start')) fail('NodeMobile 里没有 node_start 符号 ⇒ 不是 nodejs-mobile 的 framework');
const verMatch = /\bv(\d{1,2}\.\d{1,2}\.\d{1,2})\x00/.exec(latin);
const abiMatch = /node_register_module_v(\d+)/.exec(latin);

log(`== framework ==`);
log(`  App            ${apps[0]}`);
log(`  NodeMobile     ${bin.length} B  sha256=${sha256(bin).slice(0, 16)}…  node=${verMatch ? 'v' + verMatch[1] : '?'}  abi=${abiMatch ? abiMatch[1] : '?'}  ncmds 等由 ipsw 复核`);
if (abiMatch && abiMatch[1] !== '108') {
  fail(`framework 的 ABI 是 ${abiMatch[1]}，但我们交叉编译的 better_sqlite3.node 是 ABI 108 ⇒ 必须一致`);
}

// ── 写盘（保留 framework 内部结构）──
mkdirSync(fwRoot, { recursive: true });
const written = [];
for (const h of hits) {
  const dst = path.join(fwRoot, h.rel);
  mkdirSync(path.dirname(dst), { recursive: true });
  const data = readEntryData(h.e);
  writeFileSync(dst, data);
  written.push({ rel: `NodeMobile.framework/${h.rel}`, bytes: data.length, sha256: sha256(data), zipBytes: h.e.raw.length });
}
written.sort((a, b) => a.rel.localeCompare(b.rel));
for (const w of written) log(`  + ${w.rel.padEnd(46)} ${String(w.bytes).padStart(9)} B  ${w.sha256.slice(0, 16)}…`);

const prov = {
  kind: 'spcn-ios-node-framework',
  extractedAt: new Date().toISOString(),
  note: 'nodejs-mobile 系 Node 18.20.4（ABI 108）iOS framework；从既有 iOS 单机服务端 App 中逐字节抽出，'
      + '与本仓库交叉编译的 better_sqlite3.node（ABI 108）配套；自建需 macOS + Xcode。',
  source: { ipa: IPA, bytes: ipaBuf.length, sha256: sha256(ipaBuf), app: apps[0], frameworkEntry: `Payload/${apps[0]}.app/Frameworks/NodeMobile.framework` },
  node: { version: verMatch ? 'v' + verMatch[1] : 'unknown', abi: abiMatch ? Number(abiMatch[1]) : 0 },
  files: written,
};
writeFileSync(path.join(OUT, 'PROVENANCE.json'), JSON.stringify(prov, null, 2) + '\n');
log(`  清单           ${path.join(OUT, 'PROVENANCE.json')}`);
console.log(`OK  NodeMobile.framework 抽出完成（${written.length} 个文件）`);
