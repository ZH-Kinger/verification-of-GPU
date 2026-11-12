#!/bin/bash
# §8 长稳：在训练任务里调用项目原版 scripts/soak_node.sh（gpu_burn 满载 + 持续 NCCL AllReduce + 每 60 s 采样，判增量）。
# 每台一个任务，结果写到对应的 standard 日志目录，soak 跑完后 check_node.sh 重新判定一次。
# 用法（任务启动命令）: bash soak_job.sh <LOG_DIR 名>
set -u
export PATH=/usr/local/bin:$PATH
BASE=/mnt/acceptance/GPU_Offline_Acceptance
LOG=$BASE/logs/$1
T=$BASE/tools
export LD_LIBRARY_PATH=$T/lib:${LD_LIBRARY_PATH:-}
# DCGM / dmon 需要的工具：离线 deb（镜像 apt 源不可达）
dpkg -i --force-depends /mnt/acceptance/debs/dcgm4/*.deb >/tmp/dpkg.log 2>&1 || true
nv-hostengine >/dev/null 2>&1 || true
# 自检：工具依赖与 30 s 试烤，任何一项不过直接失败（上次 VLA/CUDA13 镜像里 gpu_burn exit=127，烤机 1 秒就"结束"）
for b in gpu_burn all_reduce_perf; do
  miss=$(ldd $T/bin/$b | grep "not found"); [ -n "$miss" ] && { echo "PRECHECK FAIL: $b 缺库: $miss"; exit 11; }
done
# 与正式长稳同配置：gpu_burn 限显存 + 同时跑一轮 NCCL（上次 gpu_burn 占满显存，NCCL 725 轮全 OOM）
MEM=${SOAK_GPU_BURN_MEM:-75%}; export SOAK_GPU_BURN_MEM=$MEM
( cd $T/bin && timeout 150 ./gpu_burn -m $MEM 90 > /tmp/burn_precheck.txt 2>&1 ) & BP=$!
sleep 25
NB=$(sed -n 's/^NCCL_BENCH_ARGS=//p' $BASE/profiles/h200_8gpu.env | tr -d '"' | sed 's/ *#.*//')
$T/bin/all_reduce_perf $NB > /tmp/nccl_precheck.txt 2>&1; nrc=$?
wait $BP; rc=$?
grep -q -E "OK|errors: 0" /tmp/burn_precheck.txt && [ $rc -eq 0 ] || { echo "PRECHECK FAIL: gpu_burn rc=$rc"; tail -5 /tmp/burn_precheck.txt; exit 12; }
[ $nrc -eq 0 ] && grep -q "Avg bus bandwidth" /tmp/nccl_precheck.txt || { echo "PRECHECK FAIL: gpu_burn 同时 NCCL rc=$nrc"; grep -a -E "WARN|failure|rror" /tmp/nccl_precheck.txt | head -3; exit 13; }
echo "PRECHECK OK: gpu_burn -m $MEM 与 NCCL 同时运行通过；NCCL $(grep "Avg bus bandwidth" /tmp/nccl_precheck.txt | awk '{print $NF}') GB/s"
echo "[$(date -u +%FT%TZ)] soak start host=$(hostname) log=$LOG SOAK_SECONDS=${SOAK_SECONDS:-64800}"
cd "$BASE"
bash scripts/run_acceptance.sh soak "$LOG" h200_8gpu > "$LOG/soak_console.log" 2>&1
rc=$?
echo "[$(date -u +%FT%TZ)] soak end rc=$rc"
grep -E "§8|长稳|机器判定|合计" "$LOG/soak_console.log" | tail -8
