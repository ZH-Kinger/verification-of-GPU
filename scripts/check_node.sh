#!/usr/bin/env bash
# 单机判定 —— 解析 collect_node.sh / soak_node.sh 的日志目录，逐条对照
# 《验收标准》§1-§4 §7 §8 的阈值，输出 PASS/FAIL 表。
#
#   bash scripts/check_node.sh <log_dir> [profile]
#
# 输出：
#   <log_dir>/acceptance_report.tsv           机器可读，一行一个标准项
#   <log_dir>/acceptance_report.tsv.summary   汇总
#   <log_dir>/acceptance_report.txt           对齐后的人读表
#
# 判定值：PASS / FAIL / SKIP（工具缺失或未运行）/ MANUAL（标准要求人工核对）
# 只要有一项 FAIL，整机判 FAIL；无 FAIL 但有 SKIP，判 HOLD。

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

LOG_DIR="${1:-}"
if [ -z "$LOG_DIR" ] || [ ! -d "$LOG_DIR" ]; then
  echo "用法: bash scripts/check_node.sh <log_dir> [profile]" >&2
  exit 2
fi
LOG_DIR="$(cd "$LOG_DIR" && pwd)"
export LOG_DIR

# profile 优先级：命令行 > 采集时存进日志目录的 profile.env > 默认
PROFILE_ARG="${2:-}"
if [ -z "$PROFILE_ARG" ] && [ -f "$LOG_DIR/profile.env" ]; then
  # shellcheck disable=SC1091
  . "$LOG_DIR/profile.env"
  ACC_PROFILE="$(grep -oE '^Profile: [a-z0-9_]+' "$LOG_DIR/session.txt" 2>/dev/null | awk '{print $2}')"
  ACC_PROFILE="${ACC_PROFILE:-recorded}"
  # 快照是采集当时的版本，可能缺后来新增的变量。补齐声明，否则 set -u
  # 会让判定中途死掉、只留下一份看着正常实际残缺的表。
  apply_profile_defaults
  MISSING_KEYS="$(comm -23 \
      <(grep -oE '^[A-Z][A-Z0-9_]+=' "$BASE_DIR/profiles/b300_8gpu.env" | tr -d '=' | sort -u) \
      <(grep -oE '^[A-Z][A-Z0-9_]+=' "$LOG_DIR/profile.env" | tr -d '=' | sort -u) | tr '\n' ' ')"
  if [ -n "${MISSING_KEYS// /}" ]; then
    echo "[check] 注意：日志里记录的 profile 快照缺少以下变量，相关项将判 SKIP：" >&2
    echo "[check]   $MISSING_KEYS" >&2
    echo "[check] 想按当前标准复核请显式指定：bash scripts/check_node.sh $LOG_DIR b300_8gpu" >&2
  fi
else
  load_profile "${PROFILE_ARG:-${PROFILE:-b300_8gpu}}" || exit 2
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

report_init "$LOG_DIR/acceptance_report.tsv"

# ------------------------------------------------------------- 解析小工具
# CSV(noheader) 第 n 列，去空格
colN() {
  local name="$1" n="$2"
  cap "$name" | awk -F',' -v n="$n" 'NF>=n {gsub(/^[ \t]+|[ \t]+$/,"",$n); print $n}'
}
# 第 n 列的首个数字（丢掉 "MiB"/"W" 之类单位）。
# 非数值（典型是 nvidia-smi 的 "[N/A]"）整行丢弃，绝不能让 awk 把它算成 0 ——
# 那会把"没有数据"变成"计数为 0"，直接给出假 PASS。
colN_num() { colN "$1" "$2" | awk '$1 ~ /^-?[0-9]+([.][0-9]+)?$/ {print $1+0}'; }

# 某列里 N/A 的条数：>0 说明驱动没报告这项，只能判 SKIP
na_count() { colN "$1" "$2" | grep -ci 'n/a' || true; }

# 一列数值的 min~max 摘要；全部相同时只显示一个值。
range_of() {
  awk 'BEGIN{mn="";mx=""} {v=$1+0; if(mn==""||v<mn)mn=v; if(mx==""||v>mx)mx=v}
       END{ if(mn=="") exit;
            f=(mn==int(mn)&&mx==int(mx))?"%d":"%.2f";
            if(mn==mx) printf f, mn; else { printf f"~"f, mn, mx } }'
}
# "n/N" 形式的计数，用来替代"全部 xxx"这种说不出数的表述
count_eq() { # <file> <col> <expected>
  colN "$1" "$2" | awk -v e="$3" 'BEGIN{n=0;t=0} {t++; if($0==e) n++} END{printf "%d/%d", n, t}'
}

# 每个测试项对应的原始命令 —— 输出表里的"测试手段/命令"列，
# 与甲方《验收标准》表格逐条对应，便于复核和现场复现。
cmd_of() {
  case "$1" in
    "GPU 数量")            echo "nvidia-smi -L | wc -l" ;;
    "系统内存(DDR5)")      echo "free -h" ;;
    "内存识别率")          echo "free -b 与 dmidecode -t memory 对比" ;;
    "内存条一致性")        echo "dmidecode -t memory" ;;
    "内存压力测试")        echo "stressapptest -s ${SYS_MEM_STRESS_SECONDS:-1800} -M <可用内存的${SYS_MEM_STRESS_PCT:-80}%> -m \$(nproc) -W" ;;
    "风扇状态")            echo "ipmitool sensor list | grep -i fan" ;;
    "GPU 温度(压测期间)")  echo "nvidia-smi --query-gpu=temperature.gpu --format=csv" ;;
    "CPU 型号")            echo "lscpu" ;;
    "内存规格")            echo "dmidecode -t memory" ;;
    "系统盘/本地盘")       echo "lsblk" ;;
    "本地 NVMe 配置")      echo "nvme list" ;;
    "品牌一致性")          echo "dmidecode -t system" ;;
    "单卡显存")            echo "nvidia-smi --query-gpu=memory.total --format=csv,noheader" ;;
    "节点总显存")          echo "上项求和" ;;
    "ECC 状态确认")        echo "nvidia-smi --query-gpu=ecc.mode.current --format=csv" ;;
    "不可纠正错误")        echo "nvidia-smi --query-gpu=ecc.errors.uncorrected.aggregate.total --format=csv" ;;
    "可纠正错误")          echo "nvidia-smi --query-gpu=ecc.errors.corrected.volatile.total --format=csv" ;;
    "TDP")                 echo "nvidia-smi --query-gpu=power.limit --format=csv" ;;
    "DCGM Level 3")        echo "dcgmi diag -r 3 -j" ;;
    "DCGM Level 4（含 Memtest/EUD）") echo "dcgmi diag -r 4" ;;
    "1 小时压测")          echo "gpu_burn -tc ${GPU_BURN_SHORT_SECONDS:-3600}" ;;
    "压测 ECC 增量")       echo "压测前后 ecc.errors.corrected.volatile.total 之差" ;;
    "Persistence Mode")    echo "nvidia-smi -pm 1 && nvidia-smi --query-gpu=persistence_mode --format=csv" ;;
    "满载时钟")            echo "nvidia-smi --query-gpu=clocks.current.graphics --format=csv" ;;
    "节流原因")            echo "nvidia-smi --query-gpu=clocks_throttle_reasons.active --format=csv" ;;
    "PCIe Gen/Width")      echo "nvidia-smi --query-gpu=pcie.link.gen.current,pcie.link.width.current --format=csv" ;;
    "H2D 带宽")            echo "nvbandwidth --testcase host_to_device_memcpy_ce" ;;
    "D2H 带宽")            echo "nvbandwidth --testcase device_to_host_memcpy_ce" ;;
    "GPU 间带宽")          echo "nvbandwidth --testcase device_to_device_memcpy_read_ce" ;;
    "拓扑验证")            echo "nvidia-smi topo -m" ;;
    "链路检查")            echo "nvidia-smi nvlink -s -i <0-7>" ;;
    "CRC / Replay")        echo "nvidia-smi nvlink -e -i <0-7>" ;;
    "P2P Access"|"单向 P2P 带宽") echo "p2pBandwidthLatencyTest" ;;
    "GPU 间 P2P 延迟")     echo "p2pBandwidthLatencyTest (Latency 输出)" ;;
    "FM 状态")             echo "systemctl status nvidia-fabricmanager" ;;
    "版本")  # 驱动与 CUDA 共用这个项名，按模块区分
      case "${2:-}" in
        CUDA) echo "nvcc --version" ;;
        *)    echo "nvidia-smi --query-gpu=driver_version --format=csv" ;;
      esac ;;
    "模块")                echo "lsmod | grep nvidia_peermem" ;;
    "FM 版本与状态")       echo "nv-fabricmanager --version && systemctl status nvidia-fabricmanager" ;;
    "GDRCopy 功能")        echo "gdrcopy_sanity" ;;
    "cuda-samples 工具集") echo "which p2pBandwidthLatencyTest && which bandwidthTest" ;;
    "NVIDIA 内核模块参数") echo "cat /etc/modprobe.d/nvidia.conf" ;;
    "内核日志 XID / 掉卡") echo "dmesg -T | grep -iE 'xid|fallen off'" ;;
    *AllReduce)            echo "./all_reduce_perf ${NCCL_BENCH_ARGS}" ;;
    *AllGather)            echo "./all_gather_perf ${NCCL_BENCH_ARGS}" ;;
    "GPU 满载稳定性")      echo "gpu_burn -tc ${SOAK_SECONDS} + 持续 NCCL AllReduce" ;;
    "温度峰值"|"温度波动"|"温度峰值/波动") echo "nvidia-smi dmon -s pucvmet -d ${SOAK_SAMPLE_INTERVAL_S}" ;;
    "XID 增量")            echo "dmesg -T | grep -ci xid（压测前后差值）" ;;
    "可纠正 ECC 增量"|"不可纠正 ECC 增量") echo "ecc.errors.*（压测前后差值）" ;;
    "NVLink CRC 增量")     echo "nvidia-smi nvlink -e（压测前后差值）" ;;
    *)                     echo "-" ;;
  esac
}
# 所有值是否都等于某字符串
all_equal() {
  local expected="$1"
  awk -v e="$expected" 'BEGIN{ok=1;n=0} {n++; if($0!=e) ok=0} END{ if(n==0) print "EMPTY"; else print (ok?"YES":"NO") }'
}

section="1"

# ============================================================ §1 物理与环境
gpu_count="$(cap nvidia_smi_L | grep -c '^GPU ')"
if [ "$gpu_count" -eq 0 ]; then
  report_row 1 "节点物理" "GPU 数量" "0（nvidia-smi 无输出）" "$EXPECTED_GPU_COUNT" FAIL \
    "驱动未加载或未采集；后续 GPU 相关项全部不可判"
else
  report_eq 1 "节点物理" "GPU 数量" "$gpu_count" "$EXPECTED_GPU_COUNT"
fi

# --- 系统内存：报实际值，不假设配置 ---
# dmidecode 的内存条库存（已装容量、条数、容量/频率是否一致）
dmi_mem() { cap dmidecode_memory_full; }
dmi_installed_gib="$(dmi_mem | awk '
    /^[[:space:]]*Size:[[:space:]]*[0-9]+[[:space:]]*(GB|MB)/{
      v=$2; u=$3; if(u=="MB") v=v/1024; s+=v }
    END{ if(s>0) printf "%.0f", s }')"
dmi_populated="$(dmi_mem | grep -cE '^[[:space:]]*Size:[[:space:]]*[0-9]+' || true)"
dmi_slots="$(dmi_mem | grep -cE '^[[:space:]]*Size:' || true)"
# 注意分隔符不能用 "/"：频率字符串本身就含斜杠（"6400 MT/s"），
# 先各自数出唯一值个数，再拼成展示用的字符串。
dmi_size_list="$(dmi_mem | awk '/^[[:space:]]*Size:[[:space:]]*[0-9]+/{print $2" "$3}' | sort -u)"
dmi_speed_list="$(dmi_mem | awk '/^[[:space:]]*Configured Memory Speed:[[:space:]]*[0-9]+/{print $4" "$5}' | sort -u)"
n_size="$(printf '%s\n' "$dmi_size_list" | grep -c . || true)"
n_speed="$(printf '%s\n' "$dmi_speed_list" | grep -c . || true)"
dmi_sizes="$(printf '%s' "$dmi_size_list" | paste -sd',' -)"
dmi_speeds="$(printf '%s' "$dmi_speed_list" | paste -sd',' -)"

mem_bytes="$(cap free_b | awk '/^Mem:/{print $2}')"
mem_gib=""
is_num "$mem_bytes" && mem_gib="$(awk -v b="$mem_bytes" 'BEGIN{printf "%.0f", b/1073741824}')"

# 1) 容量：只对照标准给的下限（十进制 TB → GiB），实际有多少就报多少
if is_num "$mem_gib"; then
  # 不能用 ${SYS_MEM_MIN_TB:-0} 兜底：0 是合法数字，会绕过 report_ge 的阈值守卫，
  # 变成 "要求 >= 0 GiB" 的假 PASS。阈值缺失就传空，让它判 SKIP。
  min_gib=""
  is_num "$SYS_MEM_MIN_TB" && \
    min_gib="$(awk -v t="$SYS_MEM_MIN_TB" 'BEGIN{printf "%.0f", t*1000000000000/1073741824}')"
  report_ge 1 "节点物理" "系统内存(DDR5)" "$mem_gib" "$min_gib" "GiB" \
    "实测 ${mem_gib} GiB$( [ -n "$dmi_installed_gib" ] && echo "；dmidecode 已装 ${dmi_installed_gib} GiB / ${dmi_populated} 条（共 ${dmi_slots} 槽）" )；标准 ≥${SYS_MEM_MIN_TB:-?}TB"
else
  report_row 1 "节点物理" "系统内存(DDR5)" "N/A" ">= ${SYS_MEM_MIN_TB:-?} TB" SKIP "未采集 free -b"
fi

# 2) 识别率：free 认到的 / dmidecode 已装的。这一项才是抓"掉内存"的，
#    不依赖任何写死的容量 —— 换配置也照样有效。
if is_num "$mem_gib" && is_num "$dmi_installed_gib" && [ "${dmi_installed_gib:-0}" -gt 0 ]; then
  detect_pct="$(awk -v a="$mem_gib" -v b="$dmi_installed_gib" 'BEGIN{printf "%.1f", a/b*100}')"
  report_ge 1 "节点物理" "内存识别率" "$detect_pct" "$SYS_MEM_DETECT_MIN_PCT" "%" \
    "free 认到 ${mem_gib} GiB / dmidecode 已装 ${dmi_installed_gib} GiB；低于阈值说明有内存条未被识别或已被 BIOS 屏蔽"
else
  report_row 1 "节点物理" "内存识别率" "N/A" ">= ${SYS_MEM_DETECT_MIN_PCT:-?} %" SKIP \
    "需要 dmidecode（root）才能拿到已装容量"
fi

# 3) 内存条一致性：容量或频率不一致 = 混插/降频，容量检查看不出来
if [ "${dmi_populated:-0}" -gt 0 ]; then
  if [ "${n_size:-0}" -le 1 ] && [ "${n_speed:-0}" -le 1 ]; then
    report_row 1 "节点物理" "内存条一致性" \
      "${dmi_populated}/${dmi_slots} 槽已装，全部 ${dmi_sizes:-?} @ ${dmi_speeds:-?}" \
      "容量与频率一致" PASS
  else
    report_row 1 "节点物理" "内存条一致性" \
      "${dmi_populated}/${dmi_slots} 槽已装，容量 ${dmi_sizes:-?}，频率 ${dmi_speeds:-?}" \
      "容量与频率一致" FAIL "存在混插或降频，容量检查看不出来"
  fi
else
  report_row 1 "节点物理" "内存条一致性" "N/A" "容量与频率一致" SKIP "需要 dmidecode（root）"
fi

# 4) 系统内存压测（标准未要求，本项目补充）
if cap_exists mem_stress; then
  mem_tool="$(cat "$LOG_DIR/mem_stress_tool.txt" 2>/dev/null || echo "?")"
  mem_rc="$(cap_exit mem_stress)"
  # stressapptest 以 "Status: PASS"/"Status: FAIL" 收尾；memtester 用 "FAILURE"
  # stressapptest 收尾会打 "Found N hardware incidents" —— 要取那个 N，
  # 不能去数匹配的行数（"Found 0 hardware incidents" 也匹配，会算成 1 处错误）。
  hw_err="$(cap mem_stress | grep -oE 'Found [0-9]+ hardware incidents' | grep -oE '[0-9]+' | tail -n1)"
  hw_err="${hw_err:-0}"
  miscmp="$(cap mem_stress | grep -ci 'miscompare' || true)"
  status_pass=0
  if [ "$mem_tool" = "memtester" ]; then
    [ "$mem_rc" = "0" ] && ! cap mem_stress | grep -qi 'FAILURE' && status_pass=1
  else
    cap mem_stress | grep -qi 'Status: *PASS' && status_pass=1
  fi
  if [ "$status_pass" = "1" ] && [ "${hw_err:-0}" -eq 0 ] && [ "${miscmp:-0}" -eq 0 ]; then
    report_row 1 "节点物理" "内存压力测试" \
      "${mem_tool} ${SYS_MEM_STRESS_SECONDS}s，Status PASS，硬件错误 ${hw_err} 处，miscompare ${miscmp} 处" \
      "无 miscompare / 无硬件错误" PASS
  else
    report_row 1 "节点物理" "内存压力测试" \
      "${mem_tool}，exit=${mem_rc}，硬件错误 ${hw_err} 处，miscompare ${miscmp} 处" \
      "无 miscompare / 无硬件错误" FAIL "见 mem_stress.txt"
  fi
else
  report_row 1 "节点物理" "内存压力测试" "未执行" "无 miscompare / 无硬件错误" SKIP \
    "stressapptest/memtester 未安装或 SYS_MEM_STRESS_SECONDS=0"
fi

if cap_exists ipmi_fan && ! grep -q 'not found' "$LOG_DIR/ipmi_fan.txt"; then
  # ipmitool sensor list 列序：名称 | 读数 | 单位 | 状态 | 各级阈值...
  fan_total="$(cap ipmi_fan | grep -c .)"
  fan_bad="$(cap ipmi_fan | awk -F'|' 'NF>=4 {gsub(/ /,"",$4); if($4!="" && $4!="ok" && $4!="na") n++} END{print n+0}')"
  fan_rpm="$(cap ipmi_fan | awk -F'|' 'NF>=2 {gsub(/ /,"",$2); if($2 ~ /^[0-9.]+$/) print $2+0}' | range_of)"
  if [ "$fan_bad" -eq 0 ]; then
    report_row 1 "散热" "风扇状态" "${fan_total} 个，转速 ${fan_rpm:-?} RPM，异常 0" \
      "全部正常，无告警" PASS
  else
    report_row 1 "散热" "风扇状态" "${fan_total} 个，转速 ${fan_rpm:-?} RPM，异常 ${fan_bad}" \
      "全部正常，无告警" FAIL "见 ipmi_fan.txt / ipmi_sel.txt"
  fi
else
  report_row 1 "散热" "风扇状态" "N/A" "全部正常，无告警" SKIP "ipmitool 未安装（见 docs/tooling_gaps.md）"
fi

# ========================================================== §2 基础配置规格
# 标准第 2 章是"规格核对"。给了采购清单就逐项自动比对，没给就照旧标人工核对 ——
# 不能因为没清单就把这几项判成通过。
cpu_model="$(cap lscpu | awk -F': *' '/Model name/{print $2; exit}')"
cpu_sockets="$(cap lscpu | awk -F': *' '/^Socket\(s\)/{gsub(/ /,"",$2); print $2; exit}')"
sysdisk="$(cap lsblk | awk '$3=="disk"{print $1"("$2")"}' | tr '\n' ' ')"
nvme_n="$(cap nvme_list | grep -c '^/dev/nvme')"
# nvme list 的容量列在不同 nvme-cli 版本里位置不一，按 "数字 + TB/GB" 抓，统一折算成 TB
nvme_tb="$(cap nvme_list | grep -oE '[0-9]+\.?[0-9]* *(TB|GB)' | head -n1 \
           | awk '{v=$1+0; if($2=="GB") v=v/1000; if(v>0) printf "%.2f", v}')"
sys_brand="$(cap dmidecode_system | awk -F': *' '/^[[:space:]]*Manufacturer/{print $2; exit}')"
mem_type="$(dmi_mem | awk -F': *' '/^[[:space:]]*Type: /{if($2!="Unknown" && $2!="Other"){print $2; exit}}')"
mem_one_gb="$(printf '%s' "${dmi_sizes:-}" | grep -oE '^[0-9]+' | head -n1)"
mem_speed_n="$(printf '%s' "${dmi_speeds:-}" | grep -oE '^[0-9]+' | head -n1)"
gpu_name="$(cap nvidia_smi_L | sed -n '1s/.*: \(.*\) (UUID.*/\1/p')"
[ -z "$gpu_name" ] && gpu_name="$(colN q_overview 2 | sed -n '2p')"

PURCHASE_LIST="${PURCHASE_LIST:-$BASE_DIR/inventory/purchase_list.csv}"
HOST_SN="$(sed -n 's/^Host SN: //p' "$LOG_DIR/session.txt" 2>/dev/null)"
declare -A PL=()
pl_rows=0
if [ -f "$PURCHASE_LIST" ]; then
  while IFS=$'\t' read -r k v; do
    [ -n "$k" ] && { PL["$k"]="$v"; pl_rows=$((pl_rows + 1)); }
  done < <(csv_row_for "$PURCHASE_LIST" "${HOST_SN:-__none__}")
fi

# 文本类：忽略 (R)/(TM)/空格标点后互相包含即匹配
spec_text() { # <项名> <实测> <清单列名> [期望展示后缀]
  local item="$1" measured="$2" col="$3" want="${PL[$3]:-}"
  if [ -z "$want" ]; then
    report_row 2 "基础规格" "$item" "${measured:-N/A}" "对照采购清单" MANUAL \
      "$( [ "$pl_rows" -gt 0 ] && echo "采购清单未填该列" || echo "未提供采购清单（见 templates/purchase_list_template.csv）")"
  elif model_match "$measured" "$want"; then
    report_row 2 "基础规格" "$item" "${measured:-N/A}" "$want" PASS "对照采购清单"
  else
    report_row 2 "基础规格" "$item" "${measured:-N/A}" "$want" FAIL "与采购清单不符"
  fi
}
# 数值类：tol 为允许的相对偏差（0 = 必须相等）
spec_num() { # <项名> <实测> <清单列名> <单位> <tol>
  local item="$1" measured="$2" col="$3" unit="$4" tol="$5" want="${PL[$3]:-}"
  if [ -z "$want" ]; then
    report_row 2 "基础规格" "$item" "${measured:-N/A} $unit" "对照采购清单" MANUAL \
      "$( [ "$pl_rows" -gt 0 ] && echo "采购清单未填该列" || echo "未提供采购清单")"
  elif ! is_num "$measured"; then
    report_row 2 "基础规格" "$item" "N/A" "$want $unit" SKIP "未能从采集结果解析出实测值"
  elif awk -v a="$measured" -v b="$want" -v t="$tol" \
         'BEGIN{d=a-b; if(d<0)d=-d; exit !(d <= b*t + 1e-9)}'; then
    report_row 2 "基础规格" "$item" "$measured $unit" "$want $unit" PASS "对照采购清单"
  else
    report_row 2 "基础规格" "$item" "$measured $unit" "$want $unit" FAIL "与采购清单不符"
  fi
}

if [ "$pl_rows" -gt 0 ]; then
  report_row 2 "基础规格" "采购清单" "已加载 ${pl_rows} 项（SN=${HOST_SN:-未知}）" \
    "$(basename "$PURCHASE_LIST")" PASS "以下 §2 各项按清单自动核对"
else
  report_row 2 "基础规格" "采购清单" "未提供" "inventory/purchase_list.csv" MANUAL \
    "填了清单后 §2 可自动核对，模板见 templates/purchase_list_template.csv"
fi

spec_text "品牌一致性"     "${sys_brand:-}"   "品牌"
spec_text "CPU 型号"       "${cpu_model:-}"   "CPU型号"
spec_num  "CPU 路数"       "${cpu_sockets:-}" "CPU路数"    "路"  0
spec_num  "内存条数"       "${dmi_populated:-}" "内存条数" "条"  0
spec_num  "内存单条容量"   "${mem_one_gb:-}"  "内存单条GB" "GB" 0
spec_num  "内存总容量"     "${dmi_installed_gib:-}" "内存总GB" "GiB" 0.02
spec_text "内存类型"       "${mem_type:-}"    "内存类型"
spec_num  "内存频率"       "${mem_speed_n:-}" "内存频率MTs" "MT/s" 0
spec_num  "本地 NVMe 数量" "${nvme_n:-0}"     "NVMe数量"   "块"  0
spec_num  "NVMe 单盘容量"  "${nvme_tb:-}"     "NVMe单盘TB" "TB"  0.05
spec_text "GPU 型号"       "${gpu_name:-}"    "GPU型号"
spec_num  "GPU 数量(清单)" "${gpu_count:-}"   "GPU数量"    "颗"  0
# 系统盘藏在 RAID 后面，看不到物理盘，只做记录
report_row 2 "基础规格" "系统盘/本地盘" "${sysdisk:-N/A}" "${PL[系统盘描述]:-对照采购清单}" MANUAL \
  "RAID 后面看不到物理盘，需人工核对"

# ========================================================== §3 GPU 硬件验证
mem_min="$(colN_num q_memory_total 2 | num_min)"
mem_range="$(colN_num q_memory_total 2 | range_of)"
report_ge 3 "GPU 显存" "单卡显存" "$mem_min" "$GPU_MEM_MIN_MIB" "MiB" \
  "标称 ${GPU_MEM_NOMINAL_GB}GB HBM3e；全卡实测 ${mem_range:-N/A} MiB，判定取最小值"

mem_sum_gib="$(colN_num q_memory_total 2 | awk '{s+=$1} END{if(NR) printf "%.0f", s/1024}')"
report_ge 3 "GPU 显存" "节点总显存" "$mem_sum_gib" "$NODE_GPU_MEM_MIN_GIB" "GiB" \
  "标准：${EXPECTED_GPU_COUNT} × ${GPU_MEM_NOMINAL_GB}GB"

ecc_mode_na="$(na_count q_ecc_mode 2)"
ecc_mode_ok="$(colN q_ecc_mode 2 | all_equal "$ECC_MODE_EXPECTED")"
if [ "${ecc_mode_na:-0}" -gt 0 ]; then
  report_row 3 "GPU ECC" "ECC 状态确认" "N/A ×${ecc_mode_na}" "全部 GPU ECC = Enabled" SKIP \
    "驱动未报告 ECC 模式（该卡不支持 ECC，或查询失败）"
else
  case "$ecc_mode_ok" in
    YES) report_row 3 "GPU ECC" "ECC 状态确认" "$(count_eq q_ecc_mode 2 "$ECC_MODE_EXPECTED") $ECC_MODE_EXPECTED" \
           "全部 GPU ECC = Enabled" PASS ;;
    NO)  report_row 3 "GPU ECC" "ECC 状态确认" \
           "$(count_eq q_ecc_mode 2 "$ECC_MODE_EXPECTED") $ECC_MODE_EXPECTED（实测: $(colN q_ecc_mode 2 | sort -u | tr '\n' ' '))" \
           "全部 GPU ECC = Enabled" FAIL ;;
    *)   report_row 3 "GPU ECC" "ECC 状态确认" "N/A" "全部 GPU ECC = Enabled" SKIP "未采集" ;;
  esac
fi

# ECC 计数为 N/A 时必须判 SKIP。"没有数据"和"计数为 0"是两回事，
# 后者会让一台根本没在报 ECC 的机器拿到 PASS。
ecc_unc_na="$(na_count q_ecc_uncorrected 2)"
if [ "${ecc_unc_na:-0}" -gt 0 ]; then
  report_row 3 "GPU ECC" "不可纠正错误" "N/A ×${ecc_unc_na}" "= $ECC_UNCORRECTED_MAX" SKIP \
    "驱动未报告 ECC 计数，不能据此判 PASS"
else
  report_le 3 "GPU ECC" "不可纠正错误" "$(colN_num q_ecc_uncorrected 2 | num_max)" \
    "$ECC_UNCORRECTED_MAX" "个" \
    "单卡最大值；全节点合计 $(colN_num q_ecc_uncorrected 2 | awk '{s+=$1} END{print s+0}') 个"
fi

ecc_cor_na="$(na_count q_ecc_corrected 2)"
if [ "${ecc_cor_na:-0}" -gt 0 ]; then
  report_row 3 "GPU ECC" "可纠正错误" "N/A ×${ecc_cor_na}" "<= $ECC_CORRECTED_MAX" SKIP \
    "驱动未报告 ECC 计数，不能据此判 PASS"
else
  report_le 3 "GPU ECC" "可纠正错误" "$(colN_num q_ecc_corrected 2 | num_max)" \
    "$ECC_CORRECTED_MAX" "个" \
    "单卡最大值；全节点合计 $(colN_num q_ecc_corrected 2 | awk '{s+=$1} END{print s+0}') 个。标准口径为压测窗口内增量，见 §8"
fi

pl_min="$(colN_num q_power_limit 2 | num_min)"
pl_max="$(colN_num q_power_limit 2 | num_max)"
if is_num "$pl_min" && num_eq_tol "$pl_min" "$GPU_POWER_LIMIT_W" "$GPU_POWER_LIMIT_TOL_W" \
   && num_eq_tol "$pl_max" "$GPU_POWER_LIMIT_W" "$GPU_POWER_LIMIT_TOL_W"; then
  report_row 3 "GPU 功耗" "TDP" "${pl_min}~${pl_max} W" "每卡 ${GPU_POWER_LIMIT_W} W" PASS
elif is_num "$pl_min"; then
  report_row 3 "GPU 功耗" "TDP" "${pl_min}~${pl_max} W" "每卡 ${GPU_POWER_LIMIT_W} W" FAIL
else
  report_row 3 "GPU 功耗" "TDP" "N/A" "每卡 ${GPU_POWER_LIMIT_W} W" SKIP "未采集"
fi

# DCGM：不依赖 jq，直接统计 JSON 里的 status 取值
# 「主动跳过」和「工具缺失」性质完全不同：前者是流程决定，后者是打包缺口
# 需要回制盘机补。混成一句 "未运行或 dcgmi 缺失" 等于把责任归属也一起模糊掉。
skip_reason() { # <默认说明>
  if [ -f "$LOG_DIR/dcgm_skipped.txt" ]; then echo "操作员主动跳过（SKIP_DCGM=1）"
  elif [ -f "$LOG_DIR/dcgm_missing.txt" ]; then echo "dcgmi 未安装 —— 打包缺口，见 docs/tooling_gaps.md"
  else echo "$1"; fi
}
check_dcgm() {
  local name="$1" label="$2"
  if ! cap_exists "$name"; then
    report_row 3 "GPU 诊断" "$label" "未执行" "全部 PASS" SKIP "$(skip_reason "未运行")"
    return
  fi
  local rc fails warns passes
  rc="$(cap_exit "$name")"
  fails="$(cap "$name" | grep -oE '"status"[[:space:]]*:[[:space:]]*"Fail"' | wc -l)"
  warns="$(cap "$name" | grep -oE '"status"[[:space:]]*:[[:space:]]*"Warn"' | wc -l)"
  passes="$(cap "$name" | grep -oE '"status"[[:space:]]*:[[:space:]]*"Pass"' | wc -l)"
  if [ "$fails" -gt 0 ]; then
    report_row 3 "GPU 诊断" "$label" "Fail=$fails Warn=$warns Pass=$passes" "全部 PASS" FAIL
  elif [ "$passes" -eq 0 ]; then
    report_row 3 "GPU 诊断" "$label" "无 Pass 记录, exit=$rc" "全部 PASS" FAIL \
      "DCGM 未真正执行测试（常见于 DCGM 版本不支持本机 GPU）"
  elif [ "$warns" -gt 0 ]; then
    report_row 3 "GPU 诊断" "$label" "Warn=$warns Pass=$passes" "全部 PASS" MANUAL "有告警，需人工确认"
  else
    report_row 3 "GPU 诊断" "$label" "Pass=$passes, exit=$rc" "全部 PASS" PASS
  fi
}
check_dcgm dcgm_diag_r3 "DCGM Level 3"
# DCGM r4 的 Memtest 是 GPU 显存(HBM)的压测；系统内存(DDR5)压测在 §1，两者不互相替代。
check_dcgm dcgm_diag_r4 "DCGM Level 4（含 Memtest/EUD）"

# gpu_burn 1 小时
if cap_exists gpu_burn_1h; then
  burn_rc="$(cap_exit gpu_burn_1h)"
  faulty="$(cap gpu_burn_1h | grep -ci 'faulty')"
  if [ "$burn_rc" = "0" ] && [ "$faulty" -eq 0 ]; then
    burn_ok="$(cap gpu_burn_1h | grep -cE 'GPU [0-9]+: *OK' || true)"
    report_row 3 "GPU 压力" "1 小时压测" \
      "${GPU_BURN_SHORT_SECONDS}s，${burn_ok:-0}/${EXPECTED_GPU_COUNT} OK，FAULTY=0，exit=0" \
      "全部 PASS，无 XID，无 Uncorrectable ECC" PASS
  else
    report_row 3 "GPU 压力" "1 小时压测" "exit=$burn_rc, FAULTY=$faulty" "全部 PASS" FAIL
  fi
  # 压测前后的 ECC 增量。标准是"单卡 ≤ 2"，所以按 GPU index 配对求差，取最大值，
  # 不能把 8 张卡的增量加起来比。
  ecc_burn_delta="$(awk -F',' '
      NR==FNR { gsub(/ /,"",$1); gsub(/ /,"",$2); b[$1]=$2+0; next }
      { gsub(/ /,"",$1); gsub(/ /,"",$2); d=($2+0)-b[$1]; if(d>m) m=d }
      END { print m+0 }' \
      "$LOG_DIR/ecc_before_burn.txt" "$LOG_DIR/ecc_after_burn.txt" 2>/dev/null)"
  report_le 3 "GPU 压力" "压测 ECC 增量" "${ecc_burn_delta:-}" "$ECC_CORRECTED_MAX" "个" "单卡可纠正错误增量最大值"
  tmax="$(colN_num temp_after_burn 2 | num_max)"
  report_le 1 "散热" "GPU 温度(压测期间)" "$tmax" "$GPU_TEMP_MAX_C" "°C" "gpu_burn 结束时刻采样；连续采样见 §8"
else
  if [ -f "$LOG_DIR/gpu_burn_skipped.txt" ]; then
    burn_why="操作员主动跳过（SKIP_GPU_BURN=1）"
  elif [ -f "$LOG_DIR/gpu_burn_missing.txt" ]; then
    burn_why="gpu_burn 未安装 —— 打包缺口，见 docs/tooling_gaps.md"
  else
    burn_why="未执行"
  fi
  report_row 3 "GPU 压力" "1 小时压测" "未执行" "全部 PASS" SKIP "$burn_why"
fi

pm_ok="$(colN q_persistence_after 2 | all_equal "Enabled")"
[ "$pm_ok" = "EMPTY" ] && pm_ok="$(colN q_persistence 2 | all_equal "Enabled")"
case "$pm_ok" in
  YES) report_row 3 "GPU 持久模式" "Persistence Mode" "$(count_eq q_persistence_after 2 Enabled) Enabled" "全部 Enabled" PASS ;;
  NO)  report_row 3 "GPU 持久模式" "Persistence Mode" "$(count_eq q_persistence_after 2 Enabled) Enabled" "全部 Enabled" FAIL ;;
  *)   report_row 3 "GPU 持久模式" "Persistence Mode" "N/A" "全部 Enabled" SKIP ;;
esac

clk_range="$(colN_num q_clocks 2 | range_of)"
clk_cur="$(colN_num q_clocks 2 | num_min)"
clk_max="$(colN_num q_clocks 3 | num_max)"
clk_pct=""
if is_num "$clk_cur" && is_num "$clk_max"; then
  clk_pct="$(awk -v a="$clk_cur" -v b="$clk_max" 'BEGIN{if(b>0) printf "%.0f%%", a/b*100}')"
fi
report_row 3 "GPU 时钟" "满载时钟" "${clk_range:-N/A} MHz（Boost ${clk_max:-?} MHz 的 ${clk_pct:-?}）" \
  "运行在 Boost Clock，无 Throttle" MANUAL "空闲采样会偏低；以 §8 连续采样为准"

# Throttle：nvidia-smi -q -d PERFORMANCE 里的具名布尔
if cap_exists perf_state; then
  thr="$(cap perf_state | grep -E 'HW Slowdown|HW Thermal Slowdown|SW Thermal Slowdown|HW Power Brake Slowdown' \
        | grep -ci ': *Active')"
  thr_total="$(cap perf_state | grep -cE 'HW Slowdown|HW Thermal Slowdown|SW Thermal Slowdown|HW Power Brake Slowdown' || true)"
  if [ "$thr" -eq 0 ]; then
    report_row 3 "GPU 节流" "节流原因" "0/${thr_total:-0} 项 Active" \
      "无 HW Slowdown、无 Thermal Throttle" PASS
  else
    report_row 3 "GPU 节流" "节流原因" "${thr}/${thr_total:-0} 项 Active" \
      "无 HW Slowdown、无 Thermal Throttle" FAIL "见 perf_state.txt"
  fi
else
  report_row 3 "GPU 节流" "节流原因" "N/A" "无 HW Slowdown、无 Thermal Throttle" SKIP
fi

# PCIe：空闲时链路会降速，判定用 max（链路能力），current 作为备注
pcie_gen_max="$(colN_num q_pcie 3 | num_min)"
pcie_w_max="$(colN_num q_pcie 5 | num_min)"
pcie_gen_cur="$(colN_num q_pcie 2 | num_min)"
pcie_w_cur="$(colN_num q_pcie 4 | num_min)"
if is_num "$pcie_gen_max"; then
  if num_ge "$pcie_gen_max" "$PCIE_GEN" && num_ge "$pcie_w_max" "$PCIE_WIDTH"; then
    report_row 3 "PCIe" "PCIe Gen/Width" "max=Gen${pcie_gen_max%.*} x${pcie_w_max%.*} (current Gen${pcie_gen_cur%.*} x${pcie_w_cur%.*})" \
      "Gen${PCIE_GEN} x${PCIE_WIDTH}" PASS "current 低于 max 属空闲降速，正常"
  else
    report_row 3 "PCIe" "PCIe Gen/Width" "max=Gen${pcie_gen_max%.*} x${pcie_w_max%.*}" \
      "Gen${PCIE_GEN} x${PCIE_WIDTH}" FAIL "链路能力不足，非空闲降速"
  fi
else
  report_row 3 "PCIe" "PCIe Gen/Width" "N/A" "Gen${PCIE_GEN} x${PCIE_WIDTH}" SKIP
fi

h2d_min=""; d2h_min=""
cap_exists nvb_h2d && h2d_min="$(matrix_float_all "$LOG_DIR/nvb_h2d.txt" | num_min)"
cap_exists nvb_d2h && d2h_min="$(matrix_float_all "$LOG_DIR/nvb_d2h.txt" | num_min)"
report_ge 3 "PCIe 带宽" "H2D 带宽" "$h2d_min" "$NVB_H2D_MIN_GBS" "GB/s" "取矩阵最小值"
report_ge 3 "PCIe 带宽" "D2H 带宽" "$d2h_min" "$NVB_D2H_MIN_GBS" "GB/s" "取矩阵最小值"

# =============================================== §4 NVLink（节点内 / Rank 内）
d2d_min=""
cap_exists nvb_d2d && d2d_min="$(matrix_float_offdiag "$LOG_DIR/nvb_d2d.txt" | num_min)"
report_ge 4 "NVLink P2P" "GPU 间带宽" "$d2d_min" "$NVB_D2D_READ_MIN_GBS" "GB/s" "任意 GPU 对，单向，取最小值"

if cap_exists nvidia_smi_topo; then
  # GPU 行里的 GPU-GPU 单元格：非 NV* 或 != NV18 的都算不合格
  bad_topo="$(cap nvidia_smi_topo | awk '/^GPU[0-9]+/{
      for(i=2;i<=NF;i++){ if($i ~ /^(X|NV[0-9]+)$/){ if($i!="X" && $i!=TAG) n++ } }
    } END{print n+0}' TAG="$NVLINK_TOPO_TAG")"
  topo_total="$(cap nvidia_smi_topo | awk '/^GPU[0-9]+/{for(i=2;i<=NF;i++) if($i ~ /^NV[0-9]+$/) n++} END{print n+0}')"
  if [ "$bad_topo" -eq 0 ]; then
    report_row 4 "NVLink 拓扑" "拓扑验证" "${topo_total}/${topo_total} 个 GPU 对为 $NVLINK_TOPO_TAG" \
      "${EXPECTED_GPU_COUNT} GPU 全互联 $NVLINK_TOPO_TAG" PASS
  else
    report_row 4 "NVLink 拓扑" "拓扑验证" \
      "$((topo_total - bad_topo))/${topo_total} 个 GPU 对为 $NVLINK_TOPO_TAG，${bad_topo} 个降链" \
      "${EXPECTED_GPU_COUNT} GPU 全互联 $NVLINK_TOPO_TAG" FAIL "见 nvidia_smi_topo.txt"
  fi
else
  report_row 4 "NVLink 拓扑" "拓扑验证" "N/A" "全互联 $NVLINK_TOPO_TAG" SKIP
fi

if cap_exists nvlink_status; then
  active_links="$(cap nvlink_status | grep -cE '^[[:space:]]*Link [0-9]+:.*GB/s')"
  inactive="$(cap nvlink_status | grep -ciE 'inactive|degraded')"
  want=$((NVLINK_LINKS_PER_GPU * EXPECTED_GPU_COUNT))
  if [ "$active_links" -eq "$want" ] && [ "$inactive" -eq 0 ]; then
    report_row 4 "NVLink 状态" "链路检查" "${active_links} 条活跃，0 Inactive/Degraded" \
      "每卡 ${NVLINK_LINKS_PER_GPU} 条，共 ${want} 条" PASS
  else
    report_row 4 "NVLink 状态" "链路检查" "${active_links} 条活跃，${inactive} 条 Inactive/Degraded" \
      "每卡 ${NVLINK_LINKS_PER_GPU} 条，共 ${want} 条" FAIL
  fi
else
  report_row 4 "NVLink 状态" "链路检查" "N/A" "每卡 ${NVLINK_LINKS_PER_GPU} 条活跃" SKIP
fi

if cap_exists nvlink_errors; then
  err_max="$(cap nvlink_errors | awk -F: '/[Ee]rror|[Rr]eplay|CRC/{gsub(/[^0-9]/,"",$NF); if($NF!="") print $NF+0}' | num_max)"
  report_le 4 "NVLink 错误" "CRC / Replay" "${err_max:-0}" "$NVLINK_ERR_MAX" "个" "全部链路最大值"
else
  report_row 4 "NVLink 错误" "CRC / Replay" "N/A" "= $NVLINK_ERR_MAX" SKIP
fi

if cap_exists p2p_bw_lat; then
  matrix_block "$LOG_DIR/p2p_bw_lat.txt" "P2P Connectivity Matrix" > "$TMP/p2p_conn"
  matrix_block "$LOG_DIR/p2p_bw_lat.txt" "Unidirectional P2P=Enabled Bandwidth Matrix" > "$TMP/p2p_bw"
  matrix_block "$LOG_DIR/p2p_bw_lat.txt" "P2P=Enabled Latency Matrix" > "$TMP/p2p_lat"

  # 数值比较，不要拿 num_min 的输出做字符串比对 —— 它会按值决定输出
  # "1" 还是 "1.00"，字符串比对会随格式化方式静默失效。
  conn_min="$(matrix_int_offdiag "$TMP/p2p_conn" | num_min)"
  conn_tot="$(matrix_int_offdiag "$TMP/p2p_conn" | grep -c . || true)"
  conn_yes="$(matrix_int_offdiag "$TMP/p2p_conn" | grep -c '^1$' || true)"
  if is_num "$conn_min" && num_ge "$conn_min" 1; then
    report_row 4 "P2P 带宽矩阵" "P2P Access" "${conn_yes}/${conn_tot} 对可达" \
      "${EXPECTED_GPU_COUNT}x${EXPECTED_GPU_COUNT} 全部 Yes" PASS
  else
    report_row 4 "P2P 带宽矩阵" "P2P Access" "${conn_yes}/${conn_tot} 对可达" "全部 Yes" FAIL
  fi
  report_ge 4 "P2P 带宽矩阵" "单向 P2P 带宽" "$(matrix_float_offdiag "$TMP/p2p_bw" | num_min)" \
    "$P2P_BW_MIN_GBS" "GB/s" "取非对角最小值"
  report_le 4 "P2P 延迟" "GPU 间 P2P 延迟" "$(matrix_float_offdiag "$TMP/p2p_lat" | num_max)" \
    "$P2P_LAT_MAX_US" "us" "取非对角最大值"
else
  report_row 4 "P2P 带宽矩阵" "全 GPU 对 P2P 带宽" "N/A" ">= $P2P_BW_MIN_GBS GB/s" SKIP "p2pBandwidthLatencyTest 未运行"
  report_row 4 "P2P 延迟" "GPU 间 P2P 延迟" "N/A" "<= $P2P_LAT_MAX_US us" SKIP
fi

# nccl-tests：数据行末尾固定是 "... time algbw busbw #wrong"，故 busbw = 倒数第二列
nccl_busbw_peak() {
  cap "$1" | awk '/^[[:space:]]*[0-9]+[[:space:]]/ && NF>=8 {
      v=$(NF-1); if(v ~ /^[0-9.]+$/ && v+0>m) m=v+0 } END{ if(m) printf "%.2f", m }'
}
nccl_busbw_avg() { cap "$1" | awk -F: '/Avg bus bandwidth/{gsub(/ /,"",$2); print $2}'; }

if cap_exists nccl_all_reduce; then
  report_ge 4 "NCCL 节点内" "${EXPECTED_GPU_COUNT} GPU AllReduce" "$(nccl_busbw_peak nccl_all_reduce)" \
    "$NCCL_ALLREDUCE_MIN_GBS" "GB/s" "峰值 Bus BW；均值=$(nccl_busbw_avg nccl_all_reduce)"
else
  report_row 4 "NCCL 节点内" "${EXPECTED_GPU_COUNT} GPU AllReduce" "N/A" ">= $NCCL_ALLREDUCE_MIN_GBS GB/s" SKIP
fi
if cap_exists nccl_all_gather; then
  report_ge 4 "NCCL 节点内" "${EXPECTED_GPU_COUNT} GPU AllGather" "$(nccl_busbw_peak nccl_all_gather)" \
    "$NCCL_ALLGATHER_MIN_GBS" "GB/s" "峰值 Bus BW；均值=$(nccl_busbw_avg nccl_all_gather)"
else
  report_row 4 "NCCL 节点内" "${EXPECTED_GPU_COUNT} GPU AllGather" "N/A" ">= $NCCL_ALLGATHER_MIN_GBS GB/s" SKIP
fi

fm_active="$(cap fm_is_active | tr -d ' \n')"
fm_err="$(cap fm_journal | grep -ciE '\berror\b' || true)"
if [ "$fm_active" = "active" ] && [ "${fm_err:-0}" -eq 0 ]; then
  report_row 4 "Fabric Manager" "FM 状态" "active，日志 Error 0 条（共 $(cap fm_journal | grep -c . || true) 行）" \
    "Active (running)，日志无 Error" PASS
elif [ -n "$fm_active" ]; then
  report_row 4 "Fabric Manager" "FM 状态" "$fm_active，Error=${fm_err:-?}" "Active (running)，日志无 Error" FAIL
else
  report_row 4 "Fabric Manager" "FM 状态" "N/A" "Active (running)" SKIP
fi

# ============================================================ §7 GPU 软件栈
drv_list="$(colN q_driver 2 | sort -u)"
drv_one="$(printf '%s' "$drv_list" | head -n1)"
drv_n="$(printf '%s\n' "$drv_list" | grep -c .)"
if [ -z "$drv_one" ]; then
  report_row 7 "驱动" "版本" "N/A" ">= $DRIVER_MIN_VERSION 且全集群一致" SKIP
elif [ "$drv_n" -ne 1 ]; then
  report_row 7 "驱动" "版本" "$(printf '%s' "$drv_list" | tr '\n' ' ')" ">= $DRIVER_MIN_VERSION 且一致" FAIL "节点内驱动版本不一致"
elif ver_ge "$drv_one" "$DRIVER_MIN_VERSION"; then
  report_row 7 "驱动" "版本" "$drv_one" ">= $DRIVER_MIN_VERSION" PASS "跨节点一致性需在集群阶段核对"
else
  report_row 7 "驱动" "版本" "$drv_one" ">= $DRIVER_MIN_VERSION" FAIL
fi

cuda_ver="$(cap nvcc_version | grep -oE 'release [0-9]+\.[0-9]+' | head -n1 | awk '{print $2}')"
if [ -z "$cuda_ver" ]; then
  report_row 7 "CUDA" "版本" "N/A（nvcc 未安装）" ">= $CUDA_MIN_VERSION" SKIP "只装 runtime 时无 nvcc"
elif ver_ge "$cuda_ver" "$CUDA_MIN_VERSION"; then
  report_row 7 "CUDA" "版本" "$cuda_ver" ">= $CUDA_MIN_VERSION" PASS
else
  report_row 7 "CUDA" "版本" "$cuda_ver" ">= $CUDA_MIN_VERSION" FAIL "需整体升级工具链并按 CUDA_ARCH_LIST 重编"
fi

if [ "${REQUIRE_NVIDIA_PEERMEM:-1}" = "1" ]; then
  if cap lsmod_peermem | grep -q peermem; then
    report_row 7 "nvidia_peermem" "模块" "已加载（$(cap lsmod_peermem | awk '{print $1" "$2" bytes"; exit}')）" "已加载" PASS
  else
    report_row 7 "nvidia_peermem" "模块" "未加载" "已加载" FAIL "GPUDirect RDMA 依赖该模块"
  fi
fi

fm_ver="$(cap fm_version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)"
if [ -n "$fm_ver" ] && [ -n "$drv_one" ]; then
  if [ "${fm_ver%%.*}" = "${drv_one%%.*}" ]; then
    report_row 7 "Fabric Manager" "FM 版本与状态" "FM $fm_ver / 驱动 $drv_one" "与驱动版本匹配，服务 Active" PASS
  else
    report_row 7 "Fabric Manager" "FM 版本与状态" "FM $fm_ver / 驱动 $drv_one" "与驱动版本匹配" FAIL "主版本不一致"
  fi
else
  report_row 7 "Fabric Manager" "FM 版本与状态" "N/A" "与驱动版本匹配，服务 Active" SKIP
fi

if [ "${REQUIRE_GDRCOPY:-0}" = "1" ]; then
  if cap_exists gdrcopy_sanity; then
    if [ "$(cap_exit gdrcopy_sanity)" = "0" ] && ! cap gdrcopy_sanity | grep -qi 'fail'; then
      report_row 7 "GDRCopy" "GDRCopy 功能" "PASS" "测试 PASS" PASS
    else
      report_row 7 "GDRCopy" "GDRCopy 功能" "exit=$(cap_exit gdrcopy_sanity)" "测试 PASS" FAIL
    fi
  else
    report_row 7 "GDRCopy" "GDRCopy 功能" "N/A" "测试 PASS" SKIP "gdrcopy 未安装（见 docs/tooling_gaps.md）"
  fi
fi

missing_samples="$(cap cuda_samples_present | grep -c 'MISSING')"
if [ "$missing_samples" -eq 0 ] && cap_exists cuda_samples_present; then
  report_row 7 "CUDA Samples" "cuda-samples 工具集" \
    "$(cap cuda_samples_present | grep -cv MISSING || true)/$(cap cuda_samples_present | grep -c . || true) 可用" \
    "p2pBandwidthLatencyTest、bandwidthTest 已编译可用" PASS
else
  report_row 7 "CUDA Samples" "cuda-samples 工具集" "$(cap cuda_samples_present | grep 'MISSING' | tr '\n' ' ')" \
    "p2pBandwidthLatencyTest、bandwidthTest 已编译可用" FAIL "新版 cuda-samples 已删除 bandwidthTest，需单独补"
fi

mp_missing=""
for want in $NVIDIA_MODPROBE_REQUIRED; do
  cap modprobe_conf | grep -q -- "$want" || mp_missing="$mp_missing $want"
done
if [ -z "$mp_missing" ]; then
  mp_total="$(printf '%s\n' $NVIDIA_MODPROBE_REQUIRED | grep -c .)"
  report_row 7 "驱动参数" "NVIDIA 内核模块参数" "${mp_total}/${mp_total} 项已配置" \
    "$NVIDIA_MODPROBE_REQUIRED" PASS
else
  report_row 7 "驱动参数" "NVIDIA 内核模块参数" "缺:$mp_missing" "$NVIDIA_MODPROBE_REQUIRED" FAIL \
    "执行 scripts/set_nvidia_modprobe_params.sh 后重启"
fi

# ==================================== §8 长稳烤机（存在 soak/ 子目录时才判）
SOAK="$LOG_DIR/soak"
if [ -d "$SOAK" ]; then
  soak_rc="$(cat "$SOAK/gpu_burn.exit" 2>/dev/null || echo "")"
  # grep -c 找不到时会「打印 0 且退出码非 0」，写 || echo 0 会得到两行 "0"。
  faulty="$(grep -ci 'faulty' "$SOAK/gpu_burn.txt" 2>/dev/null | head -n1)"
  faulty="${faulty:-0}"
  xid_delta="$(cat "$SOAK/xid_delta.txt" 2>/dev/null || echo "")"
  ecc_delta="$(cat "$SOAK/ecc_corrected_delta.txt" 2>/dev/null || echo "")"
  unc_delta="$(cat "$SOAK/ecc_uncorrected_delta.txt" 2>/dev/null || echo "")"
  crc_delta="$(cat "$SOAK/nvlink_crc_delta.txt" 2>/dev/null || echo "")"
  # 实际时长优先：被中断的长稳如果报计划时长，会把跑了 2 小时的结果
  # 写成 18 小时，这是直接影响验收结论的误报。
  dur="$(cat "$SOAK/duration_actual_seconds.txt" 2>/dev/null \
         || cat "$SOAK/duration_seconds.txt" 2>/dev/null || echo "?")"
  dur_planned="$(cat "$SOAK/duration_planned_seconds.txt" 2>/dev/null \
                 || cat "$SOAK/duration_seconds.txt" 2>/dev/null || echo "?")"

  # 实际时长明显短于计划，说明被中断了 —— 不能按跑完判
  short_run=0
  if is_num "$dur" && is_num "$dur_planned"; then
    awk -v a="$dur" -v p="$dur_planned" 'BEGIN{exit !(a < p*0.98)}' && short_run=1
  fi
  if [ "$short_run" = "1" ]; then
    report_row 8 "长稳烤机" "GPU 满载稳定性" \
      "实际 ${dur}s / 计划 ${dur_planned}s，未跑完" "跑满 ${dur_planned}s 且零掉卡" FAIL \
      "长稳被中断（断电/重启/人工终止），本次不构成有效的稳定性证据，需重跑"
  elif [ "$soak_rc" = "0" ] && [ "$faulty" -eq 0 ]; then
    report_row 8 "长稳烤机" "GPU 满载稳定性" "${dur}s, exit=0, FAULTY=0" "零掉卡" PASS
  else
    report_row 8 "长稳烤机" "GPU 满载稳定性" "${dur}s, exit=${soak_rc:-?}, FAULTY=$faulty" "零掉卡" FAIL
  fi
  report_le 8 "长稳烤机" "XID 增量" "$xid_delta" "$SOAK_XID_MAX" "条"
  report_le 8 "长稳烤机" "可纠正 ECC 增量" "$ecc_delta" "$ECC_CORRECTED_MAX" "个" "单卡最大增量"
  report_le 8 "长稳烤机" "不可纠正 ECC 增量" "$unc_delta" "$ECC_UNCORRECTED_MAX" "个"
  report_le 8 "长稳烤机" "NVLink CRC 增量" "$crc_delta" "$SOAK_NVLINK_CRC_DELTA_MAX" "个"

  if [ -s "$SOAK/samples.csv" ]; then
    # samples.csv: timestamp,index,temperature,power,sm_clock,...
    # samples.csv 第一行是表头。不跳过的话 "index"/"temperature_gpu" 会被当成 0，
    # 每张卡的最小温度都变成 0，波动直接等于峰值 —— 一台完全正常的机器会被判 FAIL。
    peak="$(awk -F',' 'NR>1 && $3+0>0 {gsub(/ /,"",$3); if($3+0>m) m=$3+0}
                       END{if(m) printf "%.0f", m}' "$SOAK/samples.csv")"
    fluct="$(awk -F',' 'NR>1 {
                gsub(/ /,"",$2); gsub(/ /,"",$3);
                if($2 !~ /^[0-9]+$/ || $3 !~ /^[0-9.]+$/) next;
                g=$2+0; v=$3+0;
                if(!(g in mx) || v>mx[g]) mx[g]=v;
                if(!(g in mn) || v<mn[g]) mn[g]=v }
              END{ m=0; for(g in mx){ d=mx[g]-mn[g]; if(d>m) m=d } printf "%.0f", m }' \
              "$SOAK/samples.csv")"
    report_le 8 "长稳烤机" "温度峰值" "$peak" "$GPU_TEMP_MAX_C" "°C"
    report_le 8 "长稳烤机" "温度波动" "$fluct" "$GPU_TEMP_FLUCT_MAX_C" "°C" "单卡窗口内 max-min 的最大值"
  else
    report_row 8 "长稳烤机" "温度峰值/波动" "N/A" "峰值<=${GPU_TEMP_MAX_C}°C，波动<=${GPU_TEMP_FLUCT_MAX_C}°C" SKIP
  fi
else
  report_row 8 "长稳烤机" "GPU 满载稳定性" "未执行" "零掉卡/ECC/XID/NVLink CRC 增量" SKIP \
    "执行 scripts/soak_node.sh 后重跑本脚本"
fi

# ==================================================== 采集条件本身是否可信
# 非 root 采集会让一堆项静默变成 SKIP。这一行把"证据不完整"本身摆到表里，
# 而不是让人从一堆 SKIP 里自己推断。
if [ -f "$LOG_DIR/WARNING_NOT_ROOT.txt" ]; then
  report_row 0 "采集条件" "采集权限" "非 root（uid 见 WARNING_NOT_ROOT.txt）" "root" FAIL \
    "dmidecode/ipmitool/dmesg/持久模式均未采到，本次结果不足以作为验收依据，请 sudo 重采"
else
  report_row 0 "采集条件" "采集权限" "root" "root" PASS
fi

# ============================================================ 硬性 FAIL 扫描
xid_hits="$(cap dmesg_gpu_after | grep -ci 'xid' || true)"
fallen="$(cap dmesg_gpu_after | grep -ci 'fallen off' || true)"
if [ "${xid_hits:-0}" -eq 0 ] && [ "${fallen:-0}" -eq 0 ]; then
  report_row 0 "硬性条件" "内核日志 XID / 掉卡" "无" "无 XID，无 fallen off the bus" PASS
else
  report_row 0 "硬性条件" "内核日志 XID / 掉卡" "XID=${xid_hits} fallenOffBus=${fallen}" \
    "无 XID，无 fallen off the bus" FAIL "见 dmesg_gpu_after.txt"
fi

# ==================================================== 每张卡的实测明细
# 判定表给的是"最差的那张卡"，但验收报告要能追溯到具体某张卡的具体数值 ——
# 掉队卡、RMA 证据链、同批次比对都靠这张表。
build_per_gpu_table() {
  local out="$LOG_DIR/per_gpu_detail.tsv"
  local n="${gpu_count:-0}"
  [ "$n" -gt 0 ] || return 0

  # 各 CSV 都是 noheader 且按 index 排序，第 (i+1) 行即 GPU i
  val_at() { colN "$1" "$2" | sed -n "$(( $3 + 1 ))p"; }
  nvlink_links_of() {
    cap nvlink_status | awk -v g="$1" '
      $0 ~ ("^== GPU "g" ==$") {inb=1; next}
      /^== GPU /{inb=0}
      inb && /Link [0-9]+:.*GB\/s/ {n++}
      END{print n+0}'
  }

  {
    printf 'GPU\t型号\tSN\tUUID\tVBIOS\t显存MiB\t功耗上限W\t温度°C\t当前时钟MHz\tPCIe\tNVLink活跃\tECC模式\t可纠正\t不可纠正\t持久模式\n'
    local i
    for i in $(seq 0 $((n - 1))); do
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\tGen%s x%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$i" \
        "$(val_at q_overview 2 "$((i + 1))")" \
        "$(val_at q_overview 4 "$((i + 1))")" \
        "$(val_at q_overview 3 "$((i + 1))")" \
        "$(val_at q_overview 5 "$((i + 1))")" \
        "$(val_at q_memory_total 2 "$i" | awk '{print $1}')" \
        "$(val_at q_power_limit 2 "$i" | awk '{print $1}')" \
        "$(val_at temp_after_burn 2 "$i" | awk '{print $1}')" \
        "$(val_at q_clocks 2 "$i" | awk '{print $1}')" \
        "$(val_at q_pcie 2 "$i")" "$(val_at q_pcie 4 "$i")" \
        "$(nvlink_links_of "$i")" \
        "$(val_at q_ecc_mode 2 "$i")" \
        "$(val_at q_ecc_corrected 2 "$i")" \
        "$(val_at q_ecc_uncorrected 2 "$i")" \
        "$(val_at q_persistence_after 2 "$i")"
    done
  } > "$out"

  # 掉队卡提示：某张卡的关键值明显低于同机中位数，往往是 RMA 的第一个信号
  awk -F'\t' 'NR>1 {
      if($6 ~ /^[0-9]+$/) { mem[NR]=$6+0; g[NR]=$1 }
      if($11 ~ /^[0-9]+$/) { nvl[NR]=$11+0 }
    }
    END{
      # NVLink 活跃链路数不一致 = 有卡掉链
      first=""; bad="";
      for(k in nvl){ if(first=="") first=nvl[k]; else if(nvl[k]!=first) bad=bad" GPU"g[k] }
      if(bad!="") printf "注意：以下 GPU 的 NVLink 活跃链路数与其它卡不一致:%s\n", bad
    }' "$out"
}
per_gpu_note="$(build_per_gpu_table 2>/dev/null || true)"
[ -n "$per_gpu_note" ] && echo "$per_gpu_note"

# ------------------------------------------------------------------ 输出
report_summary || true

# 人读版：验收判定表 + 每卡实测明细
{
  echo "=============================================================================="
  echo " GPU 验收判定表"
  echo "=============================================================================="
  echo " 日志目录 : $(basename "$LOG_DIR")"
  echo " 机型档案 : ${PROFILE_NAME:-?} (${ACC_PROFILE:-?})"
  echo " 主机 SN  : $(grep -oE '^Host SN: .*' "$LOG_DIR/session.txt" 2>/dev/null | cut -d' ' -f3-)"
  echo " 采集时间 : $(grep -oE '^Timestamp: .*' "$LOG_DIR/session.txt" 2>/dev/null | cut -d' ' -f2-) $(sed -n 's/^Timezone: //p' "$LOG_DIR/session.txt" 2>/dev/null)"
  clk="$(sed -n 's/^Clock synced: //p' "$LOG_DIR/session.txt" 2>/dev/null)"
  [ "$clk" = "no" ] && echo " 时钟提醒 : 系统时钟未与 NTP 同步（离线环境常见），时间戳仅供排序参考"
  echo " 生成时间 : $(date '+%F %T')"
  echo
  echo "一、逐项判定（对照《验收标准》§1-§8）"
  echo "------------------------------------------------------------------------------"
  # 按章节排序：采集顺序不等于标准的章节顺序（如温度项在 §3 处理时才拿得到数据）
  { head -n1 "$LOG_DIR/acceptance_report.tsv"; tail -n +2 "$LOG_DIR/acceptance_report.tsv" | sort -s -k1,1n; } \
    | fmt_table
  echo
  if [ -s "$LOG_DIR/per_gpu_detail.tsv" ]; then
    echo "二、每张 GPU 实测明细"
    echo "------------------------------------------------------------------------------"
    fmt_table "$LOG_DIR/per_gpu_detail.tsv"
    [ -n "$per_gpu_note" ] && { echo; echo "$per_gpu_note"; }
    echo
  fi
  echo "三、汇总"
  echo "------------------------------------------------------------------------------"
  cat "$LOG_DIR/acceptance_report.tsv.summary"
  echo
  echo "说明：余量 = 实测相对阈值的百分比裕度，正数为达标裕度，负数为越线幅度；"
  echo "      阈值为 0 的项（ECC/CRC 等）给绝对差值。判定 MANUAL 的项需人工核对。"
} > "$LOG_DIR/acceptance_report.txt"

# 交付用 CSV（Excel 可直接打开）
tsv_to_csv "$LOG_DIR/acceptance_report.tsv" "$LOG_DIR/acceptance_report.csv"

# 交付用 HTML（自包含，可直接发给甲方或打印存 PDF）
{
  echo "机器 SN: $(sed -n 's/^Host SN: //p' "$LOG_DIR/session.txt" 2>/dev/null)"
  echo "机型档案: ${PROFILE_NAME:-?} (${ACC_PROFILE:-?})"
  echo "架构: ${PROFILE_ARCH_NOTE:-?}"
  echo "采集时间: $(sed -n 's/^Timestamp: //p' "$LOG_DIR/session.txt" 2>/dev/null) $(sed -n 's/^Timezone: //p' "$LOG_DIR/session.txt" 2>/dev/null)"
  echo "报告生成: $(date '+%F %T %Z')"
  echo "日志目录: $(basename "$LOG_DIR")"
  clk="$(sed -n 's/^Clock synced: //p' "$LOG_DIR/session.txt" 2>/dev/null)"
  [ "$clk" = "no" ] && echo "时钟提醒: 系统时钟未与 NTP 同步，时间戳仅供排序参考"
} > "$TMP/meta.txt"
write_html_report "$LOG_DIR/acceptance_report.tsv" "$LOG_DIR/acceptance_report.html" \
  "GPU 验收判定表" "$TMP/meta.txt" \
  "$([ -s "$LOG_DIR/per_gpu_detail.tsv" ] && echo "$LOG_DIR/per_gpu_detail.tsv")"
[ -s "$LOG_DIR/per_gpu_detail.tsv" ] && \
  tsv_to_csv "$LOG_DIR/per_gpu_detail.tsv" "$LOG_DIR/per_gpu_detail.csv"

echo
echo "判定表(人读): $LOG_DIR/acceptance_report.txt"
echo "判定表(机读): $LOG_DIR/acceptance_report.tsv"
echo "判定表(Excel): $LOG_DIR/acceptance_report.csv"
echo "判定表(HTML):  $LOG_DIR/acceptance_report.html   ← 可直接发甲方/打印存 PDF"
[ -s "$LOG_DIR/per_gpu_detail.tsv" ] && echo "每卡明细:     $LOG_DIR/per_gpu_detail.tsv"
[ "${ACC_VERDICT:-FAIL}" = "PASS" ]
