#!/usr/bin/env bash
# server-banner-ondevice.sh —— 看设备上服务端的启动横幅与 IOS/asset 相关行（确认 IOS_COMPAT_ENABLED 等 env 是否真进去）
# 用法：bash tools/server-banner-ondevice.sh [host] [pass] [container-uuid]
set -uo pipefail
HOST="${1:-192.168.0.100}"
PASS="${2:-qweasd}"
CONTAINER="${3:-FC27FEB7-C7FE-43CB-A361-AC9C512F5846}"
LOG="/var/mobile/Containers/Data/Application/$CONTAINER/Documents/SpCn/data/spcn-server.log"
SSHOPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=8 -o PreferredAuthentications=password,keyboard-interactive,publickey"
SSH="sshpass -p $PASS ssh $SSHOPTS root@$HOST"

echo "== 最近一次服务端启动的横幅（最后 60 行里的非请求行）=="
$SSH "grep -a -v 'incoming request' '$LOG' | grep -a -v 'request completed' | tail -60" 2>&1

echo
echo "== ios / asset / 兼容 相关行（不分大小写，尾 25）=="
$SSH "grep -a -iE 'ios|asset|compat|legacy|platform' '$LOG' | grep -a -v 'incoming request' | tail -25" 2>&1

echo
echo "== healthz =="
$SSH "curl -s --max-time 8 http://127.0.0.1:8001/healthz" 2>&1

echo
echo "== 服务端进程的 env（IOS_/ASSET_ 相关）=="
$SSH "PID=\$(ps -A -o pid,comm | grep worldflipper | head -1 | awk '{print \$1}'); echo pid=\$PID; ps eww -p \$PID 2>/dev/null | tr ' ' '\n' | grep -E '^(IOS_|ASSET_MODE|CDN_|CN_LISTEN|SESSION_|ADMIN_)' | head -25" 2>&1
