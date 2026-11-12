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
( cd $T/bin && timeout 120 ./gpu_burn 30 > /tmp/burn_precheck.txt 2>&1 ); rc=$?
grep -q -E "OK|errors: 0" /tmp/burn_precheck.txt && [ $rc -eq 0 ] || { echo "PRECHECK FAIL: gpu_burn 30s rc=$rc"; tail -5 /tmp/burn_precheck.txt; exit 12; }
echo "PRECHECK OK: gpu_burn 30s 通过，$(grep -c OK /tmp/burn_precheck.txt) 行 OK"
echo "[$(date -u +%FT%TZ)] soak start host=$(hostname) log=$LOG SOAK_SECONDS=${SOAK_SECONDS:-64800}"
cd "$BASE"
bash scripts/run_acceptance.sh soak "$LOG" h200_8gpu > "$LOG/soak_console.log" 2>&1
rc=$?
echo "[$(date -u +%FT%TZ)] soak end rc=$rc"
grep -E "§8|长稳|机器判定|合计" "$LOG/soak_console.log" | tail -8
