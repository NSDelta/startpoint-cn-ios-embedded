#!/usr/bin/env bash
# pack-cdn.sh —— 把 CDN 目录打成可分发的压缩包。
#
# 三种打包范围（--only）：
#   cn      只打 cn/ + .complete        → SpCnCdn-<stamp>.tar.gz      （主资源，~10 GB，建议 --split）
#   patches 只打 patches/               → SpCnPatches-<stamp>.tar.gz  （1.4.55/56/57 增量，~111 MB）
#   both    cn + patches + .complete    → SpCnCdnAll-<stamp>.tar.gz   （一份搞定，默认）
#
# 用法：
#   bash tools/pack-cdn.sh [--only=cn|patches|both] [--cdn=/mnt/d/wfspcn/resources/server/.cdn] \
#                          [--out=dist] [--split=2G] [--level=1] [--with-dl] [--list-only]
# 解包：tar -xzf <包> -C <CDN_DIR 的父目录>   # 得到 <CDN_DIR>/cn 与/或 <CDN_DIR>/patches
set -uo pipefail
ROOT=/mnt/d/spcntweak
CDN=/mnt/d/wfspcn/resources/server/.cdn
OUT="$ROOT/dist"
ONLY=both
SPLIT=""
LEVEL=1
WITH_DL=0
LIST_ONLY=0
for a in "$@"; do
  case "$a" in
    --only=*) ONLY="${a#--only=}" ;;
    --cdn=*) CDN="${a#--cdn=}" ;;
    --out=*) OUT="${a#--out=}" ;;
    --split=*) SPLIT="${a#--split=}" ;;
    --level=*) LEVEL="${a#--level=}" ;;
    --with-dl) WITH_DL=1 ;;
    --list-only) LIST_ONLY=1 ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
  esac
done
[ -d "$CDN" ] || { echo "CDN 目录不存在：$CDN" >&2; exit 1; }
mkdir -p "$OUT"

case "$ONLY" in
  cn)      PREFIX=SpCnCdn ;;
  patches) PREFIX=SpCnPatches ;;
  both)    PREFIX=SpCnCdnAll ;;
  *) echo "--only 只接受 cn|patches|both" >&2; exit 1 ;;
esac

INCLUDE=()
if [ "$ONLY" != "patches" ]; then
  [ -d "$CDN/cn" ] && INCLUDE+=("cn")
  [ -f "$CDN/.complete" ] && INCLUDE+=(".complete")
  [ "$WITH_DL" = "1" ] && [ -f "$CDN/_dl.zip" ] && INCLUDE+=("_dl.zip")
fi
if [ "$ONLY" != "cn" ]; then
  [ -d "$CDN/patches" ] && INCLUDE+=("patches")
fi
[ "${#INCLUDE[@]}" -gt 0 ] || { echo "没有可打包的内容（$ONLY）" >&2; exit 1; }

echo "== 打包内容（$PREFIX）=="
echo "  CDN   : $CDN"
echo "  成员  : ${INCLUDE[*]}"
du -sh "$CDN"/"${INCLUDE[@]}" 2>/dev/null | sed 's/^/  /'
size=$(du -sb "$CDN"/"${INCLUDE[@]}" 2>/dev/null | awk '{s+=$1} END {printf "%.2f", s/1073741824}')
echo "  明文  : ${size} GB（gzip -${LEVEL}）"
[ "$LIST_ONLY" = "1" ] && exit 0

STAMP=$(date +%Y%m%d-%H%M%S)
if [ -n "$SPLIT" ]; then
  BASE="$OUT/$PREFIX-$STAMP.tar.part"
  echo "== 打包（分流 $SPLIT）→ $BASE.NN =="
  tar -C "$CDN" -cf - "${INCLUDE[@]}" | gzip -"$LEVEL" | split -b "$SPLIT" -d -a 2 - "$BASE"
  rc=${PIPESTATUS[0]}
  OUT_FILE=""
else
  OUT_FILE="$OUT/$PREFIX-$STAMP.tar.gz"
  echo "== 打包 → $OUT_FILE =="
  tar -C "$CDN" -cf - "${INCLUDE[@]}" | gzip -"$LEVEL" > "$OUT_FILE"
  rc=${PIPESTATUS[0]}
fi
[ "$rc" = "0" ] || { echo "打包失败（tar exit $rc）" >&2; exit 1; }

echo
echo "== 产物 =="
ls -l "$OUT"/$PREFIX-$STAMP* | sed 's/^/  /'
if [ -n "$SPLIT" ]; then
  echo "  合计 $(cat "$OUT"/$PREFIX-$STAMP.tar.part* | wc -c) B"
  echo "  解包：cat $PREFIX-$STAMP.tar.part* | tar -xzf - -C <CDN_DIR 的父目录>"
else
  echo "  sha256 $(sha256sum "$OUT_FILE" | awk '{print $1}')"
  echo "  条目数 $(tar -tzf "$OUT_FILE" | wc -l)"
  echo "  含 patches/ ：$(tar -tzf "$OUT_FILE" | grep -c '^patches/') 个条目"
  echo "  解包：tar -xzf $(basename "$OUT_FILE") -C <CDN_DIR 的父目录>"
fi
