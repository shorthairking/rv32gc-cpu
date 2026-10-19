#!/usr/bin/env bash
#==============================================================================
# sim/functional/test_lsq.sh —— F2 LSQ 本体语义包功能定向测试入口（fail-closed）
#==============================================================================
# 项目 : rv32gc-cpu（阶段二 2B 乱序后端）
# 依据 : prompts/common.md §3（确定性脚本 + 退出码 + 日志锚点）、F2 验收（唯一整行
#        `FUNCTIONAL_LSQ: PASS`；缺例/少跑/非零/超时/错误标记一律拒）；审计
#        `sim/audit/global-2026-10-18/03-lsq-2b.md` F1..F5。
#
# 做什么 :
#   1) 用 iverilog 编译**本包固定 TB**（sim/functional/tb_lsq_semantics.sv）
#      + DUT_ROOT 下 `rtl/back2/lsq_simple.v`（头文件同根解析）；
#   2) 跑 vvp，把编译/运行输出捕获到**本次独占**的 run 目录；
#   3) 逐向量严格校验摘要/格式/冻结规格/逐向量检查数；缺一即失败；
#   4) 默认 DUT_ROOT = 本仓库根（当前树）；置 DUT_ROOT=<只读源根> 可对旧源码复跑
#      同一 TB 做反证。
#
# 两种判定模式（同一 TB、同一脚本，只换期望）：
#   · 默认 LSQ_EXPECT=fixed（修复后口径）：fails=0 且 defect=0 且冻结规格精确匹配
#     ⇒ stdout 只有摘要行 + `FUNCTIONAL_LSQ: PASS`，rc=0。
#   · LSQ_EXPECT=old（旧树反证口径）：要求**每个**登记根因向量都给出 defect=1 且
#     fails>0，逐根因打印 `FUNCTIONAL_LSQ: DEFECT_REPRODUCED root=<F#> vectors=...`；
#     **绝不**打印 PASS 锚点，rc=1。旧树上"缺陷被复现"不是修复通过。
#
# 产物纪律（每次运行互不覆盖、**不删除任何历史文件**）:
#   · 产物根 = RV32_FUNCTIONAL_PKG_OUT_DIR（功能总入口传入，若设置）
#              > OUT_DIR（显式指定）
#              > $REPO_ROOT/build/functional/lsq（默认）
#   · 根先 readlink -m 规范化并校验位于 $REPO_ROOT/build/functional 之下，再 mkdir；
#     随后 `mktemp -d <根>/run-XXXXXXXX` 建**独占 run 目录**，本次全部产物都在其中。
#   · 因目录独占，脚本**不做任何 rm**；固定文件名也不会覆盖历史。
#
# 工具真源 : 只从 scripts/env.sh 取 RV32_IVERILOG / RV32_VVP（env.sh 只读）；
#            二者仍可被调用方以同名环境变量覆盖 ⇒ 保留"假工具"反证能力。
# 源冻结  : DUT 源 + 头 + TB 的 sha256 **运行前后各算一次并要求逐字节一致**。
#
# 用法 : bash sim/functional/test_lsq.sh
#        DUT_ROOT=<只读源根> bash sim/functional/test_lsq.sh
#        LSQ_EXPECT=old DUT_ROOT=<旧源根> bash sim/functional/test_lsq.sh
# 说明 : 成功时 stdout 仅两行：`LSQ_VECTORS ...` 与 `FUNCTIONAL_LSQ: PASS`。
#==============================================================================
set -u

#------------------------------------------------------------------------------
# 0. 参数：本入口不接受任何位置参数
#------------------------------------------------------------------------------
if [ "$#" -ne 0 ]; then
    printf 'FUNCTIONAL_LSQ: FAIL reason=unknown_arg argv=%s\n' "$*"
    exit 1
fi

TIMEOUT_COMPILE_S="${TIMEOUT_COMPILE_S:-300}"
TIMEOUT_RUN_S="${TIMEOUT_RUN_S:-300}"
LSQ_EXPECT="${LSQ_EXPECT:-fixed}"

#------------------------------------------------------------------------------
# 1. 路径解析（按脚本自身位置推导，不依赖调用者 cwd）
#------------------------------------------------------------------------------
SELF_PATH="${BASH_SOURCE[0]}"
SELF_DIR="$(cd -- "$(dirname -- "$SELF_PATH")" && pwd -P)" || {
    printf 'FUNCTIONAL_LSQ: FAIL reason=self_dir_unresolved\n'; exit 1; }
REPO_ROOT="$(cd -- "$SELF_DIR/../.." && pwd -P)" || {
    printf 'FUNCTIONAL_LSQ: FAIL reason=repo_root_unresolved\n'; exit 1; }
TB_SRC="$SELF_DIR/tb_lsq_semantics.sv"
ENV_SH="$REPO_ROOT/scripts/env.sh"

# ---- 本包冻结规格（与 tb_lsq_semantics.sv 同步；改 TB 必须同步改这里）----
#      TB 本体不做 SPEC 自判（只报真实计数），脚本这层是唯一守卫 ⇒ 必须精确。
#      ★ 初审 #4：**逐向量 ID/name/checks 三元组全部冻结**（`id|name|checks`）——
#        仅比总数会被“重复缺陷名 / 零检查向量 + 别例补偿 checksum”蒙混；这里要求
#        实际 VEC 行与下表**逐行完全一致**（ID 完整 1..N、唯一、名字与 checks 精确）。
SPEC_TOTAL=18
SPEC_NONZERO=18
SPEC_CHECKS=285
SPEC_DEFECT_VECTORS=12
SPEC_CONTROL_VECTORS="f1_lq_no_release_neg f2_high_slot_drain_content f4_single_beat_retire ctrl_no_forward_policy ctrl_young_indep_load xz_checker_selfcheck"

#   登记根因 → 期望在旧树上给出 defect=1 的向量名（与审计 F1..F5 对应）
F1_VECS="f1_lq_release_wrap63 f1_lq_release_multiwrap f1_stq_window_wrap63 f1_squash_keeps_committed f1_flush_reclaim_no_dup_rsp flush_wb_same_cycle flush_stq_xlate_act"
F2_VECS="f2_stq_slot_select32"
F3_VECS="f3_flush_drains_cdq"
F4_VECS="f4_split_low_no_release"
F5_VECS="f5_cross_page_indep_pa f5_cross_page_fault"

#   ★ 冻结逐向量表（顺序即 ID 1..N；`id|name|checks`）。任何少例/重复 ID/错名/错 checks/
#     零检查一律判失败（与 TB 的 `VEC` 行逐字段比对）。
SPEC_TABLE='1|f1_lq_release_wrap63|3
2|f1_lq_no_release_neg|1
3|f1_lq_release_multiwrap|3
4|f1_stq_window_wrap63|5
5|f2_stq_slot_select32|160
6|f2_high_slot_drain_content|25
7|f4_single_beat_retire|3
8|f3_flush_drains_cdq|4
9|f1_squash_keeps_committed|3
10|f4_split_low_no_release|12
11|f5_cross_page_indep_pa|8
12|f5_cross_page_fault|24
13|ctrl_no_forward_policy|11
14|ctrl_young_indep_load|5
15|f1_flush_reclaim_no_dup_rsp|8
16|flush_wb_same_cycle|3
17|flush_stq_xlate_act|4
18|xz_checker_selfcheck|3'

#------------------------------------------------------------------------------
# 2. 判定状态与输出助手（stdout 只放摘要 + 唯一锚点；细节在 run 目录日志）
#------------------------------------------------------------------------------
RUN_LOG=""
SUM_TOTAL="-"; SUM_NONZERO="-"; SUM_CHECKS="-"; SUM_FAILS="-"; SUM_DEFECT="-"; SUM_XZ="-"

emit_summary_line() {
    printf 'LSQ_VECTORS total=%s nonzero=%s checks=%s fails=%s defect=%s xz=%s\n' \
        "$SUM_TOTAL" "$SUM_NONZERO" "$SUM_CHECKS" "$SUM_FAILS" "$SUM_DEFECT" "$SUM_XZ"
}

emit_fail() {
    emit_summary_line
    printf 'FUNCTIONAL_LSQ: FAIL reason=%s run_dir=%s\n' "$1" "${RUN_LOG%/*}"
    exit 1
}

parse_summary_besteffort() {
    local line
    line="$(grep -m1 '^LSQ_VECTORS ' "$RUN_LOG" 2>/dev/null || true)"
    if [[ "$line" =~ ^LSQ_VECTORS\ total=([0-9]+)\ nonzero=([0-9]+)\ checks=([0-9]+)\ fails=([0-9]+)\ defect=([0-9]+)\ xz=([0-9]+)$ ]]; then
        SUM_TOTAL="${BASH_REMATCH[1]}"; SUM_NONZERO="${BASH_REMATCH[2]}"
        SUM_CHECKS="${BASH_REMATCH[3]}"; SUM_FAILS="${BASH_REMATCH[4]}"
        SUM_DEFECT="${BASH_REMATCH[5]}"; SUM_XZ="${BASH_REMATCH[6]}"
    fi
}

#------------------------------------------------------------------------------
# 3. 产物根：规范化 → 授权树校验 → mkdir → mktemp 独占 run 目录（绝不 rm）
#------------------------------------------------------------------------------
AUTH_ROOT="$(readlink -m -- "$REPO_ROOT/build/functional")" || emit_fail "auth_root_readlink_failed"
ROOT_RAW="${RV32_FUNCTIONAL_PKG_OUT_DIR:-${OUT_DIR:-$AUTH_ROOT/lsq}}"

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
RUN_LOG="$RUN_DIR/test_lsq.log"
COMPILE_LOG="$RUN_DIR/test_lsq.compile.log"
VVP_OUT="$RUN_DIR/tb_lsq_semantics.vvp"

: > "$RUN_LOG" || emit_fail "run_log_create_failed"

{
    echo "==== test_lsq.sh : F2 LSQ semantics (functional) ===="
    echo "date            = $(date -Is 2>/dev/null || date)"
    echo "SELF_DIR        = $SELF_DIR"
    echo "REPO_ROOT       = $REPO_ROOT"
    echo "RUN_DIR         = $RUN_DIR"
    echo "ARTIFACT_ROOT   = $ROOT_NORM"
    echo "AUTH_ROOT       = $AUTH_ROOT"
    echo "TB_SRC          = $TB_SRC"
    echo "LSQ_EXPECT      = $LSQ_EXPECT"
    echo "SPEC            = total=$SPEC_TOTAL nonzero=$SPEC_NONZERO checks=$SPEC_CHECKS defect=$SPEC_DEFECT_VECTORS"
    printf '%s\n' "$SPEC_TABLE" | sed 's/^/SPEC_TABLE      = /' 
    if git -C "$REPO_ROOT" rev-parse HEAD >/dev/null 2>&1; then
        echo "GIT_HEAD        = $(git -C "$REPO_ROOT" rev-parse HEAD)"
    else
        echo "GIT_HEAD        = unavailable"
    fi
    echo "====================================================="
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
DUT_LSQ="$DUT_ROOT/rtl/back2/lsq_simple.v"
DUT_HDR="$DUT_ROOT/rtl/back2/back2_params.vh"
[ -f "$DUT_LSQ" ] || emit_fail "dut_src_missing file=$DUT_LSQ"
[ -f "$DUT_HDR" ] || emit_fail "dut_header_missing file=$DUT_HDR"

freeze_sha() {
    sha256sum -- "$DUT_LSQ" "$DUT_HDR" "$TB_SRC" 2>>"$RUN_LOG"
}
SHA_PRE="$(freeze_sha)" || emit_fail "sha256_pre_failed"
N_SHA_LINES="$(printf '%s\n' "$SHA_PRE" | grep -c '^[0-9a-f]\{64\} ' || true)"
[ "$N_SHA_LINES" = "3" ] || emit_fail "sha256_pre_lines=$N_SHA_LINES"
{
    echo "-- pre-run source sha256 (DUT / header / TB) --"
    printf '%s\n' "$SHA_PRE"
} >> "$RUN_LOG" || emit_fail "run_log_sha_pre_append_failed"

#------------------------------------------------------------------------------
# 6. 编译（DUT 取 DUT_ROOT，TB 恒取本包；rc=0 零产物亦失败）
#------------------------------------------------------------------------------
#   ★ 初审 #3：编译在 **DUT_ROOT 子 shell** 内进行（并显式 `-I "$DUT_ROOT"`）——
#   头文件只允许来自被冻结的 DUT_ROOT，禁止借调用者 cwd 里同路径的 `back2_params.vh`。
(
    cd -- "$DUT_ROOT" || exit 91
    exec timeout "$TIMEOUT_COMPILE_S" "$IV" -g2012 -Wall -I "$DUT_ROOT" \
        -s tb_lsq_semantics_top -o "$VVP_OUT" \
        "$TB_SRC" "$DUT_LSQ"
) > "$COMPILE_LOG" 2>&1
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
N_SUMMARY="$(grep -c '^LSQ_VECTORS ' "$RUN_LOG" || true)"
[ "$N_SUMMARY" = "1" ] || emit_fail "summary_count=$N_SUMMARY"
SUM_LINE="$(grep -m1 '^LSQ_VECTORS ' "$RUN_LOG" || true)"
if [[ "$SUM_LINE" =~ ^LSQ_VECTORS\ total=([0-9]+)\ nonzero=([0-9]+)\ checks=([0-9]+)\ fails=([0-9]+)\ defect=([0-9]+)\ xz=([0-9]+)$ ]]; then
    SUM_TOTAL="${BASH_REMATCH[1]}"; SUM_NONZERO="${BASH_REMATCH[2]}"
    SUM_CHECKS="${BASH_REMATCH[3]}"; SUM_FAILS="${BASH_REMATCH[4]}"
    SUM_DEFECT="${BASH_REMATCH[5]}"; SUM_XZ="${BASH_REMATCH[6]}"
else
    emit_fail "summary_format"
fi

# 9.2 冻结规格（防"少向量/少跑"冒充完整包）
[ "$SUM_TOTAL"   -eq "$SPEC_TOTAL"    ] || emit_fail "summary_total=$SUM_TOTAL expect=$SPEC_TOTAL"
[ "$SUM_NONZERO" -eq "$SPEC_NONZERO"  ] || emit_fail "summary_nonzero=$SUM_NONZERO expect=$SPEC_NONZERO"
[ "$SUM_CHECKS"  -eq "$SPEC_CHECKS"   ] || emit_fail "summary_checks=$SUM_CHECKS expect=$SPEC_CHECKS"

# 9.3 逐向量：行数、严格格式、**冻结三元组逐行一致**（判“重复 ID / 错名 / 零检查 +
#     别例补偿 checksum”）、checks 之和与汇总一致。
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

# 9.3b ★ ID 唯一且完整 1..N（先独立于冻结表判，便于给出精确 reason）
ID_STAT="$(awk '/^VEC /{print $2}' "$RUN_LOG" | sort -n | awk '
    { if ($1 != NR) { printf "gap_or_dup_at=%d got=%d\n", NR, $1; bad=1; exit } }
    END { if (!bad) printf "ok=%d\n", NR }')" || emit_fail "vec_id_awk_failed"
case "$ID_STAT" in
    ok=$SPEC_TOTAL) : ;;
    *) emit_fail "vec_ids_not_1_to_N $ID_STAT" ;;
esac

# 9.3c ★ 每例 checks>0（先判，防“零检查向量 + 别例补偿 checksum”给出精确 reason）
ACTUAL_ROWS="$(awk '/^VEC /{c=$4; sub(/^checks=/,"",c); print $2"|"$3"|"c}' "$RUN_LOG")" \
    || emit_fail "vec_rows_awk_failed"
if printf '%s\n' "$ACTUAL_ROWS" | awk -F'|' '$3+0 <= 0 {bad=1} END{exit bad?1:0}'; then :; else
    emit_fail "vec_zero_checks"
fi
# 9.3d ★ 实际 (id|name|checks) 序列与冻结表逐行一致（顺序、名字、每例 checks 精确）
if ! diff <(printf '%s\n' "$SPEC_TABLE") <(printf '%s\n' "$ACTUAL_ROWS") >/dev/null; then
    emit_fail "spec_table_mismatch"
fi

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
#   注：控制向量检查在两种模式下都执行。
for cv in $SPEC_CONTROL_VECTORS; do
    cl="$(vec_line "$cv")"
    [ -n "$cl" ] || emit_fail "control_vec_missing name=$cv"
    cf="$(vec_field "$cv" fails)"; cd="$(vec_field "$cv" defect)"
    [ "$cf" = "0" ] || emit_fail "control_vec_fails name=$cv fails=$cf"
    [ "$cd" = "0" ] || emit_fail "control_vec_defect name=$cv defect=$cd"
done

[ "$SUM_XZ" -eq 0 ] || emit_fail "summary_xz=$SUM_XZ"

if [ "$LSQ_EXPECT" = "fixed" ]; then
    # 9.5a 修复口径：零失败、零缺陷签名、无 X/Z、唯一 PASS 锚点、无旧错误复现标记
    [ "$SUM_FAILS"  -eq 0 ] || emit_fail "summary_fails=$SUM_FAILS"
    [ "$SUM_DEFECT" -eq 0 ] || emit_fail "summary_defect=$SUM_DEFECT"
    N_ANYFAIL="$(grep -c 'FAIL' "$RUN_LOG" || true)"
    [ "$N_ANYFAIL" = "0" ] || emit_fail "log_has_FAIL=$N_ANYFAIL"
    N_DEFECT="$(grep -c 'DEFECT_REPRODUCED' "$RUN_LOG" || true)"
    [ "$N_DEFECT" = "0" ] || emit_fail "log_has_defect_reproduced=$N_DEFECT"
    N_PASS="$(grep -cxF 'FUNCTIONAL_LSQ: PASS' "$RUN_LOG" || true)"
    [ "$N_PASS" = "1" ] || emit_fail "pass_anchor_count=$N_PASS"
    emit_summary_line
    printf 'FUNCTIONAL_LSQ: PASS\n'
    exit 0
elif [ "$LSQ_EXPECT" = "old" ]; then
    # 9.5b 旧树反证口径：每个登记根因向量都必须给出 defect=1；fails 必须非零。
    [ "$SUM_DEFECT" -eq "$SPEC_DEFECT_VECTORS" ] || emit_fail "old_defect=$SUM_DEFECT expect=$SPEC_DEFECT_VECTORS"
    [ "$SUM_FAILS" -gt 0 ] || emit_fail "old_no_failure_observed"
    N_PASS="$(grep -cxF 'FUNCTIONAL_LSQ: PASS' "$RUN_LOG" || true)"
    [ "$N_PASS" = "0" ] || emit_fail "old_mode_printed_pass"
    for rv in $F1_VECS; do
        [ "$(vec_field "$rv" defect)" = "1" ] || emit_fail "old_missing_defect vec=$rv root=F1"
    done
    for rv in $F2_VECS; do
        [ "$(vec_field "$rv" defect)" = "1" ] || emit_fail "old_missing_defect vec=$rv root=F2"
    done
    for rv in $F3_VECS; do
        [ "$(vec_field "$rv" defect)" = "1" ] || emit_fail "old_missing_defect vec=$rv root=F3"
    done
    for rv in $F4_VECS; do
        [ "$(vec_field "$rv" defect)" = "1" ] || emit_fail "old_missing_defect vec=$rv root=F4"
    done
    for rv in $F5_VECS; do
        [ "$(vec_field "$rv" defect)" = "1" ] || emit_fail "old_missing_defect vec=$rv root=F5"
    done
    emit_summary_line
    printf 'FUNCTIONAL_LSQ: DEFECT_REPRODUCED root=F1 vectors=%s\n' "$F1_VECS"
    printf 'FUNCTIONAL_LSQ: DEFECT_REPRODUCED root=F2 vectors=%s\n' "$F2_VECS"
    printf 'FUNCTIONAL_LSQ: DEFECT_REPRODUCED root=F3 vectors=%s\n' "$F3_VECS"
    printf 'FUNCTIONAL_LSQ: DEFECT_REPRODUCED root=F4 vectors=%s\n' "$F4_VECS"
    printf 'FUNCTIONAL_LSQ: DEFECT_REPRODUCED root=F5 vectors=%s\n' "$F5_VECS"
    printf 'FUNCTIONAL_LSQ: FAIL reason=old_tree_defects_confirmed run_dir=%s\n' "$RUN_DIR"
    exit 1
else
    emit_fail "unknown_expect=$LSQ_EXPECT"
fi
