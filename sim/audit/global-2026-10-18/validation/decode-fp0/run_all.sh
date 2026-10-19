#!/usr/bin/env bash
#==============================================================================
# run_all.sh —— 固定 24 例清单（c0..c8, f0..f10, b1..b4）全量执行 + 计数。
#   判据（fail-closed）：
#     · 清单常量硬编码且断言长度 == 24（不依赖 ls / glob 的发现结果）；
#     · 执行前逐个检查 run_<id>.sh **存在**；任一缺失 ⇒ 打印缺失清单、
#       `VALIDATION: 0/24 (manifest preflight failed)`、exit 1，不执行任何用例；
#     · 逐个用例独立子进程 + 独立退出码；汇总恒为 `VALIDATION: <pass>/24`；
#     · pass != 24 ⇒ 打印失败用例并 exit 1。
#   反证用：可用 VALIDATION_SCRIPT_DIR 指向夹具目录（见 negative/）。
#==============================================================================
set -uo pipefail
DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPT_DIR="${VALIDATION_SCRIPT_DIR:-$DIR}"

MANIFEST=(c0 c1 c2 c3 c4 c5 c6 c7 c8 \
          f0 f1 f2 f3 f4 f5 f6 f7 f8 f9 f10 \
          b1 b2 b3 b4)
EXPECTED=24
if [ "${#MANIFEST[@]}" -ne "$EXPECTED" ]; then
    echo "MANIFEST: internal count ${#MANIFEST[@]} != ${EXPECTED}"
    exit 1
fi

cd "$DIR" || exit 1

# ---- 1. 清单预检：每例脚本必须存在 ----
missing=()
for id in "${MANIFEST[@]}"; do
    [ -f "${SCRIPT_DIR}/run_${id}.sh" ] || missing+=("run_${id}.sh")
done
if [ "${#missing[@]}" -ne 0 ]; then
    echo "MANIFEST: ${#missing[@]}/${EXPECTED} case scripts missing in ${SCRIPT_DIR}:"
    printf '  MISSING %s\n' "${missing[@]}"
    echo "VALIDATION: 0/${EXPECTED} (manifest preflight failed; no case executed)"
    exit 1
fi

# ---- 2. 逐例执行（独立子进程/退出码）----
pass=0; failed=()
for id in "${MANIFEST[@]}"; do
    script="${SCRIPT_DIR}/run_${id}.sh"
    out="${SCRIPT_DIR}/all_${id}.out"
    if bash "$script" > "$out" 2>&1; then
        pass=$((pass + 1)); echo "PASS ${id}"
    else
        failed+=("$id"); echo "FAIL ${id}"
    fi
done

# ---- 3. 汇总（恒以 24 为分母）----
echo "------------------------------------------------------------"
echo "VALIDATION: ${pass}/${EXPECTED}"
if [ "$pass" -ne "$EXPECTED" ]; then
    printf 'FAILED CASES: %s\n' "${failed[*]}"
    exit 1
fi
exit 0
