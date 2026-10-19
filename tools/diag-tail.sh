#!/usr/bin/env bash
# diag-tail.sh —— 取设备上 SpCnEmbedded.log 里的 [DIAG] 段（身份诊断 / longjmp 失败现场的调用栈）
# 用法：bash tools/diag-tail.sh [host] [pass] [N 行]
set -uo pipefail
HOST="${1:-192.168.0.100}"
PASS="${2:-qweasd}"
N="${3:-80}"
CONT="/var/mobile/Containers/Data/Application/FC27FEB7-C7FE-43CB-A361-AC9C512F5846"
DATA="$CONT/Documents/SpCn/data"
SSH="sshpass -p $PASS ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 -o PreferredAuthentications=password,keyboard-interactive,publickey root@$HOST"

echo "== [DIAG] 段（末 $N 行）=="
$SSH "grep -a -e '[DIAG]' '$DATA/SpCnEmbedded.log' 2>/dev/null | tail -n $N" 2>&1
echo
echo "== SpCnEmbedded.log 末尾 40 行 =="
$SSH "tail -n 40 '$DATA/SpCnEmbedded.log' 2>/dev/null" 2>&1
echo
echo "== 进程 =="
$SSH "ps -Ao pid,etime,comm | grep '[w]orldflipper' || echo '（没有进程）'" 2>&1
CRASHDIR="/var/mobile/Library/Logs/CrashReporter"
echo
echo "== 最近 5 份崩溃报告 =="
$SSH "ls -t $CRASHDIR/ 2>/dev/null | head -5" 2>&1
NEWEST=$($SSH "ls -t $CRASHDIR/worldflipper-*.ips 2>/dev/null | head -1" 2>/dev/null | tr -d '\r')
if [ -n "${NEWEST:-}" ]; then
  echo
  echo "== 最新崩溃报告头部（${NEWEST##*/}）=="
  $SSH "head -c 2000 '$NEWEST' 2>/dev/null" 2>&1
fi
