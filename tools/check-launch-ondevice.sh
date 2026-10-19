#!/usr/bin/env bash
# check-launch-ondevice.sh —— 一次看完「这次启动」的关键事实（不依赖中文 grep）。
# 用法：bash tools/check-launch-ondevice.sh [host] [pass] [container-uuid]
set -uo pipefail
HOST="${1:-192.168.0.100}"; PASS="${2:-qweasd}"
C="${3:-FC27FEB7-C7FE-43CB-A361-AC9C512F5846}"
D="/var/mobile/Containers/Data/Application/$C"
BOOT="$D/tmp/SpCnBoot-stdout.log"
SLOG="$D/Documents/SpCn/data/spcn-server.log"
SSHOPT="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
run() { sshpass -p "$PASS" ssh $SSHOPT "root@$HOST" "$@"; }

echo "== 进程 =="
run "ps -A -o pid,comm | grep worldflipper | head -3" 2>&1

echo
echo "== 引导 stdout（进程自己的 stdout/stderr）=="
run "wc -c < '$BOOT'; echo '--- packaging error 次数:'; grep -a -c 'application packaging error' '$BOOT' || true; echo '--- 尾部 12 行:'; tail -12 '$BOOT'" 2>&1

echo
echo "== healthz =="
run "curl -s --max-time 8 http://127.0.0.1:8001/healthz" 2>&1
echo

echo "== 请求直方图（本次进程的日志，按 url 归类）=="
run "grep -a '\"req\":{\"method\"' '$SLOG' | sed 's/.*\"url\":\"\\([^\"?]*\\)[^\"]*\".*/\\1/' | sort | uniq -c | sort -rn | head -22" 2>&1

echo
echo "== 非 2xx/3xx =="
run "grep -a '\"res\":{\"statusCode\"' '$SLOG' | grep -a -v '\"statusCode\":[23]' | sed 's/.*\"statusCode\":\\([0-9]*\\).*/\\1/' | sort | uniq -c | head -10" 2>&1

echo
echo "== CDN / 版本相关行（1.4.5 / patch / version）=="
run "grep -a -E '1\\.4\\.5|/patch/|client_release' '$SLOG' | tail -12" 2>&1

echo
echo "== 绑定相关（应为 0）=="
run "grep -a -c -E 'BIND_REQUIRED|服务器绑定验证码|517' '$SLOG' || true" 2>&1
