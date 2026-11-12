#!/usr/bin/env python3
"""单机 GPU 性能探测（只依赖 PyTorch + 自带 NCCL，镜像里没有 nccl-tests/nvbandwidth 时用）。

子命令:
  gemm     每卡 GEMM 实测 TFLOPS（bf16/fp16/tf32/fp8 若支持）
  hbm      每卡显存带宽（device-to-device copy，读+写计）
  p2p      卡间 P2P 拷贝带宽矩阵（单向，GB/s）
  nccl     torchrun 下跑：all_reduce / all_gather / reduce_scatter 的 busbw（口径同 nccl-tests）
  burn     每卡持续 GEMM N 秒（给外层采样温度/功耗用）
每条结果打印成一行 `@@RESULT {json}`，日志里 grep 出来解析。
"""
import json, os, sys, time

import torch


def emit(kind, **kw):
    kw["kind"] = kind
    print("@@RESULT " + json.dumps(kw, ensure_ascii=False), flush=True)


def timed(fn, iters, warm=3):
    for _ in range(warm):
        fn()
    torch.cuda.synchronize()
    t = time.perf_counter()
    for _ in range(iters):
        fn()
    torch.cuda.synchronize()
    return (time.perf_counter() - t) / iters


def gemm():
    n = 8192
    for dev in range(torch.cuda.device_count()):
        torch.cuda.set_device(dev)
        for name, dt in (("bf16", torch.bfloat16), ("fp16", torch.float16), ("tf32", torch.float32)):
            torch.backends.cuda.matmul.allow_tf32 = name == "tf32"
            a = torch.randn(n, n, device=dev, dtype=dt)
            b = torch.randn(n, n, device=dev, dtype=dt)
            s = timed(lambda: a @ b, 50)
            emit("gemm", gpu=dev, dtype=name, n=n, tflops=round(2 * n**3 / s / 1e12, 1))
            del a, b
        # FP8：torch._scaled_mm 需要 sm_89+；失败就记录原因而不是跳过不报
        try:
            a = torch.randn(n, n, device=dev).to(torch.float8_e4m3fn)
            b = torch.randn(n, n, device=dev).to(torch.float8_e4m3fn).t()
            one = torch.tensor(1.0, device=dev)
            f = lambda: torch._scaled_mm(a, b, scale_a=one, scale_b=one, out_dtype=torch.bfloat16)
            s = timed(f, 50)
            emit("gemm", gpu=dev, dtype="fp8", n=n, tflops=round(2 * n**3 / s / 1e12, 1))
        except Exception as e:  # noqa: BLE001
            emit("gemm", gpu=dev, dtype="fp8", error=str(e)[:200])
        torch.cuda.empty_cache()


def hbm():
    nbytes = 4 << 30
    for dev in range(torch.cuda.device_count()):
        torch.cuda.set_device(dev)
        src = torch.empty(nbytes, dtype=torch.uint8, device=dev)
        dst = torch.empty_like(src)
        s = timed(lambda: dst.copy_(src), 20)
        # copy 读 N 字节 + 写 N 字节，按 2N 计（与 nvbandwidth device_local_copy 口径一致）
        emit("hbm", gpu=dev, gbs=round(2 * nbytes / s / 1e9, 1))
        del src, dst
        torch.cuda.empty_cache()


def p2p():
    n = torch.cuda.device_count()
    nbytes = 1 << 30
    bufs = [torch.empty(nbytes, dtype=torch.uint8, device=d) for d in range(n)]
    for i in range(n):
        row = []
        for j in range(n):
            if i == j:
                row.append(None)
                continue
            ok = torch.cuda.can_device_access_peer(i, j)
            with torch.cuda.device(i):
                s = timed(lambda: bufs[j].copy_(bufs[i], non_blocking=True), 10, warm=2)
            row.append(round(nbytes / s / 1e9, 1))
            if not ok:
                emit("p2p_access", src=i, dst=j, peer_access=False)
        emit("p2p_row", src=i, gbs=row)


def nccl():
    import torch.distributed as dist
    dist.init_process_group("nccl")
    rank, world = dist.get_rank(), dist.get_world_size()
    torch.cuda.set_device(int(os.environ.get("LOCAL_RANK", rank)))
    sizes = [1 << 20, 16 << 20, 128 << 20, 512 << 20, 1 << 30, 2 << 30, 4 << 30, 8 << 30]
    for op in ("all_reduce", "all_gather", "reduce_scatter"):
        for size in sizes:
            numel = size // 2  # bf16
            x = torch.ones(numel, dtype=torch.bfloat16, device="cuda")
            if op == "all_reduce":
                f = lambda: dist.all_reduce(x)
                factor = 2 * (world - 1) / world
            elif op == "all_gather":
                part = x[: numel // world]
                f = lambda: dist.all_gather_into_tensor(x, part)
                factor = (world - 1) / world
            else:
                out = x[: numel // world].clone()
                f = lambda: dist.reduce_scatter_tensor(out, x)
                factor = (world - 1) / world
            iters = 20 if size <= (1 << 30) else 8
            s = timed(f, iters)
            if rank == 0:
                algbw = size / s / 1e9
                emit("nccl", op=op, bytes=size, world=world, time_us=round(s * 1e6, 1),
                     algbw=round(algbw, 1), busbw=round(algbw * factor, 1))
            del x
            torch.cuda.empty_cache()
    if rank == 0:
        emit("nccl_version", version=".".join(map(str, torch.cuda.nccl.version())))
    dist.destroy_process_group()


def burn(seconds):
    import threading
    n = 8192
    stop = time.time() + seconds
    counts = {}

    def work(dev):
        torch.cuda.set_device(dev)
        a = torch.randn(n, n, device=dev, dtype=torch.bfloat16)
        b = torch.randn(n, n, device=dev, dtype=torch.bfloat16)
        ref = (a @ b).float().sum().item()
        c, bad = 0, 0
        while time.time() < stop:
            for _ in range(50):
                out = a @ b
            torch.cuda.synchronize()
            c += 50
            # 结果一致性检查：同输入应得同输出，漂移即计算错误（SDC 粗筛）
            if c % 1000 == 0 and abs(out.float().sum().item() - ref) > abs(ref) * 1e-3:
                bad += 1
        counts[dev] = (c, bad)

    ts = [threading.Thread(target=work, args=(d,)) for d in range(torch.cuda.device_count())]
    t0 = time.time()
    [t.start() for t in ts]
    [t.join() for t in ts]
    dt = time.time() - t0
    for dev, (c, bad) in sorted(counts.items()):
        emit("burn", gpu=dev, seconds=round(dt), tflops=round(2 * n**3 * c / dt / 1e12, 1), mismatches=bad)


if __name__ == "__main__":
    cmd = sys.argv[1]
    if cmd == "burn":
        burn(int(sys.argv[2]))
    else:
        globals()[cmd]()
