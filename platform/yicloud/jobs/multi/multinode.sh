#!/bin/bash
# 多机验收（2 节点 × 8 GPU）。在 rank0 副本上执行；对端通过 SSH（副本间免密由本脚本建立）。
# 依赖平台注入：MASTER_ADDR / NODE_RANK / NODE_COUNT / NCCL_IB_HCA / NCCL_IB_GID_INDEX / NCCL_SOCKET_IFNAME
# 工具在 GPFS：/mnt/acceptance/GPU_Offline_Acceptance/tools/{bin,lib,mpi}
# 用法: bash multinode.sh <peer_host_or_ip> [phase...]
#   phase: env rdma gdr nccl gpfs   （默认全部，按此顺序）
set -u
PEER=$1; shift || true
PHASES=${*:-env rdma gdr nccl gpfs}
T=/mnt/acceptance/GPU_Offline_Acceptance/tools
OUT=/mnt/acceptance/results/multinode/$(date +%Y%m%d-%H%M%S); mkdir -p "$OUT"
export LD_LIBRARY_PATH=$T/lib:$T/mpi/lib-openmpi:${LD_LIBRARY_PATH:-}
export PATH=$T/bin:$T/mpi/bin:$PATH
export OPAL_PREFIX=$T/mpi OPAL_LIBDIR=$T/mpi/lib-openmpi OMPI_MCA_mca_base_component_path=$T/mpi/lib-openmpi/openmpi
SSHP="ssh -p 22222 -o StrictHostKeyChecking=no -o BatchMode=yes"   # 平台 sshd 在 22222
log() { echo "[$(date -u +%T)] $*" | tee -a "$OUT/summary.txt"; }
onpeer() { $SSHP "$PEER" "export LD_LIBRARY_PATH=$LD_LIBRARY_PATH PATH=$PATH; $*"; }

# RDMA 设备：优先用平台注入的 NCCL_IB_HCA（形如 mlx5_0:1,mlx5_1:1,...），否则枚举 400G 口
HCAS=$(echo "${NCCL_IB_HCA:-}" | tr ',' '\n' | sed 's/:.*//; s/^[=^]*//' | grep . )
export NCCL_IB_GID_INDEX=${NCCL_IB_GID_INDEX:-1} NCCL_SOCKET_IFNAME=${NCCL_SOCKET_IFNAME:-bond0}
[ -n "$HCAS" ] || true
[ -z "$HCAS" ] && HCAS=$(for d in /sys/class/infiniband/*; do r=$(cat $d/ports/1/rate 2>/dev/null); case "$r" in 400*) basename $d;; esac; done)
export NCCL_IB_HCA=${NCCL_IB_HCA:-$(echo $HCAS | tr ' ' '\n' | sed 's/$/:1/' | paste -sd,)}
GID=${NCCL_IB_GID_INDEX:-1}   # 本平台 400G 轨道口只有 IPv6 链路本地地址，RoCE v2 在 idx 1

phase_env() {
  log "== env"
  { hostname; env | grep -E '^(NCCL_|NODE_|MASTER_|PROC_PER_NODE|OMPI_|UCX_)' | sort
    echo "HCAS: $(echo $HCAS | tr '\n' ' ') GID=$GID"
    ls -la /dev/infiniband 2>&1 | head -20
    for d in $HCAS; do echo "$d $(cat /sys/class/infiniband/$d/ports/1/state) $(cat /sys/class/infiniband/$d/ports/1/rate) $(cat /sys/class/infiniband/$d/ports/1/gids/$GID 2>/dev/null)"; done
    lsmod 2>/dev/null | grep -E 'nvidia_peermem|ib_core|mlx5' ; cat /proc/modules 2>/dev/null | grep -c nvidia_peermem
    nvidia-smi topo -m | head -20
    echo "peer: $PEER"; onpeer hostname
  } > "$OUT/env.txt" 2>&1
  log "$(grep -c '' "$OUT/env.txt") lines; /dev/infiniband: $(ls /dev/infiniband 2>/dev/null | wc -l) nodes; HCAs: $(echo $HCAS | wc -w)"
}

# 逐口 ib_write_bw / ib_write_lat，然后 8 口并发聚合
phase_rdma() {
  log "== RDMA 逐口带宽/时延（ib_write_bw 64KiB×qp4，ib_write_lat 2B）"
  local port=18515
  for d in $HCAS; do
    onpeer "ib_write_bw -d $d -x $GID -s 65536 -q 4 -D 10 --report_gbits -p $port" > "$OUT/bw_srv_$d.txt" 2>&1 &
    sleep 2
    ib_write_bw -d $d -x $GID -s 65536 -q 4 -D 10 --report_gbits -p $port "$PEER" > "$OUT/bw_$d.txt" 2>&1
    wait
    bw=$(awk '/^ *65536/{print $4}' "$OUT/bw_$d.txt" | tail -1)
    onpeer "ib_write_lat -d $d -x $GID -s 2 -n 10000 -p $((port+1))" > /dev/null 2>&1 &
    sleep 2
    ib_write_lat -d $d -x $GID -s 2 -n 10000 -p $((port+1)) "$PEER" > "$OUT/lat_$d.txt" 2>&1
    wait
    lat=$(awk '/^ *2 /{print $6}' "$OUT/lat_$d.txt" | tail -1)
    log "$d  bw=${bw:-FAIL} Gb/s  lat_avg=${lat:-FAIL} us"
  done
  log "== RDMA 8 口并发聚合"
  local i=0
  for d in $HCAS; do onpeer "ib_write_bw -d $d -x $GID -s 1048576 -q 4 -D 15 --report_gbits -p $((port+10+i))" >/dev/null 2>&1 & i=$((i+1)); done
  sleep 3; i=0
  for d in $HCAS; do ib_write_bw -d $d -x $GID -s 1048576 -q 4 -D 15 --report_gbits -p $((port+10+i)) "$PEER" > "$OUT/agg_$d.txt" 2>&1 & i=$((i+1)); done
  wait
  agg=$(cat "$OUT"/agg_*.txt | awk '/^ *1048576/{s+=$4} END{print s+0}')
  log "aggregate 8-port write bw = ${agg} Gb/s ($(awk -v a=$agg 'BEGIN{printf "%.1f", a/8}') GB/s)"
}

# GPUDirect RDMA：GPU i ↔ 配对网卡
phase_gdr() {
  log "== GPUDirect RDMA（ib_write_bw --use_cuda，GPU i ↔ 第 i 口）"
  local i=0 port=18600
  for d in $HCAS; do
    onpeer "ib_write_bw -d $d -x $GID -s 1048576 -q 4 -D 10 --report_gbits --use_cuda=$i -p $port" > /dev/null 2>&1 &
    sleep 3
    ib_write_bw -d $d -x $GID -s 1048576 -q 4 -D 10 --report_gbits --use_cuda=$i -p $port "$PEER" > "$OUT/gdr_${i}_$d.txt" 2>&1
    wait
    bw=$(awk '/^ *1048576/{print $4}' "$OUT/gdr_${i}_$d.txt" | tail -1)
    log "GPU$i ↔ $d  gdr_bw=${bw:-FAIL} Gb/s"
    i=$((i+1)); [ $i -ge 8 ] && break
  done
}

# 跨机 NCCL，16 rank（每节点 8），mpirun 经 SSH 拉起对端
phase_nccl() {
  log "== 跨机 NCCL 16 卡（nccl-tests MPI 版，-b 8 -e 16G -f 2）"
  printf '%s slots=8\n%s slots=8\n' "$(ip -4 -o addr show bond0 | awk '{print $4}' | cut -d/ -f1)" "$PEER" > "$OUT/hostfile"
  local MPI="$T/mpi/bin/mpirun --prefix $T/mpi --allow-run-as-root --hostfile $OUT/hostfile -np 16 --bind-to none \
    -x LD_LIBRARY_PATH -x PATH -x OPAL_PREFIX -x OPAL_LIBDIR -x OMPI_MCA_mca_base_component_path \
    -x NCCL_IB_HCA -x NCCL_IB_GID_INDEX -x NCCL_SOCKET_IFNAME -x NCCL_DEBUG=WARN \
    --mca plm_rsh_agent ssh --mca plm_rsh_args '-p 22222 -o StrictHostKeyChecking=no' --mca orte_keep_fqdn_hostnames 1 --mca btl_tcp_if_include ${NCCL_SOCKET_IFNAME:-eth0}"
  for op in all_reduce all_gather reduce_scatter alltoall sendrecv; do
    eval $MPI $T/bin/${op}_perf_mpi -b 8 -e 16G -f 2 -g 1 -w 5 -n 20 > "$OUT/nccl_$op.txt" 2>&1
    bus=$(awk '$1 ~ /^[0-9]+$/ && NF>=12 {b=$8} END{print b}' "$OUT/nccl_$op.txt")
    log "$op 16 GPU busbw(16G) = ${bus:-FAIL} GB/s"
  done
  # 纯网络路径（排除节点内 NVLink 的贡献）：每节点 1 卡 × 2 节点
  printf '%s slots=1\n%s slots=1\n' "$(ip -4 -o addr show bond0 | awk '{print $4}' | cut -d/ -f1)" "$PEER" > "$OUT/hostfile1"
  eval ${MPI/-np 16/-np 2} --hostfile $OUT/hostfile1 $T/bin/all_reduce_perf_mpi -b 8 -e 8G -f 2 -g 1 > "$OUT/nccl_allreduce_1x2.txt" 2>&1
  log "all_reduce 2 GPU (1/node) busbw = $(awk '$1 ~ /^[0-9]+$/ && NF>=12 {b=$8} END{print b}' "$OUT/nccl_allreduce_1x2.txt") GB/s"
}

# GPFS 双机并发：两台同时 fio 顺序读/写，求聚合
phase_gpfs() {
  log "== GPFS 双客户端并发（16M × 32 jobs × qd16，各 45s）"
  local FIO=$T/bin/fio
  for rw in write read; do
    for h in local peer; do
      cmd="mkdir -p /mnt/acceptance/fio2/\$(hostname) && $FIO --name=g --directory=/mnt/acceptance/fio2/\$(hostname) --rw=$rw --bs=16M --iodepth=16 --numjobs=32 --size=4G --runtime=45 --ramp_time=5 --time_based --ioengine=libaio --direct=1 --group_reporting --output-format=json"
      if [ $h = local ]; then bash -c "$cmd" > "$OUT/gpfs2_${rw}_local.json" 2>/dev/null &
      else onpeer "$cmd" > "$OUT/gpfs2_${rw}_peer.json" 2>/dev/null & fi
    done
    wait
    agg=$(python3 - "$OUT" "$rw" <<'EOF'
import json,sys,glob
s=0
for f in glob.glob(f"{sys.argv[1]}/gpfs2_{sys.argv[2]}_*.json"):
    try: j=json.load(open(f))["jobs"][0]; s+=j["read"]["bw_bytes"]+j["write"]["bw_bytes"]
    except Exception: pass
print(f"{s/1e9:.2f}")
EOF
)
    log "GPFS 2-client aggregate $rw = $agg GB/s"
  done
  rm -rf /mnt/acceptance/fio2
}

log "multinode start: $(hostname) ↔ $PEER  phases: $PHASES  out=$OUT"
for p in $PHASES; do "phase_$p"; done
log "multinode done"
