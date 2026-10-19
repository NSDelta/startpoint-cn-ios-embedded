#!/usr/bin/env bash
# log-urls-ondevice.sh —— 从设备上的服务端日志里做 URL 直方图（看清客户端到底请求了哪些接口）
# 用法：bash tools/log-urls-ondevice.sh [host] [pass] [container-uuid] [关键字]
set -uo pipefail
HOST="${1:-192.168.0.100}"
PASS="${2:-qweasd}"
CONTAINER="${3:-FC27FEB7-C7FE-43CB-A361-AC9C512F5846}"
KEY="${4:-}"
LOG="/var/mobile/Containers/Data/Application/$CONTAINER/Documents/SpCn/data/spcn-server.log"
SSHOPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=8 -o PreferredAuthentications=password,keyboard-interactive,publickey"
SSH="sshpass -p $PASS ssh $SSHOPTS root@$HOST"

echo "== 全部 incoming 请求的 URL 直方图（top 30）=="
$SSH "grep -a 'incoming request' '$LOG' | sed 's/.*\"url\":\"//; s/\".*//' | sort | uniq -c | sort -rn | head -30" 2>&1

if [ -n "$KEY" ]; then
  echo
  echo "== 含关键字 '$KEY' 的行（尾 20）=="
  $SSH "grep -a -i '$KEY' '$LOG' | tail -20" 2>&1
fi

echo
echo "== 非 2xx/3xx 的响应（尾 15）=="
$SSH "grep -a '\"msg\":\"request completed\"' '$LOG' | grep -a -v '\"statusCode\":2' | grep -a -v '\"statusCode\":3' | tail -15" 2>&1

echo
echo "== 客户端 stdout 里的错误/失败行（尾 25）=="
$SSH "grep -a -iE 'fail|error|失败|错误' /var/mobile/Containers/Data/Application/$CONTAINER/tmp/SpCnBoot-stdout.log | tail -25" 2>&1
