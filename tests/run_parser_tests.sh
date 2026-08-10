#!/usr/bin/env bash
# 解析器与判定逻辑回归测试 —— 不需要 GPU，也不需要网络。
#
#   bash tests/run_parser_tests.sh
#
# 现场没有第二次机会：判定脚本解析错一个列号，就会把好机器判成 FAIL 或者把坏机器
# 放过去。改动 check_node.sh / check_cluster.sh / lib/common.sh / profiles 之后必跑。
#
# 覆盖四类：
#   1. 全部脚本语法
#   2. 达标输入 -> 不应出现 FAIL（解析对了）
#   3. 逐项劣化输入 -> 对应项必须变 FAIL（阈值真的生效了，不是摆设）
#   4. 环境降级 -> 没有 GPU/工具时脚本不能崩，只能判 SKIP

set -u

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$TEST_DIR/.." && pwd)"

fails=0
ok()  { printf '  [ OK ] %s\n' "$*"; }
bad() { printf '  [FAIL] %s\n' "$*"; fails=$((fails + 1)); }

WORKROOT="$(mktemp -d)"
trap 'rm -rf "$WORKROOT"' EXIT

# ============================================================ 1. 语法
echo "== 1. 语法检查 =="
n_ok=0
for f in "$BASE_DIR"/scripts/*.sh "$BASE_DIR"/scripts/lib/*.sh "$BASE_DIR"/scripts/cluster/*.sh \
         "$BASE_DIR"/bootstrap/*.sh "$BASE_DIR"/bootstrap.sh "$TEST_DIR"/*.sh; do
  [ -f "$f" ] || continue
  if bash -n "$f" 2>/dev/null; then n_ok=$((n_ok + 1)); else bad "$(basename "$f") 语法错误"; fi
done
ok "$n_ok 个脚本语法通过"

# ==================================================== 2. 单机达标输入
echo
echo "== 2. 单机判定（达标输入，b300_8gpu）=="
NODE="$WORKROOT/node"
mkdir -p "$NODE"
cp -r "$TEST_DIR/fixtures/node_b300_pass/"* "$NODE/"
out="$(bash "$BASE_DIR/scripts/check_node.sh" "$NODE" b300_8gpu 2>&1)"

expect_in() {  # <输出> <行关键字> <期望判定>
  local blob="$1" pattern="$2" verdict="$3" line
  line="$(printf '%s\n' "$blob" | grep -F "$pattern" | head -n1)"
  if [ -z "$line" ]; then
    bad "未产出该判定项: $pattern"
  elif printf '%s' "$line" | grep -q "\[$verdict"; then
    ok "$pattern -> $verdict"
  else
    bad "$pattern 期望 $verdict，实得: $(printf '%s' "$line" | tr -s ' ')"
  fi
}

# 每一条都对应一处容易出错的解析
expect_in "$out" "采集权限"        PASS   # root 采集，证据完整
expect_in "$out" "GPU 数量"        PASS   # nvidia-smi -L 计数
expect_in "$out" "系统内存"        PASS   # free -b -> GiB
expect_in "$out" "风扇状态"        PASS
expect_in "$out" "内存识别率"      PASS   # free 实测 / dmidecode 已装，不依赖写死容量
expect_in "$out" "内存条一致性"    PASS   # 分隔符不能用 "/"：频率串本身含 "MT/s"
expect_in "$out" "内存压力测试"    PASS   # 硬件错误要取 "Found N" 的 N，不是数行数   # ipmitool 状态在第 4 列，不是第 3 列
expect_in "$out" "压测 ECC 增量"   PASS   # 按 GPU index 配对求差，不是求和
expect_in "$out" "H2D 带宽"        PASS   # 矩阵要跳过纯整数的列号表头
expect_in "$out" "GPU 间带宽"      PASS   # 非对角最小值，N/A 占位在对角
expect_in "$out" "PCIe Gen/Width"  PASS   # 判 max 不判 current（fixture current 是 Gen1）
expect_in "$out" "单向 P2P 带宽"   PASS   # matrix_block 定位到正确那张矩阵
expect_in "$out" "GPU 间 P2P 延迟" PASS   # 延迟矩阵取非对角最大值
expect_in "$out" "AllReduce"       PASS   # busbw = 倒数第二列
expect_in "$out" "AllGather"       PASS   # 列数与 AllReduce 不同，同一套解析都要对
expect_in "$out" "链路检查"        PASS   # 18 links × 8 GPU = 144
expect_in "$out" "DCGM Level 4"    SKIP   # 未运行 -> SKIP，不是 PASS
expect_in "$out" "满载稳定性"      PASS   # §8 跑满且零掉卡
expect_in "$out" "温度峰值"        PASS   # samples.csv 第一行是表头，必须跳过
expect_in "$out" "温度波动"        PASS   # 波动=单卡 max-min，不是峰值本身
expect_in "$out" "NVLink CRC 增量" PASS

if printf '%s' "$out" | grep -q "FAIL=0"; then
  ok "达标输入无 FAIL"
else
  bad "达标输入出现 FAIL: $(printf '%s' "$out" | grep '合计')"
fi
if printf '%s' "$out" | grep -q "机器判定：HOLD"; then
  ok "有 SKIP 无 FAIL -> HOLD（SKIP 不等于 PASS）"
else
  bad "汇总判定不是 HOLD: $(printf '%s' "$out" | grep '机器判定')"
fi

# =============================================== 3. 逐项劣化：阈值是否真生效
echo
echo "== 3. 劣化输入（每项阈值必须真的拦下来）=="
mutate_expect() {  # <说明> <行关键字> <mutator 函数名>
  local desc="$1" pattern="$2" fn="$3"
  local dir="$WORKROOT/mut_$$_$RANDOM"
  mkdir -p "$dir"
  cp -r "$TEST_DIR/fixtures/node_b300_pass/"* "$dir/"
  "$fn" "$dir"
  local o
  o="$(bash "$BASE_DIR/scripts/check_node.sh" "$dir" b300_8gpu 2>&1)"
  local line
  line="$(printf '%s\n' "$o" | grep -F "$pattern" | head -n1)"
  if printf '%s' "$line" | grep -q '\[FAIL'; then
    ok "$desc -> 判 FAIL"
  else
    bad "$desc 未被拦下: $(printf '%s' "$line" | tr -s ' ')"
  fi
  rm -rf "$dir"
}

m_gpu_count()  { sed -i '$d' "$1/nvidia_smi_L.txt"; }                                  # 只剩 7 张卡
m_ecc_unc()    { sed -i '1s/, 0/, 1/' "$1/q_ecc_uncorrected.txt"; }                    # 出现不可纠正 ECC
m_d2d()        { sed -i 's/795\.44/612.30/' "$1/nvb_d2d.txt"; }                        # NVLink 带宽掉到 612
m_nvlink_down(){ sed -i '3s#.*#         Link 1: <inactive>#' "$1/nvlink_status.txt"; } # 一条链路 inactive
m_driver()     { sed -i 's/610\.43\.02/570.12.01/' "$1/q_driver.txt"; }                # 驱动低于 580.105
m_pcie()       { sed -i 's/, 1, 6, 16, 16/, 1, 5, 16, 16/' "$1/q_pcie.txt"; }          # 链路能力只有 Gen5
m_throttle()   { sed -i 's/HW Thermal Slowdown : Not Active/HW Thermal Slowdown : Active/' "$1/perf_state.txt"; }
m_temp()       { sed -i 's/, 78/, 91/' "$1/temp_after_burn.txt"; }                     # 压测温度 91°C
m_power()      { sed -i 's/1100\.00 W/700.00 W/' "$1/q_power_limit.txt"; }             # TDP 不对
m_allreduce()  { sed -i 's/845\.60/612.10/;s/812\.30/601.00/' "$1/nccl_all_reduce.txt"; }
m_burn_fault() { echo "GPU 3: FAULTY" >> "$1/gpu_burn_1h.txt"; }
m_dcgm_fail()  { printf '{"status" : "Fail"}\n' > "$1/dcgm_diag_r3.txt"; }
m_dcgm_empty() { printf '{"info" : "no tests run"}\n' > "$1/dcgm_diag_r3.txt"; }       # 版本不支持本机 GPU
m_ecc_burn()   { sed -i 's/, 1, 0/, 9, 0/' "$1/ecc_after_burn.txt"; }                  # 单卡增量 9 > 2
m_modprobe()   { echo "options nvidia" > "$1/modprobe_conf.txt"; }                     # 缺 §7 驱动参数
m_fm_down()    { echo "inactive" > "$1/fm_is_active.txt"; }
m_p2p_lat()    { sed -i 's/3\.30/7.80/' "$1/p2p_bw_lat.txt"; }                         # P2P 延迟 7.8us
m_topo()       { sed -i '3s/NV18/NV9/2' "$1/nvidia_smi_topo.txt"; }                    # 拓扑降链
# 连通性矩阵第 3 行是 GPU0 那行，把它最后一个非对角单元格改成 0 = P2P 不通。
# 这条同时守住一个坑：判定必须做数值比较，不能拿 num_min 的输出做字符串比对
# （它按值输出 "1" 或 "1.00"，字符串比对会静默失效）。
m_p2p_access() { sed -i '3s/1$/0/' "$1/p2p_bw_lat.txt"; }
m_p2p_bw()     { sed -i 's/779\.10/640.20/' "$1/p2p_bw_lat.txt"; }                     # 单向 P2P 带宽不达标
m_mem()        { sed -i '1s/293120/270000/' "$1/q_memory_total.txt"; }                 # 单卡显存不足
m_ecc_mode()   { sed -i '1s/Enabled/Disabled/' "$1/q_ecc_mode.txt"; }                  # ECC 未开
m_persist()    { sed -i '1s/Enabled/Disabled/' "$1/q_persistence_after.txt"; }
m_cuda()       { sed -i 's/release 13\.0/release 12.8/' "$1/nvcc_version.txt"; }       # CUDA 低于 13.0
m_peermem()    { : > "$1/lsmod_peermem.txt"; }                                          # nvidia_peermem 未加载
m_xid()        { echo "[12345.6] NVRM: Xid (PCI:0000:1a:00): 79, GPU has fallen off the bus" \
                   > "$1/dmesg_gpu_after.txt"; }
# 少一条 128GiB DIMM：24×128=3072 -> 23×128=2944。
# 这条守的是一个真实盲区：阈值定在 2900 时 2944 会被判 PASS，掉内存漏检。
m_dimm()       { printf 'Mem:  3161095929856  1000  2000\n' > "$1/free_b.txt"; }
# 内存相关的三条：不依赖写死容量，换配置照样有效
# 一条内存条已装但没被系统认出来 -> 识别率掉到 95.8%
m_mem_undetected() { printf 'Mem:  3161095929856  1000  2000\n' > "$1/free_b.txt"; }
# 混插：24 条里有 4 条是 96GB
m_mem_mixed()  { sed -i '0~6s/Size: 128 GB/Size: 96 GB/' "$1/dmidecode_memory_full.txt"; }
# 内存压测报出硬件错误
m_mem_stress() { printf 'Stats: Found 3 hardware incidents\nStatus: PASS\n' > "$1/mem_stress.txt"; }
# 压测出现 miscompare（Status 仍打 PASS 也不能放过）
m_mem_miscmp() { printf 'Hardware Error: miscompare on CPU 3\nStats: Found 0 hardware incidents\nStatus: PASS\n' > "$1/mem_stress.txt"; }
# 忘了 sudo：一堆项静默变 SKIP，判定表必须把"证据不完整"本身标成 FAIL，
# 而不是让人从散落的 SKIP 里自己推断。
m_nonroot()    { echo "collected as non-root (uid=1000)" > "$1/WARNING_NOT_ROOT.txt"; }
# §8 长稳：被中断的那次必须判 FAIL，而不是按计划时长当成跑完了
m_soak_short() { echo 7200 > "$1/soak/duration_actual_seconds.txt"; }
m_soak_temp()  { sed -i 's/,78,/,91,/' "$1/soak/samples.csv"; }          # 峰值超 86
m_soak_fluct() { awk -F',' 'NR==1{print;next}{if(NR%9==0)$3=70; print $1","$2","$3","$4","$5","$6","$7}' \
                   "$1/soak/samples.csv" > "$1/soak/s.tmp" && mv "$1/soak/s.tmp" "$1/soak/samples.csv"; }
m_soak_xid()   { echo 4 > "$1/soak/xid_delta.txt"; }
m_soak_crc()   { echo 12 > "$1/soak/nvlink_crc_delta.txt"; }

mutate_expect "GPU 少一张"          "GPU 数量"        m_gpu_count
mutate_expect "出现不可纠正 ECC"    "不可纠正错误"    m_ecc_unc
mutate_expect "NVLink 带宽不达标"   "GPU 间带宽"      m_d2d
mutate_expect "NVLink 链路 inactive" "链路检查"       m_nvlink_down
mutate_expect "驱动版本过低"        "驱动"            m_driver
mutate_expect "PCIe 只有 Gen5"      "PCIe Gen/Width"  m_pcie
mutate_expect "出现热节流"          "节流原因"        m_throttle
mutate_expect "压测温度 91°C"       "GPU 温度"        m_temp
mutate_expect "TDP 不是 1100W"      "TDP"             m_power
mutate_expect "AllReduce 不达标"    "AllReduce"       m_allreduce
mutate_expect "gpu_burn 报 FAULTY"  "1 小时压测"      m_burn_fault
mutate_expect "DCGM 有 Fail"        "DCGM Level 3"    m_dcgm_fail
mutate_expect "DCGM 没真正跑测试"   "DCGM Level 3"    m_dcgm_empty
mutate_expect "单卡 ECC 增量超标"   "压测 ECC 增量"   m_ecc_burn
mutate_expect "缺 §7 驱动参数"      "内核模块参数"    m_modprobe
mutate_expect "Fabric Manager 未运行" "FM 状态"       m_fm_down
mutate_expect "P2P 延迟 7.8us"      "P2P 延迟"        m_p2p_lat
mutate_expect "NVLink 拓扑降链"     "拓扑验证"        m_topo
mutate_expect "P2P 有一对不通"      "P2P Access"      m_p2p_access
mutate_expect "单向 P2P 带宽不达标" "单向 P2P 带宽"   m_p2p_bw
mutate_expect "单卡显存不足"        "单卡显存"        m_mem
mutate_expect "ECC 未开启"          "ECC 状态确认"    m_ecc_mode
mutate_expect "持久模式未开"        "Persistence"     m_persist
mutate_expect "CUDA 低于 13.0"      "CUDA"            m_cuda
mutate_expect "nvidia_peermem 未加载" "nvidia_peermem" m_peermem
mutate_expect "内核日志有 XID/掉卡" "内核日志"        m_xid
mutate_expect "少一条 128G 内存条"  "内存识别率"      m_mem_undetected
mutate_expect "内存条混插 96/128G"  "内存条一致性"    m_mem_mixed
mutate_expect "内存压测报硬件错误"  "内存压力测试"    m_mem_stress
mutate_expect "内存压测出现 miscompare" "内存压力测试" m_mem_miscmp
mutate_expect "非 root 采集"        "采集权限"        m_nonroot
mutate_expect "长稳被中断未跑完"    "满载稳定性"      m_soak_short
mutate_expect "长稳温度峰值 91°C"   "温度峰值"        m_soak_temp
mutate_expect "长稳温度波动超标"    "温度波动"        m_soak_fluct
mutate_expect "长稳出现 XID"        "XID 增量"        m_soak_xid
mutate_expect "长稳 NVLink CRC 增长" "NVLink CRC 增量" m_soak_crc

# 特殊一类：驱动返回 N/A。这不是"合格"也不是"不合格"，是"没有数据"，
# 必须判 SKIP —— 早期实现会把 "[N/A]" 当成 0，直接给出假 PASS。
expect_verdict() {  # <说明> <行关键字> <mutator> <期望判定>
  local desc="$1" pattern="$2" fn="$3" want="$4"
  local dir="$WORKROOT/na_$$_$RANDOM"
  mkdir -p "$dir"
  cp -r "$TEST_DIR/fixtures/node_b300_pass/"* "$dir/"
  "$fn" "$dir"
  local line
  line="$(bash "$BASE_DIR/scripts/check_node.sh" "$dir" b300_8gpu 2>&1 | grep -F "$pattern" | head -n1)"
  if printf '%s' "$line" | grep -q "\[$want"; then
    ok "$desc -> 判 $want"
  else
    bad "$desc 期望 $want，实得: $(printf '%s' "$line" | tr -s ' ')"
  fi
  rm -rf "$dir"
}
m_ecc_na()  { sed -i 's/, 0$/, [N\/A]/' "$1/q_ecc_uncorrected.txt"; }
m_eccm_na() { sed -i 's/, Enabled$/, [N\/A]/' "$1/q_ecc_mode.txt"; }
expect_verdict "ECC 计数返回 N/A"   "不可纠正错误"    m_ecc_na  SKIP
expect_verdict "ECC 模式返回 N/A"   "ECC 状态确认"    m_eccm_na SKIP

# 报表结构：必须给出准确数值和可复现的命令，而不是 yes/no
if grep -q '测试手段/命令' "$NODE/acceptance_report.tsv" && grep -q '余量' "$NODE/acceptance_report.tsv"; then
  ok "报表含「测试手段/命令」与「余量」列"
else
  bad "报表缺少命令列或余量列"
fi
if grep -P '\t8/8 Enabled\t' "$NODE/acceptance_report.tsv" >/dev/null 2>&1; then
  ok "定性项已数值化（ECC 状态输出 8/8 而非「全部 Enabled」）"
else
  bad "定性项仍是「全部 xxx」这类说不出数的表述"
fi
if grep -q '+5.7%' "$NODE/acceptance_report.tsv"; then
  ok "余量按百分比计算（AllReduce 845.60 vs 800 = +5.7%）"
else
  bad "余量列计算不正确"
fi
if [ -s "$NODE/per_gpu_detail.tsv" ] && [ "$(wc -l < "$NODE/per_gpu_detail.tsv")" -eq 9 ]; then
  ok "每卡明细表 8 行 + 表头，含 SN/UUID/显存/功耗/时钟/NVLink"
else
  bad "每卡明细表缺失或行数不对"
fi

# 不指定 profile 时应回落到日志目录里记录的 profile.env（现场复核旧日志的路径）。
# fixture 里的 profile.env 是 profiles/b300_8gpu.env 的快照，会随主档案漂移 ——
# 这条同时充当漂移告警。
if diff -q "$TEST_DIR/fixtures/node_b300_pass/profile.env" \
           "$BASE_DIR/profiles/b300_8gpu.env" >/dev/null 2>&1; then
  ok "fixture 的 profile.env 与主档案一致"
else
  bad "fixture 的 profile.env 已与 profiles/b300_8gpu.env 漂移，执行：cp profiles/b300_8gpu.env tests/fixtures/node_b300_pass/profile.env"
fi
outr="$(bash "$BASE_DIR/scripts/check_node.sh" "$NODE" 2>&1)"
if printf '%s' "$outr" | grep -q '机器判定'; then
  ok "不带 profile 参数时回落到日志目录记录的 profile.env"
else
  bad "不带 profile 参数时无法完成判定"
fi

# 阈值缺失必须判 SKIP，绝不能判 PASS。
# 这是整套系统最危险的一类失效：变量名拼错或 profile 少一行时，awk 把空串当 0，
# 于是"实测 >= 0"恒成立，检查项静默退化成橡皮图章 —— 比崩溃糟，因为崩溃看得见。
STRIP="$WORKROOT/stripped"
mkdir -p "$STRIP"
cp -r "$TEST_DIR/fixtures/node_b300_pass/"* "$STRIP/"
grep -vE '^(SYS_MEM_MIN_TB|SYS_MEM_DETECT_MIN_PCT|NVB_D2D_READ_MIN_GBS|P2P_LAT_MAX_US)=' \
  "$BASE_DIR/profiles/b300_8gpu.env" > "$STRIP/profile.env"
outs="$(bash "$BASE_DIR/scripts/check_node.sh" "$STRIP" 2>&1)"
for item in "系统内存" "内存识别率" "GPU 间带宽" "GPU 间 P2P 延迟"; do
  line="$(printf '%s\n' "$outs" | grep -F "$item" | head -n1)"
  if printf '%s' "$line" | grep -q '\[SKIP'; then
    ok "阈值缺失时「$item」判 SKIP"
  else
    bad "阈值缺失时「$item」未判 SKIP，实得: $(printf '%s' "$line" | tr -s ' ')"
  fi
done
# 旧快照缺变量时不能崩（set -u 下会中途死掉，只留半张表）
if printf '%s' "$outs" | grep -q '机器判定' && printf '%s' "$outs" | grep -q '缺少以下变量'; then
  ok "旧 profile 快照：不崩溃，且明确提示缺失变量"
else
  bad "旧 profile 快照处理有问题（崩溃或未提示）"
fi

# 输出层：CSV 交付 + 无外部依赖的表格排版
if [ -s "$NODE/acceptance_report.csv" ]; then
  # Excel 按本地编码解无 BOM 的 UTF-8，中文会全乱码
  if head -c3 "$NODE/acceptance_report.csv" | od -An -tx1 | grep -q 'ef bb bf'; then
    ok "CSV 带 UTF-8 BOM（Excel 直接打开不乱码）"
  else
    bad "CSV 缺少 UTF-8 BOM"
  fi
  # 字段里本来就含逗号（--query-gpu=index,name），必须加引号，否则 Excel 拆错列
  if grep -q '"nvidia-smi --query-gpu=index,name' "$NODE/acceptance_report.csv" \
     || grep -qE '"[^"]*,[^"]*"' "$NODE/acceptance_report.csv"; then
    ok "含逗号的字段已按 RFC4180 加引号"
  else
    bad "含逗号的字段未加引号，Excel 会拆错列"
  fi
  # 列数必须与 TSV 一致（用 python 按 CSV 规则解析，而不是简单数逗号）
  if command -v python3 >/dev/null 2>&1; then
    ncsv="$(python3 -c "
import csv,sys
with open('$NODE/acceptance_report.csv',encoding='utf-8-sig') as f:
    print(len(next(csv.reader(f))))")"
    ntsv="$(head -n1 "$NODE/acceptance_report.tsv" | awk -F'\t' '{print NF}')"
    if [ "$ncsv" = "$ntsv" ]; then
      ok "CSV 列数与 TSV 一致（$ncsv 列）"
    else
      bad "CSV 列数 $ncsv 与 TSV 列数 $ntsv 不符"
    fi
  fi
else
  bad "未生成交付用 CSV"
fi
# fmt_table 与 column -t 输出应当一致（等价性），且不依赖 bsdextrautils
if command -v column >/dev/null 2>&1; then
  # 行尾空白不比较：column 保留末列 padding，fmt_table 去掉，两者都无碍阅读
  a="$(head -n8 "$NODE/acceptance_report.tsv" | column -t -s "$(printf '\t')" | sed 's/[[:space:]]*$//')"
  b="$(head -n8 "$NODE/acceptance_report.tsv" | { . "$BASE_DIR/scripts/lib/common.sh"; fmt_table; } | sed 's/[[:space:]]*$//')"
  if [ "$a" = "$b" ]; then
    ok "fmt_table 与 column -t 输出一致（且不依赖 bsdextrautils）"
  else
    bad "fmt_table 与 column -t 输出不一致"
  fi
fi

# ==================================================== 4. profile 切换
echo
echo "== 4. profile 切换（阈值来自 profile，不是硬编码）=="
out2="$(bash "$BASE_DIR/scripts/check_node.sh" "$NODE" h200_8gpu 2>&1)"
if printf '%s' "$out2" | grep -F "TDP" | grep -q '\[FAIL'; then
  ok "同一份日志换 h200 profile 后 TDP 判 FAIL（1100W 卡 vs 700W 阈值）"
else
  bad "换 profile 后 TDP 判定未变，阈值可能被硬编码"
fi
if printf '%s' "$out2" | grep -F "GPU 间带宽" | grep -q '\[PASS'; then
  ok "同一份日志换 h200 profile 后 NVLink 带宽判 PASS（795 > 350 阈值）"
else
  bad "换 profile 后 NVLink 带宽判定异常"
fi

# ================================================== 5. 多机判定
echo
echo "== 5. 多机判定（§5 RoCE + §6 跨节点）=="
CL="$WORKROOT/cluster"
mkdir -p "$CL"
cp -r "$TEST_DIR/fixtures/cluster_pass/"* "$CL/"
outc="$(bash "$BASE_DIR/scripts/cluster/check_cluster.sh" "$CL" b300_8gpu 2>&1)"

expect_in "$outc" "Ethernet 模式确认" PASS  # grep -c 多文件会每文件一行计数，必须先 cat
expect_in "$outc" "全端口活跃"        PASS
expect_in "$outc" "QoS 标记"          PASS  # trust state: dscp
expect_in "$outc" "巨帧"              PASS  # MTU 9000
expect_in "$outc" "rx_discards"       PASS
expect_in "$outc" "单 NIC 写带宽"     PASS  # perftest 的 BW average 是倒数第二列
expect_in "$outc" "GPUDirect RDMA"    PASS
expect_in "$outc" "小消息延迟"        PASS
expect_in "$outc" "2 节点 16 GPU AllReduce" PASS
expect_in "$outc" "8 节点 64 GPU AllReduce" PASS
expect_in "$outc" "16 节点 128 GPU AllReduce" SKIP   # hostfile 不够 16 台 -> SKIP 不是 PASS
expect_in "$outc" "纯 RoCE AllReduce" PASS
if printf '%s' "$outc" | grep -q "FAIL=0"; then
  ok "多机达标输入无 FAIL"
else
  bad "多机达标输入出现 FAIL: $(printf '%s' "$outc" | grep '合计')"
fi

# 多机劣化：4 节点带宽掉下去必须被拦
CLM="$WORKROOT/cluster_bad"
mkdir -p "$CLM"
cp -r "$TEST_DIR/fixtures/cluster_pass/"* "$CLM/"
sed -i 's/721\.10/510.00/g' "$CLM/cluster/allreduce_4n.txt"
sed -i 's/471\.88/312.00/' "$CLM/roce/ib_write_bw.txt"
outcm="$(bash "$BASE_DIR/scripts/cluster/check_cluster.sh" "$CLM" b300_8gpu 2>&1)"
printf '%s' "$outcm" | grep -F "4 节点 32 GPU AllReduce" | grep -q '\[FAIL' \
  && ok "4 节点 AllReduce 不达标 -> 判 FAIL" || bad "4 节点 AllReduce 劣化未被拦下"
printf '%s' "$outcm" | grep -F "单 NIC 写带宽" | grep -q '\[FAIL' \
  && ok "RoCE 写带宽不达标 -> 判 FAIL" || bad "RoCE 写带宽劣化未被拦下"

# =============================================== 6. 环境降级（本机无 GPU）
echo
echo "== 6. 环境降级（无 GPU / 无工具时不能崩）=="
EMPTY="$WORKROOT/empty"
mkdir -p "$EMPTY"
if oute="$(bash "$BASE_DIR/scripts/check_node.sh" "$EMPTY" b300_8gpu 2>&1)"; then :; fi
if printf '%s' "$oute" | grep -q '机器判定'; then
  ok "空日志目录仍能产出判定表（不崩）"
else
  bad "空日志目录导致判定脚本异常: $(printf '%s' "$oute" | tail -n3)"
fi
if printf '%s' "$oute" | grep -F "GPU 数量" | grep -q '\[FAIL'; then
  ok "空目录时 GPU 数量判 FAIL（不会因为没数据就放过）"
else
  bad "空目录时 GPU 数量未判 FAIL"
fi

outp="$(bash "$BASE_DIR/scripts/preflight.sh" b300_8gpu 2>&1)"; rc=$?
if printf '%s' "$outp" | grep -q 'nvidia-smi 不存在\|GPU 数量'; then
  ok "preflight 在无 GPU 主机上给出明确阻断说明（exit=$rc）"
else
  bad "preflight 在无 GPU 主机上的输出不符合预期"
fi
rm -rf "$BASE_DIR"/logs/*_preflight 2>/dev/null || true

# 采集与解析必须在 C locale 下：中文环境 free 打的是 "内存：" 而非 "Mem:"，
# 解析器一无所获，对应项静默变 SKIP —— 判定表照出，只是少了覆盖。
if ( . "$BASE_DIR/scripts/lib/common.sh"; [ "$LC_ALL" = "C" ] ); then
  ok "共用库钉死 LC_ALL=C（工具输出不随系统语言变化）"
else
  bad "共用库未钉死 locale"
fi
if grep -q 'export LC_ALL=C LANG=C; \$command' "$BASE_DIR/scripts/lib/common.sh"; then
  ok "run_shell 在登录 shell 内重新钉死 locale（profile 可能改回去）"
else
  bad "run_shell 未防住 profile 重置 locale"
fi

# ================================================== 7. 同批次比对
echo
echo "== 7. 同批次比对（跨机器找掉队的那台）=="
BATCH="$WORKROOT/batch"
for i in 1 2 3 4; do
  d="$BATCH/2026-08-10_10000${i}_SN000${i}"
  mkdir -p "$d"; cp -r "$TEST_DIR/fixtures/node_b300_pass/"* "$d/"
  # 批次比对通常在长稳之前做，这里去掉 soak/ 以模拟"温度峰值尚无数据"，
  # 顺便验证配置了却匹配不到的指标会被显式列出而不是静默跳过。
  rm -rf "$d/soak"
  printf 'Host SN: SN000%d\n' "$i" > "$d/session.txt"
  # 第 4 台：NVLink 带宽与 AllReduce 都比同批低 ~12%，但每项仍在绝对阈值之上
  if [ "$i" = "4" ]; then
    sed -i 's/795\.44/697.20/;s/801\.23/700.10/;s/800\.10/699.50/' "$d/nvb_d2d.txt"
    sed -i 's/845\.60/742.30/;s/812\.30/735.00/' "$d/nccl_all_reduce.txt"
  fi
  bash "$BASE_DIR/scripts/check_node.sh" "$d" b300_8gpu >/dev/null 2>&1
done
outb="$(OUT_DIR="$WORKROOT/reports" bash "$BASE_DIR/scripts/compare_batch.sh" "$BATCH" b300_8gpu 2>&1)"
brc=$?
if printf '%s' "$outb" | grep -q '4 台机器'; then
  ok "自动发现并汇总 4 台机器的判定表"
else
  bad "未能收集到 4 台机器"
fi
# 掉队机器每项都过了绝对阈值，只有横向比对才看得出来
if printf '%s' "$outb" | grep -A5 '掉队清单' | grep -q 'SN0004'; then
  ok "识别出掉队机器 SN0004（各项均过绝对阈值，仅同批次比对能发现）"
else
  bad "未识别出掉队机器"
fi
if printf '%s' "$outb" | grep -A5 '掉队清单' | grep -q 'SN0001\|SN0002\|SN0003'; then
  bad "正常机器被误判为掉队"
else
  ok "正常机器未被误判"
fi
# 配置了却匹配不到的指标必须出声，不能静默消失
if printf '%s' "$outb" | grep -q '未参与比对'; then
  ok "无数据的指标被显式列出（不会静默跳过）"
else
  bad "无数据的指标被静默跳过了"
fi
if [ "$brc" -ne 0 ]; then
  ok "存在掉队机器时退出码非 0（可用于流水线拦截）"
else
  bad "存在掉队机器但退出码为 0"
fi

# ====================================== 8. 真驱动 smoke test（有 nvidia-smi 才跑）
echo
echo "== 8. 真驱动 smoke test =="
if ! command -v nvidia-smi >/dev/null 2>&1; then
  echo "  (跳过：本机没有 nvidia-smi)"
else
  # 采集脚本用到的每个 --query-gpu 字段名都必须被驱动接受。写错一个字段，
  # 现场表现是整行判 SKIP，而不是报错，很容易被忽略过去。
  bad_fields=""
  for f in memory.total ecc.mode.current ecc.errors.uncorrected.aggregate.total \
           ecc.errors.corrected.volatile.total power.limit persistence_mode \
           clocks.current.graphics clocks.max.graphics clocks_throttle_reasons.active \
           pcie.link.gen.current pcie.link.gen.max pcie.link.width.current \
           pcie.link.width.max driver_version temperature.gpu power.draw \
           utilization.gpu vbios_version serial name uuid; do
    if nvidia-smi --query-gpu="$f" --format=csv,noheader 2>&1 | head -1 \
       | grep -qi 'not a valid\|invalid\|is not a valid field'; then
      bad_fields="$bad_fields $f"
    fi
  done
  if [ -z "$bad_fields" ]; then
    ok "全部 --query-gpu 字段被驱动 $(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1) 接受"
  else
    bad "驱动不认识这些字段:$bad_fields"
  fi

  # 长稳烤机的后台进程回收：跑 8 秒然后确认没有残留的采样器。
  # GNU timeout 默认把子进程放进自己新建的进程组，按作业进程组回收够不着它，
  # 被中断的 18h 烤机会留下一个一直在跑的 nvidia-smi dmon。
  # pgrep -c 找不到时会「打印 0 并且退出码非 0」，用 || echo 0 会得到两行 "0"。
  before="$(pgrep -fc 'nvidia-smi dmon' 2>/dev/null | head -n1)"; before="${before:-0}"
  SOAKDIR="$WORKROOT/soak"; mkdir -p "$SOAKDIR"
  SOAK_SECONDS_OVERRIDE=8 timeout 120 bash "$BASE_DIR/scripts/soak_node.sh" \
    "$SOAKDIR" b300_8gpu >"$WORKROOT/soak.log" 2>&1
  src=$?
  sleep 2
  after="$(pgrep -fc 'nvidia-smi dmon' 2>/dev/null | head -n1)"; after="${after:-0}"
  if [ "$after" -le "$before" ]; then
    ok "8 秒长稳跑完无残留后台进程（exit=$src）"
  else
    bad "长稳结束后残留 $((after - before)) 个 nvidia-smi dmon 进程"
  fi
  if [ -s "$SOAKDIR/soak/samples.csv" ] && [ -s "$SOAKDIR/soak/xid_delta.txt" ]; then
    ok "长稳产出 samples.csv 与增量快照"
  else
    bad "长稳未产出 samples.csv / 增量快照"
  fi
fi

echo
if [ "$fails" -eq 0 ]; then
  echo "全部通过。"
  exit 0
fi
echo "$fails 项失败。"
exit 1
