# GPU Offline Acceptance Project Plan

版本：v1.0

## 目标

建立一套可在无网络、无预装系统、无管理口裸金属机器上执行的 GPU 离线验收标准和工具包。

## 当前阶段

Phase 1：验收标准与 SOP 草案。

已完成：

```text
离线单机 GPU 验收 SOP
最低性能通过线
fieldiag 判定标准
现场验收模板
离线日志采集脚本草案
单 U 盘启动盘结构设计
Ubuntu Server LTS 最小启动盘制作脚本
```

## 里程碑

### Phase 1：标准文件

交付物：

```text
docs/offline_gpu_acceptance_sop.md
docs/acceptance_criteria.md
docs/single_usb_boot_disk_design.md
docs/minimal_usb_build_runbook.md
templates/final_result_template.txt
templates/machine_acceptance_checklist.csv
```

验收条件：

```text
H200 通过线、复测线、失败线明确
B300/GB300 通过线公式明确
fieldiag/DCGM/带宽/拓扑/ECC 判定关系明确
```

### Phase 2：U 盘验机包

交付物：

```text
单盘可启动 Linux 诊断 U 盘
fieldiag 工具目录
DCGM / nvbandwidth / nccl-tests 工具目录
自动采集脚本
日志目录结构
```

验收条件：

```text
U 盘可在目标服务器上启动
无需联网即可运行诊断
日志可自动保存到 U 盘
```

### Phase 3：小批量试运行

范围：

```text
选择 1-2 台 H200 机器
选择 1 台 B300/GB300 机器，如有
完整跑一轮 SOP
```

验收条件：

```text
日志完整
脚本可用
fieldiag 结果可追溯到 GPU SN
性能阈值能落地判断 PASS/RETEST/FAIL
```

### Phase 4：正式批量验收

范围：

```text
按批次执行离线验收
每台机器生成 final_result.txt
汇总 PASS/FAIL/RETEST/HOLD
```

验收条件：

```text
每台机器都有完整日志目录
每台机器都有最终结论
异常机器有复测记录
失败机器有拒收/RMA 证据链
```

## 需要补齐的信息

```text
实际 H200 机器品牌和型号
B300/GB300 的准确 SKU 和 OEM datasheet
每台机器 GPU 数量
服务器 PCIe/NVLink 拓扑图
fieldiag 工具版本和支持 SKU 清单
是否有 OEM 专用诊断镜像
现场是否可带便携显示器和键盘
是否允许格式化 F:\ U 盘
Linux/OEM 诊断 ISO 路径
```

## 当前默认标准

```text
H200 HBM 带宽 PASS：>= 4.3 TB/s
H200 HBM 带宽 RETEST：>= 4.1 TB/s 且 < 4.3 TB/s
H200 HBM 带宽 FAIL：< 4.1 TB/s

B300/GB300 使用 OEM 单 GPU 带宽 X：
PASS：>= X * 90%
RETEST：>= X * 85% 且 < X * 90%
FAIL：< X * 85%
```

## 决策记录

```text
fieldiag 作为硬件验收主标准。
DCGM 作为系统集成和压力补充标准。
nvbandwidth / NCCL 作为带宽和多 GPU 互联性能证据。
任意单张 GPU 不达标，整机不判 PASS。
```
