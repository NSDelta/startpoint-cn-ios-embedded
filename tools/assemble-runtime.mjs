#!/usr/bin/env node
// assemble-runtime.mjs —— 把「iOS node 可执行 + Server Bundle + 生产依赖 + ios-arm64 原生模块」
// 组装成一个自包含的 SpCnRuntime 目录（= 嵌入式运行契约 v1 里 Runtime Pack 的物化形态），
// 并产出 sha256 清单 spcn-runtime.json（清单进版本库，payload 不进）。
//
// 依据：D:\wfcnmod\server\startpoint-cn-dev\docs\embedded-runtime-contract.md
//   · Runtime Pack  = node 可执行 + node_modules + 运行时清单
//   · Server Bundle = out/ assets/ web/dist/ LICENSE NOTICE server-manifest.json
//   · Data Volume   = 运行期唯一的可写目录（设备上由 Supervisor 指定 DATA_DIR）
//
// 用法（Windows 开发机）：
//   node tools/assemble-runtime.mjs ^
//     --node    runtime\node-ios-arm64\node ^
//     --bundle  runtime\SpCnRuntime\server-bundle ^
//     --modules runtime\SpCnRuntime\node_modules ^
//     --out     runtime\SpCnRuntime
// 可选：
//   --binding <better_sqlite3.node 路径>   缺省 = <modules>/better-sqlite3/build/Release/better_sqlite3.node
//   --check-only                           只校验现有 --out 目录，不复制
//   --quiet

import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, readdirSync, statSync, writeFileSync, cpSync } from 'node:fs';
import path from 'node:path';

const argv = process.argv.slice(2);
const args = {};
for (let i = 0; i < argv.length; i++) {
  const m = /^--([^=]+)(?:=(.*))?$/.exec(argv[i]);
  if (!m) continue;
  if (m[2] !== undefined) args[m[1]] = m[2];
  else if (argv[i + 1] && !argv[i + 1].startsWith('--')) args[m[1]] = argv[++i];
  else args[m[1]] = true;
}
const QUIET = !!args.quiet;
const log = (...a) => { if (!QUIET) console.log(...a); };
const fail = (m) => { console.log('ERROR ' + m); process.exit(1); };

const NODE_SRC = args.node ? path.resolve(args.node) : null;
const BUNDLE_SRC = args.bundle ? path.resolve(args.bundle) : null;
const MODULES_SRC = args.modules ? path.resolve(args.modules) : null;
const OUT = args.out ? path.resolve(args.out) : null;
const CHECK_ONLY = !!args['check-only'];
if (!OUT) fail('需要 --out <SpCnRuntime 目录>');
if (!CHECK_ONLY && (!NODE_SRC || !BUNDLE_SRC || !MODULES_SRC)) fail('需要 --node --bundle --modules --out（或用 --check-only 只校验）');

const sha256 = (p) => createHash('sha256').update(readFileSync(p)).digest('hex');
const isMachOArm64 = (p) => {
  const b = readFileSync(p, { encoding: null, flag: 'r' }).subarray(0, 8);
  if (b.length < 8) return false;
  const magic = b.readUInt32LE(0);
  const cputype = b.readUInt32LE(4);
  return magic === 0xfeedfacf && cputype === 0x0100000c;   // MH_MAGIC_64 + CPU_TYPE_ARM64
};
const dirStats = (dir) => {           // 递归统计文件数/字节数
  let files = 0, bytes = 0;
  const walk = (d) => {
    for (const e of readdirSync(d, { withFileTypes: true })) {
      const p = path.join(d, e.name);
      if (e.isDirectory()) walk(p);
      else if (e.isFile()) { files++; bytes += statSync(p).size; }
    }
  };
  walk(dir);
  return { files, bytes };
};

const NODE_DST = path.join(OUT, 'node-ios-arm64', 'node');
const BUNDLE_DST = path.join(OUT, 'server-bundle');
const MODULES_DST = path.join(OUT, 'node_modules');

if (!CHECK_ONLY) {
  // ── 1. 校验输入 ────────────────────────────────────────────────
  if (!existsSync(NODE_SRC)) fail(`找不到 node 可执行：${NODE_SRC}`);
  if (!isMachOArm64(NODE_SRC)) fail(`node 不是 arm64 Mach-O：${NODE_SRC}（是不是拿了 Windows/Linux 的 node？）`);
  const manifestPath = path.join(BUNDLE_SRC, 'server-manifest.json');
  if (!existsSync(manifestPath)) fail(`Server Bundle 缺 server-manifest.json：${manifestPath}`);
  const sm = JSON.parse(readFileSync(manifestPath, 'utf8'));
  if (!sm.entry) fail('server-manifest.json 缺 entry');
  if (!existsSync(path.join(BUNDLE_SRC, sm.entry))) fail(`server-manifest.entry 指向的文件不存在：${sm.entry}`);
  const adminPath = sm.admin?.path || 'web/dist';
  if (!existsSync(path.join(BUNDLE_SRC, adminPath))) fail(`Server Bundle 缺后台前端 ${adminPath}（契约要求 admin 必须可用）`);

  const BINDING_SRC = path.resolve(args.binding || path.join(MODULES_SRC, 'better-sqlite3', 'build', 'Release', 'better_sqlite3.node'));
  if (!existsSync(BINDING_SRC)) fail(`找不到 better_sqlite3.node：${BINDING_SRC}`);

  // ── 2. 复制三件套（源与目标同一路径时跳过：允许直接把 runtime/SpCnRuntime 当暂存目录）──
  log('== 组装 SpCnRuntime ==');
  const same = (a, b) => path.resolve(a) === path.resolve(b);
  mkdirSync(path.join(OUT, 'node-ios-arm64'), { recursive: true });
  const already = (src, dst) => existsSync(dst) && statSync(dst).size === statSync(src).size;
  if (!same(NODE_SRC, NODE_DST)) {
    if (already(NODE_SRC, NODE_DST)) log('  node        已就位（大小一致，跳过复制）');
    else cpSync(NODE_SRC, NODE_DST);
  }
  log(`  node        -> node-ios-arm64/node   (${(statSync(NODE_DST).size / 1048576).toFixed(1)} MB)${same(NODE_SRC, NODE_DST) ? ' [原地]' : ''}`);
  if (!same(BUNDLE_SRC, BUNDLE_DST)) { cpSync(BUNDLE_SRC, BUNDLE_DST, { recursive: true }); log('  server-bundle -> server-bundle/'); }
  else log('  server-bundle 已就位（原地）');
  if (!same(MODULES_SRC, MODULES_DST)) { cpSync(MODULES_SRC, MODULES_DST, { recursive: true }); log('  node_modules  -> node_modules/'); }
  else log('  node_modules  已就位（原地）');
}

// ── 3. 校验产物（--check-only 也走这里）─────────────────────────
if (!existsSync(NODE_DST)) fail(`产物缺 node：${NODE_DST}`);
if (!isMachOArm64(NODE_DST)) fail('产物 node 不是 arm64 Mach-O');
if (!existsSync(path.join(BUNDLE_DST, 'server-manifest.json'))) fail('产物缺 server-bundle/server-manifest.json');
if (!existsSync(path.join(MODULES_DST, 'better-sqlite3'))) fail('产物缺 node_modules/better-sqlite3');

const BINDING_DST = path.join(MODULES_DST, 'better-sqlite3', 'build', 'Release', 'better_sqlite3.node');
if (!existsSync(BINDING_DST)) fail(`产物缺原生模块：${BINDING_DST}`);

const smFinal = JSON.parse(readFileSync(path.join(BUNDLE_DST, 'server-manifest.json'), 'utf8'));
const nodeBytes = statSync(NODE_DST).size;
const bindingBytes = statSync(BINDING_DST).size;
const bundleStats = dirStats(BUNDLE_DST);
const moduleStats = dirStats(MODULES_DST);
if (moduleStats.files < 500) fail(`node_modules 只有 ${moduleStats.files} 个文件，像是没装全`);

// node 版本 / ABI：直接从 Mach-O 镜像里抓（v18.20.4 这类字符串在 ~42 MB 处，
// 只扫前 8 MB 会漏；ABI 用 node_register_module_vNNN 这个导出符号名判定）。
const nodeStr = readFileSync(NODE_DST, { encoding: 'latin1' });
const nodeVersionMatch = /\bv(\d{1,2}\.\d{1,2}\.\d{1,2})\x00/.exec(nodeStr);
const nodeVersion = nodeVersionMatch ? 'v' + nodeVersionMatch[1] : 'unknown';
const abiMatch = /node_register_module_v(\d+)/.exec(nodeStr);
const nodeAbi = abiMatch ? Number(abiMatch[1]) : 0;
if (nodeVersion === 'unknown') fail('抓不到 node 版本串（是 node 可执行吗？）');
if (nodeAbi !== 108) fail(`node ABI = ${nodeAbi || '未知'}，但原生模块是按 ABI 108（Node 18 系）编的 ⇒ 必须重新交叉编译`);
// 原生模块必须真的导出 node_register_module_v108
const bindStr = readFileSync(BINDING_DST, { encoding: 'latin1' });
if (!bindStr.includes('node_register_module_v108')) fail('原生模块里没有 node_register_module_v108 符号 ⇒ 不是给 Node 18 编的');

const manifest = {
  schemaVersion: 1,
  kind: 'spcn-ios-runtime',
  builtAt: new Date().toISOString(),
  target: { platform: 'ios', arch: 'arm64', minOS: '14.0', kind: 'jailbroken-or-sideloaded' },
  node: {
    path: 'node-ios-arm64/node',
    version: nodeVersion,
    sha256: sha256(NODE_DST),
    bytes: nodeBytes,
    // Node 18 = ABI(modules) 108 ⇒ 原生模块必须导出 node_register_module_v108
    abi: nodeAbi,
  },
  nativeBinding: {
    path: 'node_modules/better-sqlite3/build/Release/better_sqlite3.node',
    sha256: sha256(BINDING_DST),
    bytes: bindingBytes,
    note: '用 theos 工具链（clang 11.1.0 + iPhoneOS16.5.sdk）对 node-v18.20.4 头文件交叉编译；'
        + '导出 node_register_module_v108，undefined 走 dynamic_lookup（不链接 libnode）',
  },
  serverBundle: {
    path: 'server-bundle',
    name: smFinal.name,
    version: smFinal.serverVersion,
    bundleId: smFinal.bundleId,
    entry: smFinal.entry,
    files: bundleStats.files,
    bytes: bundleStats.bytes,
  },
  modules: { path: 'node_modules', files: moduleStats.files, bytes: moduleStats.bytes },
  totals: { files: bundleStats.files + moduleStats.files + 2, bytes: nodeBytes + bundleStats.bytes + moduleStats.bytes },
};
writeFileSync(path.join(OUT, 'spcn-runtime.json'), JSON.stringify(manifest, null, 2) + '\n');

log('== 产物校验 ==');
log(`  node          ${manifest.node.version}  ${nodeBytes} B  sha256=${manifest.node.sha256.slice(0, 16)}…`);
log(`  原生模块       ${bindingBytes} B  sha256=${manifest.nativeBinding.sha256.slice(0, 16)}…`);
log(`  server-bundle ${bundleStats.files} 文件 / ${(bundleStats.bytes / 1048576).toFixed(1)} MB  ${smFinal.name}@${smFinal.serverVersion}`);
log(`  node_modules  ${moduleStats.files} 文件 / ${(moduleStats.bytes / 1048576).toFixed(1)} MB`);
log(`  合计          ${manifest.totals.files} 文件 / ${(manifest.totals.bytes / 1048576).toFixed(1)} MB`);
log(`  清单          ${path.join(OUT, 'spcn-runtime.json')}`);
console.log('OK  SpCnRuntime 组装完成');
