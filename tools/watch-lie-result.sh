#!/usr/bin/env bash
# watch-lie-result.sh —— 等用户手动打开 App，一旦有**新的**启动输出就把结论打出来
#   用法：bash tools/watch-lie-result.sh [host] [pass] [最長等待秒数]
set -uo pipefail
HOST="${1:-192.168.0.100}"
PASS="${2:-qweasd}"
DEADLINE="${3:-900}"
APP=/var/containers/Bundle/Application/399484D7-62FE-44B3-BE62-42E5180B1919/worldflipper.app
CONT=/var/mobile/Containers/Data/Application/FC27FEB7-C7FE-43CB-A361-AC9C512F5846
BOOT="$CONT/tmp/SpCnBoot-stdout.log"
DATA="$CONT/Documents/SpCn/data"
SSH="sshpass -p $PASS ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o PreferredAuthentications=password,keyboard-interactive,publickey root@$HOST"

BASE=$($SSH "wc -c < '$BOOT' 2>/dev/null | tr -d ' \r' || echo 0")
echo "基线字节数 = $BASE；等新一次启动（最多 ${DEADLINE}s）…"
WAITED=0
while [ "$WAITED" -lt "$DEADLINE" ]; do
  sleep 10
  WAITED=$((WAITED + 10))
  NOW=$($SSH "wc -c < '$BOOT' 2>/dev/null | tr -d ' \r' || echo 0")
  if [ "${NOW:-0}" -gt "${BASE:-0}" ]; then
    echo "★ 检测到新启动（+$((NOW - BASE)) 字节），等 25 s 收尾…"
    sleep 25
    NOW2=$($SSH "wc -c < '$BOOT' 2>/dev/null | tr -d ' \r' || echo 0")
    echo
    echo "== 1. 新启动里 packaging error 次数（0 = 解掉了 ★）=="
    $SSH "tail -c +$((BASE+1)) '$BOOT' 2>/dev/null | grep -a -c 'packaging error' || true"
    echo "== 2. 新启动里的 AIR/AdobeAIR 行 =="
    $SSH "tail -c +$((BASE+1)) '$BOOT' 2>/dev/null | grep -a -e 'AdobeAIR' -e 'packaging' | head -6"
    echo "== 3. 身份诊断安装行（要看 infoDictionary=ok）=="
    $SSH "grep -a '身份诊断已装' '$DATA/SpCnEmbedded.log' 2>/dev/null | tail -1"
    echo "== 4. infoDictionary 谎报行 =="
    $SSH "grep -a -e 'infoDictionary 谎报' '$DATA/SpCnEmbedded.log' 2>/dev/null | tail -4"
    echo "== 5. 客户端是否发了请求（非 /healthz）=="
    $SSH "grep -a '\"req\":{\"method\"' '$DATA/spcn-server.log' 2>/dev/null | grep -a -v '/healthz' | tail -6"
    echo "== 6. 服务端 healthz 就绪行 =="
    $SSH "grep -a -c 'healthz 就绪' '$DATA/SpCnEmbedded.log' 2>/dev/null || true"
    exit 0
  fi
  printf '  等待中… %ss（当前 %s 字节）\n' "$WAITED" "${NOW:-0}"
done
echo "超时：${DEADLINE}s 内没有新的启动输出"
