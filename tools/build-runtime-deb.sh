#!/usr/bin/env bash
# build-runtime-deb.sh —— 出「一键安装」deb：dylib + 过滤器 plist + 完整运行时（含 NodeMobile.framework）
#
# 为什么要有这个：
#   越狱线原来的装法要手工把 4368 个文件（220 MB）铺到 /var/mobile/Library/SpCn/runtime —— Filza 里手点
#   到天亮，还容易漏。打进 deb 后 Sileo/Filza 点一下就装完。
#
# 安装布局（必须与 ios/src/SpCnConfig.m 的探测顺序对齐）：
#   rootless(/var/jb): /var/jb/Library/MobileSubstrate/DynamicLibraries/{SpCnEmbedded.dylib,SpCnEmbedded.plist}
#                      /var/jb/usr/share/spcn/runtime/**            ← SpCnConfig.m:43 会找到
#   rootful          : /Library/MobileSubstrate/DynamicLibraries/…   + /usr/share/spcn/runtime/**  （:44）
#   数据卷：运行时不在 App 包里 ⇒ 数据落 /var/mobile/Library/SpCn/data（tweak 首次运行自建，SpCnConfig.m:5）
#
# 包名与 tweak 的小 deb 相同（com.starpoint.spcnembedded），只是版本更高 ⇒ 装 full 就是升级，不会出现
# 两个包同时拥有同一批文件、卸载其中一个把另一个的文件删掉的烂摊子。
#
# 用法：bash tools/build-runtime-deb.sh [rootless|rootful|both]   缺省 both
set -euo pipefail

REPO=/mnt/d/spcntweak
DIST="$REPO/dist"
TAR="$DIST/SpCnRuntime.tar.gz"
PLIST="$REPO/ios/SpCnEmbedded.plist"
SCHEMES="${1:-both}"

[ -f "$TAR" ] || { echo "缺 $TAR —— 先跑 tools/build-wsl.sh runtime"; exit 1; }
[ -f "$PLIST" ] || { echo "缺 $PLIST"; exit 1; }

build_one() {
  local scheme="$1" prefix stage out list
  case "$scheme" in
    rootless) prefix="/var/jb" ;;
    rootful)  prefix="" ;;
    *) echo "未知 scheme: $scheme"; exit 1 ;;
  esac

  stage="$(mktemp -d "$HOME/spcn-deb-XXXXXX")"
  list="$stage/.pkglist"          # 门禁用；放在 stage 里最后会被清掉
  echo ""
  echo "== 组装 $scheme 完整 deb（stage=$stage）=="

  # ① 运行时：tar 里是 SpCnRuntime/，要落到前缀下的 spcn/runtime（小写，与探测路径逐字一致）
  mkdir -p "$stage$prefix/usr/share/spcn"
  tar -xzf "$TAR" -C "$stage$prefix/usr/share/spcn"
  rm -rf "$stage$prefix/usr/share/spcn/runtime"
  mv "$stage$prefix/usr/share/spcn/SpCnRuntime" "$stage$prefix/usr/share/spcn/runtime"

  # ② dylib + 过滤器 plist（与 tweak 小 deb 装到同一路径：dpkg 覆盖，等价）
  mkdir -p "$stage$prefix/Library/MobileSubstrate/DynamicLibraries"
  cp "$DIST/SpCnEmbedded-$scheme.dylib" \
     "$stage$prefix/Library/MobileSubstrate/DynamicLibraries/SpCnEmbedded.dylib"
  cp "$PLIST" "$stage$prefix/Library/MobileSubstrate/DynamicLibraries/SpCnEmbedded.plist"

  # ③ control（LF + ASCII；dpkg-deb 对 CRLF 与中文都不友好）
  mkdir -p "$stage/DEBIAN"
  cat > "$stage/DEBIAN/control" <<'EOF'
Package: com.starpoint.spcnembedded
Name: SpCn Embedded
Version: 0.2.0
Architecture: iphoneos-arm64
Depends: mobilesubstrate | ellekit
Maintainer: junyuwang722
Author: junyuwang722
Section: Tweaks
License: GPL-3.0
Homepage: https://github.com/NSDelta/startpoint-cn-ios-embedded
Description: World Flipper CN standalone server (dylib + full Node runtime).
EOF

  # ④ 打包：gzip（与 theos 的 dm.pl 同款；220 MB 走 xz 要好几分钟，gzip 几十秒）
  out="$DIST/SpCnEmbedded-full-$scheme.deb"
  rm -f "$out"
  dpkg-deb --build -Zgzip -z6 --root-owner-group "$stage" "$out" > /dev/null
  echo "  产物   $out  $(stat -c%s "$out") B"

  # ⑤ 门禁：先落文件再 grep（dpkg-deb | grep -q 会吃 SIGPIPE，让整条管道非零 ⇒ 误报）
  dpkg-deb -c "$out" > "$list"
  local n
  n="$(wc -l < "$list")"
  local fail=0
  check() { if grep -q -- "$2" "$list"; then echo "  ✓ $1"; else echo "  ✗ $1（缺 $2）"; fail=1; fi; }
  check "运行时可执行 node"      "usr/share/spcn/runtime/node-ios-arm64/node"
  check "运行时清单"            "usr/share/spcn/runtime/spcn-runtime.json"
  check "进程内入口 ios-entry.js" "usr/share/spcn/runtime/ios-entry.js"
  check "NodeMobile.framework"  "usr/share/spcn/runtime/NodeMobile.framework/NodeMobile"
  check "server-bundle 入口"     "usr/share/spcn/runtime/server-bundle/out/cn-server.js"
  check "原生模块 better_sqlite3.node" "usr/share/spcn/runtime/node_modules/better-sqlite3/build/Release/better_sqlite3.node"
  check "dylib"                 "Library/MobileSubstrate/DynamicLibraries/SpCnEmbedded.dylib"
  check "过滤器 plist"           "Library/MobileSubstrate/DynamicLibraries/SpCnEmbedded.plist"
  # node 必须带可执行位（deb 里是 -rwxr-xr-x）
  if grep -E '^-rwxr-xr-x .*usr/share/spcn/runtime/node-ios-arm64/node$' "$list" > /dev/null; then
    echo "  ✓ node 权限 0755"
  else
    echo "  ✗ node 权限不是 0755（不能 exec）"; fail=1
  fi
  echo "  条目数 $n（预期 ≈ 4370+）"
  if [ "$n" -lt 4300 ]; then echo "  ✗ 条目数偏少，运行时可能没进去"; fail=1; fi
  [ "$fail" -eq 0 ] || { echo "  ⇒ $scheme 门禁失败，保留 stage 供排查：$stage"; exit 1; }

  rm -rf "$stage"
  echo "  ✓ $scheme 完整 deb 就绪"
}

case "$SCHEMES" in
  both) build_one rootless; build_one rootful ;;
  rootless|rootful) build_one "$SCHEMES" ;;
  *) echo "用法: bash tools/build-runtime-deb.sh [rootless|rootful|both]"; exit 1 ;;
esac

echo ""
echo "== dist 现状 =="
ls -l "$DIST" | tail -n +1
echo "== 完成：runtime-deb =="
