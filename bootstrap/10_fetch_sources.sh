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

# 《验收标准》新增要求的两个来源：
# gpu-burn —— §3 的 1 小时压测和 §8 的长稳烤机都点名用它，项目原先没有。
fetch "https://github.com/wilicc/gpu-burn/archive/refs/heads/master.zip"     "gpu-burn-master.zip"
# 旧版 cuda-samples —— §7 点名要 bandwidthTest，新版 master 已经删除了它。
fetch "https://github.com/NVIDIA/cuda-samples/archive/refs/tags/v12.3.zip"   "cuda-samples-v12.3.zip"

echo "Sources in $DEST:"
ls -la "$DEST"/*.zip
