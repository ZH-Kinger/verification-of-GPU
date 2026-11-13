#!/bin/bash
# OpenWAM dual_system 训练吞吐。与 B300 基线（ACCELERATION.md：bs24/卡、accum8、workers8、ZeRO-2、ckpt on → 2.259 s/micro-step、85.0 samples/s）同参数。
# 测法同基线：跳过 warmup，稳态窗口内按 step 增量算 step_time。
# 用法: bash openwam_bench.sh <tag> [PERF:0|1] [WINDOW_S=240] [WARMUP_STEPS=25]
set -u
TAG=$1; PERF=${2:-0}; WIN=${3:-240}; WARM=${4:-25}
source /mnt/acceptance/tools/imgenv.sh /opt/img/openwam
B=/dev/shm/benchmark
OUT=/mnt/acceptance/results/bench/openwam; mkdir -p "$OUT"
LOG=$OUT/$TAG.log; : > "$LOG"
# 容器 /app、/models、/datasets 三个挂载点 → 软链（rootfs 外路径，用户态不 chroot）
ln -sfn $B/wuji-openwam-dev /app; ln -sfn $B/models /models; ln -sfn $B/datasets /datasets
EXTRA=""
[ "$PERF" = 1 ] && EXTRA="training.use_gradient_checkpointing=false model.architecture.mot_checkpoint_mixed_attn=false"
nvidia-smi --query-gpu=timestamp,index,utilization.gpu,memory.used,power.draw,temperature.gpu,clocks.sm \
  --format=csv,noheader,nounits -l 2 > "$OUT/$TAG.gpu.csv" 2>/dev/null &
SP=$!
cd /app
( WANDB_MODE=offline bash scripts/train.sh \
    model.video_backbone.model_path=/models/Wan2.2-TI2V-5B \
    model.video_backbone.encoder.model_path=/models/Wan2.2-TI2V-5B \
    dataloader.dataset_dir=/datasets/robotwin_2_0/dataset \
    dataloader.task_name=adjust_bottle dataloader.robot=arx-x5 dataloader.variant=randomized_500 \
    training.batch_size=24 training.dataset_num_workers=8 training.gradient_accumulation_steps=8 \
    training.resume=false training.output_path=/tmp/openwam_ckpt_$TAG $EXTRA > "$LOG" 2>&1 ) &
TP=$!
# 等到 warmup 步，再开窗口
# 进度是 tqdm 条（\r 刷新）："Training:   5%|▍ | 52/1070 [02:59<37:14,  2.20s/step, ..."，8 个 rank 各打一份
step() { tr '\r' '\n' < "$LOG" | grep -a -oE "Training: +[0-9]+%\|[^|]*\| *[0-9]+/[0-9]+" | grep -oE "[0-9]+/[0-9]+$" | cut -d/ -f1 | sort -n | tail -1; }
t_start=$(date +%s)
while kill -0 $TP 2>/dev/null; do s=$(step); [ -n "$s" ] && [ "$s" -ge "$WARM" ] && break; sleep 5
  [ $(( $(date +%s) - t_start )) -gt 1800 ] && { echo "TIMEOUT waiting warmup" >> "$LOG"; break; }; done
s0=$(step); t0=$(date +%s.%N)
sleep "$WIN"
s1=$(step); t1=$(date +%s.%N)
pkill -P $TP 2>/dev/null; kill $TP 2>/dev/null; pkill -f "[s]cripts/train.py" 2>/dev/null; sleep 5; kill $SP 2>/dev/null
python3 - "$s0" "$s1" "$t0" "$t1" "$OUT/$TAG.gpu.csv" <<'EOF' | tee "$OUT/$TAG.result.txt"
import sys, statistics
s0, s1, t0, t1 = int(sys.argv[1] or 0), int(sys.argv[2] or 0), float(sys.argv[3]), float(sys.argv[4])
if s1 <= s0: print(f"无有效窗口 s0={s0} s1={s1}"); sys.exit()
st = (t1 - t0) / (s1 - s0)
print(f"steps {s0}->{s1} in {t1-t0:.0f}s: step_time {st:.3f} s/micro-step  throughput {24*8/st:.1f} samples/s  (B300 基线 2.259 s / 85.0)")
rows = [l.strip().split(", ") for l in open(sys.argv[5]) if l.count(",") >= 6]
if rows:
    mem = [float(r[3]) for r in rows]; pw = sorted(float(r[4]) for r in rows); tp = [float(r[5]) for r in rows]
    ut = [float(r[2]) for r in rows if float(r[2]) > 5]
    print(f"GPU mem_peak {max(mem)/1024:.0f} GiB  power_p95 {pw[int(len(pw)*.95)-1]:.0f} W  util(busy) {statistics.mean(ut) if ut else 0:.0f}%  temp_max {max(tp):.0f}C")
EOF
