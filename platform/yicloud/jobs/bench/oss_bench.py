#!/usr/bin/env python3
"""平台对象存储（S3 兼容）性能测试，单客户端。凭证取 /.auth/accesskey_{id,secret}。
测：
  1. 单流 PUT/GET 64 MiB，看单连接带宽
  2. 多流并发 PUT/GET（4/16/64 线程 × 64 MiB），看用户级总带宽上限（文档：30~300 MiB/s）
  3. 小对象 4 KiB PUT/HEAD/GET/LIST（64 线程），看 QPS（文档：单用户 ≤ 300）与时延
  4. 大对象分片上传 2 GiB（multipart 64 MiB × 并发 16）
输出 @@RESULT json 行，并按「每 TiB 容量」「每 GPU」折算。
用法: python3 oss_bench.py <endpoint> <bucket> [cap_tib=2] [ngpu=8]
"""
import concurrent.futures as cf, json, os, statistics, sys, time
import boto3
from botocore.config import Config

EP, BUCKET = sys.argv[1], sys.argv[2]
CAP = float(sys.argv[3]) if len(sys.argv) > 3 else 2.0
NGPU = int(sys.argv[4]) if len(sys.argv) > 4 else 8
ak = open("/.auth/accesskey_id").read().strip()
sk = open("/.auth/accesskey_secret").read().strip()
s3 = boto3.client("s3", endpoint_url=EP, aws_access_key_id=ak, aws_secret_access_key=sk, region_name="shanghai",
                  config=Config(s3={"addressing_style": "path"}, max_pool_connections=128,
                                retries={"max_attempts": 2}, request_checksum_calculation="when_required"))
PFX = f"bench/{os.uname().nodename}-{int(time.time())}"
MiB = 1 << 20

def emit(**kw):
    print("@@RESULT " + json.dumps(kw, ensure_ascii=False), flush=True)

def put(key, body):
    s3.put_object(Bucket=BUCKET, Key=key, Body=body)

def get(key):
    return len(s3.get_object(Bucket=BUCKET, Key=key)["Body"].read())

def bw_phase(tag, nthreads, size, count):
    body = os.urandom(size)
    keys = [f"{PFX}/{tag}/{i}" for i in range(count)]
    t = time.time()
    with cf.ThreadPoolExecutor(nthreads) as ex: list(ex.map(lambda k: put(k, body), keys))
    tw = time.time() - t
    t = time.time()
    with cf.ThreadPoolExecutor(nthreads) as ex: n = sum(ex.map(get, keys))
    tr = time.time() - t
    wr, rd = size * count / tw / MiB, n / tr / MiB
    emit(kind="oss_bw", tag=tag, threads=nthreads, obj_mib=size // MiB, objects=count,
         put_mibs=round(wr, 1), get_mibs=round(rd, 1),
         get_mibs_per_tib=round(rd / CAP, 1), get_mibs_per_gpu=round(rd / NGPU, 1))
    return keys

def small_phase(nthreads=64, count=2000):
    body = os.urandom(4096)
    keys = [f"{PFX}/small/{i}" for i in range(count)]
    res = {}
    for op, fn in (("put", lambda k: put(k, body)), ("head", lambda k: s3.head_object(Bucket=BUCKET, Key=k)),
                   ("get", get)):
        lat = []
        def timed(k):
            t0 = time.time(); fn(k); lat.append((time.time() - t0) * 1000)
        t = time.time()
        with cf.ThreadPoolExecutor(nthreads) as ex: list(ex.map(timed, keys))
        dt = time.time() - t; lat.sort()
        res[op] = dict(qps=round(count / dt), p50_ms=round(statistics.median(lat), 1), p99_ms=round(lat[int(len(lat) * .99) - 1], 1))
    t = time.time(); n = 0; tok = None
    while True:
        kw = dict(Bucket=BUCKET, Prefix=f"{PFX}/small/", MaxKeys=1000)
        if tok: kw["ContinuationToken"] = tok
        r = s3.list_objects_v2(**kw); n += r.get("KeyCount", 0)
        if not r.get("IsTruncated"): break
        tok = r["NextContinuationToken"]
    res["list"] = dict(objects=n, seconds=round(time.time() - t, 2))
    emit(kind="oss_small", threads=nthreads, objects=count, **res)
    return keys

def multipart(total=2 << 30, part=64 * MiB, nthreads=16):
    key = f"{PFX}/big.bin"
    up = s3.create_multipart_upload(Bucket=BUCKET, Key=key)["UploadId"]
    body = os.urandom(part); n = total // part
    t = time.time()
    def up_part(i):
        return dict(PartNumber=i, ETag=s3.upload_part(Bucket=BUCKET, Key=key, UploadId=up, PartNumber=i, Body=body)["ETag"])
    with cf.ThreadPoolExecutor(nthreads) as ex: parts = list(ex.map(up_part, range(1, n + 1)))
    s3.complete_multipart_upload(Bucket=BUCKET, Key=key, UploadId=up, MultipartUpload={"Parts": parts})
    tw = time.time() - t
    # 分段并发 GET（Range）
    t = time.time()
    def rng(i):
        return len(s3.get_object(Bucket=BUCKET, Key=key, Range=f"bytes={i*part}-{(i+1)*part-1}")["Body"].read())
    with cf.ThreadPoolExecutor(nthreads) as ex: got = sum(ex.map(rng, range(n)))
    tr = time.time() - t
    emit(kind="oss_multipart", total_gib=total >> 30, part_mib=part // MiB, threads=nthreads,
         put_mibs=round(total / tw / MiB, 1), get_mibs=round(got / tr / MiB, 1))
    return [key]

if __name__ == "__main__":
    s3.head_bucket(Bucket=BUCKET)
    emit(kind="oss_info", endpoint=EP, bucket=BUCKET, capacity_tib=CAP)
    cleanup = []
    cleanup += bw_phase("single", 1, 64 * MiB, 4)
    for th in (4, 16, 64):
        cleanup += bw_phase(f"par{th}", th, 64 * MiB, th * 2)
    cleanup += small_phase()
    cleanup += multipart()
    for i in range(0, len(cleanup), 1000):
        s3.delete_objects(Bucket=BUCKET, Delete={"Objects": [{"Key": k} for k in cleanup[i:i + 1000]], "Quiet": True})
    emit(kind="oss_cleanup", deleted=len(cleanup))
