#!/usr/bin/env bash
# set-startup-delay.sh —— 在设备上写 <DATA_DIR>/spcn-conf.plist 的 StartupDelay（无需重编 dylib），并杀掉游戏。
#
# 用法：bash tools/set-startup-delay.sh [--host 192.168.0.100] [--pass qweasd] [--delay 120] [--backend framework|process|auto] [--no-kill]
#
# 为什么需要它：dylib 里的 SpCnStartupDelay() 每次都读这份 plist，所以改它等于远程改行为 ——
# 用来做「后端完全不启动 / 延后启动」的对照实验（判断黑屏是游戏自己的问题还是后端引起的）。
set -euo pipefail

HOST=192.168.0.100
PASS=qweasd
DELAY=120
BACKEND=framework
KILL=1
while [ $# -gt 0 ]; do
  case "$1" in
    --host) HOST="$2"; shift 2;;
    --pass) PASS="$2"; shift 2;;
    --delay) DELAY="$2"; shift 2;;
    --backend) BACKEND="$2"; shift 2;;
    --no-kill) KILL=0; shift;;
    *) echo "未知参数：$1"; exit 2;;
  esac
done

SSHOPT="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
run() { sshpass -p "$PASS" ssh $SSHOPT "root@$HOST" "$@"; }

DATA=$(run 'for p in /var/mobile/Containers/Data/Application/*/; do d="$p/Documents/SpCn/data"; [ -d "$d" ] && echo "$d"; done; true' | tail -1)
[ -n "$DATA" ] || { echo "找不到数据卷（App 没跑过？）"; exit 1; }
echo "数据卷 $DATA"

run "cat > '$DATA/spcn-conf.plist' <<'PLIST'
<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">
<plist version=\"1.0\">
<dict>
	<key>StartupDelay</key>
	<real>$DELAY</real>
	<key>NodeBackend</key>
	<string>$BACKEND</string>
</dict>
</plist>
PLIST
cat '$DATA/spcn-conf.plist'"

if [ "$KILL" = 1 ]; then
  run 'killall -9 worldflipper 2>/dev/null; sleep 1; ps -A -o pid,comm | grep -c worldflipper || true'
fi

echo
echo "已设置 StartupDelay=$DELAY 秒（后端延后启动；悬浮球照旧立刻挂）。"
echo "请用户点亮屏幕、手动打开 App，然后跑：bash /mnt/d/spcntweak/tools/watch-boot.sh $HOST $PASS 60"
