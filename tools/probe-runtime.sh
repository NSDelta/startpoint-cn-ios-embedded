#!/usr/bin/env bash
# probe-runtime.sh —— 看客户端到底在干什么：CPU/线程/内存、有没有网络活动、容器里新写了什么、AIR 相关内容
HOST="${1:-192.168.0.100}"; PASS="${2:-qweasd}"
CONT=/var/mobile/Containers/Data/Application/FC27FEB7-C7FE-43CB-A361-AC9C512F5846
APP=/var/containers/Bundle/Application/399484D7-62FE-44B3-BE62-42E5180B1919/worldflipper.app
SSHOPT="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
run() { sshpass -p "$PASS" ssh $SSHOPT "root@$HOST" "$@"; }

echo "== 1. 进程 CPU/内存/线程 =="
run "ps -A -o pid,ppid,%cpu,time,rss,comm | grep -E 'PID|[w]orldflipper'"
echo
echo "== 2. 线程数与状态（前 20 行）=="
PID=$(run "ps -A -o pid,comm | grep '[w]orldflipper' | awk '{print \$1}' | head -1")
echo "  pid=$PID"
run "ls /var/containers/Bundle/Application/399484D7-62FE-44B3-BE62-42E5180B1919/worldflipper.app >/dev/null; ps -M $PID 2>/dev/null | head -20 || echo '  (ps -M 不可用)'"
echo
echo "== 3. 该进程的 TCP 连接 =="
run "netstat -an 2>/dev/null | grep -E 'ESTABLISHED|SYN_SENT' | grep -E '127.0.0.1|8001|7001' | head -10; echo '--- 全部 ESTABLISHED 前 10 ---'; netstat -an 2>/dev/null | grep ESTABLISHED | head -10"
echo
echo "== 4. 容器里最近 30 分钟被写入的文件（前 25 条）=="
run "find '$CONT' -newermt '-30 minutes' -type f 2>/dev/null | grep -v -E 'SpCn|tmp/' | head -25"
echo
echo "== 5. 沙盒 Documents/Library 顶层 =="
run "ls -la '$CONT/Documents/' 2>/dev/null | head -12; echo '--- Library ---'; ls -la '$CONT/Library/' 2>/dev/null | head -16"
echo
echo "== 6. AIR 相关内容（stdout 里除 [SpCn] 之外的最后 25 行）=="
run "tail -c 200000 '$CONT/tmp/SpCnBoot-stdout.log' | grep -a -v '\\[SpCn\\]' | grep -a -v 'isPathRestricted' | tail -n 25"
echo
echo "== 7. 服务端请求分类（incoming 行）=="
run "grep -a '\"req\":{\"method\"' '$CONT/Documents/SpCn/data/spcn-server.log' 2>/dev/null | sed 's/.*\"url\":\"//; s/\".*//' | sort | uniq -c | sort -rn | head"
