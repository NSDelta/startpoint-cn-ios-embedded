#!/usr/bin/env bash
# client-errors-ondevice.sh —— 客户端启动期错误 + 版本接口实况（排查「获取版本信息失败」）
# 用法：bash tools/client-errors-ondevice.sh [host] [pass] [container-uuid]
set -uo pipefail
HOST="${1:-192.168.0.100}"
PASS="${2:-qweasd}"
CONTAINER="${3:-FC27FEB7-C7FE-43CB-A361-AC9C512F5846}"
APP=/var/containers/Bundle/Application/399484D7-62FE-44B3-BE62-42E5180B1919/worldflipper.app
STDOUT="/var/mobile/Containers/Data/Application/$CONTAINER/tmp/SpCnBoot-stdout.log"
LOG="/var/mobile/Containers/Data/Application/$CONTAINER/Documents/SpCn/data/spcn-server.log"
SSHOPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=8 -o PreferredAuthentications=password,keyboard-interactive,publickey"
SSH="sshpass -p $PASS ssh $SSHOPTS root@$HOST"

echo "== 1. 版本接口：客户端实际请求与响应码 =="
$SSH "grep -a 'client_release_ios.dis' '$LOG' | tail -6" 2>&1
echo "-- 非 2xx 响应（尾 8）--"
$SSH "grep -a 'request completed' '$LOG' | grep -a -v '\"statusCode\":2' | grep -a -v '\"statusCode\":3' | tail -8" 2>&1

echo
echo "== 2. 直接问服务端：/shijtswy/version/client_release_ios.dis =="
$SSH "curl -s -i --max-time 8 'http://127.0.0.1:8001/shijtswy/version/client_release_ios.dis' | head -25" 2>&1

echo
echo "== 3. 客户端 stdout 里的错误/版本相关行（尾 30）=="
$SSH "grep -a -E 'Error|error|FAIL|fail|失败|错误|版本|VerifyError|IOError' '$STDOUT' | tail -30" 2>&1

echo
echo "== 4. 客户端 stdout 最尾部 25 行（原样）=="
$SSH "tail -25 '$STDOUT'" 2>&1

echo
echo "== 5. 客户端眼里 AIR 载荷 =="
$SSH "ls -l '$APP/META-INF/AIR/' 2>&1 | head; ls -l '$APP' | head -12" 2>&1
