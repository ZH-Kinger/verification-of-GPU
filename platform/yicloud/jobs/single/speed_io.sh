#!/bin/bash
# 存储与主机侧速度测试（不碰 GPU）。目标是测到理论上限，而不是一个"跑出来的数"：
#   - 每项做参数扫描（块大小 / 并发 / 队列深度），取平台段，报告最佳值和取得最佳值的参数
#   - 除总吞吐外，输出折算口径：GB/s per TiB（容量归一）、per client、per GPU；IOPS / 元数据 ops per TiB
# 用法: bash speed_io.sh <node-label> [gpfs_capacity_TiB]
# 结果: /mnt/acceptance/results/<node>/speed_io.txt（人读）+ speed_io.jsonl（机读）
set -u
NODE=$1
CAP_TIB=${2:-$(df -B1 /mnt/acceptance | awk 'NR==2{printf "%.2f", $2/1099511627776}')}
NGPU=$(nvidia-smi -L 2>/dev/null | wc -l); NGPU=${NGPU:-8}
D=/mnt/acceptance/results/$NODE; OUT=$D/speed_io.txt; JS=$D/speed_io.jsonl
FIO=$(command -v fio || echo /mnt/acceptance/GPU_Offline_Acceptance/tools/bin/fio)
export LD_LIBRARY_PATH=/mnt/acceptance/GPU_Offline_Acceptance/tools/lib:${LD_LIBRARY_PATH:-}
mkdir -p "$D"; : > "$OUT"; : > "$JS"
log() { echo "$*" | tee -a "$OUT"; }

# fiorun <tag> <dir> <rw> <bs> <iodepth> <numjobs> <size> [extra fio args]
fiorun() {
  local tag=$1 dir=$2 rw=$3 bs=$4 qd=$5 nj=$6 size=$7; shift 7
  mkdir -p "$dir"
  "$FIO" --name="$tag" --directory="$dir" --rw="$rw" --bs="$bs" --iodepth="$qd" --numjobs="$nj" \
    --size="$size" --runtime="${FIO_RUNTIME:-45}" --ramp_time=5 --time_based --ioengine=libaio \
    --group_reporting --output-format=json "$@" 2>/dev/null \
  | python3 -c '
import json,sys
tag,rw,bs,qd,nj,cap,ngpu=sys.argv[1:8]
try: j=json.load(sys.stdin)["jobs"][0]
except Exception: print(json.dumps(dict(tag=tag,rw=rw,bs=bs,qd=qd,nj=nj,error="fio failed"))); sys.exit()
r,w=j["read"],j["write"]
bw=(r["bw_bytes"]+w["bw_bytes"])/1e9; iops=r["iops"]+w["iops"]
side=r if r["iops"]>=w["iops"] else w
p99=side.get("clat_ns",{}).get("percentile",{}).get("99.000000",0)/1000
print(json.dumps(dict(tag=tag,rw=rw,bs=bs,qd=int(qd),nj=int(nj),gbs=round(bw,3),iops=round(iops),
  lat_avg_us=round(side["clat_ns"]["mean"]/1000,1),lat_p99_us=round(p99,1),
  gbs_per_tib=round(bw/float(cap),3) if float(cap)>0 else None, gbs_per_gpu=round(bw/int(ngpu),3),
  iops_per_tib=round(iops/float(cap)) if float(cap)>0 else None)))
' "$tag" "$rw" "$bs" "$qd" "$nj" "$CAP_TIB" "$NGPU" | tee -a "$JS"
  rm -f "$dir/$tag".* 2>/dev/null
}

best() {  # best <tag-prefix> <field>：从 jsonl 里取该组最佳值
  python3 - "$JS" "$1" "$2" <<'EOF'
import json,sys
rows=[json.loads(l) for l in open(sys.argv[1]) if l.strip()]
rows=[r for r in rows if r.get("tag","").startswith(sys.argv[2]) and sys.argv[3] in r]
if not rows: print(f"{sys.argv[2]:22s} 无有效结果"); sys.exit()
b=max(rows,key=lambda r:r[sys.argv[3]])
extra=f"  ({b['gbs_per_tib']} GB/s/TiB, {b['gbs_per_gpu']} GB/s/GPU)" if sys.argv[3]=="gbs" else f"  ({b['iops_per_tib']} IOPS/TiB)"
print(f"{sys.argv[2]:22s} 最佳 {b[sys.argv[3]]:>12} {'GB/s' if sys.argv[3]=='gbs' else 'IOPS'}  @ bs={b['bs']} qd={b['qd']} jobs={b['nj']}  p99={b['lat_p99_us']}us{extra}")
EOF
}

log "== $(hostname) $(date -u +%FT%TZ)  GPFS 配额容量 ${CAP_TIB} TiB, GPU ${NGPU}"

G=/mnt/acceptance/fio/$NODE
log "-- GPFS 顺序读写：块大小 × 并发扫描（GPFS 块通常 4~16MB，1MB 测不满）"
for bs in 1M 4M 16M; do for nj in 8 32 64; do
  fiorun gpfs_seqwrite_${bs}_${nj} $G write $bs 16 $nj 4G --direct=1 >/dev/null
  fiorun gpfs_seqread_${bs}_${nj}  $G read  $bs 16 $nj 4G --direct=1 >/dev/null
done; done
log "$(best gpfs_seqread gbs)"
log "$(best gpfs_seqwrite gbs)"
log "-- GPFS 4K 随机读（帧级随机采样），并发 × 队列深度扫描"
for nj in 32 64 128; do for qd in 32 64; do
  fiorun gpfs_randread_${nj}_${qd} $G randread 4k $qd $nj 1G --direct=1 >/dev/null
done; done
log "$(best gpfs_randread iops)"
fiorun gpfs_randwrite_64_32 $G randwrite 4k 32 64 1G --direct=1 >/dev/null
log "$(best gpfs_randwrite iops)"
log "-- GPFS checkpoint 写（单大文件流 + 多分片），折算 2TB 耗时"
fiorun gpfs_ckpt_single $G write 16M 64 1 64G --direct=1 >/dev/null
fiorun gpfs_ckpt_shard  $G write 16M 16 64 4G --direct=1 >/dev/null
python3 - "$JS" <<'EOF' | tee -a "$OUT"
import json,sys
rows={r["tag"]:r for r in map(json.loads,open(sys.argv[1])) if "gbs" in r}
for t in ("gpfs_ckpt_single","gpfs_ckpt_shard"):
    r=rows.get(t)
    if r: print(f"{t:22s} {r['gbs']:>8} GB/s  → 2TB 约 {2000/r['gbs']/60:.1f} 分钟（标准 ≤5 分钟，需 ≥7 GB/s）")
EOF
rm -rf "$G"

log "-- GPFS 元数据：create / stat / open / delete，并发扫描（mdtest 口径的近似）"
python3 - "$NODE" "$CAP_TIB" <<'EOF' | tee -a "$OUT" | tee -a /dev/null
import os, sys, time, json, concurrent.futures as cf
node, cap = sys.argv[1], float(sys.argv[2])
base = f"/mnt/acceptance/meta/{node}"
data = os.urandom(4096)
N = 4000
def work(i, op):
    d = f"{base}/t{i}"
    if op == "create": os.makedirs(d, exist_ok=True)
    for k in range(N):
        p = f"{d}/f{k}"
        if op == "create":
            with open(p, "wb") as f: f.write(data)
        elif op == "stat": os.stat(p)
        elif op == "open":
            with open(p, "rb") as f: f.read(1)
        else: os.unlink(p)
for th in (16, 64):
    os.makedirs(base, exist_ok=True)
    for op in ("create", "stat", "open", "delete"):
        t = time.time()
        with cf.ThreadPoolExecutor(th) as ex: list(ex.map(lambda i: work(i, op), range(th)))
        dt = time.time() - t; ops = th * N / dt
        print(f"gpfs_meta_{op:6s} threads={th:<3d} {ops:10.0f} ops/s  ({ops/cap:,.0f} ops/s/TiB)")
    os.system(f"rm -rf {base}")
EOF

log "-- 系统盘 / (rbd 云盘)"
for bs in 1M 4M; do fiorun sys_seqread_$bs /var/tmp/fio read $bs 32 8 4G --direct=1 >/dev/null; fiorun sys_seqwrite_$bs /var/tmp/fio write $bs 32 8 4G --direct=1 >/dev/null; done
fiorun sys_randread /var/tmp/fio randread 4k 64 16 2G --direct=1 >/dev/null
fiorun sys_randwrite /var/tmp/fio randwrite 4k 64 16 2G --direct=1 >/dev/null
log "$(best sys_seqread gbs)"; log "$(best sys_seqwrite gbs)"; log "$(best sys_randread iops)"; log "$(best sys_randwrite iops)"
rm -rf /var/tmp/fio

log "-- 主机内存带宽（多线程，按 NUMA 分别测；stressapptest 是查错工具，不测带宽）"
python3 - <<'EOF' | tee -a "$OUT"
import numpy as np, os, time, threading
cpus = sorted(os.sched_getaffinity(0))
def bench(nthreads, per=1 << 28):
    bufs = [(np.ones(per, np.uint8), np.empty(per, np.uint8)) for _ in range(nthreads)]
    def run(i):
        os.sched_setaffinity(0, {cpus[i * len(cpus) // nthreads]})
        a, b = bufs[i]
        for _ in range(8): np.copyto(b, a)
    ts = [threading.Thread(target=run, args=(i,)) for i in range(nthreads)]
    t = time.time(); [x.start() for x in ts]; [x.join() for x in ts]
    return 2 * per * 8 * nthreads / (time.time() - t) / 1e9
for n in (1, 16, 48, 96):
    print(f"mem_copy threads={n:<3d} {bench(n):8.1f} GB/s (读+写)")
EOF

log "-- 网络（Pod 网卡 / RDMA 网卡链路）"
log "eth0 speed=$(cat /sys/class/net/eth0/speed 2>/dev/null)Mb/s mtu=$(cat /sys/class/net/eth0/mtu)"
for d in /sys/class/infiniband/mlx5_*; do
  log "$(basename $d) fw=$(cat $d/fw_ver) $(cat $d/ports/1/state) $(cat $d/ports/1/rate) $(cat $d/ports/1/link_layer)"
done
log "/dev/infiniband: $(ls /dev/infiniband 2>/dev/null | tr '\n' ' ')"
log "== done $(date -u +%FT%TZ)"
