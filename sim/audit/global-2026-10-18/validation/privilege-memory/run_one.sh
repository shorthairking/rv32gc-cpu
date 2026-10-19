#!/usr/bin/env bash
#==============================================================================
# run_one.sh <p|b|l> <case> <control|defect> <ref-tag>
#   单向用例执行器（privilege-memory 隔离批次）：
#     kind/case/mode 白名单 → 参考计算（rc + 精确锚点）→ 编译 → 运行 →
#     唯一 RESULT 行判定 → 独立退出码；删除 vvp 前校验路径只在本目录且只删本例。
#==============================================================================
set -uo pipefail

KIND="${1:?kind p|b|l}"; CASE="${2:?case}"; MODE="${3:?control|defect}"; TAG="${4:?ref tag}"
DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

fail() { printf 'CASE %s%s: FAIL %s\n' "$KIND" "$CASE" "$*"; exit 1; }

find_repo() {
    local d="$1"
    while [ -n "$d" ] && [ "$d" != "/" ]; do
        [ -r "$d/rtl/pkg/rv32_defs.vh" ] && { printf '%s' "$d"; return 0; }
        d="$(dirname -- "$d")"
    done
    return 1
}
REPO="$(find_repo "$DIR")" || fail "cannot locate repo root from ${DIR}"

case "$KIND" in
    p) CASE_MIN=0; CASE_MAX=5 ;;
    b) CASE_MIN=1; CASE_MAX=3 ;;
    l) CASE_MIN=1; CASE_MAX=2 ;;
    *) fail "kind '${KIND}' not in whitelist {p,b,l}" ;;
esac
[[ "$CASE" =~ ^(0|[1-9][0-9]*)$ ]] || fail "case '${CASE}' is not canonical decimal"
{ [ "$CASE" -ge "$CASE_MIN" ] && [ "$CASE" -le "$CASE_MAX" ]; } || \
    fail "case ${CASE} out of range ${CASE_MIN}..${CASE_MAX} for kind ${KIND}"
case "$MODE" in
    control|defect) ;;
    *) fail "mode '${MODE}' not in whitelist {control,defect}" ;;
esac
[[ "$TAG" =~ ^[a-z][a-z0-9]*$ ]] || fail "ref tag '${TAG}' has illegal characters"

LOG="${DIR}/log_${KIND}${CASE}.log"
REFLOG="${DIR}/ref_${KIND}${CASE}.log"
OUT="${DIR}/${KIND}${CASE}.vvp"

safe_cleanup_out() {
    local dir_real out_real
    dir_real="$(readlink -m -- "$DIR")" || fail "readlink DIR failed"
    out_real="$(readlink -m -- "$OUT")" || fail "readlink OUT failed"
    [ "$(dirname -- "$out_real")" = "$dir_real" ] || fail "refuse OUT outside DIR: ${out_real}"
    [ "$(basename -- "$out_real")" = "${KIND}${CASE}.vvp" ] || fail "refuse non-case vvp: ${out_real}"
    if [ -e "$out_real" ] || [ -L "$out_real" ]; then
        [ -f "$out_real" ] || fail "OUT exists but not regular file: ${out_real}"
        rm -f -- "$out_real" || fail "cannot remove ${out_real}"
    fi
}
safe_cleanup_out

# ---- 参考计算：rc + 精确锚点 ----
python3 "${DIR}/ref_calc.py" "$TAG" > "$REFLOG" 2>&1
REF_RC=$?
[ "$REF_RC" -eq 0 ] || fail "ref_calc.py rc=${REF_RC} (see ${REFLOG})"
BAD_LINES="$(grep -cvE '^REF_(CHECK|PREDICT) ' "$REFLOG" || true)"
[ "$BAD_LINES" = "0" ] || fail "ref output has ${BAD_LINES} non-REF line(s)"
N_CHECK="$(grep -cE "^REF_CHECK ${TAG}: OK value=0x[0-9a-f]{8}$" "$REFLOG" || true)"
[ "$N_CHECK" = "1" ] || fail "REF_CHECK anchor for '${TAG}' count=${N_CHECK} (expect 1)"

# ---- 编译 + 运行 ----
if [ "$KIND" = "p" ]; then
    mapfile -t SRC < <(find "${REPO}/rtl" -name '*.v' | sort)
    SRC+=("${DIR}/tb_priv_backend.sv")
    TOP=tb_priv_backend; PARAM="tb_priv_backend.CASE=${CASE}"
elif [ "$KIND" = "b" ]; then
    SRC=("${REPO}/rtl/clint/clint.v" "${DIR}/tb_clint_edge.sv")
    TOP=tb_clint_edge; PARAM="tb_clint_edge.CASE=${CASE}"
else
    SRC=("${REPO}/rtl/back2/lsq_simple.v" "${DIR}/tb_lsq_release.sv")
    TOP=tb_lsq_release; PARAM="tb_lsq_release.CASE=${CASE}"
fi
timeout 60 iverilog -g2012 -I "${REPO}/rtl/pkg" -I "${REPO}" -s "$TOP" \
        -P "$PARAM" -o "$OUT" "${SRC[@]}" > "${LOG}.compile" 2>&1
rc=$?
[ $rc -eq 0 ] || { cat "${LOG}.compile" >> "$LOG"; fail "iverilog rc=$rc"; }

timeout 170 vvp "$OUT" > "$LOG" 2>&1
rc=$?
[ $rc -eq 0 ] || fail "vvp rc=$rc (see $LOG)"
safe_cleanup_out

# ---- 判定 ----
n_res="$(grep -c 'RESULT=' "$LOG" || true)"
[ "$n_res" = "1" ] || fail "RESULT lines=${n_res} (expect 1; log=$LOG)"
RES="$(grep -o 'RESULT=[A-Z_]*' "$LOG")"
case "$MODE" in
    control) [ "$RES" = "RESULT=CONTROL_OK" ] || fail "DUT 与规范不一致（$RES）" ;;
    defect)  [ "$RES" = "RESULT=DEFECT_REPRODUCED" ] || fail "缺陷未复现（$RES）" ;;
esac

DUTLINE="$(grep -m1 'DUT ' "$LOG")"
EXPLINE="$(grep -m1 'EXPECT ' "$LOG")"
if [ "$MODE" = "control" ]; then
    printf 'CASE %s%s: PASS [控制例 DUT==规范] %s | %s\n' "$KIND" "$CASE" "$DUTLINE" "$EXPLINE"
else
    printf 'CASE %s%s: PASS [缺陷已复现] %s | %s\n' "$KIND" "$CASE" "$DUTLINE" "$EXPLINE"
fi
exit 0
