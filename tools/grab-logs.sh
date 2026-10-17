#!/usr/bin/env bash
# grab-logs.sh —— 从设备上抓面板日志 / 服务端日志 / healthz / 进程（只读，不改任何东西）。
#
# 面板里的日志视图不方便复制，所以诊断走这条路：找到 <bundle id> 容器的 Documents/SpCn/data。
#   SpCnEmbedded.log   = 面板日志（dylib 自己的日志）
#   spcn-server.log    = 服务端 stdout/stderr
#
# 用法：bash tools/grab-logs.sh --host 192.168.0.100 --pass qweasd [--bundle com.testdj.wf] [--lines 120]
set -uo pipefail

HOST=""; USER_NAME="root"; PASS=""; BID="com.testdj.wf"; LINES=120
while [ $# -gt 0 ]; do
  case "$1" in
    --host) HOST="${2:-}"; shift 2;;
    --user) USER_NAME="${2:-}"; shift 2;;
    --pass) PASS="${2:-}"; shift 2;;
    --bundle) BID="${2:-}"; shift 2;;
    --lines) LINES="${2:-}"; shift 2;;
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

say "== 0. 连通性 =="
remote "echo '  连上了；' \$(uname -n) ' iOS' \$(sw_vers -productVersion 2>/dev/null || echo '?')" || { say "  ✗ SSH 不通（屏幕/网络）"; exit 1; }

say "== 1. 定位容器（$BID）=="
ROOT=$(remote "grep -rl '$BID' $DC/*/.com.apple.mobile_container_manager.metadata.plist 2>/dev/null | head -1 | xargs -r dirname")
if [ -z "$ROOT" ]; then
  say "  ✗ 没找到 $BID 的容器。已装的数据容器："
  remote "for f in $DC/*/.com.apple.mobile_container_manager.metadata.plist; do b=\$(grep -A1 MCMMetadataIdentifier \$f 2>/dev/null | grep -o '<string>[^<]*' | sed 's/<string>//'); echo \"    \$(basename \$(dirname \$f)) \$b\"; done" | head -25
  exit 1
fi
say "  容器 $ROOT"

say "== 2. 路径与文件 =="
remote "ls -la '$ROOT/Documents' 2>/dev/null; echo '  --- Documents/SpCn'; ls -la '$ROOT/Documents/SpCn' 2>/dev/null; echo '  --- Documents/SpCn/data'; ls -la '$ROOT/Documents/SpCn/data' 2>/dev/null; echo '  --- tmp'; ls -la '$ROOT/tmp' 2>/dev/null | head -15; echo '  --- /var/mobile/Library/SpCn'; ls -la /var/mobile/Library/SpCn 2>/dev/null"

LOG1="$ROOT/Documents/SpCn/data/SpCnEmbedded.log"
LOG2="$ROOT/tmp/SpCnEmbedded.log"
LOG3="/var/mobile/Library/SpCn/data/SpCnEmbedded.log"
say "== 3. 面板日志（尾 $LINES 行）=="
remote "if [ -f '$LOG1' ]; then echo '  [Documents/SpCn/data/SpCnEmbedded.log]'; tail -n $LINES '$LOG1'; \
        elif [ -f '$LOG3' ]; then echo '  [/var/mobile/Library/SpCn/data/SpCnEmbedded.log]'; tail -n $LINES '$LOG3'; \
        elif [ -f '$LOG2' ]; then echo '  [tmp/SpCnEmbedded.log]'; tail -n $LINES '$LOG2'; \
        else echo '  （三个路径都没有日志文件）'; fi"

say "== 4. 服务端 stdout（尾 50 行）=="
remote "for p in '$ROOT/Documents/SpCn/data/spcn-server.log' '/var/mobile/Library/SpCn/data/spcn-server.log' '$ROOT/tmp/spcn-server.log'; do \
          if [ -f \"\$p\" ]; then echo \"  [\$p]\"; tail -n 50 \"\$p\"; break; fi; done; echo '  （如果上面没有输出，就是没有 spcn-server.log）'"

say "== 5. healthz（服务端起没起来）=="
remote "curl -s -m 4 http://127.0.0.1:8001/healthz || echo '  ✗ 8001 不通'"
say ""
say "== 6. 进程 =="
remote "ps -A -o pid,user,pcpu,etime,command 2>/dev/null | grep -E 'worldflipper|node|SpCn' | grep -v grep || ps -A | grep -E 'worldflipper|node' | grep -v grep"

say "== 7. 运行时文件在不在（从 App 包内）=="
remote "B=\$(ls -d /var/containers/Bundle/Application/*/worldflipper.app 2>/dev/null | head -1); echo \"  bundle: \$B\"; \
        ls -l \"\$B/SpCnRuntime/node-ios-arm64/node\" 2>/dev/null; \
        ls -l \"\$B/Frameworks/NodeMobile.framework/NodeMobile\" 2>/dev/null; \
        ls -l \"\$B/Frameworks/SpCnEmbedded.dylib\" 2>/dev/null; \
        ls -l \"\$B/SpCnRuntime/ios-entry.js\" 2>/dev/null; \
        ls -l \"\$B/SpCnRuntime/node_modules/better-sqlite3/build/Release/better_sqlite3.node\" 2>/dev/null; \
        echo '  --- 可执行?'; [ -x \"\$B/SpCnRuntime/node-ios-arm64/node\" ] && echo '  node 有 x 位' || echo '  node 没有 x 位'"
