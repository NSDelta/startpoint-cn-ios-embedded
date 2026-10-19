#!/usr/bin/env bash
# dev-client-activity.sh —— 客户端到底有没有跟服务端说过话、AIR 有没有留下错误、有没有新崩溃。
#
# 用法：bash tools/dev-client-activity.sh --host 192.168.0.100 --pass qweasd [--container <UUID>]
set -uo pipefail

HOST="192.168.0.100"; USER_NAME="root"; PASS="qweasd"; CONTAINER=""
while [ $# -gt 0 ]; do
  case "$1" in
    --host) HOST="$2"; shift 2;;
    --user) USER_NAME="$2"; shift 2;;
    --pass) PASS="$2"; shift 2;;
    --container) CONTAINER="$2"; shift 2;;
    *) echo "未知参数：$1"; exit 2;;
  esac
done

SSHOPT="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
run() { sshpass -p "$PASS" ssh $SSHOPT "$USER_NAME@$HOST" "$@"; }

[ -n "$CONTAINER" ] || CONTAINER=$(run 'ls -d /var/mobile/Containers/Data/Application/*/ | while read p; do [ -d "$p/Documents/SpCn/data" ] && basename "$p"; done | head -1')
echo "数据容器 $CONTAINER"

run "C='$CONTAINER' bash -s" <<'REMOTE'
D="/var/mobile/Containers/Data/Application/$C/Documents/SpCn/data"
SRV="$D/spcn-server.log"

echo "== 1. 进程 =="
ps -A -o pid,etime,comm | grep worldflipper | grep -v grep || echo "  没有 worldflipper 在跑"

echo
echo "== 2. 服务端收到的所有请求（按 URL 归类计数）=="
if [ -f "$SRV" ]; then
  grep -o '"url":"[^"]*"' "$SRV" | sort | uniq -c | sort -rn | head -30
  echo "  —— 请求总数：$(grep -c '"incoming request"' "$SRV")"
  echo "  —— 非 /healthz 请求（客户端真的连上来的证据）："
  grep '"incoming request"' "$SRV" | grep -v '/healthz' | tail -20 || echo "    （无）"
else
  echo "  没有 $SRV"
fi

echo
echo "== 3. 服务端日志里非 node/非 fastify 的行（AIR 自己的 stdout/stderr 会被我们重定向到这里）=="
[ -f "$SRV" ] && grep -v -E '^\{"level"|^\[spcn\]|^\[TCP\]|^\[iOS-|^\[ADMIN|^\[TIME|^\[BIND|^\[Shadow\]' "$SRV" | tail -40

echo
echo "== 4. 最近 20 分钟有没有新的崩溃报告 =="
ls -lt /var/mobile/Library/Logs/CrashReporter/ 2>/dev/null | head -8
for f in $(ls -t /var/mobile/Library/Logs/CrashReporter/worldflipper* 2>/dev/null | head -3); do
  echo "  --- $f"
  grep -m1 -E '"timestamp"|"procName"' "$f" 2>/dev/null | head -2
  grep -m1 -E 'exception|termination' "$f" 2>/dev/null | head -2
done

echo
echo "== 5. 客户端自己写过的文件（容器里最近 30 分钟被改动的，前 25 个）=="
find "/var/mobile/Containers/Data/Application/$C" -mmin -30 -type f 2>/dev/null | head -25

echo
echo "== 6. 客户端自己的日志目录 =="
ls -lt "/var/mobile/Containers/Data/Application/$C/Documents" 2>/dev/null | head -12
ls -lt "/var/mobile/Containers/Data/Application/$C/Library/Caches" 2>/dev/null | head -12
REMOTE
