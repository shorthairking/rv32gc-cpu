#!/usr/bin/env bash
#==============================================================================
# run_all.sh —— privilege-memory 固定 11 例清单（p0..p5, b1..b3, l1..l2）
#   清单硬编码 + 长度断言 == 11；执行前逐文件存在性预检；缺失即 0/11 + exit 1；
#   逐例独立子进程/退出码；汇总恒为 <pass>/11，pass!=11 即 exit 1。
#==============================================================================
set -uo pipefail
DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPT_DIR="${VALIDATION_SCRIPT_DIR:-$DIR}"

MANIFEST=(p0 p1 p2 p3 p4 p5 b1 b2 b3 l1 l2)
EXPECTED=11
if [ "${#MANIFEST[@]}" -ne "$EXPECTED" ]; then
    echo "MANIFEST: internal count ${#MANIFEST[@]} != ${EXPECTED}"; exit 1
fi
cd "$DIR" || exit 1

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

pass=0; failed=()
for id in "${MANIFEST[@]}"; do
    if bash "${SCRIPT_DIR}/run_${id}.sh" > "${SCRIPT_DIR}/all_${id}.out" 2>&1; then
        pass=$((pass + 1)); echo "PASS ${id}"
    else
        failed+=("$id"); echo "FAIL ${id}"
    fi
done
echo "------------------------------------------------------------"
echo "VALIDATION: ${pass}/${EXPECTED}"
if [ "$pass" -ne "$EXPECTED" ]; then
    printf 'FAILED CASES: %s\n' "${failed[*]}"
    exit 1
fi
exit 0
