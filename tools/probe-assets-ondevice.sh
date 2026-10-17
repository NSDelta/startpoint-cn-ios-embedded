#!/usr/bin/env bash
# probe-assets-ondevice.sh —— 只看不写：把设备上所有 "Local Store" 找出来量体积/文件数/版本，
# 并把每个容器 id 映射到 bundle id，用来确认「哪一份是真资源」「新容器该往哪拷」。
#
# 用法（WSL）：bash tools/probe-assets-ondevice.sh --host 192.168.0.100 --pass qweasd
set -uo pipefail

HOST=""; USER_NAME="root"; PASS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --host) HOST="${2:-}"; shift 2;;
    --user) USER_NAME="${2:-}"; shift 2;;
    --pass) PASS="${2:-}"; shift 2;;
    *) echo "未知参数：$1"; exit 2;;
  esac
done
[ -n "$HOST" ] || { echo "需要 --host <设备IP> [--pass <密码>]"; exit 2; }

if [ -n "$PASS" ]; then
  SSH=(sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 "$USER_NAME@$HOST")
else
  SSH=(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 "$USER_NAME@$HOST")
fi

"${SSH[@]}" 'bash -s' <<'REMOTE'
DC=/var/mobile/Containers/Data/Application

echo "== 1. 容器 id → bundle id =="
for f in $DC/*/.com.apple.mobile_container_manager.metadata.plist; do
  [ -f "$f" ] || continue
  d=$(dirname "$f")
  b=$(plutil -extract MCMMetadataIdentifier raw "$f" 2>/dev/null || grep -A1 MCMMetadataIdentifier "$f" 2>/dev/null | sed -n 's/.*<string>\(.*\)<\/string>.*/\1/p')
  echo "  $(basename "$d")  $b"
done

echo
echo "== 2. 所有 Local Store（体积 / asset 文件数 / info.json 版本）=="
for d in $(find $DC -maxdepth 6 -type d -name 'Local Store' 2>/dev/null); do
  n=$(find "$d/asset/asset_download" -type f 2>/dev/null | wc -l | tr -d ' ')
  s=$(du -sh "$d" 2>/dev/null | cut -f1)
  info="$d/asset/asset_download/dummy/info.json"
  if [ -f "$info" ]; then
    v=$(grep -o '"version"[^,}]*' "$info" 2>/dev/null | head -1 | cut -d: -f2 | tr -d '"')
    sz=$(grep -o '"totalSize"[^,}]*' "$info" 2>/dev/null | head -1 | cut -d: -f2)
  else
    v="(无 info.json)"; sz=""
  fi
  echo "  体积=${s:-?}  文件=${n}  版本=${v:-?}  声明总大小=${sz:-?}"
  echo "      $d"
  echo "      子目录: $(ls "$d/asset/asset_download" 2>/dev/null | tr '\n' ' ')"
done

echo
echo "== 3. com.testdj.wf 容器全貌（我们的单机版）=="
NEW=$(grep -rl 'com.testdj.wf' $DC/*/.com.apple.mobile_container_manager.metadata.plist 2>/dev/null | head -1 | xargs -r dirname)
if [ -z "$NEW" ]; then echo "  (找不到 com.testdj.wf 容器)"; else
  echo "  容器 $NEW"
  echo "  Library/Application Support 下:"; ls -la "$NEW/Library/Application Support" 2>/dev/null | head -20
  echo "  Documents 下:";               ls -la "$NEW/Documents" 2>/dev/null | head -20
  echo "  我们自己的数据卷:";            ls -la "$NEW/Documents/SpCn/data" 2>/dev/null | head
fi

echo
echo "== 4. 磁盘余量 =="
df -h / /private/preboot 2>/dev/null | head -5
REMOTE
