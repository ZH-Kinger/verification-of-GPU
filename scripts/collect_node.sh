#!/usr/bin/env bash
# 单机离线压测 —— 采集《验收标准》§1 §2 §3 §4 §7 的全部测试项。
#
#   sudo bash scripts/collect_node.sh [profile]        # 默认 b300_8gpu
#
# 只负责"按标准原样执行命令并留证"，不做判定；判定交给 check_node.sh。
# 长稳烤机（§8）在 soak_node.sh 里单独跑。
#
# 环境变量：
#   LOG_DIR            指定日志目录（默认 logs/<ts>_<SN>）
#   SKIP_DCGM=1        跳过 dcgmi diag（r3 约 10-20 分钟，r4 更久）
#   RUN_DCGM_R4=1      额外跑 dcgmi diag -r 4
#   SKIP_GPU_BURN=1    跳过 §3 的 1 小时 gpu_burn
#   SKIP_BENCH=1       跳过 nvbandwidth / p2p / nccl 带宽测试

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

PROFILE_ARG="${1:-${PROFILE:-b300_8gpu}}"
load_profile "$PROFILE_ARG" || exit 2

LOG_ROOT="${LOG_ROOT:-$BASE_DIR/logs}"
ts="$(date +%F_%H%M%S)"

# 机器标识：日志目录名必须能指认是哪一台，否则批量验收时几十份日志分不开。
# 不能只回落到 hostname —— live USB 上每台机器的 hostname 都一样（ubuntu），
# 一批机器会产出一堆同名目录。按可靠性依次尝试。
machine_id() {
  local id
  id="$(dmidecode -s system-serial-number 2>/dev/null | tr -dc 'A-Za-z0-9._-' | head -c 64)"
  case "$id" in ""|*[Tt]o[Bb]e*|*[Nn]ot[Ss]pecified*|0|000*) id="" ;; esac
  [ -n "$id" ] && { echo "$id"; return; }

  # 主板 SN（部分机型整机 SN 为空但主板有）
  id="$(dmidecode -s baseboard-serial-number 2>/dev/null | tr -dc 'A-Za-z0-9._-' | head -c 64)"
  case "$id" in ""|*[Tt]o[Bb]e*|*[Nn]ot[Ss]pecified*|0|000*) id="" ;; esac
  [ -n "$id" ] && { echo "BB-$id"; return; }

  # GPU0 序列号：dcgm 模式下一定有，且天然唯一
  id="$(nvidia-smi --query-gpu=serial --format=csv,noheader 2>/dev/null | head -n1 | tr -dc 'A-Za-z0-9')"
  [ -n "$id" ] && [ "$id" != "0" ] && { echo "GPU-$id"; return; }

  # 第一块物理网卡 MAC
  id="$(cat /sys/class/net/*/address 2>/dev/null | grep -v '^00:00:00' | head -n1 | tr -d ':')"
  [ -n "$id" ] && { echo "MAC-$id"; return; }

  echo "${HOSTNAME:-UNKNOWN_HOST}"
}
host_sn="$(machine_id)"

LOG_DIR="${LOG_DIR:-$LOG_ROOT/${ts}_${host_sn}}"
mkdir -p "$LOG_DIR"
export LOG_DIR

BIN_DIR="$(tools_bin_dir)"

{
  echo "Offline GPU Acceptance — 单机采集"
  echo "Timestamp: $ts"
  # live 系统默认 UTC 且离线无 NTP，时间戳可能既不是本地时间也不准。
  # 把时区和 RTC 状态一并记下来，事后对账才有依据。
  echo "Timezone: $(date +%Z%z) ($(timedatectl show -p Timezone --value 2>/dev/null || echo unknown))"
  echo "Clock synced: $(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo unknown)"
  echo "Host SN: $host_sn"
  echo "Profile: $ACC_PROFILE ($PROFILE_NAME)"
  echo "Arch note: $PROFILE_ARCH_NOTE"
  echo "Expected GPU count: $EXPECTED_GPU_COUNT"
  echo "Tools bin dir: $BIN_DIR"
  echo "Log dir: $LOG_DIR"
} > "$LOG_DIR/session.txt"
cp -f "$BASE_DIR/profiles/${ACC_PROFILE}.env" "$LOG_DIR/profile.env" 2>/dev/null || true

log() { echo "[collect] $*" | tee -a "$LOG_DIR/run.log"; }
have() { command -v "$1" >/dev/null 2>&1; }
bin_or_path() { tool_path "$1" 2>/dev/null; }

log "profile=$ACC_PROFILE  log_dir=$LOG_DIR"

# 非 root 会静默降级一大片：dmidecode（内存库存/识别率、机器 SN）、
# nvidia-smi -pm（持久模式）、dmesg（XID 扫描）、ipmitool（风扇）全部拿不到，
# 判定表看起来照常出，只是多了一堆 SKIP —— 现场很容易没注意就签了字。
if [ "$(id -u)" -ne 0 ]; then
  log "======================================================================"
  log "警告：当前不是 root。以下项将无法采集，判定时会记 SKIP："
  log "  §1 内存识别率/内存条一致性、风扇状态   （dmidecode / ipmitool 需要 root）"
  log "  §2 内存规格、机器 SN                   （日志目录名会退化为网卡 MAC 或主机名）"
  log "  §3 持久模式设置、内核日志 XID 扫描"
  log "正确用法：sudo bash scripts/collect_node.sh $ACC_PROFILE"
  log "======================================================================"
  echo "collected as non-root (uid=$(id -u)); many items degraded to SKIP" \
    > "$LOG_DIR/WARNING_NOT_ROOT.txt"
fi

# ============================================================ §1 物理与环境
section_1_physical() {
  log "§1 物理与环境"
  have nvidia-smi && run_cmd nvidia_smi_L nvidia-smi -L
  run_cmd free_h free -h
  run_cmd free_b free -b
  # 完整的内存条库存 —— 判定不假设"应该有多少内存"，而是拿机器自己报的
  # 已装容量去比对 free 实际认到的容量，配置换了也不用改脚本。
  have dmidecode && run_cmd dmidecode_memory_full dmidecode -t memory
  if have ipmitool; then
    run_shell ipmi_fan "ipmitool sensor list | grep -i fan || true"
    run_shell ipmi_sensor_all "ipmitool sensor list || true"
    run_shell ipmi_sel "ipmitool sel list | tail -n 200 || true"
  else
    echo "ipmitool not found" > "$LOG_DIR/ipmi_fan.txt"
  fi
}

# ========================================================== §2 基础配置规格
section_2_spec() {
  log "§2 基础配置规格"
  have dmidecode && run_cmd dmidecode_system dmidecode -t system
  have dmidecode && run_cmd dmidecode_baseboard dmidecode -t baseboard
  have dmidecode && run_shell dmidecode_memory "dmidecode -t memory | grep -E 'Size|Speed|Manufacturer|Part Number|Type:' || true"
  have lscpu && run_cmd lscpu lscpu
  have lsblk && run_cmd lsblk lsblk -o NAME,SIZE,TYPE,MODEL,MOUNTPOINT
  have nvme && run_cmd nvme_list nvme list
  have lspci && run_shell gpu_lspci "lspci | grep -i nvidia || true"
  have lspci && run_shell nic_lspci "lspci | grep -iE 'mellanox|connectx' || true"
  # RAID / 系统盘：尽力而为，不同平台工具不同
  run_shell raid_probe "for t in storcli64 perccli64 mvcli arcconf; do command -v \$t >/dev/null 2>&1 && echo \"== \$t ==\" && \$t show 2>/dev/null; done; true"
}

# =================================================== 系统内存压测（DDR5）
# 标准只查内存容量，没有要求压测。但 3TB 级 DDR5 不做压测等于放过一整类隐患：
# 松动/劣化的内存条在容量上完全正常，只有在持续读写下才暴露。
# GPU 显存（HBM）不走这里 —— 它由 dcgmi diag -r 4 的 Memtest 和 gpu_burn 覆盖。
section_mem_stress() {
  local secs="${SYS_MEM_STRESS_SECONDS:-0}"
  if [ "${SKIP_MEM_STRESS:-0}" = "1" ] || [ "$secs" -eq 0 ] 2>/dev/null; then
    echo "system memory stress skipped (SYS_MEM_STRESS_SECONDS=$secs)" > "$LOG_DIR/mem_stress_skipped.txt"
    return 0
  fi

  # 用可用内存的 SYS_MEM_STRESS_PCT%，避免把机器压进 OOM killer
  local avail_kb pct mb
  avail_kb="$(awk '/^MemAvailable:/{print $2}' /proc/meminfo 2>/dev/null || echo 0)"
  pct="${SYS_MEM_STRESS_PCT:-80}"
  mb=$(( avail_kb / 1024 * pct / 100 ))

  if have stressapptest; then
    log "  stressapptest ${secs}s，占用 ${mb} MB（可用内存的 ${pct}%）"
    # -W 用更激进的复制线程；-M 指定占用量；-m 线程数取核数
    run_shell mem_stress \
      "stressapptest -s $secs -M $mb -m $(nproc) -W 2>&1"
    echo "stressapptest" > "$LOG_DIR/mem_stress_tool.txt"
  elif have memtester; then
    log "  memtester ${mb}MB（stressapptest 不可用，退化为 memtester 单轮）"
    run_shell mem_stress "memtester ${mb}M 1 2>&1"
    echo "memtester" > "$LOG_DIR/mem_stress_tool.txt"
  else
    echo "stressapptest / memtester 均未安装 —— 见 docs/tooling_gaps.md" \
      > "$LOG_DIR/mem_stress_missing.txt"
  fi
}

# ========================================================== §3 GPU 硬件验证
section_3_gpu() {
  log "§3 GPU 硬件验证"
  if ! have nvidia-smi; then
    echo "nvidia-smi not found — §3/§4/§7/§8 无法采集" > "$LOG_DIR/nvidia_smi_missing.txt"
    return 0
  fi

  run_cmd nvidia_smi_q nvidia-smi -q
  run_shell q_memory_total "nvidia-smi --query-gpu=index,memory.total --format=csv,noheader"
  run_shell q_ecc_mode "nvidia-smi --query-gpu=index,ecc.mode.current --format=csv,noheader"
  run_shell q_ecc_uncorrected "nvidia-smi --query-gpu=index,ecc.errors.uncorrected.aggregate.total --format=csv,noheader"
  run_shell q_ecc_corrected "nvidia-smi --query-gpu=index,ecc.errors.corrected.volatile.total --format=csv,noheader"
  run_shell q_power_limit "nvidia-smi --query-gpu=index,power.limit --format=csv,noheader"
  run_shell q_persistence "nvidia-smi --query-gpu=index,persistence_mode --format=csv,noheader"
  run_shell q_clocks "nvidia-smi --query-gpu=index,clocks.current.graphics,clocks.max.graphics --format=csv,noheader"
  run_shell q_throttle "nvidia-smi --query-gpu=index,clocks_throttle_reasons.active --format=csv,noheader"
  run_cmd perf_state nvidia-smi -q -d PERFORMANCE
  # PCIe：空闲时链路会降速省电，因此同时记录 current 与 max，判定以 max 为准、
  # current 作为压测期间的旁证（见 check_node.sh 的说明）。
  run_shell q_pcie "nvidia-smi --query-gpu=index,pcie.link.gen.current,pcie.link.gen.max,pcie.link.width.current,pcie.link.width.max --format=csv,noheader"
  run_shell q_overview "nvidia-smi --query-gpu=index,name,uuid,serial,vbios_version,memory.total,power.limit,temperature.gpu --format=csv"

  # 持久模式：标准要求先置位再确认
  if [ "${SET_PERSISTENCE:-1}" = "1" ]; then
    run_shell set_persistence "nvidia-smi -pm 1"
    run_shell q_persistence_after "nvidia-smi --query-gpu=index,persistence_mode --format=csv,noheader"
  fi

  # DCGM
  if [ "${SKIP_DCGM:-0}" != "1" ] && have dcgmi; then
    log "  dcgmi diag -r 3（耗时较长）"
    run_cmd dcgm_diag_r3 dcgmi diag -r 3 -j
    if [ "${RUN_DCGM_R4:-0}" = "1" ]; then
      log "  dcgmi diag -r 4（含 Memtest / 扩展 EUD，耗时很长）"
      run_cmd dcgm_diag_r4 dcgmi diag -r 4 -j
    fi
  else
    if [ "${SKIP_DCGM:-0}" = "1" ]; then
      echo "SKIP_DCGM=1（操作员主动跳过）" > "$LOG_DIR/dcgm_skipped.txt"
    else
      echo "dcgmi not found — 见 docs/tooling_gaps.md（打包缺口）" > "$LOG_DIR/dcgm_missing.txt"
    fi
  fi

  # §3 的 1 小时 gpu_burn
  if [ "${SKIP_GPU_BURN:-0}" = "1" ]; then
    echo "SKIP_GPU_BURN=1（操作员主动跳过）" > "$LOG_DIR/gpu_burn_skipped.txt"
  fi
  if [ "${SKIP_GPU_BURN:-0}" != "1" ]; then
    local burn
    burn="$(bin_or_path gpu_burn)"
    if [ -n "$burn" ]; then
      log "  gpu_burn -tc ${GPU_BURN_SHORT_SECONDS}（约 $((GPU_BURN_SHORT_SECONDS / 60)) 分钟）"
      run_shell ecc_before_burn "nvidia-smi --query-gpu=index,ecc.errors.corrected.volatile.total,ecc.errors.uncorrected.aggregate.total --format=csv,noheader"
      ( cd "$(dirname "$burn")" && ./"$(basename "$burn")" -tc "$GPU_BURN_SHORT_SECONDS" ) \
        > "$LOG_DIR/gpu_burn_1h.txt" 2>&1
      echo "$?" > "$LOG_DIR/gpu_burn_1h.exit"
      run_shell ecc_after_burn "nvidia-smi --query-gpu=index,ecc.errors.corrected.volatile.total,ecc.errors.uncorrected.aggregate.total --format=csv,noheader"
      run_shell temp_after_burn "nvidia-smi --query-gpu=index,temperature.gpu --format=csv,noheader"
    else
      echo "gpu_burn not found — 见 docs/tooling_gaps.md" > "$LOG_DIR/gpu_burn_missing.txt"
    fi
  fi
}

# ================================================= §3/§4 带宽（nvbandwidth 等）
section_4_nvlink() {
  log "§4 NVLink / P2P / NCCL"
  have nvidia-smi && run_cmd nvidia_smi_topo nvidia-smi topo -m
  if have nvidia-smi; then
    run_shell nvlink_status "for i in \$(seq 0 \$((${EXPECTED_GPU_COUNT} - 1))); do echo \"== GPU \$i ==\"; nvidia-smi nvlink -s -i \$i; done"
    run_shell nvlink_errors "for i in \$(seq 0 \$((${EXPECTED_GPU_COUNT} - 1))); do echo \"== GPU \$i ==\"; nvidia-smi nvlink -e -i \$i; done"
  fi

  if [ "${SKIP_BENCH:-0}" = "1" ]; then
    log "  SKIP_BENCH=1，跳过带宽/集合通信测试（拓扑、链路、FM 仍然采集）"
    echo "SKIP_BENCH=1" > "$LOG_DIR/bench_skipped.txt"
    return 0
  fi

  local nvb
  nvb="$(bin_or_path nvbandwidth)"
  if [ -n "$nvb" ]; then
    run_cmd nvb_h2d "$nvb" --testcase host_to_device_memcpy_ce
    run_cmd nvb_d2h "$nvb" --testcase device_to_host_memcpy_ce
    run_cmd nvb_d2d "$nvb" --testcase device_to_device_memcpy_read_ce
  else
    echo "nvbandwidth not found" > "$LOG_DIR/nvbandwidth_missing.txt"
  fi

  local p2p
  p2p="$(bin_or_path p2pBandwidthLatencyTest)"
  if [ -n "$p2p" ]; then
    run_cmd p2p_bw_lat "$p2p"
  else
    echo "p2pBandwidthLatencyTest not found" > "$LOG_DIR/p2p_missing.txt"
  fi

  local ar ag
  ar="$(bin_or_path all_reduce_perf)"
  ag="$(bin_or_path all_gather_perf)"
  # shellcheck disable=SC2086
  if [ -n "$ar" ]; then
    run_cmd nccl_all_reduce "$ar" $NCCL_BENCH_ARGS
  else
    echo "all_reduce_perf not found" > "$LOG_DIR/nccl_all_reduce_missing.txt"
  fi
  # shellcheck disable=SC2086
  if [ -n "$ag" ]; then
    run_cmd nccl_all_gather "$ag" $NCCL_BENCH_ARGS
  else
    echo "all_gather_perf not found" > "$LOG_DIR/nccl_all_gather_missing.txt"
  fi

}

# Fabric Manager 单独成段。它跟带宽测试没有任何关系，放在 section_4 里会被
# SKIP_BENCH=1 一起跳过 —— 一个只想快速看静态项的操作员会静默丢掉这一项。
section_fabric_manager() {
  log "§4/§7 Fabric Manager"
  if have systemctl; then
    run_shell fm_status "systemctl status nvidia-fabricmanager --no-pager 2>&1 || true"
    run_shell fm_is_active "systemctl is-active nvidia-fabricmanager 2>&1 || true"
    run_shell fm_journal "journalctl -u nvidia-fabricmanager --no-pager 2>/dev/null | tail -n 300 || true"
  fi
  have nv-fabricmanager && run_shell fm_version "nv-fabricmanager --version 2>&1 || true"
}

# =========================================================== §7 GPU 软件栈
section_7_stack() {
  log "§7 GPU 软件栈"
  have nvidia-smi && run_shell q_driver "nvidia-smi --query-gpu=index,driver_version --format=csv,noheader"
  have nvcc && run_cmd nvcc_version nvcc --version
  run_shell lsmod_peermem "lsmod | grep -E 'nvidia_peermem|nvidia-peermem' || true"
  run_shell modprobe_conf "cat /etc/modprobe.d/nvidia*.conf 2>/dev/null || true"
  run_shell nccl_version "ls /usr/lib/x86_64-linux-gnu/libnccl.so.* 2>/dev/null; dpkg -l 2>/dev/null | grep -i nccl || true"
  have dcgmi && run_cmd dcgmi_version dcgmi --version

  local gdr
  gdr="$(bin_or_path gdrcopy_sanity)"
  if [ -n "$gdr" ]; then
    run_cmd gdrcopy_sanity "$gdr"
  else
    echo "gdrcopy_sanity not found" > "$LOG_DIR/gdrcopy_missing.txt"
  fi

  run_shell cuda_samples_present "for t in p2pBandwidthLatencyTest bandwidthTest deviceQuery; do p=\$(command -v \$t 2>/dev/null || echo \"$BIN_DIR/\$t\"); if [ -x \"\$p\" ]; then echo \"\$t: \$p\"; else echo \"\$t: MISSING\"; fi; done"
  [ -x "$BIN_DIR/deviceQuery" ] && run_cmd deviceQuery "$BIN_DIR/deviceQuery"
}

# ================================================================ 内核日志
collect_kernel_logs() {
  local tag="${1:-}"
  have dmesg && run_shell "dmesg_gpu${tag}" "dmesg -T | grep -iE 'nvrm|xid|ecc|pcie|aer|nvlink|fallen|reset' || true"
  have dmesg && run_shell "xid_count${tag}" "dmesg -T | grep -ci 'xid' || true"
  have journalctl && run_shell "journal_gpu${tag}" "journalctl -k --no-pager 2>/dev/null | grep -iE 'nvrm|xid|ecc|nvlink|fallen' || true"
}

main() {
  collect_kernel_logs "_before"
  section_1_physical
  section_2_spec
  section_mem_stress
  section_3_gpu
  section_4_nvlink
  section_fabric_manager
  section_7_stack
  collect_kernel_logs "_after"
  log "采集完成"
  echo "Logs saved to: $LOG_DIR"
}

main "$@"
