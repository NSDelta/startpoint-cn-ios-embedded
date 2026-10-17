#!/usr/bin/env bash
# grab-dev-detail.sh —— 抓「引导日志 + 服务端失败上下文」，诊断用。
# 要点：SpCnConfig 的 [CFG] 行打在日志切到数据卷**之前** ⇒ 在 <容器>/tmp/SpCnEmbedded.log 里，
# 数据卷里那份看不到它（这就是「不知道它为什么选 framework」的原因）。
set -uo pipefail
HOST=${1:-192.168.0.100}
PASS=${2:-qweasd}
SSHOPT="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=8"
run() { sshpass -p "$PASS" ssh $SSHOPT "root@$HOST" "$@"; }

C=$(run 'for p in /var/mobile/Containers/Data/Application/*/; do d="$p/Documents/SpCn/data"; [ -d "$d" ] && echo "$p"; done; true' | tail -1 | tr -d '\r')
echo "== 容器 $C"
echo
echo "== 1. 引导日志（含 [CFG] 后端判定）=="
run "tail -40 '${C}tmp/SpCnEmbedded.log' 2>/dev/null || echo '(没有)'"
echo
echo "== 2. 服务端日志里 content/asset 相关行 =="
run "grep -n -i -E 'content|snapshot|asset|cdn|error|fail|失败' '${C}Documents/SpCn/data/spcn-server.log' 2>/dev/null | tail -30 || echo '(没有)'"
echo
echo "== 3. 数据卷 =="
run "ls -la '${C}Documents/SpCn/data'"
echo
echo "== 4. 装到机上的 dylib 是不是新版（找 'node能跑' / SpCnLogViewController）=="
run 'grep -a -c -E "node能跑" /var/containers/Bundle/Application/*/worldflipper.app/Frameworks/SpCnEmbedded.dylib; grep -a -c -E "SpCnLogViewController" /var/containers/Bundle/Application/*/worldflipper.app/Frameworks/SpCnEmbedded.dylib'
