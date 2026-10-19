#!/usr/bin/env bash
# test-bundleid-revert.sh —— 在设备上把已装 App 的 Info.plist bundle id 改回官方值（或还原），用来判定
# 「AIR 的 application packaging error 到底跟不跟 bundle id 走」。
#
# 背景：设备上两个 worldflipper.app：
#   399484D7-… = 我们的 com.testdj.wf 单机包（TrollStore 装）→ 启动 150 ms 后 `AdobeAIR: application packaging error`，黑屏
#   C5A975A2-… = 之前能玩的局域网版（AppSync/Filza 装，bundle id 仍是 com.leiting.wf）
# 二者 META-INF/AIR 载荷逐字节一致，所以差异只剩：bundle id / entitlements / 我们注入的 dylib+runtime。
# 本脚本只动 Info.plist 的 `<string>com.testdj.wf</string>` → `com.leiting.wf`（其余一律不碰），跑完可 --revert。
#
# 用法：bash tools/test-bundleid-revert.sh apply|revert [host] [pass]
#       bash tools/test-bundleid-revert.sh show   [host] [pass]    # 只看当前值
set -uo pipefail
MODE="${1:-show}"
HOST="${2:-192.168.0.100}"
PASS="${3:-qweasd}"
SSH="sshpass -p $PASS ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 -o PreferredAuthentications=password,keyboard-interactive,publickey root@$HOST"
APP="/var/containers/Bundle/Application/399484D7-62FE-44B3-BE62-42E5180B1919/worldflipper.app"
BAK="/var/mobile/spcn-test/Info.plist.testdj.bak"

case "$MODE" in
  show)
    $SSH "echo '== 当前 bundle id =='; grep -A1 -a 'CFBundleIdentifier' '$APP/Info.plist' | head -4; echo; echo '== 备份是否存在 =='; ls -l '$BAK' 2>&1; echo; echo '== 格式 =='; head -c 40 '$APP/Info.plist'; echo" 2>&1
    ;;
  apply)
    $SSH "set -e
      mkdir -p /var/mobile/spcn-test
      if [ ! -f '$BAK' ]; then cp -a '$APP/Info.plist' '$BAK'; echo '已备份到 $BAK'; else echo '备份已存在，沿用'; fi
      grep -q '<string>com.testdj.wf</string>' '$APP/Info.plist' || { echo '当前不是 com.testdj.wf（先 --revert？）'; grep -A1 -a CFBundleIdentifier '$APP/Info.plist' | head -3; exit 3; }
      sed 's|<string>com.testdj.wf</string>|<string>com.leiting.wf</string>|' '$APP/Info.plist' > /tmp/Info.plist.tmp
      cp /tmp/Info.plist.tmp '$APP/Info.plist'; rm -f /tmp/Info.plist.tmp
      chown _installd:_installd '$APP/Info.plist' 2>/dev/null || true
      echo '== 改后 =='; grep -A1 -a CFBundleIdentifier '$APP/Info.plist' | head -3
      killall -9 worldflipper 2>/dev/null || true
      echo '（已杀进程，请手动打开 App）'" 2>&1
    ;;
  revert)
    $SSH "set -e
      [ -f '$BAK' ] || { echo '没有备份，无法还原'; exit 4; }
      cp -a '$BAK' '$APP/Info.plist'
      chown _installd:_installd '$APP/Info.plist' 2>/dev/null || true
      echo '== 还原后 =='; grep -A1 -a CFBundleIdentifier '$APP/Info.plist' | head -3
      killall -9 worldflipper 2>/dev/null || true" 2>&1
    ;;
  *) echo "用法: $0 apply|revert|show [host] [pass]"; exit 1;;
esac
