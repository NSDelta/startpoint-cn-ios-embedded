#!/usr/bin/env bash
# set-backend-ondevice.sh —— 免重装 IPA 的快速验证通道：
#   直接改设备上的后端偏好（<DATA_DIR>/spcn-conf.plist 的 NodeBackend），可选重启游戏，然后盯 healthz。
#
# 为什么要这个：内嵌(framework)后端用的 NodeMobile.framework 是 --with-intl=none 编的（**没有 ICU**），
# 服务端 out/content/sync/ordered-map.js:6 的 `new TextDecoder("utf-8",{fatal:true})` 直接抛 ERR_NO_ICU；
# 而 App 包里那个独立 node 二进制实测有 Intl + fatal 可用 ⇒ 先切到 process 后端验证。
#
# 用法：bash tools/set-backend-ondevice.sh --host 192.168.0.100 --pass qweasd --backend process [--restart] [--wait 60]
set -uo pipefail

HOST=""; USER_NAME="root"; PASS=""; BACKEND="process"; BID="com.testdj.wf"; RESTART=0; WAIT=60
while [ $# -gt 0 ]; do
  case "$1" in
    --host) HOST="${2:-}"; shift 2;;
    --user) USER_NAME="${2:-}"; shift 2;;
    --pass) PASS="${2:-}"; shift 2;;
    --backend) BACKEND="${2:-}"; shift 2;;
    --bundle) BID="${2:-}"; shift 2;;
    --restart) RESTART=1; shift;;
    --wait) WAIT="${2:-}"; shift 2;;
    *) echo "未知参数：$1"; exit 2;;
  esac
done
[ -n "$HOST" ] || { echo "需要 --host <设备IP> [--pass <密码>]"; exit 2; }
case "$BACKEND" in auto|process|framework) ;; *) echo "--backend 只能是 auto|process|framework"; exit 2;; esac

if [ -n "$PASS" ]; then
  SSH=(sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 "$USER_NAME@$HOST")
else
  SSH=(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 "$USER_NAME@$HOST")
fi
remote() { "${SSH[@]}" "$@"; }

DC=/var/mobile/Containers/Data/Application
echo "== 1. 定位容器（$BID）=="
ROOT=$(remote "grep -rl '$BID' $DC/*/.com.apple.mobile_container_manager.metadata.plist 2>/dev/null | head -1 | xargs -r dirname")
[ -n "$ROOT" ] || { echo "  ✗ 找不到 $BID 的容器"; exit 1; }
DATA="$ROOT/Documents/SpCn/data"
CONF="$DATA/spcn-conf.plist"
echo "  数据卷 $DATA"

echo "== 2. 写后端偏好：NodeBackend=$BACKEND =="
XML="<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">
<plist version=\"1.0\">
<dict>
	<key>NodeBackend</key>
	<string>$BACKEND</string>
</dict>
</plist>"
B64=$(printf '%s' "$XML" | base64 | tr -d '\n')
remote "mkdir -p '$DATA' && printf '%s' '$B64' | base64 -d > '$CONF' && echo '  --- 写好了：' && cat '$CONF'"

if [ -f "$CONF" ] || true; then :; fi

if [ "$RESTART" = "1" ]; then
  echo "== 3. 重启游戏（让 constructor 用新偏好重来；同时把 framework 那次已烧掉的 V8 状态清零）=="
  remote "killall -9 worldflipper 2>/dev/null; sleep 1; (uiopen -b $BID 2>&1 || uiopen $BID 2>&1) | head -3; sleep 3; ps -A -o pid,user,etime,command 2>/dev/null | grep worldflipper | grep -v grep || ps -A | grep worldflipper | grep -v grep || echo '  ⚠️ 游戏没起来'"
fi

echo "== 4. 盯 healthz（最长 ${WAIT}s）=="
i=0
while [ "$i" -lt "$WAIT" ]; do
  H=$(remote "curl -s -m 3 http://127.0.0.1:8001/healthz" 2>/dev/null)
  if [ -n "$H" ]; then echo "  ✓ 第 ${i}s 通了："; echo "$H" | head -c 900; echo; break; fi
  i=$((i + 3))
  sleep 3
done
[ -n "${H:-}" ] || echo "  ✗ ${WAIT}s 内 8001 没起来"

echo ""
echo "== 5. 面板日志尾巴 =="
remote "tail -n 40 '$DATA/SpCnEmbedded.log' 2>/dev/null || echo '（没有日志）'"
echo "== 6. 服务端 stdout 尾巴 =="
remote "tail -n 40 '$DATA/spcn-server.log' 2>/dev/null || echo '（没有 spcn-server.log）'"
echo "== 7. 进程 =="
remote "ps -A -o pid,user,pcpu,etime,command 2>/dev/null | grep -E 'worldflipper|node' | grep -v grep || echo '（没有相关进程）'"
