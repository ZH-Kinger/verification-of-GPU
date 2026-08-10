#!/usr/bin/env bash
# 多机压测 —— 《验收标准》§5 高性能网络（RoCE v2）。
#
#   bash scripts/cluster/roce_check.sh <log_dir> [profile]                # 只做本机侧检查
#   PEER_IP=10.0.0.2 bash scripts/cluster/roce_check.sh <log_dir>         # 加做 perftest 打流
#
# 本机侧（无需对端）：网卡模式、端口状态、PFC、MTU、DSCP、丢包计数
# 对端侧（需 PEER_IP，且对端已起 ib_write_bw/ib_read_bw/ib_send_lat server）：
#   写带宽、读带宽、GPUDirect RDMA 带宽、小消息延迟
#
# 对端起服务端的方式（在 PEER_IP 那台机器上，逐项对应执行）：
#   ib_write_bw -d <dev> --report_gbits -s 65536 -x 3 -q 4
#   ib_read_bw  -d <dev> --report_gbits -s 65536 -x 3 -q 4
#   ib_send_lat -d <dev> -x 3
#
# 工具缺失时不报错，写一个 *_missing.txt，判定阶段记 SKIP。

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
. "$BASE_DIR/scripts/lib/common.sh"

PARENT="${1:-}"
if [ -z "$PARENT" ]; then
  echo "用法: bash scripts/cluster/roce_check.sh <log_dir> [profile]" >&2
  exit 2
fi
mkdir -p "$PARENT/roce"
LOG_DIR="$(cd "$PARENT/roce" && pwd)"
export LOG_DIR

load_profile "${2:-${PROFILE:-b300_8gpu}}" || exit 2

log() { echo "[roce] $*" | tee -a "$LOG_DIR/run.log"; }
have() { command -v "$1" >/dev/null 2>&1; }

# --------------------------------------------------------- 枚举 mlx5 设备
if have ibv_devinfo; then
  run_cmd ibv_devinfo ibv_devinfo
  DEVS="$(ibv_devinfo 2>/dev/null | awk '/hca_id:/{print $2}')"
else
  DEVS=""
fi
if [ -z "$DEVS" ]; then
  DEVS="$(ls /sys/class/infiniband 2>/dev/null || true)"
fi
IFACES="$(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -E '^(en|eth)' || true)"
# 优先用 mlx5 对应的以太网口
MLX_IFACES=""
for d in $DEVS; do
  p="/sys/class/infiniband/$d/device/net"
  [ -d "$p" ] && MLX_IFACES="$MLX_IFACES $(ls "$p" 2>/dev/null)"
done
[ -n "$MLX_IFACES" ] && IFACES="$MLX_IFACES"

echo "devices: $DEVS" > "$LOG_DIR/devices.txt"
echo "ifaces : $IFACES" >> "$LOG_DIR/devices.txt"
log "RDMA 设备: ${DEVS:-none}   以太网口: ${IFACES:-none}"

# --------------------------------------------------------- 网卡模式 / 端口
if have mlxconfig; then
  for d in $DEVS; do
    run_shell "mlxconfig_${d}" "mlxconfig -d $d q | grep -i LINK_TYPE || true"
  done
else
  echo "mlxconfig not found (MFT 未安装)" > "$LOG_DIR/mlxconfig_missing.txt"
fi

run_shell ip_link "ip -br link show 2>/dev/null | grep -E 'en|eth' || true"
run_shell ip_link_mtu "for i in $IFACES; do echo -n \"\$i \"; ip link show \$i | grep -o 'mtu [0-9]*'; done"

if have mlnx_qos; then
  for i in $IFACES; do
    run_shell "mlnx_qos_${i}" "mlnx_qos -i $i || true"
  done
else
  echo "mlnx_qos not found (DOCA-OFED 未安装)" > "$LOG_DIR/mlnx_qos_missing.txt"
fi

if have ethtool; then
  for i in $IFACES; do
    run_shell "ethtool_stats_${i}" "ethtool -S $i | grep -E 'pfc|pause|discard' || true"
  done
else
  echo "ethtool not found" > "$LOG_DIR/ethtool_missing.txt"
fi

# --------------------------------------------------------- perftest 打流
PEER="${PEER_IP:-}"
if [ -z "$PEER" ]; then
  log "未设置 PEER_IP，跳过 ib_write_bw / ib_read_bw / ib_send_lat（判定记 SKIP）"
  echo "PEER_IP not set" > "$LOG_DIR/perftest_skipped.txt"
else
  DEV="$(echo "$DEVS" | awk '{print $1}')"
  log "对端 $PEER，使用设备 $DEV"
  if have ib_write_bw; then
    # shellcheck disable=SC2086
    run_shell ib_write_bw "ib_write_bw -d $DEV $ROCE_PERFTEST_ARGS $PEER"
    if [ -n "${GDR_GPU:-}" ] || [ "${REQUIRE_GDRCOPY:-0}" = "1" ]; then
      # shellcheck disable=SC2086
      run_shell ib_write_bw_gdr "ib_write_bw -d $DEV --use_cuda=${GDR_GPU:-0} $ROCE_PERFTEST_ARGS $PEER"
    fi
  else
    echo "ib_write_bw not found (perftest 未安装)" > "$LOG_DIR/ib_write_bw_missing.txt"
  fi
  if have ib_read_bw; then
    # shellcheck disable=SC2086
    run_shell ib_read_bw "ib_read_bw -d $DEV $ROCE_PERFTEST_ARGS $PEER"
  else
    echo "ib_read_bw not found" > "$LOG_DIR/ib_read_bw_missing.txt"
  fi
  if have ib_send_lat; then
    run_shell ib_send_lat "ib_send_lat -d $DEV -x 3 $PEER"
  else
    echo "ib_send_lat not found" > "$LOG_DIR/ib_send_lat_missing.txt"
  fi
fi

log "完成。判定：bash scripts/cluster/check_cluster.sh $PARENT"
echo "RoCE logs: $LOG_DIR"
