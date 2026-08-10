#!/usr/bin/env bash
# 长稳烤机 —— 《验收标准》§8。
#
#   sudo bash scripts/soak_node.sh <log_dir> [profile]
#
# 同时做三件事，全程持续到 SOAK_SECONDS：
#   1. gpu_burn -tc <SOAK_SECONDS>            满载算力
#   2. 循环跑节点内 NCCL AllReduce            持续压 NVLink（标准要求"持续 NCCL AllReduce"）
#   3. 每 SOAK_SAMPLE_INTERVAL_S 采样一次     温度/功耗/时钟/节流 + 标准指定的 dmon
#
# 开跑前后各做一次 ECC / XID / NVLink CRC 快照，判定用的是增量而不是绝对值。
#
# 注意（U 盘现场）：日志目录必须落在持久化分区上，GPU_DATA(exFAT) 或 writable(ext4)
# 均可，但不要落在 live 系统的 tmpfs —— 十几小时的采样会吃满内存。

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

PARENT_LOG_DIR="${1:-}"
if [ -z "$PARENT_LOG_DIR" ] || [ ! -d "$PARENT_LOG_DIR" ]; then
  echo "用法: sudo bash scripts/soak_node.sh <log_dir> [profile]" >&2
  echo "      <log_dir> 用 collect_node.sh 生成的那个目录，结果写入其 soak/ 子目录。" >&2
  exit 2
fi
PARENT_LOG_DIR="$(cd "$PARENT_LOG_DIR" && pwd)"

PROFILE_ARG="${2:-${PROFILE:-b300_8gpu}}"
load_profile "$PROFILE_ARG" || exit 2

SOAK_DIR="$PARENT_LOG_DIR/soak"
mkdir -p "$SOAK_DIR"
LOG_DIR="$SOAK_DIR"
export LOG_DIR

DURATION="${SOAK_SECONDS_OVERRIDE:-$SOAK_SECONDS}"
INTERVAL="$SOAK_SAMPLE_INTERVAL_S"

log() { echo "[soak] $*" | tee -a "$SOAK_DIR/run.log"; }

if ! command -v nvidia-smi >/dev/null 2>&1; then
  echo "[soak] nvidia-smi 不存在（当前多半在 fieldiag 模式）。§8 需要驱动。" >&2
  exit 1
fi

BURN="$(tool_path gpu_burn 2>/dev/null || true)"
AR="$(tool_path all_reduce_perf 2>/dev/null || true)"

if [ -z "$BURN" ]; then
  echo "[soak] gpu_burn 未找到 —— §8 的主压测项无法执行。见 docs/tooling_gaps.md。" >&2
  echo "[soak] 仍会继续采样 + NCCL 循环，但判定会记为不完整。" >&2
fi

log "duration=${DURATION}s (~$((DURATION / 3600))h)  interval=${INTERVAL}s  profile=$ACC_PROFILE"
echo "$DURATION" > "$SOAK_DIR/duration_seconds.txt"

# ------------------------------------------------------------ 起始快照
snapshot() {
  local tag="$1"
  nvidia-smi --query-gpu=index,ecc.errors.corrected.volatile.total,ecc.errors.uncorrected.aggregate.total \
    --format=csv,noheader > "$SOAK_DIR/ecc_${tag}.csv" 2>&1
  dmesg -T 2>/dev/null | grep -ci 'xid' > "$SOAK_DIR/xid_${tag}.txt" 2>/dev/null || echo 0 > "$SOAK_DIR/xid_${tag}.txt"
  {
    for i in $(seq 0 $((EXPECTED_GPU_COUNT - 1))); do
      echo "== GPU $i =="
      nvidia-smi nvlink -e -i "$i" 2>&1
    done
  } > "$SOAK_DIR/nvlink_errors_${tag}.txt"
}

sum_col() { awk -F',' -v c="$2" '{gsub(/ /,"",$c); s+=$c} END{print s+0}' "$1"; }
# 按 GPU index 配对求增量，取最大值 —— 标准的 ECC 阈值是"单卡"口径，
# 直接拿 max(after)-max(before) 或求和都会算错。
max_delta_col() {
  awk -F',' -v c="$3" '
    NR==FNR { gsub(/ /,"",$1); gsub(/ /,"",$c); b[$1]=$c+0; next }
    { gsub(/ /,"",$1); gsub(/ /,"",$c); d=($c+0)-b[$1]; if(d>m) m=d }
    END { print m+0 }' "$1" "$2"
}
sum_nvlink_err() {
  awk -F: '/[Ee]rror|[Rr]eplay|CRC/{gsub(/[^0-9]/,"",$NF); if($NF!="") s+=$NF} END{print s+0}' "$1"
}

log "采集起始快照"
snapshot before

# ------------------------------------------------------------ 采样器
sampler() {
  local end=$(( $(date +%s) + DURATION + 30 ))
  echo "timestamp,index,temperature_gpu,power_draw_w,sm_clock_mhz,throttle_reasons,utilization_pct" \
    > "$SOAK_DIR/samples.csv"
  while [ "$(date +%s)" -lt "$end" ]; do
    nvidia-smi --query-gpu=index,temperature.gpu,power.draw,clocks.current.graphics,clocks_throttle_reasons.active,utilization.gpu \
      --format=csv,noheader 2>/dev/null \
      | while IFS= read -r line; do
          printf '%s,%s\n' "$(date +%s)" "$line"
        done >> "$SOAK_DIR/samples.csv"
    sleep "$INTERVAL"
  done
}

# NCCL 持续负载：标准要求"gpu_burn + 持续 NCCL AllReduce"
nccl_loop() {
  local end=$(( $(date +%s) + DURATION ))
  local n=0
  : > "$SOAK_DIR/nccl_loop.txt"
  [ -z "$AR" ] && { echo "all_reduce_perf 未找到，NCCL 持续负载跳过" > "$SOAK_DIR/nccl_loop.txt"; return 0; }
  while [ "$(date +%s)" -lt "$end" ]; do
    n=$((n + 1))
    echo "===== iteration $n @ $(date -Is) =====" >> "$SOAK_DIR/nccl_loop.txt"
    # shellcheck disable=SC2086
    "$AR" $NCCL_BENCH_ARGS >> "$SOAK_DIR/nccl_loop.txt" 2>&1
  done
  echo "$n" > "$SOAK_DIR/nccl_iterations.txt"
}

# 标准点名的 dmon（列布局随驱动版本变化，判定用 samples.csv，dmon 作为留证）
# --foreground 不能省：GNU timeout 默认会把子进程放进它自己新建的进程组，
# 那样 cleanup 按作业进程组回收就够不着它，中断后 nvidia-smi dmon 会一直活着。
dmon_record() {
  timeout --foreground "$((DURATION + 60))" nvidia-smi dmon -s pucvmet -d "$INTERVAL" \
    > "$SOAK_DIR/dmon.txt" 2>&1 || true
}

log "启动采样器 / dmon / NCCL 负载"
# 开作业控制，让每个后台作业自成进程组：只 kill 作业本身的 PID 收不掉它的子进程
# （dmon 下面还挂着 timeout 和 nvidia-smi，all_reduce_perf 也是独立子进程），
# 被中断的 18h 烤机会留下一个还在跑的采样器，下次重跑两个采样器互相打架。
set -m
sampler &     SAMPLER_PID=$!
dmon_record & DMON_PID=$!
nccl_loop &   NCCL_PID=$!
set +m

kill_group() {
  local pid="${1:-}"
  [ -n "$pid" ] || return 0
  # 负号 = 整个进程组；进程组不存在时退回到只杀该进程
  kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
}

CLEANED=0
cleanup() {
  [ "$CLEANED" = "1" ] && return 0
  CLEANED=1
  local p
  for p in "$SAMPLER_PID" "$DMON_PID" "$NCCL_PID"; do kill_group "$p"; done
  sleep 1
  for p in "$SAMPLER_PID" "$DMON_PID" "$NCCL_PID"; do
    kill -KILL -- "-$p" 2>/dev/null || true
  done
  wait "$SAMPLER_PID" "$DMON_PID" "$NCCL_PID" 2>/dev/null || true
}
# EXIT 也挂上：脚本因任何原因结束都要回收，否则采样器会活到下一次验收
trap 'log "收到中断，正在收尾"; cleanup; exit 130' INT TERM
trap 'cleanup' EXIT

# ------------------------------------------------------------ 主压测
if [ -n "$BURN" ]; then
  log "gpu_burn -tc $DURATION 开始（$(date -Is)）"
  ( cd "$(dirname "$BURN")" && ./"$(basename "$BURN")" -tc "$DURATION" ) \
    > "$SOAK_DIR/gpu_burn.txt" 2>&1
  echo "$?" > "$SOAK_DIR/gpu_burn.exit"
  log "gpu_burn 结束（$(date -Is)），exit=$(cat "$SOAK_DIR/gpu_burn.exit")"
else
  log "gpu_burn 缺失，仅以 NCCL 负载维持 ${DURATION}s"
  sleep "$DURATION"
  echo "127" > "$SOAK_DIR/gpu_burn.exit"
  echo "gpu_burn not installed" > "$SOAK_DIR/gpu_burn.txt"
fi

cleanup
trap - INT TERM

# ------------------------------------------------------------ 结束快照与增量
log "采集结束快照"
snapshot after

ecc_u_before="$(sum_col "$SOAK_DIR/ecc_before.csv" 3)"
ecc_u_after="$(sum_col "$SOAK_DIR/ecc_after.csv" 3)"
xid_before="$(cat "$SOAK_DIR/xid_before.txt" 2>/dev/null || echo 0)"
xid_after="$(cat "$SOAK_DIR/xid_after.txt" 2>/dev/null || echo 0)"
crc_before="$(sum_nvlink_err "$SOAK_DIR/nvlink_errors_before.txt")"
crc_after="$(sum_nvlink_err "$SOAK_DIR/nvlink_errors_after.txt")"

max_delta_col "$SOAK_DIR/ecc_before.csv" "$SOAK_DIR/ecc_after.csv" 2 > "$SOAK_DIR/ecc_corrected_delta.txt"
echo "$((ecc_u_after - ecc_u_before))" > "$SOAK_DIR/ecc_uncorrected_delta.txt"
echo "$((xid_after - xid_before))"     > "$SOAK_DIR/xid_delta.txt"
echo "$((crc_after - crc_before))"     > "$SOAK_DIR/nvlink_crc_delta.txt"

{
  echo "长稳烤机结果（增量口径）"
  echo "duration            : ${DURATION}s"
  echo "gpu_burn exit       : $(cat "$SOAK_DIR/gpu_burn.exit")"
  echo "NCCL 迭代次数        : $(cat "$SOAK_DIR/nccl_iterations.txt" 2>/dev/null || echo 0)"
  echo "可纠正 ECC 增量(单卡max): $(cat "$SOAK_DIR/ecc_corrected_delta.txt")"
  echo "不可纠正 ECC 增量      : $(cat "$SOAK_DIR/ecc_uncorrected_delta.txt")"
  echo "XID 增量              : $(cat "$SOAK_DIR/xid_delta.txt")"
  echo "NVLink CRC 增量        : $(cat "$SOAK_DIR/nvlink_crc_delta.txt")"
  echo "采样条数              : $(wc -l < "$SOAK_DIR/samples.csv")"
} | tee "$SOAK_DIR/soak_summary.txt"

log "完成。运行 bash scripts/check_node.sh $PARENT_LOG_DIR 生成含 §8 的判定表。"
