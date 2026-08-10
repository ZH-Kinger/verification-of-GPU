# 工具缺口与离线获取方法

新标准要求的工具里，项目当前只有一部分。本文件逐个说明**缺什么、影响哪些验收项、
怎么离线拿到**。运行 `scripts/preflight.sh` 会打印本机的实际缺失清单。

工作主机（workshop host）是联网的 Ubuntu 22.04 jammy；目标机是离线 noble。
凡是 `.deb`，一律在 `docker run --rm -v $PWD:/out ubuntu:24.04` 里解析下载，
**不要在 jammy 主机上 `apt download`**（会拿到 jammy 版本）。

## 已自动化的部分

以下几项已经接进 `bootstrap.sh` + `build_official_stress_tools.sh`，
在联网工作主机上一条命令就能补齐：

```bash
bash bootstrap.sh sources offline_deb        # 抓源码 + noble deb（含新增的 tools/）
PROFILE=b300_8gpu bash scripts/build_official_stress_tools.sh
```

| 工具 | 来源 | 产出 |
|------|------|------|
| `gpu_burn` + `compare.ptx` | `gpu-burn-master.zip` | `tools/<subdir>/` |
| `bandwidthTest` | `cuda-samples-v12.3.zip`（旧版才有） | 同上 |
| `*_perf_mpi` | nccl-tests `MPI=1`，独立编译目录 | 同上 |
| `ipmitool` `ethtool` `nvme-cli` `openmpi` | docker noble 闭包 | `downloads/offline_deb_noble/tools/` |

目标机安装：`sudo bash scripts/install_offline_tools.sh`。
构建结束会打印一张"产出核对"表，缺哪个直接点名到验收章节。

两个非显然的坑，脚本已经处理，改动时不要破坏：

- **`gpu_burn` 运行时需要同目录的 `compare.ptx`**（PTX 运行时 JIT，反而对新架构
  天然兼容）。两个文件必须一起拷贝；采集脚本会先 `cd` 到二进制目录再执行。
- **`gpu_burn` 链接 cublas**，所以 `runtime/` 新增了 `libcublas-12-8`。
  本项目原先刻意不打包 CUDA 数学库，这是唯一的例外。
- **nccl-tests 的 `MPI=1` 产出文件名和 `MPI=0` 相同**，直接在同一目录编会互相
  覆盖，所以在 `nccl-tests-mpi/` 独立编译，再按标准命名加 `_mpi` 后缀。

## 仍需人工处理

### gdrcopy — 影响 §7 GDRCopy 功能

需要编内核模块（DKMS），在 live 系统上不一定装得起来。建议：
在与目标机同内核的环境里预编译好 `gdrdrv.ko` + `gdrcopy_sanity`，随包携带。
如果现场判定为不可行，这一项会记 SKIP，需与甲方确认是否豁免。

### DCGM 4.x — 影响 §3 的 DCGM Level 3 / Level 4

项目当前是 `datacenter-gpu-manager 3.3.9`，**不支持 Blackwell**，在 B300 上
`dcgmi diag` 会跳过测试项或直接报错。`profiles/b300_8gpu.env` 的
`DCGM_MIN_VERSION=4.0` 就是为此。从 NVIDIA CUDA repo 取 noble 的
`datacenter-gpu-manager-4-*` 包替换。

判定脚本对这种情况有专门处理：JSON 里没有任何 `"Pass"` 记录时判 FAIL 并注明
"DCGM 未真正执行测试"，不会因为"没有 Fail"就误判 PASS。

### `*_perf_mpi` 的分发 — 影响 §6 全部

编译已自动化（见上），但**每个节点都要有这些二进制，且路径相同**——
`mpirun` 不会替你分发。要么各节点本地复制，要么放共享存储。
`nccl_scale.sh` 会在自检阶段确认 head 节点上存在，但**不检查其它节点**，
路径不一致的表现是 mpirun 报 "No such file or directory" 而不是性能不达标。

### MFT（mlxconfig）/ DOCA-OFED（mlnx_qos）/ perftest — 影响 §5 全部

体量较大，且随网卡固件版本绑定。两种现场情况：

- **节点已装好 OS + RoCE**（多数情况）：这些工具通常随 DOCA-OFED 一起装好了，
  `roce_check.sh` 直接能用，无需本项目携带。
- **节点是裸机**：需要把 DOCA-OFED 的离线安装包（`.tgz`，数 GB）一并带上，
  并按目标内核版本选对应版本。

`roce_check.sh` 对缺失工具是**优雅降级**：写 `*_missing.txt`，判定阶段记 SKIP，
不会中断其它检查。

## 影响面速查

| 缺失工具 | 会变成 SKIP 的验收项 | 状态 |
|---------|-------------------|------|
| gpu_burn | §3 1 小时压测、§8 全部 | 已自动化 |
| ipmitool | §1 风扇状态 | 已自动化 |
| ethtool | §5 PFC 暂停帧 / 丢包 | 已自动化 |
| nvme-cli | §2 本地 NVMe 配置 | 已自动化 |
| bandwidthTest | §7 cuda-samples 工具集（判 FAIL，不是 SKIP） | 已自动化 |
| mpirun + `*_perf_mpi` | §6 全部 | 编译已自动化，分发靠人 |
| dcgmi (4.x) | §3 DCGM Level 3 / Level 4 | **待办** |
| gdrcopy_sanity | §7 GDRCopy | **待办**（需编内核模块） |
| mlxconfig / mlnx_qos / perftest | §5 网卡模式、PFC、带宽、延迟 | **待办**（多数现场自带） |

**SKIP 不等于通过。** `check_node.sh` 在有 SKIP 且无 FAIL 时判 `HOLD`，
不会给出 PASS。
