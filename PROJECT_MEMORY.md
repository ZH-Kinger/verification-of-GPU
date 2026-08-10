# Project Memory

Last updated: 2026-08-10

## v3.0 — 对接甲方《验收标准》（2026-08-10）

甲方给出一份逐条数值化的《验收标准》（8 章，约 50 项，第 23-29 页），
针对 **Blackwell Ultra 8 卡节点**（2×NVSwitch4、每卡 18×NVLink5、288GB HBM3e、
1100W、PCIe Gen6 x16、8×ConnectX-8）。与项目原有 H200 散文式标准差异很大，
本轮改造把项目从"采集 + 人工判"改成"采集 + 自动判"，并拆成两条链路。

已决定（用户确认）：

```text
1. 两条链路：单机离线压测（§1-4,7,8）+ 多机压测（§5,6）。
   多机两种现场都要支持：节点已装好 OS，或裸机。
2. fieldiag 保持阶段一主标准，新标准作为阶段二。grub 默认项不变。
3. CUDA：先做脚本和判定，加环境预检确认实际计算能力后再重编。
```

新增结构：

```text
profiles/b300_8gpu.env, h200_8gpu.env   每机型的全部阈值 + 驱动/CUDA/NCCL/DCGM
                                        版本要求 + 使用哪套 tools 二进制
scripts/lib/common.sh                   profile 加载、阈值断言、报告、输出解析
scripts/preflight.sh                    计算能力 / 版本 / 工具在位预检
scripts/collect_node.sh                 §1 §2 §3 §4 §7 采集
scripts/soak_node.sh                    §8 长稳烤机（增量口径）
scripts/check_node.sh                   单机判定 → acceptance_report.tsv/.txt
scripts/set_nvidia_modprobe_params.sh   §7 驱动参数
scripts/cluster/                        §5 §6 多机链路
docs/acceptance_criteria_b300.md        标准 → 脚本 → 判定 映射表
docs/tooling_gaps.md                    缺失工具与离线获取方法
docs/cuda_arch_decision.md              CUDA 13 / sm_103 决策记录
docs/cluster_runbook.md                 多机 runbook
```

判定口径（写死在 check_node.sh 里，改动前先想清楚）：

```text
可纠正 ECC 按 GPU index 配对求增量取最大值，不求和（标准是"单卡"口径）
PCIe 判 link.gen.max 不判 current（空闲会降到 Gen1，判 current 会全线误 FAIL）
带宽矩阵取非对角最小值（标准说"任意 GPU 对"）
NCCL 取峰值 Bus BW，均值记备注
温度/波动用 samples.csv 而非 dmon.txt（dmon 列布局随驱动版本变）
nvidia-smi 返回 [N/A] 一律判 SKIP，绝不当成 0
  —— "没有数据"和"计数为 0"是两回事，后者会给出假 PASS
SKIP 不等于 PASS：有 SKIP 无 FAIL 判 HOLD
```

测试中实测发现、已修复的坑（都不是 bash -n 能看出来的）：

```text
ipmitool sensor list 的状态在第 4 列（第 3 列是单位）
grep -c 找不到时「打印 0 且退出码非 0」，写 || echo 0 会得到两行 "0"
grep -c 带多个文件会每文件输出一行计数，-h 也不抑制 -> 先 cat 成单流
num_min/num_max 按值输出 "1" 或 "1.00"，不能拿它的输出做字符串比对
GNU timeout 默认把子进程放进自己新建的进程组，按作业进程组回收够不着它
  -> soak 的 dmon 必须用 timeout --foreground，否则中断后采样器一直活着
中文 locale 下 free 打的是「内存：」而非「Mem:」，解析器一无所获，
  系统内存/内存识别率静默变 SKIP -> 共用库统一 export LC_ALL=C，
  且 run_shell 要在登录 shell 内再钉一次（profile 可能改回去）
samples.csv 的表头不跳过，"index" 被当成 0，每卡最小温度=0，
  温度波动直接等于峰值，正常机器会被判 FAIL
长稳被中断时报的是「计划时长」而非实际时长 -> 跑了 2 小时会写成 18 小时；
  实际时长必须在 cleanup 里落盘，因为被 TERM 杀掉时收尾代码执行不到
频率串 "6400 MT/s" 含斜杠，与拼接分隔符撞车
Ubuntu 默认 awk 是 mawk：不支持多维数组，length/substr 按字节
column 来自 bsdextrautils（optional，非 essential），最小镜像里可能没有
全角破折号是 East Asian Ambiguous，显示宽度随终端在 1/2 间摇摆
```

工具缺口 —— 已接进 bootstrap + build（联网工作主机上一条命令补齐）：

```text
gpu_burn + compare.ptx        gpu-burn-master.zip -> tools/<subdir>/
bandwidthTest                 cuda-samples-v12.3.zip（新版 master 已删除它）
*_perf_mpi                    nccl-tests MPI=1，独立编译目录 + _mpi 后缀
ipmitool/ethtool/nvme-cli/openmpi   downloads/offline_deb_noble/tools/
                              目标机: scripts/install_offline_tools.sh
```

新引入的依赖（重要）：**gpu-burn 链接 cublas**，所以 runtime/ 新增
`libcublas-12-8`。这是本项目原先"不打包 CUDA 数学库"决定的唯一例外。
另外 gpu_burn 运行时需要同目录的 `compare.ptx`，两个文件必须一起拷。

仍待办（见 docs/tooling_gaps.md）：

```text
DCGM 升到 4.x（3.3.9 不支持 Blackwell，diag 会"没测也没 Fail"）
gdrcopy_sanity（需编内核模块，live 系统上不一定装得起来）
MFT / mlnx_qos / perftest（§5；多数现场节点自带 DOCA-OFED，不必本项目携带）
*_perf_mpi 的多节点分发（编译已自动化，但 mpirun 不会替你分发到各节点）
CUDA 13 + sm_103 重编（待 preflight 在真机确认计算能力后启动）
```

## Project Goal

Build an offline, single-USB GPU acceptance toolkit for bare-metal NVIDIA H200 / B300 / GB300 machines with no network, no installed OS, and no management port.

The USB must support:

```text
UEFI boot
offline SOP and templates
fieldiag-first hardware validation
NVIDIA driver / DCGM / Fabric Manager offline installation
official stress-tool source packages
log retention
persistence with NVIDIA driver blocked by default
```

## Current USB State

USB device:

```text
Kingston DataTraveler 3.0
Disk number used during build: 2
Serial observed: EE0AD35159E8
```

Current Windows-visible partitions:

```text
F:\  UBUNTU_BOOT  FAT32  ~8GB
G:\  GPU_DATA     exFAT  ~32GB
```

There is also a third raw partition reserved for Linux persistence:

```text
PERSIST_RAW  unformatted from Windows
Linux first-boot script formats it as ext4 label writable
```

## Boot Behavior

The USB boot menu is customized in:

```text
boot_configs/grub.cfg
boot_configs/loopback.cfg
```

Default boot entry:

```text
GPU Acceptance - fieldiag mode, persistent, NVIDIA driver blocked
```

Default blocked modules:

```text
nvidia
nvidia_drm
nvidia_modeset
nvidia_uvm
nouveau
```

DCGM/pressure mode is available as a separate menu entry:

```text
GPU Acceptance - dcgm mode, persistent, NVIDIA driver allowed
```

## Important Decisions

1. `fieldiag` is the primary hardware acceptance standard.
2. DCGM is the primary official system/stress diagnostic.
3. `nvbandwidth`, `nccl-tests`, and CUDA samples are official supplemental tools.
4. Default boot blocks NVIDIA/nouveau drivers to protect `fieldiag` compatibility.
5. Driver/DCGM mode must be selected intentionally when running system-level stress tests.
6. The USB uses Ubuntu Server 24.04.4 LTS, not the newest LTS, for stability and NVIDIA Ubuntu 24.04 package availability.
7. Stress tools are now precompiled (tools/bin/, sm_90+sm_100); their offline CUDA
   runtime + NCCL and a full offline rebuild toolchain ship as noble debs under
   downloads/offline_deb_noble/. Full CUDA math libs (cublas/cufft) are intentionally
   not packaged since the acceptance tools do not need them.

## Downloaded Official Assets

Stored under:

```text
GPU_Offline_Acceptance/downloads/
```

Assets:

```text
iso/ubuntu-24.04.4-live-server-amd64.iso
nvidia/NVIDIA-Linux-x86_64-610.43.02.run
nvidia/datacenter-gpu-manager_3.3.9_amd64.deb
nvidia/datacenter-gpu-manager-exporter_4.8.2-1_amd64.deb
nvidia/nvidia-fabricmanager_610.43.02-1ubuntu1_amd64.deb
nvidia/cuda-compat-13-3_610.43.02-1ubuntu1_amd64.deb
nvidia/cuda-keyring_1.1-1_all.deb
source/nvbandwidth-main.zip
source/nccl-tests-master.zip
source/cuda-samples-master.zip
DOWNLOAD_MANIFEST.txt
```

Ubuntu ISO SHA256 was verified successfully before USB build.

## Precompiled Binaries + Offline deb (added v2.0, 2026-06-15)

Built on a networked Ubuntu host with CUDA 12.8, written to the USB:

```text
tools/bin/                     nvbandwidth, all_reduce_perf & other *_perf,
                               deviceQuery, p2pBandwidthLatencyTest
                               (fatbin: sm_90 H200 + sm_100 B300/GB300)
tools/bin_MANIFEST.sha256      sha256 of the binaries
downloads/offline_deb_noble/runtime/   cuda-cudart-12-8 + libnccl2 2.30.7+cuda12.9
downloads/offline_deb_noble/rebuild/   full offline rebuild toolchain (141 debs:
                               nvcc 12.8, build-essential, cmake, boost, unzip,
                               nccl dev, complete dependency closure)
downloads/offline_deb_noble/README.txt + MANIFEST.sha256
scripts/install_offline_cuda_runtime.sh   installs the runtime debs on target
```

Key version decisions:

```text
nccl-tests needs NCCL >= 2.30 symbols (ncclTeamLsa, ncclDevCommCreate, ...);
shipped libnccl2 is 2.30.7 (the +cuda12.9 build -> single libcudart.so.12).
All CUDA components are the 12.8 line, matching libcudart.so.12 the binaries link.
```

Offline verification (all in a network-disabled ubuntu:24.04 container): binary
symbol resolution, runtime deb install, rebuild toolchain install on bare noble,
and end-to-end offline recompile of nvbandwidth from the USB source — all passed.
Only the GPU driver (libcuda/libnvidia-ml) must be installed on the real target.

## Missing External Asset

The user has `fieldiag`, but it has not been copied into the project yet.

Expected location:

```text
GPU_Offline_Acceptance/tools/fieldiag/
```

The `offline_gpu_acceptance_collect.sh` script expects the default executable at:

```text
tools/fieldiag/fieldiag
```

If the executable name differs, set:

```bash
FIELDIAG_BIN=/mnt/gpu_acceptance/GPU_Offline_Acceptance/tools/fieldiag/<actual_binary>
```

## Package Completeness

See:

```text
docs/package_completeness.md
```

Current short status:

```text
Ready: Ubuntu Server LTS boot, NVIDIA driver runfile, DCGM, Fabric Manager, CUDA
  compatibility, official source packages, PRECOMPILED stress binaries (tools/bin/,
  sm_90+sm_100), offline CUDA runtime + NCCL deb, offline full rebuild toolchain.
Missing: fieldiag package (user must copy in). That is now the only hard gap.
```

## First Linux Boot Steps

Boot default fieldiag mode, then mount data:

```bash
sudo mkdir -p /mnt/gpu_acceptance
sudo mount -L GPU_DATA /mnt/gpu_acceptance
cd /mnt/gpu_acceptance/GPU_Offline_Acceptance
```

Initialize persistence partition once:

```bash
sudo CONFIRM_FORMAT=YES bash scripts/init_persistence_partition.sh
```

NOTE: the persistence partition (sda3, ~18 GB) was ALREADY formatted as ext4
label `writable` on 2026-06-16, so this step is normally a no-op — the script
will report "no unformatted persistence partition found", which is expected.
Only re-run it if the partition was wiped.

Reboot into default fieldiag mode again.

## Fieldiag Mode

Default mode should avoid driver interference.

Optional persistent block inside the live system:

```bash
sudo bash scripts/set_fieldiag_driver_block.sh
```

Run collection (one command):

```bash
sudo bash scripts/run_acceptance.sh fieldiag
```

This runs fieldiag, collects logs, skips driver-only tools (DCGM/nvbandwidth),
and writes a pre-filled `final_result.txt` into the timestamped log directory.
The lower-level `scripts/offline_gpu_acceptance_collect.sh` can still be called
directly if finer control is needed.

## DCGM / Stress Mode

Reboot and choose:

```text
GPU Acceptance - dcgm mode, persistent, NVIDIA driver allowed
```

Then:

```bash
sudo mount -L GPU_DATA /mnt/gpu_acceptance
cd /mnt/gpu_acceptance/GPU_Offline_Acceptance
sudo bash scripts/run_acceptance.sh dcgm
```

`run_acceptance.sh dcgm` installs the offline NVIDIA tools, best-effort builds
the stress-tool sources, then collects with DCGM and nvbandwidth enabled and
fieldiag skipped. Use `SKIP_INSTALL=1` / `SKIP_BUILD=1` to skip those stages.

If CUDA build dependencies are available:

```bash
sudo bash scripts/build_official_stress_tools.sh
```

## Key Acceptance Thresholds

H200:

```text
HBM bandwidth PASS:   >= 4.3 TB/s
HBM bandwidth RETEST: >= 4.1 TB/s and < 4.3 TB/s
HBM bandwidth FAIL:   < 4.1 TB/s
```

B300/GB300:

```text
Use OEM official single-GPU bandwidth X.
PASS:   >= X * 90%
RETEST: >= X * 85% and < X * 90%
FAIL:   < X * 85%
```

Hard fail:

```text
fieldiag FAIL
XID
GPU fallen off the bus
uncorrectable ECC
GPU reset
PCIe fatal error
NVLink missing/fatal
performance below fail line
```

## Next Recommended Work

1. Copy the user's `fieldiag` package into `tools/fieldiag/`.
2. Boot one target machine in fieldiag mode.
3. Initialize persistence partition.
4. Confirm default boot blocks NVIDIA/nouveau modules.
5. Run `fieldiag` and collect logs.
6. Reboot into DCGM mode and test offline driver/DCGM installation.
   In dcgm mode also run `scripts/install_offline_cuda_runtime.sh`, then the
   tools/bin binaries run directly (no build needed).
7. DONE: precompiled `nvbandwidth`, `nccl-tests`, `deviceQuery`,
   `p2pBandwidthLatencyTest` in tools/bin/ (sm_90+sm_100); cuda-samples zip added.
8. DONE: `scripts/run_acceptance.sh` added (fieldiag/dcgm one-command modes).
   Set `FIELDIAG_ARGS` once the exact fieldiag arguments for the target SKU are known.
9. DONE: noble offline deb (runtime + full rebuild toolchain) in
   downloads/offline_deb_noble/; offline-install + offline-recompile verified.
