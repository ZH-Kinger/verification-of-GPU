#!/usr/bin/env python3
"""仪电智算云 OpenAPI 只读客户端（按 openapi-sdk-go base/auth/sign.go 的签名规则实现）。

签名: hex(HMAC-SHA256(secret, tick_ms + public_key + sorted(k+v for query) + body))
请求头: X-OGW-TICK / X-OGW-PUBLIC-KEY / X-OGW-SIGN / X-OGW-REGION-ID

只允许 GET，且 action 名必须以 List/Get/Describe 开头——这是验收工具，不该改平台状态。
用法: yc.py <product>/<version>/<Action> [Key=Value ...]   (列表值用逗号: GPU=8)
"""
import hashlib, hmac, json, os, sys, time, urllib.error, urllib.parse, urllib.request

ENV_FILE = os.path.expanduser("~/.yicloud/env")
READ_PREFIXES = ("List", "Get", "Describe", "Query")


def load_env():
    cfg = {}
    with open(ENV_FILE) as fh:
        for line in fh:
            line = line.strip()
            if line.startswith("export "):
                line = line[7:]
            if "=" in line and not line.startswith("#"):
                k, v = line.split("=", 1)
                cfg[k.strip()] = v.strip().strip("'\"")
    for k in ("YICLOUD_PUBLIC_KEY", "YICLOUD_SECRET_KEY"):
        if not cfg.get(k):
            sys.exit(f"{ENV_FILE} 缺少 {k}")
    cfg.setdefault("YICLOUD_API_HOST", "https://gate.yicloud.com")
    cfg.setdefault("YICLOUD_REGION_ID", os.environ.get("YICLOUD_REGION_ID", "cn-shanghai"))
    return cfg


def sorted_qs_for_sign(query: str) -> str:
    kvs = []
    for p in query.split("&"):
        if not p:
            continue
        k, _, v = p.partition("=")
        kvs.append((urllib.parse.unquote_plus(k), urllib.parse.unquote_plus(v)))
    kvs.sort(key=lambda kv: kv[0])  # Python sort is stable, same as SliceStable
    return "".join(k + v for k, v in kvs)


def call(path: str, params: dict | None = None, cfg: dict | None = None):
    cfg = cfg or load_env()
    action = path.rstrip("/").rsplit("/", 1)[-1]
    if not action.startswith(READ_PREFIXES):
        raise SystemExit(f"拒绝: {action} 不是只读接口（只放行 {READ_PREFIXES}）")
    query = urllib.parse.urlencode(params or {}, doseq=True)
    tick = str(int(time.time() * 1000))
    to_sign = tick + cfg["YICLOUD_PUBLIC_KEY"] + sorted_qs_for_sign(query)
    sign = hmac.new(cfg["YICLOUD_SECRET_KEY"].encode(), to_sign.encode(), hashlib.sha256).hexdigest()
    url = cfg["YICLOUD_API_HOST"].rstrip("/") + path + ("?" + query if query else "")
    req = urllib.request.Request(url, method="GET", headers={
        "Content-Type": "application/json",
        "User-Agent": "acceptance-readonly/0.1",
        "X-OGW-REGION-ID": cfg["YICLOUD_REGION_ID"],
        "X-OGW-PUBLIC-KEY": cfg["YICLOUD_PUBLIC_KEY"],
        "X-OGW-TICK": tick,
        "X-OGW-SIGN": sign,
    })
    t0 = time.perf_counter()
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            status, body, rid = r.status, r.read(), r.headers.get("X-OGW-Request-Id")
    except urllib.error.HTTPError as e:
        status, body, rid = e.code, e.read(), e.headers.get("X-OGW-Request-Id")
    ms = (time.perf_counter() - t0) * 1000
    try:
        data = json.loads(body)
    except ValueError:
        data = {"_raw": body[:500].decode(errors="replace")}
    return status, data, ms, rid


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    path = "/" + sys.argv[1].strip("/")
    params = {}
    for a in sys.argv[2:]:
        k, _, v = a.partition("=")
        params[k] = v.split(",") if "," in v else v
    status, data, ms, rid = call(path, params)
    print(f"# HTTP {status}  {ms:.0f} ms  request-id={rid}", file=sys.stderr)
    print(json.dumps(data, ensure_ascii=False, indent=2))
    sys.exit(0 if status == 200 and data.get("Code", data.get("code", 0)) in (0, None) else 1)


if __name__ == "__main__":
    main()
