#!/usr/bin/env bash
# device-signcheck.sh —— 看设备上两个安装包的「签名/描述文件」状态。
#
# 为什么：真机黑屏时 stdout 只有 `AdobeAIR: application packaging error`。两个候选原因：
#   ① AIR 的应用身份（烧在二进制里）与 CFBundleIdentifier 不一致（我们改了 bundle id）；
#   ② 安装方式：AppSync/Filza 直装未签名 IPA ⇒ 没有真实签名/描述文件，AIR 自检不过。
# 这个脚本把 ② 的现场取回来：有没有 embedded.mobileprovision、CodeResources 多大、有没有 SC_Info（App Store DRM）。
#
# 用法：bash tools/device-signcheck.sh [host] [pass]
set -uo pipefail
HOST="${1:-192.168.0.100}"; PASS="${2:-qweasd}"
SSHOPT="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=8"

sshpass -p "$PASS" ssh $SSHOPT "root@$HOST" bash -s <<'REMOTE'
A=/var/containers/Bundle/Application
for p in "$A"/*/worldflipper.app; do
  [ -d "$p" ] || continue
  echo "════ $p"
  # 这个包是谁：读 Info.plist 里的 CFBundleIdentifier（设备上没有 plutil，用 strings 兜底）
  echo -n "  bundle id: "
  grep -a -A1 '<key>CFBundleIdentifier</key>' "$p/Info.plist" 2>/dev/null | tail -1 | sed 's/[[:space:]]*//g' | head -1
  [ -z "$(grep -a -A1 '<key>CFBundleIdentifier</key>' "$p/Info.plist" 2>/dev/null)" ] && \
    strings -a "$p/Info.plist" 2>/dev/null | grep -a -m1 '^com\.' || true
  echo "  顶层文件（前 24）："
  ls -la "$p" | head -24 | sed 's/^/    /'
  echo -n "  embedded.mobileprovision: "
  if [ -f "$p/embedded.mobileprovision" ]; then wc -c < "$p/embedded.mobileprovision"; else echo "无"; fi
  echo -n "  _CodeSignature/CodeResources: "
  if [ -f "$p/_CodeSignature/CodeResources" ]; then wc -c < "$p/_CodeSignature/CodeResources"; else echo "无"; fi
  echo -n "  SC_Info（App Store DRM）: "
  if [ -d "$p/SC_Info" ]; then ls "$p/SC_Info" | tr '\n' ' '; echo; else echo "无"; fi
  echo -n "  主二进制权限/体积: "
  ls -l "$p/worldflipper" 2>/dev/null | awk '{print $1, $5}'
  echo -n "  Frameworks 目录: "
  ls "$p/Frameworks" 2>/dev/null | tr '\n' ' '; echo
  echo "  安装时间（包目录 mtime）: $(ls -ld "$p" | awk '{print $6, $7, $8}')"
  echo
done
echo "════ 其它可能的安装痕迹"
ls -la /var/mobile/Library/Caches/ 2>/dev/null | grep -i -E 'appsync|sideloadly|altstore|filza' | head
echo "== AppSync 包是否装（dpkg）"
dpkg -l 2>/dev/null | grep -i -E 'appsync|appsinc' | head -3
REMOTE
