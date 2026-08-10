#!/usr/bin/env bash
set -u

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_DIR="${SOURCE_DIR:-$BASE_DIR/downloads/source}"
BUILD_ROOT="${BUILD_ROOT:-$BASE_DIR/tools/src}"
LOG_DIR="${LOG_DIR:-$BASE_DIR/logs/build_stress_tools_$(date +%F_%H%M%S)}"

# 架构与输出目录优先从 profile 取（PROFILE=b300_8gpu 会给出 "90;100;103" 和
# tools/bin_cuda13_sm90-100-103），显式的 CUDA_ARCH / BIN_DIR 仍然覆盖它。
# 不同机型的 CUDA 线不能混用同一个输出目录：libcudart 主版本必须和二进制一致。
if [ -n "${PROFILE:-}" ] && [ -f "$BASE_DIR/scripts/lib/common.sh" ]; then
  # shellcheck disable=SC1091
  . "$BASE_DIR/scripts/lib/common.sh"
  if load_profile "$PROFILE" 2>/dev/null; then
    CUDA_ARCH="${CUDA_ARCH:-$CUDA_ARCH_LIST}"
    BIN_DIR="${BIN_DIR:-$BASE_DIR/tools/${TOOLS_BIN_SUBDIR:-bin}}"
    echo "[build] profile=$PROFILE arch=$CUDA_ARCH bin_dir=$BIN_DIR"
  fi
fi

BIN_DIR="${BIN_DIR:-$BASE_DIR/tools/bin}"
# Target GPU architectures (H200=90, B300=100, Blackwell Ultra=103). Semicolon list
# for CMake, also used to build the nccl-tests NVCC_GENCODE flags below.
CUDA_ARCH="${CUDA_ARCH:-90;100}"

# MPI 版 nccl-tests 用的 MPI 安装路径（Ubuntu 的 openmpi 默认位置）
MPI_HOME="${MPI_HOME:-/usr/lib/x86_64-linux-gnu/openmpi}"

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

build_nccl_tests_mpi() {
  # 跨节点（《验收标准》§6）需要 MPI 版。upstream 的 MPI=1 产出文件名和 MPI=0
  # 相同，会互相覆盖，所以在独立目录里编，并按标准的命名加 _mpi 后缀。
  local src="$BUILD_ROOT/nccl-tests-master"
  local dir="$BUILD_ROOT/nccl-tests-mpi"
  [ -d "$src" ] || { echo "nccl-tests source not extracted; skip MPI build" | tee -a "$LOG_DIR/build.log"; return 0; }
  if ! need_tool mpicc && [ ! -x "$MPI_HOME/bin/mpicc" ]; then
    echo "No MPI toolchain (mpicc / $MPI_HOME/bin/mpicc); skipping *_perf_mpi." | tee -a "$LOG_DIR/build.log"
    echo "  Install openmpi (see docs/tooling_gaps.md) — §6 全部测试项依赖它。" | tee -a "$LOG_DIR/build.log"
    return 0
  fi
  [ -d "$dir" ] || cp -a "$src" "$dir"

  local gencode="" hi=0 a
  IFS=';' read -r -a _arches <<< "$CUDA_ARCH"
  for a in "${_arches[@]}"; do
    gencode="$gencode -gencode=arch=compute_${a},code=sm_${a}"
    [ "$a" -gt "$hi" ] && hi="$a"
  done
  gencode="$gencode -gencode=arch=compute_${hi},code=compute_${hi}"

  (cd "$dir" && run nccl_tests_mpi_make make -j"$(nproc)" MPI=1 MPI_HOME="$MPI_HOME" \
    CUDA_HOME="${CUDA_HOME:-/usr/local/cuda}" NCCL_HOME="${NCCL_HOME:-/usr}" \
    NVCC_GENCODE="$gencode")
  local b
  for b in "$dir"/build/*_perf; do
    [ -x "$b" ] && copy_if_exists "$b" "$(basename "$b")_mpi"
  done
}

build_gpu_burn() {
  # 《验收标准》§3 的 1 小时压测和 §8 的长稳烤机都以 gpu_burn 为准。
  # 注意两点：
  #   1. 运行时需要同目录的 compare.ptx（PTX 在运行时 JIT，所以对新架构天然兼容），
  #      两个文件必须一起拷贝；采集脚本已经会 cd 到二进制所在目录再执行。
  #   2. gpu-burn 链接 cublas —— 目标机的离线 runtime deb 必须包含 libcublas，
  #      这是本项目原先"不打包 cublas"决定的一个例外。
  extract_zip "$SOURCE_DIR/gpu-burn-master.zip" "gpu-burn-master" || return 0
  local dir="$BUILD_ROOT/gpu-burn-master"
  [ -d "$dir" ] || return 0

  # gpu-burn 的 COMPUTE 只接受单个架构；取列表里最高的那个，PTX 负责向下/向上兼容。
  local hi=0 a
  IFS=';' read -r -a _arches <<< "$CUDA_ARCH"
  for a in "${_arches[@]}"; do [ "$a" -gt "$hi" ] && hi="$a"; done

  (cd "$dir" && run gpu_burn_make make COMPUTE="$hi" CUDAPATH="${CUDA_HOME:-/usr/local/cuda}")
  copy_if_exists "$dir/gpu_burn" "gpu_burn"
  if [ -f "$dir/compare.ptx" ]; then
    cp -f "$dir/compare.ptx" "$BIN_DIR/compare.ptx"
    echo "Installed $BIN_DIR/compare.ptx (gpu_burn 运行时依赖)" | tee -a "$LOG_DIR/build.log"
  fi
}

build_bandwidth_test() {
  # §7 点名要 bandwidthTest，但新版 cuda-samples 已删除它，只能从旧版取。
  # 旧版是 Makefile 布局（SMS 变量），不是 CMake。
  extract_zip "$SOURCE_DIR/cuda-samples-v12.3.zip" "cuda-samples-12.3" || return 0
  local dir="$BUILD_ROOT/cuda-samples-12.3/Samples/1_Utilities/bandwidthTest"
  if [ ! -d "$dir" ]; then
    echo "bandwidthTest path not found in legacy cuda-samples" | tee -a "$LOG_DIR/build.log"
    return 0
  fi
  (cd "$dir" && run bandwidthTest_make make SMS="${CUDA_ARCH//;/ }" \
    CUDA_PATH="${CUDA_HOME:-/usr/local/cuda}")
  copy_if_exists "$dir/bandwidthTest" "bandwidthTest"
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
  build_nccl_tests_mpi
  build_cuda_samples
  build_bandwidth_test
  build_gpu_burn

  echo "Build logs saved to: $LOG_DIR"
  echo "Built binaries, if any, are in: $BIN_DIR"

  # 按《验收标准》需要的工具核对产出，缺什么直接点名到章节
  echo
  echo "=== 产出核对（对照《验收标准》）==="
  check_out() {
    if [ -x "$BIN_DIR/$1" ]; then printf '  [有] %-26s %s\n' "$1" "$2"
    else printf '  [缺] %-26s %s\n' "$1" "$2"; fi
  }
  check_out nvbandwidth              "§3 H2D/D2H, §4 D2D"
  check_out p2pBandwidthLatencyTest  "§4 P2P 带宽矩阵与延迟"
  check_out deviceQuery              "预检：确认计算能力"
  check_out bandwidthTest            "§7 cuda-samples 工具集"
  check_out gpu_burn                 "§3 1 小时压测, §8 长稳烤机"
  check_out all_reduce_perf          "§4 节点内 AllReduce"
  check_out all_gather_perf          "§4 节点内 AllGather"
  check_out all_reduce_perf_mpi      "§6 跨节点 NCCL"
  [ -f "$BIN_DIR/compare.ptx" ] && echo "  [有] compare.ptx                gpu_burn 运行时依赖" \
    || echo "  [缺] compare.ptx                gpu_burn 没有它跑不起来"
}

main "$@"

