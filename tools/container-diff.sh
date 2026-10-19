#!/usr/bin/env bash
# container-diff.sh —— 对比「原版 com.leiting.wf 的容器」与「我们 com.testdj.wf 的容器」的**非资源**部分。
#
# 为什么：我们的包能启动、AIR 渲染器也起来了，但客户端一个请求都不发（内容不执行）。
# 唯一没被覆盖的差异就是「新容器的非资源状态」—— 原版容器里可能有首次启动就写好、之后一直复用的东西
# （首启标记、激活/票据、prefs、savedState、Caches 索引…）。这里先做只读盘点，不做任何写入。
# 用法：bash tools/container-diff.sh [host] [pass]
set -uo pipefail
HOST="${1:-192.168.0.100}"; PASS="${2:-qweasd}"
OLD=8FA94FE4-3255-4F22-8CD3-E447EFA7A492   # 原版 com.leiting.wf
NEW=FC27FEB7-C7FE-43CB-A361-AC9C512F5846   # 我们的 com.testdj.wf
BASE=/var/mobile/Containers/Data/Application
APP=/var/containers/Bundle/Application/399484D7-62FE-44B3-BE62-42E5180B1919/worldflipper.app
SSH="sshpass -p $PASS ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10 root@$HOST"

for id in "$OLD" "$NEW"; do
  echo "===== $id （非 Local Store 部分，深度 3）====="
  $SSH "cd '$BASE/$id' 2>/dev/null || { echo '(容器不存在)'; exit 0; }
        find . -maxdepth 3 -not -path './Library/Application Support/*/Local Store*' | sed 's|^\./||' | sort | head -90"
  echo "--- 文件数（排除 Local Store）---"
  $SSH "cd '$BASE/$id' 2>/dev/null && find . -type f -not -path './Library/Application Support/*/Local Store*' | wc -l"
  echo "--- 体积（排除 Local Store）---"
  $SSH "cd '$BASE/$id' 2>/dev/null && du -sh --exclude='Local Store' . 2>/dev/null | tail -1"
  echo
done

echo "===== 包里 ios-entry.js 是否存在 ====="
$SSH "ls -l '$APP/SpCnRuntime/ios-entry.js' 2>&1; echo '--- md5 ---'; md5sum '$APP/SpCnRuntime/ios-entry.js' 2>&1; echo '--- runtime 顶层 ---'; ls -l '$APP/SpCnRuntime' | head -12"
