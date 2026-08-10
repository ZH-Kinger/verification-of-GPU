#!/usr/bin/env bash
# 安装《验收标准》要求、但基础系统没有的工具（离线 noble deb）。
#
#   sudo bash scripts/install_offline_tools.sh
#
# 包含：
#   ipmitool   §1 风扇状态
#   stressapptest §1 系统内存压测（memtester 为退化选项）
#   ethtool    §5 PFC 暂停帧 / 丢包
#   nvme-cli   §2 本地 NVMe 配置
#   openmpi    §5 §6 跨节点，*_perf_mpi 的运行依赖
#
# 这些包由 bootstrap/30_fetch_offline_deb_noble.sh 抓到
# downloads/offline_deb_noble/tools/。缺了它们对应的验收项会判 SKIP 而不是 PASS。

set -u

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEB_DIR="${DEB_DIR:-$BASE_DIR/downloads/offline_deb_noble/tools}"

if [ "$(id -u)" -ne 0 ]; then
  echo "需要 root：sudo bash scripts/install_offline_tools.sh"
  exit 1
fi

if [ ! -d "$DEB_DIR" ]; then
  echo "离线 deb 目录不存在: $DEB_DIR"
  echo "在联网工作主机上先跑: bash bootstrap.sh offline_deb"
  exit 1
fi

shopt -s nullglob
debs=("$DEB_DIR"/*.deb)
if [ "${#debs[@]}" -eq 0 ]; then
  echo "$DEB_DIR 里没有 .deb"
  exit 1
fi

echo "从 $DEB_DIR 安装 ${#debs[@]} 个包"
# 依赖闭包完整时一次 dpkg -i 即可；顺序问题用重跑一次解决，不需要网络。
dpkg -i "${debs[@]}" 2>&1 | tail -n 20
echo "--- 第二遍（解决安装顺序造成的依赖未满足）---"
dpkg -i "${debs[@]}" >/dev/null 2>&1
rc=$?
ldconfig

echo
echo "dpkg exit=$rc  逐个确认："
for t in ipmitool stressapptest ethtool nvme mpirun; do
  if command -v "$t" >/dev/null 2>&1; then
    printf '  [有] %-10s %s\n' "$t" "$(command -v "$t")"
  else
    printf '  [缺] %-10s 对应验收项将判 SKIP\n' "$t"
  fi
done
