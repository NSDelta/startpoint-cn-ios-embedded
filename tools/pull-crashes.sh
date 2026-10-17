#!/usr/bin/env bash
# pull-crashes.sh —— 把设备上最近的 worldflipper 崩溃报告拉到本机 .work/crash/，供 parse-crash.mjs 解析。
#
# 用法：bash tools/pull-crashes.sh --host 192.168.0.100 --pass qweasd [--count 4]
set -uo pipefail

HOST=""; USER_NAME="root"; PASS=""; COUNT=4
OUT=/mnt/d/spcntweak/.work/crash
while [ $# -gt 0 ]; do
  case "$1" in
    --host) HOST="${2:-}"; shift 2;;
    --user) USER_NAME="${2:-}"; shift 2;;
    --pass) PASS="${2:-}"; shift 2;;
    --count) COUNT="${2:-}"; shift 2;;
    --out) OUT="${2:-}"; shift 2;;
    *) echo "未知参数：$1"; exit 2;;
  esac
done
[ -n "$HOST" ] || { echo "需要 --host <设备IP> [--pass <密码>]"; exit 2; }

if [ -n "$PASS" ]; then
  SSH=(sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 "$USER_NAME@$HOST")
  SCP=(sshpass -p "$PASS" scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10)
else
  SSH=(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 "$USER_NAME@$HOST")
  SCP=(scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10)
fi

CRASHDIR=/var/mobile/Library/Logs/CrashReporter
mkdir -p "$OUT"
rm -f "$OUT"/*.ips 2>/dev/null

echo "== 设备上最近的 worldflipper 崩溃报告 =="
FILES=$("${SSH[@]}" "ls -t $CRASHDIR/worldflipper-*.ips 2>/dev/null | head -$COUNT")
if [ -z "$FILES" ]; then echo "  (没有)"; exit 0; fi
echo "$FILES" | sed 's/^/  /'

for f in $FILES; do
  base=$(basename "$f")
  "${SCP[@]}" "$USER_NAME@$HOST:$f" "$OUT/$base" >/dev/null 2>&1 && echo "  拉回 $base ($(stat -c%s "$OUT/$base" 2>/dev/null) B)" || echo "  ✗ $base 拉取失败"
done
echo
echo "解析：node tools/parse-crash.mjs --dir .work/crash"
