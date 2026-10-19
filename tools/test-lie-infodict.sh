#!/usr/bin/env bash
# test-lie-infodict.sh —— 验证「infoDictionary 谎报」是否解掉 AIR 的 packaging error
#   IDA 实证：AIR 的 -[CTAppDescriptor appID] 是读 [[NSBundle mainBundle] infoDictionary][@"CFBundleIdentifier"]
#   做法：plist id 保持 com.testdj.wf；偏好里设 IdentityLie=com.leiting.wf（30 s 窗口）；
#        改完重启，只统计「本次新增 stdout」里的 packaging error。
set -uo pipefail
HOST="${1:-192.168.0.100}"
PASS="${2:-qweasd}"
APP=/var/containers/Bundle/Application/399484D7-62FE-44B3-BE62-42E5180B1919/worldflipper.app
CONT=/var/mobile/Containers/Data/Application/FC27FEB7-C7FE-43CB-A361-AC9C512F5846
DATA="$CONT/Documents/SpCn/data"
SSH="sshpass -p $PASS ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o PreferredAuthentications=password,keyboard-interactive,publickey root@$HOST"

echo "== 1. 把 Info.plist 的 id 还原成 com.testdj.wf =="
bash /mnt/d/spcntweak/tools/test-bundleid-revert.sh revert 2>&1 | tail -3

echo "== 2. 写偏好（IdentityLie=com.leiting.wf，30 s）=="
bash /mnt/d/spcntweak/tools/set-conf-ondevice.sh --identity-lie=com.leiting.wf --identity-lie-seconds=30 --no-kill 2>&1 | tail -3

echo "== 3. 拉起（按 App 路径，锁屏也能远程拉起）=="
BEFORE=$($SSH "wc -c < '$CONT/tmp/SpCnBoot-stdout.log' 2>/dev/null | tr -d ' \r' || echo 0")
echo "  旧 stdout 字节数 = $BEFORE"
$SSH "killall -9 worldflipper 2>/dev/null; sleep 1; uiopen '$APP' >/dev/null 2>&1; sleep 1; echo launched" 2>&1 | tail -1

echo "== 4. 等 35 s 收集 =="
sleep 35
echo "  本次新增 stdout 行数：$($SSH "tail -c +$((BEFORE+1)) '$CONT/tmp/SpCnBoot-stdout.log' 2>/dev/null | wc -l | tr -d ' \r'")"
echo "  本次 packaging error 次数：$($SSH "tail -c +$((BEFORE+1)) '$CONT/tmp/SpCnBoot-stdout.log' 2>/dev/null | grep -a -c 'packaging error' || true")"
echo
echo "== 5. 本次新增 stdout 里 AIR 相关行 =="
$SSH "tail -c +$((BEFORE+1)) '$CONT/tmp/SpCnBoot-stdout.log' 2>/dev/null | grep -a -e 'AdobeAIR' -e 'packaging' -e 'InfoAdditions' -e 'applicationDescriptor' | tail -n 12" 2>&1
echo
echo "== 6. 数据卷日志：谎报是否生效 =="
$SSH "grep -a -e 'infoDictionary 谎报' -e '身份诊断已装' '$DATA/SpCnEmbedded.log' 2>/dev/null | tail -n 4" 2>&1
echo
echo "== 7. 服务端是否收到客户端请求（非 /healthz）=="
$SSH "grep -a '\"req\":{\"method\"' '$DATA/spcn-server.log' 2>/dev/null | grep -a -v '/healthz' | tail -n 8" 2>&1
