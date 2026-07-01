#!/usr/bin/env bash
# Install the offline CUDA runtime + NCCL needed to RUN the precompiled
# stress-tool binaries in tools/bin/ on the target machine (Ubuntu 24.04 noble).
#
# This does NOT install the NVIDIA driver. Install the driver first
# (scripts/install_offline_nvidia_tools.sh, or the dcgm-mode runfile), because
# the driver provides libcuda.so.1 / libnvidia-ml.so.1.
#
# After the driver, this script installs:
#   - cuda-cudart-12-8        -> libcudart.so.12   (nccl-tests, deviceQuery, p2p)
#   - libnccl2 2.30.7+cuda12.9 -> libnccl.so.2      (nccl-tests)
# and registers the cudart library path with the dynamic linker.
#
# Usage:
#   sudo bash scripts/install_offline_cuda_runtime.sh

set -u

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEB_DIR="${DEB_DIR:-$BASE_DIR/downloads/offline_deb_noble/runtime}"

if [ "$(id -u)" -ne 0 ]; then
  echo "Please run as root: sudo bash scripts/install_offline_cuda_runtime.sh"
  exit 1
fi

if [ ! -d "$DEB_DIR" ]; then
  echo "Offline deb directory not found: $DEB_DIR"
  exit 1
fi

shopt -s nullglob
debs=("$DEB_DIR"/*.deb)
if [ "${#debs[@]}" -eq 0 ]; then
  echo "No .deb packages found in $DEB_DIR"
  exit 1
fi

echo "Installing offline CUDA runtime + NCCL from: $DEB_DIR"
dpkg -i "${debs[@]}"
rc=$?

# Make libcudart.so.12 discoverable by the dynamic linker.
cudart_dir="$(dirname "$(find /usr/local -name 'libcudart.so.12*' 2>/dev/null | head -n1)")"
if [ -n "$cudart_dir" ] && [ -d "$cudart_dir" ]; then
  echo "$cudart_dir" > /etc/ld.so.conf.d/cuda-acceptance.conf
  echo "Registered cudart path: $cudart_dir"
fi
ldconfig

echo
echo "dpkg exit=$rc"
echo "Verify with:"
echo "  ldd $BASE_DIR/tools/bin/all_reduce_perf   # only libcuda.so.1 should require the driver"
echo "  $BASE_DIR/tools/bin/deviceQuery"
