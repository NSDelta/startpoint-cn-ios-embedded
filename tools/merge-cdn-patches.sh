#!/usr/bin/env bash
# merge-cdn-patches.sh —— 把 CDN 的增量补丁目录（.cdn/patches/<ver>/archive-*）并进主目录（.cdn/cn/archive-*），
# 让 1.4.0 → 1.4.57 的 diff 链连续（上游的 path/清单只覆盖到 1.4.54，1.4.55/56/57 在 patches/ 里）。
#
# 只搬 archive-* 目录里的 zip（补丁包很小：1.4.55 ≈ 2.4 MB、1.4.56 ≈ 8.5 KB、1.4.57 ≈ 112 MB）。
# 用法：
#   bash tools/merge-cdn-patches.sh [--cdn=/mnt/d/wfspcn/resources/server/.cdn] [--dry-run|--revert]
set -uo pipefail
CDN=/mnt/d/wfspcn/resources/server/.cdn
MODE=apply
for a in "$@"; do
  case "$a" in
    --cdn=*) CDN="${a#--cdn=}" ;;
    --dry-run) MODE=dry ;;
    --revert) MODE=revert ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
  esac
done
[ -d "$CDN/cn" ] || { echo "CDN 目录不对：$CDN/cn 不存在" >&2; exit 1; }
[ -d "$CDN/patches" ] || { echo "没有 patches 目录（$CDN/patches），无需合并" >&2; exit 0; }

echo "CDN  : $CDN"
echo "模式 : $MODE"
echo

total=0
for vdir in "$CDN"/patches/*/; do
  v=$(basename "$vdir")
  for sdir in "$vdir"archive-*/; do
    [ -d "$sdir" ] || continue
    set=$(basename "$sdir")
    for z in "$sdir"*.zip; do
      [ -f "$z" ] || continue
      name=$(basename "$z")
      dst="$CDN/cn/$set/$name"
      total=$((total+1))
      case "$MODE" in
        dry)  echo "  would copy $v/$set/$name ($(stat -c%s "$z") B)" ;;
        apply)
          if [ -f "$dst" ]; then
            echo "  = 已存在 $set/$name"
          else
            # 注意：DrvFs（/mnt/d）上 cp -p 会因 utime 失败返回非零，但文件本身已复制成功 ⇒ 不用 -p
            cp "$z" "$dst" && echo "  ✓ $set/$name ← patches/$v ($(stat -c%s "$z") B)"
          fi ;;
        revert)
          if [ -f "$dst" ] && cmp -s "$z" "$dst"; then rm -f "$dst" && echo "  - 移除 $set/$name"; fi ;;
      esac
    done
  done
done

echo
echo "共扫描 $total 个补丁归档"
echo

# 校验：diff 链是否连续到 1.4.57
chain_ok=1
for prev_next in "1.4.54 1.4.55" "1.4.55 1.4.56" "1.4.56 1.4.57"; do
  set -- $prev_next
  hit=$(ls "$CDN/cn"/archive-*/pinball-"$1"-"$2"-*.zip 2>/dev/null | wc -l | tr -d ' ')
  if [ "$hit" -gt 0 ]; then
    echo "✓ $1 → $2 有 $hit 个归档"
  else
    echo "✗ $1 → $2 缺归档"; chain_ok=0
  fi
done
[ "$chain_ok" = "1" ] || echo "（提示：patches 里 1.4.57 的 common/medium 差分较大，链不完整时服务端会按 full+最新 diff 供包）"
