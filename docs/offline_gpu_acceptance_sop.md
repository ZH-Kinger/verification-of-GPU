# 离线单机 GPU 验收 SOP

版本：v3.0（对应本 U 盘实际工具与脚本）

适用范围：无系统、无网络、无管理口的裸金属单机服务器；GPU 为 NVIDIA
H200、B300/GB300 或同等级数据中心 GPU。

**验收分两个阶段**：

| 阶段 | 内容 | 启动模式 | 入口 |
|------|------|---------|------|
| 一 | fieldiag 硬件主验收 | fieldiag mode（驱动被屏蔽） | `run_acceptance.sh fieldiag` |
| 二 | 甲方《验收标准》§1-§4 §7 §8 逐项自动判定 | dcgm mode（驱动放行） | `run_acceptance.sh standard <机型>` |

阶段二的阈值不写在本文，全部在 `profiles/<机型>.env`（每条都标了来源：
`[标准]` 甲方原值 / `[推导]` 附推导过程 / `[待校准]` 待实测回填），
项与阈值的对照见 `docs/acceptance_criteria_b300.md`。
H200 时期的散文式标准 `docs/acceptance_criteria.md` 仍适用于其"硬性 FAIL 条件"。

多机（§5 RoCE + §6 跨节点 NCCL）需要组网与 MPI，不在本 SOP 的单机流程内，
见 `docs/cluster_runbook.md`。

首次在某机型上验证本 U 盘时，先按 `docs/first_target_run_checklist.md` 走一遍。

---

## 0. 验收总原则

不是“能点亮就通过”。一台机器判 PASS 必须同时满足：

```text
实物与采购清单一致
+ 对应 SKU 的 fieldiag 全部 GPU PASS
+ 压力测试无硬件硬错误（XID/掉卡/reset/ECC/PCIe/NVLink fatal）
+ 显存/互联/功耗达到 acceptance_criteria.md 的最低性能线
+ 原始日志完整落盘、可追溯到服务器 SN 与 GPU SN
```

任意一张 GPU 不达标，整机不 PASS。每台机器只有四种结论：
**PASS / FAIL / RETEST（只许复测一次）/ HOLD**。

---

## 1. 现场工装

无管理口、无预装系统的裸机必须准备物理控制台：

```text
本验机 U 盘
USB 键盘 + 便携显示器（或 HDMI/VGA 采集卡）
电源线、记录用笔记本（仅用于读日志/制盘，不作服务器显示器）
采购清单、服务器 SN 清单、GPU SN/PN 清单
fieldiag 支持 SKU 清单
```

无法进入 U 盘诊断系统的机器 → 结论 HOLD，不进入 GPU 验收。

---

## 2. 本 U 盘结构与两种启动模式

U 盘三分区：`UBUNTU_BOOT`(启动) / `GPU_DATA`(项目与工具) / `writable`(持久层)。
grub 启动菜单两项：

```text
GPU Acceptance - fieldiag mode, persistent, NVIDIA driver blocked   ← 默认，硬件主验收
GPU Acceptance - dcgm mode, persistent, NVIDIA driver allowed       ← 系统/压力/性能
```

项目根（下称 $ROOT）：`/mnt/gpu_acceptance/GPU_Offline_Acceptance`
关键位置：`scripts/`（脚本）、`tools/bin/`（预编译二进制）、
`tools/fieldiag/`（**需先放入 fieldiag**）、`downloads/`（离线安装包）、
`logs/`（自动生成的每机日志）。

前置：把官方/OEM fieldiag 拷入 `tools/fieldiag/`（缺口，见该目录 PLACEHOLDER.txt）。

---

## 3. SOP-01 资料核对

核对采购合同、服务器/GPU SN·PN、型号显存、供应商 ATP/Burn-in 报告、fieldiag 版本与支持 SKU。

```text
PASS：SN/PN 与实物一致，报告与本批次对应，fieldiag 明确支持当前 SKU
FAIL：SN/PN 不一致
HOLD：fieldiag 无法证明支持当前 GPU / 供应商报告缺失或对不上号
```

## 4. SOP-02 外观检查

外箱、外壳、GPU 固定、PCIe/SXM 连接器、NVLink/NVSwitch、散热/冷板/液冷管路、封签与 SN。

```text
PASS：无撞击/变形/烧蚀/渗液/接口损伤，封签标签正常
FAIL：PCB 损伤 / 金手指或连接器损伤 / 冷板或液冷渗液 / SN 无法识别
```

## 5. SOP-03 从 U 盘启动并挂载

```bash
# 1) UEFI 选 USB 启动，进默认 “fieldiag mode”
# 2) 挂载数据分区
sudo mkdir -p /mnt/gpu_acceptance
sudo mount -L GPU_DATA /mnt/gpu_acceptance      # 或 sudo bash <盘>/scripts/mount_gpu_data.sh
cd /mnt/gpu_acceptance/GPU_Offline_Acceptance
lsblk -f | grep writable                        # 确认持久层 ext4 label=writable（已预格式化）
```

```text
PASS：可从 U 盘启动、无死机黑屏，能挂载 GPU_DATA 看到 INDEX.md/scripts/tools
HOLD：无法从 U 盘启动
FAIL：启动中死机或 BIOS 报硬件错误
```

说明：持久分区已在制盘阶段格式化，`init_persistence_partition.sh` 会报
“no unformatted persistence partition found”，属正常，无需处理。

---

## 6. A 线 —— fieldiag 硬件主验收（默认模式，驱动被屏蔽）

fieldiag 是本 SOP 的硬件验收主标准。此模式下 NVIDIA/nouveau 驱动被 grub 屏蔽。

### 6.1 确认驱动未加载

```bash
lsmod | egrep -i "nvidia|nouveau"     # 期望无输出；若有：
sudo bash scripts/set_fieldiag_driver_block.sh && sudo reboot   # 重启后重进 fieldiag mode
```

### 6.2 跑 fieldiag（一键，自动采集+落盘）

```bash
sudo bash scripts/run_acceptance.sh fieldiag
# 可执行名不同：加 FIELDIAG_BIN=/…/tools/fieldiag/<名字>
# 需要参数：加 FIELDIAG_ARGS="…"
```

该脚本会：跑 fieldiag → 采集基础信息/内核错误日志 → 写
`logs/<时间戳>_<SN>/`（含 fieldiag 原始日志、`summary.txt`、`final_result.txt` 骨架）。

```text
PASS：每张 GPU fieldiag 结果均为 PASS，日志可对应到服务器 SN 与 GPU SN
FAIL：任一 GPU FAIL；或 RETEST/CONFIG 修正环境复测一次后仍非 PASS
HOLD：fieldiag 报不支持当前 SKU（记录版本与 SKU，可能需 OEM 专版）
```

---

## 7. B 线 —— 系统 / 压力 / 性能（dcgm 模式，驱动放行）

重启，grub 选 **dcgm mode**，重新 `mount -L GPU_DATA …`，`cd $ROOT`。

### 7.1 离线安装驱动 + DCGM + Fabric Manager

```bash
sudo bash scripts/install_offline_nvidia_tools.sh
nvidia-smi -L                          # 数量/型号/显存正确；数量==采购数
```

### 7.2 离线安装 CUDA 运行时 + NCCL（跑 tools/bin 二进制所需）

```bash
sudo bash scripts/install_offline_cuda_runtime.sh
ldd tools/bin/all_reduce_perf | grep "not found"   # 期望：除驱动 libcuda 外无 not found
```

### 7.3 基础信息 / GPU 识别 / 错误日志（run_acceptance 会自动做，也可手动核对）

```bash
tools/bin/deviceQuery | tail -5                     # 每卡 Result=PASS，compute capability 正确
nvidia-smi -q | grep -i -A20 "ECC"                  # SOP-ECC
nvidia-smi topo -m                                  # SOP-拓扑
dmesg -T | egrep -i "xid|fallen|ecc|pcie|aer|nvlink|reset"   # 期望无硬错误
```

硬性 FAIL（出现即判）：少卡/掉卡、型号或显存不符、XID、fallen off the bus、
uncorrectable ECC、GPU reset、PCIe fatal、NVLink fatal。

### 7.4 性能与压力（带宽 / 互联 / 集合通信 / DCGM）

```bash
tools/bin/nvbandwidth                                        # HBM/链路带宽
tools/bin/all_reduce_perf -b 8 -e 8G -f 2 -g <GPU数>          # 多卡；#wrong 必须全 0
sudo bash scripts/run_acceptance.sh dcgm                      # 含 dcgmi diag -r 3 -j + 全量采集
```

阈值对照 `acceptance_criteria.md`：H200 HBM PASS ≥ 4.3TB/s（RETEST 4.1~4.3）；
B300/GB300 按 OEM 单卡 X 的 90%/85%；功耗达 power limit 85%~95%；DCGM r3 全 PASS。

若极少数情况下预编译二进制无法在真卡执行，可现场离线重编：

```bash
sudo dpkg -i downloads/offline_deb_noble/rebuild/*.deb
sudo bash scripts/build_official_stress_tools.sh
```

### 7.5 压力时长（见 acceptance_criteria.md §11）

```text
最低验收：fieldiag 跑完 + DCGM r3 + 30 分钟压力监控
正式验收：fieldiag 跑完 + DCGM r3 + 2 小时压力监控
高风险/二手/可疑批次：8 小时老化
```

---

## 7bis. 阶段二 —— 甲方《验收标准》逐项自动判定（dcgm 模式）

上面 B 线的手工核对仍然有效，但阶段二把《验收标准》§1-§4 §7 §8 的每一项
做成了自动判定。**在 dcgm 模式下执行，全程需要 root。**

### 7bis.1 补装标准新增要求的工具

```bash
sudo bash scripts/install_offline_tools.sh    # ipmitool/ethtool/nvme-cli/openmpi/stressapptest
```
缺哪个，对应验收项就判 SKIP 而不是 PASS。

### 7bis.2 环境预检（必做）

```bash
sudo bash scripts/preflight.sh b300_8gpu      # H200 机型用 h200_8gpu
```

- [STOP] 报 `no kernel image available` → 预编译二进制的 fatbin 架构与本机 GPU
  不符，§3/§4/§8 的带宽与压测项全部无效。按 `docs/cuda_arch_decision.md`
  重编后再继续，**不要带着这个问题往下走**。
- 记下它打印的"实测计算能力"和"缺失工具清单"——这两条决定后续所有工作。

### 7bis.3 采集 + 自动判定

```bash
sudo bash scripts/run_acceptance.sh standard b300_8gpu
```

默认包含 §3 的 1 小时 `gpu_burn`、30 分钟系统内存压测和 `dcgmi diag -r 3`，
整轮约 2 小时。只看静态项：`SKIP_GPU_BURN=1 SKIP_DCGM=1 SYS_MEM_STRESS_SECONDS=0`。
补 Level 4：`RUN_DCGM_R4=1`（很慢）。

### 7bis.4 §7 驱动参数（改完需重启）

```bash
sudo bash scripts/set_nvidia_modprobe_params.sh b300_8gpu
```

### 7bis.5 长稳烤机（§8）

```bash
sudo bash scripts/run_acceptance.sh soak logs/<刚才的目录> b300_8gpu
```

跑完自动重新判定并把 §8 并入同一张表。日志目录必须在持久分区上。
中途被打断会如实记录实际时长并判 FAIL——被中断的长稳不构成有效证据。

### 7bis.6 读判定表

```text
logs/<时间戳>_<SN>/
  acceptance_report.html   交付甲方：浏览器打开 / 打印存 PDF / 签字
  acceptance_report.csv    Excel
  per_gpu_detail.tsv       每卡 SN/显存/功耗/温度/NVLink —— 定位掉队卡、RMA 证据链
```

判定值四态，**SKIP 不等于 PASS**：

```text
PASS    达标
FAIL    不达标 —— 任意一项 FAIL，整机 FAIL
SKIP    未执行或无法判定（工具缺失 / 主动跳过 / 阈值未定义），整机判 HOLD
MANUAL  标准要求人工核对（§2 规格项）
```

脚本退出码就是整机结论：0=PASS，1=FAIL 或 HOLD。批量验收可直接据此拦截。

### 7bis.7 同批次比对（验完一批之后）

```bash
bash scripts/compare_batch.sh logs/ b300_8gpu
```

单机判定回答不了"这台在这批里是不是明显落后"。一台每项都过绝对阈值、
但样样比同批中位数低 12% 的机器，通常是散热或供电问题——
`docs/acceptance_criteria.md` 把"低于中位数 10% 以上"列为硬性 FAIL。

---

## 8. SOP-判定与归档

```bash
# 每次 run_acceptance.sh 已在日志目录生成 final_result.txt 骨架
$EDITOR logs/<时间戳>_<SN>/final_result.txt        # 逐项填 PASS/FAIL/RETEST/HOLD
```

- 对照 `templates/machine_acceptance_checklist.csv` 核对未漏项。
- 确认原始日志完整写在 U 盘 `logs/`（持久层）、断电可追溯到 SN。
- 归档 `templates/final_result_template.txt` 生成的最终结论。

### 结论与硬性 FAIL 条件

```text
PASS  ：SOP-01~判定全部通过，性能达 PASS 线
FAIL  ：fieldiag FAIL/复测仍非 PASS、少卡/掉卡、SN/PN 不一致、
        XID、fallen off bus、GPU reset、uncorrectable ECC、PCIe/NVLink fatal、
        液冷泄漏、温度保护关机、性能低于失败线
RETEST：一次性异常或性能落入 RETEST 区间，只许复测一次
HOLD  ：资料不全 / SKU 不明 / fieldiag 版本无法确认 / 无法进入诊断环境
```

---

## 9. 每台机器最短执行路径（速查）

```bash
# —— 默认 fieldiag mode 启动后 ——
sudo mount -L GPU_DATA /mnt/gpu_acceptance && cd /mnt/gpu_acceptance/GPU_Offline_Acceptance
sudo bash scripts/run_acceptance.sh fieldiag        # 硬件主验收

# —— 重启选 dcgm mode ——
sudo mount -L GPU_DATA /mnt/gpu_acceptance && cd /mnt/gpu_acceptance/GPU_Offline_Acceptance
sudo bash scripts/install_offline_nvidia_tools.sh && sudo bash scripts/install_offline_cuda_runtime.sh
sudo bash scripts/install_offline_tools.sh
sudo bash scripts/preflight.sh b300_8gpu             # STOP: no kernel image -> 先重编
sudo bash scripts/run_acceptance.sh standard b300_8gpu
sudo bash scripts/run_acceptance.sh soak logs/<上一步的目录> b300_8gpu
# 交付物：logs/<目录>/acceptance_report.html
sudo bash scripts/install_offline_nvidia_tools.sh   # 驱动+DCGM+FM
sudo bash scripts/install_offline_cuda_runtime.sh   # CUDA运行时+NCCL
sudo bash scripts/run_acceptance.sh dcgm            # DCGM+带宽+采集

# 填结论
$EDITOR logs/<时间戳>_<SN>/final_result.txt
```
