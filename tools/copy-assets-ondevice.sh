#!/usr/bin/env bash
# copy-assets-ondevice.sh —— 把旧容器的 1.4.54 资源整目录拷进新 bundle id 的容器（纯手机内部 cp，不走网络）。
#
# 为什么需要：换了 bundle id（例如 com.testdj.wf）以后是新容器，游戏会以为"资源没下过"，
# 而单机线是 client-owned（服务端不下发资源）⇒ 只能把已经下全的 9.8 GB 资源搬过去。
# 游戏按 <容器>/Library/Application Support/<bundle id>/Local Store/asset/asset_download/<sub>/ 找资源，
# 所以源与目标除了 bundle id 段以外路径完全同构。
#
# 用法（WSL）：
#   bash tools/copy-assets-ondevice.sh --host 192.168.0.100 --pass qweasd
#   [--user root] [--from com.leiting.wf] [--to com.testdj.wf] [--dry-run]
set -uo pipefail

HOST=""; USER_NAME="root"; PASS=""; FROM_ID="com.leiting.wf"; TO_ID="com.testdj.wf"; DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --host) HOST="${2:-}"; shift 2;;
    --user) USER_NAME="${2:-}"; shift 2;;
    --pass) PASS="${2:-}"; shift 2;;
    --from) FROM_ID="${2:-}"; shift 2;;
    --to)   TO_ID="${2:-}"; shift 2;;
    --dry-run) DRY=1; shift;;
    *) echo "未知参数：$1"; exit 2;;
  esac
done
[ -n "$HOST" ] || { echo "需要 --host <设备IP> [--pass <密码>]"; exit 2; }

if [ -n "$PASS" ]; then
  SSH=(sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 "$USER_NAME@$HOST")
else
  SSH=(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 "$USER_NAME@$HOST")
fi
remote() { "${SSH[@]}" "$@"; }
say() { echo "$@"; }

DC=/var/mobile/Containers/Data/Application
SRC_REL="Library/Application Support/$FROM_ID/Local Store"
DST_REL="Library/Application Support/$TO_ID/Local Store"

say "== 1. 找源容器（$FROM_ID 的 Local Store）=="
SRC=$(remote "find $DC -maxdepth 4 -type d -path '*$SRC_REL' 2>/dev/null | head -1")
if [ -z "$SRC" ]; then say "  ✗ 找不到源：$SRC_REL"; remote "find $DC -maxdepth 4 -type d -name 'Local Store' 2>/dev/null | head -5"; exit 1; fi
say "  源  $SRC"
remote "du -sh \"$SRC\" 2>/dev/null; find \"$SRC/asset/asset_download\" -type f 2>/dev/null | wc -l | sed 's/^/  asset 文件数 /'"

say "== 2. 找目标容器（$TO_ID）=="
DST_APP=$(remote "find $DC -maxdepth 4 -type d -path '*Library/Application Support/$TO_ID' 2>/dev/null | head -1")
if [ -z "$DST_APP" ]; then
  # 容器目录本身带 bundle id 的 .com.apple.mobile_container_manager.metadata.plist
  DST_ROOT=$(remote "grep -rl '$TO_ID' $DC/*/.com.apple.mobile_container_manager.metadata.plist 2>/dev/null | head -1 | xargs -r dirname")
  if [ -n "$DST_ROOT" ]; then DST_APP="$DST_ROOT/Library/Application Support/$TO_ID"; fi
fi
if [ -z "$DST_APP" ]; then
  say "  ✗ 找不到 $TO_ID 的容器 —— 新 App 还没装/还没启动过一次？"
  say "  （列出所有候选容器，便于人工确认）"
  remote "for f in $DC/*/.com.apple.mobile_container_manager.metadata.plist; do id=\$(basename \$(dirname \$f)); b=\$(grep -A1 MCMMetadataIdentifier \$f 2>/dev/null | grep string | sed 's/.*<string>\\(.*\\)<\\/string>.*/\\1/'); echo \"  \$id \$b\"; done" | head -20
  exit 1
fi
say "  目标 $DST_APP"

if [ "$DRY" = "1" ]; then say "（--dry-run：到此为止，不拷贝）"; exit 0; fi

say "== 3. 拷（cp -a，手机内部；9.8 GB 大约几分钟）=="
remote "mkdir -p \"$DST_APP\" && \
        rm -rf \"$DST_APP/Local Store\" && \
        cp -a \"$SRC\" \"$DST_APP/Local Store\" && \
        chown -R mobile:mobile \"$DST_APP\" && \
        echo '  cp 完成'"

say "== 4. 校验 =="
remote "A=\$(find \"$SRC\" -type f | wc -l); B=\$(find \"$DST_APP/Local Store\" -type f | wc -l); \
        echo \"  源 \$A 文件 / 目标 \$B 文件\"; \
        [ \"\$A\" = \"\$B\" ] && echo '  ✓ 文件数一致' || echo '  ✗ 文件数不一致（重跑一次）'; \
        du -sh \"$DST_APP/Local Store\"; \
        ls -l \"$DST_APP/Local Store/asset/asset_download/dummy/info.json\" 2>/dev/null || echo '  ⚠️ 没有 info.json'"

say ""
say "下一步：打开新 App（或者在手机上新 App 已在后台就杀一次再开）——"
say "  它应该直接跳过资源下载。面板里能看到 服务端状态 = 运行中。"
