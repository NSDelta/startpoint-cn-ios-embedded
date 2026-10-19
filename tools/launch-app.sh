#!/usr/bin/env bash
# launch-app.sh —— 干净地远程拉起我们的 App 并报告证据（进程 pid / 日志增长 / AIR 关键行）
#   ★ 关键：uiopen 只能「前台化」已经在跑的进程，那样构造函数不会再跑 ⇒ 必须先确认真的杀干净了。
#   用法：bash tools/launch-app.sh [host] [pass] [等待秒数]
set -uo pipefail
HOST="${1:-192.168.0.100}"
PASS="${2:-qweasd}"
WAIT="${3:-20}"
APP=/var/containers/Bundle/Application/399484D7-62FE-44B3-BE62-42E5180B1919/worldflipper.app
CONT=/var/mobile/Containers/Data/Application/FC27FEB7-C7FE-43CB-A361-AC9C512F5846
BOOT="$CONT/tmp/SpCnBoot-stdout.log"
SSH="sshpass -p $PASS ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o PreferredAuthentications=password,keyboard-interactive,publickey root@$HOST"

echo "== 1. 杀干净并确认 =="
$SSH "killall -9 worldflipper 2>/dev/null; sleep 2; ps -A | grep -c '[w]orldflipper' || true" 2>&1
BEFORE=$($SSH "wc -c < '$BOOT' 2>/dev/null | tr -d ' \r' || echo 0")
echo "  杀后进程数（上）／旧日志字节数 = $BEFORE"

echo "== 2. uiopen（按 App 路径）=="
$SSH "uiopen '$APP' 2>&1; echo \"uiopen_rc=\$?\"" 2>&1 | tail -2
sleep "$WAIT"

echo "== 3. 拉起后证据 =="
$SSH "ps -A | grep '[w]orldflipper' | head -3; echo '--- 日志 ---'; wc -c < '$BOOT' 2>/dev/null" 2>&1
echo "== 4. 本次新增 stdout（关键行）=="
$SSH "tail -c +$((BEFORE+1)) '$BOOT' 2>/dev/null | grep -a -e 'BOOT' -e 'PROBE' -e 'AdobeAIR' -e 'packaging' -e 'DIAG' | head -20" 2>&1
echo "== 5. 本次新增 stdout 的 packaging error 计数 =="
$SSH "tail -c +$((BEFORE+1)) '$BOOT' 2>/dev/null | grep -a -c 'packaging error' || true" 2>&1
