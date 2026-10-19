#!/usr/bin/env bash
# diag-frames.sh —— 直接抓「调用栈」段落（中文标签 %s 会被双重编码，所以不能按中文字面 grep）
set -uo pipefail
HOST="${1:-192.168.0.100}"
PASS="${2:-qweasd}"
CONT="${3:-/var/mobile/Containers/Data/Application/FC27FEB7-C7FE-43CB-A361-AC9C512F5846}"
SSH="sshpass -p $PASS ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 -o PreferredAuthentications=password,keyboard-interactive,publickey root@$HOST"

echo "== 调用栈段落（按 #行 抓，末 80 行）=="
$SSH "grep -a -e '\]     #' -e 'SecTaskCopyValueForEntitlement' '$CONT/tmp/SpCnEmbedded.log' 2>/dev/null | tail -n 80" 2>&1
echo
echo "== 调用栈标题行（按 UTF-8 中文抓）=="
$SSH "grep -a -c '调用栈' '$CONT/tmp/SpCnEmbedded.log' 2>/dev/null || true" 2>&1
