#!/usr/bin/env bash
# link-asset-id-ondevice.sh —— 让「被谎报成 com.leiting.wf 的 app id」也能找到资源。
# 背景：AIR 读 app id 走 -[NSBundle infoDictionary]（我们谎报成 com.leiting.wf），而客户端的资源路径约定是
#   <容器>/Library/Application Support/<app id>/Local Store —— 那份 9.8 GB 实际在 com.testdj.wf 下。
# 于是建一条 <AS>/com.leiting.wf -> com.testdj.wf 的符号链接（瞬间完成，不复制 9.8 GB），两边路径都能命中。
# 用法：bash tools/link-asset-id-ondevice.sh [host] [pass] [--remove]
set -uo pipefail
HOST="${1:-192.168.0.100}"; PASS="${2:-qweasd}"; RM=0
[ "${3:-}" = "--remove" ] && RM=1
CONT=/var/mobile/Containers/Data/Application/FC27FEB7-C7FE-43CB-A361-AC9C512F5846
AS="$CONT/Library/Application Support"
SSHOPT="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
run() { sshpass -p "$PASS" ssh $SSHOPT "root@$HOST" "$@"; }

echo "== 现状 =="
run "ls -la '$AS' | head -12"

if [ "$RM" = 1 ]; then
  echo; echo "== 删除链接 =="
  run "rm -f '$AS/com.leiting.wf'; ls -la '$AS' | head -8"
  exit 0
fi

echo
echo "== 建链接（若不存在）=="
run "cd '$AS' && [ -e com.leiting.wf ] && echo '  已存在，跳过' || { ln -s com.testdj.wf com.leiting.wf && echo '  已建 com.leiting.wf -> com.testdj.wf'; }"
echo
echo "== 校验（顺着链接读 info.json）=="
run "ls -la '$AS'; echo '--- 跟进 ---'; ls -l '$AS/com.leiting.wf/Local Store/asset/asset_download/dummy/info.json' 2>&1; wc -c < '$AS/com.leiting.wf/Local Store/asset/asset_download/dummy/info.json' 2>&1"
