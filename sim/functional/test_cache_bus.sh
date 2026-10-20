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
#      + DUT_ROOT 下 5 个 RTL（l1d/l1i/cache_tag_array/cache_array_bram/axi_master_ctrl）；
#      ★ 编译前 `cd "$DUT_ROOT"` 且只用 `-I "$DUT_ROOT"` ⇒ `rtl/pkg/*.vh` 只能来自
#        DUT 根，**不会**从调用者 cwd 或活树 fallback 借头文件（毒化 cwd 反证见 driver）。
#   2) 跑 vvp，把编译/运行输出捕获到**本次独占**的 run 目录；
#   3) 逐向量**逐项核对**（编号/名称/checks/fails/defect 全固定，见 §2 的规格表）；
#      多一条、少一条、重名、错名、错数、0 检查凑数，一律失败；
#   4) 默认 DUT_ROOT = 本仓库根（当前树）；置 DUT_ROOT=<只读源根> 可对旧源码复跑
#      同一 TB 做反证。
#
# 两种判定模式（同一 TB、同一脚本、同一 env，只换期望规格）：
#   · 默认 CACHE_BUS_EXPECT=fixed：逐向量 fails=0 / defect=0，checks 等于 fixed 表
#     ⇒ stdout 只有摘要行 + `FUNCTIONAL_CACHE_BUS: PASS`，rc=0。
#   · CACHE_BUS_EXPECT=old（旧树反证口径）：逐向量 checks/fails/defect 等于 old 表
#     （旧树真实死锁会让部分向量提前中止，故**旧/新检查数不同**，各自独立规格，
#      不强行压成同一个数），逐根因打印 DEFECT_REPRODUCED；**绝不**打印 PASS，rc=1。
#
# 产物纪律（每次运行互不覆盖、**不删除任何历史文件**）:
#   · 产物根 = RV32_FUNCTIONAL_PKG_OUT_DIR > OUT_DIR > $REPO_ROOT/build/functional/cache-bus
#   · 根先 readlink -m 规范化并校验位于 $REPO_ROOT/build/functional 之下，再 mkdir；
#     随后 `mktemp -d <根>/run-XXXXXXXX` 建**独占 run 目录**，本次全部产物都在其中。
#   · 因目录独占，脚本**不做任何 rm**。
#
# 工具真源 : 只从 scripts/env.sh 取 RV32_IVERILOG / RV32_VVP（env.sh 只读）。
# 源冻结  : 集合 A（8 依赖）= 5 RTL + 2 头 + TB，**恰好 8 行全为 64 位 hex**；
#           集合 B（包/env）= 本包脚本 + env.sh，**恰好 2 行全为 hex**。
#           两组都运行前后各算一次并要求逐字节一致（不容忍额外坏行）。
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
TIMEOUT_RUN_S="${TIMEOUT_RUN_S:-900}"
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

#------------------------------------------------------------------------------
# 2. 冻结规格（与 tb_cache_bus_semantics.sv **逐向量逐字段**同步；改 TB 必须同步改这里）
#    ★ 顺序即 VEC 行顺序；编号必须 1..SPEC_TOTAL；每项 checks 必须 > 0。
#    ★ fixed 与 old 是**两套独立规格**：旧树在真实死锁处提前中止，检查数必然更少，
#      这不是"少跑"，而是缺陷证据；两套都精确匹配才判通过。
#------------------------------------------------------------------------------
SPEC_NAMES="wb_first_valid_zero_delay wb_two_victims_distinct wb_accept_delay3 \
ctrl_wb_clean_no_req axi_split_read_single_done axi_split_write_single_done \
ctrl_axi_nonsplit_single_done l1i_fill_err_early l1i_fill_err_last \
l1i_two_err_lines_alternate l1d_fill_err_mid l1d_wb_b_fail_keeps_dirty \
l1d_maint_clean_b_fail ctrl_l1d_fill_hit axi_r_err_early axi_r_err_mid \
axi_r_err_last axi_b_err_write axi_split_first_err_last_ok axi_err_clear_next_req \
axi_r_resp_x_fail_closed axi_b_resp_x_fail_closed ctrl_axi_error_free_chain \
l1i_fill_err_x_early l1i_fill_err_x_last l1d_fill_err_x_mid \
l1d_wb_err_x_keeps_dirty l1d_maint_flush_b_fail_two_ways"
SPEC_TOTAL=28

SPEC_CHECKS_FIXED="36 53 37 6 12 11 8 15 6 10 12 35 49 7 11 9 8 9 10 10 9 6 10 9 8 7 24 21"
SPEC_CHECKS_OLD="35 49 37 6 12 11 8 6 1 1 5 21 11 7 11 9 8 9 10 10 9 6 10 1 1 5 21 11"
SPEC_FAILS_OLD="13 26 10 0 2 1 0 1 1 1 1 1 1 0 3 2 2 1 3 3 3 1 0 1 1 1 1 1"
SPEC_DEFECT_OLD="1 1 1 0 1 1 0 1 1 1 1 1 1 0 1 1 1 1 1 1 1 1 0 1 1 1 1 1"

SPEC_CONTROL_VECTORS="ctrl_wb_clean_no_req ctrl_axi_nonsplit_single_done ctrl_l1d_fill_hit ctrl_axi_error_free_chain"

#   登记根因 → 期望在旧树上给出 defect=1 的向量名（与审计 04-04/04-05/04-07 对应）
R0404_VECS="wb_first_valid_zero_delay wb_two_victims_distinct wb_accept_delay3"
R0405_VECS="axi_split_read_single_done axi_split_write_single_done"
R0407_VECS="l1i_fill_err_early l1i_fill_err_last l1i_two_err_lines_alternate l1d_fill_err_mid l1d_wb_b_fail_keeps_dirty l1d_maint_clean_b_fail axi_r_err_early axi_r_err_mid axi_r_err_last axi_b_err_write axi_split_first_err_last_ok axi_err_clear_next_req axi_r_resp_x_fail_closed axi_b_resp_x_fail_closed l1i_fill_err_x_early l1i_fill_err_x_last l1d_fill_err_x_mid l1d_wb_err_x_keeps_dirty l1d_maint_flush_b_fail_two_ways"

#------------------------------------------------------------------------------
# 3. 判定状态与输出助手（stdout 只放摘要 + 唯一锚点；细节在 run 目录日志）
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
# 4. 产物根：规范化 → 授权树校验 → mkdir → mktemp 独占 run 目录（绝不 rm）
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
    echo "SPEC_TOTAL      = $SPEC_TOTAL"
    if git -C "$REPO_ROOT" rev-parse HEAD >/dev/null 2>&1; then
        echo "GIT_HEAD        = $(git -C "$REPO_ROOT" rev-parse HEAD)"
    else
        echo "GIT_HEAD        = unavailable"
    fi
    echo "==============================================================="
} >> "$RUN_LOG" || emit_fail "run_log_header_failed"

#------------------------------------------------------------------------------
# 5. 工具真源：scripts/env.sh（只读）；工具缺失/不可执行即失败
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
# 6. DUT 源根校验 + 源冻结（**恰好 10 行、全为 hex**；前后一致）
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
if grep -q '^[[:space:]]*input[[:space:]]\+wire[[:space:]]\+fill_err' "$DUT_L1D" 2>/dev/null; then
    DUT_HAS_ERR=1
else
    DUT_HAS_ERR=0
fi
echo "DUT_HAS_ERR_IF  = $DUT_HAS_ERR" >> "$RUN_LOG"
#   新增输出 `cs_err_paddr` 只在当前树存在；旧/HEAD 树不连（端口可悬空）
if grep -q 'cs_err_paddr' "$DUT_L1I" 2>/dev/null; then
    DUT_HAS_ERR_PA=1
else
    DUT_HAS_ERR_PA=0
fi
echo "DUT_HAS_ERR_PA  = $DUT_HAS_ERR_PA" >> "$RUN_LOG"

#   ★ 冻结集合 A（"8 依赖"）= 5 RTL + 2 头 + TB ⇒ **恰好 8 行**
FREEZE_LIST=("$DUT_L1D" "$DUT_L1I" "$DUT_TAG" "$DUT_DAT" "$DUT_AXI" \
             "$DUT_DEFS" "$DUT_PARAMS" "$TB_SRC")
FREEZE_N=8
#   ★ 冻结集合 B（包/env）= 本包脚本 + env.sh ⇒ **恰好 2 行**
FREEZE_AUX=("$SELF_PATH" "$ENV_SH")
FREEZE_AUX_N=2

#   ★ 注意 rc 传播：直接把 sha256sum 的 rc 作为函数返回值（不吞进管道）。
freeze_sha() {
    sha256sum -- "${FREEZE_LIST[@]}" 2>>"$RUN_LOG"
}
freeze_aux_sha() {
    sha256sum -- "${FREEZE_AUX[@]}" 2>>"$RUN_LOG"
}

check_freeze_lines() {  # check_freeze_lines <block> <tag> <expect_n>
    local block="$1" tag="$2" want="$3" n_total n_hex
    n_total="$(printf '%s\n' "$block" | wc -l)"
    n_hex="$(printf '%s\n' "$block" | grep -c '^[0-9a-f]\{64\}  ' || true)"
    # ★ 必须"总行数 == 期望 且 每行全为 hex"：只数合法行会让额外坏行蒙混过关。
    [ "$n_total" = "$want" ] || emit_fail "${tag}_lines=$n_total expect=$want"
    [ "$n_hex"   = "$want" ] || emit_fail "${tag}_hex=$n_hex expect=$want"
}

SHA_PRE="$(freeze_sha)"
SHA_RC=$?
[ "$SHA_RC" -eq 0 ] || emit_fail "sha256_pre_rc=$SHA_RC"
check_freeze_lines "$SHA_PRE" "sha256_pre" "$FREEZE_N"
AUX_PRE="$(freeze_aux_sha)"
AUX_RC=$?
[ "$AUX_RC" -eq 0 ] || emit_fail "sha256_aux_pre_rc=$AUX_RC"
check_freeze_lines "$AUX_PRE" "sha256_aux_pre" "$FREEZE_AUX_N"
{
    echo "-- run phase start (both phases must match; driver checks ENV/TB/PKG) --"
    echo "-- pre-run source sha256 (8 deps = 5 RTL + 2 header + TB) --"
    printf '%s\n' "$SHA_PRE"
    echo "-- pre-run package/env sha256 (2 files) --"
    printf '%s\n' "$AUX_PRE"
} >> "$RUN_LOG" || emit_fail "run_log_sha_pre_append_failed"

#------------------------------------------------------------------------------
# 7. 编译（**cd "$DUT_ROOT"** + 只用 `-I "$DUT_ROOT"`；rc=0 零产物亦失败）
#------------------------------------------------------------------------------
COMPILE_DEFS=()
if [ "$DUT_HAS_ERR" = "0" ]; then
    COMPILE_DEFS+=( -DCACHE_BUS_OLD_DUT )
fi
if [ "$DUT_HAS_ERR_PA" = "1" ]; then
    COMPILE_DEFS+=( -DCACHE_BUS_HAS_ERR_PA )
fi

( cd -- "$DUT_ROOT" && \
  timeout "$TIMEOUT_COMPILE_S" "$IV" -g2012 -Wall -I "$DUT_ROOT" "${COMPILE_DEFS[@]}" \
        -s tb_cache_bus_semantics_top -o "$VVP_OUT" \
        "$TB_SRC" "$DUT_L1D" "$DUT_L1I" "$DUT_TAG" "$DUT_DAT" "$DUT_AXI" ) \
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
# 8. 运行（超时/非零退出即失败）
#------------------------------------------------------------------------------
( cd -- "$RUN_DIR" && timeout "$TIMEOUT_RUN_S" "$VV" "$VVP_OUT" ) >> "$RUN_LOG" 2>&1
RC=$?
parse_summary_besteffort
if [ "$RC" -eq 124 ]; then
    emit_fail "run_timeout"
elif [ "$RC" -ne 0 ]; then
    emit_fail "run_rc=$RC"
fi
[ -s "$RUN_LOG" ] || emit_fail "run_zero_output"

#------------------------------------------------------------------------------
# 9. 源冻结复核（编译/运行前后逐字节一致）
#------------------------------------------------------------------------------
SHA_POST="$(freeze_sha)"
SHA_RC=$?
[ "$SHA_RC" -eq 0 ] || emit_fail "sha256_post_rc=$SHA_RC"
check_freeze_lines "$SHA_POST" "sha256_post" "$FREEZE_N"
AUX_POST="$(freeze_aux_sha)"
AUX_RC=$?
[ "$AUX_RC" -eq 0 ] || emit_fail "sha256_aux_post_rc=$AUX_RC"
check_freeze_lines "$AUX_POST" "sha256_aux_post" "$FREEZE_AUX_N"
if [ "$SHA_PRE" != "$SHA_POST" ]; then
    emit_fail "source_changed_during_run"
fi
if [ "$AUX_PRE" != "$AUX_POST" ]; then
    emit_fail "package_or_env_changed_during_run"
fi

#------------------------------------------------------------------------------
# 10. 判定
#------------------------------------------------------------------------------
# 10.1 摘要整行唯一且严格匹配
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

# 10.2 摘要与规格
[ "$SUM_TOTAL"   -eq "$SPEC_TOTAL" ] || emit_fail "summary_total=$SUM_TOTAL expect=$SPEC_TOTAL"
[ "$SUM_NONZERO" -eq "$SPEC_TOTAL" ] || emit_fail "summary_nonzero=$SUM_NONZERO expect=$SPEC_TOTAL"

# 10.3 选模式规格表
if [ "$CACHE_BUS_EXPECT" = "fixed" ]; then
    SPEC_CHECKS="$SPEC_CHECKS_FIXED"
    SPEC_FAILS="$(for ((q=0;q<SPEC_TOTAL;q++)); do printf '0 '; done)"
    SPEC_DEFECT="$(for ((q=0;q<SPEC_TOTAL;q++)); do printf '0 '; done)"
elif [ "$CACHE_BUS_EXPECT" = "old" ]; then
    SPEC_CHECKS="$SPEC_CHECKS_OLD"
    SPEC_FAILS="$SPEC_FAILS_OLD"
    SPEC_DEFECT="$SPEC_DEFECT_OLD"
else
    emit_fail "unknown_expect=$CACHE_BUS_EXPECT"
fi

# 10.4 **逐向量逐字段**核对：编号 1..N、名称、checks、fails、defect 全等于规格
#      ⇒ 多一条/少一条/重复名/错名/错数/0 检查凑数 一律失败。
IFS=' ' read -r -a E_NAMES <<< "$SPEC_NAMES"
IFS=' ' read -r -a E_CHECKS <<< "$SPEC_CHECKS"
IFS=' ' read -r -a E_FAILS  <<< "$SPEC_FAILS"
IFS=' ' read -r -a E_DEFECT <<< "$SPEC_DEFECT"
[ "${#E_NAMES[@]}" -eq "$SPEC_TOTAL" ] || emit_fail "spec_names_len=${#E_NAMES[@]}"
[ "${#E_CHECKS[@]}" -eq "$SPEC_TOTAL" ] || emit_fail "spec_checks_len=${#E_CHECKS[@]}"

N_VEC="$(grep -c '^VEC ' "$RUN_LOG" || true)"
[ "$N_VEC" -eq "$SPEC_TOTAL" ] || emit_fail "vec_line_count=$N_VEC expect=$SPEC_TOTAL"

VEC_IDX=0
SUM_C=0; SUM_F=0; SUM_D=0
while IFS= read -r vline; do
    VEC_IDX=$((VEC_IDX + 1))
    if [[ ! "$vline" =~ ^VEC\ ([0-9]+)\ ([A-Za-z0-9_]+)\ checks=([0-9]+)\ fails=([0-9]+)\ defect=([0-9]+)$ ]]; then
        emit_fail "vec_format line=$VEC_IDX"
    fi
    v_id="${BASH_REMATCH[1]}"; v_nm="${BASH_REMATCH[2]}"
    v_c="${BASH_REMATCH[3]}"; v_f="${BASH_REMATCH[4]}"; v_d="${BASH_REMATCH[5]}"
    e_i=$((VEC_IDX - 1))
    # 编号必须等于序号（拒绝乱序/跳号/重复）
    [ "$v_id" = "$VEC_IDX" ] || emit_fail "vec_id=$v_id expect=$VEC_IDX"
    # 名称必须逐位一致（拒绝重名/错名/额外名）
    [ "$v_nm" = "${E_NAMES[$e_i]}" ] || emit_fail "vec_name=$v_nm expect=${E_NAMES[$e_i]} at=$VEC_IDX"
    # 每例至少 1 个检查（拒绝 0 检查凑数）
    [ "$v_c" -gt 0 ] || emit_fail "vec_zero_checks name=$v_nm"
    [ "$v_c" = "${E_CHECKS[$e_i]}" ] || emit_fail "vec_checks name=$v_nm got=$v_c expect=${E_CHECKS[$e_i]}"
    [ "$v_f" = "${E_FAILS[$e_i]}" ]  || emit_fail "vec_fails name=$v_nm got=$v_f expect=${E_FAILS[$e_i]}"
    [ "$v_d" = "${E_DEFECT[$e_i]}" ] || emit_fail "vec_defect name=$v_nm got=$v_d expect=${E_DEFECT[$e_i]}"
    SUM_C=$((SUM_C + v_c)); SUM_F=$((SUM_F + v_f)); SUM_D=$((SUM_D + v_d))
done < <(grep '^VEC ' "$RUN_LOG")

[ "$VEC_IDX" -eq "$SPEC_TOTAL" ] || emit_fail "vec_parsed=$VEC_IDX expect=$SPEC_TOTAL"
# 汇总必须等于逐向量之和（拒绝"摘要自报"与逐向量不一致）
[ "$SUM_C" = "$SUM_CHECKS" ] || emit_fail "vec_checks_sum=$SUM_C expect=$SUM_CHECKS"
[ "$SUM_F" = "$SUM_FAILS" ]  || emit_fail "vec_fails_sum=$SUM_F expect=$SUM_FAILS"
[ "$SUM_D" = "$SUM_DEFECT" ] || emit_fail "vec_defect_sum=$SUM_D expect=$SUM_DEFECT"

# 10.5 控制向量：两棵树都必须 fails=0 defect=0（否则"修复"是靠放宽判据）
vec_field() { # vec_field <name> <field>
    local ln
    ln="$(grep -m1 -- "^VEC [0-9]\+ $1 checks=" "$RUN_LOG" || true)"
    printf '%s\n' "$ln" | sed -n "s/.*[[:space:]]$2=\([0-9]\+\).*/\1/p"
}
for cv in $SPEC_CONTROL_VECTORS; do
    [ "$(vec_field "$cv" fails)"  = "0" ] || emit_fail "control_vec_fails name=$cv"
    [ "$(vec_field "$cv" defect)" = "0" ] || emit_fail "control_vec_defect name=$cv"
done

if [ "$CACHE_BUS_EXPECT" = "fixed" ]; then
    [ "$SUM_FAILS" -eq 0 ] || emit_fail "summary_fails=$SUM_FAILS"
    [ "$SUM_DEFECT" -eq 0 ] || emit_fail "summary_defect=$SUM_DEFECT"
    N_ANYFAIL="$(grep -c 'FAIL' "$RUN_LOG" || true)"
    [ "$N_ANYFAIL" = "0" ] || emit_fail "log_has_FAIL=$N_ANYFAIL"
    N_DEFECT="$(grep -c 'DEFECT_REPRODUCED\|DEFECT_SIG' "$RUN_LOG" || true)"
    [ "$N_DEFECT" = "0" ] || emit_fail "log_has_defect_marker=$N_DEFECT"
    N_TIMEOUT="$(grep -c 'CACHE_BUS_TIMEOUT' "$RUN_LOG" || true)"
    [ "$N_TIMEOUT" = "0" ] || emit_fail "log_has_timeout=$N_TIMEOUT"
    N_PASS="$(grep -cxF 'FUNCTIONAL_CACHE_BUS: PASS' "$RUN_LOG" || true)"
    [ "$N_PASS" = "1" ] || emit_fail "pass_anchor_count=$N_PASS"
    emit_summary_line
    printf 'FUNCTIONAL_CACHE_BUS: PASS\n'
    exit 0
else
    [ "$SUM_DEFECT" -gt 0 ] || emit_fail "old_no_defect_observed"
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
fi
