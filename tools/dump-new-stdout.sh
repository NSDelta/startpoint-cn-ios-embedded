#!/usr/bin/env bash
# dump-new-stdout.sh —— 打印设备上进程 stdout/stderr 的**完整尾巴**（不做关键字筛选）。
#
# 为什么要它：relaunch-and-grab.sh 只打印匹配关键字（BOOT/CFG/packaging error…）的行，
# 而 AIR 抛 AS3 异常时通常还会打「Error: …」+ 调用栈，那些行被筛掉了。
# 用法：bash tools/dump-new-stdout.sh [host] [pass] [行数]
set -uo pipefail
HOST="${1:-192.168.0.100}"
PASS="${2:-qweasd}"
N="${3:-160}"
CONT="/var/mobile/Containers/Data/Application/FC27FEB7-C7FE-43CB-A361-AC9C512F5846"
BOOTLOG="$CONT/tmp/SpCnBoot-stdout.log"
SSH="sshpass -p $PASS ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 -o PreferredAuthentications=password,keyboard-interactive,publickey root@$HOST"

echo "== stdout 日志大小 =="
$SSH "wc -c < '$BOOTLOG'" 2>&1
echo
echo "== 全文里的错误/异常行（不限最近）=="
$SSH "grep -a -n -E 'Error|error|Exception|exception|Verify|TypeError|ReferenceError|ArgumentError|#2[0-9]{3}|thrown|failed' '$BOOTLOG' 2>/dev/null | tail -n 40" 2>&1
echo
echo "== 最后 $N 行（完整，不筛选）=="
$SSH "tail -n $N '$BOOTLOG' 2>/dev/null" 2>&1
