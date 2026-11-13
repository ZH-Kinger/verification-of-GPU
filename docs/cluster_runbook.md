# 多机压测 Runbook（《验收标准》§5 §6）

## 最短路径（v3.1 起）

```bash
# 在 head 节点（hostfile 第一行）执行
bash scripts/cluster/setup_ssh.sh <hostfile>              # 只需一次，会逐台提示输入密码
sudo bash scripts/cluster/run_cluster.sh --dry-run  <hostfile>   # 先看要跑多久
sudo bash scripts/cluster/run_cluster.sh --check-env <hostfile>  # 只查环境，不压测
sudo bash scripts/cluster/run_cluster.sh <hostfile>              # 全流程
```

`run_cluster.sh` 内部依次跑：SSH 与路径一致性检查 → 拓扑发现 → §5 RoCE → §6 NCCL 规模 →
§6b 慢节点体检（并发分发到各节点）→ 出判定表。

- **profile 不用填**，按 `nvidia-smi` 的 GPU 型号自动识别；认不出会停下来要求指定。
- **阶段成功才打 `.done` 标记**，中断后重跑同一条命令从断点继续；
  要重跑某个阶段就删掉 `<log_dir>/.cluster-state/<阶段>.done`。
- **各节点上本项目的绝对路径必须一致**，否则分发过去的命令找不到脚本；
  `--check-env` 会先验这一条。
- `--dry-run` 会列出每阶段预计耗时并扣掉已完成的 —— 现场靠它安排值班。

下面各节是分步执行与排错细节；一键入口跑不通时按节对照。


多机链路和单机离线链路是两套东西：它需要网络、MPI 和跨节点免密，
**不在 U 盘 live 系统里跑**。本 runbook 覆盖两种现场情况。

## 两种现场

### A. 节点已装好 OS + 驱动 + RoCE（常见）

把本项目目录复制到 head 节点，各节点只需要 `*_perf_mpi` 二进制在**相同路径**。

```bash
# head 节点
cp -r GPU_Offline_Acceptance /opt/
cd /opt/GPU_Offline_Acceptance
cp scripts/cluster/hosts.template scripts/cluster/hosts
vi scripts/cluster/hosts          # 填实际主机名/IP

bash scripts/cluster/setup_ssh.sh scripts/cluster/hosts
```

`setup_ssh.sh` 顺带核对全集群驱动版本是否一致（§7 要求一致）。

### B. 节点是裸机

先用单机链路把每个节点各自验收一遍（U 盘逐台启动，或先装 OS），
装好驱动 + DOCA-OFED + OpenMPI 之后再回到情况 A。
本项目不承担"批量装机"，那是交付方的事。

## 执行顺序

```bash
LOGDIR=logs/$(date +%F_%H%M%S)_cluster
mkdir -p "$LOGDIR"

# §5 本机侧 RoCE 检查（每个节点都要跑一遍）
bash scripts/cluster/roce_check.sh "$LOGDIR" b300_8gpu

# §5 打流（需要对端起 server，见脚本头部注释）
PEER_IP=10.0.0.2 bash scripts/cluster/roce_check.sh "$LOGDIR" b300_8gpu

# §6 跨节点 NCCL 规模扫描 2/4/8/16 节点
bash scripts/cluster/nccl_scale.sh "$LOGDIR" scripts/cluster/hosts b300_8gpu

# 判定
bash scripts/cluster/check_cluster.sh "$LOGDIR" b300_8gpu
```

产出 `$LOGDIR/cluster_report.txt`（人读）和 `.tsv`（机器可读），
格式与单机 `acceptance_report.tsv` 一致，可以直接合并成一份交付报告。

## STOP 条件

以下情况先停下来查，不要继续往大规模跑：

```text
2 节点 AllReduce 就低于阈值        —— 单节点 §4 先复查，多半不是网络问题
ib_write_bw 远低于 460 Gb/s        —— 查 PFC / MTU / DSCP 是否真的生效
rx_discards 非 0                   —— 无损网络没配好，跨节点数据全部不可信
不同节点驱动版本不一致              —— §7 直接不合格，先统一
节点数从 2 涨到 4 带宽断崖式下跌    —— 查交换机上联收敛比和 ECMP 哈希
```

## 已知限制

1. **`*_perf_mpi` 二进制目前不存在**。当前工具集是 `make MPI=0` 编的，
   `nccl_scale.sh` 会在自检阶段直接退出并提示。补齐方法见
   `docs/tooling_gaps.md`。
2. **PFC 暂停帧比例判定标 MANUAL**。计数口径随网卡固件变化，
   脚本只把 `ethtool -S` 的原始计数留证，比例由人换算。
3. **16 节点规模需要 hostfile 真有 16 行**。行数不足时对应规模记 SKIP
   而不是 PASS——判定表会明确标出来。
4. **纯 RoCE AllReduce**（§5 最后一行）用每节点 1 GPU 强制走网卡，
   和 §6 的每节点 8 GPU 不是同一个口径，不要互相比较。
