#!/bin/bash
# 在开发机上后台跑项目的 run_acceptance.sh standard。用法: bash run_standard.sh <node-label> [profile]
# 日志目录写到 GPFS（GPU_Offline_Acceptance/logs/），控制台输出另存一份。
set -eu
NODE=$1; PROFILE=${2:-h200_8gpu}
BASE=/mnt/acceptance/GPU_Offline_Acceptance
OUT=/mnt/acceptance/results/$NODE
mkdir -p "$OUT"
TS=$(date +%Y%m%d-%H%M%S)
echo "$TS" > "$OUT/STANDARD_CURRENT"
cd "$BASE"
setsid nohup env LD_LIBRARY_PATH="$BASE/tools/lib:${LD_LIBRARY_PATH:-}" \
  bash scripts/run_acceptance.sh standard "$PROFILE" > "$OUT/standard-$TS.console.log" 2>&1 < /dev/null &
echo "$!" > "$OUT/standard-$TS.pid"
echo "started $NODE standard run $TS pid $(cat "$OUT/standard-$TS.pid") profile=$PROFILE"
