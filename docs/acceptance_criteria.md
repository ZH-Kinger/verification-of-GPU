# GPU 验收通过标准与最低性能线

版本：v1.0

## 1. 判定优先级

验收依据优先级：

```text
1. 采购合同、SN/PN 清单、OEM ATP / Burn-in 报告
2. 对应 SKU 的 NVIDIA/OEM fieldiag 结果
3. DCGM Diagnostics 现场离线测试结果
4. nvidia-smi、PCIe/NVLink、ECC、温度、功耗、带宽日志
5. 同批次性能基线
```

## 2. 总体通过条件

机器必须同时满足：

```text
fieldiag PASS
+ 无硬件错误
+ 压力测试稳定
+ 最低性能线达标
+ 同批次无明显掉队
+ 日志完整
```

## 3. 硬性 FAIL 条件

压力测试期间出现任意一项，直接不通过：

```text
fieldiag FAIL
fieldiag RETEST/CONFIG 后复测仍非 PASS
XID error
GPU fallen off the bus
GPU reset
uncorrectable ECC
corrected ECC 持续增长
PCIe fatal error
PCIe 降宽或降速且复测仍存在
NVLink 缺链、降链或 fatal error
温度保护关机
持续 thermal throttle
显存带宽低于失败线
同批次性能低于中位数 10% 以上
SN/PN 与采购清单不一致
```

## 4. fieldiag 标准

`fieldiag` 是硬件验收主标准。

```text
PASS：硬件诊断通过
FAIL：硬件诊断失败，整机 FAIL
RETEST：修正测试环境后允许复测一次
CONFIG：SKU/配置/环境异常，不能判 PASS
```

正式标准：

```text
每张 GPU 必须使用对应 SKU 的官方或 OEM fieldiag 完成测试。
每张 GPU 的结果必须为 PASS。
任意一张 GPU 非 PASS，整机不得判定为 PASS。
```

## 5. H200 最低性能标准

NVIDIA 官方 H200 规格：141GB HBM3e，4.8TB/s 显存带宽。

### 5.1 HBM 显存容量

```text
通过：nvidia-smi 显示约 141GB 级别，或 >= 140GB
失败：显存容量明显低于采购规格
```

### 5.2 HBM 显存带宽

以 `nvbandwidth`、DCGM memory_bandwidth 或 OEM 指定工具结果为准。

```text
PASS：>= 4.3 TB/s
RETEST：>= 4.1 TB/s 且 < 4.3 TB/s
FAIL：< 4.1 TB/s
```

说明：

```text
4.3 TB/s 约等于官方 4.8 TB/s 的 90%。
4.1 TB/s 约等于官方 4.8 TB/s 的 85%。
如果 OEM 对具体平台给出更严格数值，以 OEM ATP 为准。
```

### 5.3 压力负载

```text
GPU utilization：压力阶段稳定 >= 95%
Power：平均功耗达到 power limit 的 85%-95% 区间
Throttle：不得持续 thermal throttle
ECC：uncorrectable ECC = 0，corrected ECC 不持续增长
XID：0
```

### 5.4 同批次偏差

同型号、同配置、同 BIOS/驱动版本下：

```text
PASS：单卡关键性能 >= 同批次中位数的 95%
RETEST：单卡关键性能 >= 同批次中位数的 90% 且 < 95%
FAIL：单卡关键性能 < 同批次中位数的 90%
```

关键性能至少包括：

```text
HBM bandwidth
DCGM diagnostic throughput
NVLink bandwidth，如适用
NCCL all_reduce bandwidth，如多 GPU 适用
```

## 6. B300 / GB300 最低性能标准

如果采购对象是 GB300 NVL72 或 Blackwell Ultra 平台，官方整柜 GPU memory bandwidth 标称最高 576TB/s / 72 GPU，折算约 8TB/s 每 GPU。

如没有更详细 OEM 单卡指标，可先采用：

```text
单 GPU HBM 带宽 PASS：>= 7.2 TB/s
单 GPU HBM 带宽 RETEST：>= 6.8 TB/s 且 < 7.2 TB/s
单 GPU HBM 带宽 FAIL：< 6.8 TB/s
```

如果供应商/OEM datasheet 给出单 GPU 官方带宽 `X TB/s`，则按以下标准：

```text
PASS：>= X * 90%
RETEST：>= X * 85% 且 < X * 90%
FAIL：< X * 85%
```

注意：

```text
B300/GB300 具体形态可能是单 GPU、节点、整柜或 NVL72 平台。
最终阈值必须绑定到实际 OEM SKU、服务器型号、散热形态和 power limit。
```

## 7. PCIe 标准

以服务器平台规格为准。

```text
PASS：链路宽度和速率符合平台规格
RETEST：偶发降速，重插/换槽/重启后恢复
FAIL：复测后仍降宽、降速或出现 fatal error
```

例：

```text
合同/OEM 标称 Gen5 x16，则不得长期降为 x8/x4。
合同/OEM 标称 Gen4 x16，则不得长期降为 x8/x4。
```

## 8. NVLink / NVSwitch 标准

适用于 SXM、NVL、HGX、GB300 等平台。

```text
PASS：链路数量、拓扑、带宽符合 OEM 拓扑图
RETEST：链路异常但重插/重启后恢复且日志无 fatal
FAIL：缺链、降链、NVLink fatal error 或带宽低于失败线
```

性能标准：

```text
PASS：NVLink/互联带宽 >= OEM 标称或同批次中位数的 90%
RETEST：>= 85% 且 < 90%
FAIL：< 85%
```

## 9. 温度和功耗标准

压力测试期间：

```text
PASS：无温度保护关机，无持续 thermal throttle
RETEST：出现短时 throttle，但性能不低于最低线，复测确认
FAIL：持续 throttle、降频导致性能低于最低线、温度保护关机
```

功耗：

```text
PASS：压力阶段平均功耗达到 power limit 的 85%-95% 区间
RETEST：功耗低于 85%，但性能接近通过线
FAIL：功耗长期过低且性能不达标，或 power brake 持续触发
```

## 10. DCGM 标准

如 U 盘诊断系统支持 DCGM：

```bash
dcgmi diag -r 3 -j
```

通过：

```text
dcgm_r3 全部 PASS
pcie、memory、memory_bandwidth、diagnostic、targeted_power、targeted_stress 无失败
```

高风险批次、二手机、异常机建议：

```bash
dcgmi diag -r 4 -j
```

判定：

```text
PASS：r3 全部 PASS
RETEST：单次 FAIL 且怀疑环境问题，修正后复测一次
FAIL：复测仍 FAIL
```

## 11. 测试时长标准

```text
最低验收：fieldiag 完整跑完 + DCGM r3 + 30 分钟压力监控
正式验收：fieldiag 完整跑完 + DCGM r3 + 2 小时压力监控
高风险/二手/可疑批次：8 小时老化
```

## 12. 最终结论

```text
PASS：全部硬性项通过，性能达到 PASS 线
RETEST：一次性异常或性能落入 RETEST 区间，只允许复测一次
FAIL：硬件错误、复测失败或性能低于失败线
HOLD：资料不全、工具不匹配、无法进入诊断环境
```

