#!/usr/bin/env bash
# install-full-deb.sh —— 从 Windows 侧一条命令把「越狱一键版」装到设备上（SSH，root + 密码）。
#
# 做的事：
#   1. scp dist/SpCnEmbedded-full-rootless.deb 到 /tmp 并 dpkg -i（插件 + 完整运行时）
#   2. 校验装完的位置（dylib / 过滤器 plist / runtime 的 node 与 ios-entry.js）
#   3. 把**同一份**最新 dylib 也推进当前已装 App 的 Frameworks/（避免「内嵌旧 dylib + 系统新 dylib」两份不同代码；
#      Tweak.xm 里的同名类守卫会保证只有一份真正干活）
#   4. 写一份干净偏好：{NodeBackend=auto, StartupDelay=4, Overlay=1}（清掉实验期的 IdentityLie）
#   5. killall -9 worldflipper（由用户手动点开 App）
#
# 用法：bash tools/install-full-deb.sh [host] [pass] [--deb=dist/SpCnEmbedded-full-rootless.deb]
set -uo pipefail
ROOT=/mnt/d/spcntweak
HOST="${1:-192.168.0.100}"
PASS="${2:-qweasd}"
DEB="$ROOT/dist/SpCnEmbedded-full-rootless.deb"
for a in "$@"; do case "$a" in --deb=*) DEB="${a#--deb=}" ;; esac; done
SSHOPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o PreferredAuthentications=password,keyboard-interactive,publickey"
SSH="sshpass -p $PASS ssh $SSHOPTS root@$HOST"
SCP="sshpass -p $PASS scp $SSHOPTS"
say () { echo "== $* =="; }

[ -f "$DEB" ] || { echo "找不到 deb：$DEB" >&2; exit 1; }

say "连接与身份"
$SSH "uname -a | cut -d' ' -f1-3; id -u; ls -d /var/jb 2>/dev/null || echo 'no /var/jb'" || exit 1

say "推送 deb（$(stat -c%s "$DEB") B）"
$SCP "$DEB" "root@$HOST:/tmp/spcn-full.deb" || exit 1
$SSH "ls -l /tmp/spcn-full.deb"

say "dpkg -i"
$SSH "dpkg -i /tmp/spcn-full.deb 2>&1 | tail -12; echo '--- 已装版本 ---'; dpkg -s com.starpoint.spcnembedded 2>/dev/null | grep -E '^(Status|Version|Architecture)'"

say "校验安装位置"
$SSH "set -u
 DYL=/var/jb/Library/MobileSubstrate/DynamicLibraries/SpCnEmbedded.dylib
 PLIST=/var/jb/Library/MobileSubstrate/DynamicLibraries/SpCnEmbedded.plist
 RT=/var/jb/usr/share/spcn/runtime
 ls -l \$DYL \$PLIST 2>&1
 ls -l \$RT/node-ios-arm64/node \$RT/ios-entry.js \$RT/server-bundle/out/cn-server.js 2>&1
 ls -l \$RT/node_modules/better-sqlite3/build/Release/better_sqlite3.node 2>&1
 echo -n 'runtime files: '; find \$RT -type f 2>/dev/null | wc -l
 echo -n 'dylib md5: '; md5sum \$DYL 2>/dev/null || echo '(设备无 md5)'
"

say "定位已安装的 App（按 Info.plist 的 bundle id）"
APP=$($SSH "for p in /var/containers/Bundle/Application/*/worldflipper.app; do [ -f \"\$p/Info.plist\" ] || continue; if grep -aq 'com.leiting.wf' \"\$p/Info.plist\" && [ -d \"\$p/SpCnRuntime\" ]; then echo \$p; break; fi; done")
echo "  APP=$APP"
[ -n "$APP" ] || { echo "没找到带 SpCnRuntime 的 worldflipper.app（先装一体 IPA）" >&2; exit 1; }

say "把同一份最新 dylib 推进 App 的 Frameworks/（两份代码一致，守卫保证只跑一份）"
$SCP "$ROOT/dist/SpCnEmbedded-rootless.dylib" "root@$HOST:$APP/Frameworks/SpCnEmbedded.dylib" || exit 1
$SSH "chown mobile:mobile '$APP/Frameworks/SpCnEmbedded.dylib'; chmod 0755 '$APP/Frameworks/SpCnEmbedded.dylib'; ls -l '$APP/Frameworks/SpCnEmbedded.dylib'"

say "写干净偏好（清掉实验期的 IdentityLie）"
CONTAINER=$($SSH "for c in /var/mobile/Containers/Data/Application/*; do [ -d \"\$c/Documents/SpCn\" ] && { echo \$c; break; }; done")
echo "  CONTAINER=$CONTAINER"
[ -n "$CONTAINER" ] || { echo "没找到数据容器（App 至少启动过一次才会有 Documents/SpCn）" >&2; exit 1; }
CONF="$CONTAINER/Documents/SpCn/data/spcn-conf.plist"
$SSH "mkdir -p '$CONTAINER/Documents/SpCn/data' && cat > '$CONF' <<'EOF'
<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">
<plist version=\"1.0\">
<dict>
	<key>NodeBackend</key><string>auto</string>
	<key>StartupDelay</key><real>4</real>
	<key>Overlay</key><integer>1</integer>
</dict>
</plist>
EOF
chown mobile:mobile '$CONF'; cat '$CONF'"

say "杀掉进程（请在手机上点亮屏幕、手动打开「世界弹射物语」）"
$SSH "killall -9 worldflipper 2>/dev/null; sleep 1; ps -A -o pid,comm | grep -c worldflipper || true"

say "完成"
echo "  下一步：手机上点开 App，等 8~10 秒（悬浮球出现 → 点球看面板状态）"
echo "  我这边随后用 tools/grab-boot-logs.sh / tools/show-launch.sh 复查日志与 /healthz"
