#!/usr/bin/env bash
# test-identity-lie.sh —— 实验 E4：让 dylib 对 AIR 谎报 bundleIdentifier（默认 com.leiting.wf，启动后 8 秒内），
# 检验「AIR 的 application packaging error 来自 bundle id 对账」这一假设。
#
# 背景：身份全为 com.leiting.wf ⇒ 不报错；plist/描述符/entitlements 全改成 com.testdj.wf ⇒ 报错（连重签也救不了）。
# 若谎报能消掉这句错误，说明 AIR 读的是 `-[NSBundle bundleIdentifier]`（或经它派生），
# 那我们就能「OS 看到新 id（可共存安装）、AIR 看到旧 id（通过自检）」两全。
#
# 用法: bash tools/test-identity-lie.sh [lie-id] [real-bid] [host] [pass] [wait]
set -uo pipefail
LIE="${1:-com.leiting.wf}"
BID="${2:-com.testdj.wf}"
HOST="${3:-192.168.0.100}"
PASS="${4:-qweasd}"
WAIT="${5:-50}"
ROOT=/mnt/d/spcntweak

echo "== 1. 推最新 dylib + JS（--keep-conf：不动偏好）=="
bash "$ROOT/tools/push-dev-patch.sh" --host="$HOST" --pass="$PASS" --no-kill --keep-conf

echo
echo "== 2. 写偏好：谎报 $LIE（前 8 秒）+ 后端延迟 4s + auto =="
bash "$ROOT/tools/set-conf-ondevice.sh" --delay=4 --backend=auto --identity-lie="$LIE" --identity-lie-seconds=8 --host="$HOST" --pass="$PASS"

echo
echo "== 3. 拉起并抓本次新增 stdout =="
bash "$ROOT/tools/relaunch-and-grab.sh" "$BID" "$HOST" "$PASS" "$WAIT"

echo
echo "== 4. 诊断行（[DIAG] / packaging error）=="
CONTAINER=FC27FEB7-C7FE-43CB-A361-AC9C512F5846
sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -o PreferredAuthentications=password,keyboard-interactive,publickey "root@$HOST" \
  "T=/var/mobile/Containers/Data/Application/$CONTAINER/tmp/SpCnBoot-stdout.log;
   echo '--- [DIAG] 命中 ---'; grep -c 'DIAG' \$T; grep 'DIAG' \$T | tail -20;
   echo '--- packaging error 累计 ---'; grep -c 'packaging error' \$T;
   echo '--- 本次（尾部 40 行）---'; tail -40 \$T" 2>&1
