#!/usr/bin/env bash
# diag-cf.sh —— 看身份诊断里最关键的一段：AIR 到底通过哪个 API 读身份（CFBundle / NSBundle / SecTask）
# 用法：bash tools/diag-cf.sh [host] [pass]
set -uo pipefail
HOST="${1:-192.168.0.100}"
PASS="${2:-qweasd}"
CONT="/var/mobile/Containers/Data/Application/FC27FEB7-C7FE-43CB-A361-AC9C512F5846"
SSH="sshpass -p $PASS ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 -o PreferredAuthentications=password,keyboard-interactive,publickey root@$HOST"

echo "== 身份诊断装载行 =="
$SSH "grep -a -e '身份诊断已装' '$CONT/tmp/SpCnEmbedded.log' 2>/dev/null | tail -2" 2>&1
echo
echo "== CFBundle / NSBundle / SecTask 身份读取（末 55 行）=="
$SSH "grep -a -e 'CFBundleGetIdentifier' -e 'CFBundleGetValueForInfoDictionaryKey' -e 'objectForInfoDictionaryKey' -e 'SecTaskCopyValueForEntitlement' -e 'ObjC 异常' -e 'C++ 异常' '$CONT/tmp/SpCnEmbedded.log' 2>/dev/null | tail -n 55" 2>&1
