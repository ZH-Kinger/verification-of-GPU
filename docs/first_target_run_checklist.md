# 真机首跑核对清单 (First Target Run Checklist)

目的：第一次在真实 H200 / B300 / GB300 机器上验证这只 U 盘端到端可用。
按顺序做，每步记录“看到了什么”。出现 [STOP] 标记的异常先停下排查，不要继续。

前置：把 fieldiag 拷进 `tools/fieldiag/`（唯一硬缺口，见该目录 PLACEHOLDER.txt）。

约定：U 盘项目根在目标机上的路径记为
`/mnt/gpu_acceptance/GPU_Offline_Acceptance`（下称 $ROOT）。

---

## 0. 启动盘可用性

- [ ] 目标机 UEFI 引导列表里能看到 USB
- [ ] 选 USB 启动，进入 grub，能看到两个菜单项：
      - `GPU Acceptance - fieldiag mode, persistent, NVIDIA driver blocked`（默认）
      - `GPU Acceptance - dcgm mode, persistent, NVIDIA driver allowed`
- [ ] 默认项能进入系统、出现登录/shell，无死机
- 期望：进入 Ubuntu 24.04 live。
- [STOP] 无法 UEFI 启动 / grub 报错 / 卡死 → 记录机型、BIOS 版本、Secure Boot 是否开启。
        Secure Boot 可能拦截未签名内核模块，必要时在 BIOS 关闭后重试。

## 1. 挂载数据分区

```bash
sudo mkdir -p /mnt/gpu_acceptance
sudo mount -L GPU_DATA /mnt/gpu_acceptance
cd /mnt/gpu_acceptance/GPU_Offline_Acceptance
ls
```
- [ ] 能挂载，`ls` 看到 INDEX.md / scripts / tools / downloads
- [STOP] 挂不上 → `lsblk -f` 看 GPU_DATA 是否识别为 exfat（可能缺 exfat 驱动，少见）。

## 2. 持久分区确认（已预格式化，通常无需操作）

```bash
lsblk -f | grep writable
```
- [ ] 看到 sda3 / 对应分区 fstype=ext4 label=writable
- 说明：已在制盘机预格式化。`init_persistence_partition.sh` 现在会报
  “no unformatted persistence partition found”，属正常，不是错误。

---

## A 线：DCGM / 压测模式（先走这条，验证驱动 + 二进制）

> 重启选 `dcgm mode`，重新 `mount -L GPU_DATA /mnt/gpu_acceptance`，cd 回 $ROOT。

### A1. 离线安装驱动 / DCGM / Fabric Manager

```bash
sudo bash scripts/install_offline_nvidia_tools.sh
```
- [ ] 脚本结束无 fatal；`logs/offline_tool_install_*/` 里 *.exit 多为 0
- [ ] `nvidia-smi` 能出卡（数量、型号、显存正确）
- [ ] `nvidia-smi -L` 数量 == 采购数量
- [STOP] `nvidia-smi` 报 “driver/library version mismatch” 或无设备 →
        多半是驱动未正确装载 / Secure Boot 拦了 DKMS 模块。看 install 日志。
- [STOP] dpkg 报缺依赖 → 记录缺哪个包；该机基础系统可能比 live 镜像更精简。

### A2. 离线安装 CUDA 运行时 + NCCL（跑预编译二进制所需）

```bash
sudo bash scripts/install_offline_cuda_runtime.sh
ldd tools/bin/all_reduce_perf | grep -E "not found"   # 期望：只缺 libcuda 之外无 not found
```
- [ ] dpkg 成功；ldd 除 GPU 驱动库外无 “not found”
- [STOP] 仍缺 libcudart/libnccl → 确认 runtime/ 的 deb 都装上了、ldconfig 跑过。

### A3. GPU 识别 / 基本健康

```bash
tools/bin/deviceQuery | tail -5
nvidia-smi -q | grep -i -A3 "ECC Errors" | head
dmesg | egrep -i "xid|fallen|nvlink|aer|pcie" | tail
```
- [ ] deviceQuery `Result = PASS`，每张卡 compute capability 正确（H200=9.0 / B300=10.x）
- [STOP] 出现 Xid / fallen off the bus / uncorrectable ECC / PCIe fatal / NVLink fatal
        → 硬错误，按 acceptance_criteria.md 直接判 FAIL，记录卡 SN。

### A4. 带宽 / 互联 / 集合通信（性能证据）

```bash
tools/bin/nvbandwidth | tee /tmp/nvb.txt
tools/bin/all_reduce_perf -b 8 -e 8G -f 2 -g <GPU数>
```
- [ ] nvbandwidth 各项有数值、无 error；HBM/链路达到 acceptance_criteria.md 的线
      （H200 HBM PASS ≥ 4.3 TB/s；B300/GB300 按 OEM 单卡 X 的 90%/85%）
- [ ] all_reduce_perf `#wrong` 全 0，busbw 合理
- [STOP] `#wrong` 非 0 → 数据校验失败，硬问题。
- 注：若二进制无法在真卡执行（极少数 SASS 不匹配），现场可离线重编：
  `sudo dpkg -i downloads/offline_deb_noble/rebuild/*.deb` 后
  `sudo bash scripts/build_official_stress_tools.sh`。

### A5. DCGM 诊断

```bash
sudo bash scripts/run_acceptance.sh dcgm    # 内含 dcgmi diag -r 3 + 上述采集
```
- [ ] `dcgmi diag -r 3` 全 PASS
- [ ] `logs/<时间戳>_<SN>/` 生成，含 final_result.txt 骨架
- [STOP] DCGM 任一子项 FAIL → 记录项名，按标准判 RETEST/FAIL。

---

## B 线：fieldiag 模式（硬件主验收）

> 重启选默认 `fieldiag mode`（驱动被屏蔽），重新 mount、cd 回 $ROOT。

### B1. 确认驱动确实未加载

```bash
lsmod | egrep -i "nvidia|nouveau"    # 期望：无输出
```
- [ ] 无 nvidia / nouveau 模块
- 若有：`sudo bash scripts/set_fieldiag_driver_block.sh` 后重启再确认。

### B2. 跑 fieldiag

```bash
# 若可执行名不是 fieldiag，用 FIELDIAG_BIN=... 指定
sudo bash scripts/run_acceptance.sh fieldiag
```
- [ ] fieldiag 实际启动并跑完（看 `logs/<时间戳>_<SN>/fieldiag*.txt`）
- [ ] 每张 GPU 结果 PASS
- [STOP] fieldiag 报不支持当前 SKU → 记录 fieldiag 版本与 GPU SKU，可能需 OEM 专版。
- [STOP] 任一 GPU FAIL → 整机不判 PASS，记录卡 SN，进 RMA 证据链。

---

## C 线：甲方《验收标准》自动判定（阶段二，单机离线压测）

> 需要驱动，所以在 **dcgm mode** 下跑（A 线跑完可直接接着做）。
> 覆盖《验收标准》§1 §2 §3 §4 §7；§8 长稳烤机单独一步。

### C1. 环境预检（必做，先确认工具和机器对得上）

```bash
sudo bash scripts/preflight.sh b300_8gpu     # H200 机型用 h200_8gpu
```
- [ ] 实测计算能力与 profile 期望一致
- [ ] 驱动 / CUDA / DCGM 版本满足该机型下限
- [ ] 记录"缺失工具清单"（决定哪些项会判 SKIP）
- [STOP] `deviceQuery` 报 `no kernel image available` → 预编译二进制架构与本机
  GPU 不符，§3/§4/§8 的带宽与压测项全部跑不了。按
  `docs/cuda_arch_decision.md` 重编后再继续，不要带着这个问题往下走。

### C2. 采集 + 自动判定

```bash
sudo bash scripts/run_acceptance.sh standard b300_8gpu
```
- [ ] 生成 `logs/<时间戳>_<SN>/acceptance_report.txt`（逐项 实测值/阈值/判定）
- [ ] FAIL 数为 0
- [ ] SKIP 项逐个确认原因（工具缺失 or 主动跳过），记进结论
- [STOP] 出现 FAIL → 按判定表的"实测值 vs 阈值"定位，不要只看汇总。

> 默认会跑 §3 的 1 小时 `gpu_burn` 和 `dcgmi diag -r 3`，整轮约 1.5-2 小时。
> 只想先看静态项：`SKIP_GPU_BURN=1 SKIP_DCGM=1`。
> 补 Level 4：`RUN_DCGM_R4=1`（很慢）。

### C3. 驱动参数（§7 要求，改完需重启）

```bash
sudo bash scripts/set_nvidia_modprobe_params.sh b300_8gpu
```
- [ ] `NVreg_EnableStreamMemOPs=1` 与 `PeerMappingOverride=1` 均已写入
- [ ] 重启后 `cat /proc/driver/nvidia/params` 确认生效

### C4. 长稳烤机（§8，18h/24h）

```bash
sudo bash scripts/run_acceptance.sh soak logs/<时间戳>_<SN> b300_8gpu
```
- [ ] 日志目录在持久分区上（十几小时的采样，别落 tmpfs）
- [ ] 跑完自动重新判定，§8 结果并入同一张表
- [ ] ECC / XID / NVLink CRC 增量均为 0（或在阈值内）
- [ ] 温度峰值 ≤ 86°C，单卡波动 ≤ 5°C
- [STOP] 中途掉卡、XID、不可纠正 ECC → 立即停，保留全部日志

---

## 3. 结论与归档

- [ ] 打开 `logs/<时间戳>_<SN>/final_result.txt`，逐项填 PASS/FAIL/RETEST/HOLD
- [ ] 附上 `acceptance_report.txt`（阶段二的逐项判定表）
- [ ] 对照 `templates/machine_acceptance_checklist.csv` 核对未漏项
- [ ] 确认日志写在持久分区/ U 盘，断电后仍在
- [ ] 整机结论：任一张卡不达标 → 整机不 PASS
- [ ] **有 SKIP 项时不得直接判 PASS**——判定表会给 HOLD，需说明每个 SKIP 的处置

## 首跑特别关注（这是第一次在真机上验证这只盘）

```text
[ ] U 盘在该机型 UEFI 下能否启动（Secure Boot 行为）
[ ] 驱动 610/DKMS 能否在该内核版本编译加载
[ ] 离线 deb 在该机基础系统上是否还缺包（记录任何缺失，回制盘机补）
[ ] 预编译二进制能否在真卡直接执行（deviceQuery 的实测计算能力是多少？
    如果不是 profile 期望的 10.3，回制盘机按实测值重编，见 cuda_arch_decision.md）
[ ] DCGM 版本是否真的认识这块卡（diag 有没有真正执行，而不是"没有 Fail"）
[ ] 整轮日志是否完整落盘、可追溯到 GPU SN
```

**首跑最该带回来的一条信息**：`preflight.sh` 打印的实测计算能力和缺失工具清单。
这两项决定了要不要重编、要补哪些离线包，是后续所有工作的输入。
把以上任何“与预期不符”的点记下来反馈，用于固化脚本默认值（如 FIELDIAG_ARGS）。
