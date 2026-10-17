#!/usr/bin/env bash
# 越狱设备安装/自检脚本（在 WSL 里运行；设备需开 OpenSSH）
#
#   bash tools/install-device.sh --host 192.168.0.101                 # 完整安装
#   bash tools/install-device.sh --host 192.168.0.101 --check         # 只自检，不写设备
#   bash tools/install-device.sh --host 192.168.0.101 --logs          # 抓日志
#   bash tools/install-device.sh --host 192.168.0.101 --uninstall     # 卸载（保留数据卷）
#
# 做什么：把运行时送到 /var/mobile/Library/SpCn/runtime、装 deb、重启游戏、抓日志。
# 不做什么：不动游戏 IPA 自身（那是 dist/spcn-ios-standalone.ipa 或既有 LAN 包的事）。
set -uo pipefail

HOST=""; USER_NAME="root"; PORT=22
RUNTIME=""; DEB=""; DATA_ROOT="/var/mobile/Library/SpCn"
GAME_BUNDLE="com.leiting.wf"; MODE="install"

while [ $# -gt 0 ]; do
  case "$1" in
    --host) HOST="$2"; shift 2 ;;
    --user) USER_NAME="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --runtime) RUNTIME="$2"; shift 2 ;;
    --deb) DEB="$2"; shift 2 ;;
    --data) DATA_ROOT="$2"; shift 2 ;;
    --game) GAME_BUNDLE="$2"; shift 2 ;;
    --check) MODE="check"; shift ;;
    --logs) MODE="logs"; shift ;;
    --uninstall) MODE="uninstall"; shift ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    *) echo "未知参数：$1"; exit 2 ;;
  esac
done

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[ -n "$RUNTIME" ] || RUNTIME="$ROOT/dist/SpCnRuntime.tar.gz"
case "$DEB" in "") DEB="$ROOT/dist/SpCnEmbedded-rootless.deb" ;; esac
[ -n "$HOST" ] || { echo "缺少 --host（设备局域网 IP）"; exit 2; }

SSH=(ssh -p "$PORT" -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new "$USER_NAME@$HOST")
SCP=(scp -P "$PORT" -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new)

say() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
remote() { "${SSH[@]}" "$@" 2>&1; }

# ── 0. 连通性 + 环境判定 ────────────────────────────────────────────────
say "0. 连接 $USER_NAME@$HOST:$PORT"
if ! remote 'echo REMOTE_OK'; then
  echo "连不上。检查：设备已开 OpenSSH（Sileo 装 openssh）、同一局域网、IP 正确、必要时 --user root 与端口。"
  exit 1
fi
remote 'echo "  机型: $(uname -m)  iOS: $(sw_vers -productVersion 2>/dev/null || echo ?)  内核: $(uname -r)"; \
        echo "  rootless(/var/jb): $([ -d /var/jb ] && echo 是 || echo 否)"; \
        echo "  dpkg: $(command -v dpkg >/dev/null && echo 有 || echo 无)  注: $([ -d /var/jb ] && echo /var/jb/Library/MobileSubstrate/DynamicLibraries || echo /Library/MobileSubstrate/DynamicLibraries)"; \
        echo "  已装游戏: $(ls -d /var/containers/Bundle/Application/*/worldflipper.app 2>/dev/null | head -1 || echo 未找到)"; \
        echo "  已装 dylib: $(ls -l /var/jb/Library/MobileSubstrate/DynamicLibraries/SpCnEmbedded.dylib /Library/MobileSubstrate/DynamicLibraries/SpCnEmbedded.dylib 2>/dev/null || echo 未装)"'

if [ "$MODE" = check ]; then
  say "自检：本地产物"
  ls -l "$RUNTIME" "$DEB" 2>&1
  say "自检：设备上的运行时"
  remote "ls -l $DATA_ROOT/runtime/spcn-runtime.json $DATA_ROOT/runtime/node-ios-arm64/node 2>&1 | head -5"
  say "自检：服务端健康（游戏已启动时才有）"
  remote "curl -s -m 3 http://127.0.0.1:8001/healthz || echo '（未响应，游戏没开或服务端没起来）'"
  exit 0
fi

if [ "$MODE" = logs ]; then
  say "服务端 stdout / stderr（$DATA_ROOT/data/spcn-server.log）"
  remote "ls -l $DATA_ROOT/data/spcn-server.log 2>/dev/null && tail -n 60 $DATA_ROOT/data/spcn-server.log"
  say "dylib 自身日志（沙盒 Documents，路径随容器）"
  remote 'for f in $(ls -t /var/mobile/Containers/Data/Application/*/Documents/SpCnEmbedded.log 2>/dev/null | head -3); do echo "--- $f"; tail -n 40 "$f"; done'
  say "系统日志里的 [SpCn]（最近 60 行）"
  remote 'grep -a "\[SpCn\]" /var/mobile/Library/Logs/*.log 2>/dev/null | tail -n 60 || echo "（无 /var/mobile/Library/Logs 纯文本日志，改用 idevicesyslog）"'
  exit 0
fi

if [ "$MODE" = uninstall ]; then
  say "卸载 dylib（保留 $DATA_ROOT 数据卷）"
  remote "dpkg -r com.starpoint.spcnembedded 2>&1 || true; \
          rm -f /var/jb/Library/MobileSubstrate/DynamicLibraries/SpCnEmbedded.* \
                /Library/MobileSubstrate/DynamicLibraries/SpCnEmbedded.*"
  echo "完成。数据卷仍在 $DATA_ROOT（要清就 rm -rf $DATA_ROOT）。"
  exit 0
fi

# ── 1. 传运行时 + deb ───────────────────────────────────────────────────
say "1. 上传（运行时 $(du -h "$RUNTIME" | cut -f1) + deb）"
remote "mkdir -p $DATA_ROOT/tmp $DATA_ROOT/runtime"
"${SCP[@]}" "$RUNTIME" "$USER_NAME@$HOST:$DATA_ROOT/tmp/SpCnRuntime.tar.gz" || exit 1
"${SCP[@]}" "$DEB" "$USER_NAME@$HOST:$DATA_ROOT/tmp/SpCnEmbedded.deb" || exit 1

# ── 2. 解运行时（node 必须带可执行位） ──────────────────────────────────
say "2. 解包运行时到 $DATA_ROOT/runtime"
remote "cd $DATA_ROOT/tmp && tar xzf SpCnRuntime.tar.gz && \
        rm -rf $DATA_ROOT/runtime && mv SpCnRuntime $DATA_ROOT/runtime && \
        chmod +x $DATA_ROOT/runtime/node-ios-arm64/node && \
        ls -l $DATA_ROOT/runtime/node-ios-arm64/node $DATA_ROOT/runtime/spcn-runtime.json" || exit 1

# ── 3. 装 dylib（deb 优先，失败退化为直接铺文件） ───────────────────────
say "3. 安装 dylib"
if remote "dpkg -i $DATA_ROOT/tmp/SpCnEmbedded.deb"; then
  echo "  dpkg 安装成功"
else
  echo "  dpkg 失败（可能架构不符或依赖缺失），退化：直接铺 dylib + 过滤器 plist"
  DEST="/Library/MobileSubstrate/DynamicLibraries"
  remote "[ -d /var/jb ] && DEST=/var/jb\$DEST; \
          mkdir -p \$DEST && \
          (cd $DATA_ROOT/tmp && tar xzf SpCnEmbedded.deb 2>/dev/null || true); \
          find $DATA_ROOT/tmp -name 'SpCnEmbedded.dylib' -exec cp {} \$DEST/ \; ; \
          find $DATA_ROOT/tmp -name 'SpCnEmbedded.plist' -exec cp {} \$DEST/ \; ; \
          ls -l \$DEST/SpCnEmbedded.*"
fi
remote "rm -f $DATA_ROOT/tmp/SpCnEmbedded.deb"

# ── 4. 重启游戏（让 dylib 在干净进程里加载） ────────────────────────────
say "4. 重启游戏"
remote "killall -9 worldflipper 2>/dev/null; sleep 1; \
        (uiopen -b $GAME_BUNDLE 2>/dev/null || open -b $GAME_BUNDLE 2>/dev/null || echo '请手动点开游戏') "
echo "  游戏起来后面板里的悬浮球应出现在右上角（拖动可移动，点一下展开后台面板）"

# ── 5. 等服务端就绪 ─────────────────────────────────────────────────────
say "5. 等服务端（最多 40 s）"
OK=0
for i in $(seq 1 20); do
  sleep 2
  H="$(remote 'curl -s -m 3 http://127.0.0.1:8001/healthz')"
  if printf '%s' "$H" | grep -q '"status"[[:space:]]*:[[:space:]]*"ready"'; then
    printf '%s\n' "$H" | head -5
    OK=1; break
  fi
  printf '  [%2d/20] 未就绪…\n' "$i"
done

if [ "$OK" = 1 ]; then
  say "✅ 服务端已就绪（单机后端跑在设备上）"
else
  say "⚠️ 未就绪 —— 抓现场"
  remote "tail -n 40 $DATA_ROOT/data/spcn-server.log 2>/dev/null || echo '（没有 spcn-server.log，说明 Supervisor 没拉起 node）'"
  remote 'for f in $(ls -t /var/mobile/Containers/Data/Application/*/Documents/SpCnEmbedded.log 2>/dev/null | head -2); do echo "--- $f"; tail -n 40 "$f"; done'
  echo
  echo "常见原因：① dylib 没加载（看 Documents/SpCnEmbedded.log 有无 'loaded' 标记）"
  echo "          ② 运行时路径不对（日志里的 runtime root 那行）"
  echo "          ③ node 起不来（spcn-server.log 里的 dyld/AMFI 报错）"
  echo "          ④ better_sqlite3.node 加载失败（报 ERR_DLOPEN_FAILED）"
fi
