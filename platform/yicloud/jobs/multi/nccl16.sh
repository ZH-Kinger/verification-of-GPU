#!/bin/bash
# 跨机 NCCL（2 节点 × 8 GPU），在 rank0 副本执行。
# 用镜像自带的 MLNX_OFED OpenMPI + libibverbs；只从工具目录借 libnccl.so.2（2.32.3），
# 不能把工具目录的 jammy libibverbs 放进 LD_LIBRARY_PATH，否则加载不了 OFED 的 mlx5 provider，NCCL 报 "No device found"。
set -u
PEER=${PEER:?需要设置 PEER=<对端副本 bond0 IP>}; SELF=$(ip -4 -o addr show bond0 | awk '{print $4}' | cut -d/ -f1)
T=/mnt/acceptance/GPU_Offline_Acceptance/tools; M=/usr/mpi/gcc/openmpi-4.1.7a1
OUT=/mnt/acceptance/results/multinode/nccl-$(date +%Y%m%d-%H%M%S); mkdir -p "$OUT"
mkdir -p /tmp/nlib && cp -f $T/lib/libnccl.so.2 /tmp/nlib/
ssh -p 22222 -o StrictHostKeyChecking=no "$PEER" "mkdir -p /tmp/nlib && cp -f $T/lib/libnccl.so.2 /tmp/nlib/"
export PATH=$M/bin:$PATH LD_LIBRARY_PATH=$M/lib:/tmp/nlib
HCA=mlx5_0:1,mlx5_1:1,mlx5_2:1,mlx5_3:1,mlx5_4:1,mlx5_5:1,mlx5_6:1,mlx5_7:1
MPI=(mpirun --allow-run-as-root --bind-to none -np 16 -H "$SELF:8,$PEER:8"
     --mca plm_rsh_args "-p 22222 -o StrictHostKeyChecking=no"
     --mca btl_tcp_if_include bond0 --mca oob_tcp_if_include bond0 --mca pml ob1 --mca btl tcp,self
     -x PATH -x LD_LIBRARY_PATH -x NCCL_IB_HCA=$HCA -x NCCL_IB_GID_INDEX=1 -x NCCL_SOCKET_IFNAME=bond0
     -x NCCL_DEBUG=WARN -x NCCL_IB_QPS_PER_CONNECTION=${QPS:-2})
log() { echo "[$(date -u +%T)] $*" | tee -a "$OUT/summary.txt"; }
busbw() { awk '$1 ~ /^[0-9]+$/ && NF>=12 {b=$8} END{print b}' "$1"; }  # out-of-place busbw @ 最大消息
log "nccl16 start  $SELF ↔ $PEER  HCA=$HCA  NCCL=$(strings /tmp/nlib/libnccl.so.2 | grep -m1 -E '^NCCL version')"
for op in all_reduce all_gather reduce_scatter alltoall sendrecv; do
  "${MPI[@]}" $T/bin/${op}_perf_mpi -b 8 -e 16G -f 2 -g 1 -w 5 -n 20 > "$OUT/${op}.txt" 2>&1
  log "$op 16 GPU busbw(16GiB) = $(busbw "$OUT/${op}.txt") GB/s   avg_busbw=$(grep -oE 'Avg bus bandwidth *: *[0-9.]+' "$OUT/${op}.txt" | awk '{print $NF}')"
done
# 纯网络：每节点 1 GPU（消除节点内 NVLink），以及每节点 8 GPU 仅 1 个 rail（单口上限参照）
"${MPI[@]/-np/-np}" >/dev/null 2>&1 || true
mpirun --allow-run-as-root --bind-to none -np 2 -H "$SELF:1,$PEER:1" --mca plm_rsh_args "-p 22222 -o StrictHostKeyChecking=no" \
  --mca btl_tcp_if_include bond0 --mca oob_tcp_if_include bond0 --mca pml ob1 --mca btl tcp,self \
  -x PATH -x LD_LIBRARY_PATH -x NCCL_IB_HCA=mlx5_0:1 -x NCCL_IB_GID_INDEX=1 -x NCCL_SOCKET_IFNAME=bond0 -x NCCL_DEBUG=WARN \
  $T/bin/all_reduce_perf_mpi -b 8 -e 8G -f 2 -g 1 -n 20 > "$OUT/all_reduce_1x2.txt" 2>&1
log "all_reduce 2 GPU(1/节点, 单口 mlx5_0) busbw(8GiB) = $(busbw "$OUT/all_reduce_1x2.txt") GB/s"
log "nccl16 done"
