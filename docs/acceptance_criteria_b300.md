# 验收标准对照表 — B300 / GB300（Blackwell Ultra 8 卡节点）

版本：v2.0　　对应甲方《验收标准》第 1-8 章（文档第 23-29 页）

本文件是**标准 → 脚本 → 判定**的映射表。数值阈值不写在这里，全部在
`profiles/b300_8gpu.env`；改阈值只改 profile，本文件只记录"哪一条由谁执行、谁判定"。

## 输出长什么样

`check_node.sh` 产出的表直接对齐甲方那张表，并补上实测证据：

```text
章节 | 模块 | 测试项 | 测试手段/命令 | 实测值 | 验收标准 | 余量 | 判定 | 备注
```

前四列就是《验收标准》原表的列。**实测值一律给准确数值**，不给 yes/no：

```text
单卡显存      293120 MiB          >= 286000 MiB     +2.5%    PASS
ECC 状态确认  8/8 Enabled         全部 Enabled      —        PASS
风扇状态      12 个，转速 8000~8600 RPM，异常 0     —        PASS
拓扑验证      56/56 个 GPU 对为 NV18                —        PASS
8 GPU AllReduce  845.60 GB/s      >= 800 GB/s       +5.7%    PASS
```

**余量**是实测相对阈值的百分比裕度，正数为达标裕度，负数为越线幅度；
阈值为 0 的项（ECC/CRC）给绝对差值。它的用处是识别"刚好压线通过"的机器 ——
+1.5% 和 +40% 都算 PASS，但前者值得复测。

另出一张 `per_gpu_detail.tsv`：每张卡的 SN / UUID / VBIOS / 显存 / 功耗上限 /
温度 / 时钟 / PCIe / NVLink 活跃链路 / ECC 计数 / 持久模式。判定表给的是"最差
那张卡"，这张表用来追溯到具体是哪一张 —— 掉队卡定位、RMA 证据链、同批次比对都靠它。
NVLink 活跃链路数在卡间不一致时会额外提示。

## 阈值的来源标注

profile 里每个阈值都标了来源，改之前先看标注：

| 标注 | 含义 |
|------|------|
| `[标准]` | 甲方《验收标准》表格里的原值，不得擅改 |
| `[推导]` | 由标称规格 + 明确判据推出，注释里写清推导过程 |
| `[待校准]` | 首批机器实测后应回填的经验值，现值只保证不误判 |

举一个推导的例子（也是一个被修掉的真实盲区）：标准写"系统内存 ≥3TB"，
但 24×128GiB 满配是 3072 GiB，`free` 实际报约 3047 GiB（扣掉内核保留），
而**少一条 DIMM 是 2944 GiB**。阈值必须落在 2944 和 3047 之间才既不误判满配机器、
又能抓住掉内存 —— 取 3000。最初拍的 2900 会让少一条内存条的机器判 PASS。

旧的 `docs/acceptance_criteria.md`（v1.0，H200 散文式标准）仍然有效，
对应 `profiles/h200_8gpu.env`。

## 架构前提

```text
每节点 8 颗 GPU（Blackwell Ultra）+ 2 颗 NVSwitch4
每 GPU 18 条 NVLink 5.0（9 条接 NVSwitch#1，9 条接 NVSwitch#2）
节点内 NVLink 全互联 1.8 TB/s per GPU
节点间 8× ConnectX-8 SuperNIC（800Gb/s），合计 6.4 Tb/s per node
风冷 8U，1,100 W per GPU
```

## 两条验收链路

| 链路 | 覆盖章节 | 运行环境 | 入口 |
|------|---------|---------|------|
| **单机离线压测** | §1 §2 §3 §4 §7 §8 | U 盘 live 系统，无网 | `run_acceptance.sh standard` / `soak` |
| **多机压测** | §5 §6 | 各节点自有 OS + RoCE 组网 | `scripts/cluster/*` |

单机链路完全离线自包；多机链路需要网络、MPI 和免密 SSH，见
`docs/cluster_runbook.md`。

## 章节映射

### §1 物理与环境 — `collect_node.sh` → `check_node.sh`

| 测试项 | 命令 | profile 变量 | 自动判定 |
|--------|------|-------------|---------|
| GPU 数量 | `nvidia-smi -L \| wc -l` | `EXPECTED_GPU_COUNT` | 是 |
| 系统内存 | `free -b` | `SYS_MEM_MIN_GIB` | 是 |
| GPU 温度（压测期间） | `nvidia-smi --query-gpu=temperature.gpu` | `GPU_TEMP_MAX_C` | 是 |
| 风扇状态 | `ipmitool sensor list \| grep -i fan` | — | 是（需 ipmitool） |

> 内存阈值取 3000 GiB 而不是标准写的 3 TB（=3072 GiB）：`free` 报的是扣除内核保留
> 后的可用量，满配机器实测约 3047 GiB，按 3072 判会全线误 FAIL；但阈值也不能压太低 ——
> 少一条 128GiB DIMM 是 2944 GiB，必须落在这条线之上才能抓住掉内存。

### §2 基础配置规格 — 记录型，人工核对

品牌、CPU 型号、内存规格、系统盘、本地 NVMe 全部没有可自动判定的阈值，
脚本只提取实测值填进判定表并标 `MANUAL`，由验收人对照采购清单。

### §3 GPU 硬件验证

| 测试项 | 命令 | profile 变量 | 自动判定 |
|--------|------|-------------|---------|
| 单卡显存 | `--query-gpu=memory.total` | `GPU_MEM_MIN_MIB` | 是 |
| 节点总显存 | 上项求和 | `NODE_GPU_MEM_MIN_GIB` | 是 |
| ECC 状态 | `--query-gpu=ecc.mode.current` | `ECC_MODE_EXPECTED` | 是 |
| 不可纠正错误 | `ecc.errors.uncorrected.aggregate.total` | `ECC_UNCORRECTED_MAX` | 是 |
| 可纠正错误 | `ecc.errors.corrected.volatile.total` | `ECC_CORRECTED_MAX` | 是（增量口径） |
| TDP | `--query-gpu=power.limit` | `GPU_POWER_LIMIT_W` | 是 |
| DCGM Level 3 | `dcgmi diag -r 3 -j` | — | 是 |
| DCGM Level 4 | `dcgmi diag -r 4 -j` | — | 是（需 `RUN_DCGM_R4=1`） |
| 1 小时压测 | `gpu_burn -tc 3600` | `GPU_BURN_SHORT_SECONDS` | 是（需 gpu_burn） |
| Persistence Mode | `nvidia-smi -pm 1` 后查询 | — | 是 |
| 满载时钟 | `clocks.current.graphics` | — | 人工（见下） |
| 节流原因 | `nvidia-smi -q -d PERFORMANCE` | — | 是 |
| PCIe Gen/Width | `pcie.link.gen/width.current+max` | `PCIE_GEN` / `PCIE_WIDTH` | 是（见下） |
| H2D / D2H 带宽 | `nvbandwidth --testcase host_to_device_memcpy_ce` 等 | `NVB_H2D_MIN_GBS` | 是 |

两个口径说明：

- **可纠正错误按增量判**。标准写"18h 压测期间单卡 ≤ 2"，是窗口内增量、单卡口径。
  脚本按 GPU index 配对求差取最大值，不做求和（8 卡各 +1 不等于超标）。
- **PCIe 判 `max` 不判 `current`**。GPU 空闲时链路会主动降到 Gen1 省电，
  拿 `current` 判会误 FAIL。判定用链路能力 `pcie.link.gen.max`，
  `current` 作为备注记录；真正的降速会体现在 `max` 上。
- **满载时钟标 MANUAL**：单次采样落在空闲期就没有意义，实际以 §8 的连续采样为准。

### §4 NVLink（节点内 / Rank 内）

| 测试项 | 命令 | profile 变量 |
|--------|------|-------------|
| GPU 间带宽 | `nvbandwidth --testcase device_to_device_memcpy_read_ce` | `NVB_D2D_READ_MIN_GBS` |
| 拓扑验证 | `nvidia-smi topo -m` | `NVLINK_TOPO_TAG` |
| 链路检查 | `nvidia-smi nvlink -s -i <0-7>` | `NVLINK_LINKS_PER_GPU` |
| CRC / Replay | `nvidia-smi nvlink -e -i <0-7>` | `NVLINK_ERR_MAX` |
| P2P 带宽矩阵 | `p2pBandwidthLatencyTest` | `P2P_BW_MIN_GBS` |
| P2P 延迟 | 同上（Latency 矩阵） | `P2P_LAT_MAX_US` |
| 8 GPU AllReduce | `all_reduce_perf -b 512M -e 8G -f 2 -g 8` | `NCCL_ALLREDUCE_MIN_GBS` |
| 8 GPU AllGather | `all_gather_perf` 同参数 | `NCCL_ALLGATHER_MIN_GBS` |
| FM 状态 | `systemctl status nvidia-fabricmanager` | — |

带宽矩阵一律取**非对角最小值**（标准说"任意 GPU 对"，最差的那一对决定结论）。
NCCL 取峰值 Bus BW，均值一并记进备注。

### §5 高性能网络（RoCE v2）— 多机链路

`scripts/cluster/roce_check.sh` → `check_cluster.sh`。本机侧检查（网卡模式、
端口、PFC、MTU、DSCP、丢包）不需要对端；`ib_write_bw` / `ib_read_bw` /
`ib_send_lat` 需要 `PEER_IP=` 且对端已起 server。

PFC 与 PFC 暂停帧比例标 `MANUAL`：Enabled 的是不是 RoCE 实际走的那条 TC、
pause 帧比例怎么换算，都随交换机配置和固件版本变化，不适合硬判。

### §6 跨节点 NCCL — 多机链路

`scripts/cluster/nccl_scale.sh`，按 `CLUSTER_ALLREDUCE_SCALE` 扫 2/4/8/16 节点。
**需要 `*_perf_mpi` 二进制**（MPI=1 编译），当前工具集是 MPI=0 版本，
见 `docs/tooling_gaps.md`。hostfile 行数不足时对应规模记 SKIP，不是 PASS。

### §7 GPU 软件栈

| 测试项 | profile 变量 | 备注 |
|--------|-------------|------|
| 驱动版本 | `DRIVER_MIN_VERSION` | 节点内一致性自动判；跨节点一致性在集群阶段 |
| CUDA 版本 | `CUDA_MIN_VERSION` | 见 `docs/cuda_arch_decision.md` |
| nvidia_peermem | `REQUIRE_NVIDIA_PEERMEM` | GPUDirect RDMA 依赖 |
| FM 版本与状态 | — | 与驱动主版本比对 |
| GDRCopy | `REQUIRE_GDRCOPY` | 需 gdrcopy_sanity |
| cuda-samples 工具集 | — | `bandwidthTest` 在新版 cuda-samples 已删除 |
| 驱动参数 | `NVIDIA_MODPROBE_REQUIRED` | `scripts/set_nvidia_modprobe_params.sh` |

### §8 标准化算力基准与稳定性

`scripts/soak_node.sh`：`gpu_burn -tc <SOAK_SECONDS>` + 持续 NCCL AllReduce 循环
+ 每 60s 采样，前后各做 ECC / XID / NVLink CRC 快照，判定用**增量**。

> **标准内部不一致**：第 8 章标题写"24h 烤机"，命令写 `-tc 64800`（= 18 小时），
> §3 的 ECC 那行也写 18h。profile 默认取 64800 与命令一致。若甲方要求 24h，
> 设 `SOAK_SECONDS=86400`。**签署验收前应书面确认到底是 18h 还是 24h。**

判定用 `samples.csv`（`--query-gpu` 定长 CSV）而不是 `dmon.txt`：`nvidia-smi dmon`
的列布局随驱动版本和 `-s` 组合变化，按列号解析不可靠。`dmon.txt` 仍然采集，
作为标准点名要求的留证。

## 其它需要与甲方确认的点

1. **§5 单 NIC 460 Gb/s** 对 800 Gb/s 的 ConnectX-8 偏低，更像 400G 单口指标。
   若现场是 800G 口，这条阈值形同虚设。
2. **CUDA ≥ 13.0** 与本项目当前 12.8 工具链冲突，见 `docs/cuda_arch_decision.md`。
3. **fieldiag 未在标准中出现**。本项目仍保留 fieldiag 为阶段一硬件主标准
   （`run_acceptance.sh fieldiag`），新标准作为阶段二。
