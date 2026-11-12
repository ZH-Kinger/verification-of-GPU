#!/bin/bash
# RDMA 补测：GPUDirect RDMA（CUDA 版 perftest）+ 8 口并发聚合（按网卡 NUMA 绑核，复核 57% 的聚合结果）
# 用镜像自带的 OFED libibverbs；perftest 用工具目录里的 CUDA 版（bin-gdr）。
set -u
PEER=${PEER:?需要设置 PEER=<对端副本 bond0 IP>}
B=/mnt/acceptance/GPU_Offline_Acceptance/tools/bin-gdr
OUT=/mnt/acceptance/results/multinode/rdma2-$(date +%Y%m%d-%H%M%S); mkdir -p "$OUT"
SSHP="ssh -p 22222 -o StrictHostKeyChecking=no -o BatchMode=yes $PEER"
log() { echo "[$(date -u +%T)] $*" | tee -a "$OUT/summary.txt"; }
bw() { awk '$1 ~ /^[0-9]+$/ {b=$4} END{print b}' "$1"; }
numa() { cat /sys/class/infiniband/$1/device/numa_node; }
cpus_of() { cat /sys/devices/system/node/node$1/cpulist; }

log "== GPUDirect RDMA：GPU i 显存 ↔ 对端 GPU i 显存，经第 i 口（1MiB × qp4 × 10s）"
for i in 0 1 2 3 4 5 6 7; do
  d=mlx5_$i; p=$((19000 + i))
  $SSHP "$B/ib_write_bw -d $d -x 1 -s 1048576 -q 4 -D 10 --report_gbits --use_cuda=$i -p $p" > "$OUT/gdr_srv_$i.txt" 2>&1 &
  sleep 3
  $B/ib_write_bw -d $d -x 1 -s 1048576 -q 4 -D 10 --report_gbits --use_cuda=$i -p $p "$PEER" > "$OUT/gdr_$i.txt" 2>&1
  wait
  log "GPU$i ↔ $d  GDR write = $(bw "$OUT/gdr_$i.txt") Gb/s   $(grep -m1 -o 'using cuda device.*\|CUDA device.*' "$OUT/gdr_$i.txt" | head -c 60)"
done

log "== 8 口并发聚合（主机内存，按网卡 NUMA 绑核，1MiB × qp4 × 20s）"
for i in 0 1 2 3 4 5 6 7; do
  d=mlx5_$i; n=$(numa $d); p=$((19100 + i))
  $SSHP "taskset -c \$(cat /sys/devices/system/node/node$n/cpulist) $B/ib_write_bw -d $d -x 1 -s 1048576 -q 4 -D 20 --report_gbits -p $p" > /dev/null 2>&1 &
done
sleep 4
for i in 0 1 2 3 4 5 6 7; do
  d=mlx5_$i; n=$(numa $d); p=$((19100 + i))
  taskset -c "$(cpus_of $n)" $B/ib_write_bw -d $d -x 1 -s 1048576 -q 4 -D 20 --report_gbits -p $p "$PEER" > "$OUT/agg_$i.txt" 2>&1 &
done
wait
tot=0
for i in 0 1 2 3 4 5 6 7; do v=$(bw "$OUT/agg_$i.txt"); log "  mlx5_$i (NUMA $(numa mlx5_$i)) = $v Gb/s"; tot=$(awk -v a=$tot -v b=${v:-0} 'BEGIN{print a+b}'); done
log "aggregate (NUMA-bound) = $tot Gb/s"

log "== 8 口并发聚合（GPU 显存，GDR）"
for i in 0 1 2 3 4 5 6 7; do
  p=$((19200 + i))
  $SSHP "$B/ib_write_bw -d mlx5_$i -x 1 -s 1048576 -q 4 -D 20 --report_gbits --use_cuda=$i -p $p" > /dev/null 2>&1 &
done
sleep 5
for i in 0 1 2 3 4 5 6 7; do
  p=$((19200 + i))
  $B/ib_write_bw -d mlx5_$i -x 1 -s 1048576 -q 4 -D 20 --report_gbits --use_cuda=$i -p $p "$PEER" > "$OUT/gdragg_$i.txt" 2>&1 &
done
wait
tot=0; for i in 0 1 2 3 4 5 6 7; do v=$(bw "$OUT/gdragg_$i.txt"); tot=$(awk -v a=$tot -v b=${v:-0} 'BEGIN{print a+b}'); done
log "aggregate GDR 8-port = $tot Gb/s  per-port: $(for i in 0 1 2 3 4 5 6 7; do printf '%s ' $(bw "$OUT/gdragg_$i.txt"); done)"
log "rdma2 done"
