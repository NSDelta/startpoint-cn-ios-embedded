#!/usr/bin/env bash
# wsl-install-node.sh —— 给 WSL 装一个 Node（rootless 解压 + 链到 /usr/local/bin），
# 让 WSL 里那些调 node 的脚本（extract-info-plist / analyze-* / push-plist-urlname）能跑。
set -uo pipefail
VER="${1:-v20.18.1}"
DIR="$HOME/tools/node-$VER-linux-x64"
mkdir -p "$HOME/tools"
if [ -x "$DIR/bin/node" ]; then
  echo "已有：$("$DIR/bin/node" -v)"
else
  echo "== 下载 $VER =="
  curl -sSL "https://nodejs.org/dist/$VER/node-$VER-linux-x64.tar.xz" -o "$HOME/tools/node.tar.xz" || { echo "下载失败"; exit 1; }
  tar -xJf "$HOME/tools/node.tar.xz" -C "$HOME/tools" || { echo "解压失败"; exit 1; }
fi
sudo ln -sf "$DIR/bin/node" /usr/local/bin/node
sudo ln -sf "$DIR/bin/npm"  /usr/local/bin/npm
sudo ln -sf "$DIR/bin/npx"  /usr/local/bin/npx
echo "node = $(command -v node) $(node -v)"
node -e "console.log('node 可用：', process.version)"
