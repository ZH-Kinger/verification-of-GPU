#!/usr/bin/env python3
"""把各节点 run log 的 @@RESULT 汇总成对比表，并按 H200 阈值（需求书附录 A.2 / profiles/h200_8gpu.env）判定。

用法: summarize.py results/node-a2/latest.log results/node-b2/latest.log
判定口径：PASS / FAIL / REF(参考，无阈值) / HOLD(口径不一致，待标准工具复测)。
"""
import json, re, statistics, sys
from collections import defaultdict

TH = {  # 阈值来源：docs/gpu_rental_rfp.md 附录 A.2 + profiles/h200_8gpu.env
    "allreduce_busbw": 350, "allgather_busbw": 290, "p2p_gbs": 345,
    "hbm_pass_gbs": 4300, "hbm_retest_gbs": 4100, "temp_max_c": 86,
    "gpu_mem_mib": 140000, "power_w": 700, "power_tol": 10,
}


def parse(path):
    rs, inv, samples, in_s = [], {}, [], False
    for line in open(path, errors="replace"):
        if line.startswith("@@RESULT "):
            try:
                rs.append(json.loads(line[9:]))
            except ValueError:
                pass
        elif line.startswith("@@BURN_SAMPLES_BEGIN"):
            in_s = True
        elif line.startswith("@@BURN_SAMPLES_END"):
            in_s = False
        elif in_s and line.strip():
            samples.append([c.strip() for c in line.split(",")])
        m = re.match(r"^(\d), NVIDIA (\S+), (\d+), (GPU-\S+), (\S+), (\d+) MiB, (\w+), ([\d.]+) W, [\d.]+ W, \d+ MHz, \d+ MHz, (\d), (\d+), (\d), (\d+), ([\d.]+), (\S+), ", line)
        if m:
            inv[int(m[1])] = dict(model=m[2], serial=m[3], mem=int(m[6]), ecc=m[7], plim=float(m[8]),
                                  pcie=f"Gen{m[11]} x{m[12]}", driver=m[13], vbios=m[14])
    return rs, inv, samples


def verdict(v, th, higher=True, retest=None):
    if v is None:
        return "SKIP"
    if retest is not None and retest <= v < th:
        return "HOLD"  # 低于通过线、高于复测线：须用标准工具复测，不直接判 FAIL
    ok = v >= th if higher else v <= th
    return "PASS" if ok else "FAIL"


def main(paths):
    nodes = {}
    for p in paths:
        name = p.split("/")[-2]
        nodes[name] = parse(p)
    rows = []
    for name, (rs, inv, samples) in nodes.items():
        big = lambda op: max((r["busbw"] for r in rs if r["kind"] == "nccl" and r["op"] == op), default=None)
        p2p = [x for r in rs if r["kind"] == "p2p_row" for x in r["gbs"] if x]
        hbm = [r["gbs"] for r in rs if r["kind"] == "hbm"]
        bf16 = [r["tflops"] for r in rs if r["kind"] == "gemm" and r["dtype"] == "bf16"]
        burn = [r for r in rs if r["kind"] == "burn"]
        temps = [float(s[1]) for s in samples if len(s) > 1 and s[1].replace(".", "").isdigit()]
        d = {
            "allreduce": big("all_reduce"), "allgather": big("all_gather"),
            "p2p_min": min(p2p) if p2p else None, "hbm_min": min(hbm) if hbm else None,
            "bf16_median": statistics.median(bf16) if bf16 else None,
            "bf16_min": min(bf16) if bf16 else None,
            "burn_tflops_min": min((b["tflops"] for b in burn), default=None),
            "burn_mismatch": sum(b["mismatches"] for b in burn) if burn else None,
            "temp_max": max(temps) if temps else None,
            "inv": inv,
        }
        rows.append((name, d))
    print(f"{'项目':28s}" + "".join(f"{n:>18s}" for n, _ in rows) + "   阈值")
    def line(label, key, th=None, higher=True, fmt="{:.1f}", retest=None):
        vals = [d[key] for _, d in rows]
        cells = []
        for v in vals:
            if v is None:
                cells.append(f"{'—':>18s}")
            else:
                vd = "" if th is None else " " + verdict(v, th, higher, retest)
                cells.append(f"{(fmt.format(v) + vd):>18s}")
        print(f"{label:28s}" + "".join(cells) + (f"   {'≥' if higher else '≤'}{th}" if th is not None else "   参考"))
    line("NCCL AllReduce busbw GB/s", "allreduce", TH["allreduce_busbw"])
    line("NCCL AllGather busbw GB/s", "allgather", TH["allgather_busbw"])
    line("P2P 单向 min GB/s", "p2p_min", TH["p2p_gbs"])
    line("HBM copy min GB/s (torch口径)", "hbm_min", TH["hbm_pass_gbs"], retest=TH["hbm_retest_gbs"])
    line("GEMM bf16 median TFLOPS", "bf16_median")
    line("GEMM bf16 min TFLOPS", "bf16_min")
    line("burn 期间最低 TFLOPS", "burn_tflops_min")
    line("burn 结果不一致次数", "burn_mismatch", 0, higher=False, fmt="{:.0f}")
    line("burn 期间最高温度 ℃", "temp_max", TH["temp_max_c"], higher=False, fmt="{:.0f}")
    # 同批次横向比对：任一指标低于两台中位数 10% → FAIL（需求书 5.2.3）
    if len(rows) >= 2:
        print("\n同批次比对（低于中位数 10% 判 FAIL）:")
        for key in ("allreduce", "allgather", "p2p_min", "hbm_min", "bf16_median", "burn_tflops_min"):
            vals = [d[key] for _, d in rows if d[key] is not None]
            if len(vals) < 2:
                continue
            med = statistics.median(vals)
            for n, d in rows:
                if d[key] is not None:
                    dev = (d[key] - med) / med * 100
                    flag = "FAIL" if dev < -10 else "ok"
                    print(f"  {key:16s} {n:10s} {d[key]:9.1f}  vs 中位数 {med:9.1f}  {dev:+5.1f}%  {flag}")
        print("\n批次一致性（需求书 5.4.1）:")
        for attr in ("model", "vbios", "driver", "mem", "plim", "pcie", "ecc"):
            per = {n: sorted({str(g[attr]) for g in d["inv"].values()}) for n, d in rows}
            allv = {v for vs in per.values() for v in vs}
            print(f"  {attr:8s} {'一致' if len(allv) == 1 else '不一致'}  " + "  ".join(f"{n}={'/'.join(v)}" for n, v in per.items()))


if __name__ == "__main__":
    main(sys.argv[1:])
