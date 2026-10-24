#!/usr/bin/env bash
#==============================================================================
# sim/functional/test_rob_window_driver.sh —— ROB 窗口包**反证/冻结驱动**
#==============================================================================
# 项目 : rv32gc-cpu（阶段二后端；P1 ROB 窗口语义 + 测试基础设施审阅 P1）
# 依赖 : sim/functional/test_rob_window.sh（包入口，唯一锚点来源）
#
# 做什么 :
#   1) 正控 default（11/11 OK）、反证 --negative（defect 候选：e_ok/e_bad 全去）、
#      --b227（母冻结的 e_bad=flush-only 旧候选：原 0..7+9+10 绿、新 case8 红）、
#      --mut-hpv（stuck0 / &done 变异必须让 case10 红）、--harness-selftest
#      （任意 DEFECT/异号 COV 的合成日志杀伤路径）。
#   2) 每一相前后冻结**实际 DUT_ROOT 的完整 7 输入 + driver 自身**（rob.v /
#      rob_wide_mem.v / back2_params.vh / TB / pkg / driver / scripts/env.sh）；
#      任一相间变化即失败；b227 冻结源另按 SHA 前后复核。
#   3) 每 caller 的 sha 捕获都走 `strict_sha`：先收 `file_sha` 的**原始 rc**，再核
#      非空/64 小写 hex/精确路径；self-test 用 exit9/空/多行/坏格式假工具反证。
#   4) self-test：validators 正反 fixture、sha 假工具、7 输入逐一突变必须被冻结矩阵拒。
#
# 支持边界（审阅 P1：执行输入不得与冻结矩阵错位）:
#   · 主 DUT_ROOT 必须 canonical == 实际 REPO_ROOT；跨根 DUT_ROOT 不支持，直接拒
#     `unsupported_cross_dut_root`（不扩第 8 输入、不做跨根映射）。
#   · `ROB_WINDOW_PKG_SH` 只允许缺省或显式指向同根默认包；其它 override 直接拒
#     `unsupported_pkg_override`（冻结矩阵固定 pkg，不允许包/冻结错位）。
#   · `RV32_FUNCTIONAL_PKG_OUT_DIR` 允许同根父输出树（必须在 build/functional 下）。
#   · b227 旧候选默认 = in-tree 正式 fixture `sim/functional/fixtures/rob_window_b227`
#     （干净 checkout 可重建）；`RV32_ROBWIN_B227_ROOT` 可显式指向外部只读副本，
#     但三依赖身份必须与 fixture 钉死 SHA 一致；不 fallback 母本机 r0 目录。
#   · self-test 内部的模拟 root（$DRV/fix/dut 冻结突变）不是 CLI 入口，不受上述限制。
#   · driver 实际 SELF 就是冻结矩阵中同根的 sim/functional/test_rob_window_driver.sh。
#   · 冻结矩阵 = 原 7 输入 + b227 正式 fixture 三依赖 = 10 项（真实新增，如实纳入）。
#
# 产物纪律：全部产物落 `$REPO_ROOT/build/functional/rob-window/` 的独占 driver 目录，
#          `mktemp -d` 分配，不删除历史。
#
# 用法 : bash sim/functional/test_rob_window_driver.sh
#        bash sim/functional/test_rob_window_driver.sh --self-test
#==============================================================================
set -u

SELF_PATH="${BASH_SOURCE[0]}"
SELF_DIR="$(cd -- "$(dirname -- "$SELF_PATH")" && pwd -P)" || {
    printf 'ROB_WINDOW_DRIVER: FAIL reason=self_dir_unresolved\n'; exit 1; }
REPO_ROOT="$(cd -- "$SELF_DIR/../.." && pwd -P)" || {
    printf 'ROB_WINDOW_DRIVER: FAIL reason=repo_root_unresolved\n'; exit 1; }
DEFAULT_PKG="$REPO_ROOT/sim/functional/test_rob_window.sh"

#   ★ CLI 执行输入边界（只约束 CLI 入口；内部 self-test 的模拟 root 不走这里）
cli_boundary() {
    local pkg_env="${ROB_WINDOW_PKG_SH:-}" dut_env="${DUT_ROOT:-}" out_env="${RV32_FUNCTIONAL_PKG_OUT_DIR:-}" canon
    if [ -n "$pkg_env" ]; then
        canon="$(readlink -m -- "$pkg_env" 2>/dev/null)" || {
            printf 'ROB_WINDOW_DRIVER: FAIL reason=unsupported_pkg_override env=%s canonical=<unresolvable> allowed=%s\n' \
                   "$pkg_env" "$DEFAULT_PKG"; return 1; }
        if [ "$canon" != "$DEFAULT_PKG" ]; then
            printf 'ROB_WINDOW_DRIVER: FAIL reason=unsupported_pkg_override env=%s canonical=%s allowed=%s\n' \
                   "$pkg_env" "$canon" "$DEFAULT_PKG"; return 1
        fi
    fi
    if [ -n "$dut_env" ]; then
        canon="$(readlink -m -- "$dut_env" 2>/dev/null)" || {
            printf 'ROB_WINDOW_DRIVER: FAIL reason=unsupported_cross_dut_root env=%s canonical=<unresolvable> repo=%s\n' \
                   "$dut_env" "$REPO_ROOT"; return 1; }
        if [ "$canon" != "$REPO_ROOT" ]; then
            printf 'ROB_WINDOW_DRIVER: FAIL reason=unsupported_cross_dut_root env=%s canonical=%s repo=%s\n' \
                   "$dut_env" "$canon" "$REPO_ROOT"; return 1
        fi
    fi
    if [ -n "$out_env" ]; then
        canon="$(readlink -m -- "$out_env" 2>/dev/null)" || {
            printf 'ROB_WINDOW_DRIVER: FAIL reason=unsupported_pkgo_unresolvable env=%s\n' "$out_env"; return 1; }
        case "$canon" in
            "$REPO_ROOT/build/functional"|"$REPO_ROOT/build/functional"/*) ;;
            *) printf 'ROB_WINDOW_DRIVER: FAIL reason=unsupported_pkgo_unauthorized env=%s canonical=%s allowed_root=%s\n' \
                      "$out_env" "$canon" "$REPO_ROOT/build/functional"; return 1 ;;
        esac
    fi
    return 0
}

#   --cli-probe：只做边界判定（self-test 用；不建 DRV、不跑五相）
if [ "$#" -eq 1 ] && [ "$1" = "--cli-probe" ]; then
    cli_boundary || exit 1
    printf 'ROB_WINDOW_CLI_PROBE: PASS\n'
    exit 0
fi
if [ "$#" -gt 1 ]; then
    printf 'ROB_WINDOW_DRIVER: FAIL reason=unknown_arg argv=%s\n' "$*"; exit 1
fi
if [ "$#" -eq 1 ] && [ "$1" != "--self-test" ]; then
    printf 'ROB_WINDOW_DRIVER: FAIL reason=unknown_arg argv=%s\n' "$1"; exit 1
fi

cli_boundary || exit 1
DUT_ROOT="$REPO_ROOT"
PKG_SH="$DEFAULT_PKG"
TB_SRC="$DUT_ROOT/sim/functional/tb_rob_window_semantics.sv"
ROB_SRC="$DUT_ROOT/rtl/back2/rob.v"
B227_ROOT="${RV32_ROBWIN_B227_ROOT:-$REPO_ROOT/sim/functional/fixtures/rob_window_b227}"
B227_ROB_SHA="b227f017a03d8d90af02e9113f823a48a4ae63963443b0fe72b765953ccb05b5"
B227_WIDE_SHA="41ae6420e434b7748f62a0a8f3e09685723d97c78890fc6e2c327f2f9e0f41fc"
B227_PARAMS_SHA="066c8a7a30eac41c81f64788a3c3f80c4330f2ebec908ba5f940ad9bd1b48e34"
#   ★ 实际 DUT_ROOT / b227 根必须传给子包，冻结与包内快照才指向同一组源。
export DUT_ROOT
export RV32_ROBWIN_B227_ROOT="$B227_ROOT"

MODE="full"
if [ "$#" -eq 1 ] && [ "$1" = "--self-test" ]; then
    MODE="selftest"
fi

[ -f "$PKG_SH" ] || { printf 'ROB_WINDOW_DRIVER: FAIL reason=pkg_missing path=%s\n' "$PKG_SH"; exit 1; }

AUTH_ROOT="$(readlink -m -- "$REPO_ROOT/build/functional")" || {
    printf 'ROB_WINDOW_DRIVER: FAIL reason=auth_root_readlink_failed\n'; exit 1; }
ROOT_RAW="${RV32_FUNCTIONAL_PKG_OUT_DIR:-$AUTH_ROOT/rob-window}"
case "$(readlink -m -- "$ROOT_RAW")" in
    "$AUTH_ROOT" | "$AUTH_ROOT"/*) : ;;
    *) printf 'ROB_WINDOW_DRIVER: FAIL reason=out_root_unauthorized root=%s\n' "$ROOT_RAW"; exit 1 ;;
esac
mkdir -p -- "$(readlink -m -- "$ROOT_RAW")" || {
    printf 'ROB_WINDOW_DRIVER: FAIL reason=out_root_mkdir_failed\n'; exit 1; }
ROOT_NORM="$(readlink -m -- "$ROOT_RAW")"
DRV="$(mktemp -d -- "$ROOT_NORM/driver-XXXXXXXX")" || {
    printf 'ROB_WINDOW_DRIVER: FAIL reason=mktemp_run_dir_failed root=%s\n' "$ROOT_NORM"; exit 1; }
DRV_LOG="$DRV/driver.log"
: > "$DRV_LOG" || { printf 'ROB_WINDOW_DRIVER: FAIL reason=driver_log_create_failed\n'; exit 1; }

note() { printf '%s\n' "$*" >> "$DRV_LOG"; }
fail() {
    note "DRIVER_FAIL reason=$1"
    printf 'ROB_WINDOW_DRIVER: FAIL reason=%s run_dir=%s\n' "$1" "$DRV"
    exit 1
}

#------------------------------------------------------------------------------
# S. SHA 收口：file_sha 只把 hash 写 stdout、原 rc 由 strict_sha 捕获；
#    所有 caller 都先 rc/non-empty/64hex，不做 `[ "$(sha)" = "$(sha)" ]`。
#------------------------------------------------------------------------------
file_sha() {  # $1=path；成功 stdout=64hex；失败 rc!=0（错误只进 DRV_LOG）
    local raw rc total line h
    raw="$(mktemp -- "$DRV/sha-raw-XXXXXXXX")" || return 1
    sha256sum -- "$1" > "$raw" 2>>"$DRV_LOG"; rc=$?
    [ "$rc" -eq 0 ] || { printf 'sha256_failed path=%s rc=%s\n' "$1" "$rc" >> "$DRV_LOG"; return 1; }
    total="$(wc -l < "$raw")"
    [ "$total" -eq 1 ] || { printf 'sha256_lines path=%s lines=%s\n' "$1" "$total" >> "$DRV_LOG"; return 1; }
    IFS= read -r line < "$raw" || { printf 'sha256_unterminated path=%s\n' "$1" >> "$DRV_LOG"; return 1; }
    printf '%s\n' "$line" | cmp -s - "$raw" \
        || { printf 'sha256_raw_bytes path=%s\n' "$1" >> "$DRV_LOG"; return 1; }
    h="${line:0:64}"
    is_sha_value "$h" && [ "${line:64:2}" = '  ' ] && [ "${line:66}" = "$1" ] \
        || { printf 'sha256_format_or_path path=%s\n' "$1" >> "$DRV_LOG"; return 1; }
    printf '%s' "$h"
}

is_sha_value() {
    case "${1:-}" in ''|*[!0-9a-f]*) return 1;; esac
    [ "${#1}" -eq 64 ]
}

strict_sha() {  # $1=变量名 $2=path；成功 printf -v，失败 rc!=0（不吞）
    local __sha_val rc
    __sha_val="$(file_sha "$2")"; rc=$?
    if [ "$rc" -ne 0 ]; then
        printf 'strict_sha: file_sha rc=%s path=%s\n' "$rc" "$2" >> "$DRV_LOG"; return 1
    fi
    if [ -z "$__sha_val" ] || ! is_sha_value "$__sha_val"; then
        printf 'strict_sha: empty/malformed hash path=%s value=%s\n' "$2" "${__sha_val:-<empty>}" >> "$DRV_LOG"
        return 1
    fi
    printf -v "$1" '%s' "$__sha_val"
    return 0
}

#------------------------------------------------------------------------------
# V. 输出判定（自检复用；default/negative/b227/hpv/harness）
#------------------------------------------------------------------------------
defect_only_in() {  # $1=out $2=允许含 DEFECT 的行前缀
    local out="$1" keep="$2" n
    n="$(grep 'DEFECT' "$out" | grep -vcE "^${keep}" || true)"
    [ "$n" = "0" ]
}

validate_default() {
    local out="$1" rc="$2" n_sum sum
    [ "$rc" -eq 0 ] && [ -s "$out" ] || return 1
    [ "$(grep -cxF 'FUNCTIONAL_ROB_WINDOW: PASS' "$out" || true)" = "1" ] || return 1
    for a in 'FUNCTIONAL_ROB_WINDOW_NEGATIVE: PASS' 'FUNCTIONAL_ROB_WINDOW_B227: PASS' \
             'FUNCTIONAL_ROB_WINDOW_HPV: PASS' 'ROB_WINDOW_HARNESS_SELFTEST: PASS' \
             'FUNCTIONAL_ROB_WINDOW_B227_SELFTEST: PASS'; do
        [ "$(grep -cxF "$a" "$out" || true)" = "0" ] || return 1
    done
    n_sum="$(grep -c '^ROB_WINDOW_VECTORS ' "$out" || true)"; [ "$n_sum" = "1" ] || return 1
    sum="$(grep -m1 '^ROB_WINDOW_VECTORS ' "$out" || true)"
    printf '%s\n' "$sum" | grep -qE '^ROB_WINDOW_VECTORS total=11 trigger=8 control=3 ok=11 bad=0$' || return 1
    [ "$(grep -c 'FAIL' "$out" || true)" = "0" ] || return 1
    [ "$(grep -c 'DEFECT' "$out" || true)" = "0" ] || return 1
    [ "$(grep -c 'MISMATCH' "$out" || true)" = "0" ] || return 1
    return 0
}

validate_negative() {
    local out="$1" rc="$2" n sum
    [ "$rc" -eq 0 ] && [ -s "$out" ] || return 1
    [ "$(grep -cxF 'FUNCTIONAL_ROB_WINDOW_NEGATIVE: PASS' "$out" || true)" = "1" ] || return 1
    [ "$(grep -cxF 'FUNCTIONAL_ROB_WINDOW: PASS' "$out" || true)" = "0" ] || return 1
    [ "$(grep -cxF 'FUNCTIONAL_ROB_WINDOW_B227: PASS' "$out" || true)" = "0" ] || return 1
    [ "$(grep -cxF 'FUNCTIONAL_ROB_WINDOW_B227_SELFTEST: PASS' "$out" || true)" = "0" ] || return 1
    [ "$(grep -c '^ROB_WINDOW_CANDIDATE removed_guard_mutation source=generated_from_fixed_rob$' "$out" || true)" = "1" ] || return 1
    n="$(grep -c '^ROB_WINDOW_NEGATIVE_MATRIX ' "$out" || true)"; [ "$n" = "1" ] || return 1
    sum="$(grep -m1 '^ROB_WINDOW_NEGATIVE_MATRIX ' "$out" || true)"
    printf '%s\n' "$sum" | grep -qE \
        '^ROB_WINDOW_NEGATIVE_MATRIX old_trigger=8/8 old_control=2/2 old_case9=DEFECT_SIG old_raw=[1-9][0-9]* new_ok=11/11 defect=e_ok_bad_removed$' \
        || return 1
    [ "$(grep -c 'FAIL' "$out" || true)" = "0" ] || return 1
    defect_only_in "$out" '^ROB_WINDOW_NEGATIVE_MATRIX ' || return 1
    return 0
}

validate_b227() {
    local out="$1" rc="$2" n sum
    [ "$rc" -eq 0 ] && [ -s "$out" ] || return 1
    [ "$(grep -cxF 'FUNCTIONAL_ROB_WINDOW_B227: PASS' "$out" || true)" = "1" ] || return 1
    [ "$(grep -cxF 'FUNCTIONAL_ROB_WINDOW: PASS' "$out" || true)" = "0" ] || return 1
    [ "$(grep -cxF 'FUNCTIONAL_ROB_WINDOW_NEGATIVE: PASS' "$out" || true)" = "0" ] || return 1
    [ "$(grep -cxF 'FUNCTIONAL_ROB_WINDOW_B227_SELFTEST: PASS' "$out" || true)" = "0" ] || return 1
    [ "$(grep -c '^ROB_WINDOW_CANDIDATE b227_original_fixture root=' "$out" || true)" = "1" ] || return 1
    n="$(grep -c '^ROB_WINDOW_B227_MATRIX ' "$out" || true)"; [ "$n" = "1" ] || return 1
    sum="$(grep -m1 '^ROB_WINDOW_B227_MATRIX ' "$out" || true)"
    printf '%s\n' "$sum" | grep -qE \
        '^ROB_WINDOW_B227_MATRIX old_ok=10/10 old_case8=DEFECT_SIG control_ok=2/2 new_ok=11/11 root=b227$' \
        || return 1
    [ "$(grep -c 'FAIL' "$out" || true)" = "0" ] || return 1
    defect_only_in "$out" '^ROB_WINDOW_B227_MATRIX ' || return 1
    return 0
}

validate_b227_self() {
    local out="$1" rc="$2" n sum
    [ "$rc" -eq 0 ] && [ -s "$out" ] || return 1
    [ "$(grep -cxF 'FUNCTIONAL_ROB_WINDOW_B227_SELFTEST: PASS' "$out" || true)" = "1" ] || return 1
    for a in 'FUNCTIONAL_ROB_WINDOW: PASS' 'FUNCTIONAL_ROB_WINDOW_NEGATIVE: PASS' \
             'FUNCTIONAL_ROB_WINDOW_B227: PASS' 'FUNCTIONAL_ROB_WINDOW_HPV: PASS' \
             'ROB_WINDOW_HARNESS_SELFTEST: PASS'; do
        [ "$(grep -cxF "$a" "$out" || true)" = "0" ] || return 1
    done
    n="$(grep -c '^ROB_WINDOW_B227_ID_MATRIX ' "$out" || true)"; [ "$n" = "1" ] || return 1
    sum="$(grep -m1 '^ROB_WINDOW_B227_ID_MATRIX ' "$out" || true)"
    [ "$sum" = 'ROB_WINDOW_B227_ID_MATRIX identity=ok missing=red rob_mut=red wide_mut=red header_mut=red default_root=in_tree' ] || return 1
    [ "$(grep -c 'FAIL' "$out" || true)" = "0" ] || return 1
    [ "$(grep -c 'DEFECT' "$out" || true)" = "0" ] || return 1
    return 0
}

validate_hpv() {
    local out="$1" rc="$2" n sum
    [ "$rc" -eq 0 ] && [ -s "$out" ] || return 1
    [ "$(grep -cxF 'FUNCTIONAL_ROB_WINDOW_HPV: PASS' "$out" || true)" = "1" ] || return 1
    for a in 'FUNCTIONAL_ROB_WINDOW: PASS' 'FUNCTIONAL_ROB_WINDOW_NEGATIVE: PASS' \
             'FUNCTIONAL_ROB_WINDOW_B227: PASS' 'ROB_WINDOW_HARNESS_SELFTEST: PASS' \
             'FUNCTIONAL_ROB_WINDOW_B227_SELFTEST: PASS'; do
        [ "$(grep -cxF "$a" "$out" || true)" = "0" ] || return 1
    done
    n="$(grep -c '^ROB_WINDOW_HPV_MATRIX ' "$out" || true)"; [ "$n" = "1" ] || return 1
    sum="$(grep -m1 '^ROB_WINDOW_HPV_MATRIX ' "$out" || true)"
    [ "$sum" = 'ROB_WINDOW_HPV_MATRIX fixed_ok=1/1 stuck0=DEFECT_SIG done=DEFECT_SIG' ] || return 1
    [ "$(grep -c 'FAIL' "$out" || true)" = "0" ] || return 1
    defect_only_in "$out" '^ROB_WINDOW_HPV_MATRIX ' || return 1
    return 0
}

validate_harness() {
    local out="$1" rc="$2" n sum
    [ "$rc" -eq 0 ] && [ -s "$out" ] || return 1
    [ "$(grep -cxF 'ROB_WINDOW_HARNESS_SELFTEST: PASS' "$out" || true)" = "1" ] || return 1
    for a in 'FUNCTIONAL_ROB_WINDOW: PASS' 'FUNCTIONAL_ROB_WINDOW_NEGATIVE: PASS' \
             'FUNCTIONAL_ROB_WINDOW_B227: PASS' 'FUNCTIONAL_ROB_WINDOW_HPV: PASS' \
             'FUNCTIONAL_ROB_WINDOW_B227_SELFTEST: PASS'; do
        [ "$(grep -cxF "$a" "$out" || true)" = "0" ] || return 1
    done
    n="$(grep -c '^ROB_WINDOW_HARNESS_MATRIX ' "$out" || true)"; [ "$n" = "1" ] || return 1
    sum="$(grep -m1 '^ROB_WINDOW_HARNESS_MATRIX ' "$out" || true)"
    [ "$sum" = 'ROB_WINDOW_HARNESS_MATRIX good=2/2 kill=11/11' ] || return 1
    [ "$(grep -c 'FAIL' "$out" || true)" = "0" ] || return 1
    [ "$(grep -c 'DEFECT' "$out" || true)" = "0" ] || return 1
    return 0
}

#------------------------------------------------------------------------------
# F. 完整 7 输入 + driver 冻结（实际 DUT_ROOT）
#------------------------------------------------------------------------------
FREEZE_RELS=(
    rtl/back2/rob.v
    rtl/back2/rob_wide_mem.v
    rtl/back2/back2_params.vh
    sim/functional/tb_rob_window_semantics.sv
    sim/functional/test_rob_window.sh
    sim/functional/test_rob_window_driver.sh
    scripts/env.sh
    sim/functional/fixtures/rob_window_b227/rtl/back2/rob.v
    sim/functional/fixtures/rob_window_b227/rtl/back2/rob_wide_mem.v
    sim/functional/fixtures/rob_window_b227/rtl/back2/back2_params.vh
)
declare -A FS0

freeze_capture_root() {  # $1=root；7 输入全部可读且 hash 合格
    local root="$1" rel h
    for rel in "${FREEZE_RELS[@]}"; do
        [ -f "$root/$rel" ] || { printf 'freeze_missing %s\n' "$root/$rel" >> "$DRV_LOG"; return 1; }
        strict_sha h "$root/$rel" || return 1
        FS0["$rel"]="$h"
    done
    return 0
}

freeze_verify_root() {  # $1=root；逐项与 FS0 比，任一不符即失败
    local root="$1" rel h bad=0
    for rel in "${FREEZE_RELS[@]}"; do
        if ! strict_sha h "$root/$rel"; then
            printf 'freeze_recheck_sha_failed %s\n' "$rel" >> "$DRV_LOG"; bad=1; continue
        fi
        if [ -z "${FS0[$rel]:-}" ] || [ "${FS0[$rel]}" != "$h" ]; then
            printf 'freeze_changed %s exp=%s got=%s\n' "$rel" "${FS0[$rel]:-<unset>}" "$h" >> "$DRV_LOG"
            bad=1
        fi
    done
    return "$bad"
}

#------------------------------------------------------------------------------
# 1. 自检（私有 fixture；不改正式源）
#------------------------------------------------------------------------------
if [ "$MODE" = "selftest" ]; then
    note "==== test_rob_window_driver.sh --self-test ===="
    note "DRV = $DRV"
    mkdir -p -- "$DRV/fix" || fail "fixture_mkdir_failed"
    FIX="$DRV/fix"

    # ---- 1a. validators 正反 fixture ----
    GOOD_DEF="$FIX/good_default.out"
    GOOD_NEG="$FIX/good_negative.out"
    GOOD_B="$FIX/good_b227.out"
    GOOD_H="$FIX/good_hpv.out"
    GOOD_HS="$FIX/good_harness.out"
    GOOD_BS="$FIX/good_b227_selftest.out"
    {
        printf 'ROB_WINDOW_RUN_DIR=/x\n'
        printf 'ROB_WINDOW_VECTORS total=11 trigger=8 control=3 ok=11 bad=0\n'
        printf 'FUNCTIONAL_ROB_WINDOW: PASS\n'
    } > "$GOOD_DEF"
    {
        printf 'ROB_WINDOW_RUN_DIR=/y\n'
        printf 'ROB_WINDOW_NEGATIVE_MATRIX old_trigger=8/8 old_control=2/2 old_case9=DEFECT_SIG old_raw=79 new_ok=11/11 defect=e_ok_bad_removed\n'
        printf 'ROB_WINDOW_CANDIDATE removed_guard_mutation source=generated_from_fixed_rob\n'
        printf 'FUNCTIONAL_ROB_WINDOW_NEGATIVE: PASS\n'
    } > "$GOOD_NEG"
    {
        printf 'ROB_WINDOW_RUN_DIR=/z\n'
        printf 'ROB_WINDOW_B227_MATRIX old_ok=10/10 old_case8=DEFECT_SIG control_ok=2/2 new_ok=11/11 root=b227\n'
        printf 'ROB_WINDOW_CANDIDATE b227_original_fixture root=/fixture\n'
        printf 'FUNCTIONAL_ROB_WINDOW_B227: PASS\n'
    } > "$GOOD_B"
    {
        printf 'ROB_WINDOW_RUN_DIR=/h\n'
        printf 'ROB_WINDOW_HPV_MATRIX fixed_ok=1/1 stuck0=DEFECT_SIG done=DEFECT_SIG\n'
        printf 'FUNCTIONAL_ROB_WINDOW_HPV: PASS\n'
    } > "$GOOD_H"
    {
        printf 'ROB_WINDOW_RUN_DIR=/s\n'
        printf 'ROB_WINDOW_HARNESS_MATRIX good=2/2 kill=11/11\n'
        printf 'ROB_WINDOW_HARNESS_SELFTEST: PASS\n'
    } > "$GOOD_HS"
    {
        printf 'ROB_WINDOW_RUN_DIR=/bs\n'
        printf 'ROB_WINDOW_B227_ID_MATRIX identity=ok missing=red rob_mut=red wide_mut=red header_mut=red default_root=in_tree\n'
        printf 'FUNCTIONAL_ROB_WINDOW_B227_SELFTEST: PASS\n'
    } > "$GOOD_BS"

    validate_default "$GOOD_DEF" 0 || fail "selftest_good_default_rejected"
    validate_negative "$GOOD_NEG" 0 || fail "selftest_good_negative_rejected"
    validate_b227 "$GOOD_B" 0 || fail "selftest_good_b227_rejected"
    validate_hpv "$GOOD_H" 0 || fail "selftest_good_hpv_rejected"
    validate_harness "$GOOD_HS" 0 || fail "selftest_good_harness_rejected"
    validate_b227_self "$GOOD_BS" 0 || fail "selftest_good_b227_selftest_rejected"

    { cat "$GOOD_DEF"; printf 'DEFECT_ARBITRARY x\n'; } > "$FIX/m_def_arb.out"
    validate_default "$FIX/m_def_arb.out" 0 && fail "selftest_default_arbitrary_defect_accepted"
    { cat "$GOOD_DEF"; printf 'FUNCTIONAL_ROB_WINDOW_NEGATIVE: PASS\n'; } > "$FIX/m_def_neg_anchor.out"
    validate_default "$FIX/m_def_neg_anchor.out" 0 && fail "selftest_default_neg_anchor_accepted"
    sed 's/old_trigger=8\/8/old_trigger=7\/8/' "$GOOD_NEG" > "$FIX/m_neg_matrix.out"
    validate_negative "$FIX/m_neg_matrix.out" 0 && fail "selftest_neg_matrix_accepted"
    { cat "$GOOD_NEG"; printf 'DEFECT_REPRODUCED x\n'; } > "$FIX/m_neg_rep.out"
    validate_negative "$FIX/m_neg_rep.out" 0 && fail "selftest_neg_reproduced_accepted"
    sed 's/old_case8=DEFECT_SIG/old_case8=OK/' "$GOOD_B" > "$FIX/m_b_case8ok.out"
    validate_b227 "$FIX/m_b_case8ok.out" 0 && fail "selftest_b227_case8_ok_accepted"
    sed 's/stuck0=DEFECT_SIG/stuck0=OK/' "$GOOD_H" > "$FIX/m_h_stuck0ok.out"
    validate_hpv "$FIX/m_h_stuck0ok.out" 0 && fail "selftest_hpv_stuck0_ok_accepted"
    sed 's/kill=11\/11/kill=10\/11/' "$GOOD_HS" > "$FIX/m_hs_kill.out"
    validate_harness "$FIX/m_hs_kill.out" 0 && fail "selftest_harness_kill_accepted"
    sed 's/identity=ok/identity=bad/' "$GOOD_BS" > "$FIX/m_bs_bad.out"
    validate_b227_self "$FIX/m_bs_bad.out" 0 && fail "selftest_b227_selftest_bad_accepted"

    # ---- 1b. sha 假工具反证（exit9 / 空 / 多行 / 坏格式 / 好）----
    FAKE="$FIX/fakebin"; mkdir -p -- "$FAKE" || fail "fakebin_mkdir_failed"
    mk_fake() {  # $1=dir name $2=script body；目录内可执行文件名必须是 sha256sum
        local name="$1" body="$2"
        mkdir -p -- "$FAKE/$name" || return 1
        printf '#!/bin/bash\n%s\n' "$body" > "$FAKE/$name/sha256sum" || return 1
        chmod +x "$FAKE/$name/sha256sum" || return 1
    }
    mk_fake sha_exit9 'exit 9'
    mk_fake sha_empty 'exit 0'
    mk_fake sha_multi "printf '0000000000000000000000000000000000000000000000000000000000000000  %s\\n1111111111111111111111111111111111111111111111111111111111111111  %s\\n' \"\$2\" \"\$2\""
    mk_fake sha_bad "printf 'ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ  %s\\n' \"\$2\""
    mk_fake sha_out9 "printf '0000000000000000000000000000000000000000000000000000000000000000  %s\\n' \"\$2\"; exit 9"
    mk_fake sha_wrongpath "printf '0000000000000000000000000000000000000000000000000000000000000000  WRONG_PATH\\n'"
    mk_fake sha_good "printf '0000000000000000000000000000000000000000000000000000000000000000  %s\\n' \"\$2\""
    OLD_PATH="$PATH"; SHA_PROBE="$FIX/sha_probe_fixture"; : > "$SHA_PROBE"
    for f in sha_exit9 sha_empty sha_multi sha_bad sha_out9 sha_wrongpath; do
        PATH="$FAKE/$f:$OLD_PATH"; hash -r
        if strict_sha H "$SHA_PROBE"; then PATH="$OLD_PATH"; hash -r; fail "selftest_sha_not_rejected $f"; fi
        PATH="$OLD_PATH"; hash -r
    done
    PATH="$FAKE/sha_good:$OLD_PATH"; hash -r
    strict_sha H "$SHA_PROBE" || { PATH="$OLD_PATH"; hash -r; fail "selftest_sha_good_rejected"; }
    PATH="$OLD_PATH"; hash -r
    [ "$H" = "0000000000000000000000000000000000000000000000000000000000000000" ] \
        || fail "selftest_sha_good_value"

    # ---- 1b1. strict_sha真实caller逐字节反证（额外LF/尾空行/未终止/路径/CR/NUL/垃圾/exit9）----
    STRICT_BIN="$FIX/strict-raw-bin"; mkdir -p -- "$STRICT_BIN" || fail "strict_sha_raw_bin_failed"
    cat > "$STRICT_BIN/sha256sum" <<'EOF'
#!/usr/bin/env bash
h=0000000000000000000000000000000000000000000000000000000000000000
case "${SHA_DRIVER_CASE:-good}" in
  good) printf '%s  %s\n' "$h" "$2" ;;
  extra1) printf '%s  %s\n\n' "$h" "$2" ;;
  extra2) printf '%s  %s\n\n\n' "$h" "$2" ;;
  unterminated) printf '%s  %s' "$h" "$2" ;;
  wrongpath) printf '%s  WRONG_PATH\n' "$h" ;;
  junk) printf '%s  %s\nJUNK\n' "$h" "$2" ;;
  cr) printf '%s  %s\r\n' "$h" "$2" ;;
  nul) printf '%s  %s\n\0' "$h" "$2" ;;
  exit9) printf '%s  %s\n' "$h" "$2"; exit 9 ;;
esac
EOF
    chmod +x "$STRICT_BIN/sha256sum" || fail "strict_sha_raw_chmod_failed"
    STRICT_PROBE="$FIX/strict_sha_probe"; : > "$STRICT_PROBE"
    STRICT_KILL=0
    for f in extra1 extra2 unterminated wrongpath junk cr nul exit9; do
        if PATH="$STRICT_BIN:$OLD_PATH" SHA_DRIVER_CASE="$f" strict_sha H "$STRICT_PROBE"; then
            fail "selftest_strict_sha_raw_not_rejected $f"
        fi
        STRICT_KILL=$((STRICT_KILL+1))
    done
    printf 'ROB_DRIVER_SHA_RAW_SELFTEST good=1/1 kill=%s/8\n' "$STRICT_KILL" | tee -a "$DRV_LOG"

    # ---- 1c. 完整 7 输入 + driver 冻结突变矩阵 ----
    FDUT="$FIX/dut"
    for rel in "${FREEZE_RELS[@]}"; do
        mkdir -p -- "$FDUT/$(dirname -- "$rel")" || fail "freeze_fixture_mkdir_failed rel=$rel"
        cp -p -- "$DUT_ROOT/$rel" "$FDUT/$rel" || fail "freeze_fixture_copy_failed rel=$rel"
        chmod u+w -- "$FDUT/$rel" || fail "freeze_fixture_chmod_failed rel=$rel"
    done
    freeze_capture_root "$FDUT" || fail "freeze_fixture_capture_failed"
    freeze_verify_root "$FDUT" || fail "freeze_fixture_clean_rejected"
    FREEZE_MUT=0
    for rel in "${FREEZE_RELS[@]}"; do
        printf '\n// freeze mutation\n' >> "$FDUT/$rel" || fail "freeze_fixture_mutate_failed rel=$rel"
        if freeze_verify_root "$FDUT"; then fail "freeze_mutation_not_detected rel=$rel"; fi
        cp -p -- "$DUT_ROOT/$rel" "$FDUT/$rel" || fail "freeze_fixture_restore_failed rel=$rel"
        freeze_capture_root "$FDUT" || fail "freeze_fixture_recapture_failed rel=$rel"
        freeze_verify_root "$FDUT" || fail "freeze_fixture_restored_rejected rel=$rel"
        FREEZE_MUT=$((FREEZE_MUT+1))
    done
    [ "$FREEZE_MUT" -eq "${#FREEZE_RELS[@]}" ] || fail "freeze_mutation_count=$FREEZE_MUT"

    # ---- 1d. CLI 执行输入边界：2 个精确 reason 反控 + 3 个同根合法正控 ----
    CLI_OK=0
    cli_probe() {  # $1=label $2=want(0/1) $3=needle；其余为 env 赋值/选项
        local label="$1" want="$2" needle="$3" out rc
        shift 3
        out="$(env "$@" bash "$SELF_PATH" --cli-probe 2>&1)"; rc=$?
        if [ "$want" -eq 0 ]; then
            [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -qxF 'ROB_WINDOW_CLI_PROBE: PASS' \
                || { printf 'CLI_PROBE good failed label=%s rc=%s out=%s\n' "$label" "$rc" "$out" >> "$DRV_LOG"; return 1; }
        else
            [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qF "$needle" \
                || { printf 'CLI_PROBE reject failed label=%s rc=%s out=%s\n' "$label" "$rc" "$out" >> "$DRV_LOG"; return 1; }
        fi
        note "CLI_PROBE $label want=$want needle=${needle:-pass} OK"
        CLI_OK=$((CLI_OK+1))
        return 0
    }
    cli_probe pkg_override 1 'reason=unsupported_pkg_override' \
        ROB_WINDOW_PKG_SH="$FIX/other_pkg" || fail "selftest_cli_pkg_override"
    cli_probe cross_dut_root 1 'reason=unsupported_cross_dut_root' \
        DUT_ROOT="$FIX/other_root" || fail "selftest_cli_cross_dut_root"
    cli_probe clean_same_root 0 '' \
        -u DUT_ROOT -u ROB_WINDOW_PKG_SH -u RV32_FUNCTIONAL_PKG_OUT_DIR || fail "selftest_cli_clean_same_root"
    cli_probe parent_pkgo 0 '' \
        -u DUT_ROOT -u ROB_WINDOW_PKG_SH \
        RV32_FUNCTIONAL_PKG_OUT_DIR="$REPO_ROOT/build/functional/rob-window/cli-parent" \
        || fail "selftest_cli_parent_pkgo"
    cli_probe canonical_pkg 0 '' \
        -u DUT_ROOT -u RV32_FUNCTIONAL_PKG_OUT_DIR \
        ROB_WINDOW_PKG_SH="$REPO_ROOT/sim/functional/test_rob_window.sh" \
        || fail "selftest_cli_canonical_pkg"
    [ "$CLI_OK" -eq 5 ] || fail "selftest_cli_count=$CLI_OK expect=5"

    # ---- 1b2. package 实际 SHA caller 元反证：单文件 sha1_of + compile manifest ----
    RAWBIN="$FIX/rawbin"; mkdir -p -- "$RAWBIN" || fail "sha_raw_fakebin_failed"
    REAL_SHA="$(command -v sha256sum)"
    cat > "$RAWBIN/sha256sum" <<EOF
#!/usr/bin/env bash
scope="\${SHA_SCOPE:-single}"; mode="\${SHA_CASE:-good}"
if [ "\$scope" = multi ] && { [ "\$#" -le 2 ] || [ "\$1" = -c ]; }; then exec "$REAL_SHA" "\$@"; fi
if [ "\$scope" = single ] && [ "\$#" -ne 2 ]; then exec "$REAL_SHA" "\$@"; fi
raw="\$SHA_TMP_DIR/raw.\$\$"
"$REAL_SHA" "\$@" > "\$raw" || exit \$?
case "\$mode" in
 extra1) printf '\\n' >> "\$raw";; extra2) printf '\\n\\n' >> "\$raw";;
 unterminated) truncate -s -1 "\$raw";; wrongpath) h=\$(head -c 64 "\$raw"); printf '%s  WRONG\\n' "\$h" > "\$raw";;
 junk) printf 'JUNK\\n' >> "\$raw";; order) sed -n '1!G;h;\$p' "\$raw" > "\$raw.tmp"; mv "\$raw.tmp" "\$raw";; cr) printf '\\r' >> "\$raw";; nul) printf '\\0' >> "\$raw";;
 exit9) cat "\$raw"; exit 9;; *) exit 88;; esac
cat "\$raw"
EOF
    chmod +x "$RAWBIN/sha256sum" || fail "sha_raw_fake_chmod_failed"
    RAW_KILL=0; RAW_TOTAL=0
    for scope in single multi; do
        for mode in extra1 extra2 unterminated wrongpath junk cr nul exit9 order; do
            [ "$scope" = single ] && [ "$mode" = order ] && continue
            RAW_TOTAL=$((RAW_TOTAL+1)); RAW_OUT="$FIX/pkg-$scope-$mode.out"
            RAW_TMP="$FIX"; RAW_ROOT="$REPO_ROOT/build/functional/rob-window-sha-selftest-metadata-followup/$scope-$mode"
            mkdir -p -- "$RAW_ROOT" || fail "sha_raw_outdir_failed"
            ( unset RV32_FUNCTIONAL_PKG_OUT_DIR
              PATH="$RAWBIN:$OLD_PATH" SHA_TMP_DIR="$RAW_TMP" SHA_CASE="$mode" SHA_SCOPE="$scope" \
                OUT_DIR="$RAW_ROOT" bash "$PKG_SH" > "$RAW_OUT" 2>&1 ); RAW_RC=$?
            RAW_RD="$(sed -n 's/^ROB_WINDOW_RUN_DIR=//p' "$RAW_OUT" | head -1)"
            [ "$RAW_RC" -eq 1 ] || fail "sha_raw_not_rejected scope=$scope mode=$mode rc=$RAW_RC"
            [ "$(grep -c '^FUNCTIONAL_ROB_WINDOW: PASS$' "$RAW_OUT" || true)" -eq 0 ] \
                || fail "sha_raw_false_pass scope=$scope mode=$mode"
            if [ "$scope" = single ]; then
                grep -q 'reason=tb_sha_unavailable' "$RAW_OUT" || fail "sha_raw_reason scope=$scope mode=$mode"
                grep -qE 'sha1_of: (raw LF lines|missing terminating LF|raw bytes malformed|malformed hash/path|sha256sum rc=9)' "$RAW_RD/test_rob_window.log" \
                    || fail "sha_raw_detail scope=$scope mode=$mode"
            else
                grep -q 'reason=compile_new_failed' "$RAW_OUT" || fail "sha_raw_reason scope=$scope mode=$mode"
                grep -qE '^\[new\] (sha256 command rc=9|sha256 raw LF lines|sha line/path mismatch|raw sha bytes/count differ)' "$RAW_RD/test_rob_window.log" \
                    || fail "sha_raw_detail scope=$scope mode=$mode"
            fi
            RAW_KILL=$((RAW_KILL+1))
        done
    done
    [ "$RAW_KILL" -eq 17 ] || fail "sha_raw_kills=$RAW_KILL/17"
    printf 'ROB_SHA_RAW_SELFTEST good=1/1 kill=%s/%s (package single+manifest)\n' "$RAW_KILL" "$RAW_TOTAL" | tee -a "$DRV_LOG"

    note "SELFTEST validators=6+8 sha=6+1 freeze=$FREEZE_MUT/${#FREEZE_RELS[@]} cli=2+3 raw=good1+kill$RAW_KILL/$RAW_TOTAL"
    printf 'ROB_WINDOW_DRIVER_SELFTEST: PASS\n'
    exit 0
fi

#------------------------------------------------------------------------------
# 2. 正式六相（default / negative / b227 / mut-hpv / harness-selftest / b227-selftest）
#------------------------------------------------------------------------------
note "==== test_rob_window_driver.sh ===="
note "date      = $(date -Is 2>/dev/null || date)"
note "REPO_ROOT = $REPO_ROOT"
note "DUT_ROOT  = $DUT_ROOT"
note "PKG_SH    = $PKG_SH"
note "DRV       = $DRV"

freeze_capture_root "$DUT_ROOT" || fail "freeze_capture_failed root=$DUT_ROOT"
note "freeze captured: ${#FREEZE_RELS[@]} inputs (incl. driver)"

B227_ROB="$B227_ROOT/rtl/back2/rob.v"
B227_WIDE="$B227_ROOT/rtl/back2/rob_wide_mem.v"
B227_PARAMS="$B227_ROOT/rtl/back2/back2_params.vh"
strict_sha B227_SHA0 "$B227_ROB" || fail "b227_sha_unavailable path=$B227_ROB"
strict_sha B227_WIDE0 "$B227_WIDE" || fail "b227_wide_sha_unavailable path=$B227_WIDE"
strict_sha B227_PARAM0 "$B227_PARAMS" || fail "b227_params_sha_unavailable path=$B227_PARAMS"
[ "$B227_SHA0" = "$B227_ROB_SHA" ] || fail "b227_rob_identity_mismatch"
[ "$B227_WIDE0" = "$B227_WIDE_SHA" ] || fail "b227_wide_identity_mismatch"
[ "$B227_PARAM0" = "$B227_PARAMS_SHA" ] || fail "b227_params_identity_mismatch"

OUT_DEF="$DRV/default.out"; OUT_NEG="$DRV/negative.out"; OUT_B="$DRV/b227.out"
OUT_H="$DRV/mut_hpv.out"; OUT_HS="$DRV/harness.out"; OUT_BS="$DRV/b227_selftest.out"

run_phase() {  # $1=label $2=out $3..=argv
    local label="$1" out="$2"; shift 2
    local rc
    bash "$PKG_SH" "$@" > "$out" 2>&1
    rc=$?
    note "phase $label rc=$rc out=$out"
    return "$rc"
}

run_phase_no_b227() {  # b227-selftest 的"合法默认不设 B227_ROOT"控：子 shell unset
    local label="$1" out="$2"; shift 2
    local rc
    ( unset RV32_ROBWIN_B227_ROOT; bash "$PKG_SH" "$@" > "$out" 2>&1 )
    rc=$?
    note "phase $label rc=$rc out=$out (RV32_ROBWIN_B227_ROOT unset)"
    return "$rc"
}

run_phase default  "$OUT_DEF"            || fail "default_phase_rc"
validate_default "$OUT_DEF" 0             || fail "default_phase_rejected"
freeze_verify_root "$DUT_ROOT"            || fail "freeze_changed_after_default"

run_phase negative "$OUT_NEG" --negative || fail "negative_phase_rc"
validate_negative "$OUT_NEG" 0            || fail "negative_phase_rejected"
freeze_verify_root "$DUT_ROOT"            || fail "freeze_changed_after_negative"

run_phase b227     "$OUT_B" --b227       || fail "b227_phase_rc"
validate_b227 "$OUT_B" 0                  || fail "b227_phase_rejected"
grep -qxF "ROB_WINDOW_CANDIDATE b227_original_fixture root=$B227_ROOT" "$OUT_B" \
    || fail "b227_original_fixture_root_line_mismatch"
freeze_verify_root "$DUT_ROOT"            || fail "freeze_changed_after_b227"
strict_sha B227_SHA1 "$B227_ROB"          || fail "b227_sha_recheck_unavailable"
strict_sha B227_WIDE1 "$B227_WIDE"        || fail "b227_wide_sha_recheck_unavailable"
strict_sha B227_PARAM1 "$B227_PARAMS"     || fail "b227_params_sha_recheck_unavailable"
[ "$B227_SHA1" = "$B227_SHA0" ]           || fail "b227_source_changed"
[ "$B227_WIDE1" = "$B227_WIDE0" ]         || fail "b227_wide_source_changed"
[ "$B227_PARAM1" = "$B227_PARAM0" ]       || fail "b227_params_source_changed"

run_phase hpv      "$OUT_H" --mut-hpv    || fail "hpv_phase_rc"
validate_hpv "$OUT_H" 0                   || fail "hpv_phase_rejected"
freeze_verify_root "$DUT_ROOT"            || fail "freeze_changed_after_hpv"

run_phase harness  "$OUT_HS" --harness-selftest || fail "harness_phase_rc"
validate_harness "$OUT_HS" 0              || fail "harness_phase_rejected"
freeze_verify_root "$DUT_ROOT"            || fail "freeze_changed_after_harness"

run_phase_no_b227 b227self "$OUT_BS" --b227-selftest || fail "b227_self_phase_rc"
validate_b227_self "$OUT_BS" 0            || fail "b227_self_phase_rejected"
freeze_verify_root "$DUT_ROOT"            || fail "freeze_changed_after_b227_self"

#   末尾再次逐项复核（含 driver 自身）与 b227 三依赖
freeze_verify_root "$DUT_ROOT" || fail "freeze_changed_at_end"
strict_sha B227_SHA2 "$B227_ROB" || fail "b227_final_sha_unavailable"
strict_sha B227_WIDE2 "$B227_WIDE" || fail "b227_wide_final_sha_unavailable"
strict_sha B227_PARAM2 "$B227_PARAMS" || fail "b227_params_final_sha_unavailable"
[ "$B227_SHA2" = "$B227_SHA0" ] || fail "b227_source_changed_at_end"
[ "$B227_WIDE2" = "$B227_WIDE0" ] || fail "b227_wide_source_changed_at_end"
[ "$B227_PARAM2" = "$B227_PARAM0" ] || fail "b227_params_source_changed_at_end"
note "freeze verified across all phases; b227 3-dep fixture unchanged (10-input matrix)"

printf 'ROB_WINDOW_DRIVER_MATRIX default=11/11 negative=8/8+2/2 b227=10/10+case8red mut_hpv=stuck0/done red harness=good2/2+kills11/11 b227_self=identity+4kills\n'
printf 'ROB_WINDOW_DRIVER: PASS\n'
exit 0
