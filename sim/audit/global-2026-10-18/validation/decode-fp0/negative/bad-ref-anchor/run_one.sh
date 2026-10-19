#!/usr/bin/env bash
#==============================================================================
# run_one.sh <c|f|b> <case> <control|defect> <ref-tag>
#   单向用例执行器：白名单 → 参考计算（退出码 + 精确锚点）→ 编译 → 运行 →
#   唯一 RESULT 行判定 → 独立退出码。
#   判定规则（fail-closed）：
#     · kind ∈ {c,f,b}，case 为十进制且在该 kind 的范围内（白名单），否则直接失败；
#     · ref_calc.py 退出码必须 0；输出只允许 REF_CHECK/REF_CIN 锚点行，
#       REF_CHECK <tag>: OK value=0x........ 恰好 1 行；kind=c 另需 REF_CIN 恰好 1 行；
#     · 日志中 RESULT= 行必须恰好 1 行，否则 FAIL（未捕获即失败）；
#     · 控制例：必须 RESULT=CONTROL_OK；缺陷例：必须 RESULT=DEFECT_REPRODUCED；
#     · 删除 vvp 前校验解析后的绝对路径仍在本目录、且文件名就是本例的 <kind><case>.vvp。
#   产物全部落在本脚本所在目录（vvp / log / 判定行）。
#==============================================================================
set -uo pipefail

KIND="${1:?kind c|f|b}"; CASE="${2:?case}"; MODE="${3:?control|defect}"; TAG="${4:?ref tag}"
DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

fail() { printf 'CASE %s%s: FAIL %s\n' "$KIND" "$CASE" "$*"; exit 1; }

# ---- 0. 仓库根（向上找到 rtl/pkg/rv32_defs.vh；不依赖固定相对层级）----
find_repo() {
    local d="$1"
    while [ -n "$d" ] && [ "$d" != "/" ]; do
        [ -r "$d/rtl/pkg/rv32_defs.vh" ] && { printf '%s' "$d"; return 0; }
        d="$(dirname -- "$d")"
    done
    return 1
}
REPO="$(find_repo "$DIR")" || fail "cannot locate repo root (rtl/pkg/rv32_defs.vh) from ${DIR}"

# ---- 1. kind / case / mode / tag 白名单 ----
case "$KIND" in
    c) CASE_MIN=0; CASE_MAX=8  ;;
    f) CASE_MIN=0; CASE_MAX=10 ;;
    b) CASE_MIN=1; CASE_MAX=4  ;;
    *) fail "kind '${KIND}' not in whitelist {c,f,b}" ;;
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

# ---- 2. 只删除本例 vvp：解析绝对路径，必须在 DIR 内且文件名 == 本例 vvp ----
safe_cleanup_out() {
    local dir_real out_real
    dir_real="$(readlink -m -- "$DIR")" || fail "readlink DIR failed"
    out_real="$(readlink -m -- "$OUT")" || fail "readlink OUT failed"
    [ "$(dirname -- "$out_real")" = "$dir_real" ] || \
        fail "refuse to touch OUT outside DIR: ${out_real}"
    [ "$(basename -- "$out_real")" = "${KIND}${CASE}.vvp" ] || \
        fail "refuse to touch non-case vvp: ${out_real}"
    if [ -e "$out_real" ] || [ -L "$out_real" ]; then
        [ -f "$out_real" ] || fail "OUT exists but is not a regular file: ${out_real}"
        rm -f -- "$out_real" || fail "cannot remove ${out_real}"
    fi
}
safe_cleanup_out    # 清掉上一次可能残留的本例 vvp（只此一个）

# ---- 3. 独立参考计算：退出码 + 精确锚点（不认任意 OK 子串）----
python3 "${DIR}/ref_calc.py" "$TAG" > "$REFLOG" 2>&1
REF_RC=$?
[ "$REF_RC" -eq 0 ] || fail "ref_calc.py rc=${REF_RC} (see ${REFLOG})"
BAD_LINES="$(grep -cvE '^REF_(CHECK|CIN) ' "$REFLOG" || true)"
[ "$BAD_LINES" = "0" ] || fail "ref output contains ${BAD_LINES} line(s) that are not REF_ anchors"
N_CHECK="$(grep -cE "^REF_CHECK ${TAG}: OK value=0x[0-9a-f]{8}$" "$REFLOG" || true)"
[ "$N_CHECK" = "1" ] || fail "REF_CHECK anchor for '${TAG}' count=${N_CHECK} (expect 1)"
if [ "$KIND" = "c" ]; then
    N_CIN="$(grep -cE "^REF_CIN ${TAG}: OK cin=0x[0-9a-f]{4}$" "$REFLOG" || true)"
    [ "$N_CIN" = "1" ] || fail "REF_CIN anchor for '${TAG}' count=${N_CIN} (expect 1)"
fi

# ---- 4. 编译 + 运行（每例 < 180 s 墙钟）----
if [ "$KIND" = "c" ]; then
    SRC=("${REPO}/rtl/decode/compressed_expand.v" "${DIR}/tb_compressed_audit.sv")
    TOP=tb_compressed_audit; PARAM="tb_compressed_audit.CASE=${CASE}"
elif [ "$KIND" = "f" ]; then
    SRC=("${REPO}/rtl/decode/decoder.v" "${REPO}/rtl/decode/dec_imm.v" \
         "${REPO}/rtl/decode/dec_csr.v" "${REPO}/rtl/decode/compressed_expand.v" \
         "${DIR}/tb_decoder_fp_audit.sv")
    TOP=tb_decoder_fp_audit; PARAM="tb_decoder_fp_audit.CASE=${CASE}"
else
    mapfile -t SRC < <(find "${REPO}/rtl" -name '*.v' | sort)
    SRC+=("${DIR}/tb_backend_f0.sv")
    TOP=tb_backend_f0; PARAM="tb_backend_f0.CASE=${CASE}"
fi
timeout 60 iverilog -g2012 -I "${REPO}/rtl/pkg" -I "${REPO}" -s "$TOP" \
        -P "$PARAM" -o "$OUT" "${SRC[@]}" > "${LOG}.compile" 2>&1
rc=$?
[ $rc -eq 0 ] || { cat "${LOG}.compile" >> "$LOG"; fail "iverilog rc=$rc"; }

timeout 170 vvp "$OUT" > "$LOG" 2>&1
rc=$?
[ $rc -eq 0 ] || fail "vvp rc=$rc (see $LOG)"
safe_cleanup_out    # 跑完只删本例 vvp（同一路径校验）

# ---- 5. 判定 ----
n_res="$(grep -c 'RESULT=' "$LOG" || true)"
[ "$n_res" = "1" ] || fail "RESULT lines=${n_res} (expect 1; log=$LOG)"
RES="$(grep -o 'RESULT=[A-Z_]*' "$LOG")"
case "$MODE" in
    control) [ "$RES" = "RESULT=CONTROL_OK" ] || fail "DUT 与规范不一致（$RES）" ;;
    defect)  [ "$RES" = "RESULT=DEFECT_REPRODUCED" ] || fail "缺陷未复现（$RES）" ;;
esac

E2ELINE="$(grep -m1 'E2E ' "$LOG")"
DUTLINE="$(grep -m1 'DUT ' "$LOG")"
EXPLINE="$(grep -m1 'EXPECT ' "$LOG")"
if [ "$MODE" = "control" ]; then
    printf 'CASE %s%s: PASS [控制例 DUT==规范] %s | %s%s\n' "$KIND" "$CASE" "$DUTLINE" "$EXPLINE" "${E2ELINE:+ | $E2ELINE}"
else
    printf 'CASE %s%s: PASS [缺陷已复现] %s | %s%s\n' "$KIND" "$CASE" "$DUTLINE" "$EXPLINE" "${E2ELINE:+ | $E2ELINE}"
fi
exit 0
