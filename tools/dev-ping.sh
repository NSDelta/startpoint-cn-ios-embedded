#!/usr/bin/env bash
# dev-ping.sh —— 看设备还在不在、SSH 还通不通（排查 push-dev-patch.sh 第 1 步失败用）
set -uo pipefail
HOST=${1:-192.168.0.100}
PASS=${2:-qweasd}
echo "== ping =="
ping -c 2 -W 2 "$HOST" || echo "  ping 失败"
echo "== ssh =="
sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -o ConnectTimeout=8 -o LogLevel=ERROR "root@$HOST" 'echo SSH_OK; uname -a; ps -A -o pid,comm | grep worldflipper || echo "游戏没在跑"'
echo "  ssh exit=$?"
