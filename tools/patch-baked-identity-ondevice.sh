#!/usr/bin/env bash
# patch-baked-identity-ondevice.sh —— 实验 E2：把主二进制里**烧死的身份记录**的 app id 也改成新 id。
#
# 为什么：实验矩阵已排除 plist 的 CFBundleIdentifier、plist 的 CFBundleURLName、描述符 <id>、
# 描述符 InfoAdditions 的 CFBundleURLName、entitlements 的 application-identifier/container ——
# 全部改成新 id 后 AIR 仍报 packaging error；而全部改回 com.leiting.wf 就不报。
# 剩下的身份来源只有二进制里那两条「app id + team id + 96 字节」记录（0x6521ffc / 0x661f106）。
# 记录体长度字段是 0x7a=122：`id\0` (15) + `team\0` (11) + 96 字节。这里**等长**改 id（补 NUL），
# 保持 96 字节不动（若那是签名/摘要，改了也无从复算 —— 只能先用「只比字符串」这一支来试）。
#
# 用法：bash tools/patch-baked-identity-ondevice.sh [bundle-id] [host] [pass]
set -uo pipefail
BID="${1:-com.testdj.wf}"
HOST="${2:-192.168.0.100}"
PASS="${3:-qweasd}"
APP="/var/containers/Bundle/Application/399484D7-62FE-44B3-BE62-42E5180B1919/worldflipper.app"
BIN="$APP/worldflipper"
TEAM="RUH384Q4E8"
SSH="sshpass -p $PASS ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 -o PreferredAuthentications=password,keyboard-interactive,publickey root@$HOST"

PAD=$(( 14 - ${#BID} ))
if [ "$PAD" -lt 0 ]; then echo "bundle id 太长（>14 字符）——这条记录改不了"; exit 1; fi
echo "新 id=$BID（$(( ${#BID} + 1 + PAD )) 字节含 NUL，原字段 15 字节），team=$TEAM"

echo "== 备份主二进制（只备一次）=="
$SSH "mkdir -p /var/mobile/spcn-test; [ -f /var/mobile/spcn-test/worldflipper.bak-e2 ] || cp -a '$BIN' /var/mobile/spcn-test/worldflipper.bak-e2; ls -l /var/mobile/spcn-test/worldflipper.bak-e2" 2>&1

write_field () {
  local off="$1"
  echo "-- 写 0x$off --"
  { printf '%s' "$BID"; printf '\0'; i=0; while [ "$i" -lt "$PAD" ]; do printf '\0'; i=$((i+1)); done; printf '%s\0' "$TEAM"; } \
    | $SSH "dd of='$BIN' bs=1 seek=$(( 16#$off )) conv=notrunc 2>&1 | tail -1"
}

for off in 6521ffc 661f106; do write_field "$off"; done

echo "== 回读（去掉 NUL 后应当是 <新id><team>）=="
for off in 6521ffc 661f106; do
  echo -n "  0x$off: "
  $SSH "dd if='$BIN' bs=1 skip=$(( 16#$off )) count=26 2>/dev/null | tr -d '\\0'; echo" 2>&1
done

echo "== 重签（先导出当前 entitlements，再用它签回去）=="
$SSH "ldid -e '$BIN' > /var/mobile/spcn-test/ent-current.plist; wc -c < /var/mobile/spcn-test/ent-current.plist; ldid -S/var/mobile/spcn-test/ent-current.plist '$BIN' && echo '重签 ok'" 2>&1
$SSH "killall -9 worldflipper 2>/dev/null; echo '（已杀进程）'" 2>&1
echo
echo "下一步：bash tools/relaunch-and-grab.sh $BID $HOST $PASS 45"
