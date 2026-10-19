#!/usr/bin/env bash
# push-dev-patch.sh —— 免重装快速迭代：把新编的 dylib 与修补过的 JS 直接推进已安装的 App 包里，
# 然后杀掉游戏，等用户点亮屏幕手动打开（远程 uiopen 在锁屏时拉起的进程不跑代码，实测过）。
#
# 用法：bash tools/push-dev-patch.sh [--host 192.168.0.100 | --host=…] [--pass qweasd | --pass=…] [--no-kill] [--keep-conf]
#   推送件：
#     <build>/.theos/obj/SpCnEmbedded.dylib                      -> <app>/Frameworks/SpCnEmbedded.dylib
#     runtime/SpCnRuntime/ios-entry.js                           -> <app>/SpCnRuntime/ios-entry.js
#     runtime/.../server-bundle/out/content/sync/ordered-map.js  -> <app>/SpCnRuntime/server-bundle/out/content/sync/ordered-map.js
#   并把后端偏好重置成 auto（删掉 spcn-conf.plist）—— 新逻辑会自己探测 node 能不能 exec。
set -euo pipefail

HOST=192.168.0.100
PASS=qweasd
KILL=1
ROOT=/mnt/d/spcntweak
BUILD=/home/ubuntu/spcn-build
KEEP_CONF=0
APP_OVERRIDE=""
EXPECT_ID=com.testdj.wf      # --expect-id=<id> 可改；传 any 表示不校验（例如身份已改回 com.leiting.wf 的实验）
while [ $# -gt 0 ]; do
  case "$1" in
    --host) HOST="$2"; shift 2;;
    --host=*) HOST="${1#*=}"; shift;;
    --pass) PASS="$2"; shift 2;;
    --pass=*) PASS="${1#*=}"; shift;;
    --app) APP_OVERRIDE="$2"; shift 2;;
    --app=*) APP_OVERRIDE="${1#*=}"; shift;;
    --expect-id) EXPECT_ID="$2"; shift 2;;
    --expect-id=*) EXPECT_ID="${1#*=}"; shift;;
    --no-kill) KILL=0; shift;;
    --keep-conf) KEEP_CONF=1; shift;;
    *) echo "未知参数：$1"; exit 2;;
  esac
done

SSHOPT="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
run() { sshpass -p "$PASS" ssh $SSHOPT "root@$HOST" "$@"; }
put() { sshpass -p "$PASS" scp $SSHOPT "$1" "root@$HOST:$2"; }

echo "== 1. 找目标 App 包（期望 bundle id=$EXPECT_ID）=="
# ⚠️ 不要用 ps 里「正在跑的进程路径」定位（原版游戏经常也在跑），也不要只按 bundle id 找：
#    现在两个 worldflipper.app 的 CFBundleIdentifier 都是 com.leiting.wf（AIR 的启动自检要求如此）⇒
#    **唯一可靠的判别是「这个包里有 SpCnRuntime/ios-entry.js」**。2026-10-19 22:47 就因此把 dylib 推进了原版（已清理）。
if [ -n "$APP_OVERRIDE" ]; then
  APP="$APP_OVERRIDE"
else
  APP=$(run "for p in /var/containers/Bundle/Application/*/worldflipper.app; do [ -f \"\$p/SpCnRuntime/ios-entry.js\" ] && echo \"\$p\"; done; true" | tail -1 || true)
  if [ -z "$APP" ]; then
    APP=$(run "for p in /var/containers/Bundle/Application/*/worldflipper.app; do [ -d \"\$p\" ] || continue; grep -aq \"$EXPECT_ID\" \"\$p/Info.plist\" && echo \"\$p\"; done; true" | tail -1 || true)
  fi
fi
[ -n "$APP" ] || { echo "找不到 $EXPECT_ID 的 App（是不是还没装？）"; exit 1; }
# 硬门禁：目标 App 的 CFBundleIdentifier 必须逐字等于 $EXPECT_ID，否则一律拒绝（保护原版游戏）
BID=$(run "grep -a -A2 'CFBundleIdentifier' '$APP/Info.plist' | grep -a '<string>' | head -1 | sed 's/.*<string>//; s/<\/string>.*//'" | tail -1 || true)
if [ "$EXPECT_ID" != "any" ] && [ "$BID" != "$EXPECT_ID" ]; then
  echo "拒绝：$APP"; echo "      CFBundleIdentifier=$BID（不是 $EXPECT_ID）—— 只允许改我们自己的单机包"
  echo "      确实要推这个包就加 --expect-id=$BID（或 --expect-id=any）"
  exit 1
fi
echo "  $APP   (bundle id=$BID)"
DATA=$(run 'for p in /var/mobile/Containers/Data/Application/*/; do d="$p/Documents/SpCn/data"; [ -d "$d" ] && echo "$d"; done; true' | tail -1 || true)
echo "  数据卷 $DATA"

[ -f "$BUILD/.theos/obj/SpCnEmbedded.dylib" ] || { echo "先编译：bash tools/wsl-rebuild.sh"; exit 1; }

echo "== 2. 推 dylib =="
put "$BUILD/.theos/obj/SpCnEmbedded.dylib" "$APP/Frameworks/SpCnEmbedded.dylib"
run "chown mobile:mobile '$APP/Frameworks/SpCnEmbedded.dylib' && chmod 0755 '$APP/Frameworks/SpCnEmbedded.dylib' && ls -l '$APP/Frameworks/SpCnEmbedded.dylib'"

echo "== 3. 推 ios-entry.js（ICU 兜底）="
put "$ROOT/runtime/SpCnRuntime/ios-entry.js" "$APP/SpCnRuntime/ios-entry.js"
run "chown mobile:mobile '$APP/SpCnRuntime/ios-entry.js' && chmod 0644 '$APP/SpCnRuntime/ios-entry.js' && wc -c < '$APP/SpCnRuntime/ios-entry.js'"

echo "== 4. 推 ordered-map.js（TextDecoder fatal 降级）=="
put "$ROOT/runtime/SpCnRuntime/server-bundle/out/content/sync/ordered-map.js" \
    "$APP/SpCnRuntime/server-bundle/out/content/sync/ordered-map.js"
run "chown mobile:mobile '$APP/SpCnRuntime/server-bundle/out/content/sync/ordered-map.js'; grep -c '_spcnNoIcu' '$APP/SpCnRuntime/server-bundle/out/content/sync/ordered-map.js' || true"

echo "== 4.5 推 lifecycle.js（启动失败诊断补丁）=="
put "$ROOT/runtime/SpCnRuntime/server-bundle/out/runtime/lifecycle.js" \
    "$APP/SpCnRuntime/server-bundle/out/runtime/lifecycle.js"
run "chown mobile:mobile '$APP/SpCnRuntime/server-bundle/out/runtime/lifecycle.js'; grep -c 'spcn-diag' '$APP/SpCnRuntime/server-bundle/out/runtime/lifecycle.js' || true"

echo "== 5. 后端偏好重置 auto（删 plist）=="
if [ "$KEEP_CONF" = 1 ]; then
  echo "  （--keep-conf：保留现有 spcn-conf.plist，不动偏好）"
else
  run "rm -f '$DATA/spcn-conf.plist' && echo removed"
fi

if [ "$KILL" = 1 ]; then
  echo "== 6. 杀游戏（必须由用户点亮屏幕、手动打开 App，远程拉起不跑代码）=="
  run 'killall -9 worldflipper 2>/dev/null; sleep 1; ps -A -o pid,comm | grep -c worldflipper || true'
fi

echo
echo "下一步：让用户点亮屏幕、打开「世界弹射物语」(com.testdj.wf)，然后跑："
echo "  bash /mnt/d/spcntweak/tools/grab-logs.sh --host $HOST --pass $PASS"
