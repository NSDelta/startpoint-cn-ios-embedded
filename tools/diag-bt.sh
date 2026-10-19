#!/usr/bin/env bash
# diag-bt.sh —— 把「谁在读身份」的调用栈打出来（身份读取者 = AIR 的 DRM 校验现场）
# 用法：bash tools/diag-bt.sh [host] [pass] [容器路径]
set -uo pipefail
HOST="${1:-192.168.0.100}"
PASS="${2:-qweasd}"
CONT="${3:-/var/mobile/Containers/Data/Application/FC27FEB7-C7FE-43CB-A361-AC9C512F5846}"
SSH="sshpass -p $PASS ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 -o PreferredAuthentications=password,keyboard-interactive,publickey root@$HOST"

echo "== 引导日志里身份读取的调用栈（末 100 行）=="
$SSH "grep -a -A 22 -e '的调用方' '$CONT/tmp/SpCnEmbedded.log' 2>/dev/null | tail -n 100" 2>&1
echo
echo "== 身份读取汇总行 =="
$SSH "grep -a -e 'CFBundleGetIdentifier' -e 'objectForInfoDictionaryKey' -e 'SecTaskCopyValueForEntitlement' -e '身份诊断已装' '$CONT/tmp/SpCnEmbedded.log' 2>/dev/null | tail -n 25" 2>&1
