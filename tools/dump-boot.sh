#!/usr/bin/env bash
# dump-boot.sh —— 把引导 stdout 与数据卷日志的尾部原样取回来（中文只在这两处，不要用内联命令抓）
#   用法：bash tools/dump-boot.sh [host] [pass] [行数]
set -uo pipefail
HOST="${1:-192.168.0.100}"
PASS="${2:-qweasd}"
N="${3:-120}"
CONT=/var/mobile/Containers/Data/Application/FC27FEB7-C7FE-43CB-A361-AC9C512F5846
BOOT="$CONT/tmp/SpCnBoot-stdout.log"
DATA="$CONT/Documents/SpCn/data"
SSH="sshpass -p $PASS ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o PreferredAuthentications=password,keyboard-interactive,publickey root@$HOST"

echo "== 文件状态 =="
$SSH "ls -l '$BOOT' '$DATA/SpCnEmbedded.log' 2>&1"
echo
echo "== 引导 stdout 计数 =="
$SSH "printf '  总行数 %s\n' \"\$(wc -l < '$BOOT')\"; printf '  [BOOT] %s\n' \"\$(grep -a -c 'BOOT' '$BOOT' || true)\"; printf '  [PROBE] %s\n' \"\$(grep -a -c 'PROBE' '$BOOT' || true)\"; printf '  packaging %s\n' \"\$(grep -a -c 'packaging' '$BOOT' || true)\"; printf '  AdobeAIR %s\n' \"\$(grep -a -c 'AdobeAIR' '$BOOT' || true)\""
echo
echo "== 引导 stdout 末 $N 行 =="
$SSH "tail -n $N '$BOOT'" 2>&1
echo
echo "== 数据卷 SpCnEmbedded.log 末 25 行 =="
$SSH "tail -n 25 '$DATA/SpCnEmbedded.log'" 2>&1
