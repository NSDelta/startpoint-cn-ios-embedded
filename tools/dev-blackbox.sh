#!/usr/bin/env bash
# dev-blackbox.sh —— 黑屏现场取证：启动时间线（tmp 引导日志）+ AIR 自己的系统日志 + 两个容器的资源目录实况。
#
# 用法：bash tools/dev-blackbox.sh [--host 192.168.0.100] [--pass qweasd] [--new <容器UUID>] [--old <容器UUID>]
set -uo pipefail

HOST=192.168.0.100; USER_NAME=root; PASS=qweasd; NEW=""; OLD=""
while [ $# -gt 0 ]; do
  case "$1" in
    --host) HOST="$2"; shift 2;;
    --user) USER_NAME="$2"; shift 2;;
    --pass) PASS="$2"; shift 2;;
    --new) NEW="$2"; shift 2;;
    --old) OLD="$2"; shift 2;;
    *) echo "未知参数：$1"; exit 2;;
  esac
done

SSHOPT="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
run() { sshpass -p "$PASS" ssh $SSHOPT "$USER_NAME@$HOST" "$@"; }

run "NEW='$NEW' OLD='$OLD' bash -s" <<'REMOTE'
B=/var/mobile/Containers/Data/Application
if [ -z "$NEW" ]; then
  for p in $B/*/; do [ -d "$p/Documents/SpCn" ] && NEW=$(basename "$p") && break; done
fi
if [ -z "$OLD" ]; then
  for p in $B/*/; do
    if [ -d "$p/Library/Application Support/com.leiting.wf/Local Store" ] || [ -d "$p/Library/Application Support/Local Store" ]; then
      [ "$(basename "$p")" != "$NEW" ] && OLD=$(basename "$p") && break
    fi
  done
fi
echo "新容器（单机版）$NEW"
echo "老容器（com.leiting.wf）$OLD"

echo
echo "== 1. 本次启动时间线（tmp 引导日志：attach / 延迟 / 后端判定）=="
tail -30 "$B/$NEW/tmp/SpCnEmbedded.log" 2>/dev/null || echo "  （没有 tmp 日志）"

echo
echo "== 2. 数据卷日志开头（第一次 setLogFile 的时间点）=="
ls -l "$B/$NEW/Documents/SpCn/data/SpCnEmbedded.log" 2>/dev/null
grep -n -m3 -E '^[0-9]+\.[0-9]+ ' "$B/$NEW/Documents/SpCn/data/SpCnEmbedded.log" 2>/dev/null | head -3
echo "  —— 尾部："
tail -6 "$B/$NEW/Documents/SpCn/data/SpCnEmbedded.log" 2>/dev/null

echo
echo "== 3. AIR 自己的日志（log show；这次不吞 stderr）=="
log show --last 6m --predicate 'processImagePath CONTAINS "worldflipper"' 2>&1 | tail -30

echo
echo "== 4. 新容器的资源目录（该有的东西到底在不在）=="
find "$B/$NEW/Library/Application Support" -maxdepth 3 2>/dev/null | head -30
echo "  —— SpCn 数据卷："
du -sh "$B/$NEW/Documents/SpCn" 2>/dev/null

echo
echo "== 5. 老容器的资源目录（参考：真有 9.8 GB 的那个）=="
if [ -n "$OLD" ]; then
  find "$B/$OLD/Library/Application Support" -maxdepth 3 2>/dev/null | head -20
  echo "  —— 体积："
  du -sh "$B/$OLD/Library/Application Support"/* 2>/dev/null | head -10
  echo "  —— Local Store 里有什么："
  ls -l "$B/$OLD/Library/Application Support/com.leiting.wf/Local Store" 2>/dev/null | head -10
  ls -l "$B/$OLD/Library/Application Support/Local Store" 2>/dev/null | head -10
fi

echo
echo "== 6. 磁盘与 APFS 克隆支持（cp -c 能不能用：同卷 COW 秒拷 9.8 GB）=="
df -h /var/mobile 2>/dev/null | tail -2
echo "  cp -c 支持：$(cp --help 2>&1 | grep -c -- '-c' || echo 0) （>0 表示支持 clonefile）"
REMOTE
