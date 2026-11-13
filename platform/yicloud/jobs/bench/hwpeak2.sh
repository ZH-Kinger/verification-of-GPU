#!/bin/bash
# 补测：单卡独占 GEMM 峰值（避开 8 卡同时满载的功耗/供电叠加），nvbandwidth 全项（--disableAffinity，容器内 NVML 亲和性接口报错）
set -u
LABEL=$1
T=/mnt/acceptance/GPU_Offline_Acceptance/tools
OUT=/mnt/acceptance/results/hwpeak/$LABEL
log() { echo "[$(date -u +%T)] $*" | tee -a "$OUT/summary.txt"; }

log "== 单卡独占 GEMM（GPU0、GPU6，其余卡空闲）"
source /mnt/acceptance/tools/imgenv.sh /opt/img/vla >/dev/null
for g in 0 6; do
  CUDA_VISIBLE_DEVICES=$g python3 /mnt/acceptance/tools/hwpeak.py gemm > "$OUT/gemm_solo_gpu$g.txt" 2>&1
  grep '@@RESULT' "$OUT/gemm_solo_gpu$g.txt" | sed "s/@@RESULT //; s/\"gpu\": 0/\"gpu\": $g, \"solo\": true/" >> "$OUT/results.jsonl"
  log "solo GPU$g: $(grep '@@RESULT' "$OUT/gemm_solo_gpu$g.txt" | sed 's/@@RESULT //' | python3 -c 'import json,sys;print("  ".join(f"{r[\"dtype\"]} {r[\"tflops\"]}TF@{r[\"sm_mhz\"]:.0f}MHz/{r[\"power_w\"]:.0f}W" for r in map(json.loads,sys.stdin) if r.get("kind")=="gemm"))')"
done

log "== nvbandwidth 全项（--disableAffinity）"
export LD_LIBRARY_PATH=$T/lib
$T/bin/nvbandwidth -d > "$OUT/nvbandwidth_all.txt" 2>&1
grep -E "^Running|^SUM" "$OUT/nvbandwidth_all.txt" | paste - - | sed 's/Running //; s/\t/ /' | tee -a "$OUT/summary.txt" >/dev/null
log "hwpeak2 done"
