#!/usr/bin/env bash
# probe-crash.sh —— 一次搞清楚「闪退」：进程状态 / 最近的崩溃或诊断文件 / 引导日志有没有长 / 主二进制指纹
set -uo pipefail
HOST="${1:-192.168.0.100}"
PASS="${2:-qweasd}"
APP=/var/containers/Bundle/Application/399484D7-62FE-44B3-BE62-42E5180B1919/worldflipper.app
CONT=/var/mobile/Containers/Data/Application/FC27FEB7-C7FE-43CB-A361-AC9C512F5846
SSH="sshpass -p $PASS ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o PreferredAuthentications=password,keyboard-interactive,publickey root@$HOST"

echo "== 1. 进程 =="
$SSH "ps -A | grep '[w]orldflipper' | head -4; echo '---'; ps -A | grep -c '[w]orldflipper'" 2>&1
echo
echo "== 2. 最近 20 分钟内新增的崩溃/诊断文件（全盘常见目录）=="
$SSH "find /var/mobile/Library/Logs /var/mobile/Library/DiagnosticReports /var/containers/Data/System -name '*.ips' -newermt '-25 minutes' 2>/dev/null | head -20" 2>&1
echo
echo "== 3. CrashReporter 目录最近的 worldflipper 报告（含 Jetsam）=="
$SSH "ls -lt /var/mobile/Library/Logs/CrashReporter/ 2>/dev/null | head -8" 2>&1
echo
echo "== 4. 引导日志大小/时间（有没有新一次启动）=="
$SSH "ls -l '$CONT/tmp/SpCnBoot-stdout.log'; wc -c < '$CONT/tmp/SpCnBoot-stdout.log'" 2>&1
echo
echo "== 5. 主二进制指纹 =="
$SSH "ls -l '$APP/worldflipper'; md5sum '$APP/worldflipper'" 2>&1
echo
echo "== 6. 最近一次启动的最后 12 行（非 [SpCn]）=="
$SSH "tail -c 8000 '$CONT/tmp/SpCnBoot-stdout.log' 2>/dev/null | grep -a -v '\\[SpCn\\]' | tail -n 12" 2>&1
