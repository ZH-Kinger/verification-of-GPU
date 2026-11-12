#!/bin/bash
# 在节点上后台启动一轮 probe.sh。用法: bash launch.sh <node-label> [BURN_SECONDS]
set -eu
NODE=$1; BURN=${2:-3600}
D=/mnt/acceptance/results/$NODE
mkdir -p "$D"
TS=$(date +%Y%m%d-%H%M%S)
echo "$TS" > "$D/CURRENT"
setsid nohup env BURN_SECONDS="$BURN" bash /mnt/acceptance/tools/probe.sh > "$D/run-$TS.log" 2>&1 < /dev/null &
echo "$!" > "$D/run-$TS.pid"
echo "started $NODE run $TS pid $(cat "$D/run-$TS.pid") burn=${BURN}s"
