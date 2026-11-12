#!/usr/bin/env python3
"""单卡 GEMM 持续 20 秒，期间后台每 0.5 s 采样功耗 / SM 频率 / 降频原因，取稳态段中位数。
用于判断 GEMM 只到 70% 是功耗墙（SW Power Cap）还是别的原因。
用法: CUDA_VISIBLE_DEVICES=<physical idx> python3 gemm_power.py <physical idx>
"""
import json, statistics, subprocess, sys, threading, time
import torch
phys = sys.argv[1]
dev = 0
torch.cuda.set_device(dev)
samples = []
stop = False
def sampler():
    while not stop:
        o = subprocess.run(["nvidia-smi", "-i", phys, "--query-gpu=power.draw,clocks.sm,clocks_event_reasons.active,temperature.gpu",
                            "--format=csv,noheader,nounits"], capture_output=True, text=True).stdout.strip()
        try:
            p, c, r, t = [x.strip() for x in o.split(",")]
            samples.append((time.time(), float(p), float(c), r, float(t)))
        except ValueError:
            pass
        time.sleep(0.5)
for name, dt, n in (("bf16", torch.bfloat16, 12288), ("fp8", None, 16384)):
    if dt is None:
        a = torch.randn(n, n, device=dev).to(torch.float8_e4m3fn); b = torch.randn(n, n, device=dev).to(torch.float8_e4m3fn).t()
        one = torch.tensor(1.0, device=dev)
        f = lambda: torch._scaled_mm(a, b, scale_a=one, scale_b=one, out_dtype=torch.bfloat16, use_fast_accum=True)
    else:
        a = torch.randn(n, n, device=dev, dtype=dt); b = torch.randn(n, n, device=dev, dtype=dt)
        f = lambda: torch.mm(a, b)
    for _ in range(10): f()
    torch.cuda.synchronize()
    samples.clear(); stop = False
    th = threading.Thread(target=sampler); th.start()
    t0 = time.time(); k = 0
    ev0 = torch.cuda.Event(True); ev1 = torch.cuda.Event(True)
    while time.time() - t0 < 20:
        for _ in range(20): f()
        k += 20
        torch.cuda.synchronize()
    dt_s = time.time() - t0
    stop = True; th.join()
    steady = [s for s in samples if s[0] - t0 > 5]
    reasons = sorted({s[3] for s in steady})
    print(json.dumps(dict(gpu=int(phys), dtype=name, n=n, tflops=round(2 * n**3 * k / dt_s / 1e12, 1),
        power_med=round(statistics.median(s[1] for s in steady), 1), sm_med=statistics.median(s[2] for s in steady),
        sm_min=min(s[2] for s in steady), temp_max=max(s[4] for s in steady), reasons=reasons)), flush=True)
    del a, b; torch.cuda.empty_cache()
