# 验机 U 盘持久化方案说明

版本：v1.0

## 1. 什么是持久化

当前 U 盘是：

```text
Ubuntu Server LTS 启动区
+ GPU_DATA 数据区
```

它可以启动服务器，也可以保存日志和工具包，但 Ubuntu 系统本身是临时环境。

持久化的意思是：

```text
安装过的 NVIDIA driver / DCGM 不会重启后丢失
编译好的 nvbandwidth / nccl-tests / CUDA samples 不会重启后丢失
系统配置、脚本权限、依赖包、日志可以长期保留
```

## 2. 为什么需要持久化

如果不持久化，每次启动后都可能需要重新做：

```text
安装 NVIDIA driver
安装 DCGM
安装 Fabric Manager
安装编译依赖
编译 nvbandwidth
编译 nccl-tests
编译 CUDA samples
```

持久化后，可以做到：

```text
插 U 盘
从 U 盘启动
进入系统
一键运行验机脚本
```

## 3. 持久化的影响

优点：

```text
现场更快
工具不用每次重新安装
编译好的二进制可长期保留
更适合批量验机
可以做开机自动运行脚本
```

风险：

```text
U 盘写入量变大，普通 U 盘更容易损坏
突然断电或直接拔盘可能导致系统分区损坏
系统状态会积累变化，可能影响验机一致性
NVIDIA driver 自动加载后，可能影响要求无驱动环境的 fieldiag/MODS
Secure Boot 可能阻止 NVIDIA kernel module 加载
不同服务器硬件差异可能导致同一个持久系统启动表现不同
```

## 4. 对 fieldiag 的影响

这是最重要的一点：

```text
如果 fieldiag/MODS 要求 NVIDIA driver 不加载，
持久化系统里自动安装并加载 NVIDIA driver 可能会导致 fieldiag 失败或结果无效。
```

因此正式建议：

```text
先跑 fieldiag 硬件诊断
再加载/安装 NVIDIA driver
再跑 DCGM、nvbandwidth、NCCL、CUDA samples
```

如果做持久化系统，应提供两个启动模式：

```text
fieldiag 模式：禁用 NVIDIA driver 自动加载
dcgm 模式：启用 NVIDIA driver、DCGM、Fabric Manager
```

## 5. 推荐方案

### 方案 A：移动 SSD 完整安装，最推荐

结构：

```text
EFI 分区：FAT32
Ubuntu 系统分区：ext4
GPU_DATA 数据分区：exFAT
```

适合：

```text
批量验机
长期反复使用
需要安装 driver/DCGM/CUDA
需要保存编译结果
```

优点：

```text
最稳定
最像真实 Linux 系统
工具可以完整安装
适合开机自动验机
```

缺点：

```text
需要二阶段安装
最好准备第二个 U 盘作为安装介质
普通 Windows 不能直接管理 ext4
```

### 方案 B：当前单 U 盘 Live 持久化

结构：

```text
UBUNTU_BOOT：FAT32
writable：ext4
GPU_DATA：exFAT
```

适合：

```text
临时增强当前启动盘
希望保存少量系统变更
```

风险：

```text
Ubuntu Server Live ISO 的持久化支持不如完整安装稳定
后续维护麻烦
系统升级和驱动安装更容易出问题
```

不建议作为正式批量验机主方案。

### 方案 C：不持久化，只持久化工具和日志

当前 U 盘就是这个方案。

结构：

```text
UBUNTU_BOOT：只负责启动
GPU_DATA：保存工具、脚本、日志、报告
```

适合：

```text
先跑通流程
fieldiag 优先
还没确认 OEM 诊断环境要求
```

优点：

```text
干净
可追溯
不容易污染测试环境
```

缺点：

```text
DCGM/CUDA 工具每次启动后可能要重新安装或编译
不够一键化
```

## 6. 本项目建议路线

当前阶段建议：

```text
保留当前 U 盘作为干净启动盘
先放入 fieldiag
实际在 1 台机器上试跑
确认 fieldiag 是否要求无驱动环境
确认 DCGM/driver 能否正常安装
```

确认后再做：

```text
移动 SSD 完整持久化 Ubuntu 最小系统
预装 NVIDIA driver / DCGM / Fabric Manager
预编译 nvbandwidth / nccl-tests / CUDA samples
增加 fieldiag 模式和 dcgm 模式
```

## 7. 持久化后验机模式建议

模式一：硬件诊断模式

```text
不自动加载 NVIDIA driver
只跑 fieldiag/MODS
保存 fieldiag 原始日志
```

模式二：系统压力模式

```text
加载 NVIDIA driver
启动 Fabric Manager
启动 DCGM
运行 dcgmi diag -r 3
运行 nvbandwidth
运行 NCCL tests
运行 CUDA samples
```

最终验收仍以：

```text
fieldiag PASS
+ DCGM PASS
+ 性能最低线达标
+ 无 XID/ECC/掉卡/降链
```

为准。

## 8. 本 U 盘持久化落地方式

本项目采用三分区方案：

```text
UBUNTU_BOOT：FAT32，Ubuntu Server 启动区
GPU_DATA：exFAT，工具、日志、报告
PERSIST_RAW：未格式化，第一次进 Linux 后格式化为 ext4，卷标 writable
```

启动菜单默认项：

```text
GPU Acceptance - fieldiag mode, persistent, NVIDIA driver blocked
```

默认屏蔽：

```text
nvidia
nvidia_drm
nvidia_modeset
nvidia_uvm
nouveau
```

第一次启动后初始化持久化分区：

```bash
sudo mkdir -p /mnt/gpu_acceptance
sudo mount -L GPU_DATA /mnt/gpu_acceptance
cd /mnt/gpu_acceptance/GPU_Offline_Acceptance
sudo CONFIRM_FORMAT=YES bash scripts/init_persistence_partition.sh
```

然后重启，再选择默认 fieldiag 模式。

如果需要 DCGM/压测，重启时选择：

```text
GPU Acceptance - dcgm mode, persistent, NVIDIA driver allowed
```
