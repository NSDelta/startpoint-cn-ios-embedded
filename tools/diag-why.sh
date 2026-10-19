#!/usr/bin/env bash
# diag-why.sh —— 只看 longjmp / 身份诊断的关键行（避免刷屏被截断）
# 用法：bash tools/diag-why.sh [host] [pass]
set -uo pipefail
HOST="${1:-192.168.0.100}"
PASS="${2:-qweasd}"
CONT="/var/mobile/Containers/Data/Application/FC27FEB7-C7FE-43CB-A361-AC9C512F5846"
DATA="$CONT/Documents/SpCn/data"
SSH="sshpass -p $PASS ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 -o PreferredAuthentications=password,keyboard-interactive,publickey root@$HOST"

echo "== 身份诊断装载行（数据卷日志）=="
$SSH "grep -a -e '身份诊断已装' '$DATA/SpCnEmbedded.log' 2>/dev/null | tail -n 3" 2>&1
APP="/var/containers/Bundle/Application/399484D7-62FE-44B3-BE62-42E5180B1919/worldflipper.app"
echo
echo "== Info.plist 里的身份键（设备实际值）=="
$SSH "grep -a -A1 -e 'CFBundleIdentifier' -e 'CFBundleURLName' '$APP/Info.plist' 2>/dev/null" 2>&1
echo
echo "== 描述符 application.xml 里的身份键 =="
$SSH "grep -a -o -e '<id>[^<]*</id>' -e 'CFBundleURLName[^<]*' '$APP/META-INF/AIR/application.xml' 2>/dev/null | head -8" 2>&1
echo
echo "== ★ 引导日志（构造期，含 DIAG/longjmp）=="
$SSH "grep -a -e '\[DIAG\]' '$CONT/tmp/SpCnEmbedded.log' 2>/dev/null | tail -n 40" 2>&1
echo
echo "== 引导日志里 longjmp 关键字 =="
$SSH "grep -a -c -e 'longjmp' '$CONT/tmp/SpCnEmbedded.log' 2>/dev/null || true" 2>&1
echo
echo "== 崩溃报告清单（时间倒序，前 6）=="
$SSH "ls -lt /var/mobile/Library/Logs/CrashReporter/worldflipper-*.ips 2>/dev/null | head -6" 2>&1
echo
echo "== 最新崩溃里的关键字段 =="
NEWEST=$($SSH "ls -t /var/mobile/Library/Logs/CrashReporter/worldflipper-*.ips 2>/dev/null | head -1" 2>/dev/null | tr -d '\r')
if [ -n "${NEWEST:-}" ]; then
  echo "文件：$NEWEST"
  $SSH "head -c 900 '$NEWEST' 2>/dev/null" 2>&1
fi
