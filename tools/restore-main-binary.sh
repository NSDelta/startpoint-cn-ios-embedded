#!/usr/bin/env bash
# restore-main-binary.sh —— 修「framework dlopen 被 library validation 拒」：把主二进制还原成 TrollStore 重签后的原始备份
#   背景：为了让 AIR 的自检通过，我们反复用 ldid 重签过主二进制（改 entitlements、改烧死记录）。
#        重签会让 _CodeSignature/CodeResources 与 Frameworks 里的 dylib 不再匹配 ⇒
#        dlopen(NodeMobile.framework) 报 "mapping process is a platform binary, but mapped file is not"。
#   用法：bash tools/restore-main-binary.sh [host] [pass] [--apply]
set -uo pipefail
HOST="${1:-192.168.0.100}"
PASS="${2:-qweasd}"
APPLY="${3:-}"
APP=/var/containers/Bundle/Application/399484D7-62FE-44B3-BE62-42E5180B1919/worldflipper.app
SSH="sshpass -p $PASS ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o PreferredAuthentications=password,keyboard-interactive,publickey root@$HOST"

echo "== 备份清单 =="
$SSH "ls -l /var/mobile/spcn-test/ 2>/dev/null" 2>&1
echo
echo "== md5：当前主二进制 / orig-signed / bak-e2 =="
$SSH "md5sum '$APP/worldflipper' /var/mobile/spcn-test/worldflipper.orig-signed /var/mobile/spcn-test/worldflipper.bak-e2 2>&1" 2>&1
echo
echo "== 当前 entitlements =="
$SSH "ldid -e '$APP/worldflipper' 2>&1 | head -24" 2>&1
echo
echo "== Frameworks 目录 =="
$SSH "ls -l '$APP/Frameworks/' '$APP/Frameworks/NodeMobile.framework/' 2>&1 | head -20" 2>&1

if [ "$APPLY" = "--apply" ]; then
  echo
  echo "== 还原主二进制（用 orig-signed）=="
  $SSH "cp -p /var/mobile/spcn-test/worldflipper.orig-signed '$APP/worldflipper' && chown mobile:mobile '$APP/worldflipper' && chmod 0755 '$APP/worldflipper' && echo '已还原'; md5sum '$APP/worldflipper'" 2>&1
  echo "== 还原后 entitlements =="
  $SSH "ldid -e '$APP/worldflipper' 2>&1 | head -24" 2>&1
  $SSH "killall -9 worldflipper 2>/dev/null; echo '已杀进程'" 2>&1
fi
