#!/usr/bin/env node
// World Flipper CN iOS (AIR AOT) IPA patcher — the iOS analog of patch-apk.mjs.
//
// iOS is AOT: the AS3 (DevConfig.sdkDummy / DevConfig_gf_ios.apiServer / FileReader)
// is compiled into the native Mach-O, so FFDec -replace can't be used. Instead we
// redirect the client by binary-patching the embedded endpoint URL string CONSTANTS
// in the Mach-O to point at the local server (scheme https->http, host->HOST:PORT),
// in place, null-padded to the original length. This baked-in redirect is the CN
// philosophy (patch the client, no proxy/wireguard).
//
//   https://<x>.leiting.com<path>   ->   http://HOST:PORT<path>\0...   (if it fits)
//
// The game API host is NOT patched directly — it flows from the patched
// update.leiting.com -> version.dis (served locally) -> local apiPath. Login goes to
// the local server's leiting mock. Missing-asset (FileReader) crash is avoided by the
// launcher serving the full CDN, not a code patch.
//
// After patching, the Mach-O signature is invalid — the IPA MUST be re-signed
// (Sideloadly with the user's Apple ID does this on install; it re-hashes the patched
// binary). cryptid=0 (decrypted dump) confirms re-signing is viable.
//
// Usage: node patch-ipa.mjs --ipa=in.ipa --host=192.168.x.x --port=8001 --out=out.ipa
//        node patch-ipa.mjs --bin=worldflipper --host=... --port=... --out=patched.bin   (test mode)
//
// ═══ spcntweak 说明（本文件是 vendored 改造版，来源 startpoint-cn-launcher/tools/patch-ipa.mjs）═══
// 上游用途：把客户端端点改成局域网 PC 上的服务端（--host 必填）。
// 本仓库用途：**单机集成** —— 服务端就在同一台手机上，端点固定回环 ⇒ --host 缺省 127.0.0.1、
// --port 缺省 8001。除「缺省值」与「主二进制自动嗅探」两处，其余逻辑（AIR 常量池等长改写、6 处站点
// 补丁、防重签 guard NOP、zip 元数据保真）一字未改 —— 那些都是踩过黑屏/装不上的坑换来的。
// 完整流水线见 tools/build-ipa.mjs：pack-ipa → vendor/inject-dylib → embed-runtime。

import { existsSync, readFileSync, writeFileSync, copyFileSync, mkdirSync, rmSync } from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { deflateRawSync, inflateRawSync } from 'node:zlib';

// ── Minimal, dependency-free ZIP engine ───────────────────────────────────────
// The old repack used the bundled JDK `jar`; `jar uf0` rewrote the Mach-O entry as
// STORED with a FAT/MSDOS host and DROPPED the Unix exec-permission bit. Sideloadly
// tolerates that, but AltStore/AltServer's stricter IPA parser rejects it outright with
// "The app is in an invalid format." This engine rebuilds the archive preserving every
// untouched entry's raw compressed bytes + attributes VERBATIM, and re-deflates only the
// patched Mach-O while KEEPING its original externalAttr/versionMadeBy (host=osx,
// rwxr-xr-x) — so the repacked IPA installs on BOTH Sideloadly and AltStore.
const CRC = (() => { const t = new Uint32Array(256); for (let n = 0; n < 256; n++) { let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xEDB88320 ^ (c >>> 1) : c >>> 1; t[n] = c >>> 0; } return t; })();
function crc32(b) { let c = 0xFFFFFFFF; for (let i = 0; i < b.length; i++) c = CRC[(c ^ b[i]) & 0xFF] ^ (c >>> 8); return (c ^ 0xFFFFFFFF) >>> 0; }
function readZip(buf) {
  let eocd = -1;
  for (let i = buf.length - 22; i >= 0 && i > buf.length - 22 - 65536; i--) { if (buf.readUInt32LE(i) === 0x06054b50) { eocd = i; break; } }
  if (eocd < 0) throw new Error('ZIP EOCD not found');
  const total = buf.readUInt16LE(eocd + 10); let cd = buf.readUInt32LE(eocd + 16); const entries = [];
  for (let n = 0; n < total; n++) {
    if (buf.readUInt32LE(cd) !== 0x02014b50) throw new Error('bad central dir @' + cd);
    const versionMadeBy = buf.readUInt16LE(cd + 4), method = buf.readUInt16LE(cd + 10);
    const mtime = buf.readUInt16LE(cd + 12), mdate = buf.readUInt16LE(cd + 14);
    const crc = buf.readUInt32LE(cd + 16), csize = buf.readUInt32LE(cd + 20), usize = buf.readUInt32LE(cd + 24);
    const nameLen = buf.readUInt16LE(cd + 28), extraLen = buf.readUInt16LE(cd + 30), commentLen = buf.readUInt16LE(cd + 32);
    const externalAttr = buf.readUInt32LE(cd + 38), lho = buf.readUInt32LE(cd + 42);
    const name = buf.toString('latin1', cd + 46, cd + 46 + nameLen);
    const lnameLen = buf.readUInt16LE(lho + 26), lextraLen = buf.readUInt16LE(lho + 28);
    const dataStart = lho + 30 + lnameLen + lextraLen;
    entries.push({ name, method, mtime, mdate, crc, csize, usize, versionMadeBy, externalAttr, cdata: buf.subarray(dataStart, dataStart + csize) });
    cd += 46 + nameLen + extraLen + commentLen;
  }
  return entries;
}
function writeZip(entries) {
  const locals = [], centrals = []; let offset = 0;
  for (const e of entries) {
    const name = Buffer.from(e.name, 'latin1');
    const lh = Buffer.alloc(30);
    lh.writeUInt32LE(0x04034b50, 0); lh.writeUInt16LE(20, 4); lh.writeUInt16LE(0, 6);
    lh.writeUInt16LE(e.method, 8); lh.writeUInt16LE(e.mtime, 10); lh.writeUInt16LE(e.mdate, 12);
    lh.writeUInt32LE(e.crc, 14); lh.writeUInt32LE(e.csize, 18); lh.writeUInt32LE(e.usize, 22);
    lh.writeUInt16LE(name.length, 26); lh.writeUInt16LE(0, 28);
    locals.push(lh, name, e.cdata);
    const ch = Buffer.alloc(46);
    ch.writeUInt32LE(0x02014b50, 0); ch.writeUInt16LE(e.versionMadeBy, 4); ch.writeUInt16LE(20, 6);
    ch.writeUInt16LE(0, 8); ch.writeUInt16LE(e.method, 10); ch.writeUInt16LE(e.mtime, 12); ch.writeUInt16LE(e.mdate, 14);
    ch.writeUInt32LE(e.crc, 16); ch.writeUInt32LE(e.csize, 20); ch.writeUInt32LE(e.usize, 24);
    ch.writeUInt16LE(name.length, 28); ch.writeUInt16LE(0, 30); ch.writeUInt16LE(0, 32);
    ch.writeUInt16LE(0, 34); ch.writeUInt16LE(0, 36); ch.writeUInt32LE(e.externalAttr, 38); ch.writeUInt32LE(offset, 42);
    centrals.push(ch, name);
    offset += 30 + name.length + e.cdata.length;
  }
  const localBuf = Buffer.concat(locals), centralBuf = Buffer.concat(centrals);
  const eocd = Buffer.alloc(22);
  eocd.writeUInt32LE(0x06054b50, 0); eocd.writeUInt16LE(entries.length, 8); eocd.writeUInt16LE(entries.length, 10);
  eocd.writeUInt32LE(centralBuf.length, 12); eocd.writeUInt32LE(localBuf.length, 16);
  return Buffer.concat([localBuf, centralBuf, eocd]);
}

const args = Object.fromEntries(process.argv.slice(2).map(a => {
  const m = a.match(/^--([^=]+)=(.*)$/); return m ? [m[1], m[2]] : [a.replace(/^--/, ''), true];
}));
// 单机集成 ⇒ 端点缺省回环 127.0.0.1:8001（服务端就在同一台手机上）。
const HOST = args.host || '127.0.0.1', PORT = args.port || '8001', OUT = args.out;
const GUARD_MODE = args['guard-mode'] || 'all';      // launch|all|none (default: every guard — 'launch'
                                                     // alone leaves the other abort sites live, which
                                                     // crashes multi-instance installs)
const fail = m => { console.log('ERROR ' + m); process.exit(1); };
if (!HOST || !PORT || !OUT || (!args.ipa && !args.bin)) fail('需要 --ipa(或 --bin) --host --port --out');

const HOST_PORT = `${HOST}:${PORT}`;                // e.g. 192.168.68.103:8001
const TARGET = `http://${HOST_PORT}`;               // replacement scheme+authority (e.g. 26 bytes)
const HOST_RE = /https?:\/\/[A-Za-z0-9.-]+\.(?:leiting\.com|roguelike\.com|cl2009\.com)(?::\d+)?/;
// optional whitelist: only redirect URLs whose host contains one of these substrings
const HOSTS = args.hosts ? String(args.hosts).split(',').filter(Boolean) : null;

// Redirect every leiting/roguelike/cl2009 endpoint in the Mach-O by replacing ONLY the
// authority (scheme://host[:port]) in place, padded to the EXACT original authority length.
//
// WHY authority-only + same-length (the load-black fix): the URLs live in two storage forms —
// (a) null-terminated C-strings, and (b) AIR's SEQUENTIAL length-prefixed constant pool, where
// pooled strings sit back-to-back each preceded by a u30 length byte (e.g. update.leiting.com is
// followed immediately by [0x0e]"onQuerySuccess"...). The old patcher SHORTENED the string and
// rewrote buf[off-1]; for a pooled string that shifts everything downstream AND desyncs the
// sequential parser (it then reads the next string's length from the wrong offset) → the whole
// pool corrupts → AIR content-load THROWS → black screen before any network request. The
// buf[off-1] heuristic also false-positives on any preceding data byte that equals the length.
// By overwriting exactly authLen bytes and never shifting/padding/prefix-touching, the pool stays
// byte-for-byte in sync and C-strings are equally valid. Length is preserved via userinfo padding
// (http://0000@host:port/...), which the server ignores and which is safe before a path (so base
// URLs that the client concatenates onto still resolve to host:port).
function patchBuffer(buf) {
  const s = buf.toString('latin1');
  const re = new RegExp(HOST_RE.source, 'g');        // AUTHORITY ONLY — never the greedy path
  let m, patched = 0, skipped = [], seen = new Set();
  while ((m = re.exec(s))) {
    const auth = m[0], off = m.index;
    if (HOSTS && !HOSTS.some(h => auth.includes(h))) continue;   // whitelist: skip non-listed hosts
    const authLen = Buffer.byteLength(auth, 'latin1');
    const deficit = authLen - TARGET.length;         // spare bytes to absorb via userinfo padding
    if (deficit < 0) {                               // target authority longer than original → would shift, skip
      const host = auth.replace(/^https?:\/\//, '');
      if (!seen.has(host)) { skipped.push(`${host} (auth ${authLen} < ${TARGET.length})`); seen.add(host); }
      continue;
    }
    // Build a replacement authority of EXACTLY authLen bytes. deficit==0 → plain TARGET; else pad
    // userinfo: "http://" + (deficit-1 filler) + "@" + HOST_PORT  ⇒ 7 + deficit + len(HOST_PORT) = authLen.
    const paddedAuth = deficit === 0 ? TARGET
      : `http://${'0'.repeat(deficit - 1)}@${HOST_PORT}`;
    Buffer.from(paddedAuth, 'latin1').copy(buf, off);   // overwrite authority in place — same length, nothing shifts
    patched++;
  }
  return { patched, skipped };
}

// Block non-redirectable external hosts (e.g. pv.sohu.com IP-geo lookup — its authority is too
// short to same-length-rewrite to our LAN server). Rewrite the authority to a dead loopback of
// the SAME length → the on-device request gets ECONNREFUSED → the SDK falls back to a default →
// ZERO external traffic leaves the phone. Fully local/offline guarantee.
const BLOCK_RE = /https?:\/\/[A-Za-z0-9.-]+\.sohu\.com(?::\d+)?/;
const DEAD_HOST_PORT = '127.0.0.1:1';              // nothing listens on :1 → fast connection-refused
const DEAD_TARGET = `http://${DEAD_HOST_PORT}`;    // 18 bytes
function patchBlock(buf) {
  const s = buf.toString('latin1');
  const re = new RegExp(BLOCK_RE.source, 'g');
  let m, blocked = 0, hosts = new Set();
  while ((m = re.exec(s))) {
    const auth = m[0], off = m.index, authLen = Buffer.byteLength(auth, 'latin1');
    const deficit = authLen - DEAD_TARGET.length;
    if (deficit < 0) continue;                       // sohu authority is always >= 18
    const padded = deficit === 0 ? DEAD_TARGET : `http://${'0'.repeat(deficit - 1)}@${DEAD_HOST_PORT}`;
    Buffer.from(padded, 'latin1').copy(buf, off);    // same length, nothing shifts
    blocked++; hosts.add(auth.replace(/^https?:\/\//, ''));
  }
  return { blocked, hosts: [...hosts] };
}

// Neutralize the app's deliberate "fatal abort" idiom that crashes a RE-SIGNED build at
// launch (integrity/entitlement guards). Pattern: MOVZ X8,#0 (0xd2800008) then within 3
// words a store to [X8] (writing 0xDEADBEEF to address 0 = intentional crash, since page 0
// is never mapped on iOS). We NOP the store so the abort becomes a no-op and execution
// continues. Only matches stores to a JUST-ZEROED X8 → never touches a legitimate store.
// mode: 'launch' = NOP only the launch-timer guard at file 0xb00c (minimal, proven to keep
//        AIR content-load intact); 'all' = NOP every safe-fall-through abort; 'none' = skip.
function deguardBuffer(buf, mode) {
  if (mode === 'none') return 0;
  if (mode === 'launch') {                    // only the launch guard — avoid disturbing content-load
    if (buf.readUInt32LE(0xb00c) === 0xb9000109) { buf.writeUInt32LE(0xd503201f, 0xb00c); return 1; }
    return 0;
  }
  const NOP = 0xd503201f, RET = 0xd65f03c0; let n = 0, skipped = 0; const len = buf.length & ~3;
  const isStoreToX8 = (w) => (((w >>> 5) & 31) === 8) &&
    [0xB9000000, 0xF9000000, 0x39000000, 0x79000000].includes((w & 0xFFC00000) >>> 0);
  // Only NOP an abort whose fall-through is SAFE: a RET (or unconditional B) appears within a few
  // words after the store. NOPping an abort with code after it would run that code with the bad
  // state the abort guarded against — risking exactly the black-screen we're chasing.
  const safeFallthrough = (strOff) => {
    for (let j = 1; j <= 6; j++) {
      const w = buf.readUInt32LE(strOff + 4 * j);
      if (w === RET) return true;
      if ((w & 0xFC000000) >>> 0 === 0x14000000) return true;   // B (tail branch)
      if ((w >>> 24) === 0xa8 || (w >>> 24) === 0xa9) continue;  // LDP epilogue → keep scanning
    }
    return false;
  };
  for (let o = 0; o + 28 <= len; o += 4) {
    if (buf.readUInt32LE(o) !== 0xd2800008) continue;       // MOVZ X8,#0
    for (let k = 1; k <= 3; k++) {
      const w = buf.readUInt32LE(o + 4 * k);
      if (isStoreToX8(w)) {
        if (safeFallthrough(o + 4 * k)) { buf.writeUInt32LE(NOP, o + 4 * k); n++; }
        else skipped++;
        break;
      }
      if ((w & 31) === 8) break;                            // X8 reloaded → not a null-store
    }
  }
  if (skipped) console.log(`  (skipped ${skipped} abort sites with unsafe fall-through — left intact)`);
  return n;
}

// Suppress the Leiting first-login real-name notice (实名提示 / FirstLoginTipsView).
// LTLoginManager -shouldShowFirstLoginTip is a BOOL predicate gating the notice; force it to
// return NO (mov w0,#0 ; ret) so the SDK skips the notice and continues straight to the game.
// Guarded by the method's prologue signature (stp x22,x21,[sp,#-0x30]! = 0xa9bd57f6) so a
// binary change can't corrupt the wrong site — mismatch => skip, leave bytes intact.
function patchFirstLoginTip(buf) {
  const OFF = 0x6ae0dc;
  if (OFF + 8 > buf.length || buf.readUInt32LE(OFF) !== 0xa9bd57f6) return 0;
  buf.writeUInt32LE(0x52800000, OFF);       // mov w0, #0
  buf.writeUInt32LE(0xd65f03c0, OFF + 4);   // ret
  return 1;
}

// Skip the Leiting login dialog on a FRESH install (no stored credential). The SDK's login
// decision (sub @0x68e7xx) shows the dialog (homeViewWithCallbackCancel:) when the stored token
// is nil / empty / "(null)"; otherwise it takes the auto-login path (checkLogin:callback:), which
// our mock server accepts for any credential. NOP the 3 dialog-jump branches so a fresh launch
// falls through to auto-login → guest login succeeds with no dialog. Verified in-memory: fresh
// state reaches handleLoginSuccess, no dialog, no crash. SAFE for the normal (valid-token) case:
// those branches never fire when a real token exists, so NOPping them changes nothing there.
// Each site is signature-guarded (cbz/cbnz encoding) so a binary change can't corrupt the wrong word.
function patchLoginDialog(buf) {
  const NOP = 0xd503201f;
  const sites = [[0x68e878, 0xb4000820], [0x68e898, 0xb40006a0], [0x68e8d8, 0x35000538]];
  let n = 0;
  for (const [off, want] of sites) {
    if (off + 4 <= buf.length && buf.readUInt32LE(off) === want) { buf.writeUInt32LE(NOP, off); n++; }
  }
  return n;   // 3 = fully applied
}

// Suppress the Leiting post-login welcome banner ("…，欢迎入园。" floating toast that briefly shows
// the masked account name after every login). frida discovery (probe-discover-ui.js) proved the
// banner that ACTUALLY fires is drawn by the INSTANCE method -[LTLoginManager showWelcomeView:]
// (rva 0x6adb14), which dispatches a block that calls +[LTWelcomeView showMoleWelcomeView:] to build
// it. (An earlier attempt patched the same-named CLASS method +[LTWelcomeView showWelcomeView:]
// @0x64b238 — WRONG object, no effect.) All three sites are cosmetic, side-effect-only, and do NOT
// gate progression; each is signature-guarded.
function patchWelcomeBanner(buf) {
  let n = 0;
  // (1) THE real one: stub -[LTLoginManager showWelcomeView:] entry -> return nil (sub sp,#0x50 = 0xd10143ff)
  const MAIN = 0x6adb14;
  if (MAIN + 8 <= buf.length && buf.readUInt32LE(MAIN) === 0xd10143ff) {
    buf.writeUInt32LE(0xd2800000, MAIN);      // mov x0, #0
    buf.writeUInt32LE(0xd65f03c0, MAIN + 4);  // ret
    n++;
  }
  // (2) also stub +[LTWelcomeView showWelcomeView:] (sub sp,#0x1c0 = 0xd10703ff) — a second banner
  // path; harmless defense-in-depth.
  const CLS = 0x64b238;
  if (CLS + 8 <= buf.length && buf.readUInt32LE(CLS) === 0xd10703ff) {
    buf.writeUInt32LE(0xd2800000, CLS);       // mov x0, #0
    buf.writeUInt32LE(0xd65f03c0, CLS + 4);   // ret
    n++;
  }
  // (3) NOP the +[LTWelcomeView showWelcomeView:] call in the login-success path (0x634890).
  const CALL = 0x634890;
  if (CALL + 4 <= buf.length && buf.readUInt32LE(CALL) === 0x9546daf4) {
    buf.writeUInt32LE(0xd503201f, CALL);      // nop
    n++;
  }
  return n;   // 3 = all applied
}

// Skip the Leiting agreement dialogs on first install so the game enters straight away.
// (A) EULA / 使用许可协议 (class ShowProtocolView, shown post-login by -showLicenseView:callbackBean:
//     @0x6c6c78). Its decision at 0x6c6cfc already has a branch to the "already-agreed" skip target
//     0x6c6ddc (which calls the same -showNoticeTip:callbackBean: continuation as the post-agree
//     callback). Force that branch unconditional (tbnz→b) → always take the already-agreed path.
//     DEVICE-VERIFIED: EULA no longer appears, game proceeds.
// (B) 隐私政策 popup (class ProtocolPrivacyPopView, shown first by native AS3-AOT show-funcs
//     @0x68dd30 & @0x698b08 via -initWithType:). Stub both show-funcs to `mov x0,#0 ; ret` so the
//     popup is never built. Both signature-guarded.
function patchAgreementDialogs(buf) {
  let n = 0;
  // (A) EULA gate: 0x6c6cfc tbnz w0,#0,0x6c6ddc (0x37000700) -> b 0x6c6ddc (0x14000038).
  //     Gated behind --agreement while we confirm it isn't what broke the standalone build's
  //     boot networking (ResVer.null / no server requests). Default OFF for a safe working build.
  const EULA = 0x6c6cfc;
  if (PATCH_AGREEMENT && EULA + 4 <= buf.length && buf.readUInt32LE(EULA) === 0x37000700) { buf.writeUInt32LE(0x14000038, EULA); n++; }
  // (B) privacy popup (ProtocolPrivacyPopView). SAFE approach = patch the "should I show privacy?"
  //     GATE predicates to return NO (already-agreed / returning-user path) so the caller never calls
  //     the show-funcs (0x68dd30/0x698b08) — which also register the boot observer/view-stack, so
  //     stubbing THEM broke boot networking. Returning NO from the gate = returning-user behavior
  //     (boots fine). Two BOOL predicates (prologue stp x20,x19,[sp,#-0x20]! = 0xa9be4ff4):
  //     -[LeitingSDK needShowPrivacy]@0x698990 and +[GDPRManage needShowPrivacyProtocolView]@0x60f15c.
  //     Gated behind --privacy until full-flow validated on the STANDALONE build.
  if (PATCH_PRIVACY) {
    for (const off of [0x698990, 0x60f15c]) {
      if (off + 8 <= buf.length && buf.readUInt32LE(off) === 0xa9be4ff4) {
        buf.writeUInt32LE(0x52800000, off);      // mov w0, #0  (return NO)
        buf.writeUInt32LE(0xd65f03c0, off + 4);  // ret
        n++;
      }
    }
  }
  return n;   // 0 = no agreement; 1 = EULA; 3 = EULA + both privacy gates (--privacy)
}
// EULA skip (0x6c6cfc) is DEVICE-VERIFIED SAFE on the standalone build (game enters full-flow),
// so it is default-ON. Pass --agreement=false to disable. Privacy stub stays default-OFF (it broke
// boot networking — see patchAgreementDialogs note).
const PATCH_AGREEMENT = args['agreement'] !== 'false' && args['agreement'] !== false;
// Privacy GATE approach (needShowPrivacy/needShowPrivacyProtocolView -> NO) is DEVICE-VERIFIED SAFE
// on the standalone build (full-flow: no privacy popup, game enters). Default-ON. --privacy=false to disable.
const PATCH_PRIVACY = args['privacy'] !== 'false' && args['privacy'] !== false;

// AIR's Mach-O parser resolves bundled resources through a CFBundleIdentifier check. Changing
// CFBundleIdentifier (needed to side-install a second copy alongside the first) makes that check
// fail and the app aborts. NOP the checker to `return 0`. The prologue signature is verified first
// (STP X28,X27,[SP,#-0x30]! = 0xa9bd6ffc), so on any binary where the offset does not match this
// is a no-op rather than a blind overwrite.
function patchBundleIdCheck(buf) {
  const OFF = 0x312230;
  if (OFF + 16 > buf.length || buf.readUInt32LE(OFF) !== 0xa9bd6ffc) return 0;
  buf.writeUInt32LE(0xd2800000, OFF);       // mov x0, #0
  buf.writeUInt32LE(0xd65f03c0, OFF + 4);   // ret
  buf.writeUInt32LE(0xd503201f, OFF + 8);   // nop
  buf.writeUInt32LE(0xd503201f, OFF + 12);  // nop
  return 1;
}

// 主二进制路径：默认官方那条；--macho 覆盖，找不到时按 `Payload/<X>.app/<X>` 约定自动嗅探。
const MACHO_REL = args.macho || 'Payload/worldflipper.app/worldflipper';
function findMainMacho(entries) {
  const cands = entries.filter(e => /^Payload\/[^/]+\.app\/[^/]+$/.test(e.name));
  for (const e of cands) {
    const parts = e.name.split('/');
    if (parts[2] === parts[1].replace(/\.app$/, '')) return e;
  }
  return null;
}

if (args.bin) {
  // test mode: patch a raw extracted Mach-O
  const buf = readFileSync(args.bin);
  const r = patchBuffer(buf);
  const blk = patchBlock(buf);
  const guards = deguardBuffer(buf, GUARD_MODE);
  const tip = patchFirstLoginTip(buf);
  const dlg = patchLoginDialog(buf);
  const wel = patchWelcomeBanner(buf);
  const agr = patchAgreementDialogs(buf);
  const bid = patchBundleIdCheck(buf);
  if (blk.blocked) console.log(`blocked ${blk.blocked} external request(s) -> dead loopback (zero external): ${blk.hosts.join(', ')}`);
  console.log(tip ? '  suppressed 实名提示 (shouldShowFirstLoginTip -> NO)' : '  [!] 实名提示 patch site signature mismatch — skipped');
  console.log(dlg === 3 ? '  skipped login dialog on fresh install (force auto-login, 3/3 branches NOPed)' : `  [!] login-dialog patch only ${dlg}/3 branches matched — skipped`);
  console.log(wel === 3 ? '  suppressed 欢迎入园 welcome banner (LTLoginManager showWelcomeView: + 2 extra, 3/3)' : `  [!] welcome-banner patch only ${wel}/3 sites matched — skipped`);
  console.log(agr===0 ? '  agreement dialogs LEFT INTACT (default; use --agreement / --privacy to strip)' : ('  skipped 使用许可协议 EULA' + (agr>=3 ? ' + 隐私政策 popup' : '') + ` [${agr} site(s)]`));
  console.log(bid ? '  bundle-ID resource check -> return 0 (safe to change CFBundleIdentifier for a second install)' : '  [!] bundle-ID check patch site signature mismatch — skipped');
  if (args['crash-longjmp'] && buf.readUInt32LE(0x57d834c) === 0xb0005190) { buf.writeUInt32LE(0xd4200000, 0x57d834c); console.log('  [diag] _longjmp stub -> BRK (AS3 throws now crash -> .ips backtrace = throw site)'); }
  writeFileSync(OUT, buf);
  console.log(`patched ${r.patched} URL constants -> ${TARGET}`);
  console.log(`neutralized ${guards} deliberate-abort guards (0xDEADBEEF null-write)`);
  if (r.skipped.length) console.log(`skipped (too long, ${r.skipped.length}): ` + r.skipped.slice(0, 12).join(', '));
  console.log('DONE ' + OUT);
} else {
  // full IPA mode: pure-Node zip surgery — no external tools (no JDK `jar`). Read the IPA,
  // inflate the one Mach-O entry, patch it, re-deflate, and rebuild the archive keeping every
  // other entry's raw compressed bytes + attributes VERBATIM. The patched Mach-O re-uses its
  // ORIGINAL entry attributes (host=osx, rwxr-xr-x), so the exec bit survives — this is what
  // makes the result install on AltStore (jar's STORED/FAT/no-exec-bit output did not; see the
  // ZIP-engine note near the top of this file).
  const TOTAL = 3; let step = 0;
  const progress = (label) => console.log(`STEP ${++step}/${TOTAL} ${label}`);
  progress('讀取 IPA');
  const zbuf = readFileSync(args.ipa);
  const entries = readZip(zbuf);
  const exe = entries.find(e => e.name === MACHO_REL) || findMainMacho(entries);
  if (!exe) fail('IPA 內找不到 Mach-O：' + MACHO_REL);
  console.log('  主二进制：' + exe.name + `  (${(exe.usize / 1048576).toFixed(1)} MB, method=${exe.method})`);
  progress('改寫端點 URL + 解除防重簽 guard');
  const buf = exe.method === 8 ? inflateRawSync(exe.cdata) : Buffer.from(exe.cdata);
  const r = patchBuffer(buf);
  const blk = patchBlock(buf);
  const guards = deguardBuffer(buf, GUARD_MODE);
  const tip = patchFirstLoginTip(buf);
  const dlg = patchLoginDialog(buf);
  const wel = patchWelcomeBanner(buf);
  const agr = patchAgreementDialogs(buf);
  const bid = patchBundleIdCheck(buf);
  if (blk.blocked) console.log(`blocked ${blk.blocked} external request(s) -> dead loopback (zero external): ${blk.hosts.join(', ')}`);
  console.log(tip ? '  suppressed 实名提示 (shouldShowFirstLoginTip -> NO)' : '  [!] 实名提示 patch site signature mismatch — skipped');
  console.log(dlg === 3 ? '  skipped login dialog on fresh install (force auto-login, 3/3 branches NOPed)' : `  [!] login-dialog patch only ${dlg}/3 branches matched — skipped`);
  console.log(wel === 3 ? '  suppressed 欢迎入园 welcome banner (LTLoginManager showWelcomeView: + 2 extra, 3/3)' : `  [!] welcome-banner patch only ${wel}/3 sites matched — skipped`);
  console.log(agr===0 ? '  agreement dialogs LEFT INTACT (default; use --agreement / --privacy to strip)' : ('  skipped 使用许可协议 EULA' + (agr>=3 ? ' + 隐私政策 popup' : '') + ` [${agr} site(s)]`));
  console.log(bid ? '  bundle-ID resource check -> return 0 (safe to change CFBundleIdentifier for a second install)' : '  [!] bundle-ID check patch site signature mismatch — skipped');
  if (args['crash-longjmp'] && buf.readUInt32LE(0x57d834c) === 0xb0005190) { buf.writeUInt32LE(0xd4200000, 0x57d834c); console.log('  [diag] _longjmp stub -> BRK (AS3 throws now crash -> .ips backtrace = throw site)'); }
  console.log(`patched ${r.patched} URL constants -> ${TARGET}`);
  console.log(`neutralized ${guards} deliberate-abort guards (0xDEADBEEF null-write)`);
  if (r.skipped.length) console.log(`skipped (${r.skipped.length} non-critical, too short): ` + r.skipped.slice(0, 8).join(', '));
  progress('重組 IPA');
  const def = deflateRawSync(buf, { level: 6 });          // re-deflate the patched Mach-O
  exe.method = 8; exe.usize = buf.length; exe.csize = def.length; exe.crc = crc32(buf); exe.cdata = def;
  // exe.externalAttr / exe.versionMadeBy are kept from the original entry → Unix host + rwxr-xr-x preserved.
  writeFileSync(OUT, writeZip(entries));
  console.log(`DONE ${OUT}  (host=${HOST}:${PORT}; 重簽: Sideloadly / AltStore 用你的 Apple ID 安裝時會重新簽名 patch 後的二進位)`);
}
