#!/bin/bash
# 在 nvidia/cuda:12.9.1-devel-ubuntu22.04 容器内执行，产物写到 /out（挂载自宿主 build/out）
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --allow-change-held-packages git cmake libboost-program-options-dev libnccl2 libnccl-dev perftest rdma-core ibverbs-utils fio stressapptest numactl >/dev/null
ARCH_GENCODE="-gencode=arch=compute_90,code=sm_90 -gencode=arch=compute_100,code=sm_100"
mkdir -p /src /out/bin /out/lib && cd /src

[ -x /out/bin/all_reduce_perf ] || { git clone -q --depth 1 https://github.com/NVIDIA/nccl-tests.git
make -C nccl-tests -j"$(nproc)" MPI=0 NVCC_GENCODE="$ARCH_GENCODE" >/dev/null
cp nccl-tests/build/*_perf /out/bin/; }

[ -x /out/bin/nvbandwidth ] || { git clone -q --depth 1 https://github.com/NVIDIA/nvbandwidth.git
cmake -S nvbandwidth -B nvbandwidth/build -DCMAKE_CUDA_ARCHITECTURES="90;100" >/dev/null
cmake --build nvbandwidth/build -j"$(nproc)" >/dev/null
cp nvbandwidth/build/nvbandwidth /out/bin/; }

git clone -q --depth 1 https://github.com/wilicc/gpu-burn.git
make -C gpu-burn COMPUTE=90 >/dev/null
cp gpu-burn/gpu_burn /out/bin/; find gpu-burn -name "compare*.ptx" -exec cp {} /out/bin/compare.ptx \; ; ls gpu-burn

# 运行时依赖：目标镜像未必有，一并带上（运行时 LD_LIBRARY_PATH=/mnt/acceptance/tools/lib）
cp -L /usr/lib/x86_64-linux-gnu/libboost_program_options.so.* /out/lib/
cp -L /usr/lib/x86_64-linux-gnu/libnccl.so.2 /out/lib/
for b in ib_write_bw ib_read_bw ib_write_lat ib_send_bw fio stressapptest numactl ibv_devinfo; do cp -L "$(command -v $b)" /out/bin/; done
# perftest/fio 的非 glibc 动态库
for b in /out/bin/ib_write_bw /out/bin/fio; do
  ldd "$b" | awk '/=>/{print $3}' | grep -v -E 'libc\.so|libm\.so|libpthread|libdl|librt|ld-linux' | xargs -r -I{} cp -L {} /out/lib/
done
cp -rL /usr/lib/x86_64-linux-gnu/libibverbs /out/lib/ 2>/dev/null || true
dpkg -l libnccl2 perftest fio | awk '/^ii/{print $2, $3}' > /out/VERSIONS.txt
([ -d nccl-tests ] && cd nccl-tests && echo "nccl-tests $(git rev-parse --short HEAD)") >> /out/VERSIONS.txt
([ -d nvbandwidth ] && cd nvbandwidth && echo "nvbandwidth $(git rev-parse --short HEAD)") >> /out/VERSIONS.txt
(cd gpu-burn && echo "gpu-burn $(git rev-parse --short HEAD)") >> /out/VERSIONS.txt
cd /out && find . -type f | sort | xargs sha256sum > MANIFEST.sha256
ls -la /out/bin /out/lib
