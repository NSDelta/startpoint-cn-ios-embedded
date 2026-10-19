#!/usr/bin/env bash
# push-plist-urlname.sh —— 实验 E1：把设备上 Info.plist 的 `CFBundleURLName` 也改成新 bundle id，
# 让它与 AIR 描述符 `<InfoAdditions>` 里的 `CFBundleURLName` 一致。
#
# 动机：实验矩阵
#   (b) plist id=testdj / 描述符 id=leiting（URLName 两边都是 leiting）      ⇒ 报 packaging error
#   (c) plist id=testdj / 描述符 id=testdj（描述符 URLName=testdj，plist URLName=leiting）⇒ 报错
#   (e) 同 (c) 且 entitlements 也改成新 id                                   ⇒ 报错
#   (d) plist/描述符/entitlements 全 leiting                                 ⇒ 不报错
# ⇒ 唯一与 (d) 的差别就是「字符串值本身」，所以 AIR 很可能在拿描述符与 plist 对账（id 或 InfoAdditions 里的键值）。
#    本脚本检验「InfoAdditions 里的 CFBundleURLName 必须与 plist 一致」这一支。
#
# 用法：bash tools/push-plist-urlname.sh [bundle-id] [host] [pass]
set -euo pipefail
BID="${1:-com.testdj.wf}"
HOST="${2:-192.168.0.100}"
PASS="${3:-qweasd}"
ROOT=/mnt/d/spcntweak
IPA="$ROOT/dist/spcn-ios-standalone-testdj.ipa"
APP="/var/containers/Bundle/Application/399484D7-62FE-44B3-BE62-42E5180B1919/worldflipper.app"
D=/var/mobile/spcn-test

echo "== 1. 主机侧：从 IPA 取出 Info.plist 并改 CFBundleURLName = $BID =="
node "$ROOT/tools/extract-info-plist.mjs" --ipa="$IPA" --bundle-id="$BID" --url-name="$BID" --out="$ROOT/.work/Info.plist.urlname"

echo "== 2. 上传 =="
sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -o PreferredAuthentications=password,keyboard-interactive,publickey "root@$HOST" \
  "mkdir -p $D; [ -f $D/Info.plist.bak-urlname ] || cp -a '$APP/Info.plist' $D/Info.plist.bak-urlname; echo 备份完成"
sshpass -p "$PASS" scp -o StrictHostKeyChecking=no -o PreferredAuthentications=password,keyboard-interactive,publickey \
  "$ROOT/.work/Info.plist.urlname" "root@$HOST:$D/Info.plist.new"

echo "== 3. 落到 App 包 + 杀进程 =="
sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -o PreferredAuthentications=password,keyboard-interactive,publickey "root@$HOST" \
  "cp -a $D/Info.plist.new '$APP/Info.plist'; chown mobile:mobile '$APP/Info.plist'; chmod 644 '$APP/Info.plist';
   echo '--- 现状 ---'; grep -A1 -E 'CFBundleIdentifier|CFBundleURLName' '$APP/Info.plist' | head -20;
   echo '--- 描述符里的 URLName ---'; grep -o 'CFBundleURLName[^<]*<string>[^<]*' '$APP/META-INF/AIR/application.xml';
   killall -9 worldflipper 2>/dev/null || true; echo '（已杀进程）'"
