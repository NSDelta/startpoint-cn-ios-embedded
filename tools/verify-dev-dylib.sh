#!/usr/bin/env bash
# verify-dev-dylib.sh —— 核对设备上那份 SpCnEmbedded.dylib 是不是我们刚构建的那份。
# 用法: bash tools/verify-dev-dylib.sh [host] [pass] [container-uuid]
set -uo pipefail
HOST="${1:-192.168.0.100}"
PASS="${2:-qweasd}"
UUID="${3:-399484D7-62FE-44B3-BE62-42E5180B1919}"
APP="/var/containers/Bundle/Application/$UUID/worldflipper.app"
BUILD_DIR="${SPCN_BUILD_DIR:-/home/ubuntu/spcn-build}"
LOCAL="$BUILD_DIR/.theos/obj/SpCnEmbedded.dylib"

echo "== 主机侧（$LOCAL）=="
ls -l "$LOCAL" 2>&1
md5sum "$LOCAL" 2>&1
echo "  含 DIAG 串：$(strings -a "$LOCAL" 2>/dev/null | grep -c DIAG)"
echo "  含 SpCnIdentityDiag：$(strings -a "$LOCAL" 2>/dev/null | grep -c SpCnIdentityDiag)"
echo "  含 __interpose：$(strings -a "$LOCAL" 2>/dev/null | grep -c interpose)"

echo
echo "== 设备侧（$APP/Frameworks/SpCnEmbedded.dylib）=="
sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 \
  -o PreferredAuthentications=password,keyboard-interactive,publickey "root@$HOST" "
  set +e
  ls -l '$APP/Frameworks/SpCnEmbedded.dylib' 2>&1
  md5sum '$APP/Frameworks/SpCnEmbedded.dylib' 2>&1
  echo \"  含 DIAG 串：\$(strings -a '$APP/Frameworks/SpCnEmbedded.dylib' | grep -c DIAG)\"
  echo \"  含 SpCnIdentityDiag：\$(strings -a '$APP/Frameworks/SpCnEmbedded.dylib' | grep -c SpCnIdentityDiag)\"
  echo '  ---- 引导日志里的 DIAG / 谎报行 ----'
  T=/var/mobile/Containers/Data/Application/FC27FEB7-C7FE-43CB-A361-AC9C512F5846/tmp/SpCnBoot-stdout.log
  grep -c DIAG \"\$T\"
  grep DIAG \"\$T\" | tail -10
  echo '  ---- 偏好文件 ----'
  cat /var/mobile/Containers/Data/Application/FC27FEB7-C7FE-43CB-A361-AC9C512F5846/Documents/SpCn/data/spcn-conf.plist 2>&1
" 2>&1
