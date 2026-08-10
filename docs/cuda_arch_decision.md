# CUDA 版本与 GPU 架构决策记录

## 问题

甲方《验收标准》§7 要求 `nvcc --version` ≥ **13.0**。
本项目整条链路目前是 **CUDA 12.8**：

```text
tools/bin/*                  用 CUDA 12.8 编译，fatbin 目标 sm_90 + sm_100
downloads/.../runtime/       cuda-cudart-12-8 -> libcudart.so.12
                             libnccl2 2.30.7+cuda12.9（选它是为了统一到 libcudart.so.12）
downloads/.../rebuild/       nvcc 12.8 + 完整依赖闭包
```

两个层面的冲突：

1. **合规层面**：`nvcc --version` 报 12.8，§7 那一条直接判 FAIL。
2. **能否运行**：Blackwell Ultra（B300/GB300）的计算能力预期是 **10.3**。
   CUDA 12.8 不认识 `sm_103`，只能编到 `sm_100`。而 sm_100 的 cubin
   **不能**直接在 sm_103 上加载——除非二进制里嵌了 PTX 且允许 JIT。
   如果没有，现场会直接报 `no kernel image is available for execution on the device`，
   §3/§4/§8 里所有依赖 `nvbandwidth` / `nccl-tests` / `deviceQuery` /
   `p2pBandwidthLatencyTest` 的项**全部跑不了**。

第 2 点是推断，不是实测结论——项目里没有 B300 可以验证。因此采取的策略是
**先预检、后重编**。

## 决策（2026-08-10）

**先做脚本和判定，加一个环境预检项确认实际计算能力后再重编。**

理由：重编需要联网主机拉 CUDA 13 工具链、重做 NCCL/cudart 版本对齐、
重新生成 `tools/bin_MANIFEST.sha256` 和整个 `rebuild/` 依赖闭包，周期长；
而在拿到一台真机跑 `deviceQuery` 之前，无法确认到底该编哪个架构。

## 预检怎么做

```bash
sudo bash scripts/preflight.sh b300_8gpu
```

它会：

1. 跑 `deviceQuery`，打印实测 `CUDA Capability`，写入 `compute_capability.txt`；
2. `deviceQuery` 若报 `no kernel image` → 判定为**阻断项**，明确提示必须重编；
3. 比对驱动 / CUDA / DCGM 版本与 profile 的下限，不满足的给出警告；
4. 列出《验收标准》各章所需工具的在位情况。

## 确认是 sm_103 之后要做什么

按顺序：

1. 工作主机装 **CUDA 13.x** 工具链。
2. 重编全部工具，架构取 `profiles/b300_8gpu.env` 的 `CUDA_ARCH_LIST="90;100;103"`：
   ```bash
   CUDA_ARCH="90;100;103" bash scripts/build_official_stress_tools.sh
   ```
   nccl-tests 对应 `NVCC_GENCODE="-gencode=arch=compute_90,code=sm_90 \
   -gencode=arch=compute_100,code=sm_100 -gencode=arch=compute_103,code=sm_103"`。
   建议同时保留 PTX（`code=compute_103`），给未来的新架构留 JIT 退路。
3. 换 runtime deb：`cuda-cudart-13-x` + **cuda13 构建的 libnccl2**（≥ 2.30，
   `NCCL_MIN_VERSION`）。**cudart 主版本必须和二进制链接的一致**，
   混用 12/13 会在 `dlopen` 阶段失败。
4. 重做 `rebuild/` 依赖闭包（nvcc 13 + 完整闭包），在断网的
   `ubuntu:24.04` 容器里验证能 `dpkg -i` 干净装上。
5. 新二进制放到 `tools/bin_cuda13_sm90-100-103/`（profile 的 `TOOLS_BIN_SUBDIR`
   已指向这里），**不要覆盖现有 `tools/bin/`**——那套是 H200 profile 在用的。
6. 重新生成 `tools/bin_MANIFEST.sha256` 和
   `downloads/offline_deb_noble/MANIFEST.sha256`。

## 为什么不能只靠 cuda-compat

`downloads/nvidia/cuda-compat-13-3_*.deb` 解决的是"新 CUDA 应用跑在旧驱动上"，
不改变 `nvcc` 的版本，也不会给二进制补上缺失的目标架构码。这两个问题它都解决不了。

## 一卡一套：profile 就是版本矩阵

不同 GPU 型号绑定不同的驱动 / CUDA / NCCL / DCGM 版本和二进制集，
全部写在 profile 里，脚本不硬编码：

| profile | 驱动 | CUDA | DCGM | 架构 | 二进制目录 |
|---------|------|------|------|------|-----------|
| `b300_8gpu` | ≥ 580.105 | ≥ 13.0 | ≥ 4.0 | 90;100;103 | `tools/bin_cuda13_sm90-100-103/` |
| `h200_8gpu` | ≥ 550.54 | ≥ 12.4 | ≥ 3.3 | 90 | `tools/bin/` |

新增机型 = 新增一个 `profiles/<name>.env`，不改任何脚本。
