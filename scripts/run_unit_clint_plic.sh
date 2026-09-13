#!/usr/bin/env bash
#=============================================================================
# run_unit_clint_plic.sh —— 核内 CLINT + PLIC 单元测试：编译 + 运行 + 判定
#
#   * iverilog -g2005 编译 rtl/csr/rv32_clint.v + rtl/csr/rv32_plic.v
#                       + sim/tests/unit/tb_clint_plic.v
#   * vvp 运行，testbench 打印 "CLINT_PLIC_UNIT: PASS (N checks)"
#   * 编译失败、运行失败或未打印 PASS 行 ⇒ 退出码非 0
#
# 产物：
#   sim/log/tb_clint_plic.vvp           编译产物
#   sim/log/tb_clint_plic.log           运行输出（含 PASS/FAIL 行）
#   sim/log/tb_clint_plic.compile.log   编译告警/错误（失败时打印，成功且非空时回显）
#
# 用法：bash scripts/run_unit_clint_plic.sh
#=============================================================================
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2

LOG_DIR="$ROOT/sim/log"
VVP="$LOG_DIR/tb_clint_plic.vvp"
LOG="$LOG_DIR/tb_clint_plic.log"
CLOG="$LOG_DIR/tb_clint_plic.compile.log"
mkdir -p "$LOG_DIR"

SRCS="rtl/csr/rv32_clint.v rtl/csr/rv32_plic.v sim/tests/unit/tb_clint_plic.v"

echo "== 编译 (iverilog -g2005) =="
# shellcheck disable=SC2086
if ! iverilog -g2005 -Wall -Wno-timescale -I rtl/pkg -s tb_clint_plic -o "$VVP" $SRCS >"$CLOG" 2>&1; then
  echo "CLINT_PLIC_UNIT: COMPILE_FAIL"
  cat "$CLOG"
  exit 1
fi
if [ -s "$CLOG" ]; then
  echo "-- 编译告警 --"
  cat "$CLOG"
fi

echo "== 运行 (vvp) =="
vvp "$VVP" 2>&1 | tee "$LOG"
rc_pipe=${PIPESTATUS[0]}
if [ "$rc_pipe" -ne 0 ]; then
  echo "CLINT_PLIC_UNIT: RUN_FAIL (vvp exit=$rc_pipe)"
  exit 1
fi

if grep -q "^CLINT_PLIC_UNIT: PASS" "$LOG"; then
  grep "^CLINT_PLIC_UNIT: PASS" "$LOG"
  exit 0
fi

echo "CLINT_PLIC_UNIT: FAIL"
grep -E "^\[FAIL\]|^CLINT_PLIC_UNIT" "$LOG" | head -60
exit 1
