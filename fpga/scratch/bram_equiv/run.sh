#!/usr/bin/env bash
#==============================================================================
# fpga/scratch/bram_equiv/run.sh —— BRAM 双分支（IP vs 行为模型）逐拍等价对拍
#==============================================================================
# 判据（fail-closed，未捕获即失败）：编译 rc=0 且输出**整行命中** "BRAM_EQUIV PASS"
#   且捕获到 checks=/errors= 且 errors==0 且 checks>=2000。
#   兜底文案不含 PASS（AGENT.md §3.2 假 PASS 事故教训）。
# 用法：./fpga/scratch/bram_equiv/run.sh
#==============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../../.." && pwd -P)"
cd -- "$REPO_ROOT"

IV="${RV32_IVERILOG:-iverilog}"
VVP="${RV32_VVP:-vvp}"
WORK="${SCRIPT_DIR}/work"; mkdir -p "$WORK"

IP_MODEL=(
    "fpga/ip/blk_mem_gen_cache_data/sim/blk_mem_gen_cache_data.v"
    "fpga/ip/blk_mem_gen_cache_data/simulation/blk_mem_gen_v8_4.v"
)
for f in "${IP_MODEL[@]}"; do
    [ -r "$f" ] || { echo "ERROR: IP 仿真模型缺失：$f（先跑 fpga/tcl/create_ip.tcl）" >&2; exit 2; }
done

clog="${WORK}/compile.log"; rlog="${WORK}/run.log"
if ! "$IV" -g2012 -I rtl/pkg -I . -s tb_bram_equiv -o "${WORK}/tb_bram_equiv.vvp" \
        rtl/cache/cache_array_bram.v "${IP_MODEL[@]}" "${SCRIPT_DIR}/tb_bram_equiv.v" >"$clog" 2>&1; then
    echo "BRAM_EQUIV: FAIL —— iverilog 编译失败（日志 ${clog}）"
    sed -n '1,15p' "$clog" | sed 's/^/    /'
    exit 1
fi

timeout "${BRAM_EQUIV_TIMEOUT:-300}" "$VVP" "${WORK}/tb_bram_equiv.vvp" >"$rlog" 2>&1
rc=$?

hits=$(grep -cF -- "BRAM_EQUIV PASS" "$rlog" || true)
stats_line="$(grep -F -- "BRAM_EQUIV: checks=" "$rlog" | tail -1 || true)"
checks="$(printf '%s' "$stats_line" | sed -n 's/.*checks=\([0-9]*\).*/\1/p')"
errors="$(printf '%s' "$stats_line" | sed -n 's/.*errors=\([0-9]*\).*/\1/p')"

if [ "$rc" -eq 0 ] && [ "$hits" -eq 1 ] && [ -n "$checks" ] && [ -n "$errors" ] \
   && [ "$errors" -eq 0 ] && [ "$checks" -ge 2000 ]; then
    echo "BRAM_EQUIV: PASS —— 逐拍比对 ${checks} 次、差异 0 次（IP vs 行为模型，宏未定义侧=回归分支）"
    exit 0
fi
echo "BRAM_EQUIV: FAIL —— rc=${rc} 锚点命中=${hits} checks=${checks:-未捕获} errors=${errors:-未捕获}（日志 ${rlog}）"
grep -E "MISMATCH" "$rlog" | head -5 | sed 's/^/    /'
exit 1
