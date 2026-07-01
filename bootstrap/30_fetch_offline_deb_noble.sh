#!/usr/bin/env bash
# Rebuild downloads/offline_deb_noble/ (runtime/ + rebuild/) for the Ubuntu 24.04
# (noble) TARGET, using a throwaway ubuntu:24.04 container so versions/closure match
# the target regardless of this host's distro. Requires docker + network.
#
# Produces:
#   runtime/  cuda-cudart-12-8 + libnccl2 2.30.7+cuda12.9 (+ config-common)
#   rebuild/  full offline recompile toolchain closure (nvcc/cmake/build-essential/
#             boost/unzip/nccl dev), installable offline on a bare noble system.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/downloads/offline_deb_noble"
mkdir -p "$OUT/runtime" "$OUT/rebuild"
command -v docker >/dev/null 2>&1 || { echo "docker required"; exit 1; }

NCCL_VER="2.30.7-1+cuda12.9"   # >=2.30 needed by nccl-tests master; +cuda12.9 keeps libcudart.so.12

docker run --rm -v "$OUT":/out ubuntu:24.04 bash -euc '
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq curl ca-certificates >/dev/null
  curl -fsSL https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb -o /tmp/k.deb
  dpkg -i /tmp/k.deb >/dev/null
  apt-get update -qq

  # --- runtime/ ---
  rm -f /out/runtime/*.deb
  apt-get install -y --download-only -o Dir::Cache::archives=/out/runtime \
    cuda-cudart-12-8 libnccl2='"$NCCL_VER"' >/dev/null
  find /out/runtime -name "*.deb" -exec mv -f {} /out/runtime/ \; 2>/dev/null || true
  rm -rf /out/runtime/partial

  # --- rebuild/ : full recursive closure so it installs on a bare noble target ---
  rm -f /out/rebuild/*.deb
  TARGETS="cuda-nvcc-12-8 cuda-cudart-dev-12-8 cuda-nvml-dev-12-8 cuda-nvrtc-dev-12-8 \
           build-essential cmake libboost-program-options-dev unzip"
  CLOSURE=$(apt-cache depends --recurse --no-recommends --no-suggests --no-conflicts \
            --no-breaks --no-replaces --no-enhances $TARGETS | grep "^[a-zA-Z0-9]" | sort -u)
  cd /out/rebuild
  for p in $CLOSURE; do apt-get download "$p" >/dev/null 2>&1 || true; done
  # nccl (pinned, excluded from recurse to avoid cuda12.9/13.3 conflict)
  apt-get download libnccl2='"$NCCL_VER"' libnccl-dev='"$NCCL_VER"' >/dev/null 2>&1 || true

  echo "runtime debs: $(ls /out/runtime/*.deb | wc -l)"
  echo "rebuild debs: $(ls /out/rebuild/*.deb | wc -l)"
'

# refresh manifest
{ echo "# offline_deb_noble SHA256 manifest"; echo "# runtime/"; (cd "$OUT/runtime" && sha256sum *.deb);
  echo "# rebuild/ ($(ls "$OUT"/rebuild/*.deb | wc -l) packages)"; (cd "$OUT/rebuild" && sha256sum *.deb); } \
  > "$OUT/MANIFEST.sha256"
echo "Done. Wrote $OUT/{runtime,rebuild} and MANIFEST.sha256"
