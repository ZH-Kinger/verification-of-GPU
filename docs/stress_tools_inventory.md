# 压测工具清单

版本：v1.0

## 1. 已放入 U 盘的官方工具

位置：

```text
G:\GPU_Offline_Acceptance\downloads\
```

已包含：

```text
NVIDIA DCGM：datacenter-gpu-manager_3.3.9_amd64.deb
NVIDIA Driver：NVIDIA-Linux-x86_64-610.43.02.run
NVIDIA Fabric Manager：nvidia-fabricmanager_610.43.02-1ubuntu1_amd64.deb
CUDA compatibility：cuda-compat-13-3_610.43.02-1ubuntu1_amd64.deb
nvbandwidth 源码：nvbandwidth-main.zip
nccl-tests 源码：nccl-tests-master.zip
CUDA Samples 源码：cuda-samples-master.zip
```

## 2. 官方主压测工具

正式验收主线：

```bash
dcgmi diag -r 3 -j
```

高风险/异常机器：

```bash
dcgmi diag -r 4 -j
```

DCGM 覆盖：

```text
GPU 诊断
显存测试
显存带宽
PCIe
NVLink/NVSwitch
功耗压力
温度压力
目标压力测试
```

## 3. 带宽和通信压测工具

`nvbandwidth`：

```text
用途：GPU 显存带宽、GPU-GPU 互联带宽、NVLink/NVSwitch 带宽验证
来源：NVIDIA 官方 GitHub
状态：源码已下载，需在 Linux/CUDA 环境下编译
```

`nccl-tests`：

```text
用途：多 GPU all_reduce、all_gather、broadcast 等通信带宽测试
来源：NVIDIA 官方 GitHub
状态：源码已下载，需 CUDA + NCCL + 编译环境
```

CUDA Samples：

```text
用途：deviceQuery、bandwidthTest、p2pBandwidthLatencyTest 等基础测试
来源：NVIDIA 官方 GitHub
状态：源码已下载，需 CUDA + 编译环境
```

## 4. 当前限制

当前 U 盘是 Ubuntu Server LTS 启动盘，不是完整持久化开发系统。

因此：

```text
DCGM deb 包可以作为官方主压测工具安装使用。
nvbandwidth / nccl-tests / CUDA Samples 目前是源码包。
源码包需要在目标 Linux 环境具备 nvcc、gcc、g++、make、NCCL 后编译。
Windows 当前环境不能直接为目标 Linux/H200/B300 编译这些工具。
```

## 5. 现场推荐执行顺序

1. 先跑 fieldiag：

```bash
cd /mnt/gpu_acceptance/GPU_Offline_Acceptance
bash scripts/offline_gpu_acceptance_collect.sh
```

2. 如果允许安装驱动/DCGM：

```bash
sudo bash scripts/install_offline_nvidia_tools.sh
```

3. 跑 DCGM 官方压力测试：

```bash
dcgmi diag -r 3 -j
```

4. 如有编译环境，构建官方源码工具：

```bash
sudo bash scripts/build_official_stress_tools.sh
```

5. 再跑带宽/通信测试：

```bash
nvbandwidth
./tools/bin/all_reduce_perf -b 8M -e 16G -f 2 -g 8
```

## 6. 非官方工具说明

`gpu-burn`、`stress-ng` 这类工具不是 NVIDIA 官方 GPU 验收依据。

建议：

```text
正式验收不把非官方工具作为通过依据。
如要使用，只能作为补充压力观察。
官方主依据仍为 fieldiag + DCGM + nvbandwidth/NCCL。
```

