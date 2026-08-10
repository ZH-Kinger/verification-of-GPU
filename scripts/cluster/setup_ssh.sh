#!/usr/bin/env bash
# 多机压测前置 —— head 节点到全部节点（含自己）的免密 SSH。
#
#   bash scripts/cluster/setup_ssh.sh <hostfile>
#
# mpirun 要求 head 能无交互登录每个节点。本脚本会：
#   1. 没有密钥就生成一把（~/.ssh/id_ed25519，无口令）
#   2. 对每个节点执行 ssh-copy-id（会逐台提示输入密码，这是唯一的交互点）
#   3. 复检：逐台跑 hostname，并核对驱动版本是否一致
#
# 注意：生成的是无口令密钥，仅用于验收环境。验收结束后按现场安全要求清理。

set -u

HOSTFILE="${1:-}"
if [ -z "$HOSTFILE" ] || [ ! -f "$HOSTFILE" ]; then
  echo "用法: bash scripts/cluster/setup_ssh.sh <hostfile>" >&2
  exit 2
fi

KEY="$HOME/.ssh/id_ed25519"
HOSTS="$(grep -vE '^\s*(#|$)' "$HOSTFILE" | awk '{print $1}')"

if [ ! -f "$KEY" ]; then
  echo "[ssh] 生成无口令密钥 $KEY"
  ssh-keygen -t ed25519 -N "" -f "$KEY" -C "gpu-acceptance"
fi

for h in $HOSTS; do
  echo "[ssh] 分发公钥到 $h"
  ssh-copy-id -i "${KEY}.pub" -o StrictHostKeyChecking=no "$h" || \
    echo "[ssh][WARN] $h 分发失败，稍后手工处理"
done

echo
echo "[ssh] 复检 —— 逐台 hostname / 驱动版本"
fail=0
for h in $HOSTS; do
  out="$(ssh -o BatchMode=yes -o StrictHostKeyChecking=no "$h" \
        'echo -n "$(hostname) "; nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n1' 2>&1)"
  rc=$?
  if [ $rc -ne 0 ]; then
    echo "  [FAIL] $h : $out"
    fail=1
  else
    echo "  [ OK ] $h : $out"
    echo "$out" | awk '{print $2}' >> /tmp/.acc_drivers.$$
  fi
done

if [ -f "/tmp/.acc_drivers.$$" ]; then
  n="$(sort -u "/tmp/.acc_drivers.$$" | grep -c .)"
  if [ "$n" -gt 1 ]; then
    echo
    echo "[ssh][WARN] 集群内驱动版本不一致（$n 种）——《验收标准》§7 要求全集群一致："
    sort -u "/tmp/.acc_drivers.$$" | sed 's/^/  /'
    fail=1
  fi
  rm -f "/tmp/.acc_drivers.$$"
fi

echo
[ "$fail" -eq 0 ] && echo "[ssh] 全部节点就绪。" || echo "[ssh] 存在问题，先解决再跑 nccl_scale.sh。"
exit "$fail"
