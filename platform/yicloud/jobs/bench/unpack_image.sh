#!/bin/bash
# 把 docker save 产物（tar.gz）解成 rootfs，供 chroot 运行。不依赖 docker / skopeo。
# 用法: bash unpack_image.sh <image.tar.gz> <dest_rootfs>
# 依 manifest.json 的 Layers 顺序逐层解压，并按 OCI 规则处理 whiteout（.wh.<name> 删除，.wh..wh..opq 清空目录）。
set -euo pipefail
IMG=$1; DEST=$2
WORK=$(mktemp -d /tmp/imgunpack.XXXX)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$DEST"
echo "[unpack] $IMG -> $DEST"
tar xzf "$IMG" -C "$WORK"
python3 - "$WORK" "$DEST" <<'EOF'
import json, os, sys, tarfile, shutil
work, dest = sys.argv[1], sys.argv[2]
man = json.load(open(os.path.join(work, "manifest.json")))[0]
print("[unpack] tags", man.get("RepoTags"), "layers", len(man["Layers"]))
for i, layer in enumerate(man["Layers"], 1):
    path = os.path.join(work, layer)
    with tarfile.open(path) as tf:
        members = tf.getmembers()
        # 先处理 whiteout
        for m in members:
            d, b = os.path.split(m.name)
            if b == ".wh..wh..opq":
                tgt = os.path.join(dest, d)
                if os.path.isdir(tgt):
                    for x in os.listdir(tgt):
                        p = os.path.join(tgt, x)
                        shutil.rmtree(p) if os.path.isdir(p) and not os.path.islink(p) else os.unlink(p)
            elif b.startswith(".wh."):
                tgt = os.path.join(dest, d, b[4:])
                if os.path.islink(tgt) or os.path.isfile(tgt): os.unlink(tgt)
                elif os.path.isdir(tgt): shutil.rmtree(tgt)
        keep = [m for m in members if not os.path.basename(m.name).startswith(".wh.")]
        for m in keep:  # 目标已存在且类型冲突时先删
            t = os.path.join(dest, m.name)
            if os.path.lexists(t) and not (m.isdir() and os.path.isdir(t) and not os.path.islink(t)):
                if os.path.isdir(t) and not os.path.islink(t): shutil.rmtree(t)
                else: os.unlink(t)
        tf.extractall(dest, members=keep, numeric_owner=True)
    print(f"[unpack] layer {i}/{len(man['Layers'])} ok")
cfg = json.load(open(os.path.join(work, man["Config"])))
json.dump(cfg.get("config", {}), open(os.path.join(dest, ".image_config.json"), "w"), indent=1)
EOF
du -sh "$DEST"
