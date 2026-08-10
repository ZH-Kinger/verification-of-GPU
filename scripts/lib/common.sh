#!/usr/bin/env bash
# Shared helpers for the 《验收标准》-driven acceptance scripts.
#
# Source this file; do not execute it:
#     . "$SCRIPT_DIR/lib/common.sh"
#     load_profile "${PROFILE:-b300_8gpu}"
#
# Provides:
#   load_profile <name>              source profiles/<name>.env
#   tools_bin_dir                    per-profile precompiled binary dir
#   run_cmd / run_shell <name> ...   capture stdout+stderr and exit code into LOG_DIR
#   report_init / report_row / report_summary
#   report_ge / report_le / report_eq            threshold assertions -> report rows
#   num_ge / num_le / is_num / ver_ge            comparison primitives
#   num_min / num_max / matrix_all / matrix_offdiag   output parsing primitives

ACC_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACC_BASE_DIR="$(cd "$ACC_LIB_DIR/../.." && pwd)"

# ------------------------------------------------------------------ profile

load_profile() {
  local name="${1:-b300_8gpu}"
  local file="$ACC_BASE_DIR/profiles/${name}.env"
  if [ ! -f "$file" ]; then
    echo "[common] profile not found: $file" >&2
    echo "[common] available: $(ls "$ACC_BASE_DIR/profiles" 2>/dev/null | tr '\n' ' ')" >&2
    return 1
  fi
  # shellcheck disable=SC1090
  . "$file"
  ACC_PROFILE="$name"
  export ACC_PROFILE
}

# Precompiled binaries for the loaded profile, with a fallback to tools/bin so
# an unmigrated tree still works.
tools_bin_dir() {
  local sub="${TOOLS_BIN_SUBDIR:-bin}"
  if [ -d "$ACC_BASE_DIR/tools/$sub" ]; then
    echo "$ACC_BASE_DIR/tools/$sub"
  else
    echo "$ACC_BASE_DIR/tools/bin"
  fi
}

# Resolve a tool: PATH first, then the profile's binary dir.
tool_path() {
  local name="$1" dir
  if command -v "$name" >/dev/null 2>&1; then
    command -v "$name"
    return 0
  fi
  dir="$(tools_bin_dir)"
  if [ -x "$dir/$name" ]; then
    echo "$dir/$name"
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------- capturing

# LOG_DIR must be set by the caller before using run_cmd / run_shell.
run_cmd() {
  local name="$1"
  shift
  echo "[RUN] $name: $*" | tee -a "$LOG_DIR/run.log"
  "$@" > "$LOG_DIR/${name}.txt" 2>&1
  local rc=$?
  echo "$rc" > "$LOG_DIR/${name}.exit"
  echo "[DONE] $name exit=$rc" | tee -a "$LOG_DIR/run.log"
  return 0
}

run_shell() {
  local name="$1"
  local command="$2"
  echo "[RUN] $name: $command" | tee -a "$LOG_DIR/run.log"
  bash -lc "$command" > "$LOG_DIR/${name}.txt" 2>&1
  local rc=$?
  echo "$rc" > "$LOG_DIR/${name}.exit"
  echo "[DONE] $name exit=$rc" | tee -a "$LOG_DIR/run.log"
  return 0
}

# Read a captured file; empty string if it does not exist.
cap() { cat "$LOG_DIR/${1}.txt" 2>/dev/null; }
cap_exit() { cat "$LOG_DIR/${1}.exit" 2>/dev/null || echo ""; }
cap_exists() { [ -s "$LOG_DIR/${1}.txt" ]; }

# ------------------------------------------------------- comparison helpers

is_num() { printf '%s' "${1:-}" | grep -Eq '^-?[0-9]+([.][0-9]+)?$'; }
num_ge() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a+0 >= b+0)}'; }
num_le() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a+0 <= b+0)}'; }
num_eq_tol() { awk -v a="$1" -v b="$2" -v t="$3" 'BEGIN{d=a-b; if(d<0)d=-d; exit !(d <= t+0)}'; }

# Dotted-version >= comparison: ver_ge 580.105.08 580.105 -> true
ver_ge() {
  awk -v a="$1" -v b="$2" 'BEGIN{
    na=split(a,A,"."); nb=split(b,B,".");
    n=(na>nb)?na:nb;
    for(i=1;i<=n;i++){
      x=(i<=na)?A[i]+0:0; y=(i<=nb)?B[i]+0:0;
      if(x>y) exit 0;
      if(x<y) exit 1;
    }
    exit 0}'
}

# ---------------------------------------------------------- output parsing

# Smallest / largest number on stdin (any whitespace-separated numeric token).
# Integers print as integers — a count rendered "0.00 个" reads like a measurement
# error in the report; only real measurements get decimals.
num_min() {
  awk 'BEGIN{m=""} {for(i=1;i<=NF;i++) if($i ~ /^-?[0-9]+([.][0-9]+)?$/){v=$i+0; if(m==""||v<m)m=v}}
       END{if(m!="") { if(m==int(m)) printf "%d\n", m; else printf "%.2f\n", m }}'
}
num_max() {
  awk 'BEGIN{m=""} {for(i=1;i<=NF;i++) if($i ~ /^-?[0-9]+([.][0-9]+)?$/){v=$i+0; if(m==""||v>m)m=v}}
       END{if(m!="") { if(m==int(m)) printf "%d\n", m; else printf "%.2f\n", m }}'
}

# Bandwidth/latency matrices print a leading row index and then one cell per
# column: "0   55.23  54.98 ...". The column-index header line ("   0   1   2")
# also starts with a digit, so cells must be restricted to values that carry a
# decimal point — every bandwidth/latency figure does, column indices do not.
#
#   matrix_float_all      every cell (use for H2D/D2H: rows are CPUs, no diagonal)
#   matrix_float_offdiag  skips cell[i][i]  (use for GPU x GPU matrices)
matrix_float_all() {
  awk '/^[[:space:]]*[0-9]+[[:space:]]/{
         for(i=2;i<=NF;i++) if($i ~ /^[0-9]+[.][0-9]+$/) print $i
       }' "$1" 2>/dev/null
}
matrix_float_offdiag() {
  awk '/^[[:space:]]*[0-9]+[[:space:]]/{
         r=$1+0;
         for(i=2;i<=NF;i++){ c=i-2; if(c==r) continue;
           if($i ~ /^[0-9]+[.][0-9]+$/) print $i }
       }' "$1" 2>/dev/null
}

# Integer matrices (p2p connectivity 1/0). Skips the column-index header by
# requiring the row to hold only 0/1 cells.
matrix_int_offdiag() {
  awk '/^[[:space:]]*[0-9]+[[:space:]]/{
         ok=1; for(i=2;i<=NF;i++) if($i !~ /^[01]$/) ok=0;
         if(!ok) next;
         r=$1+0;
         for(i=2;i<=NF;i++){ c=i-2; if(c==r) continue; print $i }
       }' "$1" 2>/dev/null
}

# Extract the block that follows a header line, into a temp stream. Used for
# p2pBandwidthLatencyTest, which prints several matrices in one file.
# Writes the block to stdout; caller pipes it to a temp file for the matrix_*
# helpers (which take a filename).
matrix_block() {
  local file="$1" header="$2"
  awk -v h="$header" '
    index($0,h){grab=1; seen=0; next}
    grab && /^[[:space:]]*$/{ if(seen) grab=0; next }
    grab { if($0 ~ /^[[:space:]]*[0-9]+[[:space:]]/) seen=1; print }
  ' "$file" 2>/dev/null
}

# ------------------------------------------------------------------ report

ACC_REPORT=""
ACC_N_PASS=0
ACC_N_FAIL=0
ACC_N_SKIP=0
ACC_N_MANUAL=0

report_init() {
  ACC_REPORT="$1"
  # 列序刻意对齐甲方《验收标准》的表头（模块 / 测试项 / 测试手段·命令 / 验收标准），
  # 再补上实测值、余量、判定 —— 交付时这张表就是那张表填好的样子。
  printf '章节\t模块\t测试项\t测试手段/命令\t实测值\t验收标准\t余量\t判定\t备注\n' > "$ACC_REPORT"
  ACC_N_PASS=0; ACC_N_FAIL=0; ACC_N_SKIP=0; ACC_N_MANUAL=0
}

# 余量：相对阈值还剩多少百分比。≥ 类是 (实测-阈值)/阈值，≤ 类是 (阈值-实测)/阈值。
# 正数=有余量，负数=已越线。阈值为 0（如 ECC=0）时百分比无意义，输出 "—"。
ACC_MARGIN=""
calc_margin() { # <measured> <threshold> <ge|le>
  local m="$1" t="$2" dir="$3"
  ACC_MARGIN="—"
  is_num "$m" && is_num "$t" || return 0
  if awk -v t="$t" 'BEGIN{exit !(t+0==0)}'; then
    # 阈值为 0：给绝对差值而不是百分比
    ACC_MARGIN="$(awk -v m="$m" -v t="$t" -v d="$dir" 'BEGIN{
      v=(d=="ge")?(m-t):(t-m); printf "%+g", v}')"
    return 0
  fi
  ACC_MARGIN="$(awk -v m="$m" -v t="$t" -v d="$dir" 'BEGIN{
    v=(d=="ge")?(m-t)/t:(t-m)/t; printf "%+.1f%%", v*100}')"
}

# 每个测试项对应的原始命令。check_node.sh / check_cluster.sh 各自定义 cmd_of，
# 这里按需调用 —— 避免在 50 个 report_row 调用点都多传一个参数。
_cmd_for() { # <item> <module>
  if declare -F cmd_of >/dev/null 2>&1; then cmd_of "$1" "${2:-}"; else echo "-"; fi
}

# report_row <section> <module> <item> <measured> <expected> <verdict> [note]
# verdict: PASS | FAIL | SKIP | MANUAL
report_row() {
  local section="$1" module="$2" item="$3" measured="$4" expected="$5" verdict="$6" note="${7:-}"
  local margin="${ACC_MARGIN:-—}"
  ACC_MARGIN=""
  local cmd
  cmd="$(_cmd_for "$item" "$module")"
  measured="$(printf '%s' "$measured" | tr '\t\n' '  ')"
  note="$(printf '%s' "$note" | tr '\t\n' '  ')"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$section" "$module" "$item" "${cmd:--}" "$measured" "$expected" "$margin" "$verdict" "$note" \
    >> "$ACC_REPORT"
  case "$verdict" in
    PASS)   ACC_N_PASS=$((ACC_N_PASS + 1)) ;;
    FAIL)   ACC_N_FAIL=$((ACC_N_FAIL + 1)) ;;
    SKIP)   ACC_N_SKIP=$((ACC_N_SKIP + 1)) ;;
    *)      ACC_N_MANUAL=$((ACC_N_MANUAL + 1)) ;;
  esac
  printf '[%-6s] §%-2s %-14s %-24s 实测=%-26s 要求=%-22s 余量=%s\n' \
    "$verdict" "$section" "$module" "$item" "$measured" "$expected" "$margin"
}

# report_ge <section> <module> <item> <measured> <min> [unit] [note]
report_ge() {
  local section="$1" module="$2" item="$3" measured="$4" min="$5" unit="${6:-}" note="${7:-}"
  if ! is_num "$measured"; then
    report_row "$section" "$module" "$item" "${measured:-N/A}" ">= $min $unit" SKIP \
      "${note:-未取得实测值（工具缺失或输出无法解析）}"
    return
  fi
  calc_margin "$measured" "$min" ge
  if num_ge "$measured" "$min"; then
    report_row "$section" "$module" "$item" "$measured $unit" ">= $min $unit" PASS "$note"
  else
    report_row "$section" "$module" "$item" "$measured $unit" ">= $min $unit" FAIL "$note"
  fi
}

# report_le <section> <module> <item> <measured> <max> [unit] [note]
report_le() {
  local section="$1" module="$2" item="$3" measured="$4" max="$5" unit="${6:-}" note="${7:-}"
  if ! is_num "$measured"; then
    report_row "$section" "$module" "$item" "${measured:-N/A}" "<= $max $unit" SKIP \
      "${note:-未取得实测值（工具缺失或输出无法解析）}"
    return
  fi
  calc_margin "$measured" "$max" le
  if num_le "$measured" "$max"; then
    report_row "$section" "$module" "$item" "$measured $unit" "<= $max $unit" PASS "$note"
  else
    report_row "$section" "$module" "$item" "$measured $unit" "<= $max $unit" FAIL "$note"
  fi
}

# report_eq <section> <module> <item> <measured> <expected> [note]  (string equality)
report_eq() {
  local section="$1" module="$2" item="$3" measured="$4" expected="$5" note="${6:-}"
  if [ -z "$measured" ]; then
    report_row "$section" "$module" "$item" "N/A" "$expected" SKIP "${note:-未取得实测值}"
  elif [ "$measured" = "$expected" ]; then
    report_row "$section" "$module" "$item" "$measured" "$expected" PASS "$note"
  else
    report_row "$section" "$module" "$item" "$measured" "$expected" FAIL "$note"
  fi
}

report_summary() {
  local total=$((ACC_N_PASS + ACC_N_FAIL + ACC_N_SKIP + ACC_N_MANUAL))
  local verdict="PASS"
  [ "$ACC_N_FAIL" -gt 0 ] && verdict="FAIL"
  [ "$ACC_N_FAIL" -eq 0 ] && [ "$ACC_N_SKIP" -gt 0 ] && verdict="HOLD"
  {
    echo
    echo "=============================================================="
    echo " Profile : ${PROFILE_NAME:-unknown} (${ACC_PROFILE:-?})"
    echo " 合计 $total 项：PASS=$ACC_N_PASS FAIL=$ACC_N_FAIL SKIP=$ACC_N_SKIP 人工核对=$ACC_N_MANUAL"
    echo " 机器判定：$verdict"
    [ "$ACC_N_SKIP" -gt 0 ] && echo " 注意：存在 SKIP 项（工具缺失/未运行），不能直接判 PASS。"
    echo "=============================================================="
  } | tee -a "$ACC_REPORT.summary"
  ACC_VERDICT="$verdict"
  [ "$verdict" = "PASS" ]
}
