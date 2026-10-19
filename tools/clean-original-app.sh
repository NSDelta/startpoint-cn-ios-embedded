#!/usr/bin/env bash
# clean-original-app.sh —— 清理「误推进原版 com.leiting.wf App」的我们的文件。
# 背景：2026-10-17 22:38 的两次 push 因为用 ps 定位目标，把 Frameworks/SpCnEmbedded.dylib 推进了用户的原版游戏。
# 原则：只删我们自己放进去的那一个文件；原版 App 的 Info.plist 里若 id 不是 com.testdj.wf 才动手，且绝不碰其它任何文件。
# 用法：bash tools/clean-original-app.sh [host] [pass] [--dry-run]
set -uo pipefail
HOST="${1:-192.168.0.100}"; PASS="${2:-qweasd}"; DRY=0
[ "${3:-}" = "--dry-run" ] && DRY=1
SSHOPT="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
run() { sshpass -p "$PASS" ssh $SSHOPT "root@$HOST" "$@"; }

echo "== 扫描所有 worldflipper.app 里我们的文件 =="
run 'for d in /var/containers/Bundle/Application/*/worldflipper.app; do
  [ -d "$d" ] || continue
  bid=$(grep -a -A2 "CFBundleIdentifier" "$d/Info.plist" 2>/dev/null | grep -a "<string>" | head -1 | sed "s/.*<string>//; s/<\/string>.*//")
  dyl="$d/Frameworks/SpCnEmbedded.dylib"
  rt="$d/SpCnRuntime"
  has_dyl=no; [ -f "$dyl" ] && has_dyl="yes $(stat -c%s "$dyl")B"
  has_rt=no;  [ -d "$rt" ]  && has_rt="yes $(du -sh "$rt" 2>/dev/null | cut -f1)"
  echo "  $d"
  echo "    bundle id=$bid   SpCnEmbedded.dylib=$has_dyl   SpCnRuntime=$has_rt"
done'

if [ "$DRY" = 1 ]; then echo; echo "（--dry-run：不删）"; exit 0; fi

echo
echo "== 清理：只删「非 com.testdj.wf」App 里的 Frameworks/SpCnEmbedded.dylib =="
run 'for d in /var/containers/Bundle/Application/*/worldflipper.app; do
  [ -d "$d" ] || continue
  bid=$(grep -a -A2 "CFBundleIdentifier" "$d/Info.plist" 2>/dev/null | grep -a "<string>" | head -1 | sed "s/.*<string>//; s/<\/string>.*//")
  dyl="$d/Frameworks/SpCnEmbedded.dylib"
  [ -f "$dyl" ] || continue
  if [ "$bid" = "com.testdj.wf" ]; then
    echo "  保留（这是我们自己的包）：$dyl"
  else
    rm -f "$dyl" && echo "  已删（原版包，$bid）：$dyl"
  fi
done'
echo
echo "== 复扫 =="
run 'for d in /var/containers/Bundle/Application/*/worldflipper.app; do
  [ -d "$d" ] || continue
  bid=$(grep -a -A2 "CFBundleIdentifier" "$d/Info.plist" 2>/dev/null | grep -a "<string>" | head -1 | sed "s/.*<string>//; s/<\/string>.*//")
  echo "  $bid : $([ -f "$d/Frameworks/SpCnEmbedded.dylib" ] && echo "还有 dylib" || echo "干净")"
done'
