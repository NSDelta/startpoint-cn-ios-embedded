#!/usr/bin/env bash
# grab-boot-logs.sh —— 一次取回「启动期取证」四件套（真机黑屏排查的主力工具）。
#
# 取什么：
#   ① <容器>/tmp/SpCnBoot-stdout.log   —— dylib constructor 接管后的进程 stdout/stderr（AIR 的 AS3 报错在这里）
#   ② <容器>/tmp/SpCnEmbedded.log      —— [BOOT]/[PROBE]/[CFG] 行（数据卷那份看不到这些）
#   ③ <DATA>/spcn-server.log           —— 服务端 stdout（node 日志、[Shadow]、[FW]、[SUP]）
#   ④ 服务端收到的请求 URL 清单（只算 incoming 行，completed 行没有 url 会误判）
#
# 用法：bash tools/grab-boot-logs.sh [host] [pass] [每个文件的尾巴行数]
set -uo pipefail
HOST="${1:-192.168.0.100}"; PASS="${2:-qweasd}"; N="${3:-120}"
SSHOPT="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=8"

sshpass -p "$PASS" ssh $SSHOPT "root@$HOST" "N='$N' bash -s" <<'REMOTE'
D=""
for p in /var/mobile/Containers/Data/Application/*/; do
  [ -d "$p/Documents/SpCn" ] && D="$p" && break
done
[ -n "$D" ] || { echo "找不到单机版容器"; exit 1; }
DATA="$D/Documents/SpCn/data"
echo "容器 $D"
echo "时间 $(date '+%H:%M:%S')   游戏进程：$(ps ax -o pid,command | grep '[w]orldflipper.app/worldflipper' | awk '{print $1}' | tr '\n' ' ')"

echo
echo "════ ① 进程 stdout/stderr（<容器>/tmp/SpCnBoot-stdout.log）════"
if [ -f "$D/tmp/SpCnBoot-stdout.log" ]; then
  echo "  体积 $(wc -c < "$D/tmp/SpCnBoot-stdout.log") B"
  tail -n "$N" "$D/tmp/SpCnBoot-stdout.log"
else
  echo "  ✗ 不存在 —— 说明 constructor 里的接管没跑（dylib 没加载？）"
  ls -l "$D/tmp/" 2>/dev/null | head -20
fi

echo
echo "════ ② 引导日志（[BOOT]/[PROBE]/[CFG]）════"
if [ -f "$D/tmp/SpCnEmbedded.log" ]; then
  grep -a -E '\[BOOT\]|\[PROBE\]|\[CFG\]|\[UI\]|\[SUP\]' "$D/tmp/SpCnEmbedded.log" | tail -n "$N"
else
  echo "  ✗ 不存在"
fi

echo
echo "════ ③ 服务端日志尾巴（<DATA>/spcn-server.log）════"
if [ -f "$DATA/spcn-server.log" ]; then
  echo "  体积 $(wc -c < "$DATA/spcn-server.log") B"
  tail -n 40 "$DATA/spcn-server.log"
else
  echo "  ✗ 不存在（后端没起来过）"
fi

echo
echo "════ ④ 服务端收到的请求（按 URL 归类）════"
if [ -f "$DATA/spcn-server.log" ]; then
  echo "  incoming 行总数：$(grep -c '"req":{"method"' "$DATA/spcn-server.log" 2>/dev/null || echo 0)"
  echo "  按 URL 计数："
  grep -a '"req":{"method"' "$DATA/spcn-server.log" 2>/dev/null | sed 's/.*"url":"\([^"]*\)".*/\1/' | sort | uniq -c | sort -rn | head -20
  echo "  最近 15 条非 /healthz 请求："
  grep -a '"req":{"method"' "$DATA/spcn-server.log" 2>/dev/null | grep -v '/healthz' | tail -15
else
  echo "  ✗ 无日志"
fi

echo
echo "════ ⑤ 资源与数据卷现状 ════"
du -sh "$D/Library/Application Support/com.testdj.wf/Local Store" 2>/dev/null || echo "  ✗ 资源目录不在"
ls -la "$D/Library/Application Support/com.testdj.wf/Local Store/asset/asset_download/" 2>/dev/null | head
ls -l "$D/Documents/SpCn/data/" 2>/dev/null | head
ls -lt /var/mobile/Library/Logs/CrashReporter/*.ips 2>/dev/null | head -3
REMOTE
