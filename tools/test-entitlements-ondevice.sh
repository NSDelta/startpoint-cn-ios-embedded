#!/usr/bin/env bash
# test-entitlements-ondevice.sh —— 在设备上把 App 的 entitlements 重签成「application-identifier 跟新 bundle id 一致」，
# 用来判定 AIR 的 `application packaging error` 到底是不是在拿 entitlements 里的 application-identifier 对账。
#
# 背景（已验证的事实）：
#   · plist/描述符都改成 com.testdj.wf ⇒ 仍报 packaging error（20:56）
#   · plist/描述符都改回 com.leiting.wf ⇒ 立刻不报（20:57/20:58）
#   · 但安装器（TrollStore）只把 `com.apple.private.security.container-required` 改成了新 id，
#     `application-identifier` 仍是 `RUH384Q4E8.com.leiting.wf` ⇒ 身份自相矛盾，这是最后一个嫌疑点。
#
# 用法：bash tools/test-entitlements-ondevice.sh apply  [bundle-id] [host] [pass]
#       bash tools/test-entitlements-ondevice.sh revert [bundle-id] [host] [pass]
#       bash tools/test-entitlements-ondevice.sh show   [bundle-id] [host] [pass]
set -uo pipefail
MODE="${1:-show}"
BID="${2:-com.testdj.wf}"
HOST="${3:-192.168.0.100}"
PASS="${4:-qweasd}"
SSH="sshpass -p $PASS ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 -o PreferredAuthentications=password,keyboard-interactive,publickey root@$HOST"
APP="/var/containers/Bundle/Application/399484D7-62FE-44B3-BE62-42E5180B1919/worldflipper.app"
BIN="$APP/worldflipper"
D="/var/mobile/spcn-test"
CUR="$D/ent-current.plist"
NEW="$D/ent-rewritten.plist"

case "$MODE" in
  show)
    $SSH "echo '== 当前 entitlements（ldid -e）=='; ldid -e '$BIN'; echo; echo '== 文件 =='; ls -l '$CUR' '$NEW' 2>&1" 2>&1
    ;;
  apply)
    $SSH "set -e
      mkdir -p '$D'
      [ -f '$CUR' ] || ldid -e '$BIN' > '$CUR'
      echo '== 现行 entitlements =='; cat '$CUR'
      sed -e 's|<string>RUH384Q4E8[.]com[.]leiting[.]wf</string>|<string>RUH384Q4E8.$BID</string>|' \
          -e 's|<string>com[.]leiting[.]wf</string>|<string>$BID</string>|' '$CUR' > '$NEW'
      echo; echo '== 改写后 =='; cat '$NEW'
      cp -a '$BIN' '$D/worldflipper.orig-signed' 2>/dev/null || true
      ldid -S'$NEW' '$BIN'
      echo; echo '== 重签后回读 =='; ldid -e '$BIN'
      killall -9 worldflipper 2>/dev/null || true
      echo '（已重签并杀进程）'" 2>&1
    ;;
  revert)
    $SSH "set -e
      [ -f '$CUR' ] || { echo '没有备份的 entitlements'; exit 4; }
      ldid -S'$CUR' '$BIN'
      echo '== 还原后 =='; ldid -e '$BIN'
      killall -9 worldflipper 2>/dev/null || true" 2>&1
    ;;
  *) echo "用法: $0 apply|revert|show [bundle-id] [host] [pass]"; exit 1;;
esac
