# Ubuntu Server LTS 最小验机 U 盘制作说明

版本：v1.0

## 1. 当前选择

系统底座：

```text
Ubuntu Server 24.04.4 LTS
```

原因：

```text
LTS 版本稳定
比 26.04 更新风险低
NVIDIA Ubuntu 24.04 官方仓库工具更完整
Server ISO 比 Desktop ISO 小，适合最小验机环境
```

## 2. 本方案是什么

本方案制作的是：

```text
单 U 盘 Ubuntu Server LTS 启动盘
+ 同盘 GPU_DATA 数据区
+ 离线 SOP、脚本、fieldiag、NVIDIA 工具、日志目录
```

它用于现场启动裸金属服务器，进入 Ubuntu Server 安装/诊断环境后执行验机脚本。

## 3. 本方案不是什么

它不是已经完整安装好的持久化 Ubuntu 系统。

完整安装到 U 盘需要二阶段操作：

```text
从一个安装介质启动
把 Ubuntu Server Minimal 安装到另一个 U 盘或移动硬盘
再把 GPU_DATA 数据区挂载进去
```

单 U 盘同时作为安装源和安装目标，通常不可直接完成完整安装。

## 4. 推荐分区

```text
Partition 1：UBUNTU_BOOT
格式：FAT32
大小：8GB
用途：UEFI 启动，存放 Ubuntu Server ISO 解包内容

Partition 2：GPU_DATA
格式：exFAT
大小：剩余空间
用途：验机项目包、工具、日志、报告、库存清单
```

## 5. 制作前置条件

```text
Windows 管理员权限
U 盘盘符确认，例如 F:
Ubuntu Server 24.04.4 LTS ISO 已下载并 SHA256 校验通过
确认允许清空/格式化目标 U 盘
```

校验下载：

```powershell
.\scripts\verify_downloads.ps1 -DownloadRoot ".\staging\downloads"
```

## 6. 制作命令

在 PowerShell 管理员窗口中执行：

```powershell
cd "C:\Users\asus\Documents\The verify of GPU"
.\scripts\prepare_single_usb_minimal.ps1 `
  -UsbDriveLetter F `
  -IsoPath ".\staging\downloads\iso\ubuntu-24.04.4-live-server-amd64.iso" `
  -ProjectSource "." `
  -Force
```

持久化 + 默认屏蔽 NVIDIA driver 的三分区制作命令：

```powershell
.\scripts\prepare_single_usb_minimal.ps1 `
  -UsbDiskNumber 2 `
  -IsoPath ".\staging\downloads\iso\ubuntu-24.04.4-live-server-amd64.iso" `
  -ProjectSource "." `
  -CreatePersistencePartition `
  -DataPartitionSizeGB 32 `
  -Force
```

## 7. 制作后 U 盘结构

Windows 下应能看到两个卷：

```text
UBUNTU_BOOT：启动区
GPU_DATA：数据区
```

`GPU_DATA` 内：

```text
GPU_Offline_Acceptance/
  docs/
  templates/
  scripts/
  tools/
  logs/
  reports/
  inventory/
  downloads/
```

如果启用了持久化，还会有第三个未格式化分区。第一次进 Linux 后运行：

```bash
sudo mount -L GPU_DATA /mnt/gpu_acceptance
cd /mnt/gpu_acceptance/GPU_Offline_Acceptance
sudo CONFIRM_FORMAT=YES bash scripts/init_persistence_partition.sh
```

重启后默认进入：

```text
GPU Acceptance - fieldiag mode, persistent, NVIDIA driver blocked
```

## 8. 现场启动

```text
插入 U 盘
接显示器和 USB 键盘
开机进 Boot Menu
选择 UEFI: USB
进入 Ubuntu Server 启动环境
```

重要警告：

```text
不要把 Ubuntu 安装到待验服务器本地硬盘，除非这是明确的装机任务。
本项目目标是验机，不是给裸金属写入生产系统。
进入安装界面后优先使用 shell/诊断环境执行验机脚本。
```

进入 shell 后，查找数据区：

```bash
lsblk -f
sudo mkdir -p /mnt/gpu_acceptance
sudo mount /dev/<GPU_DATA分区> /mnt/gpu_acceptance
cd /mnt/gpu_acceptance/GPU_Offline_Acceptance
bash scripts/offline_gpu_acceptance_collect.sh
```

也可以使用项目内挂载脚本：

```bash
sudo bash /path/to/GPU_Offline_Acceptance/scripts/mount_gpu_data.sh
cd /mnt/gpu_acceptance/GPU_Offline_Acceptance
bash scripts/offline_gpu_acceptance_collect.sh
```

## 9. 后续增强

后续可以继续做：

```text
自动挂载 GPU_DATA
开机自动执行验机脚本
fieldiag 参数模板
最终报告自动生成
```

## 10. 离线 NVIDIA 工具安装

如果启动环境允许安装驱动和 deb 包，可执行：

```bash
cd /mnt/gpu_acceptance/GPU_Offline_Acceptance
sudo bash scripts/install_offline_nvidia_tools.sh
```

安装脚本会优先寻找：

```text
downloads/nvidia/NVIDIA-Linux-x86_64-610.43.02.run
downloads/nvidia/cuda-keyring_1.1-1_all.deb
downloads/nvidia/cuda-compat-13-3_610.43.02-1ubuntu1_amd64.deb
downloads/nvidia/nvidia-fabricmanager_610.43.02-1ubuntu1_amd64.deb
downloads/nvidia/datacenter-gpu-manager_3.3.9_amd64.deb
downloads/nvidia/datacenter-gpu-manager-exporter_4.8.2-1_amd64.deb
```

注意：

```text
fieldiag/MODS 可能要求 NVIDIA driver 不加载。
如果 OEM 文档要求无驱动环境，先跑 fieldiag，再安装 driver/DCGM 做补充测试。
```

## 11. 完整持久化最小系统方案

如果现场需要一支“开机即进入完整 Ubuntu 系统”的 U 盘，推荐改用移动 SSD 或第二支 U 盘做二阶段安装：

```text
U 盘 A：Ubuntu Server 安装盘
U 盘 B / 移动 SSD：安装目标盘
```

安装选择：

```text
Ubuntu Server
Minimal installation / minimized profile
不安装生产业务软件
安装 openssh-server 可选
安装完成后再复制 GPU_Offline_Acceptance 到数据分区
```

单 U 盘同时作为安装源和安装目标风险较高，不建议作为批量验机标准流程。
