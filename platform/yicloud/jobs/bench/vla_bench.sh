#!/bin/bash
# VLA π0.5（VitraPytorch + PaliGemma2-3B）训练吞吐，复用测试包原脚本 run_throughput.sh。
# 与 B300 基线（10.10.3.125，VLA_RESULTS.md）同 config / 同参数，只换机器。
# 用法: bash vla_bench.sh <tag> <BATCH> <NUM_WORKERS> [STEPS] [WARMUP]
set -u
TAG=$1; BATCH=$2; NW=$3; STEPS=${4:-100}; WARMUP=${5:-40}
source /mnt/acceptance/tools/imgenv.sh /opt/img/vla
ln -sfn /mnt/acceptance/wuji-data/b300-test/benchmark /dev/shm/benchmark
KIT=/dev/shm/benchmark/test/wuji-vla-post-train
OUT=/mnt/acceptance/results/bench/vla; mkdir -p "$OUT"
rm -rf "$OUT/ckpt/$TAG"      # 测试包已知坑：8 rank 抢 rmtree
nvidia-smi --query-gpu=timestamp,index,utilization.gpu,memory.used,power.draw,temperature.gpu,clocks.sm \
  --format=csv,noheader,nounits -l 2 > "$OUT/$TAG.gpu.csv" 2>/dev/null &
SP=$!
top -b -d 5 -n 400 | grep --line-buffered -E '^%Cpu|^MiB Mem' > "$OUT/$TAG.cpu.txt" 2>/dev/null &
CP=$!
cd "$KIT"
REPO=$KIT CONFIG=vitra_bench_ab_tianji4 GPUS=8 BATCH=$BATCH STEPS=$STEPS WARMUP=$WARMUP NUM_WORKERS=$NW \
  LOG_INTERVAL=5 EXP=$TAG OUTDIR=$OUT bash /dev/shm/benchmark/test/run_throughput.sh > "$OUT/$TAG.console.log" 2>&1
rc=$?
kill $SP $CP 2>/dev/null
echo "rc=$rc" >> "$OUT/$TAG.console.log"
grep -A3 "throughput result" "$OUT/$TAG.console.log"
python3 - "$OUT/$TAG.gpu.csv" <<'EOF'
import sys, statistics
rows=[l.strip().split(", ") for l in open(sys.argv[1]) if l.count(",")>=6]
if not rows: sys.exit()
mem=[float(r[3]) for r in rows]; pw=[float(r[4]) for r in rows]; ut=[float(r[2]) for r in rows]; tp=[float(r[5]) for r in rows]
pw.sort(); ut_busy=[u for u in ut if u>5]
print(f"GPU: mem_peak={max(mem)/1024:.0f} GiB  power_p95={pw[int(len(pw)*.95)-1]:.0f} W  util_avg(busy)={statistics.mean(ut_busy) if ut_busy else 0:.0f}%  temp_max={max(tp):.0f}C")
EOF
