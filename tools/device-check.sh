#!/usr/bin/env bash
# device-check.sh —— 设备侧能力体检（只读）：能不能装 deb、能不能启动游戏、能不能自测健康接口。
# 用法： bash device-check.sh <host> <user> <password>
HOST="$1"; USER="$2"; PASS="$3"
if [ -z "$HOST" ] || [ -z "$USER" ] || [ -z "$PASS" ]; then echo "用法: device-check.sh <host> <user> <password>"; exit 2; fi
SSHOPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 -o PreferredAuthentications=password -o PubkeyAuthentication=no -o LogLevel=ERROR"
r() { echo ""; echo "── $1"; timeout 25 sshpass -p "$PASS" ssh $SSHOPTS "$USER@$HOST" "$2" 2>&1 | head -25; }

echo "== 设备能力体检 $USER@$HOST =="
r "装包与文件传输工具" 'for b in dpkg dpkg-deb apt apt-get sileo sbreload uiopen open killall curl wget nc tar gzip unzip zip scp ssh; do p=$(command -v $b 2>/dev/null || ls /var/jb/usr/bin/$b /var/jb/usr/sbin/$b /usr/bin/$b 2>/dev/null | head -1); [ -n "$p" ] && echo "OK   $b -> $p" || echo "MISS $b"; done'
r "游戏进程在不在跑" 'ps aux 2>/dev/null | grep -i -E "worldflipper" | grep -v grep | head -5; echo ---; ls -la /var/mobile/Containers/Bundle/Application/C5A975A2-3E37-43E1-85C3-8BE3648D81EB/worldflipper.app/ | head -12'
r "游戏数据容器与资源现状" 'D="/var/mobile/Containers/Data/Application/8FA94FE4-3255-4F22-8CD3-E447EFA7A492"; ls -la "$D" 2>/dev/null | head; echo ---; du -sh "$D/Library/Application Support/com.leiting.wf/Local Store" 2>/dev/null; ls "$D/Library/Application Support/com.leiting.wf/Local Store/asset/asset_download/dummy" 2>/dev/null | head; echo ---; ls "$D/Library/Application Support/com.leiting.wf/Local Store/asset/asset_download/dummy/download" 2>/dev/null | head -3; find "$D/Library/Application Support/com.leiting.wf/Local Store/asset/asset_download/dummy/download" -type f 2>/dev/null | wc -l'
r "注入目录（dylib 会装到这）与已有插件" 'ls -la /var/jb/usr/lib/TweakInject 2>/dev/null | head -20; echo ---; ls -la /var/jb/Library/MobileSubstrate/DynamicLibraries 2>/dev/null | head -5'
r "我们的落点（现在应该都还没有）" 'ls -ld /var/jb/usr/share/spcn /var/jb/usr/share/spcn/runtime 2>/dev/null; echo ---; ls -l /var/jb/usr/lib/TweakInject/SpCnEmbedded.dylib 2>/dev/null; echo ---; ls -ld /var/mobile/Library/SpCn 2>/dev/null'
r "写权限与空间（/var/mobile 与 /var/jb 在同一卷）" 'touch /var/mobile/.spcn-write-test 2>&1 && echo "WRITE-OK /var/mobile" && rm -f /var/mobile/.spcn-write-test; df -h / 2>/dev/null | tail -2'
r "AppSync 与 TrollStore 之类（侧载能力）" 'dpkg -l 2>/dev/null | grep -iE "appsync|trollstore|ldid|zsign" | head; echo ---; command -v ldid 2>/dev/null; ls /var/jb/usr/bin/ldid 2>/dev/null'
echo ""
echo "== 体检结束 =="
