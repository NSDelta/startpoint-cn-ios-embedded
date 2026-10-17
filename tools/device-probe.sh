#!/usr/bin/env bash
# 设备侧事实采集（只读，不改设备任何东西）
#   bash tools/device-probe.sh 192.168.0.100 [密码] [用户名]
set -uo pipefail
HOST="${1:-}"; PW="${2:-}"; USER_NAME="${3:-root}"
[ -n "$HOST" ] || { echo "用法: bash tools/device-probe.sh <ip> [密码] [用户名]"; exit 2; }

SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=8 -o NumberOfPasswordPrompts=1)
if [ -n "$PW" ] && command -v sshpass >/dev/null 2>&1; then
  export SSHPASS="$PW"
  SSH=(sshpass -e ssh "${SSH_OPTS[@]}" -o PreferredAuthentications=password -o PubkeyAuthentication=no "$USER_NAME@$HOST")
else
  SSH=(ssh "${SSH_OPTS[@]}" "$USER_NAME@$HOST")
fi

echo "== 连 $USER_NAME@$HOST =="
"${SSH[@]}" 'bash -s' <<'REMOTE' 2>&1
echo "机型 $(uname -m)   内核 $(uname -r)"
PV=$(/usr/bin/plutil -extract ProductVersion raw /System/Library/CoreServices/SystemVersion.plist 2>/dev/null)
echo "iOS ${PV:-?}"
if [ -d /var/jb ]; then echo "越狱模式 rootless（/var/jb 存在）"; else echo "越狱模式 rootful（无 /var/jb）"; fi
echo "dpkg $(command -v dpkg >/dev/null && echo 有 || echo 无)   apt $(command -v apt >/dev/null && echo 有 || echo 无)"
echo "--- 插件目录 ---"
for d in /var/jb/Library/MobileSubstrate/DynamicLibraries /Library/MobileSubstrate/DynamicLibraries; do
  if [ -d "$d" ]; then echo "[$d]"; ls -1 "$d" 2>/dev/null | head -25; fi
done
echo "--- 注入引擎 ---"
for k in /var/jb/usr/lib/libsubstitute.dylib /usr/lib/libsubstitute.dylib \
         /var/jb/usr/lib/libellekit.dylib /usr/lib/libellekit.dylib \
         /var/jb/Library/MobileSubstrate/MobileSubstrate.dylib /Library/MobileSubstrate/MobileSubstrate.dylib; do
  [ -e "$k" ] && echo "有 $k"
done
echo "--- 游戏 ---"
ls -d /var/containers/Bundle/Application/*/worldflipper.app 2>/dev/null || echo "未装 worldflipper"
echo "--- 安装/工具 ---"
for t in appinst ipainstaller uicache sbreload trollstorehelper TrollStoreHelper ldid ldid2; do
  p=$(command -v "$t" 2>/dev/null); [ -n "$p" ] && echo "$t = $p"
done
ls -d /Applications/TrollStore* 2>/dev/null
ls -d /var/mobile/Library/Application\ Support/TrollStore 2>/dev/null
echo "--- 空间 ---"
df -h /var/mobile / 2>/dev/null | tail -3
echo "--- 已装的相关包 ---"
dpkg -l 2>/dev/null | grep -iE 'spcn|splogin|substrate|ellekit|openssh|frida' | head -10
REMOTE
