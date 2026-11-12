#!/bin/bash
# 在宿主容器里"进入"已解包的镜像用户态，而不 chroot（容器无 CAP_SYS_ADMIN，挂不了 /proc）。
#  - 用镜像自己的 ld-linux + glibc 启动镜像的 python，所以 torch / transformers 等全部来自镜像
#  - /dev /proc /sys /dev/shm /mnt 都是宿主真实的（≈ docker run --ipc host --network host）
#  - 在 $SHIM 放一个 python / python3 包装器并置于 PATH 首位，torchrun 和 multiprocessing
#    再派生的解释器也走镜像的 loader（sys.executable 指向包装器）
# 用法: source imgenv.sh <rootfs>   然后直接 python3 / torchrun
IMG=${1:?rootfs}
IMG_LD=$IMG/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2
IMG_PY=$(ls "$IMG"/usr/local/bin/python3.1[0-9] "$IMG"/usr/bin/python3.1[0-9] 2>/dev/null | head -1)
NVHOST=/usr/lib/x86_64-linux-gnu/nvhost
mkdir -p "$NVHOST"
cp -an /usr/lib/x86_64-linux-gnu/libcuda.so* /usr/lib/x86_64-linux-gnu/libnvidia-*.so* "$NVHOST"/ 2>/dev/null || true
IMG_LP=$NVHOST:$IMG/usr/local/lib:$IMG/usr/local/cuda/lib64:$IMG/usr/lib/x86_64-linux-gnu:$IMG/lib/x86_64-linux-gnu
SHIM=$IMG/.shim; mkdir -p "$SHIM"
cat > "$SHIM/python3" <<EOF
#!/bin/bash
exec "$IMG_LD" --library-path "$IMG_LP" "$IMG_PY" "\$@"
EOF
chmod +x "$SHIM/python3"; ln -sf python3 "$SHIM/python"
# torchrun 入口：镜像里的 console script 第一行是 #!/usr/local/bin/python3.x，换成走 shim
cat > "$SHIM/torchrun" <<EOF
#!/bin/bash
exec "$SHIM/python3" -m torch.distributed.run "\$@"
EOF
chmod +x "$SHIM/torchrun"
export PYTHONHOME=$IMG/usr/local
export PATH=$SHIM:$IMG/usr/local/bin:$IMG/usr/local/cuda/bin:$PATH
export PYTHONNOUSERSITE=1
export PYTHONEXECUTABLE=$SHIM/python3
# 子进程 sys.executable 用 shim（multiprocessing spawn / DataLoader worker）
export IMGENV_ROOT=$IMG
echo "[imgenv] $IMG  python=$IMG_PY  ld=$IMG_LD"
