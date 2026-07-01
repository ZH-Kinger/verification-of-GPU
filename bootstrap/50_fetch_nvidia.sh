#!/usr/bin/env bash
# Fetch the NVIDIA driver runfile + DCGM + Fabric Manager + cuda-compat + keyring
# into downloads/nvidia/ (these install on the TARGET in dcgm mode).
#
# The .deb packages come from the NVIDIA CUDA noble repo (by exact filename). The
# driver .run is served from NVIDIA's driver host, whose URL varies by version, so
# supply it via DRIVER_URL or drop the file in manually. SHA256s from the original
# DOWNLOAD_MANIFEST.txt are checked when present.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$ROOT/downloads/nvidia"
mkdir -p "$DEST"
REPO="https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64"

# filename  expected-sha256 (from DOWNLOAD_MANIFEST.txt)
declare -A DEBS=(
  [cuda-keyring_1.1-1_all.deb]="d2a6b11c096396d868758b86dab1823b25e14d70333f1dfa74da5ddaf6a06dba"
  [cuda-compat-13-3_610.43.02-1ubuntu1_amd64.deb]="4d3b3bfe6e6a53b2153383b2f74f139339c7e5ffbf657d6af7c3967b8b670386"
  [nvidia-fabricmanager_610.43.02-1ubuntu1_amd64.deb]="9f1513ff01dbee903dd896b1748eca11645f4a790c0ec15374749e27a37519e4"
  [datacenter-gpu-manager_3.3.9_amd64.deb]="4bf3a081e24603bc995a8aa041ff7819df60563da3e1f7887dae366baed6d45c"
  [datacenter-gpu-manager-exporter_4.8.2-1_amd64.deb]="6913787efb8613f656cd2c0a239390e3a8e2b903b59c2c671522f9989a8d5a56"
)

verify() { # file sha
  [ -n "$2" ] || return 0
  local got; got="$(sha256sum "$1" | awk '{print $1}')"
  [ "$got" = "$2" ] && echo "  sha256 OK" || { echo "  sha256 MISMATCH (got $got)"; return 1; }
}

for f in "${!DEBS[@]}"; do
  if [ -s "$DEST/$f" ]; then echo "[skip] $f"; continue; fi
  echo "[get ] $f"
  if curl -fL --retry 3 -o "$DEST/$f" "$REPO/$f"; then verify "$DEST/$f" "${DEBS[$f]}" || true
  else echo "  NOT FOUND at $REPO/$f — repo may have rotated this version; fetch manually."; rm -f "$DEST/$f"; fi
done

# Driver runfile
RUN="NVIDIA-Linux-x86_64-610.43.02.run"
RUN_SHA="3034a054bb4cdf7752ff8dc272564cb105513804bff53538945901b16ca77463"
if [ -s "$DEST/$RUN" ]; then
  echo "[skip] $RUN"
elif [ -n "${DRIVER_URL:-}" ]; then
  echo "[get ] $RUN from DRIVER_URL"
  curl -fL --retry 3 -o "$DEST/$RUN" "$DRIVER_URL" && verify "$DEST/$RUN" "$RUN_SHA" || true
else
  echo "NOTE: $RUN not fetched. Set DRIVER_URL=<url to the .run> and re-run, or copy the"
  echo "      file into $DEST manually. Expected sha256: $RUN_SHA"
fi

echo "downloads/nvidia:"; ls -la "$DEST"
