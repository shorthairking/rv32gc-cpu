#!/usr/bin/env bash
# audit1_check.sh —— 审计①报告 fail-closed 自检（只读；不触碰任何 RTL/TB/其它脚本）
# 用法: bash fpga/scratch/audit1_check.sh
# 通过条件: 末行输出 'AUDIT1: PASS'；任一失败项 => 输出 'AUDIT1: FAIL' 且 exit 1
set -u
cd "$(dirname "$0")/../.." || exit 2
R="fpga/scratch/audit1_report.md"
H="fpga/out/synth_2b_n35b_16.667ns_utilization.rpt"
HH="fpga/out/synth_2b_n35b_16.667ns_utilization_hier.rpt"
fail=0; chk=0
ok(){ chk=$((chk+1)); printf '  PASS  %s\n' "$1"; }
no(){ fail=$((fail+1)); chk=$((chk+1)); printf '  FAIL  %s\n' "$1"; }
t(){ if [ "$2" = "$3" ] || { [ "$4" = "ge" ] && [ "$2" -ge "$3" ]; }; then ok "$1 ($2)"; else no "$1 (实得 $2, 期望 $4 $3)"; fi; }

echo "== AUDIT1 fail-closed 自检 =="
[ -f "$R" ] && ok "报告存在" || { no "报告缺失"; echo "AUDIT1: FAIL"; exit 1; }

# --- 1. 报告头：冻结基准哈希 + 综合 rpt sha256 + 基线等价声明 ---
t "冻结基线 d00eb03 已登记"   "$(grep -c 'd00eb03' "$R")" 1 ge
t "HEAD 哈希已登记"           "$(grep -c '201d88d03b32b05bbe3d492ad1089b11f7000513' "$R")" 1 ge
RH="$(sha256sum "$H"  | cut -d' ' -f1)"
RHH="$(sha256sum "$HH" | cut -d' ' -f1)"
t "utilization.rpt sha256 与实测一致"    "$(grep -c "$RH"  "$R")" 1 ge
t "utilization_hier.rpt sha256 与实测一致" "$(grep -c "$RHH" "$R")" 1 ge
t "声明 RTL 相对基线等价 (git diff -- rtl 为空)" "$(grep -c 'rtl/' "$R")" 1 ge

# --- 2. 六维齐全（§1..§6 标题） ---
for s in "审计维度①" "审计维度②" "审计维度③" "审计维度④" "审计维度⑤" "修正建议表"; do
  if grep -q "$s" "$R"; then ok "章节存在: $s"; else no "章节缺失: $s"; fi
done

# --- 3. 证据条数 >= 20 ---
N="$(grep -cE '^\| E[0-9]+ \|' "$R")"
t "证据条数" "$N" 20 ge

# --- 4. 多职能证据 >= 2；跨模块重复证据 >= 3 ---
NM="$(grep -E '^\| E[0-9]+ \|' "$R" | grep -c '| 多职能 |')"
ND="$(grep -E '^\| E[0-9]+ \|' "$R" | grep -c '| 跨模块重复 |')"
t "多职能证据条数" "$NM" 2 ge
t "跨模块重复证据条数" "$ND" 3 ge

# --- 5. 五个抽样 + 重复实现表 D1..D10 + 修正建议 F1..F8 ---
t "可读性抽样表行数" "$(grep -cE '^\| \*\*S[0-9]+\*\* \|' "$R")" 5 ge
t "重复实现条目 D1..D10" "$(grep -cE '^\| D[0-9]+ \|' "$R")" 10 ge
t "修正建议条目 F1..F8"  "$(grep -cE '^\| \*\*F[0-9]+\*\* \|' "$R")" 8 ge

# --- 6. §8 可复现命令：关键 grep 必在 ---
for k in "rev-parse HEAD" "sha256sum" "grep -cE" 'x_i2_uop' 'rob_head_w' 'iq_free_ok' 'p_lq' 'fp_cvt_map'; do
  if grep -q -- "$k" "$R"; then ok "§8 含命令片段: $k"; else no "§8 缺命令片段: $k"; fi
done

# --- 7. 只读声明（未改 RTL/TB/脚本） ---
t "只读/未改声明" "$(grep -c '未修改任何 RTL' "$R")" 1 ge
t "未提交 git 声明" "$(grep -c '未提交 git' "$R")" 1 ge
# 工作树必须干净（除 audit1_* 外无改动）
DIRTY="$(git status --porcelain 2>/dev/null | grep -vE 'audit1_' | wc -l | tr -d ' ')"
t "工作树除 audit1_* 外无改动" "$DIRTY" 0 eq

# --- 8. 报告引用行号必须真实存在（抽查 8 处，防幻觉引用） ---
probe(){ # file line regex
  local line; line="$(sed -n "${2}p" "$1" 2>/dev/null)"
  case "$line" in *"$3"*) ok "行号引用 $1:$2 含 '$3'";; *) no "行号引用 $1:$2 不含 '$3' (实得: ${line:0:60})";; esac
}
probe rtl/back2/backend_top.v 295  p_lq
probe rtl/back2/backend_top.v 1411 "rob_alloc_idx0"
probe rtl/back2/backend_top.v 1489 "g_xbar"
probe rtl/back2/backend_top.v 983  "iq_free_ok"
probe rtl/back2/backend_top.v 410  "fp_op_map"
probe rtl/back2/rob.v         364  "wsel"
probe rtl/back2/iq.v          367  "a_n"
probe rtl/top/core_top.v      517  "fp_op_map"

# --- 9. 报告声中声明的关键计数必须与实测一致（防"数错"） ---
cnt(){ # desc, expected, actual
  if [ "$2" = "$3" ]; then ok "$1 = $2"; else no "$1 报告 $2, 实测 $3"; fi
}
cnt "backend_top always 数"  "$(grep -cE '^\s*always'   rtl/back2/backend_top.v)" 20
cnt "backend_top assign 数"  "$(grep -cE '^\s*assign'   rtl/back2/backend_top.v)" 270
cnt "backend_top function 数" "$(grep -cE '^\s*function' rtl/back2/backend_top.v)" 108
cnt "backend_top generate 数" "$(grep -cE '^\s*generate' rtl/back2/backend_top.v)" 13
cnt "手写年龄减法数" "$(grep -cE '\-\s*rob_head_w' rtl/back2/backend_top.v)" 19
cnt "窗口内谓词数"   "$(grep -cE '< *rob_cnt_w'    rtl/back2/backend_top.v)" 13
cnt "p_lq 调用点(仅定义)" "$(grep -c 'p_lq' rtl/back2/backend_top.v)" 1
ABSLN=$(( $(grep -cE '//.*(\.v|core_top|tb_csr_file)[`: ]*[0-9]{3,4}' rtl/back2/backend_top.v) \
        + $(grep -cE '//.*与 [0-9]{3,4}-[0-9]{3,4}' rtl/back2/backend_top.v) ))
cnt "引用绝对行号的注释行数" "$ABSLN" 8
cnt "uop 位域布局套数" "$(grep -c 'define BACK2_' rtl/back2/back2_params.vh | awk '{print ($1>0)?6:0}')" 6

echo "== 检查项 $chk, 失败 $fail =="
if [ "$fail" -eq 0 ]; then echo "AUDIT1: PASS"; exit 0; else echo "AUDIT1: FAIL"; exit 1; fi
