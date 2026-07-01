# Linux Migration Notes

版本：v1.0

## 1. 迁移目标

后续迁移到 Linux 继续开发时，目标是把当前 U 盘项目升级为真正的一键验机工装。

当前 U 盘已经具备：

```text
Ubuntu Server 24.04.4 LTS 启动区
GPU_DATA 项目数据区
raw 持久化分区预留
默认 fieldiag 模式屏蔽 NVIDIA driver
DCGM 模式允许 NVIDIA driver
官方 NVIDIA/DCGM 工具包
官方压测源码包
SOP、通过标准、模板、脚本
```

## 2. Linux 下第一件事

启动默认项：

```text
GPU Acceptance - fieldiag mode, persistent, NVIDIA driver blocked
```

挂载数据区：

```bash
sudo mkdir -p /mnt/gpu_acceptance
sudo mount -L GPU_DATA /mnt/gpu_acceptance
cd /mnt/gpu_acceptance/GPU_Offline_Acceptance
```

初始化持久化分区：

```bash
sudo CONFIRM_FORMAT=YES bash scripts/init_persistence_partition.sh
```

然后重启。

## 3. 检查 driver 是否被屏蔽

重启后进入默认 fieldiag 模式，执行：

```bash
cat /proc/cmdline
lsmod | egrep 'nvidia|nouveau' || true
```

期望：

```text
/proc/cmdline 包含 modprobe.blacklist=nvidia,nvidia_drm,nvidia_modeset,nvidia_uvm,nouveau
lsmod 不应看到 nvidia/nouveau 模块
```

也可以执行：

```bash
sudo bash scripts/set_fieldiag_driver_block.sh
```

## 4. 放入 fieldiag

把 OEM/NVIDIA fieldiag 包放到：

```text
/mnt/gpu_acceptance/GPU_Offline_Acceptance/tools/fieldiag/
```

默认可执行文件路径：

```text
tools/fieldiag/fieldiag
```

如果不是这个名字，运行时设置：

```bash
FIELDIAG_BIN=/mnt/gpu_acceptance/GPU_Offline_Acceptance/tools/fieldiag/<实际文件名> \
bash scripts/offline_gpu_acceptance_collect.sh
```

## 5. fieldiag 模式验机

执行：

```bash
cd /mnt/gpu_acceptance/GPU_Offline_Acceptance
bash scripts/offline_gpu_acceptance_collect.sh
```

日志会写入：

```text
logs/YYYY-MM-DD_HHMMSS_SERVER-SN/
```

## 6. DCGM/压测模式

重启并选择：

```text
GPU Acceptance - dcgm mode, persistent, NVIDIA driver allowed
```

挂载数据区：

```bash
sudo mount -L GPU_DATA /mnt/gpu_acceptance
cd /mnt/gpu_acceptance/GPU_Offline_Acceptance
```

安装离线 NVIDIA/DCGM 包：

```bash
sudo bash scripts/install_offline_nvidia_tools.sh
```

跑主采集脚本：

```bash
bash scripts/offline_gpu_acceptance_collect.sh
```

## 7. 构建官方压测工具

如果系统里有 `nvcc`、`make`、`gcc/g++`、NCCL：

```bash
sudo bash scripts/build_official_stress_tools.sh
```

输出目录：

```text
tools/bin/
```

可能生成：

```text
tools/bin/nvbandwidth
tools/bin/all_reduce_perf
tools/bin/all_gather_perf
tools/bin/deviceQuery
tools/bin/bandwidthTest
tools/bin/p2pBandwidthLatencyTest
```

## 8. 后续开发 TODO

建议在 Linux 下继续做：

```text
1. 根据 fieldiag 实际参数完善脚本。
2. 增加 run_acceptance.sh 一键验机入口。
3. 自动解析 fieldiag/DCGM/nvbandwidth 结果。
4. 自动生成 final_result.txt。
5. 预编译 nvbandwidth/nccl-tests/CUDA samples。
6. 增加 PASS/RETEST/FAIL 自动判定。
7. 如有多型号机器，增加 SKU 配置文件。
```

## 9. 不要做的事

```text
不要把 Ubuntu 安装到待验服务器本地硬盘。
不要在 fieldiag 模式自动加载 NVIDIA driver。
不要把非官方 gpu-burn 作为正式验收通过依据。
不要覆盖原始日志。
```

