#!/usr/bin/env bash
# push-runtime-files.sh —— 把本地 runtime/SpCnRuntime 下的若干文件推到设备上已安装的 App 里（免重装）。
# 用法：bash tools/push-runtime-files.sh [host] [pass] [--kill] rel1 rel2 ...
#   rel 形如 server-bundle/out/lib/bind-gate.js（相对 runtime/SpCnRuntime）
# 注意：覆盖 Frameworks/*.dylib 前必须先 killall（否则半截文件会让进程 dyld 崩），本脚本只推数据文件。
set -uo pipefail
HOST="${1:-192.168.0.100}"; PASS="${2:-qweasd}"; shift 2 || true
KILL=0
if [ "${1:-}" = "--kill" ]; then KILL=1; shift; fi
ROOT=/mnt/d/spcntweak
RUNTIME="$ROOT/runtime/SpCnRuntime"
SSHOPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=8 -o PreferredAuthentications=password,keyboard-interactive,publickey"
SSH="sshpass -p $PASS ssh $SSHOPTS root@$HOST"
SCP="sshpass -p $PASS scp $SSHOPTS"
BID="${EXPECT_ID:-com.leiting.wf}"

APP=$($SSH "for p in /var/containers/Bundle/Application/*/worldflipper.app; do
    if [ -f \"\$p/Info.plist\" ] && grep -aq '$BID' \"\$p/Info.plist\" 2>/dev/null; then echo \"\$p\"; break; fi
  done" </dev/null | tr -d '\r')
APP=$(printf '%s\n' "$APP" | head -1)
[ -n "$APP" ] || { echo "找不到 bundle id=$BID 的 App 包" >&2; exit 1; }
echo "目标 App：$APP"

for rel in "$@"; do
  src="$RUNTIME/$rel"
  [ -f "$src" ] || { echo "  跳过（本地没有）：$rel" >&2; continue; }
  dst="$APP/SpCnRuntime/$rel"
  dir=$(dirname "$rel")
  $SSH "mkdir -p '$APP/SpCnRuntime/$dir'" </dev/null 2>/dev/null
  if $SCP "$src" "root@$HOST:$dst" </dev/null >/dev/null 2>&1; then
    $SSH "chown mobile:mobile '$dst'; ls -l '$dst'" </dev/null | tr -d '\r' | sed 's/^/  /'
  else
    echo "  ✗ 推送失败：$rel" >&2
  fi
done

if [ "$KILL" = "1" ]; then
  echo "== killall worldflipper（下次启动重新加载）=="
  $SSH "killall -9 worldflipper 2>/dev/null; echo done" </dev/null | tr -d '\r'
fi
