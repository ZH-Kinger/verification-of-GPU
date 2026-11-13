"""cluster_topology.py 的离线单测 —— 不需要 GPU、不需要网络。
    python3 tests/test_cluster_topology.py
"""
import math
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "scripts", "cluster"))
import cluster_topology as ct

NAN = float("nan")


def nodes(n, prefix="node"):
    return [f"{prefix}{i:02d}" for i in range(1, n + 1)]


def topo_of(mapping):
    return ct.parse_topology("\n".join(f"{k}\t{v}" for k, v in mapping.items()))


def even_leaves(num_leaves, per_leaf):
    m = {}
    for l in range(num_leaves):
        for i in range(per_leaf):
            m[f"node{l * per_leaf + i + 1:02d}"] = f"leaf{l}"
    return m


class TestParse(unittest.TestCase):
    def test_comments_and_blank_lines_ignored(self):
        t = ct.parse_topology("# 注释\n\nnode01\tleaf1\nnode02 leaf1  # 行尾注释\n")
        self.assertEqual(t, {"node01": "leaf1", "node02": "leaf1"})

    def test_missing_group_column_rejected(self):
        with self.assertRaises(ValueError):
            ct.parse_topology("node01\n")

    def test_conflicting_group_rejected(self):
        with self.assertRaises(ValueError):
            ct.parse_topology("node01\tleaf1\nnode01\tleaf2\n")


class TestPairing(unittest.TestCase):
    def _all_pairings(self, node_list, mapping):
        return ct.build_pairings(node_list, topo_of(mapping))

    def test_pairing_is_symmetric(self):
        """不对称的配对会让 P2P send/recv 一边等发一边等收 —— 直接死锁。"""
        for nl, per_leaf in ((8, 4), (16, 8), (9, 3), (6, 2)):
            node_list = nodes(nl)
            mapping = even_leaves(nl // per_leaf, per_leaf)
            for cls, shift, pairs in self._all_pairings(node_list, mapping):
                for a, b in pairs.items():
                    if b is None:
                        continue
                    self.assertEqual(pairs.get(b), a,
                                     f"{cls} shift={shift}: {a}->{b} 但 {b}->{pairs.get(b)}")

    def test_intra_pairs_are_same_group_inter_pairs_are_cross_group(self):
        node_list = nodes(16)
        mapping = even_leaves(4, 4)
        topo = topo_of(mapping)
        for cls, _shift, pairs in ct.build_pairings(node_list, topo):
            for a, b in pairs.items():
                if b is None:
                    continue
                same = ct.group_of(topo, a) == ct.group_of(topo, b)
                self.assertEqual(same, cls == "intra", f"{cls}: {a}({ct.group_of(topo,a)})-{b}({ct.group_of(topo,b)})")

    def test_two_rounds_use_different_partners(self):
        """两轮换位的全部意义就在于换对端；不换的话"两轮都慢"等于测了两遍同一条链路。"""
        node_list = nodes(16)
        topo = topo_of(even_leaves(4, 4))
        by_cls = {}
        for cls, shift, pairs in ct.build_pairings(node_list, topo):
            by_cls.setdefault(cls, {})[shift] = pairs
        for cls, rounds in by_cls.items():
            for node in node_list:
                a, b = rounds[0].get(node), rounds[1].get(node)
                if a is not None and b is not None:
                    self.assertNotEqual(a, b, f"{cls}: {node} 两轮对端相同 ({a})")

    def test_single_group_degrades_to_intra_only(self):
        node_list = nodes(8)
        topo = topo_of({n: "leaf0" for n in node_list})
        classes = {cls for cls, _s, _p in ct.build_pairings(node_list, topo)}
        self.assertEqual(classes, {"intra"})

    def test_no_topology_file_means_one_group(self):
        node_list = nodes(4)
        classes = {cls for cls, _s, _p in ct.build_pairings(node_list, ct.parse_topology(""))}
        self.assertEqual(classes, {"intra"})

    def test_odd_group_size_gives_exactly_one_bye_per_round(self):
        node_list = nodes(5)
        topo = topo_of({n: "leaf0" for n in node_list})
        for _cls, shift, pairs in ct.build_pairings(node_list, topo):
            byes = [n for n, p in pairs.items() if p is None]
            self.assertEqual(len(byes), 1, f"shift={shift} 轮空 {byes}")

    def test_every_node_gets_a_partner_in_at_least_one_round(self):
        node_list = nodes(16)
        topo = topo_of(even_leaves(4, 4))
        seen = {n: 0 for n in node_list}
        for _cls, _shift, pairs in ct.build_pairings(node_list, topo):
            for n, p in pairs.items():
                if p is not None:
                    seen[n] += 1
        for n, c in seen.items():
            self.assertGreaterEqual(c, 2, f"{n} 只被测了 {c} 轮")


class TestJudge(unittest.TestCase):
    def test_slow_in_both_rounds_is_flagged(self):
        samples = {f"n{i}": [100.0, 100.0] for i in range(7)}
        samples["bad"] = [50.0, 50.0]
        v, _ = ct.judge_class(samples, 0.8, higher_is_better=True)
        self.assertTrue(v["bad"])
        self.assertFalse(any(v[k] for k in v if k != "bad"))

    def test_slow_in_one_round_only_is_not_flagged(self):
        """单轮慢通常是对端的锅，换位再测才能定位到节点。"""
        samples = {f"n{i}": [100.0, 100.0] for i in range(7)}
        samples["maybe"] = [50.0, 100.0]
        v, _ = ct.judge_class(samples, 0.8, higher_is_better=True)
        self.assertFalse(v["maybe"])

    def test_median_not_dragged_by_multiple_slow_nodes(self):
        """均值会被慢节点自己拉偏；3/8 变慢时中位数仍站在健康侧。"""
        samples = {f"ok{i}": [100.0, 100.0] for i in range(5)}
        for i in range(3):
            samples[f"bad{i}"] = [50.0, 50.0]
        v, base = ct.judge_class(samples, 0.8, higher_is_better=True)
        self.assertEqual(base[0], 100.0)
        self.assertTrue(all(v[f"bad{i}"] for i in range(3)))

    def test_absolute_floor_catches_uniform_degradation(self):
        """全员一起劣化时相对比较全绿 —— 绝对下限是唯一的兜底。"""
        samples = {f"n{i}": [10.0, 10.0] for i in range(8)}
        v, _ = ct.judge_class(samples, 0.8, higher_is_better=True)
        self.assertFalse(any(v.values()), "没有绝对下限时应当全绿（这正是漏检）")
        v2, _ = ct.judge_class(samples, 0.8, higher_is_better=True, min_abs=40.0)
        self.assertTrue(all(v2.values()))

    def test_latency_direction_is_higher_is_worse(self):
        samples = {f"n{i}": [20.0, 20.0] for i in range(7)}
        samples["bad"] = [40.0, 40.0]
        v, _ = ct.judge_class(samples, 0.8, higher_is_better=False)
        self.assertTrue(v["bad"])
        self.assertFalse(v["n0"])

    def test_bye_round_does_not_count_as_pass(self):
        """轮空不能当成"这轮没问题"，否则奇数组里轮空的节点永远判不出慢。"""
        samples = {f"n{i}": [100.0, 100.0] for i in range(7)}
        samples["bad"] = [50.0, NAN]
        v, _ = ct.judge_class(samples, 0.8, higher_is_better=True)
        self.assertTrue(v["bad"], "唯一有效轮次已经判慢，不应被轮空稀释")

    def test_all_bye_is_not_flagged(self):
        samples = {f"n{i}": [100.0, 100.0] for i in range(7)}
        samples["idle"] = [NAN, NAN]
        v, _ = ct.judge_class(samples, 0.8, higher_is_better=True)
        self.assertFalse(v["idle"])


class TestRoundRobin(unittest.TestCase):
    def test_covers_every_pair_exactly_once(self):
        for n in (4, 5, 8, 9, 16):
            ms = nodes(n)
            rounds = ct.round_robin_rounds(ms)
            seen = {}
            for r in rounds:
                for a, b in r.items():
                    if b is None:
                        continue
                    key = tuple(sorted((a, b)))
                    seen[key] = seen.get(key, 0) + 1
            expected = n * (n - 1) // 2
            self.assertEqual(len(seen), expected, f"n={n} 覆盖 {len(seen)}/{expected} 对")
            self.assertTrue(all(c == 2 for c in seen.values()), f"n={n} 有重复配对")
            self.assertEqual(len(rounds), n - 1 if n % 2 == 0 else n)

    def test_pairing_is_symmetric_each_round(self):
        for r in ct.round_robin_rounds(nodes(8)):
            for a, b in r.items():
                if b is not None:
                    self.assertEqual(r[b], a)


class TestInferGroups(unittest.TestCase):
    def _matrix(self, names, groups, intra, inter, noise=0.0):
        g = dict(zip(names, groups))
        m = {}
        for i, a in enumerate(names):
            for b in names[i + 1:]:
                base = intra if g[a] == g[b] else inter
                m[(a, b)] = base + (noise if (i % 2) else -noise)
        return m

    def test_infers_two_leaves_from_layered_latency(self):
        names = nodes(8)
        groups = ["l0"] * 4 + ["l1"] * 4
        m = self._matrix(names, groups, intra=18.0, inter=31.0)
        inferred, info = ct.infer_groups(names, m)
        self.assertIsNotNone(inferred, info)
        self.assertEqual(info["group_count"], 2)
        for a in names[:4]:
            for b in names[:4]:
                self.assertEqual(inferred[a], inferred[b])
        self.assertNotEqual(inferred[names[0]], inferred[names[4]])

    def test_refuses_to_guess_when_latency_is_flat(self):
        """真 1:1 无收敛的小 fabric 上层次分不开。伪造一个看起来可信的分组
        会直接污染判定基线，比没有拓扑更糟 —— 必须拒绝猜测。"""
        names = nodes(8)
        m = self._matrix(names, ["l0"] * 8, intra=18.0, inter=18.0, noise=0.4)
        inferred, info = ct.infer_groups(names, m)
        self.assertIsNone(inferred)
        self.assertIn("未分层", info["reason"])

    def test_refuses_when_split_is_just_one_odd_node(self):
        """一台机器链路差会让它对所有人都慢 —— 那是单机异常不是拓扑分层，
        误当成"自成一组"会让它永远和自己比，从此再也判不出慢。"""
        names = nodes(8)
        m = self._matrix(names, ["l0"] * 8, intra=18.0, inter=18.0)
        for other in names:
            if other != names[3]:
                key = tuple(sorted((names[3], other)))
                m[key] = 40.0
        inferred, info = ct.infer_groups(names, m)
        self.assertIsNone(inferred)
        self.assertIn("单机异常", info["reason"])

    def test_too_few_samples_is_refused(self):
        inferred, info = ct.infer_groups(nodes(2), {("node01", "node02"): 18.0})
        self.assertIsNone(inferred)
        self.assertIn("样本不足", info["reason"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
