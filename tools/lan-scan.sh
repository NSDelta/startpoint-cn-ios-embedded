#!/usr/bin/env bash
# lan-scan.sh —— 在局域网里找 iOS 设备（以及开着 SSH 的机器）。
#
# 判据：
#   · 62078/tcp = iOS 的 lockdownd（iTunes/idevice 配对端口）⇒ **只有 iPhone/iPad 会开**，Linux/Windows 不会。
#   · 22/tcp    = SSH（越狱机常开；OpenSSH 包）。
#   · 2222/tcp  = 有些越狱 SSH 方案用这个端口。
# 用法： bash lan-scan.sh [子网前缀，默认 192.168.0]
set -u
PREFIX="${1:-192.168.0}"

check() {
  local ip="$1" p="$2"
  if timeout 1 bash -c "exec 3<>/dev/tcp/$ip/$p" 2>/dev/null; then echo "OPEN $ip:$p"; fi
}
export -f check

echo "== 扫 $PREFIX.1-254 的 62078(iOS lockdownd) / 22 / 2222 =="
for i in $(seq 1 254); do
  ip="$PREFIX.$i"
  for p in 62078 22 2222; do
    check "$ip" "$p" &
  done
  # 控制并发：每 32 个 IP（96 个连接）等一次
  if [ $((i % 32)) -eq 0 ]; then wait; fi
done
wait
echo "== 扫完 =="
