"""straggler_check.summarize 的离线判定测试 —— 用 CPU tensor 喂假数据，不需要 GPU。
    python3 tests/test_straggler_judge.py
"""
import io, os, sys, unittest
from contextlib import redirect_stdout

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "scripts", "cluster"))
import torch
import cluster_topology as ct
import straggler_check as sc

LWS = 8
CFG = {"min_ratio": 0.8, "min_p2p_gbps": 0.0, "compute_iters": 2000, "gemm_n": 4096}


def build(num_nodes, groups, bw_by_class, slow=None, telemetry=None):
    """bw_by_class: {'intra': 每节点聚合带宽, 'inter': ...}；slow: {node_idx: 倍率}
    telemetry: {node_idx: (温度, 功耗, SM时钟, 降频位)}，缺省为健康值"""
    names = [f"node{i+1:02d}" for i in range(num_nodes)]
    topo = ct.parse_topology("\n".join(f"{n}\t{g}" for n, g in zip(names, groups)))
    pairings = ct.build_pairings(names, topo)
    cols = sc.TELEMETRY_COLS + len(pairings) * 3
    M = torch.zeros(num_nodes * LWS, cols, dtype=torch.float64)
    slow = slow or {}
    for n in range(num_nodes):
        f = slow.get(n, 1.0)
        for l in range(LWS):
            r = n * LWS + l
            M[r, 0] = 1.0 / f      # compute 耗时：越慢越大
            M[r, 1] = 100.0 * f    # ring 带宽
            M[r, 2] = 0.05
            t, p, c, th = (telemetry or {}).get(n, (60.0, 500.0, 1800.0, 0.0))
            M[r, 3], M[r, 4], M[r, 5], M[r, 6] = t, p, c, th
            for idx, (cls, _s, pairs) in enumerate(pairings):
                base = sc.TELEMETRY_COLS + idx * 3
                if pairs.get(names[n]) is None:
                    M[r, base] = M[r, base + 1] = M[r, base + 2] = float("nan")
                else:
                    M[r, base] = bw_by_class[cls] / LWS * f   # 每 rank 单向，汇总时相加
                    M[r, base + 1] = 20.0 / f
                    M[r, base + 2] = 25.0 / f
    hosts = [names[r // LWS] for r in range(num_nodes * LWS)]
    return M, names, hosts, topo, pairings


def run(M, names, hosts, topo, pairings, num_nodes, cfg=None):
    with redirect_stdout(io.StringIO()) as buf:
        payload = sc.summarize(M, names, hosts, topo, pairings, LWS, num_nodes, cfg or CFG)
    return payload, buf.getvalue()


class TestTopologyAwareJudging(unittest.TestCase):
    def test_healthy_cross_spine_node_is_not_flagged(self):
        """本次改动要解决的核心问题：rail-optimized fabric 上跨 spine 的带宽天然低于
        同 leaf。有拓扑感知时，跨组只和跨组比，健康节点不该被判慢。"""
        groups = ["leaf0", "leaf0", "leaf0", "leaf0", "leaf1", "leaf1", "leaf1", "leaf1"]
        M, names, hosts, topo, pairings = build(8, groups, {"intra": 400.0, "inter": 200.0})
        payload, _ = run(M, names, hosts, topo, pairings, 8)
        self.assertFalse(payload["has_straggler"],
                         "跨 spine 只是天然慢一半，不是慢节点")

    def test_without_topology_uneven_placement_produces_false_positives(self):
        """无拓扑（原版按 index 配对）时的误判条件：少数节点两轮都跨组，
        而多数节点两轮都同组 —— 基线被"同组"值主导，跨组的健康节点被判慢。

        注意误判不是必然发生，取决于节点在 hostfile 里的排列：
          连续 leaf0x4+leaf1x4  -> 无节点两轮都跨组，不误判
          交错 leaf0/leaf1 轮流 -> 全部两轮都跨组，基线随之下移，也不误判
          不均衡 leaf0x6+1+1    -> node07/08 两轮都跨组而多数同组，误判（本例）
        真实集群里 hostfile 顺序与物理 leaf 分配不一致是常态，所以这条必须防。
        """
        groups = ["leaf0"] * 6 + ["leaf1", "leaf2"]
        names = [f"node{i+1:02d}" for i in range(8)]
        real = ct.parse_topology("\n".join(f"{n}\t{g}" for n, g in zip(names, groups)))
        blind = ct.parse_topology("")
        pairings = ct.build_pairings(names, blind)
        cols = sc.TELEMETRY_COLS + len(pairings) * 3
        M = torch.zeros(8 * LWS, cols, dtype=torch.float64)
        for n in range(8):
            for l in range(LWS):
                r = n * LWS + l
                M[r, 0], M[r, 1], M[r, 2] = 1.0, 100.0, 0.05
                M[r, 3], M[r, 4], M[r, 5], M[r, 6] = 60.0, 500.0, 1800.0, 0.0
                for idx, (_c, _s, pairs) in enumerate(pairings):
                    base = sc.TELEMETRY_COLS + idx * 3
                    p = pairs.get(names[n])
                    if p is None:
                        M[r, base] = M[r, base + 1] = M[r, base + 2] = float("nan")
                    else:
                        # 同 leaf 400 / 跨 leaf 200：物理事实，与节点是否健康无关
                        same = real[names[n]] == real[p]
                        M[r, base] = (400.0 if same else 200.0) / LWS
                        M[r, base + 1] = 20.0 if same else 30.0
                        M[r, base + 2] = 25.0 if same else 35.0
        hosts = [names[r // LWS] for r in range(8 * LWS)]
        payload, _ = run(M, names, hosts, blind, pairings, 8)
        flagged = [n["host"] for n in payload["nodes"]
                   if any(c["slow"] for c in n["classes"].values())]
        self.assertEqual(flagged, ["node07", "node08"],
                         "无拓扑时这两个健康节点会被误判 —— 这正是本次改动要修的")

    def test_with_topology_the_same_uneven_placement_is_clean(self):
        """同一批数据、同一个排列，给了拓扑文件后不应再有误判。"""
        groups = ["leaf0"] * 6 + ["leaf1", "leaf2"]
        M, names, hosts, topo, pairings = build(
            8, groups, {"intra": 400.0, "inter": 200.0})
        payload, _ = run(M, names, hosts, topo, pairings, 8)
        flagged = [n["host"] for n in payload["nodes"]
                   if any(c["slow"] for c in n["classes"].values())]
        self.assertEqual(flagged, [], f"不应有慢节点，实际报了 {flagged}")

    def test_real_straggler_inside_a_leaf_is_still_caught(self):
        """修误报不能以放过真慢节点为代价。"""
        groups = ["leaf0"] * 4 + ["leaf1"] * 4
        M, names, hosts, topo, pairings = build(
            8, groups, {"intra": 400.0, "inter": 200.0}, slow={2: 0.5})
        payload, _ = run(M, names, hosts, topo, pairings, 8)
        self.assertTrue(payload["has_straggler"])
        flagged = [n["host"] for n in payload["nodes"]
                   if any(c["slow"] for c in n["classes"].values())]
        self.assertIn("node03", flagged)
        self.assertEqual(len(flagged), 1, f"只应报 node03，实际 {flagged}")

    def test_uniform_degradation_needs_the_absolute_floor(self):
        """全员一起慢：相对比较全绿，只有绝对下限能兜住。"""
        groups = ["leaf0"] * 4 + ["leaf1"] * 4
        M, names, hosts, topo, pairings = build(8, groups, {"intra": 40.0, "inter": 20.0})
        payload, _ = run(M, names, hosts, topo, pairings, 8)
        self.assertFalse(payload["has_straggler"], "无下限时应全绿（这就是漏检）")
        payload2, _ = run(M, names, hosts, topo, pairings, 8,
                          {"min_ratio": 0.8, "min_p2p_gbps": 100.0})
        self.assertTrue(payload2["has_straggler"])

    def test_single_group_prints_an_explicit_warning(self):
        """退化成单组必须说出来，不能悄悄按原版行为跑。"""
        M, names, hosts, topo, pairings = build(4, ["l0"] * 4, {"intra": 400.0})
        _payload, out = run(M, names, hosts, topo, pairings, 4)
        self.assertIn("只有一个拓扑组", out)

    def test_json_payload_has_group_and_class_breakdown(self):
        groups = ["leaf0"] * 4 + ["leaf1"] * 4
        M, names, hosts, topo, pairings = build(8, groups, {"intra": 400.0, "inter": 200.0})
        payload, _ = run(M, names, hosts, topo, pairings, 8)
        self.assertEqual(payload["groups"], ["leaf0", "leaf1"])
        n0 = payload["nodes"][0]
        self.assertEqual(n0["group"], "leaf0")
        self.assertEqual(set(n0["classes"]), {"intra", "inter"})
        self.assertIn("bw_baseline", n0["classes"]["intra"])

class TestJsonOutput(unittest.TestCase):
    def test_payload_serialises_to_strict_json(self):
        """轮空产生的 NaN 不是合法 JSON。这份文件要进验收证据并被别的工具读，
        必须严格可解析 —— jq 宽容不代表所有解析器都宽容。"""
        import json
        groups = ["leaf0"] * 3          # 奇数个 -> 必然出现轮空 -> 必然有 NaN
        M, names, hosts, topo, pairings = build(3, groups, {"intra": 400.0})
        payload, _ = run(M, names, hosts, topo, pairings, 3)
        raw = json.dumps(payload)
        self.assertIn("NaN", raw, "前提：原始 payload 里确实有 NaN")
        text = json.dumps(sc.json_safe(payload), allow_nan=False)
        back = json.loads(text, parse_constant=lambda c: (_ for _ in ()).throw(
            ValueError(f"出现非法常量 {c}")))
        self.assertIsInstance(back, dict)
        self.assertIsNone(back["nodes"][0]["classes"]["intra"]["bw_gbs"][0]
                          if back["nodes"][0]["classes"]["intra"]["bw_gbs"][0] is None else None)


class TestAttribution(unittest.TestCase):
    """慢节点判出来还要答得出为什么慢，否则得再上机查一遍。"""

    def _flagged(self, telemetry, slow):
        groups = ["leaf0"] * 4 + ["leaf1"] * 4
        M, names, hosts, topo, pairings = build(
            8, groups, {"intra": 400.0, "inter": 200.0}, slow=slow, telemetry=telemetry)
        payload, out = run(M, names, hosts, topo, pairings, 8)
        return payload, out

    def test_thermal_throttle_is_reported_as_hard_evidence(self):
        """降频位是硬证据，措辞不能和"温度比同批高"混为一谈。"""
        payload, out = self._flagged({2: (95.0, 700.0, 900.0, 0x40)}, {2: 0.5})
        hit = [g for g in payload["gpus"] if g["host"] == "node03"][0]
        self.assertIn("硬件温度墙", hit["attribution"])
        self.assertTrue(hit["attribution"].startswith("降频："))
        self.assertIn("硬件温度墙", out)

    def test_high_temp_without_throttle_bit_is_worded_as_outlier(self):
        payload, _ = self._flagged({2: (88.0, 500.0, 1800.0, 0.0)}, {2: 0.5})
        hit = [g for g in payload["gpus"] if g["host"] == "node03"][0]
        self.assertIn("高于同批中位", hit["attribution"])
        self.assertNotIn("降频", hit["attribution"])

    def test_slow_without_any_local_cause_points_at_the_link(self):
        """算力和温度都正常却慢，说明问题在链路或主机侧，不能空着不给方向。"""
        payload, _ = self._flagged({2: (60.0, 500.0, 1800.0, 0.0)}, {2: 0.5})
        hit = [g for g in payload["gpus"] if g["host"] == "node03"][0]
        self.assertIn("查链路与主机侧", hit["attribution"])

    def test_idle_bit_is_not_treated_as_a_problem(self):
        """空闲降频每台机器都会出现，算成告警会让每次体检都是一片噪音。"""
        payload, _ = self._flagged({1: (60.0, 500.0, 300.0, 0x1)}, None)
        hit = [g for g in payload["gpus"] if g["host"] == "node02"][0]
        self.assertFalse(hit["throttle_perf"])
        self.assertNotIn("attribution", hit)

    def test_throttle_on_a_healthy_node_is_still_surfaced(self):
        """还没慢但已经在降频 —— 那是即将变慢的前兆，不能等它慢了才报。"""
        payload, _ = self._flagged({1: (95.0, 700.0, 900.0, 0x40)}, None)
        hit = [g for g in payload["gpus"] if g["host"] == "node02"][0]
        self.assertFalse(hit["slow"])
        self.assertIn("未判慢但已出现降频", hit["attribution"])

    def test_missing_telemetry_does_not_become_zero(self):
        """采集失败必须是 nan 不是 0：降频位 0 的含义是"一切正常"，
        兜底成 0 会把"没采到"伪装成"没问题"。"""
        nan = float("nan")
        payload, _ = self._flagged({2: (nan, nan, nan, nan)}, {2: 0.5})
        hit = [g for g in payload["gpus"] if g["host"] == "node03"][0]
        self.assertEqual(hit["throttle_reasons"], [])
        self.assertFalse(hit["throttle_perf"])
        self.assertIn("查链路与主机侧", hit["attribution"])


class TestAbsoluteFloors(unittest.TestCase):
    """相对比较只能发现"批内不一致"，发现不了"整批一起劣化"。
    绝对下限是唯一兜底 —— 这类静默漏检比误报危险得多。"""

    def _run(self, factor, cfg_extra):
        groups = ["leaf0"] * 4 + ["leaf1"] * 4
        # 全员同一倍率 -> 中位数跟着降 -> 相对比较必然全绿
        slow = {i: factor for i in range(8)}
        M, names, hosts, topo, pairings = build(
            8, groups, {"intra": 400.0, "inter": 200.0}, slow=slow)
        cfg = dict(CFG); cfg.update(cfg_extra)
        return run(M, names, hosts, topo, pairings, 8, cfg)

    def test_uniform_compute_degradation_is_green_without_a_floor(self):
        payload, _ = self._run(0.4, {})
        self.assertFalse(payload["has_straggler"], "无下限时应全绿 —— 这正是漏检")
        self.assertTrue(all(abs(g["compute_ratio"] - 1.0) < 1e-6 for g in payload["gpus"]),
                        "整批同幅劣化时相对比值恒为 100%")

    def test_compute_floor_catches_uniform_degradation(self):
        clean, _ = self._run(1.0, {})
        healthy = clean["gpus"][0]["compute_tflops"]
        payload, _ = self._run(0.4, {"min_compute_tflops": healthy * 0.8})
        self.assertTrue(payload["has_straggler"])
        self.assertTrue(all(g["compute_below_floor"] for g in payload["gpus"]))

    def test_tflops_is_independent_of_iteration_count(self):
        """下限必须用 TFLOPS 不用秒数：秒数随迭代数变化，阈值一改迭代数就失效。"""
        a, _ = self._run(1.0, {"compute_iters": 1000})
        b, _ = self._run(1.0, {"compute_iters": 4000})
        # 同样的"耗时"在不同迭代数下代表不同算力，TFLOPS 必须随之变化
        self.assertNotAlmostEqual(a["gpus"][0]["compute_tflops"],
                                  b["gpus"][0]["compute_tflops"], places=1)
        # 而秒数是一样的 —— 用秒数当阈值就会把这两种情况混为一谈
        self.assertAlmostEqual(a["gpus"][0]["compute_s"], b["gpus"][0]["compute_s"])

    def test_ring_ratio_alone_never_triggers(self):
        """环形同步会被最慢链路拖平，各 rank 值几乎相同 -> 比值恒约 100%。
        所以 Ring 只对绝对下限判，比值仅供参考。"""
        payload, _ = self._run(0.3, {})
        self.assertTrue(all(abs(g["ring_ratio"] - 1.0) < 1e-6 for g in payload["gpus"]))
        self.assertFalse(any(g["ring_below_floor"] for g in payload["gpus"]))
        self.assertFalse(payload["has_straggler"])

    def test_ring_floor_catches_it(self):
        payload, _ = self._run(0.3, {"min_ring_gbps": 50.0})
        self.assertTrue(payload["has_straggler"])
        self.assertTrue(all(g["ring_below_floor"] for g in payload["gpus"]))

    def test_trigger_names_which_check_fired(self):
        """报告要说清是"低于同批"还是"低于绝对下限" —— 两者的处置完全不同。"""
        payload, _ = self._run(0.4, {"min_compute_tflops": 1e9})
        hit = payload["gpus"][0]
        self.assertIn("绝对下限", hit["trigger"])

    def test_missing_floor_is_announced_not_silently_skipped(self):
        _payload, out = self._run(1.0, {})
        self.assertIn("未设", out)


if __name__ == "__main__":
    unittest.main(verbosity=2)
