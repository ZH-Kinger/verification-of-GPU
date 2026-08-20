#!/usr/bin/env bash
# 多机验收一键入口 —— 把 §5 §6 §6b 串成一条命令，支持断点续跑。
#
#   sudo bash scripts/cluster/run_cluster.sh <hostfile> [profile]
#   sudo bash scripts/cluster/run_cluster.sh --check-env <hostfile> [profile]   只查环境不压测
#   sudo bash scripts/cluster/run_cluster.sh --dry-run   <hostfile> [profile]   只列阶段与预计耗时
#
# 在 head 节点（hostfile 第一行）执行；其余节点由本脚本经免密 SSH 分发。
# 阶段成功才打 .done 标记，中断后重跑同一条命令从断点继续。
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
. "$BASE_DIR/scripts/lib/common.sh"

MODE=run
case "${1:-}" in
  --check-env) MODE=check-env; shift ;;
  --dry-run)   MODE=dry-run;   shift ;;
  -h|--help)   sed -n '2,12p' "$0"; exit 0 ;;
esac

HOSTFILE="${1:-}"
if [ -z "$HOSTFILE" ] || [ ! -f "$HOSTFILE" ]; then
  echo "用法: sudo bash scripts/cluster/run_cluster.sh [--check-env|--dry-run] <hostfile> [profile]" >&2
  echo "      hostfile 参考 scripts/cluster/hosts.template" >&2
  exit 2
fi

HOSTS=(); SLOTS=""
while read -r h rest; do
  case "$h" in ''|'#'*) continue ;; esac
  HOSTS+=("$h")
  case "$rest" in slots=*) SLOTS="${rest#slots=}" ;; esac
done < "$HOSTFILE"
[ "${#HOSTS[@]}" -ge 2 ] || { echo "[cluster] hostfile 至少要 2 个节点，当前 ${#HOSTS[@]} 个" >&2; exit 2; }

if ! PROFILE_NAME_ARG="$(resolve_profile "${2:-${PROFILE:-}}")"; then
  echo "[cluster] 无法确定机型档案，请显式指定：run_cluster.sh <hostfile> <profile>" >&2
  exit 2
fi
load_profile "$PROFILE_NAME_ARG" || exit 2

TS="$(date +%Y%m%d_%H%M%S)"
PARENT="${CLUSTER_LOG_DIR:-$BASE_DIR/logs/cluster_$TS}"
mkdir -p "$PARENT/cluster"
STATE="$PARENT/.cluster-state"; mkdir -p "$STATE"
NNODES="${#HOSTS[@]}"
NPROC="${SLOTS:-${EXPECTED_GPU_COUNT:-8}}"

log() { echo "[cluster] $*" | tee -a "$PARENT/run.log"; }

# 预计耗时：现场要靠它安排值班，尤其 §8 那种跨夜的
declare -a STAGES=(
  "ssh|SSH 免密与一致性检查|1"
  "topo|拓扑发现（LLDP / iblinkinfo）|2"
  "roce|§5 RoCE v2 网络检查与打流|10"
  "nccl|§6 跨节点 NCCL 规模测试|25"
  "straggler|§6b 慢节点体检（拓扑感知）|10"
  "report|解析并出判定表|1"
)

if [ "$MODE" = dry-run ]; then
  total=0
  echo "多机验收流程预览（$NNODES 节点 × $NPROC 卡，profile=$PROFILE_NAME_ARG）"
  echo "结果目录：$PARENT"
  printf '%-12s %-40s %s\n' 阶段 说明 预计耗时
  for entry in "${STAGES[@]}"; do
    IFS='|' read -r id desc mins <<< "$entry"
    mark=""; [ -f "$STATE/$id.done" ] && mark="（已完成，将跳过）"
    printf '%-12s %-40s %s 分钟%s\n' "$id" "$desc" "$mins" "$mark"
    [ -f "$STATE/$id.done" ] || total=$((total + mins))
  done
  echo "----"
  echo "剩余合计约 $total 分钟（不含排队与人工确认；§5 打流需对端配合起 server）"
  exit 0
fi

# ---------------------------------------------------------------- SSH 检查
if [ ! -f "$STATE/ssh.done" ] || [ "$MODE" = check-env ]; then
  log "检查 head 到全部节点（含自己）的免密 SSH"
  bad=0
  for h in "${HOSTS[@]}"; do
    if ssh -o BatchMode=yes -o ConnectTimeout=10 "$h" true 2>/dev/null; then
      echo "  $h  OK" | tee -a "$PARENT/run.log"
    else
      echo "  $h  失败" | tee -a "$PARENT/run.log"; bad=1
    fi
  done
  if [ "$bad" != 0 ]; then
    log "免密 SSH 未配好。先跑：bash scripts/cluster/setup_ssh.sh $HOSTFILE"
    exit 1
  fi
  # 各节点本项目路径必须一致，否则分发的命令找不到脚本
  for h in "${HOSTS[@]}"; do
    ssh -o BatchMode=yes "$h" "test -x '$BASE_DIR/scripts/cluster/straggler_check.sh'" 2>/dev/null \
      || { log "$h 上缺少 $BASE_DIR（各节点本项目路径必须一致）"; exit 1; }
  done
  touch "$STATE/ssh.done"
fi

if [ "$MODE" = check-env ]; then
  log "[PASS] 环境检查完成，未执行任何负载"
  exit 0
fi

run_stage() {  # <id> <说明> <命令...>
  local id="$1" desc="$2"; shift 2
  if [ -f "$STATE/$id.done" ]; then log "[跳过] $desc（已完成）"; return 0; fi
  log "[执行] $desc"
  "$@" 2>&1 | tee -a "$PARENT/run.log"
  local rc="${PIPESTATUS[0]}"
  # 阶段失败不打标记 —— 重跑时会从这里继续，不会把失败当成跑过了
  [ "$rc" = 0 ] && touch "$STATE/$id.done"
  return "$rc"
}

run_stage topo "拓扑发现" bash "$SCRIPT_DIR/topo_discover.sh" "$PARENT" "$HOSTFILE" || \
  log "拓扑发现未成功；跨组对比将退化为单组（判定表会标 MANUAL）"

run_stage roce "§5 RoCE v2" bash "$SCRIPT_DIR/roce_check.sh" "$PARENT" "$PROFILE_NAME_ARG" || \
  log "§5 未全部完成，判定表对应项会体现"

run_stage nccl "§6 跨节点 NCCL" bash "$SCRIPT_DIR/nccl_scale.sh" "$PARENT" "$HOSTFILE" "$PROFILE_NAME_ARG" || \
  log "§6 未全部完成，判定表对应项会体现"

# ------------------------------------------------ §6b 慢节点体检：并发分发到各节点
if [ ! -f "$STATE/straggler.done" ]; then
  log "[执行] §6b 慢节点体检（分发到 $NNODES 个节点）"
  MASTER="${HOSTS[0]}"
  pids=()
  for i in "${!HOSTS[@]}"; do
    h="${HOSTS[$i]}"
    env_pre="NNODES=$NNODES NPROC_PER_NODE=$NPROC NODE_RANK=$i MASTER_ADDR=$MASTER"
    if [ "$i" = 0 ]; then
      env NNODES="$NNODES" NPROC_PER_NODE="$NPROC" NODE_RANK=0 MASTER_ADDR="$MASTER" \
        bash "$SCRIPT_DIR/straggler_check.sh" "$PARENT" "$HOSTFILE" "$PROFILE_NAME_ARG" \
        > "$PARENT/cluster/straggler_rank0.log" 2>&1 &
    else
      ssh -o BatchMode=yes "$h" \
        "cd '$BASE_DIR' && $env_pre bash scripts/cluster/straggler_check.sh '$PARENT' '$HOSTFILE' '$PROFILE_NAME_ARG'" \
        > "$PARENT/cluster/straggler_rank$i.log" 2>&1 &
    fi
    pids+=("$!")
  done
  rc=0
  for pid in "${pids[@]}"; do wait "$pid" || rc=$?; done
  cat "$PARENT/cluster/straggler_rank0.log" | tee -a "$PARENT/run.log"
  # rank0 的退出码是判定结果（1=发现慢节点），不是执行失败；只有非 0/1 才算没跑成
  if [ "$rc" -le 1 ]; then touch "$STATE/straggler.done"; else
    log "§6b 执行异常（rc=$rc），见 $PARENT/cluster/straggler_rank*.log"
  fi
fi

run_stage report "解析并出判定表" bash "$SCRIPT_DIR/check_cluster.sh" "$PARENT" "$PROFILE_NAME_ARG"
VERDICT_RC=$?

log "判定表: $PARENT/cluster_report.txt"
log "HTML:   $PARENT/cluster_report.html"
log "中断后重跑同一条命令即可从断点继续；要重跑某阶段就删掉 $STATE/<阶段>.done"
exit "$VERDICT_RC"
