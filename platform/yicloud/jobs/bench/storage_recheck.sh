#!/bin/bash
# 存储复测（单客户端，另一台节点不跑存储负载）：
#  1. GPFS 元数据：create/stat/open/delete，线程 1/4/16/64 扫描，看是否随并发退化
#  2. GPFS 4K 随机读：并发 1~128 × qd 1~32 扫描，出 IOPS-时延曲线（找排队拐点）
#  3. 系统盘（rbd 云盘）：64 GiB 大文件、direct IO，排除宿主页缓存
set -u
export PATH=/usr/local/bin:$PATH
T=/mnt/acceptance/GPU_Offline_Acceptance/tools
FIO=$(command -v fio || echo $T/bin/fio)
export LD_LIBRARY_PATH=$T/lib
O=/mnt/acceptance/results/storage_recheck; mkdir -p $O; [ "${SKIP_META:-0}" = 1 ] || : > $O/summary.txt
log(){ echo "[$(date -u +%T)] $*" | tee -a $O/summary.txt; }
fj(){ "$FIO" "$@" --output-format=json 2>/dev/null | python3 /mnt/acceptance/tools/fioparse.py; }

if [ "${SKIP_META:-0}" != 1 ]; then
log "== GPFS 元数据（单客户端，每线程 4000 个 4KiB 文件）"
python3 - <<'EOF' | tee -a $O/summary.txt
import os, time, concurrent.futures as cf, shutil
base="/mnt/acceptance/meta_recheck"; data=os.urandom(4096); N=4000
for th in (1,4,16,64):
    shutil.rmtree(base, ignore_errors=True); os.makedirs(base)
    def w(i, op):
        d=f"{base}/t{i}"
        if op=="create": os.makedirs(d, exist_ok=True)
        for k in range(N):
            p=f"{d}/f{k}"
            if op=="create":
                with open(p,"wb") as f: f.write(data)
            elif op=="stat": os.stat(p)
            elif op=="open":
                with open(p,"rb") as f: f.read(1)
            else: os.unlink(p)
    row=[]
    for op in ("create","stat","open","delete"):
        t=time.time()
        with cf.ThreadPoolExecutor(th) as ex: list(ex.map(lambda i: w(i,op), range(th)))
        row.append(f"{op}={th*N/(time.time()-t):,.0f}")
    print(f"meta threads={th:<3d} " + "  ".join(row) + " ops/s")
shutil.rmtree(base, ignore_errors=True)
EOF
fi

log "== GPFS 4K 随机读 IOPS-时延曲线"
G=/mnt/acceptance/fio_recheck; mkdir -p $G
"$FIO" --name=prep --directory=$G --rw=write --bs=1M --size=2G --numjobs=16 --direct=1 --ioengine=libaio >/dev/null 2>&1
for nj in 1 4 16 64 128; do for qd in 1 8 32; do
  log "randread jobs=$nj qd=$qd: $(fj --name=prep --directory=$G --rw=randread --bs=4k --size=2G --numjobs=$nj --iodepth=$qd --direct=1 --ioengine=libaio --runtime=20 --time_based --group_reporting)"
done; done
rm -rf $G

log "== 训练任务容器根盘（本地 NVMe overlay）16 GiB×N 大文件 direct IO"
S=/var/tmp/fio_sys; mkdir -p $S
for spec in "seqread:read:4M:32:4" "seqwrite:write:4M:32:4" "randread:randread:4k:64:16" "randwrite:randwrite:4k:64:16"; do
  IFS=: read tag rw bs qd nj <<<"$spec"
  log "sys $tag: $(fj --name=sys --directory=$S --rw=$rw --bs=$bs --iodepth=$qd --numjobs=$nj --size=16G --direct=1 --ioengine=libaio --runtime=45 --ramp_time=5 --time_based --group_reporting)"
done
rm -rf $S
log "storage_recheck done"
