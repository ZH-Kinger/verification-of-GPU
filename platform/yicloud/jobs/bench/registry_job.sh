#!/bin/bash
# 在「平台镜像仓库镜像」直接启动的训练任务里跑基准（不解包、不换 loader）。
# 用法（作为任务启动命令）: bash /mnt/acceptance/tools/registry_job.sh <vla|openwam>
# 结果: /mnt/acceptance/results/bench/registry/<which>/
set -u
WHICH=$1
OUT=/mnt/acceptance/results/bench/registry/$WHICH; mkdir -p "$OUT"
exec > >(tee -a "$OUT/console.log") 2>&1
echo "[$(date -u +%FT%TZ)] host=$(hostname) image-python=$(command -v python3) which=$WHICH"
( cd /tmp && python3 -c "import sys,torch;print(sys.version.split()[0],torch.__version__,torch.cuda.device_count(),torch.cuda.get_device_name(0))" ) || exit 2
ln -sfn /mnt/acceptance/wuji-data/b300-test/benchmark /dev/shm/benchmark
B=/dev/shm/benchmark
nvidia-smi --query-gpu=timestamp,index,utilization.gpu,memory.used,power.draw,temperature.gpu,clocks.sm \
  --format=csv,noheader,nounits -l 2 > "$OUT/gpu.csv" 2>/dev/null &
SP=$!
case "$WHICH" in
vla)
  KIT=$B/test/wuji-vla-post-train
  cd "$KIT"
  REPO=$KIT CONFIG=vitra_bench_ab_tianji4 GPUS=8 BATCH=256 STEPS=100 WARMUP=40 NUM_WORKERS=64 \
    LOG_INTERVAL=5 EXP=registry_vla OUTDIR=$OUT bash $B/test/run_throughput.sh > "$OUT/train.log" 2>&1
  python3 - "$OUT/registry_vla.log" <<'EOF' | tee "$OUT/result.txt"
import re,sys
t=open(sys.argv[1],errors="replace").read()
pts=[(int(s),int(h)*3600+int(m)*60+float(x)) for h,m,x,s in re.findall(r"(\d\d):(\d\d):(\d\d\.\d+) \[I\] step=(\d+) ",t)]
w=[p for p in pts if p[0]>=40]
if len(w)>=2:
    (s0,t0),(s1,t1)=w[0],w[-1]; st=(t1-t0)/(s1-s0); print(f"VLA registry-image: steps {s0}->{s1} {st:.3f} s/step {256/st:.1f} samples/s")
else: print("VLA: 无足够 step 日志")
EOF
  ;;
openwam)
  # 仓库里的 cuda13-2 是缺 _bz2 的旧版：启动前把 4 个修复文件覆盖进镜像（不重新上传）
  # 等价 docker -v：镜像自带 /app 是空壳（openwam/ 只有 __init__.py），必须整体替换而不是在里面建链接
  for m in app:$B/wuji-openwam-dev models:$B/models datasets:$B/datasets; do
    d=/${m%%:*}; src=${m#*:}
    [ -e "$d" ] && [ ! -L "$d" ] && mv "$d" "$d.image-orig"
    ln -sfn "$src" "$d"
  done
  cp -a /mnt/acceptance/img-fix/openwam/usr/. /usr/
  ( cd /tmp && python3 -c "import bz2, deepspeed, openwam.dataloader.registry, openwam; print('deepspeed', deepspeed.__version__, 'openwam', openwam.__file__, 'import ok')" ) || exit 3
  cd /app
  ( WANDB_MODE=offline bash scripts/train.sh \
      model.video_backbone.model_path=/models/Wan2.2-TI2V-5B model.video_backbone.encoder.model_path=/models/Wan2.2-TI2V-5B \
      dataloader.dataset_dir=/datasets/robotwin_2_0/dataset dataloader.task_name=adjust_bottle dataloader.robot=arx-x5 \
      dataloader.variant=randomized_500 training.batch_size=24 training.dataset_num_workers=8 \
      training.gradient_accumulation_steps=8 training.resume=false training.output_path=/tmp/ow_ckpt > "$OUT/train.log" 2>&1 ) &
  TP=$!
  step() { tr '\r' '\n' < "$OUT/train.log" | grep -a -oE "Training: +[0-9]+%\|[^|]*\| *[0-9]+/[0-9]+" | grep -oE "[0-9]+/[0-9]+$" | cut -d/ -f1 | sort -n | tail -1; }
  t_start=$(date +%s)
  while kill -0 $TP 2>/dev/null; do s=$(step); [ -n "$s" ] && [ "$s" -ge 25 ] && break; sleep 5; [ $(( $(date +%s)-t_start )) -gt 1800 ] && break; done
  s0=$(step); t0=$(date +%s.%N); sleep 240; s1=$(step); t1=$(date +%s.%N)
  pkill -f "[s]cripts/train.py"; kill $TP 2>/dev/null
  python3 -c "s0,s1,t0,t1=int('${s0:-0}'),int('${s1:-0}'),$t0,$t1
print(f'OpenWAM registry-image: steps {s0}->{s1} {(t1-t0)/(s1-s0):.3f} s/step {192*(s1-s0)/(t1-t0):.1f} samples/s' if s1>s0 else f'OpenWAM registry-image: 无有效窗口 s0={s0} s1={s1}，见 train.log')" | tee "$OUT/result.txt"
  ;;
esac
kill $SP 2>/dev/null
echo "[$(date -u +%FT%TZ)] done"
