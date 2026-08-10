#!/usr/bin/env bash
# 环境预检 —— 在跑任何验收项之前先确认"这台机器和这套工具能不能对上"。
#
#   sudo bash scripts/preflight.sh [profile]     # 默认 b300_8gpu
#
# 回答三个问题：
#   1. GPU 实际计算能力是多少？tools/ 里的预编译二进制能不能在上面跑？
#      （Blackwell Ultra 预期 sm_103；CUDA 12.8 编出的 sm_100 cubin 无法加载，
#        会报 "no kernel image is available for execution on the device"）
#   2. 驱动 / CUDA / NCCL / DCGM 版本是否满足该机型 profile 的下限？
#   3. 《验收标准》各章需要的工具，哪些在、哪些缺？缺的会导致对应项 SKIP。
#
# 退出码：0 = 可以继续；1 = 有阻断项（二进制跑不起来 / GPU 不可见）。

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

PROFILE_ARG="${1:-${PROFILE:-b300_8gpu}}"
load_profile "$PROFILE_ARG" || exit 2

LOG_ROOT="${LOG_ROOT:-$BASE_DIR/logs}"
ts="$(date +%F_%H%M%S)"
LOG_DIR="${LOG_DIR:-$LOG_ROOT/${ts}_preflight}"
mkdir -p "$LOG_DIR"

BLOCKING=0
note() { echo "[preflight] $*"; }
fail() { echo "[preflight][BLOCK] $*"; BLOCKING=1; }
warn() { echo "[preflight][WARN ] $*"; }

echo "=============================================================="
echo " 环境预检 — profile: $PROFILE_NAME ($ACC_PROFILE)"
echo " 期望: ${EXPECTED_GPU_COUNT} GPU, 计算能力 ${EXPECTED_COMPUTE_CAP}, CUDA >= ${CUDA_MIN_VERSION}"
echo " 日志: $LOG_DIR"
echo "=============================================================="

# ---------------------------------------------------------------- 1. 驱动/GPU
if ! command -v nvidia-smi >/dev/null 2>&1; then
  fail "nvidia-smi 不存在。当前多半在 fieldiag 模式（驱动被屏蔽）——"
  note "        新标准 §1/§3/§4/§7/§8 全部需要驱动，请重启进 dcgm 模式后再跑。"
else
  run_shell driver_version "nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -n1"
  drv="$(cap driver_version | tr -d ' ')"
  if [ -n "$drv" ] && ver_ge "$drv" "$DRIVER_MIN_VERSION"; then
    note "驱动版本 $drv  (>= $DRIVER_MIN_VERSION) OK"
  else
    warn "驱动版本 ${drv:-未知} 低于该机型要求的 $DRIVER_MIN_VERSION"
  fi

  run_shell gpu_count_probe "nvidia-smi -L"
  n="$(cap gpu_count_probe | grep -c '^GPU ')"
  if [ "$n" -eq "${EXPECTED_GPU_COUNT}" ]; then
    note "GPU 数量 $n OK"
  else
    fail "GPU 数量 $n，期望 ${EXPECTED_GPU_COUNT}"
  fi

  run_shell gpu_names_probe "nvidia-smi --query-gpu=name --format=csv,noheader | sort -u"
  note "GPU 型号: $(cap gpu_names_probe | tr '\n' ';')"
fi

# ------------------------------------------------- 2. 计算能力 vs 二进制架构
BIN_DIR="$(tools_bin_dir)"
note "预编译二进制目录: $BIN_DIR"
if [ ! -d "$BIN_DIR" ] || [ -z "$(ls -A "$BIN_DIR" 2>/dev/null)" ]; then
  fail "二进制目录为空。执行 bootstrap.sh 生成，或按 profile 的 CUDA_ARCH_LIST 重编。"
else
  if [ -x "$BIN_DIR/deviceQuery" ]; then
    run_cmd deviceQuery "$BIN_DIR/deviceQuery"
    cc="$(cap deviceQuery | grep -i 'CUDA Capability' | head -n1 | awk -F: '{gsub(/ /,"",$2); print $2}')"
    if [ -z "$cc" ]; then
      # 架构不匹配时 deviceQuery 根本跑不出 CC，只会报错
      if cap deviceQuery | grep -qi 'no kernel image'; then
        fail "deviceQuery 报 'no kernel image available' —— 预编译二进制的 fatbin 架构"
        note "        与本机 GPU 不符。必须用 CUDA_ARCH_LIST=\"$CUDA_ARCH_LIST\" 重新编译"
        note "        （见 docs/cuda_arch_decision.md）。§3/§4/§8 的带宽与压测项全部不可用。"
      else
        warn "deviceQuery 未能报告计算能力，见 $LOG_DIR/deviceQuery.txt"
      fi
    else
      note "实测计算能力 sm_${cc//./}  (CUDA Capability $cc)"
      if [ "$cc" = "$EXPECTED_COMPUTE_CAP" ]; then
        note "与 profile 期望一致 OK"
      else
        warn "与 profile 期望 $EXPECTED_COMPUTE_CAP 不一致 —— 确认选对了 profile，"
        warn "      并确认 tools 二进制含 sm_${cc//./} 目标码。"
      fi
      echo "$cc" > "$LOG_DIR/compute_capability.txt"
    fi
  else
    warn "$BIN_DIR/deviceQuery 不存在，无法确认计算能力与二进制兼容性"
  fi
fi

# ------------------------------------------------------------- 3. 软件栈版本
if command -v nvcc >/dev/null 2>&1; then
  run_cmd nvcc_version nvcc --version
  cuda_ver="$(cap nvcc_version | grep -oE 'release [0-9]+\.[0-9]+' | head -n1 | awk '{print $2}')"
  if [ -n "$cuda_ver" ] && ver_ge "$cuda_ver" "$CUDA_MIN_VERSION"; then
    note "CUDA $cuda_ver (>= $CUDA_MIN_VERSION) OK"
  else
    warn "CUDA ${cuda_ver:-未知} 低于该机型要求的 $CUDA_MIN_VERSION —— §7 该项会判 FAIL。"
    warn "      当前工具链若为 12.x，需整体升级并重编（docs/cuda_arch_decision.md）。"
  fi
else
  warn "nvcc 不存在（只装了 runtime 未装 toolkit）。§7 'CUDA 版本' 项会 SKIP。"
fi

if command -v dcgmi >/dev/null 2>&1; then
  run_cmd dcgmi_version dcgmi --version
  dcgm_ver="$(cap dcgmi_version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)"
  if [ -n "$dcgm_ver" ] && ver_ge "$dcgm_ver" "$DCGM_MIN_VERSION"; then
    note "DCGM $dcgm_ver (>= $DCGM_MIN_VERSION) OK"
  else
    warn "DCGM ${dcgm_ver:-未知} 低于 $DCGM_MIN_VERSION —— 该版本可能不认识本机 GPU，"
    warn "      dcgmi diag -r 3/-r 4 会失败或跳过测试项。"
  fi
else
  warn "dcgmi 不存在 —— §3 的 DCGM Level 3 / Level 4 会 SKIP。"
fi

# ------------------------------------------------------------- 4. 工具清单
echo
echo "--- 《验收标准》各章所需工具 ---"
check_tool() {
  local name="$1" section="$2" what="$3"
  if tool_path "$name" >/dev/null 2>&1; then
    printf '  [有]   %-26s §%-6s %s\n' "$name" "$section" "$what"
  else
    printf '  [缺]   %-26s §%-6s %s\n' "$name" "$section" "$what"
    echo "$name" >> "$LOG_DIR/missing_tools.txt"
  fi
}
check_tool nvidia-smi              "1,3,4,7,8" "基础查询与监控"
check_tool free                    "1"         "系统内存"
check_tool ipmitool                "1"         "风扇/传感器"
check_tool dmidecode               "1,2"       "内存条库存/识别率、CPU 规格"
check_tool stressapptest           "1"         "系统内存压测（memtester 为退化选项）"
check_tool nvme                    "2"         "本地 NVMe 配置"
check_tool dcgmi                   "3"         "DCGM Level 3 / Level 4"
check_tool gpu_burn                "3,8"       "1h / 长稳烤机"
check_tool nvbandwidth             "3,4"       "H2D/D2H/D2D 带宽"
check_tool p2pBandwidthLatencyTest "4"         "P2P 带宽矩阵与延迟"
check_tool all_reduce_perf         "4"         "节点内 AllReduce"
check_tool all_gather_perf         "4"         "节点内 AllGather"
check_tool nv-fabricmanager        "4,7"       "Fabric Manager"
check_tool gdrcopy_sanity          "7"         "GDRCopy 功能"
check_tool bandwidthTest           "7"         "cuda-samples 工具集"
check_tool mlxconfig               "5"         "网卡 Ethernet 模式"
check_tool mlnx_qos                "5"         "PFC / DSCP"
check_tool ethtool                 "5"         "PFC 暂停帧 / 丢包"
check_tool ib_write_bw             "5"         "RoCE 写带宽 / GPUDirect"
check_tool ib_read_bw              "5"         "RoCE 读带宽"
check_tool ib_send_lat             "5"         "RoCE 小消息延迟"
check_tool mpirun                  "5,6"       "跨节点启动器"
check_tool all_reduce_perf_mpi     "6"         "跨节点 NCCL"

echo
if [ -f "$LOG_DIR/missing_tools.txt" ]; then
  note "缺失工具清单: $LOG_DIR/missing_tools.txt"
  note "补齐方式见 docs/tooling_gaps.md（离线包获取方法）。"
fi

echo
if [ "$BLOCKING" -ne 0 ]; then
  echo "[preflight] 结论：存在阻断项，先解决上面的 [BLOCK] 再继续。"
  exit 1
fi
echo "[preflight] 结论：可以继续。缺失工具只会让对应项判 SKIP，不影响其余项。"
exit 0
