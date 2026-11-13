set -eux
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq; apt-get install -y -qq --allow-change-held-packages git libopenmpi-dev openmpi-bin libnccl2 libnccl-dev >/dev/null
cd /tmp
git clone -q --depth 1 https://github.com/NVIDIA/nccl-tests.git n
G="-gencode=arch=compute_90,code=sm_90 -gencode=arch=compute_100,code=sm_100"
T=""; for b in all_reduce all_gather broadcast reduce_scatter reduce alltoall alltoallv scatter gather sendrecv hypercube; do T="$T /tmp/n/build/${b}_perf"; done
make -C n/src -j"$(nproc)" MPI=1 MPI_HOME=/usr/lib/x86_64-linux-gnu/openmpi BUILDDIR=/tmp/n/build NVCC_GENCODE="$G" $T >/dev/null
for f in $T; do cp "$f" "/out/bin/$(basename "$f")_mpi"; done
echo "nccl-tests-mpi $(cd n && git rev-parse --short HEAD) (11 collectives only)" >> /out/VERSIONS_extra.txt
mkdir -p /out/mpi
cp -L /usr/bin/orterun /out/mpi/mpirun
cp -aL /usr/lib/x86_64-linux-gnu/openmpi /out/mpi/lib-openmpi
cp -aL /usr/share/openmpi /out/mpi/share-openmpi
for l in libmpi.so.40 libopen-rte.so.40 libopen-pal.so.40 libhwloc.so.15 libevent_core-2.1.so.7 libevent_pthreads-2.1.so.7 libpmix.so.2 libltdl.so.7; do
  cp -L /usr/lib/x86_64-linux-gnu/$l /out/lib/ 2>/dev/null || echo "no $l"
done
dpkg -l openmpi-bin | awk '/^ii/{print $2, $3}' >> /out/VERSIONS_extra.txt
git clone -q --depth 1 --branch v12.4 https://github.com/NVIDIA/cuda-samples.git s
for x in p2pBandwidthLatencyTest bandwidthTest; do
  d=$(find s/Samples -type d -name "$x" | head -1); echo "$x -> $d"
  make -C "$d" SMS="90" >/dev/null && cp "$d/$x" /out/bin/ || echo "build failed $x"
done
sed -i '/^MISSING sample/d' /out/VERSIONS_extra.txt
echo "cuda-samples v12.4 p2pBandwidthLatencyTest bandwidthTest" >> /out/VERSIONS_extra.txt
git clone -q --depth 1 https://github.com/jeffhammond/STREAM.git
gcc -O3 -march=sapphirerapids -fopenmp -mcmodel=large -DSTREAM_ARRAY_SIZE=2147483648 -DNTIMES=10 STREAM/stream.c -o /out/bin/stream
cp -L /usr/lib/x86_64-linux-gnu/libgomp.so.1 /out/lib/
echo "STREAM $(cd STREAM && git rev-parse --short HEAD)" >> /out/VERSIONS_extra.txt
