#!/usr/bin/env bash
# set-conf-ondevice.sh —— 写设备上的 <DATA_DIR>/spcn-conf.plist（运行期偏好，SpCnConfig.reloadPreferences 每次读）。
#
# 支持的键：
#   StartupDelay          后端启动延迟秒数（默认 4，留给 AIR 内容加载）
#   NodeBackend           auto | process | framework
#   IdentityLie           对 AIR 谎报的 bundle id（如 com.leiting.wf；空 = 关闭）
#   IdentityLieSeconds    谎报窗口秒数（0 = 一直谎报；默认 8）
#
# 用法：
#   bash tools/set-conf-ondevice.sh --show
#   bash tools/set-conf-ondevice.sh --clear
#   bash tools/set-conf-ondevice.sh --delay=4 --backend=auto --identity-lie=com.leiting.wf --identity-lie-seconds=8
#   [--container=<uuid>] [--host=192.168.0.100] [--pass=qweasd] [--no-kill]
set -uo pipefail
HOST=192.168.0.100
PASS=qweasd
CONTAINER=FC27FEB7-C7FE-43CB-A361-AC9C512F5846
KILL=1
SHOW=0
CLEAR=0
DELAY=""
BACKEND=""
LIE=""
LIESEC=""
OVERLAY=""
BOXES=""

for a in "$@"; do
  case "$a" in
    --host=*) HOST="${a#*=}";;
    --pass=*) PASS="${a#*=}";;
    --container=*) CONTAINER="${a#*=}";;
    --delay=*) DELAY="${a#*=}";;
    --backend=*) BACKEND="${a#*=}";;
    --identity-lie=*) LIE="${a#*=}";;
    --identity-lie-seconds=*) LIESEC="${a#*=}";;
    --overlay=*) OVERLAY="${a#*=}";;
    --no-kill) KILL=0;;
    --show) SHOW=1;;
    --clear) CLEAR=1;;
    *) echo "未知参数：$a"; exit 1;;
  esac
done

DATA="/var/mobile/Containers/Data/Application/$CONTAINER/Documents/SpCn/data"
CONF="$DATA/spcn-conf.plist"
SSHOPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=8 -o PreferredAuthentications=password,keyboard-interactive,publickey"
SSH="sshpass -p $PASS ssh $SSHOPTS root@$HOST"
SCP="sshpass -p $PASS scp $SSHOPTS"

if [ "$SHOW" = 1 ]; then
  $SSH "echo '== $CONF =='; cat '$CONF' 2>&1; echo; echo '== dataDir 内容 =='; ls -la '$DATA' 2>&1 | head -20" 2>&1
  exit 0
fi

if [ "$CLEAR" = 1 ]; then
  $SSH "rm -f '$CONF'; echo 已删除 $CONF" 2>&1
  [ "$KILL" = 1 ] && $SSH "killall -9 worldflipper 2>/dev/null; echo 已杀进程" 2>&1
  exit 0
fi

# 组装 plist
ENTRIES=""
add_str() { ENTRIES="$ENTRIES	<key>$1</key>
	<string>$2</string>
"; }
[ -n "$BACKEND" ] && add_str NodeBackend "$BACKEND"
[ -n "$LIE" ] && add_str IdentityLie "$LIE"
add_real() { ENTRIES="$ENTRIES	<key>$1</key>
	<real>$2</real>
"; }
[ -n "$DELAY" ] && add_real StartupDelay "$DELAY"
[ -n "$LIESEC" ] && add_real IdentityLieSeconds "$LIESEC"
# Overlay=0：不挂悬浮球（用来判定「游戏点不动」是不是悬浮窗吃掉了手势）
if [ -n "$OVERLAY" ]; then ENTRIES="$ENTRIES	<key>Overlay</key>
	<integer>$OVERLAY</integer>
"; fi

TMP="$(mktemp)"
{
  echo '<?xml version="1.0" encoding="UTF-8"?>'
  echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
  echo '<plist version="1.0">'
  echo '<dict>'
  printf '%s' "$ENTRIES"
  echo '</dict>'
  echo '</plist>'
} > "$TMP"
echo "== 将要写入 $CONF =="
cat "$TMP"

$SSH "mkdir -p '$DATA'" 2>&1
$SCP "$TMP" "root@$HOST:$CONF.new" >/dev/null 2>&1
$SSH "mv '$CONF.new' '$CONF'; chown mobile:mobile '$CONF'; chmod 644 '$CONF'; echo '--- 落盘回读 ---'; cat '$CONF'" 2>&1
rm -f "$TMP"
[ "$KILL" = 1 ] && $SSH "killall -9 worldflipper 2>/dev/null; echo 已杀进程（下次启动生效）" 2>&1
