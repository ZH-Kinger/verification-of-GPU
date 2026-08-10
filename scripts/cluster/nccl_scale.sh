#!/usr/bin/env bash
# 多机压测 —— 《验收标准》§6 跨节点 NCCL 通信（IB / RoCE 通用）。
#
#   bash scripts/cluster/nccl_scale.sh <log_dir> <hostfile> [profile]
#
# 按 profile 里的 CLUSTER_ALLREDUCE_SCALE 依次跑 2/4/8/16 节点的 AllReduce，
# 再在 2 节点规模上补 AllGather / ReduceScatter / AlltoAll / SendRecv，
# 最后跑一次"纯 RoCE"AllReduce（NCCL_ALGO=Ring + NCCL_CROSS_NIC=1，排除 NVLink）。
#
# 前置条件（缺一不可，脚本会先自检）：
#   - mpirun 可用，且各节点免密 SSH（scripts/cluster/setup_ssh.sh）
#   - 各节点有 *_perf_mpi 二进制（MPI=1 编译；当前 tools/bin 是 MPI=0 版本，
#     必须先按 docs/tooling_gaps.md 补齐）
#   - 各节点驱动/NCCL 版本一致

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
. "$BASE_DIR/scripts/lib/common.sh"

PARENT="${1:-}"
HOSTFILE="${2:-}"
if [ -z "$PARENT" ] || [ -z "$HOSTFILE" ] || [ ! -f "$HOSTFILE" ]; then
  echo "用法: bash scripts/cluster/nccl_scale.sh <log_dir> <hostfile> [profile]" >&2
  echo "      hostfile 参考 scripts/cluster/hosts.template" >&2
  exit 2
fi
mkdir -p "$PARENT/cluster"
LOG_DIR="$(cd "$PARENT/cluster" && pwd)"
export LOG_DIR

load_profile "${3:-${PROFILE:-b300_8gpu}}" || exit 2

log() { echo "[nccl_scale] $*" | tee -a "$LOG_DIR/run.log"; }

# ------------------------------------------------------------------ 自检
if ! command -v mpirun >/dev/null 2>&1; then
  echo "[nccl_scale] mpirun 不存在 —— §6 全部项无法执行。" >&2
  echo "mpirun not found" > "$LOG_DIR/mpirun_missing.txt"
  exit 1
fi

MPI_BIN_DIR="${MPI_BIN_DIR:-$(tools_bin_dir)}"
need_mpi_bin() {
  local n="$1"
  if [ -x "$MPI_BIN_DIR/$n" ]; then echo "$MPI_BIN_DIR/$n"; return 0; fi
  command -v "$n" 2>/dev/null && return 0
  return 1
}
if ! need_mpi_bin all_reduce_perf_mpi >/dev/null; then
  echo "[nccl_scale] all_reduce_perf_mpi 不存在。当前 tools 里是 MPI=0 编译的版本，" >&2
  echo "             无法做跨节点测试。补齐方法见 docs/tooling_gaps.md。" >&2
  echo "all_reduce_perf_mpi not found" > "$LOG_DIR/nccl_mpi_missing.txt"
  exit 1
fi

# 清理并规范 hostfile（去注释空行）
grep -vE '^\s*(#|$)' "$HOSTFILE" > "$LOG_DIR/hosts.all"
TOTAL_NODES="$(wc -l < "$LOG_DIR/hosts.all")"
log "hostfile 有效节点数: $TOTAL_NODES"
cp -f "$HOSTFILE" "$LOG_DIR/hosts.original"

MPI_COMMON="${MPI_COMMON:--x NCCL_DEBUG=WARN -x LD_LIBRARY_PATH -x PATH --allow-run-as-root}"

run_mpi() {
  local name="$1" nodes="$2" tool="$3"
  shift 3
  local np=$((nodes * EXPECTED_GPU_COUNT))
  local bin hf="$LOG_DIR/hosts.${nodes}n"
  head -n "$nodes" "$LOG_DIR/hosts.all" > "$hf"
  bin="$(need_mpi_bin "$tool")" || { echo "$tool not found" > "$LOG_DIR/${name}_missing.txt"; return 0; }
  log "$name: $nodes 节点 / $np GPU"
  # shellcheck disable=SC2086
  run_shell "$name" "mpirun -np $np -N $EXPECTED_GPU_COUNT --hostfile $hf $MPI_COMMON $* $bin $CLUSTER_BENCH_ARGS"
}

# ------------------------------------------- §6 AllReduce 规模扫描 2/4/8/16
for entry in $CLUSTER_ALLREDUCE_SCALE; do
  n="${entry%%:*}"
  if [ "$n" -gt "$TOTAL_NODES" ]; then
    log "跳过 ${n} 节点（hostfile 只有 $TOTAL_NODES 个节点）"
    echo "hostfile only has $TOTAL_NODES nodes" > "$LOG_DIR/allreduce_${n}n_skipped.txt"
    continue
  fi
  run_mpi "allreduce_${n}n" "$n" all_reduce_perf_mpi
done

# ------------------------------------------------- §6 2 节点上的其余集合通信
if [ "$TOTAL_NODES" -ge 2 ]; then
  run_mpi allgather_2n     2 all_gather_perf_mpi
  run_mpi reducescatter_2n 2 reduce_scatter_perf_mpi
  run_mpi alltoall_2n      2 alltoall_perf_mpi
  run_mpi sendrecv_2n      2 sendrecv_perf_mpi
else
  log "节点不足 2 台，§6 其余项跳过"
fi

# ------------------------------------------ §5 纯 RoCE AllReduce（排除 NVLink）
# 每节点只用 1 个 GPU（-N 1 -g 1），强制走网卡，用来单独验证 RoCE 通路。
if [ "$TOTAL_NODES" -ge 2 ]; then
  bin="$(need_mpi_bin all_reduce_perf_mpi)"
  head -n 2 "$LOG_DIR/hosts.all" > "$LOG_DIR/hosts.roce"
  log "纯 RoCE AllReduce（NCCL_ALGO=Ring, NCCL_CROSS_NIC=1, 每节点 1 GPU）"
  run_shell roce_only_allreduce \
    "NCCL_ALGO=Ring NCCL_CROSS_NIC=1 mpirun -np 2 -N 1 --hostfile $LOG_DIR/hosts.roce \
     $MPI_COMMON -x NCCL_ALGO -x NCCL_CROSS_NIC $bin -b 512M -e 8G -f 2 -g 1"
fi

log "完成。判定：bash scripts/cluster/check_cluster.sh $PARENT"
echo "Cluster logs: $LOG_DIR"
