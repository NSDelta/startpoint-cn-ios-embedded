#!/usr/bin/env bash
# watch-boot.sh —— 等用户「点亮屏幕 + 手动打开 App」：轮询日志与 /healthz，
# 一旦 healthz 变 ready 或日志出现新的附加就打印关键段落并退出（默认最多等 15 分钟）。
#
# 为什么必须等用户动手：锁屏状态下从 SSH 用 uiopen 拉起的进程**不跑代码**（实测：进程在，一行日志都没有）。
#
# 用法：bash tools/watch-boot.sh [host] [pass] [timeout_seconds]
set -uo pipefail
HOST=${1:-192.168.0.100}
PASS=${2:-qweasd}
TIMEOUT=${3:-900}
SSHOPT="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=8"
run() { sshpass -p "$PASS" ssh $SSHOPT "root@$HOST" "$@"; }

DATA=$(run 'for p in /var/mobile/Containers/Data/Application/*/; do d="$p/Documents/SpCn/data"; [ -d "$d" ] && echo "$d"; done; true' | tail -1 | tr -d '\r')
LOG="$DATA/SpCnEmbedded.log"
echo "数据卷 $DATA"
echo "日志   $LOG"
start=$(date +%s)
while [ $(( $(date +%s) - start )) -lt "$TIMEOUT" ]; do
  n=$(run "wc -l < '$LOG' 2>/dev/null || echo 0" | tr -d ' \r')
  pl=$(run 'ps -A -o pid,comm | grep worldflipper || true' | tr -d '\r' | head -1)
  hz=$(run 'curl -s -m 3 http://127.0.0.1:8001/healthz 2>/dev/null | head -c 300' | tr -d '\r')
  echo "[$(date +%H:%M:%S)] 日志 $n 行 | 进程 ${pl:-无}"
  if [ -n "$hz" ]; then echo "  healthz: $hz"; fi
  case "$hz" in *'"status":"ready"'*) echo "★ healthz ready"; break;; esac
  sleep 5
done
echo
echo "== SpCnEmbedded.log 尾巴 60 行 =="
run "tail -60 '$LOG' 2>/dev/null || echo '(没有日志文件——dylib 可能没加载)'"
echo
echo "== spcn-server.log 尾巴 40 行 =="
run "tail -40 '$DATA/spcn-server.log' 2>/dev/null || echo '(没有服务端日志——独立进程后端没起来)'"
