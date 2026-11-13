export DEBIAN_FRONTEND=noninteractive
# 离线装：GPFS 上的 deb 闭包（镜像 apt 源指向外网金山云源，内网不可达）
dpkg -i --force-depends /mnt/acceptance/debs/dcgm4/*.deb >/tmp/dpkg.log 2>&1; echo "dpkg=$?"; tail -2 /tmp/dpkg.log
command -v dcgmi || exit 5
O=/mnt/acceptance/results/dcgm4/$(hostname | cut -d. -f1); mkdir -p $O
nv-hostengine >/dev/null 2>&1; sleep 3; dcgmi --version | head -2
nvidia-smi --query-gpu=index,serial,ecc.errors.corrected.volatile.total,ecc.errors.uncorrected.volatile.total,remapped_rows.pending,remapped_rows.failure --format=csv > $O/ecc_before.csv
date -u +%FT%TZ > $O/start
dcgmi diag -r 4 -j > $O/dcgm_r4.json 2> $O/dcgm_r4.err; echo $? > $O/dcgm_r4.exit
date -u +%FT%TZ > $O/end
nvidia-smi --query-gpu=index,serial,ecc.errors.corrected.volatile.total,ecc.errors.uncorrected.volatile.total,remapped_rows.pending,remapped_rows.failure --format=csv > $O/ecc_after.csv
[ -s $O/dcgm_r4.json ] || { echo "dcgm_r4.json empty"; cat $O/dcgm_r4.err; exit 6; }
python3 - $O/dcgm_r4.json <<'PY' | tee $O/summary.txt
import json,sys,collections
d=json.load(open(sys.argv[1]))
c=collections.Counter(); fails=[]
def walk(o,path=""):
    if isinstance(o,dict):
        s=o.get("status") or o.get("result")
        if isinstance(s,str) and s.lower() in ("pass","fail","warn","skip"):
            c[s.lower()]+=1
            if s.lower()!="pass": fails.append((path, s, str(o.get("warnings") or o.get("info") or "")[:160]))
        for k,v in o.items(): walk(v, path+"/"+str(o.get("name") or o.get("test_name") or k))
    elif isinstance(o,list):
        for v in o: walk(v,path)
walk(d)
print("DCGM r4:", dict(c), "runtime_error:", str(d.get("DCGM Diagnostic",{}).get("runtime_error",""))[:160])
for f in fails[:20]: print("  ", f)
PY
