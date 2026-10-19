#!/usr/bin/env bash
# relaunch-and-grab.sh —— 重启 App 并只抓「本次启动新增」的日志（AIR 打包自检是否还在、客户端有没有发请求）。
#
# 为什么：AIR 的 `application packaging error` 打在进程 stdout 上，我们的 dylib 在 constructor 期就把
# stdout/stderr 接管到 <容器>/tmp/SpCnBoot-stdout.log（设备上 `log` 命令不存在，系统日志这条路是死的）。
# 用法：bash tools/relaunch-and-grab.sh [bundle-id] [host] [pass] [wait 秒]
#       （锁屏状态下 uiopen 拉起进程不跑代码 ⇒ 必须用户已点亮屏幕 / 手动点开）
set -uo pipefail
BID="${1:-com.testdj.wf}"
HOST="${2:-192.168.0.100}"
PASS="${3:-qweasd}"
WAIT="${4:-35}"
SSH="sshpass -p $PASS ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 -o PreferredAuthentications=password,keyboard-interactive,publickey root@$HOST"
CONT="/var/mobile/Containers/Data/Application/FC27FEB7-C7FE-43CB-A361-AC9C512F5846"
BOOTLOG="$CONT/tmp/SpCnBoot-stdout.log"
DATA="$CONT/Documents/SpCn/data"

before=$($SSH "wc -c < '$BOOTLOG' 2>/dev/null || echo 0" 2>/dev/null | tr -d ' \r')
echo "启动前 stdout 日志 = $before 字节"

$SSH "killall -9 worldflipper 2>/dev/null; sleep 1; uiopen -b '$BID' 2>&1 | head -3; echo '(uiopen 已发出)'" 2>&1

echo "等 ${WAIT}s…"
sleep "$WAIT"

echo
echo "== 进程 =="
$SSH "ps -Ao pid,etime,comm | grep '[w]orldflipper' || echo '（没有进程：锁屏时 uiopen 不会真正跑起来）'" 2>&1

after=$($SSH "wc -c < '$BOOTLOG' 2>/dev/null || echo 0" 2>/dev/null | tr -d ' \r')
echo
echo "== 本次启动新增的 stdout（$before → $after 字节）=="
if [ "${after:-0}" -gt "${before:-0}" ]; then
  $SSH "tail -c +$((before + 1)) '$BOOTLOG' | grep -a -E 'packaging error|BOOT|CFG|UI\]|healthz|\[spcn\]|node_start|SUP|PROBE' | head -50" 2>&1
else
  echo "（没有新增输出）"
fi

echo
echo "== 服务端收到的请求（按 URL 计数，客户端请求应当是 /api 之类而不是 /healthz）=="
$SSH "grep -a -o '\"url\":\"[^\"]*\"' '$DATA/spcn-server.log' 2>/dev/null | sort | uniq -c | sort -rn | head -15" 2>&1

echo
echo "== 关键行计数 =="
$SSH "printf 'packaging error: '; grep -a -c 'application packaging error' '$BOOTLOG' 2>/dev/null || true
printf 'healthz 就绪: '; grep -a -c 'healthz 就绪' '$DATA/spcn-server.log' 2>/dev/null || true" 2>&1
