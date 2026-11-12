#!/bin/bash
# 单机验收探测。在平台任务容器里运行，输出全部进 stdout（平台日志），结果行以 @@RESULT 开头。
# BURN_SECONDS 控制烤机时长；QUICK=1 时只做清单 + 每项最小测试，用来先验证任务能跑通。
set -u
BURN_SECONDS=${BURN_SECONDS:-600}
QUICK=${QUICK:-0}
B=${B:-$(cd "$(dirname "$0")" && pwd)/bench.py}
sec() { echo; echo "@@SECTION $*  $(date -u +%FT%TZ)"; }

sec env
hostname; uname -r; cat /etc/os-release | head -2; id
env | grep -E '^(NCCL_|NODE_|MASTER_|PROC_PER_NODE|JOB_ID|CUDA_|NVIDIA_)' | sort

sec inventory_gpu
nvidia-smi
nvidia-smi --query-gpu=index,name,serial,uuid,pci.bus_id,memory.total,ecc.mode.current,power.limit,power.max_limit,clocks.max.sm,clocks.max.mem,pcie.link.gen.max,pcie.link.width.max,pcie.link.gen.current,pcie.link.width.current,driver_version,vbios_version,temperature.gpu,persistence_mode,mig.mode.current --format=csv
nvidia-smi --query-gpu=index,ecc.errors.corrected.volatile.total,ecc.errors.uncorrected.volatile.total,ecc.errors.corrected.aggregate.total,ecc.errors.uncorrected.aggregate.total,retired_pages.pending,remapped_rows.correctable,remapped_rows.uncorrectable,remapped_rows.pending,remapped_rows.failure --format=csv
nvidia-smi topo -m
nvidia-smi nvlink -s 2>&1 | head -60
nvidia-smi nvlink -e 2>&1 | grep -v ': 0$' | head -40
nvidia-smi -q -d CLOCK_EVENT_REASONS 2>/dev/null | grep -E 'GPU 0|Active|Throttle|Slowdown' | head -20

sec inventory_host
lscpu
echo "smt_active=$(cat /sys/devices/system/cpu/smt/active 2>/dev/null) smt_control=$(cat /sys/devices/system/cpu/smt/control 2>/dev/null)"
echo "physical_cores=$(lscpu -p=core,socket 2>/dev/null | grep -v '^#' | sort -u | wc -l) logical=$(lscpu -p=cpu 2>/dev/null | grep -v '^#' | wc -l)"
free -g
cat /sys/fs/cgroup/cpu.max 2>/dev/null; cat /sys/fs/cgroup/memory.max 2>/dev/null
nproc
numactl -H 2>/dev/null | head -20
df -h / /dev/shm /tmp 2>/dev/null
ls /dev/infiniband 2>/dev/null; (ibv_devinfo 2>/dev/null || true) | grep -E 'hca_id|state|link_layer|active_mtu|rate' | head -60
ls /sys/class/infiniband 2>/dev/null && for d in /sys/class/infiniband/*; do for p in $d/ports/*; do echo "$(basename $d) port $(basename $p): $(cat $p/state 2>/dev/null) $(cat $p/rate 2>/dev/null) $(cat $p/link_layer 2>/dev/null)"; done; done
ip -br addr 2>/dev/null | head -30
lspci 2>/dev/null | grep -i -E 'nvidia|mellanox|infiniband|ethernet|nvme' | head -40

sec tools
for t in nvcc dcgmi all_reduce_perf nvbandwidth gpu_burn ib_write_bw fio stressapptest mpirun numactl; do printf '%-16s %s\n' $t "$(command -v $t || echo MISSING)"; done
python3 -c 'import torch;print("torch",torch.__version__,"cuda",torch.version.cuda,"nccl",torch.cuda.nccl.version(),"cap",torch.cuda.get_device_capability(0),"n",torch.cuda.device_count())'

if [ "$QUICK" = 1 ]; then
  sec quick_gemm; python3 -c 'import torch;a=torch.randn(4096,4096,device="cuda",dtype=torch.bfloat16);import time;torch.cuda.synchronize();t=time.time();[a@a for _ in range(50)];torch.cuda.synchronize();print("@@RESULT",{"kind":"quick_gemm_tflops","v":round(2*4096**3*50/(time.time()-t)/1e12,1)})'
  sec done; exit 0
fi

sec gemm;  python3 $B gemm
sec hbm;   python3 $B hbm
sec p2p;   python3 $B p2p
sec nccl;  NCCL_DEBUG=WARN python3 -m torch.distributed.run --standalone --nproc_per_node=$(nvidia-smi -L | wc -l) $B nccl

sec burn  "seconds=$BURN_SECONDS"
nvidia-smi --query-gpu=index,temperature.gpu,temperature.memory,power.draw,clocks.sm,clocks.mem,utilization.gpu,clocks_event_reasons.active --format=csv,noheader -l 10 > /tmp/burn_samples.csv &
SAMPLER=$!
python3 $B burn "$BURN_SECONDS"
kill $SAMPLER 2>/dev/null
echo "@@BURN_SAMPLES_BEGIN"; cat /tmp/burn_samples.csv; echo "@@BURN_SAMPLES_END"

sec post_ecc
nvidia-smi --query-gpu=index,ecc.errors.corrected.volatile.total,ecc.errors.uncorrected.volatile.total,remapped_rows.pending,remapped_rows.failure --format=csv
nvidia-smi nvlink -e 2>&1 | grep -v ': 0$' | head -40
dmesg 2>/dev/null | grep -i xid | tail -20 || echo "dmesg not readable in container"
sec done
