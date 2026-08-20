"""多机体检的拓扑与判定逻辑 —— 纯 Python，不 import torch，可离线单测。

拆出来的原因：原版 preflight 的配对是按 node index 直接相邻配对的，
在 rail-optimized fabric 上会把"同 leaf 对"和"跨 leaf 对"混进同一个中位数，
导致跨 spine 的健康节点被误判成慢节点、同 leaf 内真降级的机器反被漏判。
本模块把配对按拓扑分类，各类各比各自的基线。
"""

import math

BYE = None


# ------------------------------------------------------------------ 拓扑文件
def parse_topology(text):
    """解析 topology.tsv: `<node>\t<group>[\t<备注>]`，# 开头为注释。

    返回 {node: group}。没有拓扑文件时全部归入同一个组，行为退化成原版
    （即"认为任意两节点之间应该一样快"），但退化是显式的、会打印出来。
    """
    topo = {}
    for lineno, raw in enumerate(text.splitlines(), 1):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        parts = line.split()
        if len(parts) < 2:
            raise ValueError(f"topology 第 {lineno} 行缺少 group 列: {raw!r}")
        node, group = parts[0], parts[1]
        if node in topo and topo[node] != group:
            raise ValueError(f"topology 里 {node} 被分到两个组: {topo[node]} / {group}")
        topo[node] = group
    return topo


def group_of(topo, node, default="_unknown"):
    return topo.get(node, default)


# ------------------------------------------------------------------ 配对
def _rotate_pairs(members, shift):
    """在一个成员列表内做两轮换位配对，沿用原版语义：
    shift=0 -> (0,1)(2,3)...; shift=1 -> (1,2)(3,4)...(m-1,0)。
    成员数为奇数时每轮轮空一个。返回 {member: partner or None}。"""
    m = len(members)
    out = {x: BYE for x in members}
    if m < 2:
        return out
    for i, node in enumerate(members):
        idx = (i - shift) % m
        if m % 2 == 1 and idx == m - 1:
            continue
        j = (i + 1) % m if idx % 2 == 0 else (i - 1 + m) % m
        out[node] = members[j]
    return out


def _round_robin(groups_ordered, members_by_group):
    """把各组成员按轮转交错展开，使展开后相邻的元素尽量来自不同组。
    这是构造"跨组完美匹配"的最省事且不会重复配对的办法。"""
    out, idx = [], 0
    while True:
        added = False
        for g in groups_ordered:
            members = members_by_group[g]
            if idx < len(members):
                out.append(members[idx])
                added = True
        if not added:
            return out
        idx += 1


def build_pairings(nodes, topo):
    """返回 [(cls, shift, {node: partner|None}), ...]。

    cls='intra' 同组内配对，cls='inter' 跨组配对。每类各两轮换位，
    保留原版"两轮都慢才算慢节点"的判据 —— 单轮慢可能是对端的锅。
    跨组轮里若某对意外落在同组，按轮空处理，不污染 inter 基线。
    """
    members_by_group = {}
    for n in nodes:
        members_by_group.setdefault(group_of(topo, n), []).append(n)
    groups_ordered = sorted(members_by_group)
    for g in groups_ordered:
        members_by_group[g].sort()

    pairings = []

    for shift in (0, 1):
        merged = {n: BYE for n in nodes}
        for g in groups_ordered:
            merged.update(_rotate_pairs(members_by_group[g], shift))
        pairings.append(("intra", shift, merged))

    if len(groups_ordered) > 1:
        flat = _round_robin(groups_ordered, members_by_group)
        for shift in (0, 1):
            paired = _rotate_pairs(flat, shift)
            merged = {}
            for n in nodes:
                p = paired.get(n)
                # 同组的配对不算跨组样本
                merged[n] = p if (p is not None and group_of(topo, p) != group_of(topo, n)) else BYE
            pairings.append(("inter", shift, merged))

    return pairings


# ------------------------------------------------------------------ 判定
def _median(values):
    """取排序后的上中位数（偶数个时不做两值平均）—— 阈值更严格的一侧。
    与采样阶段用 statistics.median 抗抖动的用途不同，不可互换。"""
    vals = sorted(v for v in values if v is not None and not math.isnan(v))
    return vals[len(vals) // 2] if vals else None


def judge_class(samples, min_ratio, higher_is_better, min_abs=0.0):
    """samples: {node: [轮1值, 轮2值]}，nan 表示轮空。
    返回 (verdicts, baselines)。verdicts[node] 为 True 表示该类里判定为慢。

    两轮都慢才判慢。基线按轮次分别取中位数 —— 不同轮次的配对组合不同，
    合在一起取中位会把轮次差异算进节点差异。
    """
    rounds = max((len(v) for v in samples.values()), default=0)
    baselines = []
    for r in range(rounds):
        baselines.append(_median([v[r] if r < len(v) else float("nan") for v in samples.values()]))

    verdicts = {}
    for node, vals in samples.items():
        flags = []
        for r in range(rounds):
            v = vals[r] if r < len(vals) else float("nan")
            base = baselines[r]
            if v is None or math.isnan(v) or base is None or base <= 0:
                continue  # 轮空不参与判定，也不算"通过"
            if higher_is_better:
                slow = v < min_ratio * base or (min_abs > 0 and v < min_abs)
            else:
                slow = v > base / min_ratio or (min_abs > 0 and v > min_abs)
            flags.append(slow)
        verdicts[node] = bool(flags) and all(flags)
    return verdicts, baselines


# ------------------------------------------------------ 降频原因（NVML 位掩码）
# 慢节点最常见的物理原因是降频。判出慢节点却不知道为什么慢，还得再上机查一遍，
# 而这些信息在测的当下就在机器上。位定义见 NVML nvmlClocksThrottleReasons。
THROTTLE_BITS = [
    (0x0001, "GpuIdle",              "空闲降频",          False),
    (0x0002, "ApplicationsClocks",   "应用时钟设定",      False),
    (0x0004, "SwPowerCap",           "软件功耗墙",        True),
    (0x0008, "HwSlowdown",           "硬件降速",          True),
    (0x0010, "SyncBoost",            "SyncBoost 同步",    True),
    (0x0020, "SwThermalSlowdown",    "软件温度墙",        True),
    (0x0040, "HwThermalSlowdown",    "硬件温度墙",        True),
    (0x0080, "HwPowerBrakeSlowdown", "硬件功率刹车",      True),
    (0x0100, "DisplayClockSetting",  "显示时钟设定",      False),
]


def decode_throttle(mask):
    """返回 (原因中文列表, 是否存在性能相关原因)。

    GpuIdle 与两个 ClockSetting 不是性能问题 —— 空闲时本来就降频，
    把它们算成"降频告警"会让每次体检都报一堆噪音。
    """
    if mask is None or (isinstance(mask, float) and math.isnan(mask)):
        return [], False
    m = int(mask)
    if m == 0:
        return [], False
    names, perf = [], False
    for bit, _en, cn, is_perf in THROTTLE_BITS:
        if m & bit:
            names.append(cn)
            perf = perf or is_perf
    if not names:
        names.append(f"未知位 0x{m:x}")
    return names, perf


def attribute(temp_c, power_w, sm_mhz, throttle_mask, temp_ref=None, power_ref=None):
    """给一个被判为慢的 GPU 归因。返回一句人读结论。

    优先级：降频位 > 温度显著高于同批 > 功耗显著高于同批 > 无法归因。
    降频位是硬证据，温度/功耗只是同批离群，措辞上要区分开。
    """
    reasons, perf = decode_throttle(throttle_mask)
    if perf:
        return "降频：" + "、".join(reasons)
    if temp_ref and temp_c is not None and not math.isnan(temp_c) and temp_c >= temp_ref + 10:
        return f"温度 {temp_c:.0f}°C，高于同批中位 {temp_ref:.0f}°C"
    if power_ref and power_w is not None and not math.isnan(power_w) and power_w >= power_ref * 1.1:
        return f"功耗 {power_w:.0f}W，高于同批中位 {power_ref:.0f}W"
    if reasons:
        return "降频位：" + "、".join(reasons) + "（非性能类）"
    return "未见降频/温度/功耗异常，查链路与主机侧"


# ------------------------------------------------------------------ 拓扑视图
def topology_summary(node_names, topo, class_stats, slow_nodes):
    """把"发现的拓扑"和"实测的性能"合成一份可交付的拓扑视图。

    class_stats: {cls: {"bw": {node: [轮值...]}, "lat": {...}}}
    返回 dict；其中 oversubscription 是**实测**收敛比 = 组内带宽 / 跨组带宽。
    厂商普遍宣称 1:1 无收敛，这个数字是唯一能证伪的实测依据 —— 交换机配置看不出
    实际打流表现，只有真打才知道。
    """
    groups = {}
    for n in node_names:
        groups.setdefault(group_of(topo, n), []).append(n)

    def med_of(cls, kind):
        samples = class_stats.get(cls, {}).get(kind, {})
        vals = [v for per_node in samples.values() for v in per_node
                if v is not None and not math.isnan(v)]
        return _median(vals)

    intra_bw, inter_bw = med_of("intra", "bw"), med_of("inter", "bw")
    intra_lat, inter_lat = med_of("intra", "lat"), med_of("inter", "lat")

    over = None
    if intra_bw and inter_bw and inter_bw > 0:
        over = intra_bw / inter_bw

    return {
        "groups": {g: sorted(m) for g, m in sorted(groups.items())},
        "group_count": len(groups),
        "intra_bw_gbs": intra_bw, "inter_bw_gbs": inter_bw,
        "intra_lat_us": intra_lat, "inter_lat_us": inter_lat,
        "oversubscription": over,
        "slow_nodes": sorted(slow_nodes),
    }


def render_topology(summary, width=78):
    """ASCII 拓扑图。报告要能直接贴进验收文档，不依赖任何绘图库。"""
    out = ["拓扑与实测收敛比"]
    if summary["group_count"] <= 1:
        out.append("  （未提供 topology.tsv，全部节点归入同一组，下方收敛比无意义）")
    for g, members in summary["groups"].items():
        marked = [f"{m} [SLOW]" if m in summary["slow_nodes"] else m for m in members]
        out.append(f"  {g:<12}├─ " + "  ".join(marked))

    def fmt(v, unit):
        return "  n/a" if v is None else f"{v:.2f} {unit}"

    out.append("")
    out.append(f"  {'组内实测（中位）':<18}{fmt(summary['intra_bw_gbs'],'GB/s'):>16}"
               f"{fmt(summary['intra_lat_us'],'µs'):>14}")
    out.append(f"  {'跨组实测（中位）':<18}{fmt(summary['inter_bw_gbs'],'GB/s'):>16}"
               f"{fmt(summary['inter_lat_us'],'µs'):>14}")
    over = summary["oversubscription"]
    if over is None:
        out.append("  实测收敛比          n/a（需要至少 2 个拓扑组）")
    else:
        pct = 100.0 / over
        verdict = "接近无收敛" if over <= 1.2 else ("轻度收敛" if over <= 2.5 else "明显收敛")
        out.append(f"  {'实测收敛比':<18}{over:>10.2f} : 1     跨组带宽为组内的 {pct:.1f}%  → {verdict}")
        out.append("  注：厂商宣称 1:1 无收敛时，本行是唯一的实测依据；交换机配置看不出实际打流表现。")
    return "\n".join(out)


# -------------------------------------------------- 从实测反推拓扑（无交换机信息时）
def round_robin_rounds(members):
    """标准循环赛排程：n 个节点用 n-1 轮（n 为奇数则 n 轮，每轮一个轮空）
    覆盖全部 n(n-1)/2 对。每轮内所有配对并发，所以轮数就是墙上时间。
    返回 [{node: partner|None}, ...]。"""
    ms = list(members)
    if len(ms) < 2:
        return []
    bye = None
    if len(ms) % 2 == 1:
        ms = ms + [bye]
    n = len(ms)
    fixed, rot = ms[0], ms[1:]
    rounds = []
    for _ in range(n - 1):
        order = [fixed] + rot
        pairing = {}
        for i in range(n // 2):
            a, b = order[i], order[n - 1 - i]
            if a is not bye:
                pairing[a] = b
            if b is not bye:
                pairing[b] = a
        rounds.append(pairing)
        rot = rot[1:] + rot[:1]
    return rounds


def infer_groups(node_names, latency, min_gap_ratio=1.30, min_group_frac=0.15):
    """从全对延迟矩阵反推拓扑分组。

    latency: {(a,b): µs}，无向。同 leaf 1 跳、跨 leaf 3 跳，延迟应当分层。
    做法：把所有对的延迟排序，找最大的相对间隙；间隙两侧比值达不到
    min_gap_ratio 就**拒绝猜测**返回 None —— 真正 1:1 无收敛的小 fabric 上
    层次本来就分不开，这时候伪造一个看起来可信的分组会直接污染判定基线，
    比没有拓扑更糟。

    返回 (groups|None, 诊断信息)。
    """
    vals = sorted(v for v in latency.values() if v is not None and not math.isnan(v))
    if len(vals) < 3:
        return None, {"reason": "样本不足（少于 3 对），无法分层"}

    best_gap, best_at = 1.0, None
    for i in range(len(vals) - 1):
        lo, hi = vals[i], vals[i + 1]
        if lo <= 0:
            continue
        if hi / lo > best_gap:
            best_gap, best_at = hi / lo, (lo + hi) / 2.0

    if best_at is None or best_gap < min_gap_ratio:
        return None, {"reason": f"延迟未分层（最大相对间隙 {best_gap:.2f}×，"
                                f"低于 {min_gap_ratio}×）；可能是真无收敛，也可能是噪声过大",
                      "max_gap_ratio": best_gap}

    # 低于阈值的对视为同组，求连通分量
    adj = {n: set() for n in node_names}
    for (a, b), v in latency.items():
        if v is not None and not math.isnan(v) and v < best_at:
            adj[a].add(b)
            adj[b].add(a)
    seen, comps = set(), []
    for n in node_names:
        if n in seen:
            continue
        stack, comp = [n], []
        seen.add(n)
        while stack:
            cur = stack.pop()
            comp.append(cur)
            for nb in adj[cur]:
                if nb not in seen:
                    seen.add(nb)
                    stack.append(nb)
        comps.append(sorted(comp))

    # 下限取 2 而不是 1：单节点组几乎总是坏网卡（它对所有人都慢），不是拓扑分层。
    # 误当成"自成一组"的后果是它从此只和自己比，永远判不出慢 —— 静默漏检最危险。
    smallest = min(len(c) for c in comps)
    if len(comps) > 1 and smallest < max(2, int(len(node_names) * min_group_frac)):
        return None, {"reason": f"分出的最小组只有 {smallest} 个节点（下限 2，或总数的"
                                f" {min_group_frac:.0%}），更像是单机异常而非拓扑分层",
                      "max_gap_ratio": best_gap}

    comps.sort(key=lambda c: c[0])
    groups = {}
    for i, comp in enumerate(comps):
        for n in comp:
            groups[n] = f"inferred{i}"
    return groups, {"threshold_us": best_at, "max_gap_ratio": best_gap,
                    "group_count": len(comps)}
