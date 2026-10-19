#!/usr/bin/env bash
# watch-then-show.sh —— 等下一次启动（引导日志增长），然后直接把原始证据打出来（不依赖中文 grep）
HOST="${1:-192.168.0.100}"; PASS="${2:-qweasd}"; TIMEOUT="${3:-900}"
CONT=/var/mobile/Containers/Data/Application/FC27FEB7-C7FE-43CB-A361-AC9C512F5846
BOOT="$CONT/tmp/SpCnBoot-stdout.log"
SSHOPT="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
run() { sshpass -p "$PASS" ssh $SSHOPT "root@$HOST" "$@"; }

BASE=$(run "wc -c < '$BOOT'" 2>/dev/null | tr -d ' \r')
echo "基线 $BASE 字节；等下一次启动（最多 ${TIMEOUT}s）…"
t=0
while [ "$t" -lt "$TIMEOUT" ]; do
  sleep 10; t=$((t+10))
  NOW=$(run "wc -c < '$BOOT'" 2>/dev/null | tr -d ' \r')
  if [ -n "$NOW" ] && [ "$NOW" -gt "$BASE" ] 2>/dev/null; then
    echo "★ 检测到新启动（+$((NOW-BASE)) 字节），等 25 s 让它跑完…"
    sleep 25
    break
  fi
  [ $((t % 60)) -eq 0 ] && echo "  等待中… ${t}s（当前 ${NOW:-?} 字节）"
done

echo
echo "############ 新启动的原始证据 ############"
bash /mnt/d/spcntweak/tools/show-launch.sh "$HOST" "$PASS" 200 2>&1 | sed -n '1,400p'
