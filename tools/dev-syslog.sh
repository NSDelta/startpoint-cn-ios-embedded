#!/usr/bin/env bash
# dev-syslog.sh —— 抓设备系统日志：客户端（AIR）启动到黑屏期间到底报了什么、有没有内存杀。
#
# 用法：bash tools/dev-syslog.sh --host 192.168.0.100 --pass qweasd [--minutes 15]
set -uo pipefail

HOST=""; USER_NAME="root"; PASS=""; MINUTES=15
while [ $# -gt 0 ]; do
  case "$1" in
    --host) HOST="${2:-}"; shift 2;;
    --user) USER_NAME="${2:-}"; shift 2;;
    --pass) PASS="${2:-}"; shift 2;;
    --minutes) MINUTES="${2:-}"; shift 2;;
    *) echo "未知参数：$1"; exit 2;;
  esac
done
[ -n "$HOST" ] || { echo "需要 --host <设备IP> [--pass <密码>]"; exit 2; }

if [ -n "$PASS" ]; then
  SSH=(sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 "$USER_NAME@$HOST")
else
  SSH=(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 "$USER_NAME@$HOST")
fi

"${SSH[@]}" "MIN='$MINUTES' bash -s" <<'REMOTE'
echo "== 1. worldflipper 自己的日志（含 AIR/CTAirSdk 输出）=="
log show --last "${MIN}m" --predicate 'process == "worldflipper"' --style compact 2>/dev/null | tail -100
echo
echo "== 2. 内存 / 被杀（jetsam、memorystatus、termination）=="
log show --last "${MIN}m" --predicate 'eventMessage CONTAINS "worldflipper" OR eventMessage CONTAINS "jetsam"' --style compact 2>/dev/null \
  | grep -i -E 'jetsam|memorystatus|killing|terminat|exceeded|highwater' | tail -40
echo
echo "== 3. SpringBoard / runningboard：为什么被拉起来/被终止 =="
log show --last "${MIN}m" --predicate 'process == "SpringBoard" OR process == "runningboardd"' --style compact 2>/dev/null \
  | grep -i 'worldflipper' | tail -40
echo
echo "== 4. 有没有 'SpCn' 前缀的 NSLog（我们 dylib 的）=="
log show --last "${MIN}m" --predicate 'eventMessage CONTAINS "SpCn"' --style compact 2>/dev/null | tail -30
echo
echo "== 5. 当前内存压力 =="
memory_pressure 2>/dev/null | tail -12 || vm_stat | head -8
REMOTE
