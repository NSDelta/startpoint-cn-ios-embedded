#!/usr/bin/env bash
# list-apps-ondevice.sh —— 设备上所有 worldflipper.app 的实况：
#   容器 UUID / bundle id / SpCnRuntime 体积与 ios-entry.js / NodeMobile / 我们的 dylib（体积+时间+md5）/ 主二进制
HOST="${1:-192.168.0.100}"
PASS="${2:-qweasd}"
SSH="sshpass -p $PASS ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o PreferredAuthentications=password,keyboard-interactive,publickey root@$HOST"

$SSH 'for d in /var/containers/Bundle/Application/*/worldflipper.app; do
  [ -d "$d" ] || continue
  uuid=$(echo "$d" | rev | cut -d/ -f2 | rev)
  bid=$(grep -a -A2 "CFBundleIdentifier" "$d/Info.plist" 2>/dev/null | grep -a "<string>" | head -1 | sed "s/.*<string>//; s/<\/string>.*//")
  echo "=== 容器 $uuid"
  echo "    bundle id      : ${bid:-<没读到>}"
  echo "    Info.plist     : $(stat -c%s "$d/Info.plist") B   $外的(stat -c%y "$d/Info.plist" 2>/dev/null | cut -d. -f1)"
  echo "    SpCnRuntime    : $([ -d "$d/SpCnRuntime" ] && du -sh "$d/SpCnRuntime" | cut -f1 || echo 无)"
  echo "    ios-entry.js   : $([ -f "$d/SpCnRuntime/ios-entry.js" ] && echo "有 $(stat -c%s "$d/SpCnRuntime/ios-entry.js") B" || echo 无)"
  echo "    node 可执行体  : $([ -f "$d/SpCnRuntime/node-ios-arm64/node" ] && ls -l "$d/SpCnRuntime/node-ios-arm64/node" | awk "{print \$1, \$5\" B\"}" || echo 无)"
  echo "    NodeMobile     : $([ -f "$d/Frameworks/NodeMobile.framework/NodeMobile" ] && echo "有 $(stat -c%s "$d/Frameworks/NodeMobile.framework/NodeMobile") B" || echo 无)"
  if [ -f "$d/Frameworks/SpCnEmbedded.dylib" ]; then
    echo "    SpCnEmbedded   : $(stat -c%s "$d/Frameworks/SpCnEmbedded.dylib") B  $(stat -c%y "$d/Frameworks/SpCnEmbedded.dylib" | cut -d. -f1)  md5=$(md5sum "$d/Frameworks/SpCnEmbedded.dylib" | cut -c1-32)"
    echo "      DIAG 串      : SpCnIdentityDiag=$(grep -c -a SpCnIdentityDiag "$d/Frameworks/SpCnEmbedded.dylib" 2>/dev/null)  infoDictionary=$(grep -c -a "infoDictionary 谎报" "$d/Frameworks/SpCnEmbedded.dylib" 2>/dev/null)"
  else
    echo "    SpCnEmbedded   : 无"
  fi
  echo "    主二进制       : $(stat -c%s "$d/worldflipper") B  $(stat -c%y "$d/worldflipper" | cut -d. -f1)  md5=$(md5sum "$d/worldflipper" | cut -c1-32)"
done' 2>&1
