#!/usr/bin/env bash
#=============================================================================
# run_unit_exec.sh —— 执行单元（ALU / MDU / BRU）单元测试：编译 + 运行 + 判定
#
#   * iverilog -g2005 编译 rtl/exec/*.v + sim/tests/unit/tb_exec_units.v
#   * vvp 运行，testbench 打印 "EXEC_UNIT_TESTS: PASS (N checks)"
#   * 编译失败、运行失败或未打印 PASS 行 ⇒ 退出码非 0
#
# 用法：bash scripts/run_unit_exec.sh
#=============================================================================
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2

LOG_DIR="$ROOT/sim/log"
VVP="$LOG_DIR/tb_exec_units.vvp"
LOG="$LOG_DIR/tb_exec_units.log"
mkdir -p "$LOG_DIR"

SRCS="rtl/exec/rv32_alu.v rtl/exec/rv32_mul_div.v rtl/exec/rv32_bru.v \
      sim/tests/unit/tb_exec_units.v"

echo "== 编译 (iverilog -g2005) =="
# shellcheck disable=SC2086
if ! iverilog -g2005 -Wall -Wno-timescale -I rtl/pkg -s tb_exec_units -o "$VVP" $SRCS >"$LOG" 2>&1; then
  echo "EXEC_UNIT_TESTS: COMPILE_FAIL"
  cat "$LOG"
  exit 1
fi
if [ -s "$LOG" ]; then
  echo "-- 编译告警 --"
  cat "$LOG"
fi

echo "== 运行 (vvp) =="
vvp "$VVP" 2>&1 | tee "$LOG.run"
rc_pipe=${PIPESTATUS[0]}
if [ "$rc_pipe" -ne 0 ]; then
  echo "EXEC_UNIT_TESTS: RUN_FAIL (vvp exit=$rc_pipe)"
  exit 1
fi

if grep -q "^EXEC_UNIT_TESTS: PASS" "$LOG.run"; then
  grep "^EXEC_UNIT_TESTS: PASS" "$LOG.run"
  exit 0
fi

echo "EXEC_UNIT_TESTS: FAIL"
grep -E "^\[FAIL\]|^EXEC_UNIT_TESTS" "$LOG.run" | head -40
exit 1
