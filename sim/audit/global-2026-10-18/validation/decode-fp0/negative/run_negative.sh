#!/usr/bin/env bash
#==============================================================================
# negative/run_negative.sh —— runner 的反证（夹具不得删除/移走任何正式用例）
#   1) empty-manifest  ：0 个用例脚本 ⇒ run_all.sh 必须 exit!=0 且 0/24；
#   2) missing-one     ：缺 run_f10.sh（其余 23 个占位）⇒ 必须 exit!=0、预检失败、
#                        不执行任何用例（当日志里不得出现 24/24）；
#   3) bad-ref-anchor  ：参考输出 rc=0 但锚点 tag 错位 ⇒ run_one.sh 必须 exit!=0；
#   4) bad-ref-exit    ：锚点正确但 python rc=1      ⇒ run_one.sh 必须 exit!=0；
#   5) bad-args        ：坏 kind/case/mode 入口 ⇒ 白名单阶段拒绝。
#   前置：两个坏 reference 夹具里的 run_one.sh 必须与正式 run_one.sh 字节相同
#         （cmp 检查；不一致 ⇒ 立即失败，避免夹具 runner 漂移后反证跑的不是当前逻辑）。
#   判据全部为“必须失败且失败原因正确”，任何一项意外 rc=0 即整体 FAIL。
#   产物：negative/log_*.log；汇总 NEGATIVE: <pass>/5。
#==============================================================================
set -uo pipefail
NEG="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
VAL="$(cd -- "${NEG}/.." && pwd -P)"
pass=0; total=0

ok()   { printf 'NEGATIVE %s: PASS (%s)\n' "$1" "$2"; pass=$((pass + 1)); }
bad()  { printf 'NEGATIVE %s: FAIL (%s)\n' "$1" "$2"; }

# ---- 0. 前置：坏 reference 夹具 runner 必须与正式 runner 字节相同 ----
for fx in bad-ref-anchor bad-ref-exit; do
    if ! cmp -s "${VAL}/run_one.sh" "${NEG}/${fx}/run_one.sh"; then
        printf 'FIXTURE DRIFT: %s/run_one.sh != run_one.sh\n' "$fx"
        printf '  official sha256: %s\n' "$(sha256sum "${VAL}/run_one.sh" | cut -d' ' -f1)"
        printf '  fixture  sha256: %s\n' "$(sha256sum "${NEG}/${fx}/run_one.sh" | cut -d' ' -f1)"
        exit 1
    fi
done
echo "FIXTURE runner sync: OK (2/2 byte-identical)"

# ---- 1. 空清单夹具 ----
total=$((total + 1)); log="${NEG}/log_empty_manifest.log"
if VALIDATION_SCRIPT_DIR="${NEG}/empty-manifest" "${VAL}/run_all.sh" > "$log" 2>&1; then
    bad empty-manifest "unexpected rc=0"
else
    if grep -qF 'VALIDATION: 0/24 (manifest preflight failed; no case executed)' "$log" \
       && grep -qF 'MISSING run_c0.sh' "$log" \
       && ! grep -qF 'VALIDATION: 24/24' "$log"; then
        ok empty-manifest "rc!=0, 0/24, missing listed, no 24/24"
    else
        bad empty-manifest "wrong diagnostics (see ${log})"
    fi
fi

# ---- 2. 缺一例夹具 ----
total=$((total + 1)); log="${NEG}/log_missing_one.log"
if VALIDATION_SCRIPT_DIR="${NEG}/missing-one" "${VAL}/run_all.sh" > "$log" 2>&1; then
    bad missing-one "unexpected rc=0"
else
    if grep -qF 'MISSING run_f10.sh' "$log" \
       && grep -qF 'VALIDATION: 0/24 (manifest preflight failed; no case executed)' "$log" \
       && ! grep -qF 'VALIDATION: 24/24' "$log" \
       && ! grep -qF 'PASS ' "$log"; then
        ok missing-one "rc!=0, only run_f10.sh missing, no case executed"
    else
        bad missing-one "wrong diagnostics (see ${log})"
    fi
fi

# ---- 3. 坏 reference：锚点错位（rc=0）----
total=$((total + 1)); log="${NEG}/log_bad_ref_anchor.log"
if bash "${NEG}/bad-ref-anchor/run_c1.sh" > "$log" 2>&1; then
    bad bad-ref-anchor "unexpected rc=0"
else
    if grep -qF 'REF_CHECK anchor' "$log" && ! grep -qF 'CASE c1: PASS' "$log"; then
        ok bad-ref-anchor "rc!=0 on missing/mismatched REF_CHECK anchor"
    else
        bad bad-ref-anchor "wrong diagnostics (see ${log})"
    fi
fi

# ---- 4. 坏 reference：锚点正确但 rc=1 ----
total=$((total + 1)); log="${NEG}/log_bad_ref_exit.log"
if bash "${NEG}/bad-ref-exit/run_c1.sh" > "$log" 2>&1; then
    bad bad-ref-exit "unexpected rc=0"
else
    if grep -qF 'ref_calc.py rc=1' "$log" && ! grep -qF 'CASE c1: PASS' "$log"; then
        ok bad-ref-exit "rc!=0 on ref_calc rc=1"
    else
        bad bad-ref-exit "wrong diagnostics (see ${log})"
    fi
fi

# ---- 5. kind/case/mode 白名单（坏入口不得进入编译阶段）----
total=$((total + 1)); log="${NEG}/log_bad_args.log"
: > "$log"
bad_rc=0
for args in "x 0 control nop" "c 9 defect c1" "b 0 control b0" "c 01 defect c1" "c 1 badmode c1"; do
    # shellcheck disable=SC2086
    if bash "${VAL}/run_one.sh" $args >> "$log" 2>&1; then bad_rc=1; fi
done
if [ "$bad_rc" -eq 0 ] \
   && [ "$(grep -c 'not in whitelist' "$log")" -ge 2 ] \
   && [ "$(grep -c 'out of range' "$log")" -ge 2 ] \
   && [ "$(grep -c 'not canonical decimal' "$log")" -ge 1 ] \
   && ! grep -q 'CASE c1: PASS' "$log"; then
    ok bad-args "kind/mode/range/canonical whitelist all rejected"
else
    bad bad-args "whitelist did not reject all bad entries (see ${log})"
fi

echo "------------------------------------------------------------"
echo "NEGATIVE: ${pass}/${total}"
[ "$pass" -eq "$total" ] || exit 1
exit 0
