#!/usr/bin/env bash
# device-identity-check.sh —— 设备侧「身份一致性」体检：把可能被 AIR 拿去对账的每一处都列出来。
# 用法: bash tools/device-identity-check.sh [host] [pass] [ours-container-uuid] [orig-container-uuid]
set -uo pipefail
HOST="${1:-192.168.0.100}"
PASS="${2:-qweasd}"
OURS="${3:-399484D7-62FE-44B3-BE62-42E5180B1919}"
ORIG="${4:-C5A975A2-3E37-43E1-85C3-8BE3648D81EB}"
SSH="sshpass -p $PASS ssh -o StrictHostKeyChecking=no -o ConnectTimeout=8 -o PreferredAuthentications=password,keyboard-interactive,publickey root@$HOST"
A="/var/containers/Bundle/Application/$OURS/worldflipper.app"
B="/var/containers/Bundle/Application/$ORIG/worldflipper.app"

$SSH "set +e
echo '=== 1. 我们的包（$OURS）顶层 ==='
ls -la '$A' | head -40
echo
echo '=== 2. 原版包（$ORIG）顶层 ==='
ls -la '$B' | head -40
echo
echo '=== 3. SC_Info（FairPlay DRM 元数据，若存在就是身份烧死处）==='
ls -la '$A/SC_Info' '$B/SC_Info' 2>&1
echo
echo '=== 4. 关键文件 md5 对照（描述符 / plist / __swf__ / license）==='
md5sum '$A/META-INF/AIR/application.xml' '$B/META-INF/AIR/application.xml' \
       '$A/Info.plist' '$B/Info.plist' \
       '$A/META-INF/AIR/__swf__' '$B/META-INF/AIR/__swf__' 2>&1
echo
echo '=== 5. CodeResources / 签名文件 ==='
ls -la '$A/_CodeSignature' '$B/_CodeSignature' 2>&1
echo
echo '=== 6. 我们二进制里两串身份的计数（应: com.testdj.wf 若干 / com.leiting.wf 仍在）==='
strings -a '$A/worldflipper' | grep -c 'com.testdj.wf'
strings -a '$A/worldflipper' | grep -c 'com.leiting.wf'
echo '--- 带 team id 的组合 ---'
strings -a '$A/worldflipper' | grep -o 'RUH384Q4E8[.a-zA-Z0-9]*' | sort | uniq -c
echo
echo '=== 7. 我们进程的 entitlements（与包内二进制比对）==='
ldid -e '$A/worldflipper' 2>&1 | head -20
echo
echo '=== 8. embedded.mobileprovision / DRM 相关文件 ==='
ls -la '$A/embedded.mobileprovision' 2>&1
find '$A' -maxdepth 2 -iname '*SC_Info*' -o -maxdepth 2 -iname '*.sinf' -o -maxdepth 2 -iname '*.supp' 2>/dev/null | head
echo
echo '=== 9. AIR 描述符里的 id（两包现状）==='
grep -o '<id>[^<]*</id>' '$A/META-INF/AIR/application.xml' '$B/META-INF/AIR/application.xml' 2>&1
" 2>&1
