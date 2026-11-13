#!/usr/bin/env bash
# 生成 topology.tsv（node -> 拓扑组），供 straggler_check.sh 分类配对。
#
#   bash scripts/cluster/topo_discover.sh <log_dir> <hostfile>
#
# 组的含义是"这些节点之间的通信不跨上层交换"。发现顺序：
#   1) IB   : iblinkinfo 取本机 HCA 对端交换机名
#   2) RoCE : lldpctl/lldpcli 取业务网口对端交换机 chassis 名
#   3) 兜底 : 主机名里的 pod/rack/leaf 字段（CLUSTER_TOPO_HOST_REGEX）
# 三条都拿不到就写 _unknown 并在文件头标注 —— 宁可显式退化成单组，
# 也不要伪造一个看起来可信的分组去污染判定基线。
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
. "$BASE_DIR/scripts/lib/common.sh"

PARENT="${1:-}"; HOSTFILE="${2:-}"
if [ -z "$PARENT" ] || [ -z "$HOSTFILE" ] || [ ! -f "$HOSTFILE" ]; then
  echo "用法: bash scripts/cluster/topo_discover.sh <log_dir> <hostfile>" >&2
  exit 2
fi
mkdir -p "$PARENT/cluster"
LOG_DIR="$(cd "$PARENT/cluster" && pwd)"
OUT="$LOG_DIR/topology.tsv"
RAW="$LOG_DIR/topology_raw.txt"
: > "$RAW"

# 单机侧探测：只用只读命令，不改任何配置
probe_local() {
  local hca_switch="" lldp_switch=""
  if command -v iblinkinfo >/dev/null 2>&1; then
    hca_switch="$(iblinkinfo 2>/dev/null | awk '
      /^Switch/ {sw=$0; sub(/^Switch[^"]*"/,"",sw); sub(/".*/,"",sw)}
      /==>/ && sw!="" {print sw; exit}')"
  fi
  if [ -z "$hca_switch" ] && command -v lldpctl >/dev/null 2>&1; then
    lldp_switch="$(lldpctl 2>/dev/null | awk -F': *' '/SysName:/{print $2; exit}')"
  elif [ -z "$hca_switch" ] && command -v lldpcli >/dev/null 2>&1; then
    lldp_switch="$(lldpcli show neighbors 2>/dev/null | awk -F': *' '/SysName:/{print $2; exit}')"
  fi
  printf 'hca=%s\tlldp=%s\n' "${hca_switch:-}" "${lldp_switch:-}"
}

if [ "${TOPO_PROBE_LOCAL:-0}" = "1" ]; then
  probe_local
  exit 0
fi

HOSTS=()
while read -r h _rest; do
  case "$h" in ''|'#'*) continue ;; esac
  HOSTS+=("$h")
done < "$HOSTFILE"
[ "${#HOSTS[@]}" -gt 0 ] || { echo "[topo] hostfile 为空" >&2; exit 2; }

REGEX="${CLUSTER_TOPO_HOST_REGEX:-.*-(pod|rack|leaf)([0-9]+)-.*}"
unknown=0

{
  echo "# 由 topo_discover.sh 生成于 $(date -Is)"
  echo "# 格式: <node>\t<group>\t<来源>"
  echo "#"
  echo "# group 表示「这些节点之间通信不跨上层交换」；_unknown 表示未探测到，"
  echo "# 该节点会被归入同一个兜底组，跨组对比对它无效 —— 不要当成已确认。"
  echo "#"
  echo "# ---- 本文件只有一层，读之前先知道它答不了什么 ----"
  echo "#"
  echo "# 1) 只区分「同组 / 不同组」，即同一台 leaf 之下还是跨 leaf。"
  echo "#    它分不出「哪几台 leaf 挂在同一个 spine」—— 那需要三层延迟分离，"
  echo "#    实测噪声基本不支持（NCCL 启动开销就有 15~30µs，交换机每跳只有零点几到 1µs）。"
  echo "#    要 spine 这一层，只能拿交换机侧的连线表，没有别的办法。"
  echo "#"
  echo "# 2) 由本文件算出的「实测收敛比」是代理指标，只能证伪不能证实："
  echo "#    测出明显大于 1 → 确实存在收敛，可以据此反驳「1:1 无收敛」；"
  echo "#    测出接近 1     → 只能说「在本测试的并发强度下未观察到收敛」，"
  echo "#                     不等于确认无收敛 —— 并发流数未必达到真实 AllReduce 的量级。"
  echo "#    要严格验证 1:1，得让所有 leaf 同时满打，属于《验收标准》§6 的规模测试。"
  echo "#"
  echo "# 3) 来源列为 hostname:regex 的行是**按主机名猜的**，没有任何链路证据。"
  echo "#    现场问网络工程师要一份 leaf 分配表，人工覆盖 group 列，比什么都快。"
} > "$OUT"

for h in "${HOSTS[@]}"; do
  line="$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$h" \
    "TOPO_PROBE_LOCAL=1 bash -s" < "$SCRIPT_DIR/topo_discover.sh" 2>/dev/null || echo "")"
  printf '%s\t%s\n' "$h" "${line:-<无法探测>}" >> "$RAW"
  hca="$(printf '%s' "$line" | sed -n 's/.*hca=\([^\t]*\).*/\1/p')"
  lldp="$(printf '%s' "$line" | sed -n 's/.*lldp=\(.*\)$/\1/p')"
  group=""; src=""
  if [ -n "$hca" ]; then
    group="$(printf '%s' "$hca" | tr -c 'A-Za-z0-9_.-' '_')"; src="ib:iblinkinfo"
  elif [ -n "$lldp" ]; then
    group="$(printf '%s' "$lldp" | tr -c 'A-Za-z0-9_.-' '_')"; src="roce:lldp"
  elif printf '%s' "$h" | grep -Eq "$REGEX"; then
    group="$(printf '%s' "$h" | sed -E "s/$REGEX/\1\2/")"; src="hostname:regex"
  else
    group="_unknown"; src="none"; unknown=$((unknown + 1))
  fi
  printf '%s\t%s\t%s\n' "$h" "$group" "$src" >> "$OUT"
done

groups="$(awk '!/^#/{print $2}' "$OUT" | sort -u | wc -l)"
echo "[topo] 写入 $OUT：${#HOSTS[@]} 节点，$groups 个组，$unknown 个未探测到"
if [ "$unknown" -gt 0 ]; then
  echo "[topo] 警告：$unknown 个节点拓扑未知。跨组判定对它们无效，" >&2
  echo "       请人工补齐 $OUT 的 group 列（现场问网络工程师要 leaf 分配表最快）。" >&2
fi
if [ "$groups" -le 1 ]; then
  echo "[topo] 警告：只有 1 个组 —— 跨组对比不会执行。若这是 rail-optimized fabric，" >&2
  echo "       说明探测失败，跨 spine 的差异会混进同一个基线。" >&2
fi
guessed="$(awk '!/^#/ && $3=="hostname:regex"' "$OUT" | wc -l)"
if [ "$guessed" -gt 0 ]; then
  echo "[topo] 注意：$guessed 个节点的分组是按主机名猜的，没有链路证据；建议人工核对。" >&2
fi
echo "[topo] 本文件只分「同 leaf / 跨 leaf」一层，分不出 leaf 与 spine 的挂接关系；" >&2
echo "       由它算出的实测收敛比只能证伪 1:1，不能证实。详见 $OUT 文件头。" >&2
