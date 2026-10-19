#!/usr/bin/env bash
# show-launch.sh —— 直接看「最近这次启动」的原始证据（不依赖任何中文 grep：中文串在日志里会双重编码）
HOST="${1:-192.168.0.100}"; PASS="${2:-qweasd}"; N="${3:-120}"
APP=/var/containers/Bundle/Application/399484D7-62FE-44B3-BE62-42E5180B1919/worldflipper.app
CONT=/var/mobile/Containers/Data/Application/FC27FEB7-C7FE-43CB-A361-AC9C512F5846
BOOT="$CONT/tmp/SpCnBoot-stdout.log"
DATA="$CONT/Documents/SpCn/data"
SSHOPT="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
run() { sshpass -p "$PASS" ssh $SSHOPT "root@$HOST" "$@"; }

echo "== 进程 / 日志尺寸 =="
run "ps -A | grep '[w]orldflipper' | head -3; echo '进程数='\$(ps -A | grep -c '[w]orldflipper'); ls -l '$BOOT' '$DATA/spcn-server.log' 2>/dev/null | awk '{print \$5\" B  \"\$6\" \"\$7\" \"\$8\"  \"\$9}'"
echo
echo "== 引导 stdout 最后 $N 行（原样）=="
run "tail -n $N '$BOOT'"
echo
echo "== 服务端日志：最后 12 行 =="
run "tail -n 12 '$DATA/spcn-server.log' 2>/dev/null"
echo
echo "== 服务端日志：请求分类（只认 fastify 的 incoming 行）=="
run "grep -a '\"req\":{\"method\"' '$DATA/spcn-server.log' 2>/dev/null | sed 's/.*\"url\":\"//; s/\".*//' | sort | uniq -c | sort -rn | head -12"
echo
echo "== 最近 25 分钟的崩溃报告 =="
run "find /var/mobile/Library/Logs/CrashReporter -name 'worldflipper*.ips' -newermt '-25 minutes' 2>/dev/null | head -5; ls -lt /var/mobile/Library/Logs/CrashReporter/ | head -4"
