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

# 采集与解析一律在 C locale 下进行。
#
# 很多工具的输出是本地化的：中文环境下 `free` 打的是 "内存：" 而不是 "Mem:"，
# 于是 awk '/^Mem:/' 一无所获，系统内存和内存识别率两项静默变成 SKIP ——
# 判定表照常产出，只是少了两行覆盖，现场根本不会注意到。
# 数字格式（小数点/千分位）同样随 locale 变化，会让所有数值解析失效。
#
# 这不影响报表里的中文：那些是我们自己的 UTF-8 字符串，按字节原样输出。
export LC_ALL=C
export LANG=C

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
  apply_profile_defaults
}

# 声明脚本用到的每一个 profile 变量，缺失的置空。
#
# 为什么必须有这个：日志目录里存的是采集当时的 profile.env 快照，用今天的脚本
# 复核一份半年前的日志时，快照里不会有后来新增的变量。在 set -u 下那会让判定
# 脚本中途死掉，只留下一份看起来正常、实际残缺的判定表。
#
# 置空而不是给默认值：阈值缺失时对应项必须判 SKIP（看得见），
# 绝不能悄悄套用一个默认值把检查变成橡皮图章。
apply_profile_defaults() {
  local v
  for v in \
    PROFILE_NAME PROFILE_ARCH_NOTE TOOLS_BIN_SUBDIR \
    EXPECTED_GPU_COUNT EXPECTED_GPU_MODEL_PATTERN EXPECTED_COMPUTE_CAP CUDA_ARCH_LIST \
    SYS_MEM_MIN_TB SYS_MEM_DETECT_MIN_PCT SYS_MEM_STRESS_SECONDS SYS_MEM_STRESS_PCT \
    GPU_TEMP_MAX_C GPU_TEMP_FLUCT_MAX_C \
    GPU_MEM_MIN_MIB GPU_MEM_NOMINAL_GB NODE_GPU_MEM_MIN_GIB \
    ECC_MODE_EXPECTED ECC_UNCORRECTED_MAX ECC_CORRECTED_MAX \
    GPU_POWER_LIMIT_W GPU_POWER_LIMIT_TOL_W PCIE_GEN PCIE_WIDTH \
    NVB_H2D_MIN_GBS NVB_D2H_MIN_GBS NVB_D2D_READ_MIN_GBS GPU_BURN_SHORT_SECONDS \
    NVLINK_TOPO_TAG NVLINK_LINKS_PER_GPU NVLINK_ERR_MAX \
    P2P_BW_MIN_GBS P2P_LAT_MAX_US NCCL_ALLREDUCE_MIN_GBS NCCL_ALLGATHER_MIN_GBS \
    NCCL_BENCH_ARGS \
    ROCE_LINK_TYPE ROCE_MTU ROCE_TRUST_MODE ROCE_WRITE_BW_MIN_GBPS ROCE_READ_BW_MIN_GBPS \
    ROCE_GDR_BW_MIN_GBPS ROCE_LAT_MAX_US ROCE_PFC_PAUSE_MAX_PCT ROCE_RX_DISCARDS_MAX \
    ROCE_ONLY_ALLREDUCE_MIN_GBS ROCE_PERFTEST_ARGS \
    CLUSTER_ALLREDUCE_SCALE CLUSTER_ALLGATHER_2N_MIN_GBS CLUSTER_REDUCESCATTER_2N_MIN_GBS \
    CLUSTER_ALLTOALL_2N_MIN_GBS CLUSTER_SENDRECV_2N_MIN_GBS CLUSTER_BENCH_ARGS \
    DRIVER_MIN_VERSION CUDA_MIN_VERSION NCCL_MIN_VERSION DCGM_MIN_VERSION \
    REQUIRE_NVIDIA_PEERMEM REQUIRE_GDRCOPY NVIDIA_MODPROBE_REQUIRED \
    SOAK_SECONDS SOAK_SAMPLE_INTERVAL_S SOAK_XID_MAX SOAK_NVLINK_CRC_DELTA_MAX \
    BATCH_PASS_PCT BATCH_RETEST_PCT BATCH_MIN_MACHINES
  do
    eval ": \"\${$v:=}\""
  done
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
  # 用登录 shell 是为了拿到 profile 里的 PATH（例如 /usr/local/cuda/bin），
  # 但 /etc/profile 和 ~/.profile 有可能把 locale 改回本地化设置，
  # 那样输出又会变成中文而解析不出来 —— 所以在命令内部再钉一次。
  bash -lc "export LC_ALL=C LANG=C; $command" > "$LOG_DIR/${name}.txt" 2>&1
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
# 正数=有余量，负数=已越线。阈值为 0（如 ECC=0）时百分比无意义，输出 "-"。
# 占位符用 ASCII "-" 而非全角破折号：后者是 East Asian Ambiguous 字符，
# 显示宽度随终端在 1/2 之间摇摆，会让任何按宽度排版的表格错位。
ACC_MARGIN=""
calc_margin() { # <measured> <threshold> <ge|le>
  local m="$1" t="$2" dir="$3"
  ACC_MARGIN="-"
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
  local margin="${ACC_MARGIN:--}"
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
  # 阈值本身缺失/非数值时必须判 SKIP。绝不能往下走 —— awk 会把空串当 0，
  # 于是任何实测值都 >= 0，一个拼错的变量名就把检查项变成橡皮图章。
  if ! is_num "$min"; then
    report_row "$section" "$module" "$item" "${measured:-N/A}" "阈值未定义" SKIP \
      "profile 未定义该阈值（变量缺失或拼写错误），不能据此判 PASS"
    return
  fi
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
  if ! is_num "$max"; then
    report_row "$section" "$module" "$item" "${measured:-N/A}" "阈值未定义" SKIP \
      "profile 未定义该阈值（变量缺失或拼写错误），不能据此判 PASS"
    return
  fi
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
  if [ -z "$expected" ]; then
    report_row "$section" "$module" "$item" "${measured:-N/A}" "期望值未定义" SKIP \
      "profile 未定义该期望值（变量缺失或拼写错误），不能据此判 PASS"
    return
  fi
  if [ -z "$measured" ]; then
    report_row "$section" "$module" "$item" "N/A" "$expected" SKIP "${note:-未取得实测值}"
  elif [ "$measured" = "$expected" ]; then
    report_row "$section" "$module" "$item" "$measured" "$expected" PASS "$note"
  else
    report_row "$section" "$module" "$item" "$measured" "$expected" FAIL "$note"
  fi
}

# TSV -> CSV，供交付方用 Excel 打开。
# 两个坑：
#   1. 字段里本来就有逗号（"--query-gpu=index,name"），必须按 RFC4180 加引号转义，
#      否则 Excel 会把一行拆成十几列。
#   2. 不带 BOM 的 UTF-8 CSV，Excel 默认按本地编码解，中文全是乱码。
tsv_to_csv() {
  local src="$1" dst="$2"
  printf '\xEF\xBB\xBF' > "$dst"          # UTF-8 BOM
  awk -F'\t' '{
    out="";
    for (i = 1; i <= NF; i++) {
      f = $i;
      gsub(/"/, "\"\"", f);               # 内部双引号翻倍
      if (f ~ /[",]/ || f ~ /\n/) f = "\"" f "\"";
      out = out (i > 1 ? "," : "") f;
    }
    print out;
  }' "$src" >> "$dst"
}

# 按显示宽度对齐的表格输出，替代 column -t。
#
# 不是因为 column -t 对不齐 —— 它是多字节感知的，中文表格排得没问题。
# 真正的理由是依赖：column 来自 bsdextrautils，priority 只是 optional，
# 最小化的 Ubuntu Server live 镜像里可能没有，而原来的回退是 "|| cat"，
# 会把一堵 TSV 墙当成"人读表"交出去。这里只用 awk，没有额外依赖。
#
# 必须在 mawk 下也能跑 —— Ubuntu 的 /usr/bin/awk 默认指向 mawk，而 mawk：
#   - 不支持 gawk 的多维数组 a[i][j]，只能用 a[i SUBSEP j]
#   - length()/substr() 按字节而非字符，逐字符判断宽度的写法直接失效
# 所以宽度用字节数反推：UTF-8 里续字节固定是 0x80-0xBF，
#   字符数 = 字节数 - 续字节数；中日韩字符是 3 字节（2 个续字节），显示占 2 列
#   显示宽度 = 字符数 + 续字节数/2
# 例 "中文abc"：9 字节、4 续字节 -> 5 字符 + 2 = 7 列，正确。
fmt_table() {
  awk -F'\t' '
    function dwidth(s,   t, cont) {
      t = s; cont = gsub(/[\200-\277]/, "", t);
      return (length(s) - cont) + int(cont / 2);
    }
    { for (i = 1; i <= NF; i++) { rows[NR SUBSEP i] = $i;
        if (dwidth($i) > w[i]) w[i] = dwidth($i) }
      if (NF > maxf) maxf = NF; n = NR }
    END{
      for (r = 1; r <= n; r++) {
        line = "";
        for (i = 1; i <= maxf; i++) {
          f = ((r SUBSEP i) in rows) ? rows[r SUBSEP i] : "";
          pad = w[i] - dwidth(f);
          line = line f;
          if (i < maxf) { while (pad-- > 0) line = line " "; line = line "  " }
        }
        sub(/[ \t]+$/, "", line);
        print line;
      }
    }' "$@"
}

# TSV -> 交付用 HTML 判定表（自包含，无任何外部资源）。
#
#   write_html_report <判定表.tsv> <输出.html> <标题> <元信息文件> [每卡明细.tsv]
#
# 两条硬约束：
#   1. 离线环境不能有 CDN / 外链字体 / 外部 CSS，全部内联。
#   2. 命令列里字面含有 "<0-7>"、"<peer_ip>"、"&&"，不转义会被浏览器当标签吞掉 ——
#      交付给甲方的表格上会凭空少掉半条命令。
write_html_report() {
  local tsv="$1" out="$2" title="$3" metafile="$4" pergpu="${5:-}"
  awk -F'\t' -v title="$title" -v metafile="$metafile" -v pergpu="$pergpu" '
    function esc(s) {
      gsub(/&/, "\\&amp;", s); gsub(/</, "\\&lt;", s); gsub(/>/, "\\&gt;", s);
      gsub(/"/, "\\&quot;", s); return s;
    }
    function cls(v) {
      if (v == "PASS")   return "pass";
      if (v == "FAIL")   return "fail";
      if (v == "SKIP")   return "skip";
      return "manual";
    }
    BEGIN {
      print "<!doctype html><html lang=\"zh-CN\"><head><meta charset=\"utf-8\">";
      print "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">";
      print "<title>" esc(title) "</title><style>";
      print ":root{--pass:#137333;--fail:#c5221f;--skip:#b06000;--manual:#5f6368;--line:#dadce0;--bg:#fff;--fg:#202124;--muted:#5f6368;--head:#f1f3f4}";
      print "*{box-sizing:border-box}";
      print "body{margin:0;padding:24px;background:var(--bg);color:var(--fg);font:14px/1.6 -apple-system,\"Noto Sans CJK SC\",\"Source Han Sans SC\",\"Microsoft YaHei\",sans-serif}";
      print ".wrap{max-width:1400px;margin:0 auto}";
      print "h1{font-size:22px;margin:0 0 4px}";
      print "h2{font-size:16px;margin:32px 0 8px;padding-bottom:6px;border-bottom:2px solid var(--line)}";
      print ".meta{display:grid;grid-template-columns:repeat(auto-fit,minmax(240px,1fr));gap:4px 24px;margin:16px 0;color:var(--muted);font-size:13px}";
      print ".meta b{color:var(--fg);font-weight:600}";
      print ".banner{margin:20px 0;padding:16px 20px;border-radius:8px;border-left:6px solid;font-size:18px;font-weight:700}";
      print ".banner.pass{background:#e6f4ea;border-color:var(--pass);color:var(--pass)}";
      print ".banner.fail{background:#fce8e6;border-color:var(--fail);color:var(--fail)}";
      print ".banner.hold{background:#fef7e0;border-color:var(--skip);color:var(--skip)}";
      print ".banner small{display:block;font-size:13px;font-weight:400;margin-top:4px;color:var(--fg)}";
      print ".chips{display:flex;flex-wrap:wrap;gap:8px;margin:12px 0 4px}";
      print ".chip{padding:4px 12px;border-radius:999px;font-size:13px;font-weight:600;border:1px solid}";
      print ".chip.pass{color:var(--pass);border-color:var(--pass);background:#e6f4ea}";
      print ".chip.fail{color:var(--fail);border-color:var(--fail);background:#fce8e6}";
      print ".chip.skip{color:var(--skip);border-color:var(--skip);background:#fef7e0}";
      print ".chip.manual{color:var(--manual);border-color:var(--manual);background:#f1f3f4}";
      print "table{border-collapse:collapse;width:100%;font-size:13px;table-layout:auto}";
      print "th,td{border:1px solid var(--line);padding:7px 9px;text-align:left;vertical-align:top}";
      print "th{background:var(--head);font-weight:600;white-space:nowrap}";
      print "tr.sec td{background:#f8f9fa;font-weight:700;border-top:2px solid var(--line)}";
      print "td.cmd{font-family:ui-monospace,\"DejaVu Sans Mono\",Consolas,monospace;font-size:12px;color:#3c4043;word-break:break-all}";
      print "td.val{font-weight:600;white-space:nowrap}";
      print "td.mgn{text-align:right;white-space:nowrap;font-variant-numeric:tabular-nums}";
      print "td.note{color:var(--muted);font-size:12px}";
      print ".v{display:inline-block;min-width:60px;text-align:center;padding:2px 8px;border-radius:4px;font-weight:700;font-size:12px;color:#fff}";
      print ".v.pass{background:var(--pass)}.v.fail{background:var(--fail)}.v.skip{background:var(--skip)}.v.manual{background:var(--manual)}";
      print "tr.fail td{background:#fef3f2}";
      print ".sign{margin-top:40px;display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:28px}";
      print ".sign div{border-top:1px solid var(--fg);padding-top:6px;font-size:13px;color:var(--muted)}";
      print "footer{margin-top:32px;padding-top:12px;border-top:1px solid var(--line);color:var(--muted);font-size:12px}";
      print "@media print{body{padding:0;font-size:11px}h2{page-break-after:avoid}tr{page-break-inside:avoid}.banner{border:2px solid}}";
      print "</style></head><body><div class=\"wrap\">";
      print "<h1>" esc(title) "</h1>";
      # 元信息（key: value 的纯文本文件）
      if (metafile != "") {
        print "<div class=\"meta\">";
        while ((getline line < metafile) > 0) {
          p = index(line, ":");
          if (p > 0) printf "<div><b>%s</b> %s</div>\n", esc(substr(line,1,p-1)), esc(substr(line,p+1));
        }
        close(metafile);
        print "</div>";
      }
      n_pass=0; n_fail=0; n_skip=0; n_manual=0; nrow=0;
    }
    NR == 1 { for (i=1;i<=NF;i++) hdr[i]=$i; ncol=NF; next }
    {
      nrow++;
      for (i=1;i<=ncol;i++) cell[nrow,i]=$i;
      v=$8;
      if (v=="PASS") n_pass++; else if (v=="FAIL") n_fail++;
      else if (v=="SKIP") n_skip++; else n_manual++;
    }
    END {
      verdict = (n_fail>0) ? "FAIL" : ((n_skip>0) ? "HOLD" : "PASS");
      vcls = (verdict=="FAIL") ? "fail" : ((verdict=="HOLD") ? "hold" : "pass");
      vtext = (verdict=="FAIL") ? "不通过（FAIL）" \
            : ((verdict=="HOLD") ? "暂缓（HOLD）" : "通过（PASS）");
      note = (verdict=="FAIL") ? "存在不达标项，详见下表中标红的行。" \
           : ((verdict=="HOLD") ? "无不达标项，但存在未执行/无法判定的项（SKIP），不足以直接判定通过。" \
           : "全部可自动判定的项均达标。标注「人工核对」的项仍需验收人对照采购清单确认。");
      printf "<div class=\"banner %s\">机器判定：%s<small>%s</small></div>\n", vcls, vtext, note;
      printf "<div class=\"chips\"><span class=\"chip pass\">达标 %d</span>", n_pass;
      printf "<span class=\"chip fail\">不达标 %d</span>", n_fail;
      printf "<span class=\"chip skip\">未判定 %d</span>", n_skip;
      printf "<span class=\"chip manual\">人工核对 %d</span></div>\n", n_manual;

      print "<h2>一、逐项判定</h2><table><thead><tr>";
      for (i=2;i<=ncol;i++) printf "<th>%s</th>", esc(hdr[i]);
      print "</tr></thead><tbody>";
      lastsec="";
      for (r=1;r<=nrow;r++) {
        sec=cell[r,1];
        if (sec != lastsec) {
          printf "<tr class=\"sec\"><td colspan=\"%d\">第 %s 章</td></tr>\n", ncol-1, esc(sec);
          lastsec=sec;
        }
        v=cell[r,8];
        printf "<tr%s>", (v=="FAIL") ? " class=\"fail\"" : "";
        printf "<td>%s</td><td>%s</td>", esc(cell[r,2]), esc(cell[r,3]);
        printf "<td class=\"cmd\">%s</td>", esc(cell[r,4]);
        printf "<td class=\"val\">%s</td><td>%s</td>", esc(cell[r,5]), esc(cell[r,6]);
        printf "<td class=\"mgn\">%s</td>", esc(cell[r,7]);
        printf "<td><span class=\"v %s\">%s</span></td>", cls(v), esc(v);
        printf "<td class=\"note\">%s</td></tr>\n", esc(cell[r,9]);
      }
      print "</tbody></table>";

      if (pergpu != "") {
        first=1;
        while ((getline line < pergpu) > 0) {
          nf = split(line, f, "\t");
          if (first) {
            print "<h2>二、每张 GPU 实测明细</h2><table><thead><tr>";
            for (i=1;i<=nf;i++) printf "<th>%s</th>", esc(f[i]);
            print "</tr></thead><tbody>"; first=0;
          } else {
            print "<tr>";
            for (i=1;i<=nf;i++) printf "<td%s>%s</td>", (i<=2?"":" class=\"cmd\""), esc(f[i]);
            print "</tr>";
          }
        }
        close(pergpu);
        if (!first) print "</tbody></table>";
      }

      print "<div class=\"sign\"><div>验收人签字 / 日期</div><div>交付方签字 / 日期</div><div>见证人签字 / 日期</div></div>";
      print "<footer>本表由 GPU 离线验收工具自动生成，判定依据见 profiles/ 中该机型的阈值档案；";
      print "「未判定」不等于通过。原始日志与命令输出保存在同一日志目录下，可逐条复核。</footer>";
      print "</div></body></html>";
    }
  ' "$tsv" > "$out"
}

# 读采购清单 CSV，取出适用于某台机器的那一行，输出 "列名<TAB>值"。
#
#   csv_row_for <csv> <SN>
#
# 具体 SN 的行优先于通配行 "*"。空值列不输出（= 不参与核对）。
#
# 必须扛住甲方用 Excel 存出来的文件：
#   - UTF-8 BOM：不剥掉的话首列名变成 "﻿SN"，SN 列永远匹配不上
#   - CRLF 换行：不剥掉的话每行最后一个字段带 \r，数值比对全错
#   - 带引号的字段：CPU 型号里出现逗号（"Xeon Platinum 8480+, 2.0GHz"）时
#     朴素按逗号切分会把一行切成两半
csv_row_for() {
  local csv="$1" sn="$2"
  [ -f "$csv" ] || return 1
  awk -v want="$sn" '
    function unq(s) {
      sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s);
      if (s ~ /^".*"$/) { s = substr(s, 2, length(s)-2); gsub(/""/, "\"", s) }
      return s;
    }
    # 按 RFC4180 切分一行，结果放进全局数组 F，返回字段数
    function split_csv(line, arr,   i, c, cur, inq, n) {
      n = 0; cur = ""; inq = 0;
      for (i = 1; i <= length(line); i++) {
        c = substr(line, i, 1);
        if (inq) {
          if (c == "\"") {
            if (substr(line, i+1, 1) == "\"") { cur = cur "\""; i++ }
            else inq = 0;
          } else cur = cur c;
        } else if (c == "\"") inq = 1;
        else if (c == ",") { arr[++n] = cur; cur = "" }
        else cur = cur c;
      }
      arr[++n] = cur;
      return n;
    }
    BEGIN { hdr_done = 0 }
    {
      sub(/\r$/, "");                       # CRLF
      if (NR == 1) sub(/^\xef\xbb\xbf/, ""); # BOM
      if ($0 ~ /^[ \t]*#/ || $0 ~ /^[ \t]*$/) next;
      if (!hdr_done) { nh = split_csv($0, H); hdr_done = 1; next }
      nf = split_csv($0, V);
      key = unq(V[1]);
      if (key == want)      { for (i=2;i<=nh;i++) if (unq(V[i]) != "") exact[unq(H[i])] = unq(V[i]); found_exact=1 }
      else if (key == "*")  { for (i=2;i<=nh;i++) if (unq(V[i]) != "") star[unq(H[i])]  = unq(V[i]) }
    }
    END {
      for (k in star)  if (!(k in exact)) printf "%s\t%s\n", k, star[k];
      for (k in exact) printf "%s\t%s\n", k, exact[k];
    }
  ' "$csv"
}

# 型号类文本比对：忽略大小写、(R)/(TM)/®/™、空格与标点后互相包含即算匹配。
# 清单写 "Intel Xeon 6776P"，机器报 "Intel(R) Xeon(R) 6776P" —— 直接比字符串必然不等。
model_norm() {
  printf '%s' "${1:-}" \
    | tr 'A-Z' 'a-z' \
    | sed -e 's/(r)//g' -e 's/(tm)//g' -e 's/®//g' -e 's/™//g' \
    | tr -cd 'a-z0-9'
}
model_match() { # <实测> <期望>
  local a b
  a="$(model_norm "$1")"; b="$(model_norm "$2")"
  [ -n "$a" ] && [ -n "$b" ] || return 1
  case "$a" in *"$b"*) return 0 ;; esac
  case "$b" in *"$a"*) return 0 ;; esac
  return 1
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
