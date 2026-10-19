#!/usr/bin/env bash
# check-build.sh —— 确认最新的 dylib 里到底有没有「infoDictionary 谎报」这份新代码
set -uo pipefail
DYLIB=/home/ubuntu/spcn-build/.theos/obj/SpCnEmbedded.dylib
echo "== md5（构建产物 / dist 里的 deb 用件）=="
md5sum "$DYLIB" /mnt/d/spcntweak/dist/SpCnEmbedded-rootless.dylib 2>/dev/null
echo
echo "== strings 命中数 =="
printf '  infoDictionary          : %s\n' "$(strings -a "$DYLIB" | grep -c infoDictionary)"
printf '  spcn_infoDictionary     : %s\n' "$(strings -a "$DYLIB" | grep -c spcn_infoDictionary)"
printf '  身份诊断已装            : %s\n' "$(strings -a "$DYLIB" | grep -c '身份诊断已装' || true)"
printf '  swizzle bundleIdentifier: %s\n' "$(strings -a "$DYLIB" | grep -c 'swizzle bundleIdentifier' || true)"
echo
echo "== install 行里的 swizzle 列表 =="
strings -a "$DYLIB" | grep -a 'swizzle bundleIdentifier' | head -2
echo
echo "== 构建日志尾 =="
tail -n 4 /mnt/d/spcntweak/.work/wsl-build.log 2>/dev/null
echo "== dylib mtime =="
ls -l "$DYLIB"
