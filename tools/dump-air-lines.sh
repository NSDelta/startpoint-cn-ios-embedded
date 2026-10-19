#!/usr/bin/env bash
# dump-air-lines.sh —— 看最近一次启动里「不是我们自己打的」那些行（AIR / UIKit / Distriqt / xzw …）
#   用途：判断 AIR 的内容加载到底走到哪一步（我们的 [SpCn] 行会淹没一切，所以过滤掉）
#   用法：bash tools/dump-air-lines.sh [host] [pass] [取尾部字节数]
set -uo pipefail
HOST="${1:-192.168.0.100}"
PASS="${2:-qweasd}"
BYTES="${3:-60000}"
CONT=/var/mobile/Containers/Data/Application/FC27FEB7-C7FE-43CB-A361-AC9C512F5846
BOOT="$CONT/tmp/SpCnBoot-stdout.log"
SSH="sshpass -p $PASS ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o PreferredAuthentications=password,keyboard-interactive,publickey root@$HOST"

echo "== 非 [SpCn] 行（末 90 行）=="
$SSH "tail -c $BYTES '$BOOT' 2>/dev/null | grep -a -v '\[SpCn\]' | grep -a -v '\[Shadow\]' | tail -n 90" 2>&1
echo
echo "== 关键字计数（最近 $BYTES 字节内）=="
$SSH "tail -c $BYTES '$BOOT' 2>/dev/null | grep -a -c -e 'AdobeAIR' -e 'packaging' || true"
echo
echo "== 最近崩溃报告 =="
$SSH "ls -lt /var/mobile/Library/Logs/CrashReporter/worldflipper-*.ips 2>/dev/null | head -4" 2>&1
