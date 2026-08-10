#!/usr/bin/env bash
# 写入《验收标准》§7 要求的 NVIDIA 内核模块参数。
#
#   sudo bash scripts/set_nvidia_modprobe_params.sh [profile]
#
# 标准要求 /etc/modprobe.d/nvidia.conf 含：
#   options nvidia NVreg_EnableStreamMemOPs=1 NVreg_RegistryDwords="PeerMappingOverride=1;"
#
# 写到独立文件 99-gpu-acceptance-nvidia.conf，不去动 set_fieldiag_driver_block.sh
# 生成的 blacklist 文件 —— 两者作用相反，混在一起会互相覆盖。
# 生效需要重新加载 nvidia 模块（实际操作等同于重启）。

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib/common.sh"
load_profile "${1:-${PROFILE:-b300_8gpu}}" || exit 2

CONF="/etc/modprobe.d/99-gpu-acceptance-nvidia.conf"

if [ "$(id -u)" -ne 0 ]; then
  echo "需要 root：sudo bash scripts/set_nvidia_modprobe_params.sh" >&2
  exit 1
fi

if [ -f "$CONF" ]; then
  cp -f "$CONF" "${CONF}.bak.$(date +%s)"
  echo "[modprobe] 已备份原文件"
fi

cat > "$CONF" <<'EOF'
# GPU acceptance — 《验收标准》§7 驱动参数
# StreamMemOPs: 允许 CUDA stream memory operations（NCCL/GPUDirect 路径需要）
# PeerMappingOverride: 放开 P2P 映射限制
options nvidia NVreg_EnableStreamMemOPs=1 NVreg_RegistryDwords="PeerMappingOverride=1;"
EOF

echo "[modprobe] 已写入 $CONF:"
cat "$CONF"

if grep -rqs 'blacklist nvidia' /etc/modprobe.d/ ; then
  echo
  echo "[modprobe][警告] /etc/modprobe.d/ 里仍有 nvidia blacklist（fieldiag 模式的产物）。"
  echo "                 驱动不会加载，本参数不会生效。跑新标准前请从 grub 选 dcgm 模式，"
  echo "                 或删除对应的 blacklist 文件。"
fi

echo
echo "[modprobe] 重启后用以下命令确认："
echo "  cat /proc/driver/nvidia/params | grep -E 'EnableStreamMemOPs|RegistryDwords'"
