#!/usr/bin/env bash
# inspect-bind-lines.sh —— 收尾核对：绑定是否真没了、410 是哪几条、healthz、客户端有没有拉 CDN 增量
# 用法：bash tools/inspect-bind-lines.sh [host] [pass] [container-uuid]
set -uo pipefail
HOST="${1:-192.168.0.100}"; PASS="${2:-qweasd}"
C="${3:-FC27FEB7-C7FE-43CB-A361-AC9C512F5846}"
D="/var/mobile/Containers/Data/Application/$C"
SLOG="$D/Documents/SpCn/data/spcn-server.log"
ELOG="$D/Documents/SpCn/data/SpCnEmbedded.log"
SSHOPT="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
run() { sshpass -p "$PASS" ssh $SSHOPT "root@$HOST" "$@"; }

echo "== 1. BIND_REQUIRED 命中（应为 0）=="
run "grep -a -c 'BIND_REQUIRED' '$SLOG' || true" 2>&1

echo
echo "== 2. 含 517 的行（可能是端口/时间戳假阳性，看内容）=="
run "grep -a -o '.\{0,40\}517.\{0,40\}' '$SLOG' | head -8" 2>&1

echo
echo "== 3. 410 的请求 URL =="
run "grep -a -B1 '\"statusCode\":410' '$SLOG' | grep -a -o '\"url\":\"[^\"]*\"' | sort -u | head -10" 2>&1

echo
echo "== 4. healthz（再试一次）=="
for i in 1 2 3; do
  out=$(run "curl -s --max-time 6 http://127.0.0.1:8001/healthz" 2>&1)
  if [ -n "$out" ]; then echo "$out"; break; fi
  sleep 2
done

echo
echo "== 5. 客户端有没有请求 /patch/cn（CDN 增量）=="
run "grep -a -c '/patch/cn' '$SLOG' || true" 2>&1
run "grep -a '"'"'"url":"[^"]*patch[^"]*"'"'"' '$SLOG' | tail -3" 2>&1

echo
echo "== 6. 服务端启动后的 ios/notice/single 相关行（尾 20）=="
run "grep -a -iE 'spcn|single_player|notice|ios-' '$ELOG' | tail -20" 2>&1
