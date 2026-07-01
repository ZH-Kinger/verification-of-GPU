# U 盘包完整性清单

版本：v2.0

更新时间：2026-06-15

## 1. 总结

当前 U 盘已经具备：

```text
Ubuntu Server 24.04.4 LTS 启动环境
NVIDIA Driver / DCGM / Fabric Manager 离线安装包
NVIDIA 官方压测源码包（nvbandwidth / nccl-tests / cuda-samples）
已编译好的压测二进制（tools/bin/，sm_90 + sm_100）
目标机(noble)离线运行时 deb：cuda-cudart-12-8 + libnccl2 2.30.7
目标机(noble)离线重编工具链 deb：nvcc 12.8 + build-essential + cmake + boost + nccl-dev（含完整依赖闭包）
验机 SOP、标准、模板、脚本、项目记忆
持久化预留分区
默认屏蔽 NVIDIA driver 的 fieldiag 启动模式
```

当前 U 盘还不具备：

```text
fieldiag 工具包（仍需用户手动拷入 tools/fieldiag/）
完整 CUDA 数学库（cublas/cufft 等）—— 本验收三件套不需要，故未打包
```

v2.0 变更（在联网 Linux 主机上完成，产物已写入 U 盘）：

```text
补下 cuda-samples-master.zip
编译 nvbandwidth / nccl-tests(全部 *_perf) / deviceQuery / p2pBandwidthLatencyTest，目标 sm_90+sm_100，放入 tools/bin/
下载 noble 离线运行时与重编 deb，放入 downloads/offline_deb_noble/
四级验证：二进制符号解析 / 运行时离线安装 / 重编工具链裸机离线安装 / 端到端断网重编 nvbandwidth —— 全部通过
```

## 2. 已齐全的包

位置：

```text
G:\GPU_Offline_Acceptance\downloads\
```

已下载：

```text
iso\ubuntu-24.04.4-live-server-amd64.iso
iso\SHA256SUMS
iso\SHA256SUMS.gpg

nvidia\NVIDIA-Linux-x86_64-610.43.02.run
nvidia\datacenter-gpu-manager_3.3.9_amd64.deb
nvidia\datacenter-gpu-manager-exporter_4.8.2-1_amd64.deb
nvidia\nvidia-fabricmanager_610.43.02-1ubuntu1_amd64.deb
nvidia\cuda-compat-13-3_610.43.02-1ubuntu1_amd64.deb
nvidia\cuda-keyring_1.1-1_all.deb
nvidia\Packages.gz

source\nvbandwidth-main.zip
source\nccl-tests-master.zip
source\cuda-samples-master.zip

DOWNLOAD_MANIFEST.txt
```

## 3. 已齐全的文档和脚本

文档：

```text
README.md
PROJECT_PLAN.md
PROJECT_MEMORY.md
docs\offline_gpu_acceptance_sop.md
docs\acceptance_criteria.md
docs\single_usb_boot_disk_design.md
docs\minimal_usb_build_runbook.md
docs\stress_tools_inventory.md
docs\persistence_options.md
docs\linux_migration_notes.md
docs\package_completeness.md
```

脚本：

```text
scripts\run_acceptance.sh
scripts\offline_gpu_acceptance_collect.sh
scripts\mount_gpu_data.sh
scripts\install_offline_nvidia_tools.sh
scripts\install_offline_cuda_runtime.sh
scripts\build_official_stress_tools.sh
scripts\init_persistence_partition.sh
scripts\set_fieldiag_driver_block.sh
scripts\prepare_single_usb_minimal.ps1
scripts\verify_downloads.ps1
```

## 3b. 已编译二进制（tools/bin/）

均为 fatbin，含 sm_90(H200) + sm_100(B300/GB300) SASS，部分带 PTX 兜底：

```text
nvbandwidth
all_reduce_perf  all_gather_perf  alltoall_perf  broadcast_perf
reduce_perf  reduce_scatter_perf  gather_perf  scatter_perf
sendrecv_perf  hypercube_perf
deviceQuery
p2pBandwidthLatencyTest
（注：新版 cuda-samples 已移除 bandwidthTest，其功能由 nvbandwidth 覆盖）
```

校验：tools/bin_MANIFEST.sha256

运行依赖（目标机需提供）：

```text
nvbandwidth          -> 仅 NVIDIA 驱动（libcuda / libnvidia-ml）
nccl-tests(*_perf)   -> 驱动 + libcudart.so.12 + libnccl.so.2(>=2.30)
deviceQuery / p2p    -> 驱动 + libcudart.so.12
```

## 3c. 目标机离线 deb（downloads/offline_deb_noble/）

```text
runtime/   运行预编译二进制所需：cuda-cudart-12-8 + libnccl2 2.30.7+cuda12.9
           安装：sudo bash scripts/install_offline_cuda_runtime.sh
rebuild/   现场离线重编整套工具链（141 个 deb，含完整依赖闭包）：
           nvcc 12.8 + cudart-dev + nvml-dev + nvrtc-dev + build-essential
           + cmake + libboost-program-options-dev + unzip + libnccl2/dev 2.30.7
           安装：sudo dpkg -i downloads/offline_deb_noble/rebuild/*.deb
```

校验：downloads/offline_deb_noble/MANIFEST.sha256
说明：downloads/offline_deb_noble/README.txt

## 4. 尚缺的关键项

### 4.1 fieldiag 工具包（唯一硬缺口）

状态：

```text
仍未放入 U 盘，需用户手动拷入
```

影响：

```text
无法完成硬件主验收项
offline_gpu_acceptance_collect.sh / run_acceptance.sh 会记录 fieldiag 缺失
```

应放位置 / 默认可执行路径：

```text
tools/fieldiag/   ->   tools/fieldiag/fieldiag
```

如果实际文件名不同，Linux 运行时设置：

```bash
FIELDIAG_BIN=/mnt/gpu_acceptance/GPU_Offline_Acceptance/tools/fieldiag/<实际文件名> \
bash scripts/run_acceptance.sh fieldiag
```

### 4.2 完整 CUDA 数学库（cublas/cufft 等）—— 有意未打包

```text
本验收三件套（nvbandwidth / nccl-tests / cuda-samples deviceQuery+p2p）均不依赖
cublas/cufft 等数学库，故未纳入 rebuild/ 闭包以控制体积。
若将来需要编译依赖这些库的 CUDA 程序，再单独补 cuda-libraries-dev-12-8 闭包。
注：CUDA Toolkit/nvcc 本身已在 v2.0 以 noble 离线 deb 补齐（见 3c）。
```

<!-- 以下为 v1.0 旧记录，已过时（CUDA Toolkit/nvcc 已补齐） -->

### (旧) CUDA Toolkit / nvcc

状态：

```text
未完整离线下载
```

影响：

```text
无法在目标机上直接编译 nvbandwidth、nccl-tests、CUDA samples
```

后续选择：

```text
在 Linux 持久化系统中补完整 CUDA Toolkit
或在兼容 Linux 环境中预编译二进制后放入 tools\bin\
```

### 4.3 ~ 4.5（已解决）

```text
[已补齐] NCCL runtime/dev：libnccl2 / libnccl-dev 2.30.7+cuda12.9（见 3c）
[已补齐] Linux 编译依赖：build-essential / cmake / unzip + 完整依赖闭包（见 3c rebuild/）
[已生成] 预编译压测二进制：见 3b（tools/bin/）
```

## 5. 当前 U 盘可直接支持的工作

当前可支持：

```text
从 U 盘启动裸金属服务器
进入默认 fieldiag 模式并屏蔽 NVIDIA/nouveau driver
挂载 GPU_DATA、保存日志
离线安装 NVIDIA Driver / DCGM / Fabric Manager
离线安装 CUDA 运行时 + NCCL（install_offline_cuda_runtime.sh）
开箱即跑 nvbandwidth / nccl-tests / deviceQuery / p2pBandwidthLatencyTest（装好驱动+运行时后）
现场零联网重编上述工具（dpkg -i rebuild/*.deb 后用源码 zip 重编）
保存 DCGM / nvidia-smi / dmesg / topology 日志
```

当前不可直接保证：

```text
开箱即跑 fieldiag —— 因 fieldiag 仍未放入（唯一阻塞项）
```

离线可用性验证（均在断网 ubuntu:24.04 容器中完成）：

```text
[通过] 预编译二进制动态符号全解析（仅缺驱动提供的 libcuda）
[通过] runtime/ deb 离线安装
[通过] rebuild/ 工具链在裸 noble 上 dpkg -i 干净安装
[通过] 端到端：断网 + 仅挂 U 盘，从源码离线重编出 nvbandwidth
```

## 6. 推荐补齐顺序

优先级 1（唯一阻塞）：

```text
把 fieldiag 包放入 tools/fieldiag/
确认默认 fieldiag 模式下 NVIDIA/nouveau driver 未加载
```

优先级 2：

```text
在 Linux 下初始化持久化分区
真机验证 NVIDIA Driver / DCGM / Fabric Manager / CUDA 运行时 离线安装
真机跑一轮 nvbandwidth / nccl-tests 确认性能数据落地
```

优先级 3（已完成）：

```text
[完成] 补完整 CUDA 编译/运行依赖（noble 离线 deb）
[完成] 预编译 nvbandwidth / nccl-tests / cuda-samples 放入 tools/bin/
[完成] 一键验机脚本 run_acceptance.sh
```

## 7. 验收主线提醒

正式验收依据仍然是：

```text
fieldiag PASS
+ DCGM PASS
+ HBM/NVLink/NCCL 性能达到最低线
+ 无 XID/ECC/掉卡/降链
+ 原始日志完整
```

