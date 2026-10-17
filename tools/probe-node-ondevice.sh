#!/usr/bin/env bash
# probe-node-ondevice.sh —— 在设备上直接跑自带的 node，问清楚能力（ICU / TextDecoder / util 可写性 / Intl）。
# 用途：nodejs-mobile 系二进制是 --with-intl=none 编出来的（无 ICU），服务端用了 TextDecoder(...,{fatal:true})
# ⇒ 必须先确认设备上到底支持什么，再决定兜底策略。
#
# 用法：bash tools/probe-node-ondevice.sh --host 192.168.0.100 --pass qweasd [--bundle com.testdj.wf]
set -uo pipefail

HOST=""; USER_NAME="root"; PASS=""; BID="com.testdj.wf"
while [ $# -gt 0 ]; do
  case "$1" in
    --host) HOST="${2:-}"; shift 2;;
    --user) USER_NAME="${2:-}"; shift 2;;
    --pass) PASS="${2:-}"; shift 2;;
    --bundle) BID="${2:-}"; shift 2;;
    *) echo "未知参数：$1"; exit 2;;
  esac
done
[ -n "$HOST" ] || { echo "需要 --host <设备IP> [--pass <密码>]"; exit 2; }

if [ -n "$PASS" ]; then
  SSH=(sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 "$USER_NAME@$HOST")
else
  SSH=(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 "$USER_NAME@$HOST")
fi
remote() { "${SSH[@]}" "$@"; }

echo "== 找 App 包与 node =="
BUNDLE=$(remote "for d in /var/containers/Bundle/Application/*/; do p=\$(grep -A1 CFBundleIdentifier \"\$d\"*.app/Info.plist 2>/dev/null | grep -o '<string>[^<]*' | head -1 | sed 's/<string>//'); [ \"\$p\" = \"$BID\" ] && echo \"\${d%/}\"; done" | head -1)
[ -n "$BUNDLE" ] || { echo "  ✗ 找不到 $BID 的 .app"; exit 1; }
APP="$BUNDLE/worldflipper.app"
NODE="$APP/SpCnRuntime/node-ios-arm64/node"
echo "  App    $APP"
echo "  node   $NODE"
remote "ls -l '$NODE'; echo '--- ldid:'; ldid -e '$NODE' 2>&1 | head -8"

echo ""
echo "== 能力探针（node -e） =="
PROBE='console.log("version", process.version, "abi", process.versions.modules);
console.log("Intl:", typeof Intl);
try { new TextDecoder("utf-8", { fatal: true }); console.log("TextDecoder fatal: OK"); }
catch (e) { console.log("TextDecoder fatal: FAIL", e.code || e.message); }
try { console.log("TextDecoder plain:", new TextDecoder("utf-8").decode(new Uint8Array([104,105]))); }
catch (e) { console.log("TextDecoder plain: FAIL", e.code || e.message); }
try { console.log("localeCompare:", "a".localeCompare("b"), "| zh sort:", ["b","a"].sort((x,y)=>x.localeCompare(y)).join("")); }
catch (e) { console.log("localeCompare: FAIL", e.code || e.message); }
var u = require("util");
try { var old = u.TextDecoder; u.TextDecoder = "sentinel"; console.log("util.TextDecoder writable:", u.TextDecoder === "sentinel"); u.TextDecoder = old; }
catch (e) { console.log("util.TextDecoder writable: NO -", e.message); }
try { console.log("global TextDecoder writable:", (function(){ var o = globalThis.TextDecoder; globalThis.TextDecoder = "sentinel"; var ok = globalThis.TextDecoder === "sentinel"; globalThis.TextDecoder = o; return ok; })()); }
catch (e) { console.log("global TextDecoder writable: NO -", e.message); }
try { console.log("TextEncoder:", new TextEncoder().encode("hi").length); } catch (e) { console.log("TextEncoder: FAIL", e.code || e.message); }'

remote "cd '$APP/SpCnRuntime' && '$NODE' -e '$PROBE' 2>&1 | head -30"

echo ""
echo "== 顺带：服务端 bundle 里那处 fatal 站点 =="
remote "grep -n 'TextDecoder' '$APP/SpCnRuntime/server-bundle/out/content/sync/ordered-map.js' '$APP/SpCnRuntime/server-bundle/out/multi/hub/client.js' 2>/dev/null"
