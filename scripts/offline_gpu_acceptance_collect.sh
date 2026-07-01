#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LOG_ROOT="${LOG_ROOT:-$BASE_DIR/logs}"
FIELDIAG_BIN="${FIELDIAG_BIN:-$BASE_DIR/tools/fieldiag/fieldiag}"
FIELDIAG_ARGS="${FIELDIAG_ARGS:-}"
FIELDIAG_LOG_ARG="${FIELDIAG_LOG_ARG:-}"
EXPECTED_GPU_COUNT="${EXPECTED_GPU_COUNT:-}"
EXPECTED_GPU_MODEL="${EXPECTED_GPU_MODEL:-}"
RUN_DCGM="${RUN_DCGM:-1}"
RUN_NVBANDWIDTH="${RUN_NVBANDWIDTH:-1}"

mkdir -p "$LOG_ROOT"

ts="$(date +%F_%H%M%S)"
host_sn="$(dmidecode -s system-serial-number 2>/dev/null | tr -dc 'A-Za-z0-9._-' | head -c 64)"
if [ -z "$host_sn" ]; then
  host_sn="$(hostname 2>/dev/null || echo UNKNOWN_HOST)"
fi

LOG_DIR="$LOG_ROOT/${ts}_${host_sn}"
mkdir -p "$LOG_DIR"

run_cmd() {
  local name="$1"
  shift
  echo "[RUN] $name: $*" | tee -a "$LOG_DIR/run.log"
  "$@" > "$LOG_DIR/${name}.txt" 2>&1
  local rc=$?
  echo "$rc" > "$LOG_DIR/${name}.exit"
  echo "[DONE] $name exit=$rc" | tee -a "$LOG_DIR/run.log"
  return 0
}

run_shell() {
  local name="$1"
  local command="$2"
  echo "[RUN] $name: $command" | tee -a "$LOG_DIR/run.log"
  bash -lc "$command" > "$LOG_DIR/${name}.txt" 2>&1
  local rc=$?
  echo "$rc" > "$LOG_DIR/${name}.exit"
  echo "[DONE] $name exit=$rc" | tee -a "$LOG_DIR/run.log"
  return 0
}

write_header() {
  {
    echo "Offline GPU Acceptance Log"
    echo "Timestamp: $ts"
    echo "Host SN: $host_sn"
    echo "Expected GPU Count: ${EXPECTED_GPU_COUNT:-not_set}"
    echo "Expected GPU Model: ${EXPECTED_GPU_MODEL:-not_set}"
    echo "Log Dir: $LOG_DIR"
  } > "$LOG_DIR/session.txt"
}

collect_basic_info() {
  run_cmd uname uname -a
  command -v dmidecode >/dev/null 2>&1 && run_cmd dmidecode_system dmidecode -t system
  command -v lscpu >/dev/null 2>&1 && run_cmd lscpu lscpu
  command -v lspci >/dev/null 2>&1 && run_cmd lspci lspci
  command -v lspci >/dev/null 2>&1 && run_shell gpu_lspci "lspci | grep -i nvidia || true"
}

collect_nvidia_info() {
  if command -v nvidia-smi >/dev/null 2>&1; then
    run_cmd nvidia_smi_L nvidia-smi -L
    run_cmd nvidia_smi_q nvidia-smi -q
    run_cmd nvidia_smi_topo nvidia-smi topo -m
    run_shell nvidia_smi_query "nvidia-smi --query-gpu=index,name,uuid,serial,memory.total,power.limit,pcie.link.gen.current,pcie.link.width.current,temperature.gpu,utilization.gpu --format=csv || true"
    run_shell ecc_summary "nvidia-smi -q | grep -i -A 25 'ECC' || true"
  else
    echo "nvidia-smi not found" > "$LOG_DIR/nvidia_smi_missing.txt"
  fi
}

collect_kernel_logs() {
  command -v dmesg >/dev/null 2>&1 && run_cmd dmesg_full dmesg -T
  command -v dmesg >/dev/null 2>&1 && run_shell dmesg_gpu_error "dmesg -T | egrep -i 'nvrm|xid|ecc|pcie|aer|nvlink|fallen|reset' || true"
  command -v journalctl >/dev/null 2>&1 && run_shell journalctl_gpu_error "journalctl -k --no-pager | egrep -i 'nvrm|xid|ecc|pcie|aer|nvlink|fallen|reset' || true"
}

run_fieldiag() {
  if [ ! -x "$FIELDIAG_BIN" ]; then
    echo "fieldiag not executable or not found: $FIELDIAG_BIN" > "$LOG_DIR/fieldiag_missing.txt"
    return 0
  fi

  local fieldiag_dir
  local fieldiag_name
  fieldiag_dir="$(dirname "$FIELDIAG_BIN")"
  fieldiag_name="$(basename "$FIELDIAG_BIN")"

  local -a extra_args=()
  if [ -n "$FIELDIAG_ARGS" ]; then
    read -r -a extra_args <<< "$FIELDIAG_ARGS"
  fi

  local log_arg="$FIELDIAG_LOG_ARG"
  if [ -z "$log_arg" ]; then
    log_arg="logfilename=$LOG_DIR/fieldiag.log"
  fi

  echo "[RUN] fieldiag from $FIELDIAG_BIN" | tee -a "$LOG_DIR/run.log"
  (
    cd "$fieldiag_dir" || exit 1
    "./$fieldiag_name" "${extra_args[@]}" "$log_arg"
  ) > "$LOG_DIR/fieldiag_stdout.txt" 2>&1
  local rc=$?
  echo "$rc" > "$LOG_DIR/fieldiag.exit"
  echo "[DONE] fieldiag exit=$rc" | tee -a "$LOG_DIR/run.log"
}

run_dcgm() {
  if [ "$RUN_DCGM" != "1" ]; then
    return 0
  fi
  if command -v dcgmi >/dev/null 2>&1; then
    run_cmd dcgm_diag_r3_json dcgmi diag -r 3 -j
  else
    echo "dcgmi not found" > "$LOG_DIR/dcgm_missing.txt"
  fi
}

run_nvbandwidth() {
  if [ "$RUN_NVBANDWIDTH" != "1" ]; then
    return 0
  fi
  if command -v nvbandwidth >/dev/null 2>&1; then
    run_cmd nvbandwidth nvbandwidth
  elif [ -x "$BASE_DIR/tools/nvbandwidth/nvbandwidth" ]; then
    run_cmd nvbandwidth "$BASE_DIR/tools/nvbandwidth/nvbandwidth"
  else
    echo "nvbandwidth not found" > "$LOG_DIR/nvbandwidth_missing.txt"
  fi
}

write_summary() {
  local summary="$LOG_DIR/summary.txt"
  {
    echo "Final manual decision required: PASS / FAIL / RETEST / HOLD"
    echo
    echo "Hard fail keyword scan:"
    grep -RIE "Xid|fallen off|uncorrectable|fatal|FAIL|RETEST|CONFIG|reset" "$LOG_DIR" 2>/dev/null || true
    echo
    echo "Required manual checks:"
    echo "1. Confirm fieldiag result is PASS for every GPU."
    echo "2. Confirm no XID, GPU reset, fallen off bus, uncorrectable ECC, or PCIe fatal error."
    echo "3. Confirm GPU count/model/memory matches purchase list."
    echo "4. Confirm HBM/NVLink/PCIe performance reaches docs/acceptance_criteria.md."
  } > "$summary"
}

main() {
  write_header
  collect_basic_info
  collect_nvidia_info
  collect_kernel_logs
  run_fieldiag
  run_dcgm
  run_nvbandwidth
  collect_kernel_logs
  collect_nvidia_info
  write_summary
  echo "Logs saved to: $LOG_DIR"
}

main "$@"

