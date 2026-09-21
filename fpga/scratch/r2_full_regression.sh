#!/usr/bin/env bash
#==============================================================================
# fpga/scratch/r2_full_regression.sh —— R2 修复后的全量功能回归（任务判据 3 的可复现入口）
#==============================================================================
# 依次跑（与任务验收判据逐字一致）：
#   ① ./scripts/regress.sh                              → 期望 `REGRESS: 23/23 PASS`
#   ② ./sim/arch_test/run.sh --group rv32i/I  --jobs 16 → 期望 39/39
#   ③ ./sim/arch_test/run.sh --group rv32i/F  --jobs 16 → 期望 80/80
#   ④ ./sim/arch_test/run.sh --group rv32i/D  --jobs 16 → 期望 106/106
#   ⑤ ./sim/arch_test/run.sh --group 'tests/priv/PMP*' --jobs 16 → 期望 63/63
#   ⑥ ./sim/arch_test/run.sh --group Sv --jobs 16       → 期望 29/29
# 日志：fpga/scratch/out/regression_r2/<编号>_<名字>.log（父进程汇总见 regression_r2.log）
# 退出码：0 = 六项全部命中期望计数；1 = 任一项未命中（**不看兜底文案，只认计数行**）
# 纪律：不修改任何判据脚本；只调用既有入口并核对它们自己打印的汇总行。
#==============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd -P)"
OUT_DIR="${SCRIPT_DIR}/out/regression_r2"
mkdir -p "${OUT_DIR}"
SUM="${SCRIPT_DIR}/out/regression_r2.log"
cd "${REPO_ROOT}" || exit 2
: >"${SUM}"

run_one() {   # run_one <编号> <名字> <期望汇总正则> <命令...>
    local idx="$1" name="$2" pat="$3"; shift 3
    local log="${OUT_DIR}/${idx}_${name}.log"
    printf '================================================================\n' >>"${SUM}"
    printf '== [%s] %s\n== cmd: %s\n' "${idx}" "${name}" "$*" >>"${SUM}"
    "$@" >"${log}" 2>&1
    local rc=$?
    local hit; hit="$(grep -E "${pat}" "${log}" | tail -n 1 || true)"
    printf '== rc=%d  汇总行：%s\n' "${rc}" "${hit:-<未命中期望汇总行>}" >>"${SUM}"
    [ "${rc}" -eq 0 ] && [ -n "${hit}" ] || { printf '== [%s] 未命中期望 ⇒ 判失败\n' "${idx}" >>"${SUM}"; return 1; }
    return 0
}

fail=0
run_one 01 regress_unit 'REGRESS: 23/23 PASS' ./scripts/regress.sh || fail=1
run_one 02 arch_I 'RV32_ARCH_TEST_RUN: PASS \(39/39\)' \
        ./sim/arch_test/run.sh --group rv32i/I --jobs 16 || fail=1
run_one 03 arch_F 'RV32_ARCH_TEST_RUN: PASS \(80/80\)' \
        ./sim/arch_test/run.sh --group rv32i/F --jobs 16 || fail=1
run_one 04 arch_D 'RV32_ARCH_TEST_RUN: PASS \(106/106\)' \
        ./sim/arch_test/run.sh --group rv32i/D --jobs 16 || fail=1
run_one 05 arch_PMP 'RV32_ARCH_TEST_RUN: PASS \(63/63\)' \
        ./sim/arch_test/run.sh --group 'tests/priv/PMP*' --jobs 16 || fail=1
run_one 06 arch_Sv 'RV32_ARCH_TEST_RUN: PASS \(29/29\)' \
        ./sim/arch_test/run.sh --group Sv --jobs 16 || fail=1

if [ "${fail}" -eq 0 ]; then
    printf 'R2_FULL_REGRESSION: OK（六项全部命中期望计数）\n' >>"${SUM}"
else
    printf 'R2_FULL_REGRESSION: FAIL（见上面未命中项；汇总日志 %s）\n' "${SUM}" >>"${SUM}"
fi
tail -n 40 "${SUM}"
exit "${fail}"
