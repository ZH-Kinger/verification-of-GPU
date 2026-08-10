#!/usr/bin/env bash
# One-command offline GPU acceptance orchestrator.
#
# Wraps the existing helper scripts into a single entry point for field use.
#
# Usage:
#   sudo bash scripts/run_acceptance.sh [fieldiag|dcgm|standard|soak] [profile]
#
# 验收分两个阶段：阶段一 fieldiag（硬件主标准），阶段二 standard（甲方《验收标准》表）。
#
# Modes:
#   fieldiag (default)
#       阶段一。Hardware-first acceptance. Assumes the machine was booted into
#       the "fieldiag mode, NVIDIA driver blocked" grub entry. Runs fieldiag and
#       collects logs. Driver-dependent tools (DCGM, nvbandwidth) are skipped
#       because the NVIDIA driver is intentionally not loaded.
#
#   dcgm
#       Legacy 驱动模式采集（v1.0 流程）。Installs the offline NVIDIA
#       driver/DCGM/Fabric Manager packages, best-effort builds the official
#       stress-tool sources, then collects logs with DCGM and nvbandwidth
#       enabled. fieldiag is skipped in this mode.
#
#   standard
#       阶段二，单机离线压测。需先从 grub 选 dcgm 模式（驱动已加载）。
#       依次执行 preflight.sh → collect_node.sh → check_node.sh，
#       按 profiles/<profile>.env 的阈值输出 PASS/FAIL 判定表。
#
#   soak
#       阶段二的长稳烤机（§8）。用法：
#         sudo bash scripts/run_acceptance.sh soak <log_dir> [profile]
#       跑完自动重新判定，把 §8 的结果并入同一张表。
#
# profile: b300_8gpu（默认）或 h200_8gpu。不同机型的显存/功耗/带宽阈值和
#          驱动/CUDA/NCCL/DCGM 版本要求都不同，全部由 profile 决定。
#
# Both modes write a timestamped log directory under logs/ and drop a
# pre-filled final_result.txt skeleton into that directory.
#
# Useful environment overrides (passed through to the wrapped scripts):
#   FIELDIAG_BIN          path to the fieldiag executable (default tools/fieldiag/fieldiag)
#   FIELDIAG_ARGS         extra fieldiag arguments
#   EXPECTED_GPU_COUNT    expected GPU count, recorded in the log header
#   EXPECTED_GPU_MODEL    expected GPU model, recorded in the log header
#   SKIP_INSTALL=1        (dcgm mode) skip offline NVIDIA tool installation
#   SKIP_BUILD=1          (dcgm mode) skip building stress-tool sources

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

MODE="${1:-${MODE:-fieldiag}}"

case "$MODE" in
  fieldiag|dcgm|standard|soak) ;;
  -h|--help)
    awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "${BASH_SOURCE[0]}"
    exit 0
    ;;
  *)
    echo "Unknown mode: $MODE"
    echo "Usage: sudo bash scripts/run_acceptance.sh [fieldiag|dcgm|standard|soak] [profile]"
    exit 2
    ;;
esac

log() { echo "[run_acceptance] $*"; }

if [ "$(id -u)" -ne 0 ]; then
  log "WARNING: not running as root. fieldiag, DCGM, dmidecode and dmesg need root."
  log "Re-run with: sudo bash scripts/run_acceptance.sh $MODE"
fi

log "Base dir: $BASE_DIR"
log "Mode: $MODE"

run_collect() {
  # Run collection, stream output live, and capture it so we can locate the
  # log directory it created. Stream to the terminal only when one exists.
  local out
  if [ -t 1 ]; then
    out="$(bash "$SCRIPT_DIR/offline_gpu_acceptance_collect.sh" 2>&1 | tee /dev/tty)"
  else
    out="$(bash "$SCRIPT_DIR/offline_gpu_acceptance_collect.sh" 2>&1)"
    printf '%s\n' "$out"
  fi
  LAST_LOG_DIR="$(printf '%s\n' "$out" | sed -n 's/^Logs saved to: //p' | tail -n 1)"
}

case "$MODE" in
  fieldiag)
    if [ ! -x "${FIELDIAG_BIN:-$BASE_DIR/tools/fieldiag/fieldiag}" ]; then
      log "NOTE: fieldiag binary not found/executable at ${FIELDIAG_BIN:-$BASE_DIR/tools/fieldiag/fieldiag}"
      log "      Copy it into tools/fieldiag/ or set FIELDIAG_BIN=/path/to/binary."
      log "      Continuing; collection will record fieldiag as missing."
    fi
    # Driver is expected to be blocked by the grub entry; skip driver-only tools.
    export RUN_DCGM="${RUN_DCGM:-0}"
    export RUN_NVBANDWIDTH="${RUN_NVBANDWIDTH:-0}"
    run_collect
    ;;

  dcgm)
    if [ "${SKIP_INSTALL:-0}" != "1" ]; then
      log "Installing offline NVIDIA tools..."
      bash "$SCRIPT_DIR/install_offline_nvidia_tools.sh" || log "offline tool install reported an error; continuing."
    else
      log "SKIP_INSTALL=1; skipping offline NVIDIA tool installation."
    fi

    if [ "${SKIP_BUILD:-0}" != "1" ]; then
      log "Building official stress-tool sources (best-effort)..."
      bash "$SCRIPT_DIR/build_official_stress_tools.sh" || log "stress-tool build reported an error; continuing."
    else
      log "SKIP_BUILD=1; skipping stress-tool build."
    fi

    # In dcgm mode the driver is loaded; do not run fieldiag.
    export FIELDIAG_BIN="${FIELDIAG_BIN:-/nonexistent/fieldiag-skipped-in-dcgm-mode}"
    export RUN_DCGM="${RUN_DCGM:-1}"
    export RUN_NVBANDWIDTH="${RUN_NVBANDWIDTH:-1}"
    run_collect
    ;;

  standard)
    # 阶段二：按甲方《验收标准》表逐项采集并自动判定（单机离线压测）。
    PROFILE_NAME_ARG="${2:-${PROFILE:-b300_8gpu}}"
    log "阶段二 — 单机离线压测，profile=$PROFILE_NAME_ARG"

    log "1/3 环境预检"
    if ! bash "$SCRIPT_DIR/preflight.sh" "$PROFILE_NAME_ARG"; then
      log "预检存在阻断项。修复后重跑；如确认要带着问题继续，用 FORCE=1。"
      [ "${FORCE:-0}" != "1" ] && exit 1
      log "FORCE=1，继续。"
    fi

    log "2/3 采集 §1-§4 §7"
    out="$(bash "$SCRIPT_DIR/collect_node.sh" "$PROFILE_NAME_ARG" 2>&1 | tee /dev/stderr)"
    LAST_LOG_DIR="$(printf '%s\n' "$out" | sed -n 's/^Logs saved to: //p' | tail -n 1)"

    if [ -z "${LAST_LOG_DIR:-}" ] || [ ! -d "$LAST_LOG_DIR" ]; then
      log "未能确定日志目录，检查 logs/。"
      exit 1
    fi

    log "3/3 判定"
    bash "$SCRIPT_DIR/check_node.sh" "$LAST_LOG_DIR" "$PROFILE_NAME_ARG" || true
    log "长稳烤机（§8）单独执行："
    log "  sudo bash scripts/run_acceptance.sh soak $LAST_LOG_DIR $PROFILE_NAME_ARG"
    ;;

  soak)
    SOAK_TARGET="${2:-}"
    PROFILE_NAME_ARG="${3:-${PROFILE:-b300_8gpu}}"
    if [ -z "$SOAK_TARGET" ] || [ ! -d "$SOAK_TARGET" ]; then
      log "用法: sudo bash scripts/run_acceptance.sh soak <log_dir> [profile]"
      log "      <log_dir> 用 standard 模式生成的那个目录。"
      exit 2
    fi
    bash "$SCRIPT_DIR/soak_node.sh" "$SOAK_TARGET" "$PROFILE_NAME_ARG"
    log "重新判定（并入 §8 结果）"
    bash "$SCRIPT_DIR/check_node.sh" "$SOAK_TARGET" "$PROFILE_NAME_ARG" || true
    LAST_LOG_DIR="$SOAK_TARGET"
    ;;
esac

if [ -n "${LAST_LOG_DIR:-}" ] && [ -d "$LAST_LOG_DIR" ]; then
  result_file="$LAST_LOG_DIR/final_result.txt"
  if [ -f "$BASE_DIR/templates/final_result_template.txt" ]; then
    cp -f "$BASE_DIR/templates/final_result_template.txt" "$result_file"
    # Fill the existing empty "日志目录：" field instead of appending a duplicate.
    sed -i "0,/^日志目录：/s##日志目录：$LAST_LOG_DIR#" "$result_file"
    {
      echo
      echo "# Auto-filled by run_acceptance.sh (mode: $MODE)"
    } >> "$result_file"
    log "Final result skeleton: $result_file"
  fi
  log "Review logs and fill in PASS/FAIL/RETEST/HOLD per docs/acceptance_criteria.md."
else
  log "Could not determine the collection log directory; check logs/ manually."
fi

log "Done (mode: $MODE)."
