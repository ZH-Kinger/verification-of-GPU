# 仪电智算云（yicloud）平台验收适配

在**云平台容器**里跑本项目的验收，而不是从 U 盘引导裸机。2026-11 对两台 H200
（专属资源）做过完整一轮，报告见 `docs/yicloud_h200_acceptance_2026-11.md`。

与 U 盘场景的根本区别：没有宿主机权限、没有 BMC、没有 systemd、没有公网。
`scripts/` 里的单机判定照常能跑，宿主机侧的项（内存条、风扇、FM 服务、XID）会 SKIP，
需平台方另行提供证据。

## 目录

| 路径 | 作用 |
|---|---|
| `jobctl/` | Go 命令行，基于官方 `openapi-sdk-go` v0.6.0：提交/查看/停止任务、开发机、GPFS、对象存储 |
| `api/yc.py` | Python 只读客户端（只放行 List/Get/Describe），自己实现了平台签名，不依赖 SDK |
| `api/api_bench.py` | OpenAPI 时延与成功率 |
| `api/summarize.py` | 多节点 `@@RESULT` 汇总与同批比对 |
| `jobs/single/` | 单机：`probe.sh` + `bench.py`（PyTorch 版快速探测）、`run_standard.sh`（调 `scripts/run_acceptance.sh standard`）、`memstress.sh`、`hwinfo.sh`、`speed_io.sh`、`dcgm_l4.sh` |
| `jobs/multi/` | 多机：`multinode.sh`（RDMA 逐口/聚合、GDR、NCCL、GPFS 双客户端）、`nccl16.sh`、`rdma2.sh` |
| `jobs/bench/` | 硬件理论值（`hwpeak*`、`gemm_power.py`）、训练基准（`vla_bench.sh`、`openwam_bench.sh`、`registry_job.sh`）、存储（`storage_recheck.sh`、`oss_bench.py`）、镜像解包运行（`unpack_image.sh`、`imgenv.sh`） |
| `jobs/soak/soak_job.sh` | §8 长稳：先让 gpu_burn 与一轮 NCCL 同时跑通，再调 `run_acceptance.sh soak` |
| `jobs/soak/watch.sh` | 长稳看护：任务退出、gpu_burn 报错、NCCL 有失败轮次、利用率低于 90% 时提醒 |
| `build/` | 在 `nvidia/cuda:12.9.1-devel-ubuntu22.04` 容器里编 nvbandwidth、nccl-tests（MPI=0/1）、gpu-burn、cuda-samples、STREAM |

## 准备

```bash
# 凭据只放本机文件，权限 600；API 地址按账号所在环境选，.com.cn 环境是：
cat ~/.yicloud/env
#   export YICLOUD_PUBLIC_KEY=...
#   export YICLOUD_SECRET_KEY=...
#   export YICLOUD_API_HOST=https://gate.yicloud.com.cn

cd platform/yicloud/jobctl
go mod edit -replace=gitee.com/yicloud-team/openapi-sdk-go=<本地 SDK 克隆>   # SDK 在 gitee，未发布到 proxy
go build -o jobctl .
set -a; . ~/.yicloud/env; set +a
YC_PROJECT=<项目> YC_QUOTA=<资源组> ./jobctl list
```

工具二进制不在仓库里：用 `build/` 脚本编好后放到 GPFS 的
`/mnt/acceptance/GPU_Offline_Acceptance/tools/{bin,lib}`，项目脚本本身用 `git archive` 拷过去。

## 常用命令

```bash
./jobctl ws-create accept-node-a          # 整机开发机（8 卡），挂 GPFS
NODE=<节点全名> GPU=8 CPU=170 MEM=1800Gi ./jobctl run <name> <image> "<命令>"   # 单副本训练任务
DIST=0 HOSTNET=0 ./jobctl hold <name> 2 24                                      # 2 副本 × 8 卡，留 24h 供 SSH
./jobctl mkfs acceptance 10               # GPFS 文件集（TiB）
./jobctl mkbucket acceptance-oss 2        # 对象存储桶（TiB）
./jobctl get|replicas|logs|stop|delete <jobId>
```

## 必须知道的坑（都是实际踩过的）

| 现象 | 原因 | 做法 |
|---|---|---|
| `Public Key 不存在` | 账号在 `.com.cn` 环境，打到了 `.com` 网关 | `YICLOUD_API_HOST=https://gate.yicloud.com.cn` |
| 任务一直 Pending，事件只有 `pod group is not ready` | 项目/配额组没给额度，或用户不在配额组 | 管理员把用户加进配额组 |
| `任务规格不合法` | 真实原因在响应隐藏字段 `_err`（如 `backoffLimit` 不能为 0） | `jobctl` 已把 `_err` 打出来 |
| 405 HTML 页面 | 网关前有阿里云 WAF，命令里出现未压缩的 base64 或 `/usr/`、`mv /app` 之类 | 命令内容先 `gzip | base64` |
| 设 `DISTRIBUTED_JOB=true` 的多机任务必然 Failed | 平台 `generate_distributed_job_envs.sh` 取到 `127.0.1.1` 报 FATAL | `DIST=0`（不设该变量），多机环境在容器里自己建 |
| 副本间 SSH 连不上 | 平台 sshd 在 **22222**，不是 22 | `ssh -p 22222 <对端 bond0 IP>` |
| 训练副本 SSH 用户名 | 开发机后缀 `.ws`，训练副本后缀 `.pod` | `<副本名>.<用户>+root.<项目>.pod@ssh.gate.<平台域名> -p 2202` |
| NCCL `NET/IB : No device found` | 把工具目录里的 jammy `libibverbs` 放进了 LD_LIBRARY_PATH，盖掉了镜像 OFED 的 mlx5 provider | 只借工具目录的 `libnccl.so.2`，verbs 用镜像自带 |
| RoCE 打流 0 带宽 | 400G 轨道口只有 IPv6 链路本地地址 | GID index 用 1（`NCCL_IB_GID_INDEX=1`） |
| AllToAll / SendRecv 失败（UDS Connection refused、shm 不存在） | 容器 IPC 隔离，NCCL cuMem 路径不可用 | `NCCL_CUMEM_ENABLE=0` |
| 8 口并发 RDMA 只有 57% | perftest 进程没绑到网卡所在 NUMA | `taskset -c <node cpulist>`，见 `rdma2.sh` |
| GDR perftest `unrecognized option --use_cuda` / 缺 `libefa.so.1` | 发行版 perftest 不带 CUDA；容器外编的二进制依赖 EFA | 在副本里对着镜像 OFED + CUDA 头文件现编 |
| 公共镜像里 `mpirun --allow-run-as-root` 不认 | 自带 OpenMPI 包装器不完整 | precheck 镜像有 MLNX_OFED 的 `/usr/mpi/gcc/openmpi-4.1.7a1`，用它 |
| gpu_burn / nccl-tests `exit=127` | 镜像是 CUDA 13，工具链接 CUDA 12 运行库 | 用 `pytorch-training-nvidia:...cuda12.9...` 镜像；`soak_job.sh` 先自检 |
| 长稳期间 NCCL 每轮 `unhandled cuda error` | gpu_burn 默认占 90% 显存，all_reduce_perf 测 8 GB 要再申请约 16 GB | `soak_node.sh` 已改为 `gpu_burn -m 75%`；`soak_job.sh` 启动前让两者同时跑一轮 |
| DCGM diag 报 `plugins/cuda13` 不存在 | 驱动 CUDA 13.2，装了 `-cuda12` 包 | 装 `datacenter-gpu-manager-4-cuda13` |
| 镜像里 apt 装不了 | 公共镜像 apt 源指向 apt.ksyun.cn / developer.download.nvidia.com，内网不可达 | 改用平台 Nexus `<平台 Nexus>/repository/{ubuntu,nvidia-drivers-proxy}`，或 GPFS 上的离线 deb |
| SSH 进训练副本后 `python3: command not found` | SSH 会话 PATH 缺 `/usr/local/bin` | `export PATH=/usr/local/bin:$PATH` |
| 镜像 tar 包没有 docker 可 load，chroot 挂不了 /proc | 容器无 CAP_SYS_ADMIN | `unpack_image.sh` 解包，`imgenv.sh` 用镜像自带 ld-linux 启动其 python |
| 解包后软链接指回宿主 | 镜像里的软链是绝对路径 | `imgenv.sh` 直接用真实文件路径 |
| 镜像自带空 `/app` | `ln -s` 会建到 `/app` 里面 | 先 `mv /app /app.image-orig` 再链接，且要在第一次 import torch 之前 |
| stressapptest 在 1.5 TB 下卡死 | power-spike 暂停/恢复后控制线程卡在 futex | `--pause_delay` 大于运行时长，见 `memstress.sh` |
| 删除任务后新任务被拒 `gpu : 24/16` | 资源释放要 1～20 分钟，失败任务还占 CPU | 先 `delete` 旧任务；整机任务 CPU 申请 170 而不是 176 |
| `pkill -f <pattern>` 把 SSH 会话自己杀了 | 会话命令行里含同一字符串 | 按 PID 杀，或用 `pgrep -x` |

## 镜像

| 用途 | 镜像 | 说明 |
|---|---|---|
| 验收工具（gpu_burn / nccl-tests / nvbandwidth） | `library/pytorch-training-nvidia:2.6.0-py3.10-cuda12.9-h20-ubuntu22.04-v20260710` | CUDA 12，与 `tools/bin` 一致 |
| 多机 / RDMA | `library/precheck:t-release-20261013-184226-f345353` | 含 MLNX_OFED 23.10、OpenMPI 4.1.7a1、perftest |
| VLA 训练基准 | `<项目>/wuji-vla-bench:cuda13` | 直接可用 |
| OpenWAM 训练基准 | `<项目>/wuji-vla-bench:cuda13-2` | 实为缺 `_bz2` 的旧版 OpenWAM；启动时把 `/mnt/acceptance/img-fix/openwam/usr/.` 复制到 `/usr/`，见 `registry_job.sh` |
