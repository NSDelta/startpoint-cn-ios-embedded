#!/usr/bin/env bash
# show-build-errors.sh —— 从 .work/wsl-build.log 里挑出编译错误与链接错误（wsl-rebuild.sh 的完整输出都在这）
set -uo pipefail
LOG=/mnt/d/spcntweak/.work/wsl-build.log
if [ ! -f "$LOG" ]; then echo "没有 $LOG"; exit 1; fi
echo "== 日志大小 =="; wc -l "$LOG"
echo
echo "== error: / Undefined / ld: 行 =="
grep -n -e 'error:' -e 'Undefined symbols' -e 'ld: ' -e 'MAKE_EXIT' "$LOG" | tail -n 30
echo
echo "== 尾 45 行 =="
tail -n 45 "$LOG"
