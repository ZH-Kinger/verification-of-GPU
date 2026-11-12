#!/usr/bin/env python3
"""硬件理论值复测（单节点 8 GPU，每卡独立）。
  gemm  : bf16 / fp16 / tf32 / fp8，矩阵 4096~16384 扫描，取峰值；同时记录功耗与 SM 频率，
          区分「峰值算力」和「功耗墙下的算力」
  hbm   : 显存带宽，读写分开（read-only reduce、write-only fill、copy），2~16 GiB 扫描取最大
输出 @@RESULT json 行。
"""
import json, os, subprocess, sys, threading, time
import torch

def emit(**kw): print("@@RESULT " + json.dumps(kw), flush=True)

def smi(i):
    o = subprocess.run(["nvidia-smi", "-i", str(i), "--query-gpu=power.draw,clocks.sm,temperature.gpu",
                        "--format=csv,noheader,nounits"], capture_output=True, text=True).stdout.strip()
    p, c, t = (float(x) for x in o.split(","))
    return p, c, t

def bench(fn, iters):
    for _ in range(5): fn()
    torch.cuda.synchronize()
    ev0, ev1 = torch.cuda.Event(True), torch.cuda.Event(True)
    ev0.record()
    for _ in range(iters): fn()
    ev1.record(); torch.cuda.synchronize()
    return ev0.elapsed_time(ev1) / 1000 / iters

def gemm(dev):
    torch.cuda.set_device(dev)
    torch.backends.cuda.matmul.allow_tf32 = True
    torch.backends.cuda.matmul.allow_bf16_reduced_precision_reduction = True
    for name, dt in (("bf16", torch.bfloat16), ("fp16", torch.float16), ("tf32", torch.float32)):
        best = (0, 0, 0, 0)
        for n in (4096, 8192, 12288, 16384):
            a = torch.randn(n, n, device=dev, dtype=dt); b = torch.randn(n, n, device=dev, dtype=dt)
            iters = max(10, int(4e14 / (2 * n**3)))
            s = bench(lambda: torch.mm(a, b), iters)
            # 采样一次功耗/频率（在下一轮持续负载中）
            box = {}
            th = threading.Thread(target=lambda: (time.sleep(0.5), box.setdefault("v", smi(dev))))
            th.start(); bench(lambda: torch.mm(a, b), iters); th.join()
            tf = 2 * n**3 / s / 1e12
            if tf > best[0]: best = (tf, n, *box.get("v", (0, 0, 0))[:2])
            del a, b; torch.cuda.empty_cache()
        emit(kind="gemm", gpu=dev, dtype=name, tflops=round(best[0], 1), n=best[1], power_w=best[2], sm_mhz=best[3])
    # fp8：torch._scaled_mm，输出 fp16/bf16 中取高者；行优先 A × 列优先 B 是 cuBLASLt fp8 要求的布局
    best = (0, 0, "", 0, 0)
    for n in (8192, 12288, 16384):
        a = torch.randn(n, n, device=dev).to(torch.float8_e4m3fn)
        b = torch.randn(n, n, device=dev).to(torch.float8_e4m3fn).t()
        one = torch.tensor(1.0, device=dev)
        for od in (torch.bfloat16, torch.float16):
            try:
                f = lambda: torch._scaled_mm(a, b, scale_a=one, scale_b=one, out_dtype=od, use_fast_accum=True)
                iters = max(10, int(8e14 / (2 * n**3)))
                s = bench(f, iters)
                box = {}
                th = threading.Thread(target=lambda: (time.sleep(0.5), box.setdefault("v", smi(dev))))
                th.start(); bench(f, iters); th.join()
                tf = 2 * n**3 / s / 1e12
                if tf > best[0]: best = (tf, n, str(od).split(".")[-1], *box.get("v", (0, 0, 0))[:2])
            except Exception as e:
                emit(kind="gemm_err", gpu=dev, dtype="fp8", n=n, err=str(e)[:160])
        del a, b; torch.cuda.empty_cache()
    emit(kind="gemm", gpu=dev, dtype="fp8", tflops=round(best[0], 1), n=best[1], out=best[2], power_w=best[3], sm_mhz=best[4])

def hbm(dev):
    torch.cuda.set_device(dev)
    res = {"read": 0, "write": 0, "copy": 0}
    for gib in (2, 4, 8, 16):
        n = (gib << 30) // 4
        x = torch.empty(n, dtype=torch.float32, device=dev).fill_(1.0)
        y = torch.empty_like(x)
        r = bench(lambda: x.sum(), 20)              # 只读 N 字节
        w = bench(lambda: y.fill_(2.0), 20)          # 只写 N 字节
        c = bench(lambda: y.copy_(x), 20)            # 读 N + 写 N
        nb = n * 4
        res["read"] = max(res["read"], nb / r / 1e9)
        res["write"] = max(res["write"], nb / w / 1e9)
        res["copy"] = max(res["copy"], 2 * nb / c / 1e9)
        del x, y; torch.cuda.empty_cache()
    emit(kind="hbm", gpu=dev, **{k: round(v, 1) for k, v in res.items()})

if __name__ == "__main__":
    what = sys.argv[1]
    devs = range(torch.cuda.device_count())
    # 8 卡并行跑（每卡一个线程），既快也代表整机同时满载的情形
    ths = [threading.Thread(target=globals()[what], args=(d,)) for d in devs]
    [t.start() for t in ths]; [t.join() for t in ths]
