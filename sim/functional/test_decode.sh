#!/usr/bin/env bash
#==============================================================================
# sim/functional/test_decode.sh —— F1 译码包功能定向测试入口（fail-closed）
#==============================================================================
# 项目 : rv32gc-cpu（阶段二 2A 单发射顺序 5 级基线核）
# 依据 : prompts/common.md §3（判定 fail-closed：确定性脚本 + 退出码 + 日志锚点）、
#        F1 译码包验收（唯一整行 `FUNCTIONAL_DECODE: PASS`；rc/超时/缺捕获/坏字段/
#        部分向量/零产物/未知参数 一律失败；明确非零向量数；DUT_ROOT 指向只读源根
#        即可对旧源码复跑同一 TB 做正/负对照）。
#
# 做什么 :
#   1) 用 iverilog 编译**本包固定 TB**（sim/functional/tb_decode_semantics.sv）
#      + DUT_ROOT 下的 4 个译码模块（decoder/dec_imm/dec_csr/compressed_expand）；
#   2) 跑 vvp，把编译/运行输出捕获到**本次独占**的 run 目录；
#   3) 默认 DUT_ROOT = 本仓库根（当前树）；置 DUT_ROOT=<只读源根> 即可对旧源码
#      （`git archive 201acf61 rtl | tar -x -C <dir>`）复跑同一 TB 做正/负对照。
#
# 产物纪律（每次运行互不覆盖、**不删除任何历史文件**）:
#   · 产物根 = RV32_FUNCTIONAL_PKG_OUT_DIR（功能总入口传入，若设置）
#              > OUT_DIR（显式指定）
#              > $REPO_ROOT/build/functional/decode（默认）
#   · 根必须先规范化（readlink -m）并校验位于 $REPO_ROOT/build/functional 之下，
#     再 mkdir；随后 `mktemp -d <根>/run-XXXXXXXX` 建**独占 run 目录**，
#     本次全部产物（编译日志/运行日志/vvp）都写在该独占目录内。
#   · 因每次目录独占，脚本**不做任何 rm**；固定文件名也不会覆盖历史。
#
# 工具真源 : 只从 scripts/env.sh 取 RV32_IVERILOG / RV32_VVP（env.sh 允许读、不可改）；
#            二者仍可被调用方以同名环境变量覆盖 ⇒ 保留"假工具"反证能力。
#            墙钟兜底可用 TIMEOUT_COMPILE_S / TIMEOUT_RUN_S 覆盖（默认 300 s）。
#
# 判定（全部满足才算 PASS，否则 exit 1 且**不打印** PASS 锚点）:
#   · 参数：不接受任何位置参数（未知参数即失败）
#   · 工具：env.sh 可读且 source rc=0；RV32_IVERILOG/RV32_VVP 非空且可执行
#   · 头：4 个 DUT 源 + TB 的 sha256 全部成功（rc=0、行数正确），失败即失败
#   · 编译：rc=0 且产出非空 vvp（rc=0 零产物 ⇒ 失败；超时 ⇒ 失败）
#   · 运行：rc=0（超时 ⇒ 失败）
#   · 实际运行输出：**不得出现任何 `FAIL` 字样**、不得出现 `DEFECT_REPRODUCED`
#   · 摘要：`DECODE_VECTORS` 整行唯一且严格匹配
#           `total=<d> nonzero_insn=<d> checks=<d> fails=<d>`（缺/多/坏字段 ⇒ 失败）
#   · 摘要各字段须严格数字；fails=0；total/nonzero_insn/checks 非零；
#           且必须等于本包冻结规格 SPEC_*（80 向量 / 79 非零 / 260 检查），
#           防止"1 向量自洽摘要"冒充完整包
#           ★ TB 本体同样以 SPEC_* + "每向量至少 1 项检查"自判，本脚本的 SPEC_*
#             是第二道守卫（不能只靠包装器遮盖 TB 自判缺口）
#   · 逐向量：`VEC ` 行数 == total；每行严格匹配
#           `^VEC <d> <name> checks=<d> fails=0$`；各行 checks 之和 == 摘要 checks
#   · 锚点：整行 `FUNCTIONAL_DECODE: PASS` 恰好 1 行
#
# 用法 : bash sim/functional/test_decode.sh
#        DUT_ROOT=<只读源根> bash sim/functional/test_decode.sh
#        OUT_DIR=<产物根>      bash sim/functional/test_decode.sh
# 说明 : 成功时 stdout 仅两行：`DECODE_VECTORS ...` 与 `FUNCTIONAL_DECODE: PASS`。
#==============================================================================
set -u

#------------------------------------------------------------------------------
# 0. 参数：本入口不接受任何位置参数
#------------------------------------------------------------------------------
if [ "$#" -ne 0 ]; then
    printf 'FUNCTIONAL_DECODE: FAIL reason=unknown_arg argv=%s\n' "$*"
    exit 1
fi

TIMEOUT_COMPILE_S="${TIMEOUT_COMPILE_S:-300}"
TIMEOUT_RUN_S="${TIMEOUT_RUN_S:-300}"

#------------------------------------------------------------------------------
# 1. 路径解析（按脚本自身位置推导，不依赖调用者 cwd）
#------------------------------------------------------------------------------
SELF_PATH="${BASH_SOURCE[0]}"
SELF_DIR="$(cd -- "$(dirname -- "$SELF_PATH")" && pwd -P)" || {
    printf 'FUNCTIONAL_DECODE: FAIL reason=self_dir_unresolved\n'; exit 1; }
REPO_ROOT="$(cd -- "$SELF_DIR/../.." && pwd -P)" || {
    printf 'FUNCTIONAL_DECODE: FAIL reason=repo_root_unresolved\n'; exit 1; }
TB_SRC="$SELF_DIR/tb_decode_semantics.sv"
ENV_SH="$REPO_ROOT/scripts/env.sh"

# ---- 本包冻结规格（与 tb_decode_semantics.sv 同步；改 TB 必须同步改这里）----
#      TB 本体也用同名常量自判（SPEC_*），脚本这层是第二道守卫，二者必须一致。
SPEC_TOTAL=80
SPEC_NONZERO=79
SPEC_CHECKS=260

#------------------------------------------------------------------------------
# 2. 判定状态与输出助手（stdout 只放摘要 + 唯一锚点；细节在 run 目录日志）
#------------------------------------------------------------------------------
RUN_LOG=""
SUM_TOTAL="-"; SUM_NONZERO="-"; SUM_CHECKS="-"; SUM_FAILS="-"

emit_summary_line() {
    printf 'DECODE_VECTORS total=%s nonzero_insn=%s checks=%s fails=%s\n' \
        "$SUM_TOTAL" "$SUM_NONZERO" "$SUM_CHECKS" "$SUM_FAILS"
}

emit_fail() {
    emit_summary_line
    printf 'FUNCTIONAL_DECODE: FAIL reason=%s run_dir=%s\n' "$1" "${RUN_LOG%/*}"
    exit 1
}

# 失败路径也尽量报出计数（非判定用；严格判定在 §8 另行重解析）
parse_summary_besteffort() {
    local line
    line="$(grep -m1 '^DECODE_VECTORS ' "$RUN_LOG" 2>/dev/null || true)"
    if [[ "$line" =~ ^DECODE_VECTORS\ total=([0-9]+)\ nonzero_insn=([0-9]+)\ checks=([0-9]+)\ fails=([0-9]+)$ ]]; then
        SUM_TOTAL="${BASH_REMATCH[1]}"
        SUM_NONZERO="${BASH_REMATCH[2]}"
        SUM_CHECKS="${BASH_REMATCH[3]}"
        SUM_FAILS="${BASH_REMATCH[4]}"
    fi
}

#------------------------------------------------------------------------------
# 3. 产物根：规范化 → 授权树校验 → mkdir → mktemp 独占 run 目录（绝不 rm）
#------------------------------------------------------------------------------
AUTH_ROOT="$(readlink -m -- "$REPO_ROOT/build/functional")" || emit_fail "auth_root_readlink_failed"
ROOT_RAW="${RV32_FUNCTIONAL_PKG_OUT_DIR:-${OUT_DIR:-$AUTH_ROOT/decode}}"

is_authorized() {
    case "$1" in
        "$AUTH_ROOT" | "$AUTH_ROOT"/*) return 0 ;;
        *) return 1 ;;
    esac
}

ROOT_NORM="$(readlink -m -- "$ROOT_RAW")" || emit_fail "out_root_readlink_failed root=$ROOT_RAW"
is_authorized "$ROOT_NORM" || emit_fail "out_root_unauthorized root=$ROOT_NORM auth=$AUTH_ROOT"

mkdir -p -- "$ROOT_NORM" || emit_fail "out_root_mkdir_failed root=$ROOT_NORM"
# mkdir 之后再规范化一次（防符号链接/父目录替换绕过授权树）
ROOT_NORM="$(readlink -m -- "$ROOT_NORM")" || emit_fail "out_root_recheck_readlink_failed"
is_authorized "$ROOT_NORM" || emit_fail "out_root_unauthorized_after_mkdir root=$ROOT_NORM"

RUN_DIR="$(mktemp -d -- "$ROOT_NORM/run-XXXXXXXX")" || emit_fail "mktemp_run_dir_failed root=$ROOT_NORM"
RUN_LOG="$RUN_DIR/test_decode.log"
COMPILE_LOG="$RUN_DIR/test_decode.compile.log"
VVP_OUT="$RUN_DIR/tb_decode_semantics.vvp"

: > "$RUN_LOG" || emit_fail "run_log_create_failed"

{
    echo "==== test_decode.sh : F1 decode semantics (functional) ===="
    echo "date            = $(date -Is 2>/dev/null || date)"
    echo "SELF_DIR        = $SELF_DIR"
    echo "REPO_ROOT       = $REPO_ROOT"
    echo "RUN_DIR         = $RUN_DIR"
    echo "ARTIFACT_ROOT   = $ROOT_NORM"
    echo "AUTH_ROOT       = $AUTH_ROOT"
    echo "TB_SRC          = $TB_SRC"
    echo "SPEC            = total=$SPEC_TOTAL nonzero_insn=$SPEC_NONZERO checks=$SPEC_CHECKS"
    if git -C "$REPO_ROOT" rev-parse HEAD >/dev/null 2>&1; then
        echo "GIT_HEAD        = $(git -C "$REPO_ROOT" rev-parse HEAD)"
    else
        echo "GIT_HEAD        = unavailable"
    fi
    echo "=========================================================="
} >> "$RUN_LOG" || emit_fail "run_log_header_failed"

#------------------------------------------------------------------------------
# 4. 工具真源：scripts/env.sh（只读）；工具缺失/不可执行即失败
#------------------------------------------------------------------------------
if [ ! -r "$ENV_SH" ]; then
    emit_fail "env_sh_unreadable path=$ENV_SH"
fi
# env.sh 设计为无副作用、可反复 source；其输出并入本次日志，不污染 stdout。
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
# 5. DUT 源根校验 + 头 SHA（任一步失败即失败，不因未 set -e 而继续）
#------------------------------------------------------------------------------
if [ ! -f "$TB_SRC" ]; then
    emit_fail "tb_missing tb=$TB_SRC"
fi

DUT_ROOT="${DUT_ROOT:-$REPO_ROOT}"
DUT_ROOT="$(cd -- "$DUT_ROOT" 2>/dev/null && pwd -P)" || emit_fail "dut_root_not_found dut=${DUT_ROOT:-unset}"
DUT_RTL_DIR="$DUT_ROOT/rtl/decode"
DUT_FILES=(
    "$DUT_RTL_DIR/decoder.v"
    "$DUT_RTL_DIR/dec_imm.v"
    "$DUT_RTL_DIR/dec_csr.v"
    "$DUT_RTL_DIR/compressed_expand.v"
)
for f in "${DUT_FILES[@]}"; do
    [ -f "$f" ] || emit_fail "dut_src_missing file=$f"
done

SHA_DUT="$(sha256sum -- "${DUT_FILES[@]}" 2>>"$RUN_LOG")"
SHA_RC=$?
[ "$SHA_RC" -eq 0 ] || emit_fail "sha256_dut_rc=$SHA_RC"
N_SHA_LINES="$(printf '%s\n' "$SHA_DUT" | grep -c '^[0-9a-f]\{64\} ' || true)"
[ "$N_SHA_LINES" = "4" ] || emit_fail "sha256_dut_lines=$N_SHA_LINES"

SHA_TB="$(sha256sum -- "$TB_SRC" 2>>"$RUN_LOG")"
SHA_RC=$?
[ "$SHA_RC" -eq 0 ] || emit_fail "sha256_tb_rc=$SHA_RC"
printf '%s\n' "$SHA_TB" | grep -q '^[0-9a-f]\{64\} ' || emit_fail "sha256_tb_bad_line"

{
    echo "-- DUT source sha256 --"
    printf '%s\n' "$SHA_DUT"
    echo "-- TB sha256 --"
    printf '%s\n' "$SHA_TB"
} >> "$RUN_LOG" || emit_fail "run_log_sha_append_failed"

#------------------------------------------------------------------------------
# 6. 编译（DUT 取 DUT_ROOT，TB 恒取本包；rc=0 零产物亦失败）
#    ★ DUT_ROOT 契约（2026-10-19 复审）：编译在**以 DUT_ROOT 为 cwd 的子shell**里执行。
#      原因：Icarus 对 `include "rtl/pkg/..."` 会从**调用者 cwd**解析（实测 cwd 里
#      放一份冲突的 rtl/pkg 头会让正确 DUT_ROOT 的编译直接 rc=2）。本脚本所有
#      源/TB/产物路径均为绝对路径，cd 只影响 include 解析口径、不改变输入输出位置；
#      子shell 隔离保证脚本自身 cwd 与后续步骤不受影响。
#------------------------------------------------------------------------------
(
    cd -- "$DUT_ROOT" || exit 1
    timeout "$TIMEOUT_COMPILE_S" "$IV" -g2012 -I "$DUT_ROOT" \
            -s tb_decode_semantics_top -o "$VVP_OUT" \
            "$TB_SRC" "${DUT_FILES[@]}" > "$COMPILE_LOG" 2>&1
)
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
# 8. 判定（严格格式 + 冻结规格 + 逐向量一致性）
#------------------------------------------------------------------------------
# 8.1 摘要整行唯一且严格匹配（缺/多/坏字段一律失败）
N_SUMMARY="$(grep -c '^DECODE_VECTORS ' "$RUN_LOG" || true)"
[ "$N_SUMMARY" = "1" ] || emit_fail "summary_count=$N_SUMMARY"
SUM_LINE="$(grep -m1 '^DECODE_VECTORS ' "$RUN_LOG" || true)"
if [[ "$SUM_LINE" =~ ^DECODE_VECTORS\ total=([0-9]+)\ nonzero_insn=([0-9]+)\ checks=([0-9]+)\ fails=([0-9]+)$ ]]; then
    SUM_TOTAL="${BASH_REMATCH[1]}"
    SUM_NONZERO="${BASH_REMATCH[2]}"
    SUM_CHECKS="${BASH_REMATCH[3]}"
    SUM_FAILS="${BASH_REMATCH[4]}"
else
    emit_fail "summary_format"
fi

# 8.2 非零约束与 fails=0
[ "$SUM_TOTAL" -ne 0 ] || emit_fail "summary_total_zero"
[ "$SUM_NONZERO" -ne 0 ] || emit_fail "summary_nonzero_zero"
[ "$SUM_CHECKS" -ne 0 ] || emit_fail "summary_checks_zero"
[ "$SUM_FAILS" -eq 0 ] || emit_fail "summary_fails_nz=$SUM_FAILS"

# 8.3 实际运行输出不得含 FAIL / DEFECT_REPRODUCED（任意位置，不限特定前缀）
N_ANYFAIL="$(grep -c 'FAIL' "$RUN_LOG" || true)"
[ "$N_ANYFAIL" = "0" ] || emit_fail "log_has_FAIL=$N_ANYFAIL"
N_DEFECT="$(grep -c 'DEFECT_REPRODUCED' "$RUN_LOG" || true)"
[ "$N_DEFECT" = "0" ] || emit_fail "log_has_defect_reproduced=$N_DEFECT"

# 8.4 冻结规格（防"1 向量自洽摘要"冒充完整包）
[ "$SUM_TOTAL" -eq "$SPEC_TOTAL" ] || emit_fail "summary_total=$SUM_TOTAL expect=$SPEC_TOTAL"
[ "$SUM_NONZERO" -eq "$SPEC_NONZERO" ] || emit_fail "summary_nonzero=$SUM_NONZERO expect=$SPEC_NONZERO"
[ "$SUM_CHECKS" -eq "$SPEC_CHECKS" ] || emit_fail "summary_checks=$SUM_CHECKS expect=$SPEC_CHECKS"

# 8.5 逐向量：行数、严格格式、fails=0、checks 之和
N_VEC="$(grep -c '^VEC ' "$RUN_LOG" || true)"
[ "$N_VEC" -eq "$SUM_TOTAL" ] || emit_fail "vec_line_count=$N_VEC total=$SUM_TOTAL"
VEC_STAT="$(awk '
    /^VEC / {
        if ($0 ~ /^VEC [0-9]+ [^ ]+ checks=[0-9]+ fails=0$/) {
            n++
            for (i = 1; i <= NF; i++) {
                if ($i ~ /^checks=/) { split($i, a, "="); s += a[2] }
            }
        } else {
            b++
        }
    }
    END { printf "%d %d %d\n", n + 0, s + 0, b + 0 }
' "$RUN_LOG")" || emit_fail "vec_awk_failed"
read -r V_OK V_SUM V_BAD <<<"$VEC_STAT"
[ "$V_BAD" = "0" ] || emit_fail "vec_format_bad=$V_BAD"
[ "$V_OK" -eq "$SUM_TOTAL" ] || emit_fail "vec_ok=$V_OK total=$SUM_TOTAL"
[ "$V_SUM" -eq "$SUM_CHECKS" ] || emit_fail "vec_checks_sum=$V_SUM checks=$SUM_CHECKS"

# 8.6 唯一整行 PASS 锚点
N_PASS="$(grep -cxF 'FUNCTIONAL_DECODE: PASS' "$RUN_LOG" || true)"
[ "$N_PASS" = "1" ] || emit_fail "pass_anchor_count=$N_PASS"

#------------------------------------------------------------------------------
# 9. 通过：摘要 + 唯一整行锚点
#------------------------------------------------------------------------------
emit_summary_line
printf 'FUNCTIONAL_DECODE: PASS\n'
exit 0
