#!/usr/bin/env bash
#==============================================================================
# sim/functional/test_data_control.sh —— F4 数据侧 LSQ 最小契约功能入口（fail-closed）
#==============================================================================
# 项目 : rv32gc-cpu（2B 后端 LSQ 叶；Top owner 负责 PMP/PMA/IRQ/kill-drain）
#
# 模式（同一 TB、同一脚本，只换编译宏与期望）：
#   · DC_EXPECT=fixed  （默认）：`-D LSQ_DATA_CTRL` 新接口全量 14 向量/92 检查；
#       要求 fails=0 defect=0 xz=0，唯一 `FUNCTIONAL_DATA_CONTROL: PASS`。
#   · DC_EXPECT=legacy ：`-D LSQ_NEW_PORTS_TIE` 旧接口子集（新 RTL）；
#       新 active 输入显式驱 known 0，不允许 Z 兼容逃生；4 向量/12 检查全绿。
#   · DC_EXPECT=old    ：不定义宏，对 DUT_ROOT（旧树）跑旧接口子集；
#       必须是**旧行为复现**：两个 level 向量 defect=1、fails>0、绝不 PASS，rc=1。
#   · DC_EXPECT=probe  ：新接口 + `+DC_STALE_PROBE`，只证明“Top 必须丢弃跨 flush
#       旧完成”的合同是必要的；要求 marker 恰一次、无 PASS/摘要，rc=0。不是通过。
#
# 源冻结：DUT LSQ / header / TB 运行前后 SHA 一致；sha256sum 原 rc 被捕获。
# 产物：父 PKGOUT（RV32_FUNCTIONAL_PKG_OUT_DIR）> OUT_DIR > build/functional/data-control；
#       根规范化并校验在 build/functional 下，每次 mktemp 独占 run 目录，不 rm。
# 工具：scripts/env.sh 的 RV32_IVERILOG / RV32_VVP（缺失即失败）。
#==============================================================================
set -u

if [ "$#" -ne 0 ]; then
    printf 'FUNCTIONAL_DATA_CONTROL: FAIL reason=unknown_arg argv=%s\n' "$*"
    exit 1
fi

TIMEOUT_COMPILE_S="${TIMEOUT_COMPILE_S:-300}"
TIMEOUT_RUN_S="${TIMEOUT_RUN_S:-300}"
DC_EXPECT="${DC_EXPECT:-fixed}"

SELF_PATH="${BASH_SOURCE[0]}"
SELF_DIR="$(cd -- "$(dirname -- "$SELF_PATH")" && pwd -P)" || {
    printf 'FUNCTIONAL_DATA_CONTROL: FAIL reason=self_dir_unresolved\n'; exit 1; }
REPO_ROOT="$(cd -- "$SELF_DIR/../.." && pwd -P)" || {
    printf 'FUNCTIONAL_DATA_CONTROL: FAIL reason=repo_root_unresolved\n'; exit 1; }
TB_SRC="$SELF_DIR/tb_data_control.sv"
ENV_SH="${REPO_ROOT}/scripts/env.sh"

# ---- 冻结规格（逐向量 id|name|checks；任何少例/错名/零检查/checks 漂移即失败）----
case "$DC_EXPECT" in
fixed)
    SPEC_TOTAL=16; SPEC_CHECKS=113; SPEC_NONZERO=16; SPEC_DEFECT=0
    SPEC_TABLE='1|cdq_level_take_once|4
2|cdq_level_after_drain|2
3|cdq_new_slot_ownership|4
4|cdq_slot_reuse_same_index|6
5|cdq_flush_push_once|3
6|dc_req_bytes_head|17
7|dc_load_cause_af_pf|9
8|dc_illegal_active|7
9|dc_store_xlate_bytes_cause|13
10|dc_store_fault_cause|19
11|dc_defer_nonhead_head_once|10
12|dc_side_token_retire|7
13|dc_squash_side_owner|4
14|dc_flush_no_new_load|2
15|dc_flush_rsp_generation|3
16|dc_squash_rsp_same_cycle|3'
    COMPILE_DEFS=(-D LSQ_DATA_CTRL)
    ;;
legacy)
    SPEC_TOTAL=5; SPEC_CHECKS=19; SPEC_NONZERO=5; SPEC_DEFECT=0
    SPEC_TABLE='1|cdq_level_take_once|4
2|cdq_level_after_drain|2
3|cdq_new_slot_ownership|4
4|cdq_slot_reuse_same_index|6
5|cdq_flush_push_once|3'
    COMPILE_DEFS=(-D LSQ_NEW_PORTS_TIE)
    ;;
old)
    SPEC_TOTAL=5; SPEC_CHECKS=19; SPEC_NONZERO=5; SPEC_DEFECT=2
    SPEC_TABLE='1|cdq_level_take_once|4
2|cdq_level_after_drain|2
3|cdq_new_slot_ownership|4
4|cdq_slot_reuse_same_index|6
5|cdq_flush_push_once|3'
    COMPILE_DEFS=()
    ;;
probe)
    SPEC_TOTAL=0; SPEC_CHECKS=0; SPEC_NONZERO=0; SPEC_DEFECT=0
    SPEC_TABLE=''
    COMPILE_DEFS=(-D LSQ_DATA_CTRL)
    ;;
*)
    printf 'FUNCTIONAL_DATA_CONTROL: FAIL reason=unknown_expect=%s\n' "$DC_EXPECT"; exit 1 ;;
esac

RUN_LOG=""; SUM_TOTAL="-"; SUM_NONZERO="-"; SUM_CHECKS="-"; SUM_FAILS="-"
SUM_DEFECT="-"; SUM_XZ="-"

emit_summary() {
    printf 'DC_VECTORS total=%s nonzero=%s checks=%s fails=%s defect=%s xz=%s\n' \
        "$SUM_TOTAL" "$SUM_NONZERO" "$SUM_CHECKS" "$SUM_FAILS" "$SUM_DEFECT" "$SUM_XZ"
}
emit_fail() {
    emit_summary
    printf 'FUNCTIONAL_DATA_CONTROL: FAIL reason=%s run_dir=%s\n' "$1" "${RUN_LOG%/*}"
    exit 1
}

# ---- 产物根 ----
AUTH_ROOT="$(readlink -m -- "$REPO_ROOT/build/functional")" || emit_fail "auth_root_readlink_failed"
ROOT_RAW="${RV32_FUNCTIONAL_PKG_OUT_DIR:-${OUT_DIR:-$AUTH_ROOT/data-control}}"
case "$(readlink -m -- "$ROOT_RAW")" in
    "$AUTH_ROOT" | "$AUTH_ROOT"/*) : ;;
    *) emit_fail "out_root_unauthorized root=$(readlink -m -- "$ROOT_RAW")" ;;
esac
mkdir -p -- "$(readlink -m -- "$ROOT_RAW")" || emit_fail "out_root_mkdir_failed"
ROOT_NORM="$(readlink -m -- "$ROOT_RAW")" || emit_fail "out_root_readlink_failed"
RUN_DIR="$(mktemp -d -- "$ROOT_NORM/run-XXXXXXXX")" || emit_fail "mktemp_failed root=$ROOT_NORM"
RUN_LOG="$RUN_DIR/test_data_control.log"
COMPILE_LOG="$RUN_DIR/compile.log"
VVP_OUT="$RUN_DIR/tb_data_control.vvp"
: > "$RUN_LOG" || emit_fail "run_log_create_failed"

{
    echo "==== test_data_control.sh : F4 data-side LSQ contract ===="
    echo "date         = $(date -Is 2>/dev/null || date)"
    echo "REPO_ROOT    = $REPO_ROOT"
    echo "RUN_DIR      = $RUN_DIR"
    echo "DC_EXPECT    = $DC_EXPECT"
    echo "SPEC         = total=$SPEC_TOTAL nonzero=$SPEC_NONZERO checks=$SPEC_CHECKS defect=$SPEC_DEFECT"
    printf '%s\n' "$SPEC_TABLE" | sed 's/^/SPEC_TABLE    = /'
} >> "$RUN_LOG" || emit_fail "run_log_header_failed"

# ---- 工具 ----
[ -r "$ENV_SH" ] || emit_fail "env_sh_unreadable path=$ENV_SH"
# shellcheck disable=SC1090
. "$ENV_SH" >> "$RUN_LOG" 2>&1
ENV_RC=$?
[ "$ENV_RC" -eq 0 ] || emit_fail "env_sh_source_rc=$ENV_RC"
IV="${RV32_IVERILOG:-}"; VV="${RV32_VVP:-}"
[ -n "$IV" ] && [ -x "$IV" ] || emit_fail "tool_missing RV32_IVERILOG=${IV:-unset}"
[ -n "$VV" ] && [ -x "$VV" ] || emit_fail "tool_missing RV32_VVP=${VV:-unset}"
echo "RV32_IVERILOG = $IV" >> "$RUN_LOG"
echo "RV32_VVP      = $VV" >> "$RUN_LOG"

# ---- DUT 源根 ----
[ -f "$TB_SRC" ] || emit_fail "tb_missing tb=$TB_SRC"
DUT_ROOT="${DUT_ROOT:-$REPO_ROOT}"
DUT_ROOT="$(cd -- "$DUT_ROOT" 2>/dev/null && pwd -P)" || emit_fail "dut_root_not_found"
DUT_LSQ="$DUT_ROOT/rtl/back2/lsq_simple.v"
DUT_HDR="$DUT_ROOT/rtl/back2/back2_params.vh"
[ -f "$DUT_LSQ" ] || emit_fail "dut_src_missing file=$DUT_LSQ"
[ -f "$DUT_HDR" ] || emit_fail "dut_header_missing file=$DUT_HDR"

FREEZE_ERR=""
freeze_sha() {  # 原始 stdout 文件+原 rc；验证字节及逐路径后再返回规范清单
    local raw="$1" rc reason
    FREEZE_ERR=""
    sha256sum -- "$DUT_LSQ" "$DUT_HDR" "$TB_SRC" >"$raw" 2>>"$RUN_LOG"
    rc=$?
    [ "$rc" -eq 0 ] || { FREEZE_ERR="sha256sum_rc=$rc"; return 1; }
    reason="$(python3 - "$raw" "$DUT_LSQ" "$DUT_HDR" "$TB_SRC" <<'PY'
import os, pathlib, re, sys
raw = pathlib.Path(sys.argv[1]).read_bytes()
paths = sys.argv[2:]
if b'\0' in raw or b'\r' in raw:
    print('sha256_bytes'); raise SystemExit(1)
if not raw.endswith(b'\n'):
    print('sha256_unterminated'); raise SystemExit(1)
rows = raw.split(b'\n')[:-1]
if len(rows) != len(paths):
    print(f'sha256_lines={len(rows)}'); raise SystemExit(1)
for i, (row, path) in enumerate(zip(rows, paths), 1):
    m = re.fullmatch(rb'([0-9a-f]{64})  (.*)', row)
    if not m:
        print(f'sha256_format line={i}'); raise SystemExit(1)
    if m.group(2) != os.fsencode(path):
        print(f'sha256_path line={i}'); raise SystemExit(1)
print('ok')
PY
)" || { FREEZE_ERR="${reason:-sha256_format}"; return 1; }
}
normalize_sha_file() { awk '{print substr($0,1,64)}' "$1"; }
SHA_PRE_RAW="$RUN_DIR/sha_pre.raw"
SHA_POST_RAW="$RUN_DIR/sha_post.raw"
if freeze_sha "$SHA_PRE_RAW"; then :; else
    emit_fail "${FREEZE_ERR:-sha256_pre_failed}"
fi
SHA_PRE="$(normalize_sha_file "$SHA_PRE_RAW")" || emit_fail "sha256_pre_normalize_failed"
{ echo "-- pre-run sha256 (DUT/header/TB) --"; cat -- "$SHA_PRE_RAW"; } >> "$RUN_LOG"

# ---- 编译（在 DUT_ROOT 快照 cwd 内；TB 恒取本包）----
(
    cd -- "$DUT_ROOT" || exit 91
    exec timeout "$TIMEOUT_COMPILE_S" "$IV" -g2012 -Wall -I "$DUT_ROOT" \
        "${COMPILE_DEFS[@]}" -s tb_data_control_top -o "$VVP_OUT" \
        "$TB_SRC" "$DUT_LSQ"
) > "$COMPILE_LOG" 2>&1
RC=$?
cat -- "$COMPILE_LOG" >> "$RUN_LOG"
[ "$RC" -eq 124 ] && emit_fail "compile_timeout"
[ "$RC" -ne 0 ] && emit_fail "compile_rc=$RC"
[ -s "$VVP_OUT" ] || emit_fail "compile_no_vvp_output"

# ---- 运行 ----
if [ "$DC_EXPECT" = "probe" ]; then
    timeout "$TIMEOUT_RUN_S" "$VV" "$VVP_OUT" +DC_STALE_PROBE >> "$RUN_LOG" 2>&1
else
    timeout "$TIMEOUT_RUN_S" "$VV" "$VVP_OUT" >> "$RUN_LOG" 2>&1
fi
RC=$?
if [ "$RC" -eq 124 ]; then emit_fail "run_timeout"; fi
if [ "$RC" -ne 0 ]; then
    # 旧树反证允许 TB 内部 F A I L 文本，但 vvp 自身 rc 必须为 0（显式 rc≠0 仍拒）。
    emit_fail "run_rc=$RC"
fi
[ -s "$RUN_LOG" ] || emit_fail "run_zero_output"

# ---- 源冻结复核 ----
if freeze_sha "$SHA_POST_RAW"; then :; else
    emit_fail "${FREEZE_ERR:-sha256_post_failed}"
fi
cmp -s -- "$SHA_PRE_RAW" "$SHA_POST_RAW" || emit_fail "source_changed_during_run"

# ---- probe 模式 ----
if [ "$DC_EXPECT" = "probe" ]; then
    N_MARK="$(grep -cxF 'DC_STALE_PROBE_CONFIRMED' "$RUN_LOG" || true)"
    [ "$N_MARK" = "1" ] || emit_fail "stale_probe_marker_count=$N_MARK"
    N_PASS="$(grep -cxF 'FUNCTIONAL_DATA_CONTROL: PASS' "$RUN_LOG" || true)"
    [ "$N_PASS" = "0" ] || emit_fail "probe_printed_pass"
    N_SUM="$(grep -c '^DC_VECTORS ' "$RUN_LOG" || true)"
    [ "$N_SUM" = "0" ] || emit_fail "probe_printed_summary"
    printf 'FUNCTIONAL_DATA_CONTROL: PROBE_CONFIRMED\n'
    exit 0
fi

# ---- 摘要/向量严格解析 ----
N_SUMMARY="$(grep -c '^DC_VECTORS ' "$RUN_LOG" || true)"
[ "$N_SUMMARY" = "1" ] || emit_fail "summary_count=$N_SUMMARY"
SUM_LINE="$(grep -m1 '^DC_VECTORS ' "$RUN_LOG" || true)"
if [[ "$SUM_LINE" =~ ^DC_VECTORS\ total=([0-9]+)\ nonzero=([0-9]+)\ checks=([0-9]+)\ fails=([0-9]+)\ defect=([0-9]+)\ xz=([0-9]+)$ ]]; then
    SUM_TOTAL="${BASH_REMATCH[1]}"; SUM_NONZERO="${BASH_REMATCH[2]}"
    SUM_CHECKS="${BASH_REMATCH[3]}"; SUM_FAILS="${BASH_REMATCH[4]}"
    SUM_DEFECT="${BASH_REMATCH[5]}"; SUM_XZ="${BASH_REMATCH[6]}"
else
    emit_fail "summary_format"
fi
[ "$SUM_TOTAL"   -eq "$SPEC_TOTAL"   ] || emit_fail "summary_total=$SUM_TOTAL expect=$SPEC_TOTAL"
[ "$SUM_NONZERO" -eq "$SPEC_NONZERO" ] || emit_fail "summary_nonzero=$SUM_NONZERO expect=$SPEC_NONZERO"
[ "$SUM_CHECKS"  -eq "$SPEC_CHECKS"  ] || emit_fail "summary_checks=$SUM_CHECKS expect=$SPEC_CHECKS"
#   旧树允许 fails>0/defect=2；其它模式必须零。
if [ "$DC_EXPECT" != "old" ]; then
    [ "$SUM_FAILS"  -eq 0 ] || emit_fail "summary_fails=$SUM_FAILS"
    [ "$SUM_DEFECT" -eq 0 ] || emit_fail "summary_defect=$SUM_DEFECT"
fi
[ "$SUM_XZ" -eq 0 ] || emit_fail "summary_xz=$SUM_XZ"

N_VEC="$(grep -c '^VEC ' "$RUN_LOG" || true)"
[ "$N_VEC" -eq "$SUM_TOTAL" ] || emit_fail "vec_line_count=$N_VEC total=$SUM_TOTAL"
ACTUAL_ROWS="$(awk '/^VEC /{ if ($0 ~ /^VEC [0-9]+ [^ ]+ checks=[0-9]+ fails=[0-9]+ defect=[0-1]$/) {c=$4; sub(/^checks=/,"",c); print $2"|"$3"|"c} else {print "BAD"}}' "$RUN_LOG")"
if printf '%s\n' "$ACTUAL_ROWS" | grep -qx 'BAD'; then emit_fail "vec_format_bad"; fi
if ! diff <(printf '%s\n' "$SPEC_TABLE") <(printf '%s\n' "$ACTUAL_ROWS") >/dev/null; then
    emit_fail "spec_table_mismatch"
fi
V_SUM="$(awk '/^VEC /{for(i=1;i<=NF;i++) if($i ~ /^checks=/){split($i,a,"=");s+=a[2]}} END{print s+0}' "$RUN_LOG")"
[ "$V_SUM" -eq "$SUM_CHECKS" ] || emit_fail "vec_checks_sum=$V_SUM checks=$SUM_CHECKS"

vec_line() { grep -m1 -- "^VEC [0-9]\+ $1 checks=" "$RUN_LOG" || true; }
vec_field() { vec_line "$1" | sed -n "s/.*[[:space:]]$2=\([0-9]\+\).*/\1/p"; }

N_FAILTXT="$(grep -c 'FAIL' "$RUN_LOG" || true)"
N_DEFECT="$(grep -c 'DEFECT_REPRODUCED' "$RUN_LOG" || true)"
N_PASS="$(grep -cxF 'FUNCTIONAL_DATA_CONTROL: PASS' "$RUN_LOG" || true)"
N_INTERNAL_FAIL="$(grep -c 'FUNCTIONAL_DATA_CONTROL: FAIL internal_checks' "$RUN_LOG" || true)"

if [ "$DC_EXPECT" = "fixed" ] || [ "$DC_EXPECT" = "legacy" ]; then
    [ "$N_FAILTXT" = "0" ] || emit_fail "log_has_FAIL=$N_FAILTXT"
    [ "$N_DEFECT" = "0" ] || emit_fail "log_has_defect_reproduced=$N_DEFECT"
    [ "$N_PASS" = "1" ] || emit_fail "pass_anchor_count=$N_PASS"
    [ "$N_INTERNAL_FAIL" = "0" ] || emit_fail "internal_fail_marker"
    emit_summary
    printf 'FUNCTIONAL_DATA_CONTROL: PASS\n'
    exit 0
elif [ "$DC_EXPECT" = "old" ]; then
    [ "$SUM_DEFECT" -eq "$SPEC_DEFECT" ] || emit_fail "old_defect=$SUM_DEFECT expect=$SPEC_DEFECT"
    [ "$SUM_FAILS" -gt 0 ] || emit_fail "old_no_failure_observed"
    [ "$N_PASS" = "0" ] || emit_fail "old_mode_printed_pass"
    for rn in cdq_level_take_once cdq_level_after_drain; do
        [ "$(vec_field "$rn" defect)" = "1" ] || emit_fail "old_missing_defect vec=$rn"
    done
    #   控制向量必须在旧树也全绿（缺陷不得被"别例失败"冒充；具体 reason 是重复 take）。
    for cv in cdq_new_slot_ownership cdq_slot_reuse_same_index cdq_flush_push_once; do
        [ "$(vec_field "$cv" fails)" = "0" ] || emit_fail "old_control_fails vec=$cv"
        [ "$(vec_field "$cv" defect)" = "0" ] || emit_fail "old_control_defect vec=$cv"
    done
    emit_summary
    printf 'FUNCTIONAL_DATA_CONTROL: DEFECT_REPRODUCED root=cdq_take_duplicate\n'
    printf 'FUNCTIONAL_DATA_CONTROL: FAIL reason=old_tree_defects_confirmed run_dir=%s\n' "$RUN_DIR"
    exit 1
else
    emit_fail "unknown_expect=$DC_EXPECT"
fi
