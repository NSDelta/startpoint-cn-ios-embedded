#!/usr/bin/env bash
# dev-server-log.sh —— 看设备上服务端到底起来没有：服务端日志尾 + 引导日志里的 [SUP]/[FW] 行 + 请求分类。
#
# 为什么要它：我们 dylib 起来后 stdout 被 freopen 到 <DATA>/spcn-server.log，所以 node 的 console.log
# 与 ios-entry.js 的 [spcn] 行都在那里；而 [SUP]/[FW] 行在 <容器>/tmp/SpCnBoot-stdout.log。
# 用法：bash tools/dev-server-log.sh [host] [pass] [服务端日志尾行数]
set -uo pipefail
HOST="${1:-192.168.0.100}"; PASS="${2:-qweasd}"; N="${3:-30}"
CONT=/var/mobile/Containers/Data/Application/FC27FEB7-C7FE-43CB-A361-AC9C512F5846
SSH="sshpass -p $PASS ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10 root@$HOST"
D="$CONT/Documents/SpCn/data"

echo "===== 服务端日志尾 $N 行（$D/spcn-server.log）====="
$SSH "tail -n $N '$D/spcn-server.log'"
echo
echo "===== 起来过几次 / 最近几次 listening ====="
$SSH "grep -a -c 'Server listening' '$D/spcn-server.log'; echo '--- 最近 3 次 ---'; grep -a 'Server listening' '$D/spcn-server.log' | tail -3"
echo
echo "===== ios-entry 是否被用到（[spcn] 行）====="
$SSH "grep -a '\[spcn\]' '$D/spcn-server.log' | tail -6"
echo
echo "===== 引导日志 [SUP]/[FW] 尾 14 行 ====="
$SSH "grep -a -e '\[SUP\]' -e '\[FW\]' '$CONT/tmp/SpCnBoot-stdout.log' | tail -14"
echo
echo "===== 请求分类 ====="
$SSH "grep -a -c '\"req\":{\"method\"' '$D/spcn-server.log' 2>/dev/null || echo 0; echo '--- 非 healthz 的 incoming ---'; grep -a '\"req\":{\"method\"' '$D/spcn-server.log' | grep -a -v '/healthz' | tail -10"
