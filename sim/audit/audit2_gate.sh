#!/usr/bin/env bash
#==============================================================================
# audit2_gate.sh —— AUDIT2 报告门禁（只读；不触碰任何 RTL/TB/脚本）
#------------------------------------------------------------------------------
# 判据：
#   G1 报告头含冻结基准 git 哈希（40 hex）与基准 d00eb03；
#   G2 指令语义覆盖表行数 ≥ 15（行首形如 `| <数字> |`）；
#   G3 差异清单含 Tier 标注 ≥ 1 条，且差异/证据含 文件.v:行号 ≥ 5 行；
#   G4 五节标题齐（覆盖表/差异/未涵盖/排除/复现命令）；
#   G5 末尾锚点 `AUDIT2: PASS` 存在（且为最后一行非空内容）。
# 退出码：0 = PASS；非 0 = FAIL（逐条打印）。
#==============================================================================
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REP="$HERE/audit2_report.md"
fail=0
say() { printf '%s\n' "$*"; }
chk() { if [ "$1" = "1" ]; then say "  [OK]   $2"; else say "  [FAIL] $2"; fail=1; fi; }
# grep 命中 ⇒ OK
chkg() { if grep -qE "$1" "$REP"; then chk 1 "$2"; else chk 0 "$2"; fi; }

[ -f "$REP" ] || { say "report not found: $REP"; exit 2; }

# G1 冻结基准
n_hash=$(grep -Eo '\b[0-9a-f]{40}\b' "$REP" | sort -u | wc -l | tr -d ' ')
chk "$([ "$n_hash" -ge 1 ] && echo 1 || echo 0)" "G1 git 哈希存在（$n_hash 个唯一 40-hex）"
chkg 'd00eb03' "G1 冻结基准 d00eb03 已登记"

# G2 指令条数
n_instr=$(grep -cE '^\| *[0-9]+ *\|' "$REP")
chk "$([ "$n_instr" -ge 15 ] && echo 1 || echo 0)" "G2 指令语义覆盖表 $n_instr 条（要求 ≥15）"

# G3 差异清单：Tier 标注 + 证据行号
n_tier=$(grep -cE 'Tier|\【(严重|中|低)' "$REP")
chk "$([ "$n_tier" -ge 1 ] && echo 1 || echo 0)" "G3 差异清单 Tier 标注 $n_tier 处"
n_evid=$(grep -cE '\.v:[0-9]+' "$REP")
chk "$([ "$n_evid" -ge 5 ] && echo 1 || echo 0)" "G3 差异/证据含 文件.v:行号（$n_evid 行）"

# G4 五节
for sec in '① 指令语义覆盖表' '② 确定差异清单' '③ 未涵盖清单' '④ 排除清单' '⑤ 复现命令'; do
  chkg "$sec" "G4 节存在：$sec"
done

# G5 锚点（必须是报告最后一行非空内容）
last=$(grep -v '^[[:space:]]*$' "$REP" | tail -1)
[ "$last" = "**AUDIT2: PASS**" ] && a=1 || a=0
chk "$a" "G5 末行锚点 = **AUDIT2: PASS**（实际：$last）"

if [ "$fail" = "0" ]; then
  say "AUDIT2: PASS"
  exit 0
else
  say "AUDIT2: FAIL"
  exit 1
fi
