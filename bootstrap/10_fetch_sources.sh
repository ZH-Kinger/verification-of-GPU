#!/usr/bin/env bash
# Fetch the official stress-tool SOURCE zips into downloads/source/.
# These are the exact upstream archives used to build tools/bin/.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$ROOT/downloads/source"
mkdir -p "$DEST"

fetch() { # url outfile
  local url="$1" out="$2"
  if [ -s "$DEST/$out" ]; then echo "[skip] $out already present"; return; fi
  echo "[get ] $out"
  curl -fL --retry 3 -o "$DEST/$out" "$url"
}

fetch "https://github.com/NVIDIA/nvbandwidth/archive/refs/heads/main.zip"    "nvbandwidth-main.zip"
fetch "https://github.com/NVIDIA/nccl-tests/archive/refs/heads/master.zip"   "nccl-tests-master.zip"
fetch "https://github.com/NVIDIA/cuda-samples/archive/refs/heads/master.zip" "cuda-samples-master.zip"

echo "Sources in $DEST:"
ls -la "$DEST"/*.zip
