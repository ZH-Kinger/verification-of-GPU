#!/usr/bin/env bash
# Compile the stress binaries into tools/bin/ ON THE WORKSHOP HOST (needs network
# once, to install the CUDA/NCCL/build toolchain). Targets sm_90 + sm_100 by default.
#
# Requires: an NVIDIA CUDA toolkit providing nvcc that supports sm_100 (CUDA >= 12.8).
# If nvcc is absent this script installs cuda-toolkit via the distro's NVIDIA repo
# only when RUN_APT=1; otherwise it just reports what is missing.
#
# Env:
#   CUDA_ARCH   default "90;100"    (H200 + B300/GB300)
#   CUDA_HOME   default /usr/local/cuda
#   RUN_APT=1   allow apt installs of build deps on this host
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export CUDA_ARCH="${CUDA_ARCH:-90;100}"
export CUDA_HOME="${CUDA_HOME:-/usr/local/cuda}"
export PATH="$CUDA_HOME/bin:$PATH"

need_src() {
  [ -s "$ROOT/downloads/source/nvbandwidth-main.zip" ] || {
    echo "Missing source zips. Run bootstrap/10_fetch_sources.sh first."; exit 1; }
}

ensure_host_deps() {
  local missing=()
  command -v nvcc  >/dev/null 2>&1 || missing+=("nvcc(cuda-toolkit>=12.8)")
  command -v cmake >/dev/null 2>&1 || missing+=("cmake")
  command -v make  >/dev/null 2>&1 || missing+=("build-essential")
  [ -f /usr/include/nccl.h ]       || missing+=("libnccl-dev")
  ls /usr/lib/*/libboost_program_options* >/dev/null 2>&1 || missing+=("libboost-program-options-dev")

  if [ "${#missing[@]}" -eq 0 ]; then echo "Host build deps present."; return; fi
  echo "Missing host build deps: ${missing[*]}"
  if [ "${RUN_APT:-0}" != "1" ]; then
    echo "Re-run with RUN_APT=1 to apt-install cmake/build-essential/libnccl-dev/boost."
    echo "For nvcc: install an NVIDIA CUDA toolkit >= 12.8 (adds sm_100 support)."
    [ -x "$CUDA_HOME/bin/nvcc" ] || exit 1
  else
    sudo apt-get update -qq
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
      cmake build-essential libnccl-dev libnccl2 libboost-program-options-dev unzip
    command -v nvcc >/dev/null 2>&1 || {
      echo "nvcc still missing — install CUDA toolkit >= 12.8 manually, then re-run."; exit 1; }
  fi
}

need_src
ensure_host_deps

# Reuse the in-repo builder (handles cmake / new cuda-samples cpp layout / sm_110 patch /
# nccl-tests NVCC_GENCODE). It reads downloads/source and writes tools/bin.
echo "Building with CUDA_ARCH=$CUDA_ARCH ..."
CUDA_ARCH="$CUDA_ARCH" CUDA_HOME="$CUDA_HOME" NCCL_HOME="${NCCL_HOME:-/usr}" \
  bash "$ROOT/scripts/build_official_stress_tools.sh"

echo "=== tools/bin ==="
ls -la "$ROOT/tools/bin" 2>/dev/null | grep -vE 'MANIFEST|^total|^d' || true
( cd "$ROOT/tools/bin" && sha256sum ./* 2>/dev/null > ../bin_MANIFEST.sha256 ) || true
echo "Updated tools/bin_MANIFEST.sha256"
