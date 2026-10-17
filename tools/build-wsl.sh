#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# build-wsl.sh —— 在 WSL 里用 theos 构建 SpCnEmbedded（越狱线的 dylib/deb），
#                并把产物拷回 Windows 侧 dist/。顺带提供 runtime 打包阶段。
#
# 用法（从 Windows 侧调用）：
#   wsl -d Ubuntu-24.04 -u ubuntu -- bash tools/build-wsl.sh package
#   wsl -d Ubuntu-24.04 -u ubuntu -- bash tools/build-wsl.sh syntax     # 只做编译检查
#   wsl -d Ubuntu-24.04 -u ubuntu -- bash tools/build-wsl.sh runtime    # 打 SpCnRuntime.tar.gz
#   wsl -d Ubuntu-24.04 -u ubuntu -- bash tools/build-wsl.sh all
#   wsl -d Ubuntu-24.04 -u ubuntu -- bash tools/build-wsl.sh clean
#
# 为什么必须"先同步到 ext4 再构建"：
#   /mnt/d 是 DrvFs，ldid / llvm-strip 之类的工具**原地改写**会报
#   `Operation not permitted`；而且 theos 在 9p 上很慢。
# 为什么 rootful / rootless 要分两个构建目录：
#   两种 scheme 产出的 deb 文件名相同（都是 …_iphoneos-arm64.deb），
#   同一个目录里连跑两次会把前一个覆盖掉（踩过：rootful 那次把 rootless 盖了）。
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

STAGE="${1:-package}"
PROJ_WIN="/mnt/d/spcntweak"
DIST_WIN="$PROJ_WIN/dist"
BUILD_ROOTLESS="${SPCN_BUILD_DIR:-$HOME/spcn-build}"
BUILD_ROOTFUL="${SPCN_BUILD_DIR:-$HOME/spcn-build}-rootful"
PKG="com.starpoint.spcnembedded"

export THEOS="${THEOS:-$HOME/theos}"
export PATH="$THEOS/toolchain/linux/iphone/bin:$THEOS/bin:$PATH"

say() { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }
die() { printf '\n\033[1;31m!! %s\033[0m\n' "$*" >&2; exit 1; }
want() { [ -e "$1" ] || die "找不到 $1"; }

want "$THEOS"
want "$PROJ_WIN/ios/Makefile"

# ── 源码同步（不带构建产物）────────────────────────────────────────────────
sync_src() {
    local dest="$1"
    say "同步 $PROJ_WIN/ios → $dest"
    mkdir -p "$dest"
    if command -v rsync >/dev/null 2>&1; then
        rsync -a --delete \
              --exclude '.theos/' --exclude 'packages/' --exclude 'obj/' \
              "$PROJ_WIN/ios/" "$dest/"
    else
        rm -rf "$dest"; mkdir -p "$dest"
        (cd "$PROJ_WIN/ios" && tar cf - --exclude='.theos' --exclude='packages' .) | (cd "$dest" && tar xf -)
    fi
    # Windows 侧 checkout 可能是 CRLF（git autocrlf）：dm.pl 会因此失败，统一清掉
    find "$dest" -type f \( -name control -o -name Makefile -o -name '*.plist' -o -name '*.x' -o -name '*.xm' \
        -o -name '*.h' -o -name '*.m' \) -exec sed -i 's/\r$//' {} +
}

# ── 取真实 dylib：顶层 .theos/obj/SpCnEmbedded.dylib 才是 strip 后的成品，
#    .theos/obj/arm64/ 下那个是同名中间件（踩过：拷错就拿到未 strip 的）。──
collect_dylib() {
    local dir="$1" out="$2"
    local cand="$dir/.theos/obj/SpCnEmbedded.dylib"
    if [ -f "$cand" ]; then
        cp -f "$cand" "$out"
    else
        local f
        f=$(find "$dir/.theos/obj" -name 'SpCnEmbedded.dylib' -not -path '*dSYM*' 2>/dev/null | head -1)
        [ -n "$f" ] || die "没找到 SpCnEmbedded.dylib（$dir）"
        cp -f "$f" "$out"
    fi
    echo "    dylib $(stat -c%s "$out") B  sha256 $(sha256sum "$out" | cut -c1-16)…"
}

build_variant() {
    local name="$1" scheme="$2" dir="$3" prefix="$4"
    sync_src "$dir"
    rm -rf "$dir/packages"
    say "make package：$name（THEOS_PACKAGE_SCHEME=${scheme:-<空=rootful>}）"
    if [ -n "$scheme" ]; then
        make -C "$dir" -j"$(nproc)" package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME="$scheme" 2>&1 | tail -6
    else
        make -C "$dir" -j"$(nproc)" package FINALPACKAGE=1 2>&1 | tail -6
    fi
    local deb
    deb=$(ls "$dir"/packages/*.deb 2>/dev/null | head -1)
    [ -n "$deb" ] || die "$name 没产出 deb"
    cp -f "$deb" "$DIST_WIN/SpCnEmbedded-$name.deb"
    # 门禁：安装路径必须落在该 scheme 该有的前缀上（rootless = /var/jb/…）
    #   注意：这里不能写成 `dpkg-deb -c | grep -q` —— grep -q 提前关管道会让
    #   dpkg-deb 吃 SIGPIPE，在 `set -o pipefail` 下整条管道变成失败（踩过）。
    local listing; listing=$(mktemp)
    dpkg-deb -c "$DIST_WIN/SpCnEmbedded-$name.deb" > "$listing"
    if grep -q "$prefix/DynamicLibraries/SpCnEmbedded.dylib" "$listing"; then
        echo "    ✓ $name 安装路径 = /$prefix/DynamicLibraries/（$(stat -c%s "$DIST_WIN/SpCnEmbedded-$name.deb") B）"
    else
        sed 's/^/      /' "$listing"
        rm -f "$listing"
        die "$name 的安装路径不是 /$prefix/…（THEOS_PACKAGE_SCHEME 没生效？）"
    fi
    rm -f "$listing"
    collect_dylib "$dir" "$DIST_WIN/SpCnEmbedded-$name.dylib"
}

pack_runtime() {
    say "打包 iOS 运行时 SpCnRuntime.tar.gz"
    local src="$PROJ_WIN/runtime/SpCnRuntime"
    [ -f "$src/spcn-runtime.json" ] || die "运行时还没组装：先跑 node tools/assemble-runtime.mjs"
    # DrvFs 上所有文件都是 0777 ⇒ tar 里自然带上可执行位（node 必须可执行）
    tar czf "$DIST_WIN/SpCnRuntime.tar.gz" --exclude='.env' --exclude='*.log' \
        -C "$PROJ_WIN/runtime" SpCnRuntime
    echo "    $(stat -c%s "$DIST_WIN/SpCnRuntime.tar.gz") B"
    echo "    sha256 $(sha256sum "$DIST_WIN/SpCnRuntime.tar.gz" | cut -c1-16)…"
}

mkdir -p "$DIST_WIN"

case "$STAGE" in
syntax)
    sync_src "$BUILD_ROOTLESS"
    say "编译检查（只编不打包）"
    make -C "$BUILD_ROOTLESS" -j"$(nproc)" all 2>&1 | tail -25
    ;;
package)
    build_variant rootless rootless "$BUILD_ROOTLESS" "var/jb/Library/MobileSubstrate"
    build_variant rootful  ""       "$BUILD_ROOTFUL"  "Library/MobileSubstrate"
    say "dist 内容"
    ls -l "$DIST_WIN" | sed 's/^/    /'
    ;;
runtime)
    pack_runtime
    ;;
all)
    "$0" package
    pack_runtime
    ;;
clean)
    rm -rf "$BUILD_ROOTLESS" "$BUILD_ROOTFUL"
    say "已清理构建目录"
    ;;
*)
    die "未知阶段：$STAGE（可用：syntax|package|runtime|all|clean）"
    ;;
esac

say "完成：$STAGE"
