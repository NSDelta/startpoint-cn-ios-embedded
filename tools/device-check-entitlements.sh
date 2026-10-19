#!/usr/bin/env bash
# device-check-entitlements.sh —— 看设备上「我们自己那个包」和「原版」的 entitlements 差异。
#
# 为什么：真机 stdout 只有 `AdobeAIR: application packaging error`（didFinishLaunching 后 150 ms，早于任何网络）。
# 二进制里**烧了一份 entitlements 副本**（0x661ee42 附近，含 `application-identifier = RUH384Q4E8.com.leiting.wf`），
# 而 AIR 的 packaging 自检很可能就是拿「进程当前 entitlements」与这份烧死的副本对照：
#   · 用户装的对照基线（局域网版，bundle id 未改）= AppSync 直装 ⇒ 原签名/entitlements 原样保留 ⇒ 自检过；
#   · 我们这个包 = TrollStore 装 ⇒ 伪签名重签会改写 entitlements ⇒ 自检不过。
# 本脚本把两边的 entitlements 与签名痕迹都取回来，判定这条假设。
#
# 用法：bash tools/device-check-entitlements.sh [host] [pass]
set -uo pipefail
HOST="${1:-192.168.0.100}"; PASS="${2:-qweasd}"
SSHOPT="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=8"

sshpass -p "$PASS" ssh $SSHOPT "root@$HOST" bash -s <<'REMOTE'
A=/var/containers/Bundle/Application
which ldid >/dev/null 2>&1 || echo "⚠️ 设备上没有 ldid"
for p in "$A"/*/worldflipper.app; do
  [ -d "$p" ] || continue
  echo "════ $p"
  # 包身份：二进制里字符串兜底（设备无 plutil）
  ID=$(strings -a "$p/Info.plist" 2>/dev/null | grep -a -m1 -E '^com\.[a-z0-9.]+$')
  echo "  Info.plist 里的 id 候选：$ID"
  echo "  ---- ldid -e（当前 entitlements）----"
  ldid -e "$p/worldflipper" 2>&1 | head -40
  echo "  ---- 签名块特征 ----"
  echo -n "    _CodeSignature/CodeResources: "
  [ -f "$p/_CodeSignature/CodeResources" ] && wc -c < "$p/_CodeSignature/CodeResources" || echo 无
  echo -n "    embedded.mobileprovision: "
  [ -f "$p/embedded.mobileprovision" ] && wc -c < "$p/embedded.mobileprovision" || echo 无
  echo -n "    binary mtime: "; ls -l "$p/worldflipper" | awk '{print $6, $7, $8}'
  echo
done
echo "════ 我们这份包由谁装的？（TrollStore 会留痕迹）"
ls -la /var/mobile/Library/Preferences/ 2>/dev/null | grep -i -E 'trollstore|com.opa334' | head
ls -d /Applications/TrollStore*.app /var/containers/Bundle/Application/*/TrollStore*.app 2>/dev/null | head
echo "════ 二进制里那份烧死的 entitlements 副本（我方视角，只读 200 字节）"
B=$(ls -d "$A"/*/worldflipper.app | while read -r x; do strings -a "$x/Info.plist" 2>/dev/null | grep -q 'com.testdj.wf' && echo "$x" && break; done)
echo "  单机版包：$B"
[ -n "$B" ] && strings -a "$B/worldflipper" | grep -a -A2 'application-identifier' | head -10
REMOTE
