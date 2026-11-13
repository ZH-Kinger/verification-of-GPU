#!/usr/bin/env python3
import json, sys
try:
    j = json.load(sys.stdin)["jobs"][0]
except Exception as e:
    print(f"FAIL({type(e).__name__})"); sys.exit()
r, w = j["read"], j["write"]
s = r if r["iops"] >= w["iops"] else w
p = s["clat_ns"].get("percentile", {})
print(f"{(r['bw_bytes']+w['bw_bytes'])/1e9:.2f}GB/s {r['iops']+w['iops']:.0f}IOPS avg={s['clat_ns']['mean']/1000:.0f}us p99={p.get('99.000000',0)/1000:.0f}us")
