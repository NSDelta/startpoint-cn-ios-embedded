#!/usr/bin/env bash
# watch-client.sh —— 等「客户端真的有动作」：出现非 /healthz 的服务端请求 / 新的崩溃报告 / 游戏进程消失。
#
# 为什么需要：现在缺的就是「客户端到底有没有走网络」这一条观测。服务端日志里每来一个请求都会打一行
# JSON（含 reqId 与 req.url），探针的 /healthz 会污染计数 ⇒ 只统计非 /healthz 的。
#
# 用法：bash tools/watch-client.sh [host] [pass] [seconds]
set -uo pipefail
HOST="${1:-192.168.0.100}"; PASS="${2:-qweasd}"; SECS="${3:-600}"
SSHOPT="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=8"

snap() {
  sshpass -p "$PASS" ssh $SSHOPT "root@$HOST" bash -s <<'REMOTE' 2>/dev/null
D=""
for p in /var/mobile/Containers/Data/Application/*/; do
  [ -d "$p/Documents/SpCn" ] && D="$p" && break
done
LOG="$D/Documents/SpCn/data/spcn-server.log"
HT=0; NH=0
if [ -f "$LOG" ]; then
  HT=$(grep -c '"reqId"' "$LOG" 2>/dev/null || true)
  NH=$(grep '"reqId"' "$LOG" 2>/dev/null | grep -vc '/healthz' || true)
fi
CR=$(ls /var/mobile/Library/Logs/CrashReporter/*.ips 2>/dev/null | wc -l | tr -d ' ')
PID=$(ps ax -o command 2>/dev/null | grep -c '[w]orldflipper.app/worldflipper' || true)
URLS=$(grep '"reqId"' "$LOG" 2>/dev/null | grep -v '/healthz' | tail -3 | sed 's/.*"url":"\([^"]*\)".*/\1/' | tr '\n' ' ')
echo "${HT:-0} ${NH:-0} ${CR:-0} ${PID:-0} ${URLS}"
REMOTE
}

echo "盯 $SECS 秒：等客户端发第一个非 /healthz 请求（或新崩溃）…"
BASE=$(snap); echo "  基线（req / 非healthz / 崩溃数 / 游戏进程）：$BASE"
B_NH=$(echo "$BASE" | awk '{print $2}'); B_CR=$(echo "$BASE" | awk '{print $3}')
START=$(date +%s)
while [ $(($(date +%s) - START)) -lt "$SECS" ]; do
  sleep 5
  S=$(snap)
  [ -z "$S" ] && continue
  NH=$(echo "$S" | awk '{print $2}'); CR=$(echo "$S" | awk '{print $3}'); PID=$(echo "$S" | awk '{print $4}')
  if [ "${NH:-0}" -gt "${B_NH:-0}" ]; then
    echo "★ 客户端发请求了！（非 /healthz：$B_NH → $NH）"
    echo "  日志：$S"
    sshpass -p "$PASS" ssh $SSHOPT "root@$HOST" \
      "D=\$(for p in /var/mobile/Containers/Data/Application/*/; do [ -d \"\$p/Documents/SpCn\" ] && echo \$p && break; done); \
       grep '\"reqId\"' \"\$D/Documents/SpCn/data/spcn-server.log\" | grep -v '/healthz' | tail -20 | \
       sed 's/.*\"req\":{\([^}]*\)}.*/\1/'" 2>/dev/null
    exit 0
  fi
  if [ "${CR:-0}" -gt "${B_CR:-0}" ]; then
    echo "✗ 出现新崩溃报告（$B_CR → $CR）—— 客户端不是没动作，是崩了"
    ls -t /var/mobile/Library/Logs/CrashReporter 2>/dev/null | head -3
    exit 2
  fi
  if [ "${PID:-0}" = "0" ]; then echo "  （游戏进程当前不在——等你打开）"; fi
done
echo "超时：$SECS 秒内客户端一个非 /healthz 请求都没发（黑屏与网络无关的强证据）"
exit 1
