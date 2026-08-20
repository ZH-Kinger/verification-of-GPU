"""拓扑感知的多机慢节点体检。

相对原版 preflight.py 的改动只有三处，测量方法本身没动：
  1. 跨节点配对从"按 index 相邻"改为按拓扑分类（同组 / 跨组），各类各比各自基线；
  2. NCCL / Python 环境不再写死，全部由 straggler_check.sh 从 profile 注入；
  3. 除人读表格外落一份 straggler.json，供 check_cluster.sh 判定与归档。

保留的原版判据（都是踩过坑的，不要改）：
  - 基线取中位数不取均值：均值会被慢节点自己拉偏，多卡同时变慢时会漏检；
  - 两轮换位、两轮都慢才判慢：单轮慢可能是对端的锅；
  - 绝对下限兜底：全员一起劣化时相对比较会全绿；
  - 发现慢节点后转入循环压测保持 job 存活，且 holding 有粘性。
"""
import json
import math
import os
import socket
import statistics
import subprocess
import sys
import time

import torch
import torch.distributed as dist

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import cluster_topology as ct

MB = 1024 * 1024
# metrics 前 7 列：compute / ring / allreduce / 温度 / 功耗 / SM时钟 / 降频位
TELEMETRY_COLS = 7


def env_f(name, default):
    return float(os.environ.get(name, default))


def env_i(name, default):
    return int(os.environ.get(name, default))


# ------------------------------------------------------------------ 测量
def read_telemetry(local_rank):
    """采本卡的温度/功耗/SM 时钟/降频位。判出慢节点却答不出为什么慢，
    就得再上机查一遍 —— 而这些信息在测的当下就在机器上。
    新驱动把 clocks_throttle_reasons 改名为 clocks_event_reasons，先试新名再回退。
    取不到一律 nan，不兜底成 0（0 在降频位里的含义是"一切正常"，会掩盖采集失败）。"""
    nan = float("nan")
    for field in ("clocks_event_reasons.active", "clocks_throttle_reasons.active"):
        try:
            out = subprocess.run(
                ["nvidia-smi", f"--id={local_rank}",
                 f"--query-gpu=temperature.gpu,power.draw,clocks.current.sm,{field}",
                 "--format=csv,noheader,nounits"],
                capture_output=True, text=True, timeout=15)
        except (OSError, subprocess.SubprocessError):
            return nan, nan, nan, nan
        if out.returncode != 0:
            continue
        parts = [p.strip() for p in out.stdout.strip().splitlines()[0].split(",")]
        if len(parts) < 4:
            continue

        def num(x):
            try:
                return float(x)
            except ValueError:
                return nan

        mask = nan
        if parts[3].lower().startswith("0x"):
            try:
                mask = float(int(parts[3], 16))
            except ValueError:
                mask = nan
        return num(parts[0]), num(parts[1]), num(parts[2]), mask
    return nan, nan, nan, nan


def test_local_compute(device, iterations, n=4096):
    a = torch.randn(n, n, device=device)
    b = torch.randn(n, n, device=device)
    # 复用输出张量：原来每轮 `_ = torch.matmul(a, b)` 都新分配一个 n*n，
    # caching allocator 虽便宜，但把分配噪声混进了算力测量。
    c = torch.empty(n, n, device=device)
    for _ in range(50):
        torch.matmul(a, b, out=c)
    torch.cuda.synchronize()
    dist.barrier()
    t0 = time.perf_counter()
    for _ in range(iterations):
        torch.matmul(a, b, out=c)
    torch.cuda.synchronize()
    return time.perf_counter() - t0


def gemm_tflops(elapsed_s, iterations, n):
    """把耗时归一成 TFLOPS。绝对下限必须用 TFLOPS 而不是秒数 ——
    秒数会随 PREFLIGHT_COMPUTE_ITERS 变化，阈值一改迭代数就失效。"""
    if elapsed_s is None or elapsed_s <= 0 or math.isnan(elapsed_s):
        return float("nan")
    return iterations * 2.0 * (n ** 3) / elapsed_s / 1e12


def p2p_exchange(send_t, send_peer, recv_t, recv_peer):
    reqs = dist.batch_isend_irecv([
        dist.P2POp(dist.isend, send_t, send_peer),
        dist.P2POp(dist.irecv, recv_t, recv_peer),
    ])
    for r in reqs:
        r.wait()


def test_ring_p2p(device, rank, world_size, msg_mb, iterations):
    """环形 P2P：整体被最慢链路拖平，只能证明存在慢链路，定位靠 pairwise。"""
    t = torch.randn((msg_mb * MB) // 4, device=device)
    r = torch.empty_like(t)
    nxt, prv = (rank + 1) % world_size, (rank - 1 + world_size) % world_size
    p2p_exchange(t, nxt, r, prv)
    torch.cuda.synchronize()
    dist.barrier()
    t0 = time.perf_counter()
    for _ in range(iterations):
        p2p_exchange(t, nxt, r, prv)
    torch.cuda.synchronize()
    return (msg_mb * MB * iterations / (time.perf_counter() - t0)) / (1024 ** 3)


def test_allreduce(device, msg_mb, iterations):
    t = torch.randn((msg_mb * MB) // 4, device=device)
    dist.all_reduce(t)
    torch.cuda.synchronize()
    dist.barrier()
    t0 = time.perf_counter()
    for _ in range(iterations):
        dist.all_reduce(t)
    torch.cuda.synchronize()
    return time.perf_counter() - t0


def measure_pair(device, peer_rank, msg_mb, iterations, lat_trials, lat_iters, send_first):
    """对给定对端测一轮带宽 + ping-pong 延迟。peer_rank 为 None 表示轮空。
    返回 (bw_GBs, lat_median_us, lat_max_us)，轮空为 nan。"""
    nan = float("nan")
    dist.barrier()
    if peer_rank is None:
        return nan, nan, nan

    t = torch.randn((msg_mb * MB) // 4, device=device)
    r = torch.empty_like(t)
    p2p_exchange(t, peer_rank, r, peer_rank)
    torch.cuda.synchronize()

    t0 = time.perf_counter()
    for _ in range(iterations):
        p2p_exchange(t, peer_rank, r, peer_rank)
    torch.cuda.synchronize()
    bw = (msg_mb * MB * iterations / (time.perf_counter() - t0)) / (1024 ** 3)

    # 8 字节 ping-pong。含 ~15-30µs NCCL 启动开销，只用于节点间横比，
    # 不代表线缆级延迟。中位抗抖动，最大值暴露毛刺（重传/绕路是尖峰不是均降）。
    small = torch.ones(2, device=device)

    def pingpong():
        if send_first:
            dist.send(small, peer_rank)
            dist.recv(small, peer_rank)
        else:
            dist.recv(small, peer_rank)
            dist.send(small, peer_rank)

    for _ in range(20):
        pingpong()
    torch.cuda.synchronize()
    lats = []
    for _ in range(lat_trials):
        t0 = time.perf_counter()
        for _ in range(lat_iters):
            pingpong()
        torch.cuda.synchronize()
        lats.append((time.perf_counter() - t0) / lat_iters / 2 * 1e6)
    return bw, statistics.median(lats), max(lats)


# ------------------------------------------------------------------ 一轮体检
def run_round(rank, world_size, lws, device, hosts, topo, cfg):
    num_nodes = world_size // lws
    node_names = [hosts[n * lws] for n in range(num_nodes)]
    my_node = rank // lws
    local_rank = rank % lws

    compute_t = test_local_compute(device, cfg["compute_iters"], cfg["gemm_n"])
    # 紧跟算力测试之后采 —— 降频只在负载峰值才看得见，空闲时采等于没采
    temp_c, power_w, sm_mhz, throttle = read_telemetry(local_rank)
    ring_bw = test_ring_p2p(device, rank, world_size, cfg["msg_mb"], cfg["bw_iters"])
    ar_t = test_allreduce(device, cfg["msg_mb"], cfg["bw_iters"])

    pairings = ct.build_pairings(node_names, topo)
    per_round = []
    for _cls, _shift, pairs in pairings:
        partner_name = pairs.get(node_names[my_node])
        if partner_name is None:
            peer = None
            send_first = True
        else:
            partner_node = node_names.index(partner_name)
            peer = partner_node * lws + local_rank
            send_first = my_node < partner_node
        per_round.append(measure_pair(device, peer, cfg["msg_mb"], cfg["bw_iters"],
                                      cfg["lat_trials"], cfg["lat_iters"], send_first))

    flat = [compute_t, ring_bw, ar_t, temp_c, power_w, sm_mhz, throttle]
    for bw, lm, lx in per_round:
        flat += [bw, lm, lx]
    metrics = torch.tensor(flat, dtype=torch.float64, device=device)
    gathered = [torch.zeros_like(metrics) for _ in range(world_size)]
    dist.all_gather(gathered, metrics)

    decision = torch.tensor([0], dtype=torch.int32, device=device)
    payload = {}

    if rank == 0:
        M = torch.stack(gathered).cpu()
        payload = summarize(M, node_names, hosts, topo, pairings, lws, num_nodes, cfg)
        if payload["has_straggler"]:
            decision[0] = 1

    dist.broadcast(decision, src=0)
    return decision[0].item() == 1, payload


def summarize(M, node_names, hosts, topo, pairings, lws, num_nodes, cfg):
    ratio = cfg["min_ratio"]
    compute_times = [M[i, 0].item() for i in range(M.shape[0])]
    ring_bws = [M[i, 1].item() for i in range(M.shape[0])]
    ar_times = [M[i, 2].item() for i in range(M.shape[0])]

    ref_compute = ct._median(compute_times)
    ref_ring = ct._median(ring_bws)
    has_straggler = False

    temps = [M[i, 3].item() for i in range(M.shape[0])]
    powers = [M[i, 4].item() for i in range(M.shape[0])]
    sm_clocks = [M[i, 5].item() for i in range(M.shape[0])]
    throttles = [M[i, 6].item() for i in range(M.shape[0])]
    temp_ref, power_ref = ct._median(temps), ct._median(powers)

    min_tflops = cfg.get("min_compute_tflops", 0) or 0
    min_ring = cfg.get("min_ring_gbps", 0) or 0

    gpus = []
    for i in range(M.shape[0]):
        c_ratio = ref_compute / compute_times[i] if compute_times[i] > 0 else 0.0
        n_ratio = ring_bws[i] / ref_ring if ref_ring else 0.0
        tflops = gemm_tflops(compute_times[i], cfg.get("compute_iters", 0), cfg.get("gemm_n", 4096))

        # 算力：相对中位 + 绝对下限。只有相对比较时，整批一起降频会让中位数
        # 跟着降，全绿 —— 这类静默漏检比误报危险得多。
        c_slow = c_ratio < ratio
        c_floor_hit = bool(min_tflops) and not math.isnan(tflops) and tflops < min_tflops

        # Ring：**只对绝对下限判**。环形通信是同步的，一条慢链路会把整个环拖平，
        # 各 rank 测出的带宽几乎相同 -> 中位数也相同 -> 逐 rank 比值恒约 100%，
        # 这个判据结构上几乎不可能触发。比值保留为参考列，不参与判定。
        n_floor_hit = bool(min_ring) and ring_bws[i] < min_ring

        slow = c_slow or c_floor_hit or n_floor_hit
        has_straggler = has_straggler or slow
        reasons, perf_throttle = ct.decode_throttle(throttles[i])
        entry = {"rank": i, "host": hosts[i], "compute_s": compute_times[i],
                 "compute_tflops": tflops, "compute_ratio": c_ratio,
                 "compute_below_floor": c_floor_hit,
                 "ring_gbs": ring_bws[i], "ring_ratio": n_ratio,
                 "ring_below_floor": n_floor_hit, "slow": slow,
                 "temp_c": temps[i], "power_w": powers[i], "sm_mhz": sm_clocks[i],
                 "throttle_reasons": reasons, "throttle_perf": perf_throttle}
        # 归因只对判慢的卡做 —— 健康卡带一行"未见异常"只是噪音。
        # 但性能类降频位即使没判慢也要报：它是即将变慢的前兆。
        if slow:
            trig = []
            if c_slow:
                trig.append(f"算力低于同批中位（{c_ratio*100:.0f}%）")
            if c_floor_hit:
                trig.append(f"算力 {tflops:.1f} TFLOPS 低于绝对下限 {min_tflops:.1f}")
            if n_floor_hit:
                trig.append(f"Ring {ring_bws[i]:.1f} GB/s 低于绝对下限 {min_ring:.1f}")
            entry["trigger"] = "；".join(trig)
            entry["attribution"] = ct.attribute(temps[i], powers[i], sm_clocks[i],
                                                throttles[i], temp_ref, power_ref)
        elif perf_throttle:
            entry["attribution"] = "未判慢但已出现降频：" + "、".join(reasons)
        gpus.append(entry)

    # 节点聚合带宽 = 该节点各 rank 单向带宽之和；节点延迟取各 rank 中最差
    classes = {}
    for idx, (cls, shift, _pairs) in enumerate(pairings):
        base = TELEMETRY_COLS + idx * 3
        bw_s, lat_s = classes.setdefault(cls, ({}, {}))
        for n in range(num_nodes):
            vals = [M[n * lws + l, base].item() for l in range(lws)]
            if math.isnan(vals[0]):
                bw_s.setdefault(node_names[n], []).append(float("nan"))
                lat_s.setdefault(node_names[n], []).append(float("nan"))
                continue
            bw_s.setdefault(node_names[n], []).append(sum(vals))
            lat_s.setdefault(node_names[n], []).append(
                max(M[n * lws + l, base + 1].item() for l in range(lws)))

    nodes_out, verdicts = [], {}
    for cls, (bw_s, lat_s) in classes.items():
        bw_v, bw_base = ct.judge_class(bw_s, ratio, True, cfg["min_p2p_gbps"])
        lat_v, lat_base = ct.judge_class(lat_s, ratio, False)
        for name in bw_s:
            flagged = bw_v[name] or lat_v[name]
            verdicts.setdefault(name, {})[cls] = {
                "bw_gbs": bw_s[name], "lat_us": lat_s[name],
                "bw_baseline": bw_base, "lat_baseline": lat_base,
                "bw_slow": bw_v[name], "lat_slow": lat_v[name], "slow": flagged,
            }
            has_straggler = has_straggler or flagged

    for n, name in enumerate(node_names):
        nodes_out.append({"node": n, "host": name, "group": ct.group_of(topo, name),
                          "classes": verdicts.get(name, {})})

    class_stats = {cls: {"bw": bw_s, "lat": lat_s} for cls, (bw_s, lat_s) in classes.items()}
    slow_names = [n["host"] for n in nodes_out
                  if any(c.get("slow") for c in n["classes"].values())]
    topo_view = ct.topology_summary(node_names, topo, class_stats, slow_names)

    print_report(gpus, nodes_out, ar_times, classes, ratio, cfg)
    print("-" * (120 + max(len(g["host"]) for g in gpus)))
    print(ct.render_topology(topo_view))
    print("=" * (120 + max(len(g["host"]) for g in gpus)))
    return {"has_straggler": has_straggler, "gpus": gpus, "nodes": nodes_out,
            "topology": topo_view,
            "allreduce_mean_s": sum(ar_times) / len(ar_times),
            "min_perf_ratio": ratio, "min_p2p_gbps": cfg["min_p2p_gbps"],
            "min_compute_tflops": min_tflops, "min_ring_gbps": min_ring,
            "groups": sorted({ct.group_of(topo, h) for h in node_names})}


def print_report(gpus, nodes_out, ar_times, classes, ratio, cfg):
    hw = max(len(g["host"]) for g in gpus)
    width = 120 + hw
    print("=" * width)
    print("集群全节点性能 Baseline Summary（基线取中位数，均值会被慢节点自己拉偏）")
    print("=" * width)
    print(f"{'Rank':<6} | {'Host':<{hw}} | {'TFLOPS':<9} | {'Perf':<9} | "
          f"{'Ring BW(GB/s)':<14} | {'Ring比(参考)':<11} | {'温度':<5} | {'功耗':<5} | {'SM时钟':<6}")
    print("-" * width)
    for g in gpus:
        ca = " !" if g["compute_ratio"] < ratio else ""
        na = " !" if g["ring_ratio"] < ratio else ""
        def fmt(v, unit=""):
            return "  n/a" if v is None or math.isnan(v) else f"{v:>4.0f}{unit}"
        cf = " !" if g.get("compute_below_floor") else ca
        rf = " !" if g.get("ring_below_floor") else ""
        tf = g.get("compute_tflops", float("nan"))
        tfs = "     n/a" if tf is None or math.isnan(tf) else f"{tf:>9.1f}"
        print(f"{g['rank']:<6} | {g['host']:<{hw}} | {tfs} | "
              f"{g['compute_ratio']*100:>6.1f}%{cf:<2} | {g['ring_gbs']:<10.2f}{rf:<4} | "
              f"{g['ring_ratio']*100:>6.1f}%      | {fmt(g['temp_c'],'C')} | "
              f"{fmt(g['power_w'],'W')} | {fmt(g['sm_mhz'])}")
    attributed = [g for g in gpus if g.get("attribution")]
    if attributed:
        print("-" * width)
        print("归因（降频位是硬证据；温度/功耗只是同批离群，措辞已区分）")
        for g in attributed:
            trig = g.get("trigger")
            print(f"  rank {g['rank']:<3} {g['host']:<{hw}}  "
                  + (f"[{trig}] " if trig else "") + g["attribution"])
    print("-" * width)
    print(f"[*] 全局 All-Reduce 平均耗时: {sum(ar_times)/len(ar_times):.4f}s")
    # 阈值未校准要印在报告体里，不能只印在会滚走的启动横幅里 ——
    # 报告是归档件，看报告的人必须知道哪几项其实没有绝对下限兜底。
    missing = []
    if not cfg.get("min_compute_tflops"):
        missing.append("算力(TFLOPS)")
    if not cfg.get("min_ring_gbps"):
        missing.append("Ring 带宽")
    if not cfg.get("min_p2p_gbps"):
        missing.append("Pairwise 带宽")
    if missing:
        print(f"[!] 以下项未设绝对下限：{'、'.join(missing)}。"
              f"这些项只做批内相对比较，整批一起劣化时会全绿 —— 首批实测后回填 profile。")

    for cls in classes:
        label = "同组（同 leaf/rail）" if cls == "intra" else "跨组（跨 leaf/spine）"
        print("-" * width)
        print(f"跨节点 Pairwise 定位 — {label}：带宽或延迟两轮都差 ⇒ 该节点是慢节点")
        print(f"{'Node':<6} | {'Host':<{hw}} | {'Group':<10} | {'R1 BW':<10} | {'R1 Lat':<10} | "
              f"{'R2 BW':<10} | {'R2 Lat':<10} | {'Verdict':<8}")
        print("-" * width)
        for nd in nodes_out:
            c = nd["classes"].get(cls)
            if not c:
                continue
            cells = []
            for r in (0, 1):
                bw = c["bw_gbs"][r] if r < len(c["bw_gbs"]) else float("nan")
                lat = c["lat_us"][r] if r < len(c["lat_us"]) else float("nan")
                cells.append("轮空".ljust(10) if math.isnan(bw) else f"{bw:>8.2f}  ")
                cells.append("轮空".ljust(10) if math.isnan(lat) else f"{lat:>8.1f}  ")
            print(f"{nd['node']:<6} | {nd['host']:<{hw}} | {nd['group']:<10} | "
                  f"{cells[0]} | {cells[1]} | {cells[2]} | {cells[3]} | "
                  f"{'SLOW' if c['slow'] else 'OK':<8}")
    if len(nodes_out) == 2:
        print("[*] 注意: 仅 2 节点时两轮配对相同, 只能证明链路差, 无法区分是哪个节点")
    if len(set(nd["group"] for nd in nodes_out)) == 1:
        print("[*] 注意: 只有一个拓扑组（未提供 topology 文件？）—— 跨组对比未执行，")
        print("          rail-optimized fabric 上这会让跨 spine 的差异混进同一个基线")
    print("=" * width)


def json_safe(obj):
    """NaN/Inf 不是合法 JSON —— Python 自己能读回来，jq 也宽容，但严格解析器会拒。
    这份文件要进验收证据并被别的工具读，统一转成 null（语义就是"轮空/无数据"）。"""
    if isinstance(obj, dict):
        return {k: json_safe(v) for k, v in obj.items()}
    if isinstance(obj, (list, tuple)):
        return [json_safe(v) for v in obj]
    if isinstance(obj, float) and not math.isfinite(obj):
        return None
    return obj


def main():
    dist.init_process_group(backend="nccl")
    rank, world_size = dist.get_rank(), dist.get_world_size()
    local_rank = int(os.environ.get("LOCAL_RANK", 0))
    lws = int(os.environ.get("LOCAL_WORLD_SIZE", str(world_size)))
    torch.cuda.set_device(local_rank)
    device = torch.device(f"cuda:{local_rank}")

    cfg = {
        "min_ratio": env_f("PREFLIGHT_MIN_PERF_RATIO", 0.8),
        "min_p2p_gbps": env_f("PREFLIGHT_MIN_P2P_GBPS", 0),
        "msg_mb": env_i("PREFLIGHT_MSG_MB", 100),
        "bw_iters": env_i("PREFLIGHT_BW_ITERS", 50),
        "compute_iters": env_i("PREFLIGHT_COMPUTE_ITERS", 2000),
        "gemm_n": env_i("PREFLIGHT_GEMM_N", 4096),
        "min_compute_tflops": env_f("PREFLIGHT_MIN_COMPUTE_TFLOPS", 0),
        "min_ring_gbps": env_f("PREFLIGHT_MIN_RING_GBPS", 0),
        "lat_trials": env_i("PREFLIGHT_LAT_TRIALS", 5),
        "lat_iters": env_i("PREFLIGHT_LAT_ITERS", 200),
    }
    loop_mode = os.environ.get("PREFLIGHT_LOOP", "0") == "1"
    loop_interval = env_f("PREFLIGHT_LOOP_INTERVAL", 30)
    loop_on_straggler = os.environ.get("PREFLIGHT_LOOP_ON_STRAGGLER", "1") == "1"
    out_json = os.environ.get("PREFLIGHT_JSON", "")

    topo_text = ""
    topo_file = os.environ.get("PREFLIGHT_TOPO_FILE", "")
    if topo_file and os.path.isfile(topo_file):
        with open(topo_file, encoding="utf-8") as fh:
            topo_text = fh.read()
    topo = ct.parse_topology(topo_text)

    hosts = [None] * world_size
    dist.all_gather_object(hosts, socket.gethostname())

    if rank == 0:
        print(f"\n[*] 集群体检启动: {world_size} GPUs ({world_size // lws} nodes x {lws})")
        floors = []
        if cfg["min_compute_tflops"] > 0:
            floors.append(f"算力 >= {cfg['min_compute_tflops']:.1f} TFLOPS")
        if cfg["min_ring_gbps"] > 0:
            floors.append(f"Ring >= {cfg['min_ring_gbps']:.1f} GB/s")
        if cfg["min_p2p_gbps"] > 0:
            floors.append(f"Pairwise >= {cfg['min_p2p_gbps']:.1f} GB/s")
        print("[*] 绝对下限: " + ("；".join(floors) if floors
              else "未设 —— 整批一起劣化时相对比较会全绿，强烈建议在 profile 里填实"))
        print("[*] Ring 比值仅供参考不参与判定：环形同步会被最慢链路拖平，各 rank 值几乎相同")
        print(f"[*] 最小性能容忍度: {cfg['min_ratio']*100:.1f}%"
              + (f"；Pairwise 节点带宽绝对下限 {cfg['min_p2p_gbps']:.1f} GB/s" if cfg["min_p2p_gbps"] > 0 else ""))
        print(f"[*] 拓扑来源: {topo_file or '（未提供，退化为单组比较）'}")
        if loop_mode:
            print(f"[*] 无限循环模式，每轮间隔 {loop_interval:.0f}s")
        print()

    round_idx, holding, has_straggler, payload = 0, False, False, {}
    while True:
        round_idx += 1
        if rank == 0 and (loop_mode or holding):
            print(f"\n[*] ===== Round {round_idx} @ {time.strftime('%Y-%m-%d %H:%M:%S')} =====")

        has_straggler, payload = run_round(rank, world_size, lws, device, hosts, topo, cfg)

        if rank == 0 and out_json:
            payload["round"] = round_idx
            payload["timestamp"] = time.strftime("%Y-%m-%dT%H:%M:%S%z")
            with open(out_json, "w", encoding="utf-8") as fh:
                json.dump(json_safe(payload), fh, ensure_ascii=False,
                          indent=2, allow_nan=False)

        was_holding = holding
        # holding 有粘性：发现过慢节点就不再放行，偶发恢复的一轮不算数
        holding = holding or (has_straggler and (loop_mode or loop_on_straggler))
        keep_looping = loop_mode or holding
        if rank == 0:
            if has_straggler:
                print("[X] 体检失败：发现低于容忍阈值的慢节点"
                      + ("，继续循环压测..." if keep_looping else "，退出"))
                if keep_looping and not loop_mode and not was_holding:
                    print("[*] 转入循环压测以保持 job 存活供确认（PREFLIGHT_LOOP_ON_STRAGGLER=0 改为直接退出）")
            else:
                print("[OK] 体检通过：集群均一性良好"
                      + ("，继续循环压测..." if keep_looping else ""))
        if not keep_looping:
            break
        time.sleep(loop_interval)

    dist.destroy_process_group()
    sys.exit(1 if has_straggler else 0)


if __name__ == "__main__":
    main()
