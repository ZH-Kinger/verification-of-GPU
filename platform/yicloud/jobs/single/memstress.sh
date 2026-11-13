#!/bin/bash
# 系统内存压测重跑。关闭 power-spike 暂停（--pause_delay 大于运行时长）——
# 默认每 600s 暂停/恢复一次，在本机 175 线程 / 1.5 TB 下控制线程卡死于 futex。
# 用法: bash memstress.sh <node-label> [seconds] [pct]
set -u
NODE=$1; SECS=${2:-1800}; PCT=${3:-80}
D=/mnt/acceptance/results/$NODE
avail_mb=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo)
lim_mb=$(awk '{print int($1/1048576)}' /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null || echo "$avail_mb")
base=$(( avail_mb < lim_mb ? avail_mb : lim_mb ))
MB=$(( base * PCT / 100 ))
TS=$(date +%Y%m%d-%H%M%S)
OUT=$D/memstress-$TS.log
{
  echo "# $(hostname) $(date -u +%FT%TZ) secs=$SECS mem=${MB}MB (${PCT}% of min(MemAvailable=${avail_mb}MB, cgroup=${lim_mb}MB)) threads=$(nproc)"
  stressapptest -s "$SECS" -M "$MB" -m "$(nproc)" -W --pause_delay $((SECS * 10)) 2>&1
  echo "# exit=$? $(date -u +%FT%TZ)"
} > "$OUT" 2>&1
