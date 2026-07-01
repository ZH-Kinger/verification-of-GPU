# 单 U 盘离线验机启动盘结构设计

版本：v1.0

适用场景：只有一个 U 盘，需要同时承担启动系统、保存工具、运行脚本、留存验机日志。

## 1. 设计原则

单盘必须同时满足：

```text
可 UEFI 启动
可离线运行 Linux 诊断环境
可保存 fieldiag / DCGM / nvbandwidth / NCCL 原始日志
日志可被 Windows 笔记本读取
工具和日志分离，避免误删系统文件
```

重要限制：

```text
制作真正启动盘通常会格式化 U 盘。
fieldiag 工具版本必须匹配目标 GPU SKU。
如果 fieldiag 要求专用环境或禁止 NVIDIA driver，必须按 OEM 文档执行。
```

## 2. 推荐分区方案

推荐容量：128GB 或更大。

```text
Partition 1：EFI_BOOT
大小：1GB
格式：FAT32
用途：UEFI 启动文件

Partition 2：DIAG_ROOT
大小：40GB - 80GB
格式：ext4
用途：Linux 诊断系统、NVIDIA driver、CUDA、DCGM、系统依赖

Partition 3：GPU_DATA
大小：剩余全部空间
格式：exFAT
用途：fieldiag 工具包、SOP 文档、脚本、验机日志
```

为什么 `GPU_DATA` 用 exFAT：

```text
Windows 可直接读取
Linux 可挂载读写
适合保存大日志和工具包
比 FAT32 更适合大文件
```

## 3. 单盘目录结构

`GPU_DATA` 分区根目录建议：

```text
/GPU_Offline_Acceptance/
  README.md
  PROJECT_PLAN.md
  docs/
    offline_gpu_acceptance_sop.md
    acceptance_criteria.md
    single_usb_boot_disk_design.md
  templates/
    final_result_template.txt
    machine_acceptance_checklist.csv
  scripts/
    offline_gpu_acceptance_collect.sh
  tools/
    fieldiag/
    dcgm/
    nvbandwidth/
    nccl-tests/
    nvidia-driver/
    cuda/
  logs/
    YYYY-MM-DD_SERVER-SN/
  reports/
  inventory/
```

说明：

```text
tools/ 放离线工具，不放日志。
logs/ 放每台机器原始日志。
reports/ 放汇总后的验收结果。
inventory/ 放采购清单、SN/PN 清单、供应商 ATP 报告。
```

## 4. Linux 系统挂载策略

Linux 启动后应自动挂载 `GPU_DATA` 到：

```text
/mnt/gpu_acceptance
```

脚本路径：

```text
/mnt/gpu_acceptance/GPU_Offline_Acceptance/scripts/offline_gpu_acceptance_collect.sh
```

日志路径：

```text
/mnt/gpu_acceptance/GPU_Offline_Acceptance/logs/
```

工具路径：

```text
/mnt/gpu_acceptance/GPU_Offline_Acceptance/tools/
```

## 5. 启动后自动验机策略

推荐两种模式。

### 5.1 手动模式

适合首批验证。

操作：

```bash
mount | grep gpu_acceptance
cd /mnt/gpu_acceptance/GPU_Offline_Acceptance
bash scripts/offline_gpu_acceptance_collect.sh
```

### 5.2 自动模式

适合批量验收。

Linux 启动后自动执行：

```bash
/mnt/gpu_acceptance/GPU_Offline_Acceptance/scripts/offline_gpu_acceptance_collect.sh
```

自动模式要求：

```text
BIOS 已能从 U 盘启动
GPU_DATA 分区能自动挂载
fieldiag 路径固定
日志路径可写
脚本跑完后在屏幕显示 PASS/REVIEW 提示
```

## 6. fieldiag 放置标准

建议路径：

```text
/mnt/gpu_acceptance/GPU_Offline_Acceptance/tools/fieldiag/
```

要求：

```text
保留原始压缩包
保留解压后的可执行文件
保留 README / release notes / supported SKU 清单
记录工具版本和 hash
```

如果 `fieldiag` 可执行文件名不是 `fieldiag`，运行脚本时可设置：

```bash
FIELDIAG_BIN=/mnt/gpu_acceptance/GPU_Offline_Acceptance/tools/fieldiag/实际文件名 \
bash scripts/offline_gpu_acceptance_collect.sh
```

## 7. 日志命名标准

每台机器一个目录：

```text
logs/YYYY-MM-DD_HHMMSS_SERVER-SN/
```

目录内至少包含：

```text
session.txt
system_info.txt
lspci.txt
gpu_lspci.txt
nvidia_smi_L.txt
nvidia_smi_q.txt
nvidia_smi_topo.txt
dmesg_full.txt
dmesg_gpu_error.txt
fieldiag_stdout.txt
fieldiag.log
dcgm_diag_r3_json.txt
nvbandwidth.txt
summary.txt
final_result.txt
```

## 8. 单盘制作方式选择

### 8.1 OEM 诊断镜像，推荐

适合：

```text
供应商提供 H200/B300/GB300 专用诊断 ISO
fieldiag/MODS 已内置或明确兼容
```

优点：

```text
最接近原厂验收环境
fieldiag 兼容风险最低
```

### 8.2 完整 Linux 安装到 U 盘

适合：

```text
需要长期维护一支专用验机 U 盘
需要安装 NVIDIA driver、DCGM、工具包
需要稳定保存日志
```

优点：

```text
可持久化安装工具和依赖
日志保存最稳定
可做自动启动脚本
```

限制：

```text
完整安装通常需要第二个启动介质或虚拟机。
单 U 盘同时作为安装源和安装目标不稳定，不建议批量验机采用。
```

### 8.3 Live ISO + 持久化

适合：

```text
临时验机
工具依赖较少
不需要复杂驱动定制
```

风险：

```text
NVIDIA driver、kernel module、fieldiag 兼容性更容易出问题
```

## 9. 正式制作前确认项

制作启动盘前必须确认：

```text
是否允许清空/格式化目标 U 盘
U 盘盘符是否为 F:\
U 盘容量是否 >= 128GB
使用 OEM 诊断 ISO 还是标准 Linux ISO
fieldiag 是否已有对应 SKU 版本
Secure Boot 是否需要关闭
目标服务器是否支持 UEFI USB 启动
```

## 10. 单盘验收成功标准

这支 U 盘本身制作完成后，必须通过：

```text
1. 可在目标服务器上 UEFI 启动
2. 可进入 Linux 诊断环境
3. 可挂载 GPU_DATA 分区
4. 可执行 offline_gpu_acceptance_collect.sh
5. 可运行 fieldiag 或明确记录 fieldiag 环境缺失原因
6. 可保存日志到 GPU_DATA/logs
7. 拔回 Windows 笔记本后可读取日志
```
