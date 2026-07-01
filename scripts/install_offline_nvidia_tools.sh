#!/usr/bin/env bash
set -u

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-$BASE_DIR/downloads/nvidia}"
LOG_DIR="${LOG_DIR:-$BASE_DIR/logs/offline_tool_install_$(date +%F_%H%M%S)}"
DRIVER_RUNFILE="${DRIVER_RUNFILE:-$DOWNLOAD_DIR/NVIDIA-Linux-x86_64-610.43.02.run}"

mkdir -p "$LOG_DIR"

run() {
  local name="$1"
  shift
  echo "[RUN] $name: $*" | tee -a "$LOG_DIR/install.log"
  "$@" > "$LOG_DIR/${name}.log" 2>&1
  local rc=$?
  echo "$rc" > "$LOG_DIR/${name}.exit"
  echo "[DONE] $name exit=$rc" | tee -a "$LOG_DIR/install.log"
  return 0
}

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "Please run as root: sudo bash scripts/install_offline_nvidia_tools.sh"
    exit 1
  fi
}

install_debs_if_present() {
  local debs=(
    "$DOWNLOAD_DIR/cuda-keyring_1.1-1_all.deb"
    "$DOWNLOAD_DIR/cuda-compat-13-3_610.43.02-1ubuntu1_amd64.deb"
    "$DOWNLOAD_DIR/nvidia-fabricmanager_610.43.02-1ubuntu1_amd64.deb"
    "$DOWNLOAD_DIR/datacenter-gpu-manager_3.3.9_amd64.deb"
    "$DOWNLOAD_DIR/datacenter-gpu-manager-exporter_4.8.2-1_amd64.deb"
  )

  local existing=()
  for deb in "${debs[@]}"; do
    if [ -f "$deb" ]; then
      existing+=("$deb")
    fi
  done

  if [ "${#existing[@]}" -gt 0 ]; then
    run dpkg_install dpkg -i "${existing[@]}"
  else
    echo "No offline NVIDIA deb packages found in $DOWNLOAD_DIR" | tee -a "$LOG_DIR/install.log"
  fi
}

install_driver_if_present() {
  if [ ! -f "$DRIVER_RUNFILE" ]; then
    echo "Driver runfile not found: $DRIVER_RUNFILE" | tee -a "$LOG_DIR/install.log"
    return 0
  fi

  chmod +x "$DRIVER_RUNFILE" || true
  run nvidia_driver_runfile "$DRIVER_RUNFILE" --silent --dkms --no-questions
}

post_checks() {
  command -v nvidia-smi >/dev/null 2>&1 && run nvidia_smi nvidia-smi
  command -v dcgmi >/dev/null 2>&1 && run dcgmi_discovery dcgmi discovery -l
  command -v systemctl >/dev/null 2>&1 && run fabricmanager_status systemctl status nvidia-fabricmanager --no-pager
}

main() {
  need_root
  {
    echo "Offline NVIDIA tool install"
    echo "Base dir: $BASE_DIR"
    echo "Download dir: $DOWNLOAD_DIR"
    echo "Log dir: $LOG_DIR"
    echo "Kernel: $(uname -a)"
  } > "$LOG_DIR/session.txt"

  install_driver_if_present
  install_debs_if_present
  post_checks

  echo "Logs saved to: $LOG_DIR"
  echo "If dpkg reports missing dependencies, install the missing Ubuntu packages into the USB image before field use."
}

main "$@"

