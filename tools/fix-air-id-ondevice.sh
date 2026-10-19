#!/usr/bin/env bash
# fix-air-id-ondevice.sh —— 在设备上原地改已装 App 的 AIR 描述符 id（验证「黑屏 = AIR 打包自检」这个判断）。
# 只改 `META-INF/AIR/application.xml` 的 `<id>` 与 CDATA 里的 CFBundleURLName，其余一律不碰；可 --revert。
#
# 用法：bash tools/fix-air-id-ondevice.sh apply [bundle-id] [host] [pass]
#       bash tools/fix-air-id-ondevice.sh revert [bundle-id] [host] [pass]
#       bash tools/fix-air-id-ondevice.sh show   [bundle-id] [host] [pass]
set -uo pipefail
MODE="${1:-show}"
BID="${2:-com.testdj.wf}"
HOST="${3:-192.168.0.100}"
PASS="${4:-qweasd}"
SSH="sshpass -p $PASS ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 -o PreferredAuthentications=password,keyboard-interactive,publickey root@$HOST"
APP="/var/containers/Bundle/Application/399484D7-62FE-44B3-BE62-42E5180B1919/worldflipper.app"
F="$APP/META-INF/AIR/application.xml"
BAK="/var/mobile/spcn-test/application.xml.bak"

case "$MODE" in
  show)
    $SSH "echo '== 描述符 id =='; grep -a -o '<id>[^<]*</id>' '$F' | head -3; echo '== 大小/mtime =='; ls -l '$F'; echo '== 备份 =='; ls -l '$BAK' 2>&1" 2>&1
    ;;
  apply)
    $SSH "set -e
      mkdir -p /var/mobile/spcn-test
      [ -f '$BAK' ] || { cp -a '$F' '$BAK'; echo '已备份 $BAK'; }
      CUR=\$(grep -a -o '<id>[^<]*</id>' '$F' | head -1)
      echo \"改前：\$CUR\"
      sed -e 's|<id>[^<]*</id>|<id>$BID</id>|' -e 's|<key>CFBundleURLName</key>|<key>CFBundleURLName</key>|' '$F' > /tmp/appxml.tmp
      cp /tmp/appxml.tmp '$F'; rm -f /tmp/appxml.tmp
      chown _installd:_installd '$F' 2>/dev/null || true
      echo \"改后：\$(grep -a -o '<id>[^<]*</id>' '$F' | head -1)  大小 \$(stat -c%s '$F')\"
      killall -9 worldflipper 2>/dev/null || true
      echo '（已杀进程：请在手机上打开这个 App 看是否还黑屏）'" 2>&1
    ;;
  revert)
    $SSH "set -e
      [ -f '$BAK' ] || { echo '没有备份'; exit 4; }
      cp -a '$BAK' '$F'; chown _installd:_installd '$F' 2>/dev/null || true
      echo \"还原后：\$(grep -a -o '<id>[^<]*</id>' '$F' | head -1)\"
      killall -9 worldflipper 2>/dev/null || true" 2>&1
    ;;
  *) echo "用法: $0 apply|revert|show [bundle-id] [host] [pass]"; exit 1;;
esac
