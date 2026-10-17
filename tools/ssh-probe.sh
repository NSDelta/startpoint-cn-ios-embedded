#!/usr/bin/env bash
# ssh-probe.sh —— 只读探测一台「疑似越狱 iPhone」的 SSH：身份/越狱方案/包管理器/我们的产物是否已在设备上。
# 用法： bash ssh-probe.sh <host> <user> <password>
# 全部命令都是只读的（不装、不删、不改），失败也只是没输出。
HOST="$1"; USER="$2"; PASS="$3"
if [ -z "$HOST" ] || [ -z "$USER" ] || [ -z "$PASS" ]; then echo "用法: ssh-probe.sh <host> <user> <password>"; exit 2; fi
if ! command -v sshpass >/dev/null 2>&1; then echo "ERROR 缺 sshpass（apt-get install -y sshpass）"; exit 3; fi

SSHOPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 -o PreferredAuthentications=password -o PubkeyAuthentication=no -o LogLevel=ERROR"
run() {  # run <描述> <远端命令>
  echo ""
  echo "── $1"
  timeout 25 sshpass -p "$PASS" ssh $SSHOPTS "$USER@$HOST" "$2" 2>&1 | head -30
  echo "   (exit=$?)"
}

echo "== 探测 $USER@$HOST =="
run "身份与内核（Darwin = iPhone；Linux = 不是手机）" 'id; uname -a; sw_vers 2>/dev/null'
run "机型 / iOS 版本" 'ls /var/mobile/Library/Preferences 2>/dev/null >/dev/null; cat /System/Library/CoreServices/SystemVersion.plist 2>/dev/null | tr -d "\n" | sed -e "s/.*ProductVersion<[^>]*>//" -e "s/<.*//"; echo; sysctl -n hw.model 2>/dev/null'
run "越狱形态（rootless /var/jb ↔ rootful）" 'ls -d /var/jb 2>/dev/null && echo ROOTLESS-JB || echo no-var-jb; ls -d /Library/MobileSubstrate 2>/dev/null && echo ROOTFUL-MS || echo no-ms; ls -d /var/jb/Library/MobileSubstrate 2>/dev/null && echo ROOTLESS-MS || echo no-jb-ms'
run "注入引擎 / 包管理器 / 侧载器" 'dpkg -l 2>/dev/null | grep -iE "ellekit|substitute|mobilesubstrate|sileo|zebra|filza|trollstore|appsync|odyssey|dopamine" | head -20; echo ---; ls /var/jb/Applications 2>/dev/null | head; ls /Applications 2>/dev/null | head -30'
run "游戏装没装 / 是哪个 bundle" 'ls -d /var/containers/Bundle/Application/*/*.app 2>/dev/null | head -20; echo ---; find /var/containers/Bundle/Application -maxdepth 3 -iname "worldflipper*" 2>/dev/null | head -5'
run "我们的产物是否已在设备上" 'ls -la /var/jb/Library/MobileSubstrate/DynamicLibraries 2>/dev/null | head; echo ---; ls -la /Library/MobileSubstrate/DynamicLibraries 2>/dev/null | head; echo ---; ls -la /var/jb/usr/share/spcn/runtime 2>/dev/null | head; ls -la /usr/share/spcn/runtime 2>/dev/null | head'
run "运行期痕迹（日志/数据卷）" 'ls -la /var/mobile/Library/SpCn 2>/dev/null; ls -la /var/mobile/Library/SpCn/data 2>/dev/null | head; echo ---; tail -6 /var/mobile/Library/SpCn/data/spcn-server.log 2>/dev/null; echo ---; tail -6 /var/mobile/Documents/SpCnEmbedded.log 2>/dev/null'
run "空间与待装位置" 'df -h 2>/dev/null | head -6; echo ---; ls /var/mobile/Documents 2>/dev/null | head -20; ls /var/mobile/Media 2>/dev/null | head -20'
run "游戏容器里的资源现状（1.4.54 下没下全）" 'for d in /var/mobile/Containers/Data/Application/*/Library/Application\ Support/com.leiting.wf/Local\ Store; do [ -d "$d" ] && echo "FOUND $d" && du -sh "$d" 2>/dev/null && ls "$d/asset/asset_download" 2>/dev/null; done | head -20'
echo ""
echo "== 探测结束 =="
