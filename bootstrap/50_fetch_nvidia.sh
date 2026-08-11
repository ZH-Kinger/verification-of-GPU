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
#
# 注意 DCGM：下面抓的 3.3.9 只适用于 H200（profiles/h200_8gpu.env 要求 >=3.3）。
# Blackwell(B300/GB300) 需要 DCGM 4.x —— profiles/b300_8gpu.env 的
# DCGM_MIN_VERSION=4.0 且 DCGM_DEB_GLOB 指向 datacenter-gpu-manager-4*.deb。
# 3.3.9 在 B300 上不识别 GPU，dcgmi diag 会「没测也没报错」，判定脚本会把
# 「JSON 里没有任何 Pass 记录」判成 FAIL 而不是放过 —— 但包本身仍需替换。
# NVIDIA 的 DCGM 4.x 包名带 CUDA 后缀且随版本变化，无法在此写死；
# 取包时请到 CUDA noble 仓库确认实际文件名后加进下表（见文末提示）。
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

# ---------------------------------------------------------------------------
# 逐个 profile 核对：抓到的包能不能满足它的版本要求。
# 不做这一步的话，profile 要求 DCGM 4.x 而 U 盘里躺着 3.3.9 这种不一致
# 会一直藏到现场才暴露。
echo
echo "=== 与各机型 profile 的版本要求核对 ==="
for prof in "$ROOT"/profiles/*.env; do
  [ -f "$prof" ] || continue
  name="$(basename "$prof" .env)"
  need="$(sed -n 's/^DCGM_MIN_VERSION="\([^"]*\)".*/\1/p' "$prof")"
  glob="$(sed -n 's/^DCGM_DEB_GLOB="\([^"]*\)".*/\1/p' "$prof")"
  [ -n "$glob" ] || continue
  # shellcheck disable=SC2086
  if ls $ROOT/downloads/$glob >/dev/null 2>&1; then
    printf '  [OK ] %-12s DCGM >=%-5s 已有匹配包: %s\n' \
      "$name" "$need" "$(basename "$(ls $ROOT/downloads/$glob | head -n1)")"
  else
    printf '  [缺 ] %-12s DCGM >=%-5s 没有匹配 %s 的包\n' "$name" "$need" "$glob"
    MISSING_DCGM=1
  fi
done
if [ "${MISSING_DCGM:-0}" = "1" ]; then
  cat <<'NOTE'

  上面标 [缺] 的机型：U 盘里的 DCGM 版本不满足其 profile 要求。
  Blackwell(B300/GB300) 必须用 DCGM 4.x —— 3.3.9 不识别这块 GPU，
  dcgmi diag 会「跳过所有测试项且不报错」。

  补法：到下面的仓库确认 DCGM 4.x 的实际文件名，连同 sha256 加进本脚本的
  DEBS 表，重跑 bootstrap.sh nvidia：
    https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/
  （筛 datacenter-gpu-manager-4 开头的包）

  在补上之前，B300 机型的 §3 DCGM Level 3/4 两项会判 FAIL 或 SKIP，
  不会被误判成通过。
NOTE
fi
