#!/usr/bin/env bash
#=============================================================================
# run_arch_test_suite.sh —— 批量运行某个 arch-test 组（ACT4）下的全部用例
#
# 用法:
#   scripts/run_arch_test_suite.sh <组名> [用例名过滤正则]
#   例: scripts/run_arch_test_suite.sh I
#       scripts/run_arch_test_suite.sh Zca 'c\.add'
#
# 环境变量:
#   RV32GC_TIMEOUT   每个用例的仿真超时拍数（默认 300000）
#   SKIP_BUILD=1     复用已构建的 sim/arch_test/out/<name>.elf（不重新生成签名）
#   MARCH/MABI       传给单个用例（默认 rv32imac_zicsr_zifencei_zicntr / ilp32）
#   JOBS             并行度（默认 1；建议 ≤ 核数-1，避免仿真抢占）
#
# 输出:
#   每个用例一行 PASS/FAIL + 末尾汇总；有失败则退出码非 0。
#   单用例完整日志: sim/log/arch_<组>_<用例>.log
#=============================================================================
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
WS_ROOT="$(cd "$ROOT/.." && pwd)"
AT_SRC="${AT_SRC:-$WS_ROOT/riscv-arch-test}"

GROUP="${1:?用法: $0 <组名> [用例名过滤正则]}"
FILTER="${2:-.}"
TMO="${RV32GC_TIMEOUT:-300000}"
MARCH="${MARCH:-rv32imac_zicsr_zifencei_zicntr}"
MABI="${MABI:-ilp32}"
JOBS="${JOBS:-1}"

DIR="$AT_SRC/tests/rv32i/$GROUP"
[ -d "$DIR" ] || { echo "ERROR: 找不到组目录 $DIR"; exit 2; }

mapfile -t TESTS < <(ls "$DIR"/*.S 2>/dev/null | sort | while read -r f; do
                       b="$(basename "$f" .S)"; [[ "$b" =~ $FILTER ]] && echo "$b"; done)
N=${#TESTS[@]}
[ "$N" -gt 0 ] || { echo "ERROR: 组 $GROUP 中无匹配 '$FILTER' 的用例"; exit 2; }

LOG_DIR="sim/log"; mkdir -p "$LOG_DIR"
RES="$LOG_DIR/arch_suite_${GROUP}.results"
: > "$RES"
echo "[suite] 组=$GROUP 用例=$N 超时=$TMO SKIP_BUILD=${SKIP_BUILD:-0} MARCH=$MARCH"

run_one() {
  local name="$1"
  local log="$LOG_DIR/arch_${GROUP}_${name}.log"
  RV32GC_TIMEOUT="$TMO" MARCH="$MARCH" MABI="$MABI" \
    bash scripts/run_arch_test.sh "$GROUP/$name" "$MARCH" "$MABI" > "$log" 2>&1
  if [ $? -eq 0 ] && grep -q "SIM: PASS" "$log"; then
    echo "PASS $GROUP/$name" >> "$RES"
    echo "  PASS $GROUP/$name"
  else
    local cyc; cyc="$(grep -oE 'TB: cycles=[0-9]+' "$log" | tail -1)"
    echo "FAIL $GROUP/$name ${cyc}" >> "$RES"
    echo "  FAIL $GROUP/$name ${cyc}  (log: $log)"
  fi
}

if [ "$JOBS" -le 1 ]; then
  for t in "${TESTS[@]}"; do run_one "$t"; done
else
  # 简单并行：每 JOBS 个用例一批
  i=0
  for t in "${TESTS[@]}"; do
    run_one "$t" &
    i=$((i+1))
    if [ $((i % JOBS)) -eq 0 ]; then wait; fi
  done
  wait
fi

NP=$(grep -c '^PASS' "$RES" || true)
NF=$(grep -c '^FAIL' "$RES" || true)
echo "[suite] 组=$GROUP 结果: PASS=$NP FAIL=$NF / 共 $N"
if [ "$NF" -gt 0 ]; then
  echo "[suite] 失败用例:"
  grep '^FAIL' "$RES" | sed 's/^/  /'
  exit 1
fi
echo "[suite] ARCH_SUITE_PASS $GROUP ($NP/$N)"
