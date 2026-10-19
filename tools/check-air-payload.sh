#!/usr/bin/env bash
# check-air-payload.sh —— 检查设备上两个 App 的 META-INF/AIR 载荷是否完整（AIR 的 SWF 解密依赖它）。
#
# 背景：AIR 启动时会读 `META-INF/AIR/__swf__`（32 B，被 license 派生的密钥 XOR 的密钥材料）与
#       `META-INF/AIR/license.txt`（856 B）；任一读不到或内容不对，就会抛
#       `AdobeAIR: application packaging error`（AIR 运行时函数 sub_100011B94 的 setjmp 兜底）。
# 用法：bash tools/check-air-payload.sh [host] [pass]
set -uo pipefail
HOST="${1:-192.168.0.100}"
PASS="${2:-qweasd}"
SSH="sshpass -p $PASS ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 -o PreferredAuthentications=password,keyboard-interactive,publickey root@$HOST"

echo "== 两个 App 的 bundle 目录 =="
$SSH 'ls -d /var/containers/Bundle/Application/*/worldflipper.app' 2>&1

echo
echo "== 每个 App 的 META-INF/AIR（大小 + mtime） =="
$SSH 'for A in /var/containers/Bundle/Application/*/worldflipper.app; do
  echo "── $A"
  ls -l "$A/META-INF/AIR/__swf__" "$A/META-INF/AIR/license.txt" "$A/META-INF/AIR/application.xml" 2>&1
  echo "   extensions 目录数: $(ls "$A/META-INF/AIR/extensions" 2>/dev/null | wc -l)"
done' 2>&1

echo
echo "== 内容指纹（与官方包对比用） =="
$SSH 'for A in /var/containers/Bundle/Application/*/worldflipper.app; do
  echo "── $A"
  for F in META-INF/AIR/__swf__ META-INF/AIR/license.txt META-INF/AIR/application.xml; do
    printf "   %-34s " "$F"
    if [ -f "$A/$F" ]; then
      cksum "$A/$F" 2>/dev/null || echo "(无 cksum)"
    else
      echo "缺失"
    fi
  done
done' 2>&1

echo
echo "== 权限（Installd/TrollStore 有时会把 META-INF 改得不可读） =="
$SSH 'for A in /var/containers/Bundle/Application/*/worldflipper.app; do
  echo "── $A"; ls -ld "$A/META-INF" "$A/META-INF/AIR" 2>&1
  su -c "id -un" mobile 2>/dev/null >/dev/null
  echo "   （以 mobile 身份试读）"
  su mobile -c "cat \"$A/META-INF/AIR/__swf__\" > /dev/null && echo \"   __swf__ 可读\" || echo \"   __swf__ 不可读\"" 2>&1
done' 2>&1
