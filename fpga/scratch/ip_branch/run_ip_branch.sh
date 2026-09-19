#!/usr/bin/env bash
#==============================================================================
# fpga/scratch/ip_branch/run_ip_branch.sh —— **IP 分支（综合侧）仿真验证**（M4 证据）
#==============================================================================
# 目的：综合侧走 `ifdef RV32GC_USE_VIVADO_IP（Vivado IP），仿真侧走行为模型分支。
#       两条分支若语义漂移，上板（M5）才会暴露 —— 故本脚本在 iverilog 下把
#       **IP 分支本身**编译运行一遍：
#         * 定义宏 -DRV32GC_USE_VIVADO_IP（⇒ RTL 走 IP 例化分支）；
#         * 链接 Vivado 生成的 IP **行为仿真模型**（纯 Verilog，无 UNISIM ⇒ iverilog 可编）；
#         * 复用 sim/unit 下**既有 TB 的判据**（不改任何 TB、不改 regress.sh）。
#
# 覆盖：Cache 数据阵列 IP（blk_mem_gen_cache_data，Simple Dual Port）——
#       tb_l1i / tb_l1d（阵列最直接的使用者）、tb_lsu / tb_fetch_unit、
#       tb_m3_ddr3（**core_top 级**全核集成，M3 基线）。
#       ★ MDU 的 mult_gen/div_gen **不在本脚本覆盖内**：其 Vivado 仿真模型只有
#         VHDL（sim/*.vhd），iverilog 无法编译 ⇒ MDU 的 IP 分支仍只有综合侧证据
#         （见 M4 报告"遗留/风险"）。
#
# 判据（与 regress.sh 同口径，fail-closed）：
#   ① 编译 rc=0；② 运行输出里 TB 的 PASS 锚点**整行命中恰好 1 次**；
#   ③ 输出里 FAIL 行数 = 0；④ 全部 TB 通过才打印 IP_BRANCH: n/n PASS。
#   任一条件不满足 ⇒ 打印 IP_BRANCH: FAIL（兜底文案不含 PASS）。
# 用法：./fpga/scratch/ip_branch/run_ip_branch.sh [tb 名...]   （默认全部）
#==============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../../.." && pwd -P)"
cd -- "$REPO_ROOT"

IV="${RV32_IVERILOG:-iverilog}"
VVP="${RV32_VVP:-vvp}"
command -v "$IV"  >/dev/null || { echo "ERROR: 未找到 iverilog" >&2; exit 2; }
command -v "$VVP" >/dev/null || { echo "ERROR: 未找到 vvp" >&2; exit 2; }

IP_MACRO="RV32GC_USE_VIVADO_IP"
IP_SIM_MODEL=(
    "fpga/ip/blk_mem_gen_cache_data/sim/blk_mem_gen_cache_data.v"
    "fpga/ip/blk_mem_gen_cache_data/simulation/blk_mem_gen_v8_4.v"
)
for f in "${IP_SIM_MODEL[@]}"; do
    [ -r "$f" ] || { echo "ERROR: IP 仿真模型缺失：$f（先跑 fpga/tcl/create_ip.tcl）" >&2; exit 2; }
done

mapfile -t RTL_SRCS < <(find rtl -name '*.v' | sort)
[ "${#RTL_SRCS[@]}" -gt 0 ] || { echo "ERROR: rtl/**/*.v 为空" >&2; exit 2; }

TB_LIST=("$@")
if [ "${#TB_LIST[@]}" -eq 0 ]; then
    TB_LIST=(tb_l1i tb_l1d tb_lsu tb_fetch_unit tb_m3_ddr3)
fi

WORK="${SCRIPT_DIR}/work"
mkdir -p "$WORK"
TB_TIMEOUT="${IP_BRANCH_TIMEOUT:-420}"

n_total=0; n_pass=0; failed=()

for stem in "${TB_LIST[@]}"; do
    n_total=$((n_total + 1))
    tb_src="sim/unit/${stem}.sv"
    if [ ! -r "$tb_src" ]; then
        echo "FAIL: ${stem} —— TB 源码不存在：$tb_src"
        failed+=("$stem"); continue
    fi
    # ---- 编译顶层（TB 源码内第一个 module） ----
    top="$(awk '!d && match($0,/^[[:space:]]*module[[:space:]]+[A-Za-z_$][A-Za-z0-9_$]*/){s=substr($0,RSTART,RLENGTH);sub(/^[[:space:]]*module[[:space:]]+/,"",s);print s;d=1;exit}' "$tb_src")"
    [ -n "$top" ] || { echo "FAIL: ${stem} —— 找不到 module 声明"; failed+=("$stem"); continue; }

    # ---- PASS 锚点（与 regress.sh 同口径：TB 名大写 + `XXX: PASS`，且必须唯一） ----
    stem_upper="$(printf '%s' "$stem" | tr 'a-z' 'A-Z')"
    mapfile -t anchors < <(awk -v want="$stem_upper" '
        { line=$0
          while (match(line, /[A-Z][A-Z0-9_]*: ?PASS/)) {
              cand=substr(line,RSTART,RLENGTH); sub(/: ?PASS$/,"",cand)
              base=cand; sub(/_UNIT$/,"",base)
              if (base==want) found[cand]=1
              line=substr(line,RSTART+RLENGTH)
          } }
        END { for (k in found) print k }' "$tb_src")
    if [ "${#anchors[@]}" -ne 1 ]; then
        echo "FAIL: ${stem} —— PASS 锚点不唯一（实测 ${#anchors[@]} 个）"
        failed+=("$stem"); continue
    fi
    anchor_line="${anchors[0]}: PASS"

    clog="${WORK}/${stem}.ipbranch.compile.log"
    rlog="${WORK}/${stem}.ipbranch.run.log"
    vvp_out="${WORK}/${stem}.ipbranch.vvp"

    if ! "$IV" -g2012 -I rtl/pkg -I . -D"${IP_MACRO}" -s "$top" -o "$vvp_out" \
             "${RTL_SRCS[@]}" "${IP_SIM_MODEL[@]}" "$tb_src" >"$clog" 2>&1; then
        echo "FAIL: ${stem} —— iverilog 编译失败（IP 分支）；日志 $clog"
        sed -n '1,15p' "$clog" | sed 's/^/      /'
        failed+=("$stem"); continue
    fi

    timeout "$TB_TIMEOUT" "$VVP" "$vvp_out" >"$rlog" 2>&1
    rc=$?
    hits=$(grep -cF -- "$anchor_line" "$rlog" || true)
    fails=$(grep -c -- 'FAIL' "$rlog" || true)
    if [ "$rc" -eq 0 ] && [ "$hits" -eq 1 ] && [ "$fails" -eq 0 ]; then
        n_pass=$((n_pass + 1))
        printf '[%2d/%2d] %-16s PASS  锚点="%s"（整行命中 1 次，FAIL 0 行，rc=0）\n' \
               "$n_total" "${#TB_LIST[@]}" "$stem" "$anchor_line"
    else
        printf '[%2d/%2d] %-16s FAIL  rc=%d 锚点命中=%d FAIL 行=%d（日志 %s）\n' \
               "$n_total" "${#TB_LIST[@]}" "$stem" "$rc" "$hits" "$fails" "$rlog"
        failed+=("$stem")
    fi
done

echo "== ip_branch：总数=${#TB_LIST[@]} 通过=${n_pass} 失败=${#failed[@]}"
if [ "${#failed[@]}" -eq 0 ] && [ "$n_pass" -eq "${#TB_LIST[@]}" ] && [ "$n_pass" -gt 0 ]; then
    echo "IP_BRANCH: ${n_pass}/${#TB_LIST[@]} PASS（宏 ${IP_MACRO} 已定义；含 IP 行为仿真模型）"
    exit 0
fi
echo "IP_BRANCH: FAIL —— 失败项：${failed[*]:-<无>}（宏 ${IP_MACRO}）"
exit 1
