#!/usr/bin/env bash
# 多机慢节点体检 —— 拓扑感知版，判定同批机器的均一性（对中位数），
# 与 nccl_scale.sh 互补：后者判绝对达标（对 profile 阈值），前者判有没有拖后腿的。
# 两个都要 —— 全员一起慢时 nccl_scale 会 FAIL 而本脚本全绿；
# 绝对达标但藏着一台差 15% 的机器时反过来。
#
#   bash scripts/cluster/straggler_check.sh <log_dir> <hostfile> [profile]
#
# 每个节点都要执行本脚本（由 mpirun/pdsh/调度器分发），NODE_RANK 自动推断或显式指定。
# 可调环境变量：
#   NNODES / NPROC_PER_NODE / NODE_RANK / MASTER_ADDR / MASTER_PORT
#   PREFLIGHT_TOPO_FILE          拓扑文件，缺省找 <log_dir>/topology.tsv
#   PREFLIGHT_LOOP=1             一直循环压测，供云厂商在线确认慢节点
#   PREFLIGHT_LOOP_ON_STRAGGLER=0  发现慢节点后直接退出，不驻留
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
. "$BASE_DIR/scripts/lib/common.sh"

PARENT="${1:-}"
HOSTFILE="${2:-}"
if [ -z "$PARENT" ] || [ -z "$HOSTFILE" ] || [ ! -f "$HOSTFILE" ]; then
  echo "用法: bash scripts/cluster/straggler_check.sh <log_dir> <hostfile> [profile]" >&2
  exit 2
fi
mkdir -p "$PARENT/cluster"
LOG_DIR="$(cd "$PARENT/cluster" && pwd)"
export LOG_DIR
load_profile "${3:-${PROFILE:-b300_8gpu}}" || exit 2

# 节点数与每节点卡数默认从 hostfile 推，避免和 §6 的 hostfile 各写一份漂移
HOSTS=()
while read -r h rest; do
  case "$h" in ''|'#'*) continue ;; esac
  HOSTS+=("$h")
  case "$rest" in slots=*) SLOTS="${rest#slots=}" ;; esac
done < "$HOSTFILE"
NNODES="${NNODES:-${#HOSTS[@]}}"
NPROC_PER_NODE="${NPROC_PER_NODE:-${SLOTS:-${EXPECTED_GPU_COUNT:-8}}}"

# 阈值来自 profile，脚本里不写死；缺失时不兜底成 0（0 会通过所有 >= 判定）
export PREFLIGHT_MIN_PERF_RATIO="${PREFLIGHT_MIN_PERF_RATIO:-${CLUSTER_STRAGGLER_MIN_RATIO:?profile 缺 CLUSTER_STRAGGLER_MIN_RATIO}}"
export PREFLIGHT_MIN_P2P_GBPS="${PREFLIGHT_MIN_P2P_GBPS:-${CLUSTER_PAIRWISE_MIN_GBS:-0}}"
export PREFLIGHT_MSG_MB="${PREFLIGHT_MSG_MB:-${CLUSTER_STRAGGLER_MSG_MB:-100}}"
# 绝对下限：缺省 0 表示未校准。0 会让对应项失去"整批一起劣化"的检测能力，
# 抬头会显式提示，不静默放行。
export PREFLIGHT_MIN_COMPUTE_TFLOPS="${PREFLIGHT_MIN_COMPUTE_TFLOPS:-${CLUSTER_COMPUTE_MIN_TFLOPS:-0}}"
export PREFLIGHT_MIN_RING_GBPS="${PREFLIGHT_MIN_RING_GBPS:-${CLUSTER_RING_MIN_GBS:-0}}"

# NCCL 走哪张网由 profile 决定 —— 原版写死 eth0/ib7s 是 alaya 集群的值，换集群必炸
[ -n "${CLUSTER_NCCL_SOCKET_IFNAME:-}" ] && export NCCL_SOCKET_IFNAME="$CLUSTER_NCCL_SOCKET_IFNAME"
[ -n "${CLUSTER_NCCL_IB_HCA:-}" ] && export NCCL_IB_HCA="$CLUSTER_NCCL_IB_HCA"
export NCCL_IB_DISABLE="${NCCL_IB_DISABLE:-0}"
export NCCL_P2P_DISABLE="${NCCL_P2P_DISABLE:-0}"
export PYTHONUNBUFFERED=1
# 把 NCCL 自己探到的拓扑与建出的通信图落盘 —— NCCL 认为的拓扑和你以为的不一定一致，
# 出问题时这是唯一能回溯的证据
export NCCL_TOPO_DUMP_FILE="${NCCL_TOPO_DUMP_FILE:-$LOG_DIR/nccl_topo_$(hostname).xml}"
export NCCL_GRAPH_DUMP_FILE="${NCCL_GRAPH_DUMP_FILE:-$LOG_DIR/nccl_graph_$(hostname).xml}"

TOPO_FILE="${PREFLIGHT_TOPO_FILE:-$LOG_DIR/topology.tsv}"
[ -f "$TOPO_FILE" ] || TOPO_FILE=""
export PREFLIGHT_TOPO_FILE="$TOPO_FILE"
export PREFLIGHT_JSON="${PREFLIGHT_JSON:-$LOG_DIR/straggler.json}"

if [ -z "${NODE_RANK:-}" ]; then
  ME="$(hostname)"
  NODE_RANK=""
  for i in "${!HOSTS[@]}"; do
    case "$ME" in "${HOSTS[$i]}"|"${HOSTS[$i]}".*) NODE_RANK="$i"; break ;; esac
  done
  [ -n "$NODE_RANK" ] || { echo "[straggler] 本机 $ME 不在 $HOSTFILE 里，请显式指定 NODE_RANK" >&2; exit 2; }
fi
MASTER_ADDR="${MASTER_ADDR:-${HOSTS[0]}}"
MASTER_PORT="${MASTER_PORT:-23456}"
PYTHON_BIN="${PYTHON_BIN:-python3}"

if ! "$PYTHON_BIN" -c 'import torch' 2>/dev/null; then
  echo "[straggler] $PYTHON_BIN 没有 torch —— 本项无法执行，判 SKIP 而不是 PASS" >&2
  echo "torch not available" > "$LOG_DIR/straggler_skipped.txt"
  exit 3
fi

echo "[straggler] nnodes=$NNODES nproc=$NPROC_PER_NODE node_rank=$NODE_RANK master=$MASTER_ADDR:$MASTER_PORT topo=${TOPO_FILE:-无}"
exec "$PYTHON_BIN" -m torch.distributed.run \
  --nnodes "$NNODES" --nproc_per_node "$NPROC_PER_NODE" --node_rank "$NODE_RANK" \
  --master_addr "$MASTER_ADDR" --master_port "$MASTER_PORT" \
  "$SCRIPT_DIR/straggler_check.py"
