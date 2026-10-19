#!/usr/bin/env bash
#==============================================================================
# sim/functional/test_cache_bus.sh —— F3 Cache/AXI 语义包功能定向测试入口（fail-closed）
#==============================================================================
# 项目 : rv32gc-cpu（阶段二）
# 依据 : prompts/common.md §3（确定性脚本 + 退出码 + 日志锚点）；审计
#        `sim/audit/global-2026-10-18/04-memory-bus.md` 的 04-04 / 04-05 / 04-07。
#
# 做什么 :
#   1) 用 iverilog 编译**本包固定 TB**（sim/functional/tb_cache_bus_semantics.sv）
#      + DUT_ROOT 下 `rtl/cache/{l1d,l1i,cache_tag_array,cache_array_bram}.v`
#      + `rtl/axi/axi_master_ctrl.v`（头文件按 DUT_ROOT 解析）；
#   2) 跑 vvp，把编译/运行输出捕获到**本次独占**的 run 目录；
#   3) 逐向量严格校验摘要/格式/冻结规格/逐向量检查数；缺一即失败；
#   4) 默认 DUT_ROOT = 本仓库根（当前树）；置 DUT_ROOT=<只读源根> 可对旧源码复跑
#      同一 TB 做反证。
#
# 两种判定模式（同一 TB、同一脚本，只换期望）：
#   · 默认 CACHE_BUS_EXPECT=fixed：fails=0 且 defect=0 且冻结规格精确匹配
#     ⇒ stdout 只有摘要行 + `FUNCTIONAL_CACHE_BUS: PASS`，rc=0。
#   · CACHE_BUS_EXPECT=old（旧树反证口径）：要求**每个**登记根因向量都给出 defect=1
#     且 fails>0，逐根因打印 `FUNCTIONAL_CACHE_BUS: DEFECT_REPRODUCED root=<04-xx> ...`；
#     **绝不**打印 PASS 锚点，rc=1。旧树上"缺陷被复现"不是修复通过。
#
# 产物纪律（每次运行互不覆盖、**不删除任何历史文件**）:
#   · 产物根 = RV32_FUNCTIONAL_PKG_OUT_DIR（功能总入口传入，若设置）
#              > OUT_DIR（显式指定）
#              > $REPO_ROOT/build/functional/cache-bus（默认）
#   · 根先 readlink -m 规范化并校验位于 $REPO_ROOT/build/functional 之下，再 mkdir；
#     随后 `mktemp -d <根>/run-XXXXXXXX` 建**独占 run 目录**，本次全部产物都在其中。
#   · 因目录独占，脚本**不做任何 rm**；固定文件名也不会覆盖历史。
#
# 工具真源 : 只从 scripts/env.sh 取 RV32_IVERILOG / RV32_VVP（env.sh 只读）；
#            二者仍可被调用方以同名环境变量覆盖 ⇒ 保留"假工具"反证能力。
# 源冻结  : DUT 源 + 头 + TB 的 sha256 **运行前后各算一次并要求逐字节一致**。
#
# 用法 : bash sim/functional/test_cache_bus.sh
#        DUT_ROOT=<只读源根> bash sim/functional/test_cache_bus.sh
#        CACHE_BUS_EXPECT=old DUT_ROOT=<旧源根> bash sim/functional/test_cache_bus.sh
#==============================================================================
set -u

#------------------------------------------------------------------------------
# 0. 参数：本入口不接受任何位置参数
#------------------------------------------------------------------------------
if [ "$#" -ne 0 ]; then
    printf 'FUNCTIONAL_CACHE_BUS: FAIL reason=unknown_arg argv=%s\n' "$*"
    exit 1
fi

TIMEOUT_COMPILE_S="${TIMEOUT_COMPILE_S:-300}"
TIMEOUT_RUN_S="${TIMEOUT_RUN_S:-600}"
CACHE_BUS_EXPECT="${CACHE_BUS_EXPECT:-fixed}"

#------------------------------------------------------------------------------
# 1. 路径解析（按脚本自身位置推导，不依赖调用者 cwd）
#------------------------------------------------------------------------------
SELF_PATH="${BASH_SOURCE[0]}"
SELF_DIR="$(cd -- "$(dirname -- "$SELF_PATH")" && pwd -P)" || {
    printf 'FUNCTIONAL_CACHE_BUS: FAIL reason=self_dir_unresolved\n'; exit 1; }
REPO_ROOT="$(cd -- "$SELF_DIR/../.." && pwd -P)" || {
    printf 'FUNCTIONAL_CACHE_BUS: FAIL reason=repo_root_unresolved\n'; exit 1; }
TB_SRC="$SELF_DIR/tb_cache_bus_semantics.sv"
ENV_SH="$REPO_ROOT/scripts/env.sh"

# ---- 本包冻结规格（与 tb_cache_bus_semantics.sv 同步；改 TB 必须同步改这里）----
SPEC_TOTAL=14
SPEC_NONZERO=14
SPEC_CHECKS=249
SPEC_DEFECT_VECTORS=11
SPEC_CONTROL_VECTORS="ctrl_wb_clean_no_req ctrl_axi_nonsplit_single_done ctrl_l1d_fill_hit"

#   登记根因 → 期望在旧树上给出 defect=1 的向量名（与审计 04-04/04-05/04-07 对应）
R0404_VECS="wb_first_valid_zero_delay wb_two_victims_distinct wb_accept_delay3"
R0405_VECS="axi_split_read_single_done axi_split_write_single_done"
R0407_VECS="l1i_fill_err_early l1i_fill_err_last l1i_two_err_lines_alternate l1d_fill_err_mid l1d_wb_b_fail_keeps_dirty l1d_maint_clean_b_fail"

#------------------------------------------------------------------------------
# 2. 判定状态与输出助手（stdout 只放摘要 + 唯一锚点；细节在 run 目录日志）
#------------------------------------------------------------------------------
RUN_LOG=""
SUM_TOTAL="-"; SUM_NONZERO="-"; SUM_CHECKS="-"; SUM_FAILS="-"; SUM_DEFECT="-"

emit_summary_line() {
    printf 'CACHE_BUS_VECTORS total=%s nonzero=%s checks=%s fails=%s defect=%s\n' \
        "$SUM_TOTAL" "$SUM_NONZERO" "$SUM_CHECKS" "$SUM_FAILS" "$SUM_DEFECT"
}

emit_fail() {
    emit_summary_line
    printf 'FUNCTIONAL_CACHE_BUS: FAIL reason=%s run_dir=%s\n' "$1" "${RUN_LOG%/*}"
    exit 1
}

parse_summary_besteffort() {
    local line
    line="$(grep -m1 '^CACHE_BUS_VECTORS ' "$RUN_LOG" 2>/dev/null || true)"
    if [[ "$line" =~ ^CACHE_BUS_VECTORS\ total=([0-9]+)\ nonzero=([0-9]+)\ checks=([0-9]+)\ fails=([0-9]+)\ defect=([0-9]+)$ ]]; then
        SUM_TOTAL="${BASH_REMATCH[1]}"; SUM_NONZERO="${BASH_REMATCH[2]}"
        SUM_CHECKS="${BASH_REMATCH[3]}"; SUM_FAILS="${BASH_REMATCH[4]}"
        SUM_DEFECT="${BASH_REMATCH[5]}"
    fi
}

#------------------------------------------------------------------------------
# 3. 产物根：规范化 → 授权树校验 → mkdir → mktemp 独占 run 目录（绝不 rm）
#------------------------------------------------------------------------------
AUTH_ROOT="$(readlink -m -- "$REPO_ROOT/build/functional")" || emit_fail "auth_root_readlink_failed"
ROOT_RAW="${RV32_FUNCTIONAL_PKG_OUT_DIR:-${OUT_DIR:-$AUTH_ROOT/cache-bus}}"

is_authorized() {
    case "$1" in
        "$AUTH_ROOT" | "$AUTH_ROOT"/*) return 0 ;;
        *) return 1 ;;
    esac
}

ROOT_NORM="$(readlink -m -- "$ROOT_RAW")" || emit_fail "out_root_readlink_failed root=$ROOT_RAW"
is_authorized "$ROOT_NORM" || emit_fail "out_root_unauthorized root=$ROOT_NORM auth=$AUTH_ROOT"

mkdir -p -- "$ROOT_NORM" || emit_fail "out_root_mkdir_failed root=$ROOT_NORM"
ROOT_NORM="$(readlink -m -- "$ROOT_NORM")" || emit_fail "out_root_recheck_readlink_failed"
is_authorized "$ROOT_NORM" || emit_fail "out_root_unauthorized_after_mkdir root=$ROOT_NORM"

RUN_DIR="$(mktemp -d -- "$ROOT_NORM/run-XXXXXXXX")" || emit_fail "mktemp_run_dir_failed root=$ROOT_NORM"
RUN_LOG="$RUN_DIR/test_cache_bus.log"
COMPILE_LOG="$RUN_DIR/test_cache_bus.compile.log"
VVP_OUT="$RUN_DIR/tb_cache_bus_semantics.vvp"

: > "$RUN_LOG" || emit_fail "run_log_create_failed"

{
    echo "==== test_cache_bus.sh : F3 Cache/AXI semantics (functional) ===="
    echo "date            = $(date -Is 2>/dev/null || date)"
    echo "SELF_DIR        = $SELF_DIR"
    echo "REPO_ROOT       = $REPO_ROOT"
    echo "RUN_DIR         = $RUN_DIR"
    echo "ARTIFACT_ROOT   = $ROOT_NORM"
    echo "AUTH_ROOT       = $AUTH_ROOT"
    echo "TB_SRC          = $TB_SRC"
    echo "CACHE_BUS_EXPECT= $CACHE_BUS_EXPECT"
    echo "SPEC            = total=$SPEC_TOTAL nonzero=$SPEC_NONZERO checks=$SPEC_CHECKS defect=$SPEC_DEFECT_VECTORS"
    if git -C "$REPO_ROOT" rev-parse HEAD >/dev/null 2>&1; then
        echo "GIT_HEAD        = $(git -C "$REPO_ROOT" rev-parse HEAD)"
    else
        echo "GIT_HEAD        = unavailable"
    fi
    echo "==============================================================="
} >> "$RUN_LOG" || emit_fail "run_log_header_failed"

#------------------------------------------------------------------------------
# 4. 工具真源：scripts/env.sh（只读）；工具缺失/不可执行即失败
#------------------------------------------------------------------------------
if [ ! -r "$ENV_SH" ]; then
    emit_fail "env_sh_unreadable path=$ENV_SH"
fi
# shellcheck disable=SC1090
. "$ENV_SH" >> "$RUN_LOG" 2>&1
ENV_RC=$?
[ "$ENV_RC" -eq 0 ] || emit_fail "env_sh_source_rc=$ENV_RC"

IV="${RV32_IVERILOG:-}"
VV="${RV32_VVP:-}"
[ -n "$IV" ] && [ -x "$IV" ] || emit_fail "tool_missing name=RV32_IVERILOG value=${IV:-unset}"
[ -n "$VV" ] && [ -x "$VV" ] || emit_fail "tool_missing name=RV32_VVP value=${VV:-unset}"
echo "RV32_IVERILOG   = $IV" >> "$RUN_LOG"
echo "RV32_VVP        = $VV" >> "$RUN_LOG"

#------------------------------------------------------------------------------
# 5. DUT 源根校验 + 源冻结（前后 SHA 一致；任一步失败即失败）
#------------------------------------------------------------------------------
if [ ! -f "$TB_SRC" ]; then
    emit_fail "tb_missing tb=$TB_SRC"
fi

DUT_ROOT="${DUT_ROOT:-$REPO_ROOT}"
DUT_ROOT="$(cd -- "$DUT_ROOT" 2>/dev/null && pwd -P)" || emit_fail "dut_root_not_found dut=${DUT_ROOT:-unset}"

DUT_L1D="$DUT_ROOT/rtl/cache/l1d.v"
DUT_L1I="$DUT_ROOT/rtl/cache/l1i.v"
DUT_TAG="$DUT_ROOT/rtl/cache/cache_tag_array.v"
DUT_DAT="$DUT_ROOT/rtl/cache/cache_array_bram.v"
DUT_AXI="$DUT_ROOT/rtl/axi/axi_master_ctrl.v"
DUT_DEFS="$DUT_ROOT/rtl/pkg/rv32_defs.vh"
DUT_PARAMS="$DUT_ROOT/rtl/pkg/core_params.vh"

for f in "$DUT_L1D" "$DUT_L1I" "$DUT_TAG" "$DUT_DAT" "$DUT_AXI" "$DUT_DEFS" "$DUT_PARAMS"; do
    [ -f "$f" ] || emit_fail "dut_src_missing file=$f"
done

#   旧树快照（201acf61 同代）**没有**错误端口 ⇒ 用宏切到旧端口表例化。
#   判定依据不是调用方口述，而是 DUT 源里是否真的存在 `fill_err` 端口。
if grep -q '^\s*input\s*\+wire\s\+fill_err' "$DUT_L1D" 2>/dev/null; then
    DUT_HAS_ERR=1
else
    DUT_HAS_ERR=0
fi
echo "DUT_HAS_ERR_IF  = $DUT_HAS_ERR" >> "$RUN_LOG"

freeze_sha() {
    sha256sum -- "$DUT_L1D" "$DUT_L1I" "$DUT_TAG" "$DUT_DAT" "$DUT_AXI" \
                 "$DUT_DEFS" "$DUT_PARAMS" "$TB_SRC" 2>>"$RUN_LOG"
}
SHA_PRE="$(freeze_sha)" || emit_fail "sha256_pre_failed"
N_SHA_LINES="$(printf '%s\n' "$SHA_PRE" | grep -c '^[0-9a-f]\{64\} ' || true)"
[ "$N_SHA_LINES" = "8" ] || emit_fail "sha256_pre_lines=$N_SHA_LINES"
{
    echo "-- pre-run source sha256 (5 RTL + 2 header + TB) --"
    printf '%s\n' "$SHA_PRE"
} >> "$RUN_LOG" || emit_fail "run_log_sha_pre_append_failed"

#------------------------------------------------------------------------------
# 6. 编译（DUT 取 DUT_ROOT，TB 恒取本包；rc=0 零产物亦失败）
#------------------------------------------------------------------------------
COMPILE_DEFS=()
if [ "$DUT_HAS_ERR" = "0" ]; then
    COMPILE_DEFS+=( -DCACHE_BUS_OLD_DUT )
fi

timeout "$TIMEOUT_COMPILE_S" "$IV" -g2012 -Wall -I "$DUT_ROOT" "${COMPILE_DEFS[@]}" \
        -s tb_cache_bus_semantics_top -o "$VVP_OUT" \
        "$TB_SRC" "$DUT_L1D" "$DUT_L1I" "$DUT_TAG" "$DUT_DAT" "$DUT_AXI" \
        > "$COMPILE_LOG" 2>&1
RC=$?
cat -- "$COMPILE_LOG" >> "$RUN_LOG" || emit_fail "run_log_compile_append_failed"
if [ "$RC" -eq 124 ]; then
    emit_fail "compile_timeout"
elif [ "$RC" -ne 0 ]; then
    emit_fail "compile_rc=$RC"
fi
[ -s "$VVP_OUT" ] || emit_fail "compile_no_vvp_output"

#------------------------------------------------------------------------------
# 7. 运行（超时/非零退出即失败）
#------------------------------------------------------------------------------
timeout "$TIMEOUT_RUN_S" "$VV" "$VVP_OUT" >> "$RUN_LOG" 2>&1
RC=$?
parse_summary_besteffort
if [ "$RC" -eq 124 ]; then
    emit_fail "run_timeout"
elif [ "$RC" -ne 0 ]; then
    emit_fail "run_rc=$RC"
fi
[ -s "$RUN_LOG" ] || emit_fail "run_zero_output"

#------------------------------------------------------------------------------
# 8. 源冻结复核（编译/运行前后逐字节一致）
#------------------------------------------------------------------------------
SHA_POST="$(freeze_sha)" || emit_fail "sha256_post_failed"
if [ "$SHA_PRE" != "$SHA_POST" ]; then
    emit_fail "source_changed_during_run"
fi

#------------------------------------------------------------------------------
# 9. 判定（严格格式 + 冻结规格 + 逐向量一致性）
#------------------------------------------------------------------------------
# 9.1 摘要整行唯一且严格匹配（缺/多/坏字段一律失败）
N_SUMMARY="$(grep -c '^CACHE_BUS_VECTORS ' "$RUN_LOG" || true)"
[ "$N_SUMMARY" = "1" ] || emit_fail "summary_count=$N_SUMMARY"
SUM_LINE="$(grep -m1 '^CACHE_BUS_VECTORS ' "$RUN_LOG" || true)"
if [[ "$SUM_LINE" =~ ^CACHE_BUS_VECTORS\ total=([0-9]+)\ nonzero=([0-9]+)\ checks=([0-9]+)\ fails=([0-9]+)\ defect=([0-9]+)$ ]]; then
    SUM_TOTAL="${BASH_REMATCH[1]}"; SUM_NONZERO="${BASH_REMATCH[2]}"
    SUM_CHECKS="${BASH_REMATCH[3]}"; SUM_FAILS="${BASH_REMATCH[4]}"
    SUM_DEFECT="${BASH_REMATCH[5]}"
else
    emit_fail "summary_format"
fi

# 9.2 冻结规格（防"少向量/少跑"冒充完整包）
#   · total/nonzero 在**两种模式**都必须精确等于规格（向量数与"每向量至少 1 检查"）
#   · checks 总数只在 fixed 模式要求精确：旧树反证时部分向量会在真实死锁处提前中止，
#     其检查数必然少于新树（这正是缺陷证据），若强求相等就永远无法反证。
#     旧模式仍由 9.3/9.4 保证"逐向量 checks 之和 == 摘要 checks"且 controls 精确。
[ "$SUM_TOTAL"   -eq "$SPEC_TOTAL"    ] || emit_fail "summary_total=$SUM_TOTAL expect=$SPEC_TOTAL"
[ "$SUM_NONZERO" -eq "$SPEC_NONZERO"  ] || emit_fail "summary_nonzero=$SUM_NONZERO expect=$SPEC_NONZERO"
if [ "$CACHE_BUS_EXPECT" = "fixed" ]; then
    [ "$SUM_CHECKS" -eq "$SPEC_CHECKS" ] || emit_fail "summary_checks=$SUM_CHECKS expect=$SPEC_CHECKS"
else
    [ "$SUM_CHECKS" -gt 0 ] || emit_fail "summary_checks_zero"
fi

# 9.3 逐向量：行数、严格格式、checks 之和、汇总一致
N_VEC="$(grep -c '^VEC ' "$RUN_LOG" || true)"
[ "$N_VEC" -eq "$SUM_TOTAL" ] || emit_fail "vec_line_count=$N_VEC total=$SUM_TOTAL"
VEC_STAT="$(awk '
    /^VEC / {
        if ($0 ~ /^VEC [0-9]+ [^ ]+ checks=[0-9]+ fails=[0-9]+ defect=[0-1]$/) {
            n++
            for (i = 1; i <= NF; i++) if ($i ~ /^checks=/) { split($i, a, "="); s += a[2] }
        } else { b++ }
    }
    END { printf "%d %d %d\n", n + 0, s + 0, b + 0 }
' "$RUN_LOG")" || emit_fail "vec_awk_failed"
read -r V_OK V_SUM V_BAD <<<"$VEC_STAT"
[ "$V_BAD" = "0" ] || emit_fail "vec_format_bad=$V_BAD"
[ "$V_OK" -eq "$SUM_TOTAL" ] || emit_fail "vec_ok=$V_OK total=$SUM_TOTAL"
[ "$V_SUM" -eq "$SUM_CHECKS" ] || emit_fail "vec_checks_sum=$V_SUM checks=$SUM_CHECKS"

# 9.4 逐向量摘要与汇总一致（fails/defect 之和）
V_SUMS="$(awk '/^VEC /{ for (i=1;i<=NF;i++){ if ($i ~ /^fails=/){split($i,a,"="); f+=a[2]} if ($i ~ /^defect=/){split($i,a,"="); d+=a[2]} } } END{printf "%d %d\n", f+0, d+0}' "$RUN_LOG")"
read -r VF_SUM VD_SUM <<<"$V_SUMS"
[ "$VF_SUM" = "$SUM_FAILS" ]  || emit_fail "vec_fails_sum=$VF_SUM fails=$SUM_FAILS"
[ "$VD_SUM" = "$SUM_DEFECT" ] || emit_fail "vec_defect_sum=$VD_SUM defect=$SUM_DEFECT"

vec_line() {  # vec_line <name> -> 该向量整行（唯一）
    grep -m1 -- "^VEC [0-9]\+ $1 checks=" "$RUN_LOG" || true
}
vec_field() { # vec_field <name> <field>
    local ln; ln="$(vec_line "$1")"
    printf '%s\n' "$ln" | sed -n "s/.*[[:space:]]$2=\([0-9]\+\).*/\1/p"
}

#   控制向量：两棵树都必须 fails=0 defect=0（否则"修复"是靠放宽判据）。
for cv in $SPEC_CONTROL_VECTORS; do
    cl="$(vec_line "$cv")"
    [ -n "$cl" ] || emit_fail "control_vec_missing name=$cv"
    cf="$(vec_field "$cv" fails)"; cd="$(vec_field "$cv" defect)"
    [ "$cf" = "0" ] || emit_fail "control_vec_fails name=$cv fails=$cf"
    [ "$cd" = "0" ] || emit_fail "control_vec_defect name=$cv defect=$cd"
done

if [ "$CACHE_BUS_EXPECT" = "fixed" ]; then
    # 9.5a 修复口径：零失败、零缺陷签名、唯一 PASS 锚点、无旧错误复现标记
    [ "$SUM_FAILS"  -eq 0 ] || emit_fail "summary_fails=$SUM_FAILS"
    [ "$SUM_DEFECT" -eq 0 ] || emit_fail "summary_defect=$SUM_DEFECT"
    N_ANYFAIL="$(grep -c 'FAIL' "$RUN_LOG" || true)"
    [ "$N_ANYFAIL" = "0" ] || emit_fail "log_has_FAIL=$N_ANYFAIL"
    N_DEFECT="$(grep -c 'DEFECT_REPRODUCED' "$RUN_LOG" || true)"
    [ "$N_DEFECT" = "0" ] || emit_fail "log_has_defect_reproduced=$N_DEFECT"
    N_TIMEOUT="$(grep -c 'CACHE_BUS_TIMEOUT' "$RUN_LOG" || true)"
    [ "$N_TIMEOUT" = "0" ] || emit_fail "log_has_timeout=$N_TIMEOUT"
    N_PASS="$(grep -cxF 'FUNCTIONAL_CACHE_BUS: PASS' "$RUN_LOG" || true)"
    [ "$N_PASS" = "1" ] || emit_fail "pass_anchor_count=$N_PASS"
    emit_summary_line
    printf 'FUNCTIONAL_CACHE_BUS: PASS\n'
    exit 0
elif [ "$CACHE_BUS_EXPECT" = "old" ]; then
    # 9.5b 旧树反证口径：每个登记根因向量都必须给出 defect=1；fails 必须非零。
    [ "$SUM_DEFECT" -eq "$SPEC_DEFECT_VECTORS" ] || emit_fail "old_defect=$SUM_DEFECT expect=$SPEC_DEFECT_VECTORS"
    [ "$SUM_FAILS" -gt 0 ] || emit_fail "old_no_failure_observed"
    N_PASS="$(grep -cxF 'FUNCTIONAL_CACHE_BUS: PASS' "$RUN_LOG" || true)"
    [ "$N_PASS" = "0" ] || emit_fail "old_mode_printed_pass"
    for rv in $R0404_VECS; do
        [ "$(vec_field "$rv" defect)" = "1" ] || emit_fail "old_missing_defect vec=$rv root=04-04"
    done
    for rv in $R0405_VECS; do
        [ "$(vec_field "$rv" defect)" = "1" ] || emit_fail "old_missing_defect vec=$rv root=04-05"
    done
    for rv in $R0407_VECS; do
        [ "$(vec_field "$rv" defect)" = "1" ] || emit_fail "old_missing_defect vec=$rv root=04-07"
    done
    emit_summary_line
    printf 'FUNCTIONAL_CACHE_BUS: DEFECT_REPRODUCED root=04-04 vectors=%s\n' "$R0404_VECS"
    printf 'FUNCTIONAL_CACHE_BUS: DEFECT_REPRODUCED root=04-05 vectors=%s\n' "$R0405_VECS"
    printf 'FUNCTIONAL_CACHE_BUS: DEFECT_REPRODUCED root=04-07 vectors=%s\n' "$R0407_VECS"
    printf 'FUNCTIONAL_CACHE_BUS: FAIL reason=old_tree_defects_confirmed run_dir=%s\n' "$RUN_DIR"
    exit 1
else
    emit_fail "unknown_expect=$CACHE_BUS_EXPECT"
fi
