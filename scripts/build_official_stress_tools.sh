#!/usr/bin/env bash
set -u

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_DIR="${SOURCE_DIR:-$BASE_DIR/downloads/source}"
BUILD_ROOT="${BUILD_ROOT:-$BASE_DIR/tools/src}"
BIN_DIR="${BIN_DIR:-$BASE_DIR/tools/bin}"
LOG_DIR="${LOG_DIR:-$BASE_DIR/logs/build_stress_tools_$(date +%F_%H%M%S)}"

# Target GPU architectures (H200=90, B300/GB300=100). Semicolon list for CMake,
# also used to build the nccl-tests NVCC_GENCODE flags below.
CUDA_ARCH="${CUDA_ARCH:-90;100}"

mkdir -p "$BUILD_ROOT" "$BIN_DIR" "$LOG_DIR"

run() {
  local name="$1"
  shift
  echo "[RUN] $name: $*" | tee -a "$LOG_DIR/build.log"
  "$@" > "$LOG_DIR/${name}.log" 2>&1
  local rc=$?
  echo "$rc" > "$LOG_DIR/${name}.exit"
  echo "[DONE] $name exit=$rc" | tee -a "$LOG_DIR/build.log"
  return 0
}

need_tool() {
  command -v "$1" >/dev/null 2>&1
}

extract_zip() {
  local zip="$1"
  local marker="$2"
  if [ ! -f "$zip" ]; then
    echo "Missing source zip: $zip" | tee -a "$LOG_DIR/build.log"
    return 1
  fi
  if [ -d "$BUILD_ROOT/$marker" ]; then
    echo "Already extracted: $BUILD_ROOT/$marker" | tee -a "$LOG_DIR/build.log"
    return 0
  fi
  run "unzip_$marker" unzip -q "$zip" -d "$BUILD_ROOT"
}

copy_if_exists() {
  local src="$1"
  local name="$2"
  if [ -x "$src" ]; then
    cp -f "$src" "$BIN_DIR/$name"
    chmod +x "$BIN_DIR/$name"
    echo "Installed $BIN_DIR/$name" | tee -a "$LOG_DIR/build.log"
  fi
}

build_nvbandwidth() {
  # nvbandwidth uses CMake and links Boost::program_options + NVML + cuda driver.
  extract_zip "$SOURCE_DIR/nvbandwidth-main.zip" "nvbandwidth-main" || return 0
  local dir="$BUILD_ROOT/nvbandwidth-main"
  if [ -d "$dir" ]; then
    run nvbandwidth_cmake cmake -S "$dir" -B "$dir/build" \
      -DCMAKE_BUILD_TYPE=Release -DCMAKE_CUDA_ARCHITECTURES="$CUDA_ARCH"
    run nvbandwidth_build cmake --build "$dir/build" -j"$(nproc)"
    copy_if_exists "$dir/build/nvbandwidth" "nvbandwidth"
  fi
}

build_nccl_tests() {
  # nccl-tests uses make. Needs NCCL headers/libs (libnccl-dev) and CUDA.
  extract_zip "$SOURCE_DIR/nccl-tests-master.zip" "nccl-tests-master" || return 0
  local dir="$BUILD_ROOT/nccl-tests-master"
  # Build NVCC_GENCODE from CUDA_ARCH, with PTX of the highest arch for forward compat.
  local gencode="" hi=0 a
  IFS=';' read -r -a _arches <<< "$CUDA_ARCH"
  for a in "${_arches[@]}"; do
    gencode="$gencode -gencode=arch=compute_${a},code=sm_${a}"
    [ "$a" -gt "$hi" ] && hi="$a"
  done
  gencode="$gencode -gencode=arch=compute_${hi},code=compute_${hi}"
  local nccl_home="${NCCL_HOME:-/usr}"
  if [ -d "$dir" ]; then
    (cd "$dir" && run nccl_tests_make make -j"$(nproc)" MPI=0 \
      CUDA_HOME="${CUDA_HOME:-/usr/local/cuda}" NCCL_HOME="$nccl_home" \
      NVCC_GENCODE="$gencode")
    local b
    for b in "$dir"/build/*_perf; do copy_if_exists "$b" "$(basename "$b")"; done
  fi
}

build_cuda_samples() {
  # Newer cuda-samples is CMake-based with a cpp/ layout; bandwidthTest was
  # removed (nvbandwidth replaces it). Build deviceQuery + p2pBandwidthLatencyTest.
  extract_zip "$SOURCE_DIR/cuda-samples-master.zip" "cuda-samples-master" || return 0
  local dir="$BUILD_ROOT/cuda-samples-master"
  local samples=(
    "cpp/1_Utilities/deviceQuery:deviceQuery"
    "cpp/5_Domain_Specific/p2pBandwidthLatencyTest:p2pBandwidthLatencyTest"
  )
  local entry sample name sample_dir
  for entry in "${samples[@]}"; do
    sample="${entry%%:*}"; name="${entry##*:}"
    sample_dir="$dir/$sample"
    if [ -d "$sample_dir" ]; then
      # Some sample CMakeLists hardcode an architecture list containing values
      # this CUDA toolkit may not support (e.g. sm_110); pin to CUDA_ARCH.
      if [ -f "$sample_dir/CMakeLists.txt" ]; then
        sed -i "s/^set(CMAKE_CUDA_ARCHITECTURES .*/set(CMAKE_CUDA_ARCHITECTURES ${CUDA_ARCH//;/ })/" \
          "$sample_dir/CMakeLists.txt"
      fi
      run "cuda_sample_${name}_cmake" cmake -S "$sample_dir" -B "$sample_dir/build" \
        -DCMAKE_CUDA_ARCHITECTURES="$CUDA_ARCH"
      run "cuda_sample_${name}_build" cmake --build "$sample_dir/build" -j"$(nproc)"
      local found
      found="$(find "$sample_dir/build" -maxdepth 2 -type f -name "$name" -executable 2>/dev/null | head -1)"
      [ -n "$found" ] && copy_if_exists "$found" "$name"
    else
      echo "CUDA sample path not found: $sample_dir" | tee -a "$LOG_DIR/build.log"
    fi
  done
}

main() {
  {
    echo "Official stress tool build"
    echo "Base dir: $BASE_DIR"
    echo "Source dir: $SOURCE_DIR"
    echo "Build root: $BUILD_ROOT"
    echo "Bin dir: $BIN_DIR"
    echo "Log dir: $LOG_DIR"
  } > "$LOG_DIR/session.txt"

  if ! need_tool unzip; then
    echo "Missing unzip; cannot extract source zips." | tee -a "$LOG_DIR/build.log"
    exit 0
  fi

  if ! need_tool make; then
    echo "Missing make; source tools cannot be built in this environment." | tee -a "$LOG_DIR/build.log"
    exit 0
  fi

  if ! need_tool cmake; then
    echo "Missing cmake; nvbandwidth and cuda-samples need it. Install downloads/offline_deb_noble/rebuild/*.deb first." | tee -a "$LOG_DIR/build.log"
  fi

  if ! need_tool nvcc; then
    echo "Missing nvcc; install downloads/offline_deb_noble/rebuild/*.deb (offline) then re-run." | tee -a "$LOG_DIR/build.log"
    echo "Note: precompiled binaries already ship in tools/bin/; building from source is only a fallback." | tee -a "$LOG_DIR/build.log"
  fi

  build_nvbandwidth
  build_nccl_tests
  build_cuda_samples

  echo "Build logs saved to: $LOG_DIR"
  echo "Built binaries, if any, are in: $BIN_DIR"
}

main "$@"

