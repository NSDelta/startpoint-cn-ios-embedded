#!/usr/bin/env bash
# syntax-check.sh —— 对 ios/src 下的每个 .m 跑一遍 clang -fsyntax-only
#
# 用的是 theos 的 clang 11 + iPhoneOS16.5.sdk、target arm64-apple-ios14.0（与 tweak.mk 同口径）。
# 只做**语法检查**，不做链接 —— 所以不需要 -lz / -framework，也不会碰任何构建目录
# （并行跑 theos 全量构建时不会互相抢目录）。
#
# 用法（必须在 WSL 里跑，路径走 /mnt/d 挂载）：
#   wsl -d Ubuntu-24.04 -u ubuntu -- bash /mnt/d/spcntweak/tools/syntax-check.sh
#
# 纪律：逐文件打印 OK/FAIL，退出码取 **clang 自己的**（绝不能把 clang 输出管道给 tail 再取 $?，
# 那样拿到的是 tail 的退出码）。最后有任一 FAIL 就以非零退出。

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 2

CLANG="${THEOS_CLANG:-$HOME/theos/toolchain/linux/iphone/bin/clang}"
SDK="${THEOS_SDK:-$HOME/theos/sdks/iPhoneOS16.5.sdk}"

if [ ! -x "$CLANG" ]; then
    echo "找不到 clang：$CLANG（可用 THEOS_CLANG 环境变量指定）"
    exit 2
fi
if [ ! -d "$SDK" ]; then
    echo "找不到 SDK：$SDK（可用 THEOS_SDK 环境变量指定）"
    exit 2
fi

echo "clang : $CLANG"
echo "sdk   : $SDK"
echo "root  : $REPO_ROOT"
echo "----"

fail=0
count=0

while IFS= read -r file; do
    count=$((count + 1))
    output="$("$CLANG" -fsyntax-only \
        -target arm64-apple-ios14.0 \
        -isysroot "$SDK" \
        -fobjc-arc \
        -I ios -I ios/src -I ios/src/importer \
        -Wno-everything \
        "$file" 2>&1)"
    status=$?
    if [ "$status" -eq 0 ]; then
        echo "OK   $file"
    else
        echo "FAIL $file (clang exit $status)"
        printf '%s\n' "$output" | sed 's/^/     /'
        fail=$((fail + 1))
    fi
done < <(find ios/src -name '*.m' | sort)

echo "----"
echo "共检查 $count 个 .m 文件，FAIL $fail 个"
if [ "$fail" -ne 0 ]; then
    exit 1
fi
exit 0
