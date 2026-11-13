#!/usr/bin/env bash
# 多机判定 —— 解析 roce_check.sh / nccl_scale.sh 的输出，对照《验收标准》§5 §6。
#
#   bash scripts/cluster/check_cluster.sh <log_dir> [profile]
#
# 输出 <log_dir>/cluster_report.tsv / .txt，格式与单机 check_node.sh 一致。

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
. "$BASE_DIR/scripts/lib/common.sh"

PARENT="${1:-}"
if [ -z "$PARENT" ] || [ ! -d "$PARENT" ]; then
  echo "用法: bash scripts/cluster/check_cluster.sh <log_dir> [profile]" >&2
  exit 2
fi
PARENT="$(cd "$PARENT" && pwd)"
load_profile "${2:-${PROFILE:-b300_8gpu}}" || exit 2

# 每个测试项对应的原始命令 —— 与甲方《验收标准》§5/§6 表格的"测试手段/命令"列对应
cmd_of() {
  case "$1" in
    "Ethernet 模式确认")   echo "mlxconfig -d mlx5_X q | grep LINK_TYPE" ;;
    "全端口活跃")          echo "ip link show | grep mlx5" ;;
    "Priority Flow Control") echo "mlnx_qos -i mlx5_X" ;;
    "巨帧")                echo "ip link show mlx5_X | grep mtu" ;;
    "QoS 标记")            echo "mlnx_qos -i mlx5_X" ;;
    "单 NIC 写带宽")       echo "ib_write_bw -d mlx5_X ${ROCE_PERFTEST_ARGS} <peer_ip>" ;;
    "单 NIC 读带宽")       echo "ib_read_bw -d mlx5_X ${ROCE_PERFTEST_ARGS} <peer_ip>" ;;
    "GPUDirect RDMA")      echo "ib_write_bw -d mlx5_X --use_cuda=<gpu> ${ROCE_PERFTEST_ARGS} <peer_ip>" ;;
    "小消息延迟")          echo "ib_send_lat -d mlx5_X -R <peer_ip>" ;;
    "rx_discards"|"PFC 暂停帧比例"|"PFC/丢包检查") \
                           echo "ethtool -S mlx5_X | grep -E 'pfc|pause|discard'" ;;
    "纯 RoCE AllReduce（排除 NVLink）") \
                           echo "NCCL_ALGO=Ring NCCL_CROSS_NIC=1 mpirun -np <N> -N 1 ./all_reduce_perf_mpi -b 512M -e 8G -f 2 -g 1" ;;
    *AllReduce)            echo "mpirun -np <N×8> -N 8 --hostfile hosts ./all_reduce_perf_mpi ${CLUSTER_BENCH_ARGS}" ;;
    *AllGather)            echo "mpirun -np 16 -N 8 --hostfile hosts ./all_gather_perf_mpi ${CLUSTER_BENCH_ARGS}" ;;
    *ReduceScatter)        echo "mpirun -np 16 -N 8 --hostfile hosts ./reduce_scatter_perf_mpi ${CLUSTER_BENCH_ARGS}" ;;
    *AlltoAll)             echo "mpirun -np 16 -N 8 --hostfile hosts ./alltoall_perf_mpi ${CLUSTER_BENCH_ARGS}" ;;
    *SendRecv*)            echo "mpirun -np 16 -N 8 --hostfile hosts ./sendrecv_perf_mpi ${CLUSTER_BENCH_ARGS}" ;;
    *)                     echo "-" ;;
  esac
}

report_init "$PARENT/cluster_report.tsv"

# ============================================================ §5 RoCE v2
LOG_DIR="$PARENT/roce"
export LOG_DIR
if [ ! -d "$LOG_DIR" ]; then
  report_row 5 "RoCE" "全部测试项" "未执行" "见《验收标准》§5" SKIP "先跑 scripts/cluster/roce_check.sh"
else
  # 网卡模式：LINK_TYPE 应为 2 (Ethernet)
  lt_files="$(ls "$LOG_DIR"/mlxconfig_*.txt 2>/dev/null || true)"
  if [ -n "$lt_files" ]; then
    # 注意：grep -c 带多个文件会每个文件输出一行计数，-h 也不抑制，
    # 结果是 "1\n1" 而不是 "2"。必须先 cat 成单一输入流再计数。
    total="$(cat $lt_files 2>/dev/null | grep -ci 'LINK_TYPE' || true)"
    bad="$(cat $lt_files 2>/dev/null | grep -i 'LINK_TYPE' | grep -vci "ETH($ROCE_LINK_TYPE)" || true)"
    if [ "${total:-0}" -eq 0 ]; then
      report_row 5 "网卡模式" "Ethernet 模式确认" "输出中无 LINK_TYPE" "LINK_TYPE = $ROCE_LINK_TYPE" SKIP \
        "mlxconfig 有输出但没解析到 LINK_TYPE"
    elif [ "${bad:-0}" -eq 0 ]; then
      report_row 5 "网卡模式" "Ethernet 模式确认" "${total} 个端口 ETH($ROCE_LINK_TYPE)" "LINK_TYPE = $ROCE_LINK_TYPE" PASS
    else
      report_row 5 "网卡模式" "Ethernet 模式确认" "异常 ${bad}/${total}" "LINK_TYPE = $ROCE_LINK_TYPE" FAIL
    fi
  else
    report_row 5 "网卡模式" "Ethernet 模式确认" "N/A" "LINK_TYPE = $ROCE_LINK_TYPE" SKIP "mlxconfig 未安装"
  fi

  # 端口状态
  if cap_exists ip_link; then
    down="$(cap ip_link | grep -cv 'UP' || true)"
    up="$(cap ip_link | grep -c 'UP' || true)"
    if [ "${down:-0}" -eq 0 ] && [ "${up:-0}" -gt 0 ]; then
      report_row 5 "端口状态" "全端口活跃" "${up} 个 UP" "全部端口 UP, carrier detected" PASS
    else
      report_row 5 "端口状态" "全端口活跃" "UP=${up} 非UP=${down}" "全部端口 UP" FAIL
    fi
  else
    report_row 5 "端口状态" "全端口活跃" "N/A" "全部端口 UP" SKIP
  fi

  # PFC / DSCP
  qos_files="$(ls "$LOG_DIR"/mlnx_qos_*.txt 2>/dev/null || true)"
  if [ -n "$qos_files" ]; then
    if grep -h -qi 'enabled' $qos_files 2>/dev/null; then
      report_row 5 "PFC" "Priority Flow Control" "存在 Enabled 优先级" "RoCE 所在 TC Enabled PFC（无损队列）" MANUAL \
        "需人工确认 Enabled 的是 RoCE 实际使用的那条 TC"
    else
      report_row 5 "PFC" "Priority Flow Control" "未见 Enabled" "RoCE 所在 TC Enabled PFC" FAIL
    fi
    trust="$(grep -h -io 'trust state: *[a-z]*' $qos_files 2>/dev/null | head -n1 | awk '{print tolower($NF)}')"
    report_eq 5 "DSCP" "QoS 标记" "${trust:-}" "$ROCE_TRUST_MODE" "信任模式"
  else
    report_row 5 "PFC" "Priority Flow Control" "N/A" "Enabled PFC" SKIP "mlnx_qos 未安装"
    report_row 5 "DSCP" "QoS 标记" "N/A" "信任模式 = $ROCE_TRUST_MODE" SKIP "mlnx_qos 未安装"
  fi

  # MTU
  if cap_exists ip_link_mtu; then
    mtu_min="$(cap ip_link_mtu | grep -oE 'mtu [0-9]+' | awk '{print $2}' | num_min)"
    report_ge 5 "MTU" "巨帧" "$mtu_min" "$ROCE_MTU" "" "取所有 RoCE 口最小值"
  else
    report_row 5 "MTU" "巨帧" "N/A" "MTU = $ROCE_MTU" SKIP
  fi

  # 丢包 / PFC 暂停帧
  eth_files="$(ls "$LOG_DIR"/ethtool_stats_*.txt 2>/dev/null || true)"
  if [ -n "$eth_files" ]; then
    discards="$(grep -h -iE 'rx_discards' $eth_files 2>/dev/null | grep -oE '[0-9]+$' | num_max)"
    report_le 5 "无损验证" "rx_discards" "${discards:-0}" "$ROCE_RX_DISCARDS_MAX" "个"
    report_row 5 "无损验证" "PFC 暂停帧比例" "见 ethtool_stats_*.txt" "<= ${ROCE_PFC_PAUSE_MAX_PCT}%" MANUAL \
      "比例需用 pause 帧数 / 总帧数换算，端口计数口径随固件版本变化"
  else
    report_row 5 "无损验证" "PFC/丢包检查" "N/A" "rx_discards = 0" SKIP "ethtool 未安装"
  fi

  # perftest 带宽/延迟
  perf_bw() { cap "$1" | awk '/^[[:space:]]*[0-9]/ && NF>=4 {v=$(NF-1); if(v ~ /^[0-9.]+$/ && v+0>m) m=v+0} END{if(m) printf "%.2f", m}'; }
  perf_lat() { cap "$1" | awk '/^[[:space:]]*[0-9]/ && NF>=6 {print $6}' | num_min; }

  if cap_exists ib_write_bw; then
    report_ge 5 "RoCE 写带宽" "单 NIC 写带宽" "$(perf_bw ib_write_bw)" "$ROCE_WRITE_BW_MIN_GBPS" "Gb/s"
  else
    report_row 5 "RoCE 写带宽" "单 NIC 写带宽" "N/A" ">= $ROCE_WRITE_BW_MIN_GBPS Gb/s" SKIP "perftest 未装或未设 PEER_IP"
  fi
  if cap_exists ib_read_bw; then
    report_ge 5 "RoCE 读带宽" "单 NIC 读带宽" "$(perf_bw ib_read_bw)" "$ROCE_READ_BW_MIN_GBPS" "Gb/s"
  else
    report_row 5 "RoCE 读带宽" "单 NIC 读带宽" "N/A" ">= $ROCE_READ_BW_MIN_GBPS Gb/s" SKIP
  fi
  if cap_exists ib_write_bw_gdr; then
    report_ge 5 "RoCE GPUDirect" "GPUDirect RDMA" "$(perf_bw ib_write_bw_gdr)" "$ROCE_GDR_BW_MIN_GBPS" "Gb/s"
  else
    report_row 5 "RoCE GPUDirect" "GPUDirect RDMA" "N/A" ">= $ROCE_GDR_BW_MIN_GBPS Gb/s" SKIP
  fi
  if cap_exists ib_send_lat; then
    report_le 5 "RoCE 延迟" "小消息延迟" "$(perf_lat ib_send_lat)" "$ROCE_LAT_MAX_US" "us"
  else
    report_row 5 "RoCE 延迟" "小消息延迟" "N/A" "<= $ROCE_LAT_MAX_US us" SKIP
  fi
fi

# ============================================================ §6 跨节点 NCCL
LOG_DIR="$PARENT/cluster"
export LOG_DIR
nccl_peak() {
  cap "$1" | awk '/^[[:space:]]*[0-9]+[[:space:]]/ && NF>=8 {
      v=$(NF-1); if(v ~ /^[0-9.]+$/ && v+0>m) m=v+0 } END{ if(m) printf "%.2f", m }'
}

if [ ! -d "$LOG_DIR" ]; then
  report_row 6 "跨节点 NCCL" "全部测试项" "未执行" "见《验收标准》§6" SKIP "先跑 scripts/cluster/nccl_scale.sh"
else
  for entry in $CLUSTER_ALLREDUCE_SCALE; do
    n="${entry%%:*}"; want="${entry##*:}"
    name="allreduce_${n}n"
    if cap_exists "$name"; then
      report_ge 6 "跨节点 NCCL" "${n} 节点 $((n * EXPECTED_GPU_COUNT)) GPU AllReduce" \
        "$(nccl_peak "$name")" "$want" "GB/s"
    else
      report_row 6 "跨节点 NCCL" "${n} 节点 $((n * EXPECTED_GPU_COUNT)) GPU AllReduce" "N/A" \
        ">= $want GB/s" SKIP "节点数不足或未运行"
    fi
  done

  check2n() {
    local name="$1" label="$2" want="$3"
    if cap_exists "$name"; then
      report_ge 6 "跨节点 NCCL" "$label" "$(nccl_peak "$name")" "$want" "GB/s"
    else
      report_row 6 "跨节点 NCCL" "$label" "N/A" ">= $want GB/s" SKIP
    fi
  }
  check2n allgather_2n     "2 节点 16 GPU AllGather"     "$CLUSTER_ALLGATHER_2N_MIN_GBS"
  check2n reducescatter_2n "2 节点 16 GPU ReduceScatter" "$CLUSTER_REDUCESCATTER_2N_MIN_GBS"
  check2n alltoall_2n      "2 节点 16 GPU AlltoAll"      "$CLUSTER_ALLTOALL_2N_MIN_GBS"
  check2n sendrecv_2n      "2 节点 16 GPU SendRecv 双向" "$CLUSTER_SENDRECV_2N_MIN_GBS"

  if cap_exists roce_only_allreduce; then
    report_ge 5 "RoCE-only" "纯 RoCE AllReduce（排除 NVLink）" "$(nccl_peak roce_only_allreduce)" \
      "$ROCE_ONLY_ALLREDUCE_MIN_GBS" "GB/s" "单 GPU Bus BW"
  else
    report_row 5 "RoCE-only" "纯 RoCE AllReduce（排除 NVLink）" "N/A" \
      ">= $ROCE_ONLY_ALLREDUCE_MIN_GBS GB/s" SKIP
  fi
fi

# ------------------------------------------ §6b 慢节点体检（straggler_check.sh）
# §6 判"够不够快"（对绝对阈值），本节判"有没有拖后腿的"（对同批中位数）。
# 两者互补：全员一起劣化时 §6 会 FAIL 而本节全绿；绝对达标但藏着一台差 15% 的
# 机器时反过来。没有 straggler.json 一律 SKIP —— 工具没跑过绝不能读成通过。
STRAG_JSON="$LOG_DIR/straggler.json"
if [ -s "$STRAG_JSON" ]; then
  strag="$(python3 - "$STRAG_JSON" <<'PYEOF'
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception as exc:                       # 文件损坏也不能当成通过
    print(f"BAD\t{exc}")
    raise SystemExit(0)
gpus, nodes = d.get("gpus", []), d.get("nodes", [])
slow_gpu = [g for g in gpus if g.get("slow")]
slow_node = [n for n in nodes if any(c.get("slow") for c in n.get("classes", {}).values())]
groups = d.get("groups", [])
tv = d.get("topology") or {}
over = tv.get("oversubscription")
attrib = [f"rank{g['rank']}@{g['host']}: {g['attribution']}"
          for g in gpus if g.get("attribution")]
print("\t".join([
    "OK",
    str(len(gpus)), str(len(slow_gpu)),
    str(len(nodes)), str(len(slow_node)),
    ",".join(n["host"] for n in slow_node) or "-",
    str(len(groups)),
    str(d.get("min_perf_ratio", "")),
    "；".join(attrib) or "-",
    "" if over is None else f"{over:.2f}",
    "" if not tv.get("intra_bw_gbs") else f"{tv['intra_bw_gbs']:.1f}",
    "" if not tv.get("inter_bw_gbs") else f"{tv['inter_bw_gbs']:.1f}",
]))
PYEOF
)"
  IFS=$'\t' read -r st n_gpu n_slow n_node n_snode snodes n_grp ratio attrib over ibw xbw <<< "$strag"
  if [ "$st" != OK ]; then
    # 两行都要出：少一行就是"配置了的指标静默消失"，看报告的人不会发现少了什么
    report_row 6 "慢节点体检" "同批均一性" "N/A" \
      ">= 同批中位 ${CLUSTER_STRAGGLER_MIN_RATIO:-?}" SKIP "straggler.json 无法解析：$n_gpu"
    report_row 6 "慢节点体检" "拓扑分组" "N/A" "按 leaf/rail 分组比较" SKIP "straggler.json 无法解析"
    report_row 6 "计算网拓扑" "实测收敛比" "N/A" "<= ${CLUSTER_OVERSUBSCRIPTION_MAX:-?} : 1" SKIP "straggler.json 无法解析"
  else
    pct="$(awk -v r="$ratio" 'BEGIN{printf "%.0f", r*100}')"
    if [ "$n_slow" -eq 0 ] && [ "$n_snode" -eq 0 ]; then
      report_row 6 "慢节点体检" "同批均一性" \
        "${n_gpu} 个 GPU、${n_node} 个节点全部不低于同批中位的 ${pct}%" \
        ">= 同批中位 ${pct}%" PASS
    else
      report_row 6 "慢节点体检" "同批均一性" \
        "${n_slow}/${n_gpu} 个 GPU、${n_snode}/${n_node} 个节点低于同批中位的 ${pct}%（${snodes}）" \
        ">= 同批中位 ${pct}%" FAIL "见 straggler.json"
    fi
    # 拓扑分组数为 1 说明没给拓扑文件：跨 leaf 差异会混进同一个基线，
    # 判定仍会出结论但可信度下降，必须显式标出来而不是默默通过。
    if [ "${n_grp:-1}" -le 1 ]; then
      report_row 6 "慢节点体检" "拓扑分组" "仅 1 组（未提供 topology.tsv）" \
        "按 leaf/rail 分组比较" MANUAL "跨 spine 差异会混进同一基线，先跑 topo_discover.sh"
    else
      report_row 6 "慢节点体检" "拓扑分组" "${n_grp} 组，同组/跨组分别比较" \
        "按 leaf/rail 分组比较" PASS
    fi
    # 实测收敛比：厂商宣称 1:1 无收敛时，这是唯一能证伪的实测依据。
    # 只有 1 个拓扑组时算不出来，必须 SKIP 而不是当成"无收敛"。
    if [ -n "$over" ]; then
      report_le 6 "计算网拓扑" "实测收敛比" "$over" "$CLUSTER_OVERSUBSCRIPTION_MAX" ": 1" \
        "组内 ${ibw} GB/s、跨组 ${xbw} GB/s（成对带宽中位）"
    else
      report_row 6 "计算网拓扑" "实测收敛比" "N/A（仅 ${n_grp} 个拓扑组，无法比较）" \
        "<= ${CLUSTER_OVERSUBSCRIPTION_MAX:-?} : 1" SKIP "先跑 topo_discover.sh 生成 topology.tsv"
    fi
    [ "$attrib" = "-" ] || echo "慢节点归因：$attrib" > "$LOG_DIR/straggler_attribution.txt"
  fi
else
  report_row 6 "慢节点体检" "同批均一性" "N/A" \
    ">= 同批中位 ${CLUSTER_STRAGGLER_MIN_RATIO:-?}%" SKIP \
    "未执行 scripts/cluster/straggler_check.sh"
  report_row 6 "慢节点体检" "拓扑分组" "N/A" "按 leaf/rail 分组比较" SKIP "同上"
  report_row 6 "计算网拓扑" "实测收敛比" "N/A" "<= ${CLUSTER_OVERSUBSCRIPTION_MAX:-?} : 1" SKIP "同上"
fi

report_summary || true

{
  echo "=============================================================================="
  echo " 多机验收判定表（《验收标准》§5 RoCE v2 + §6 跨节点 NCCL）"
  echo "=============================================================================="
  echo " 日志目录 : $(basename "$PARENT")"
  echo " 机型档案 : ${PROFILE_NAME:-?} (${ACC_PROFILE:-?})"
  echo " 生成时间 : $(date '+%F %T')"
  echo
  { head -n1 "$PARENT/cluster_report.tsv"; tail -n +2 "$PARENT/cluster_report.tsv" | sort -s -k1,1n; } \
    | fmt_table
  echo
  cat "$PARENT/cluster_report.tsv.summary"
  echo
  echo "说明：余量 = 实测相对阈值的百分比裕度。规模项 SKIP 多因 hostfile 节点数不足，"
  echo "      不等于通过。PFC 与暂停帧比例标 MANUAL：计数口径随网卡固件变化。"
} > "$PARENT/cluster_report.txt"

tsv_to_csv "$PARENT/cluster_report.tsv" "$PARENT/cluster_report.csv"
CMETA="$(mktemp)"
{
  echo "机型档案: ${PROFILE_NAME:-?} (${ACC_PROFILE:-?})"
  echo "报告生成: $(date '+%F %T %Z')"
  echo "日志目录: $(basename "$PARENT")"
} > "$CMETA"
write_html_report "$PARENT/cluster_report.tsv" "$PARENT/cluster_report.html" \
  "多机验收判定表（§5 RoCE v2 + §6 跨节点 NCCL）" "$CMETA"
rm -f "$CMETA"

echo
echo "判定表: $PARENT/cluster_report.txt"
echo "Excel:  $PARENT/cluster_report.csv"
echo "HTML:   $PARENT/cluster_report.html"
[ "${ACC_VERDICT:-FAIL}" = "PASS" ]
