#!/usr/bin/env bash
# plist-urlname-ondevice.sh —— 实验 E1（设备侧版，不依赖 WSL 的 node）：
# 把 Info.plist 里剩下的身份串 com.leiting.wf 改成新 bundle id，让它与 AIR 描述符 <InfoAdditions> 一致。
#
# 动机：实验矩阵里唯一「不报错」的一档是所有身份都是 com.leiting.wf；而我们的包里
#       Info.plist 的 CFBundleIdentifier 改了、CFBundleURLName 没改 ⇒ 描述符与 plist 不一致。
# 用法：bash tools/plist-urlname-ondevice.sh [bundle-id] [host] [pass]
set -uo pipefail
BID="${1:-com.testdj.wf}"
HOST="${2:-192.168.0.100}"
PASS="${3:-qweasd}"
APP="/var/containers/Bundle/Application/399484D7-62FE-44B3-BE62-42E5180B1919/worldflipper.app"
SSH="sshpass -p $PASS ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 -o PreferredAuthentications=password,keyboard-interactive,publickey root@$HOST"

echo "== 改前 =="
$SSH "grep -a -A1 -e 'CFBundleIdentifier' -e 'CFBundleURLName' '$APP/Info.plist' | head -12" 2>&1
echo "  包里 com.leiting.wf 出现次数：$($SSH "grep -a -c -e 'com\\.leiting\\.wf' '$APP/Info.plist'" 2>/dev/null | tr -d '\r')"

echo "== 备份 + 替换 =="
$SSH "mkdir -p /var/mobile/spcn-test; [ -f /var/mobile/spcn-test/Info.plist.bak-e1 ] || cp -a '$APP/Info.plist' /var/mobile/spcn-test/Info.plist.bak-e1; echo '备份 /var/mobile/spcn-test/Info.plist.bak-e1'" 2>&1
$SSH "sed -i 's|<string>com\\.leiting\\.wf</string>|<string>$BID</string>|g' '$APP/Info.plist'; chown mobile:mobile '$APP/Info.plist'; chmod 644 '$APP/Info.plist'; echo '替换完成'" 2>&1

echo "== 改后 =="
$SSH "grep -a -A1 -e 'CFBundleIdentifier' -e 'CFBundleURLName' '$APP/Info.plist' | head -12" 2>&1
echo "  包里 com.leiting.wf 剩余次数：$($SSH "grep -a -c -e 'com\\.leiting\\.wf' '$APP/Info.plist'" 2>/dev/null | tr -d '\r')"
$SSH "killall -9 worldflipper 2>/dev/null; echo '（已杀进程）'" 2>&1
