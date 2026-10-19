#!/usr/bin/env bash
# copy-assets-ondevice.sh —— 把老容器里已下全的 1.4.54 资源搬进单机版（新 bundle id）容器。
#
# 为什么需要：客户端读的资源根是 `<容器>/Library/Application Support/<bundle id>/Local Store/…`。
# 换了 bundle id（com.leiting.wf → com.testdj.wf）就是全新数据容器 ⇒ 这个目录**根本不存在**，
# 客户端连标题界面都渲染不出来（真机实测：一直黑屏、一个网络请求都不发、进程不崩）。
#
# 手法：老容器与新容器在**同一个 APFS 卷**上 ⇒ 用 clonefile（`cp -c`）做写时复制克隆：
#       秒级完成、几乎不占额外空间；不支持时退回真拷贝（9.8 GB，需要 10 GB 余量）。
#
# 用法：
#   bash tools/copy-assets-ondevice.sh [--host 192.168.0.100] [--pass qweasd]
#        [--src-id com.leiting.wf] [--dst-id com.testdj.wf] [--dry-run] [--verify-only]
set -uo pipefail

HOST=192.168.0.100; USER_NAME=root; PASS=qweasd
SRC_ID=com.leiting.wf; DST_ID=com.testdj.wf
DRY=0; VERIFY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --host) HOST="$2"; shift 2;;
    --user) USER_NAME="$2"; shift 2;;
    --pass) PASS="$2"; shift 2;;
    --src-id) SRC_ID="$2"; shift 2;;
    --dst-id) DST_ID="$2"; shift 2;;
    --dry-run) DRY=1; shift;;
    --verify-only) VERIFY=1; shift;;
    *) echo "未知参数：$1"; exit 2;;
  esac
done

SSHOPT="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
run() { sshpass -p "$PASS" ssh $SSHOPT "$USER_NAME@$HOST" "$@"; }

run "SRC_ID='$SRC_ID' DST_ID='$DST_ID' DRY='$DRY' VERIFY='$VERIFY' bash -s" <<'REMOTE'
set -u
B=/var/mobile/Containers/Data/Application

# 老容器：AS 里有 <SRC_ID>/Local Store 的那个
OLD=""
for p in $B/*/; do
  [ -d "$p/Library/Application Support/$SRC_ID/Local Store" ] && OLD="$p" && break
done
# 新容器：有 Documents/SpCn 的那个（我们的单机版）
NEW=""
for p in $B/*/; do
  [ -d "$p/Documents/SpCn" ] && NEW="$p" && break
done

echo "老容器 $OLD"
echo "新容器 $NEW"
[ -n "$OLD" ] || { echo "找不到老容器的资源目录（$SRC_ID/Local Store）"; exit 1; }
[ -n "$NEW" ] || { echo "找不到单机版容器（Documents/SpCn）"; exit 1; }

SRC="$OLD/Library/Application Support/$SRC_ID"
DST="$NEW/Library/Application Support/$DST_ID"
echo "源  $SRC"
echo "目标 $DST"

echo
echo "== 现状 =="
du -sh "$SRC" 2>/dev/null
du -sh "$DST" 2>/dev/null || echo "  目标不存在 ✅（符合预期：新容器是空的）"
echo "  源文件数：$(find "$SRC" -type f 2>/dev/null | wc -l)"

if [ "$VERIFY" = 1 ]; then
  echo
  echo "== 校验 =="
  find "$DST/Local Store" -maxdepth 2 2>/dev/null | head -10
  echo "  目标文件数：$(find "$DST" -type f 2>/dev/null | wc -l)"
  ls -l "$DST/Local Store/asset/asset_download/dummy/info.json" 2>/dev/null || echo "  ✗ info.json 不在"
  df -h /var/mobile | tail -1
  exit 0
fi

if [ "$DRY" = 1 ]; then echo; echo "（--dry-run：不写任何东西）"; exit 0; fi

echo
echo "== 1. 建父目录 =="
mkdir -p "$NEW/Library/Application Support" || exit 1

echo "== 2. 克隆（cp -c = clonefile COW；不支持则退回真拷贝）=="
START=$(date +%s)
if cp -c -a "$SRC" "$DST" 2>/tmp/cp-c.err; then
  echo "  ✓ clonefile 完成（$(($(date +%s) - START))s，几乎不占额外空间）"
else
  echo "  cp -c 不可用（$(head -1 /tmp/cp-c.err)）⇒ 改用真拷贝"
  rm -rf "$DST"
  cp -a "$SRC" "$DST" || { echo "  ✗ 拷贝失败"; exit 1; }
  echo "  ✓ 真拷贝完成（$(($(date +%s) - START))s）"
fi

echo "== 3. 归属改回 mobile =="
chown -R mobile:mobile "$DST"

echo
echo "== 4. 校验 =="
echo "  目标体积：$(du -sh "$DST" 2>/dev/null | cut -f1)"
echo "  目标文件数：$(find "$DST" -type f 2>/dev/null | wc -l)"
ls -l "$DST/Local Store/asset/asset_download/dummy/info.json" 2>/dev/null || echo "  ✗ 没有 info.json —— 路径假设可能不对"
echo "  dummy/download 文件数：$(find "$DST/Local Store/asset/asset_download/dummy/download" -type f 2>/dev/null | wc -l)（老容器口径 137,821）"
df -h /var/mobile | tail -1
REMOTE

echo
echo "下一步：让用户点亮屏幕、手动打开 App，然后跑："
echo "  bash /mnt/d/spcntweak/tools/watch-boot.sh $HOST $PASS 180"
