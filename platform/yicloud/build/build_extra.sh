#!/bin/bash
# 补齐工具：cuda-samples（deviceQuery / p2pBandwidthLatencyTest / bandwidthTest）、
# nccl-tests MPI=1 版 + OpenMPI 运行时、STREAM。产物写到 /out（宿主 build/out）。
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --allow-change-held-packages git cmake libopenmpi-dev openmpi-bin libnccl2 libnccl-dev >/dev/null
mkdir -p /src /out/bin /out/lib /out/mpi && cd /src

# cuda-samples：新版是 CMake + cpp/ 布局，部分 CMakeLists 硬编码含 sm_110 的架构表，统一改成 90;100
git clone -q --depth 1 https://github.com/NVIDIA/cuda-samples.git
cd cuda-samples
grep -rl 'CMAKE_CUDA_ARCHITECTURES' --include=CMakeLists.txt . | xargs sed -i -E 's/set\(CMAKE_CUDA_ARCHITECTURES [^)]*\)/set(CMAKE_CUDA_ARCHITECTURES 90 100)/'
for s in deviceQuery p2pBandwidthLatencyTest bandwidthTest; do
  d=$(find . -type d -name "$s" | head -1)
  [ -n "$d" ] || { echo "MISSING sample $s" >> /out/VERSIONS_extra.txt; continue; }
  cmake -S "$d" -B "/src/build-$s" -DCMAKE_CUDA_ARCHITECTURES="90;100" >/dev/null
  cmake --build "/src/build-$s" -j"$(nproc)" >/dev/null
  find "/src/build-$s" -type f -name "$s" -perm -u+x -exec cp {} /out/bin/ \;
done
echo "cuda-samples $(git rev-parse --short HEAD)" >> /out/VERSIONS_extra.txt
cd /src

# nccl-tests MPI=1：产物改名 *_perf_mpi，与 MPI=0 版并存（项目 nccl_scale.sh 认这个名字）
git clone -q --depth 1 https://github.com/NVIDIA/nccl-tests.git nccl-tests-mpi
make -C nccl-tests-mpi -j"$(nproc)" MPI=1 MPI_HOME=/usr/lib/x86_64-linux-gnu/openmpi \
  NVCC_GENCODE="-gencode=arch=compute_90,code=sm_90 -gencode=arch=compute_100,code=sm_100" >/dev/null
for f in nccl-tests-mpi/build/*_perf; do cp "$f" "/out/bin/$(basename "$f")_mpi"; done
echo "nccl-tests-mpi $(cd nccl-tests-mpi && git rev-parse --short HEAD)" >> /out/VERSIONS_extra.txt

# OpenMPI 运行时整包带走（目标镜像没有 mpirun）：二进制 + 库 + 插件 + help 文件
cp -L /usr/bin/mpirun /usr/bin/orterun /out/mpi/ 2>/dev/null || true
cp -aL /usr/lib/x86_64-linux-gnu/openmpi /out/mpi/lib-openmpi
for l in libmpi.so.40 libopen-rte.so.40 libopen-pal.so.40 libhwloc.so.15 libevent_core-2.1.so.7 libevent_pthreads-2.1.so.7 libpmix.so.2 libudev.so.1 libltdl.so.7; do
  f=$(ls /usr/lib/x86_64-linux-gnu/$l 2>/dev/null || true); [ -n "$f" ] && cp -L "$f" /out/lib/
done
cp -aL /usr/share/openmpi /out/mpi/share-openmpi 2>/dev/null || true
dpkg -l openmpi-bin | awk '/^ii/{print $2, $3}' >> /out/VERSIONS_extra.txt

# STREAM（OpenMP，数组远大于 L3：520MB×2 → 每数组 2^31 个 double = 16GiB）
git clone -q --depth 1 https://github.com/jeffhammond/STREAM.git
gcc -O3 -march=sapphirerapids -fopenmp -mcmodel=large -DSTREAM_ARRAY_SIZE=2147483648 -DNTIMES=10 \
  STREAM/stream.c -o /out/bin/stream
echo "STREAM $(cd STREAM && git rev-parse --short HEAD)" >> /out/VERSIONS_extra.txt
cp -L /usr/lib/x86_64-linux-gnu/libgomp.so.1 /out/lib/

ls -la /out/bin /out/mpi
