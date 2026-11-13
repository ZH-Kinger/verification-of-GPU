#!/bin/bash
# 硬件理论值复测，两台都跑（本机 + PEER 经 SSH）。结果写 GPFS。
# 用法: bash hwpeak.sh <label>     （label 区分节点，如 node-a2）
set -u
LABEL=$1
T=/mnt/acceptance/GPU_Offline_Acceptance/tools
OUT=/mnt/acceptance/results/hwpeak/$LABEL; mkdir -p "$OUT"
log() { echo "[$(date -u +%T)] $*" | tee -a "$OUT/summary.txt"; }
: > "$OUT/summary.txt"

log "== GEMM / HBM（镜像 torch 2.12.1+cu132，8 卡并行）"
source /mnt/acceptance/tools/imgenv.sh /opt/img/vla >/dev/null
python3 /mnt/acceptance/tools/hwpeak.py gemm > "$OUT/gemm.txt" 2>&1
python3 /mnt/acceptance/tools/hwpeak.py hbm  > "$OUT/hbm.txt"  2>&1
grep '@@RESULT' "$OUT/gemm.txt" "$OUT/hbm.txt" | sed 's/.*@@RESULT //' >> "$OUT/results.jsonl"

log "== nvbandwidth（标准口径：device_local_copy / H2D / D2H / D2D read & write，CE 与 SM）"
export LD_LIBRARY_PATH=$T/lib
$T/bin/nvbandwidth -t device_local_copy host_to_device_memcpy_ce device_to_host_memcpy_ce \
  host_to_device_memcpy_sm device_to_host_memcpy_sm device_to_device_memcpy_read_ce \
  device_to_device_memcpy_write_ce device_to_device_memcpy_read_sm all_to_host_memcpy_ce \
  host_to_all_memcpy_ce device_to_device_bidirectional_memcpy_read_ce > "$OUT/nvbandwidth.txt" 2>&1
grep -E "^Running|^SUM" "$OUT/nvbandwidth.txt" | paste - - | sed 's/Running //' | tee -a "$OUT/summary.txt" >/dev/null

log "== p2pBandwidthLatencyTest（cuda-samples）"
$T/bin/p2pBandwidthLatencyTest > "$OUT/p2p_latency.txt" 2>&1 || true

log "== STREAM（主机内存，OMP 绑核，两种布局）"
for cfg in "spread:$(nproc)" "close:$(nproc)"; do
  bind=${cfg%%:*}; n=${cfg#*:}
  OMP_NUM_THREADS=$n OMP_PROC_BIND=$bind OMP_PLACES=cores $T/bin/stream > "$OUT/stream_$bind.txt" 2>&1
  log "STREAM $bind threads=$n: $(grep -E '^(Copy|Scale|Add|Triad):' "$OUT/stream_$bind.txt" | awk '{printf "%s %.1f GB/s  ", $1, $2/1000}')"
done
# 单 NUMA（判断跨 NUMA 损失）
for node in 0 1; do
  cpus=$(cat /sys/devices/system/node/node$node/cpulist)
  OMP_NUM_THREADS=$(( $(nproc) / 2 )) taskset -c "$cpus" numactl --membind=$node $T/bin/stream > "$OUT/stream_numa$node.txt" 2>&1 \
    || OMP_NUM_THREADS=$(( $(nproc) / 2 )) taskset -c "$cpus" $T/bin/stream > "$OUT/stream_numa$node.txt" 2>&1
  log "STREAM NUMA$node only: $(grep -E '^Triad:' "$OUT/stream_numa$node.txt" | awk '{printf "Triad %.1f GB/s", $2/1000}')"
done
log "hwpeak done"
