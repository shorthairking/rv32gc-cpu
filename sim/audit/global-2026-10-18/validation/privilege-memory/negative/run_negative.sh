#!/usr/bin/env bash
#==============================================================================
# negative/run_negative.sh —— runner 反证（不删/不移正式用例）
#   前置：两个坏 reference 夹具内的 run_one.sh 必须与正式 run_one.sh 字节相同
#         （cmp；不一致 ⇒ FIXTURE DRIFT + exit 1）。
#   1) empty-manifest：0 个用例脚本 ⇒ run_all.sh 必须 0/11 + exit!=0；
#   2) bad-ref-anchor：rc=0 但锚点 tag 错位 ⇒ run_one.sh 必须 exit!=0；
#   3) bad-ref-exit  ：锚点正确但 rc=1      ⇒ run_one.sh 必须 exit!=0；
#   4) bad-args      ：坏 kind/case/mode 入口 ⇒ 白名单阶段拒绝。
#   汇总 NEGATIVE: <pass>/4；任何一项意外 rc=0 即 FAIL。
#==============================================================================
set -uo pipefail
NEG="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
VAL="$(cd -- "${NEG}/.." && pwd -P)"
pass=0; total=0
ok()  { printf 'NEGATIVE %s: PASS (%s)\n' "$1" "$2"; pass=$((pass + 1)); }
bad() { printf 'NEGATIVE %s: FAIL (%s)\n' "$1" "$2"; }

for fx in bad-ref-anchor bad-ref-exit; do
    if ! cmp -s "${VAL}/run_one.sh" "${NEG}/${fx}/run_one.sh"; then
        printf 'FIXTURE DRIFT: %s/run_one.sh != run_one.sh\n' "$fx"
        printf '  official sha256: %s\n' "$(sha256sum "${VAL}/run_one.sh" | cut -d' ' -f1)"
        printf '  fixture  sha256: %s\n' "$(sha256sum "${NEG}/${fx}/run_one.sh" | cut -d' ' -f1)"
        exit 1
    fi
done
echo "FIXTURE runner sync: OK (2/2 byte-identical)"

total=$((total + 1)); log="${NEG}/log_empty_manifest.log"
if VALIDATION_SCRIPT_DIR="${NEG}/empty-manifest" "${VAL}/run_all.sh" > "$log" 2>&1; then
    bad empty-manifest "unexpected rc=0"
elif grep -qF 'VALIDATION: 0/11 (manifest preflight failed; no case executed)' "$log" \
     && grep -qF 'MISSING run_p0.sh' "$log" \
     && ! grep -qF 'VALIDATION: 11/11' "$log"; then
    ok empty-manifest "rc!=0, 0/11, missing listed, no 11/11"
else
    bad empty-manifest "wrong diagnostics (see ${log})"
fi

total=$((total + 1)); log="${NEG}/log_bad_ref_anchor.log"
if bash "${NEG}/bad-ref-anchor/run_p1.sh" > "$log" 2>&1; then
    bad bad-ref-anchor "unexpected rc=0"
elif grep -qF 'REF_CHECK anchor' "$log" && ! grep -qF 'CASE p1: PASS' "$log"; then
    ok bad-ref-anchor "rc!=0 on mismatched REF_CHECK anchor"
else
    bad bad-ref-anchor "wrong diagnostics (see ${log})"
fi

total=$((total + 1)); log="${NEG}/log_bad_ref_exit.log"
if bash "${NEG}/bad-ref-exit/run_p1.sh" > "$log" 2>&1; then
    bad bad-ref-exit "unexpected rc=0"
elif grep -qF 'ref_calc.py rc=1' "$log" && ! grep -qF 'CASE p1: PASS' "$log"; then
    ok bad-ref-exit "rc!=0 on ref_calc rc=1"
else
    bad bad-ref-exit "wrong diagnostics (see ${log})"
fi

total=$((total + 1)); log="${NEG}/log_bad_args.log"; : > "$log"; bad_rc=0
for args in "x 0 control p0" "p 6 defect p1" "b 0 control b1" "p 01 defect p1" "p 1 badmode p1"; do
    # shellcheck disable=SC2086
    if bash "${VAL}/run_one.sh" $args >> "$log" 2>&1; then bad_rc=1; fi
done
if [ "$bad_rc" -eq 0 ] \
   && [ "$(grep -c 'not in whitelist' "$log")" -ge 2 ] \
   && [ "$(grep -c 'out of range' "$log")" -ge 2 ] \
   && [ "$(grep -c 'not canonical decimal' "$log")" -ge 1 ] \
   && ! grep -q 'CASE p1: PASS' "$log"; then
    ok bad-args "kind/mode/range/canonical whitelist all rejected"
else
    bad bad-args "whitelist did not reject all bad entries (see ${log})"
fi

echo "------------------------------------------------------------"
echo "NEGATIVE: ${pass}/${total}"
[ "$pass" -eq "$total" ] || exit 1
exit 0
