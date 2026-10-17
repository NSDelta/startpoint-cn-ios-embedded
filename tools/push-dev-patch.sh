#!/usr/bin/env bash
# push-dev-patch.sh —— 免重装快速迭代：把新编的 dylib 与修补过的 JS 直接推进已安装的 App 包里，
# 然后杀掉游戏，等用户点亮屏幕手动打开（远程 uiopen 在锁屏时拉起的进程不跑代码，实测过）。
#
# 用法：bash tools/push-dev-patch.sh [--host 192.168.0.100] [--pass qweasd] [--no-kill]
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
while [ $# -gt 0 ]; do
  case "$1" in
    --host) HOST="$2"; shift 2;;
    --pass) PASS="$2"; shift 2;;
    --no-kill) KILL=0; shift;;
    *) echo "未知参数：$1"; exit 2;;
  esac
done

SSHOPT="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
run() { sshpass -p "$PASS" ssh $SSHOPT "root@$HOST" "$@"; }
put() { sshpass -p "$PASS" scp $SSHOPT "$1" "root@$HOST:$2"; }

echo "== 1. 找 com.testdj.wf 的 App 包 =="
# 优先从正在跑的进程路径拿（最可靠）；没在跑就用二进制 plist 里的 id 字串兜（设备上未必有 plutil）
APP=$(run 'ps -A -o pid,comm | grep worldflipper | grep -o "/var/containers/Bundle/Application/[^ ]*worldflipper\.app" | head -1; true' | tail -1 || true)
if [ -z "$APP" ]; then
  APP=$(run 'for p in /var/containers/Bundle/Application/*/worldflipper.app; do [ -d "$p" ] || continue; grep -aq "com.testdj.wf" "$p/Info.plist" && echo "$p"; done; true' | tail -1 || true)
fi
[ -n "$APP" ] || { echo "找不到 com.testdj.wf 的 App（是不是还没装？）"; exit 1; }
echo "  $APP"
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
run "rm -f '$DATA/spcn-conf.plist' && echo removed"

if [ "$KILL" = 1 ]; then
  echo "== 6. 杀游戏（必须由用户点亮屏幕、手动打开 App，远程拉起不跑代码）=="
  run 'killall -9 worldflipper 2>/dev/null; sleep 1; ps -A -o pid,comm | grep -c worldflipper || true'
fi

echo
echo "下一步：让用户点亮屏幕、打开「世界弹射物语」(com.testdj.wf)，然后跑："
echo "  bash /mnt/d/spcntweak/tools/grab-logs.sh --host $HOST --pass $PASS"
