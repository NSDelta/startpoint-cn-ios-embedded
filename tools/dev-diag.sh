#!/usr/bin/env bash
# dev-diag.sh —— 关键证据：客户端到底有没有连上服务端？有没有崩溃报告？
# 用来区分「黑屏是资源问题」还是「黑屏发生在任何网络请求之前」。
#
# 用法：bash tools/dev-diag.sh --host 192.168.0.100 --pass qweasd [--container <uuid>]
set -uo pipefail

HOST=""; USER_NAME="root"; PASS=""; CONT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --host) HOST="${2:-}"; shift 2;;
    --user) USER_NAME="${2:-}"; shift 2;;
    --pass) PASS="${2:-}"; shift 2;;
    --container) CONT="${2:-}"; shift 2;;
    *) echo "未知参数：$1"; exit 2;;
  esac
done
[ -n "$HOST" ] || { echo "需要 --host <设备IP> [--pass <密码>]"; exit 2; }

if [ -n "$PASS" ]; then
  SSH=(sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 "$USER_NAME@$HOST")
else
  SSH=(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 "$USER_NAME@$HOST")
fi

if [ -z "$CONT" ]; then
  CONT=$("${SSH[@]}" "grep -rl 'com.testdj.wf' /var/mobile/Containers/Data/Application/*/.com.apple.mobile_container_manager.metadata.plist 2>/dev/null | head -1 | xargs -r dirname | xargs -r basename")
fi
echo "容器 $CONT"

"${SSH[@]}" "CONT='$CONT' bash -s" <<'REMOTE'
DATA="/var/mobile/Containers/Data/Application/$CONT/Documents/SpCn/data"
LOG="$DATA/spcn-server.log"
echo "== 1. 服务端收到的请求（列出去掉 /healthz 的）=="
if [ -f "$LOG" ]; then
  echo "  请求总数 $(grep -c '"incoming request"' "$LOG")，其中 /healthz $(grep -c '/healthz' "$LOG")"
  grep -h '"incoming request"' "$LOG" | grep -v '/healthz' | tail -40
  echo "  ---- 非 200 响应 ----"
  grep -h '"statusCode"' "$LOG" | grep -v '"statusCode":200' | tail -20
else
  echo "  (没有 $LOG)"
fi
echo
echo "== 2. 引导日志尾巴（dylib 侧看到的）=="
tail -25 "$DATA/SpCnEmbedded.log" 2>/dev/null
echo
echo "== 3. 游戏进程 =="
ps aux | grep -i '[w]orldflipper' | head -5
echo
echo "== 4. 崩溃/异常报告（最近 3 小时里和 worldflipper 有关的）=="
for d in /var/mobile/Library/Logs/CrashReporter /var/mobile/Library/Logs/CrashReporter/DiagnosticLogs; do
  [ -d "$d" ] && { echo "  [$d]"; ls -lt "$d" 2>/dev/null | head -8; }
done
find /var/mobile/Library/Logs -iname '*worldflipper*' -newermt '-3 hours' 2>/dev/null | head -10
echo
echo "== 5. 客户端视角的资源目录（新容器）=="
ls -la "/var/mobile/Containers/Data/Application/$CONT/Library/Application Support" 2>/dev/null | head
REMOTE
