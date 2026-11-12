#!/usr/bin/env python3
"""平台 OpenAPI 只读接口的时延与成功率。每个接口串行调用 N 次，统计 p50/p95/max 与成功率。
只调 List/Get 类接口（yc.call 内部也拦截写操作）。"""
import json, os, statistics, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import yc  # noqa: E402

N = int(os.environ.get("N", "30"))
P, Z = os.environ["YC_PROJECT"], os.environ.get("YC_ZONE", "cn-shanghai-a")
CASES = [
    ("mc/v1alpha1/ListZones", {}),
    ("mc/v1alpha1/ListNodes", {"Limit": 10}),
    ("mc/v1alpha1/GetQuotaGroup", {"Project": P, "QuotaGroup": "gpu_task"}),
    ("job/v1alpha1/ListJobs", {"Project": P, "ZoneId": Z}),
    ("workspace/v1alpha1/ListWorkspaces", {"Project": P, "ZoneId": Z, "Limit": 100}),
    ("fs/v1alpha2/ListFilesetsWithQuotaInfo", {"ZoneId": Z, "Limit": 100}),
    ("registry/v1alpha2/ListPublicRepositories", {"ZoneId": Z, "Limit": 100}),
    ("mc/v1alpha1/GetPrivateResourcesOverview", {}),
]


def main():
    cfg = yc.load_env()
    out = []
    print(f"{'接口':45s} {'成功':>7s} {'p50':>7s} {'p95':>7s} {'max':>7s}  失败样例")
    for path, params in CASES:
        lat, ok, errs = [], 0, []
        for _ in range(N):
            status, data, ms, _rid = yc.call("/" + path, params, cfg)
            lat.append(ms)
            code = data.get("Code", data.get("code")) if isinstance(data, dict) else None
            if status == 200 and code in (0, None):
                ok += 1
            elif len(errs) < 1:
                errs.append(f"HTTP {status} Code {code} {str(data.get('Msg', ''))[:40]}")
            time.sleep(0.2)
        lat.sort()
        p95 = lat[max(0, int(len(lat) * 0.95) - 1)]
        row = dict(api=path, n=N, ok=ok, p50=statistics.median(lat), p95=p95, max=lat[-1], err=errs)
        out.append(row)
        print(f"{path:45s} {ok:>3d}/{N:<3d} {row['p50']:6.0f}ms {p95:6.0f}ms {lat[-1]:6.0f}ms  {errs[0] if errs else ''}")
    json.dump(out, open(os.environ.get("OUT", "/dev/null"), "w"), ensure_ascii=False, indent=1)


if __name__ == "__main__":
    main()
