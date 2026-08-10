#!/usr/bin/env bash
# 同批次比对 —— 把多台机器的判定表横向拉平，找出掉队的机器。
#
#   bash scripts/compare_batch.sh <logs根目录|日志目录...> [profile]
#
# 例：
#   bash scripts/compare_batch.sh logs/                    # 自动收集 logs/ 下所有判定表
#   bash scripts/compare_batch.sh logs/2026-*_SN*          # 指定若干台
#
# 为什么需要这一步：单机判定只能回答"这台机器达不达标"，回答不了
# "这台机器在这批里是不是明显落后"。docs/acceptance_criteria.md v1.0 把
# "同批次性能低于中位数 10% 以上"列为硬性 FAIL —— 一台每项都过线、
# 但样样都比同批中位数低 12% 的机器，往往是散热或供电有问题，
# 单看它自己的判定表完全看不出来。
#
# 判定（阈值在 profile 的 BATCH_PASS_PCT / BATCH_RETEST_PCT）：
#   >= 中位数 95%            PASS
#   >= 90% 且 < 95%          RETEST
#   < 90%                    FAIL
# 机器数少于 BATCH_MIN_MACHINES 时中位数没有统计意义，只列数据不判定。

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
. "$SCRIPT_DIR/lib/common.sh"

# ---------------------------------------------------------------- 参数解析
DIRS=()
PROFILE_ARG=""
for a in "$@"; do
  if [ -d "$a" ]; then
    if [ -f "$a/acceptance_report.tsv" ]; then
      DIRS+=("$a")
    else
      # 当成 logs 根目录，往下找一层
      while IFS= read -r d; do DIRS+=("$d"); done \
        < <(find "$a" -maxdepth 2 -name acceptance_report.tsv -printf '%h\n' 2>/dev/null | sort)
    fi
  elif [ -f "$BASE_DIR/profiles/${a}.env" ]; then
    PROFILE_ARG="$a"
  fi
done

if [ "${#DIRS[@]}" -eq 0 ]; then
  echo "用法: bash scripts/compare_batch.sh <logs根目录|日志目录...> [profile]" >&2
  echo "      未找到任何 acceptance_report.tsv。先对每台机器跑 check_node.sh。" >&2
  exit 2
fi

load_profile "${PROFILE_ARG:-${PROFILE:-b300_8gpu}}" || exit 2

OUT_DIR="${OUT_DIR:-$BASE_DIR/reports}"
mkdir -p "$OUT_DIR"
ts="$(date +%F_%H%M%S)"
OUT="$OUT_DIR/batch_comparison_${ts}"

# 参与比对的指标：项名 + 方向（hi = 越大越好，lo = 越小越好）。
# 只挑跨机器可比、且能反映硬件差异的项 —— 版本号、计数类不参与。
METRICS="
H2D 带宽|hi
D2H 带宽|hi
GPU 间带宽|hi
单向 P2P 带宽|hi
GPU 间 P2P 延迟|lo
AllReduce|hi
AllGather|hi
温度峰值|lo
GPU 温度(压测期间)|lo
"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
: > "$TMP/unmatched"

# ------------------------------------------------ 抽取每台机器的每项实测值
# 判定表第 3 列是测试项、第 5 列是实测值（形如 "795.44 GB/s"）。
: > "$TMP/raw.tsv"
for d in "${DIRS[@]}"; do
  machine="$(basename "$d")"
  # 机器 SN 优先用采集时记录的，退回目录名
  sn="$(grep -oE '^Host SN: .*' "$d/session.txt" 2>/dev/null | cut -d' ' -f3-)"
  [ -n "$sn" ] && machine="$sn"
  # 全角冒号是多字节，cut -d 只接受单字节分隔符，这里用 sed 抠。
  verdict="$(sed -n 's/.*机器判定：\([A-Z]*\).*/\1/p' "$d/acceptance_report.tsv.summary" 2>/dev/null | head -n1)"
  echo "$machine|${verdict:-?}|$d" >> "$TMP/machines"
  awk -F'\t' -v m="$machine" '
    NR>1 {
      item=$3; val=$5;
      # 取实测值里的第一个数字；取不到就跳过（定性项不参与比对）
      if (match(val, /-?[0-9]+([.][0-9]+)?/)) {
        printf "%s\t%s\t%s\n", m, item, substr(val, RSTART, RLENGTH);
      }
    }' "$d/acceptance_report.tsv" >> "$TMP/raw.tsv"
done

N_MACHINES="$(wc -l < "$TMP/machines")"

# ------------------------------------------------------------------ 输出
{
  echo "=============================================================================="
  echo " 同批次比对 — ${N_MACHINES} 台机器"
  echo "=============================================================================="
  echo " 机型档案 : ${PROFILE_NAME:-?} (${ACC_PROFILE:-?})"
  echo " 生成时间 : $(date '+%F %T')"
  echo " 判定口径 : >=中位数${BATCH_PASS_PCT:-95}% PASS，>=${BATCH_RETEST_PCT:-90}% RETEST，否则 FAIL"
  echo
  echo "参与比对的机器："
  awk -F'|' '{printf "  %-28s 单机判定=%-6s %s\n", $1, $2, $3}' "$TMP/machines"
  echo
} > "$OUT.txt"

if [ "$N_MACHINES" -lt "${BATCH_MIN_MACHINES:-3}" ]; then
  {
    echo "注意：只有 ${N_MACHINES} 台机器，少于 ${BATCH_MIN_MACHINES:-3} 台时中位数没有统计意义。"
    echo "      以下只列出实测值，不做同批次判定。"
    echo
  } >> "$OUT.txt"
  JUDGE=0
else
  JUDGE=1
fi

printf '指标\t机器\t实测值\t中位数\t相对中位数\t判定\n' > "$OUT.tsv"

BATCH_FAIL=0
while IFS='|' read -r item dir; do
  [ -z "$item" ] && continue
  # 用子串匹配：报表里的项名带上下文（"8 GPU AllReduce"），
  # 精确匹配会让配置了的指标一条都对不上，然后被静默跳过 —— 必须让它出声。
  awk -F'\t' -v it="$item" 'index($2, it) > 0' "$TMP/raw.tsv" > "$TMP/m"
  if [ ! -s "$TMP/m" ]; then
    echo "$item" >> "$TMP/unmatched"
    continue
  fi

  median="$(awk -F'\t' '{print $3}' "$TMP/m" | sort -g | awk '
    {a[NR]=$1} END{ if(NR==0) exit;
      if(NR%2) printf "%.2f", a[(NR+1)/2];
      else printf "%.2f", (a[NR/2]+a[NR/2+1])/2 }')"
  [ -z "$median" ] && continue
  awk -v z="$median" 'BEGIN{exit !(z+0==0)}' && continue   # 中位数为 0 无法算比值

  while IFS=$'\t' read -r machine _ val; do
    ratio="$(awk -v v="$val" -v z="$median" -v d="$dir" 'BEGIN{
      r = (d=="hi") ? v/z : z/v;      # 越小越好的指标反过来算，语义统一为"越大越好"
      printf "%.1f", r*100 }')"
    v_verdict="INFO"
    if [ "$JUDGE" = "1" ]; then
      if num_ge "$ratio" "${BATCH_PASS_PCT:-95}"; then v_verdict="PASS"
      elif num_ge "$ratio" "${BATCH_RETEST_PCT:-90}"; then v_verdict="RETEST"
      else v_verdict="FAIL"; BATCH_FAIL=$((BATCH_FAIL + 1)); fi
    fi
    printf '%s\t%s\t%s\t%s\t%s%%\t%s\n' "$item" "$machine" "$val" "$median" "$ratio" "$v_verdict" \
      >> "$OUT.tsv"
  done < "$TMP/m"
done <<EOF
$(printf '%s\n' "$METRICS" | grep -v '^[[:space:]]*$' | tr '|' '\n' | paste - - | tr '\t' '|')
EOF

{
  echo "逐指标比对（相对中位数）"
  echo "------------------------------------------------------------------------------"
  fmt_table "$OUT.tsv"
  echo
  if [ -s "$TMP/unmatched" ]; then
    echo "以下指标在判定表里没有对应数据，未参与比对："
    sed 's/^/  - /' "$TMP/unmatched"
    echo "  （多半是对应测试未执行，或 compare_batch.sh 的 METRICS 项名与判定表不一致）"
    echo
  fi
  echo "掉队清单（相对中位数低于 ${BATCH_RETEST_PCT:-90}%）"
  echo "------------------------------------------------------------------------------"
  if awk -F'\t' 'NR>1 && $6=="FAIL"' "$OUT.tsv" | grep -q .; then
    awk -F'\t' 'NR>1 && $6=="FAIL"{printf "  %-28s %-22s 实测 %s（中位数 %s，%s）\n", $2,$1,$3,$4,$5}' "$OUT.tsv"
    echo
    echo "  按 docs/acceptance_criteria.md v1.0，同批次性能低于中位数 10% 以上属硬性 FAIL。"
    echo "  优先排查：散热（进风温度/风扇曲线）、供电、PCIe 插槽、BIOS 与固件版本差异。"
  else
    echo "  无"
  fi
  echo
} >> "$OUT.txt"

tsv_to_csv "$OUT.tsv" "$OUT.csv"

cat "$OUT.txt"
echo "比对表(人读): $OUT.txt"
echo "比对表(机读): $OUT.tsv"
echo "比对表(Excel): $OUT.csv"

[ "$BATCH_FAIL" -eq 0 ]
