#!/usr/bin/env bash
#=============================================================================
# run_unit_icache.sh —— L1 指令 Cache（rtl/frontend/rv32_icache.v）单元/定向测试
#
#   * iverilog -g2005 编译 rtl/frontend/rv32_icache.v + rtl/bus/rv32_axi_master.v
#     + sim/tb/sim_axi_slave.v + sim/tests/unit/tb_icache.v
#   * vvp 运行，TB 打印 "ICACHE_UNIT: PASS (N checks)"
#   * 编译失败、运行失败或未打印 PASS 行 ⇒ 退出码非 0
#
# 覆盖：命中/缺失数据正确性、XIP 绕 Cache（不命中 + **不分配**）、RR 替换、
#       `fence.i` 整表失效、`fence.i` 打断在途填充（丢弃 + 重发）、ENABLE=0 直通。
#       详见 sim/tests/unit/tb_icache.v 头部。
#
# 用法：bash scripts/run_unit_icache.sh
#=============================================================================
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2

LOG_DIR="$ROOT/sim/log"
VVP="$LOG_DIR/tb_icache.vvp"
LOG="$LOG_DIR/tb_icache.log"
CLOG="$LOG_DIR/tb_icache.compile.log"
mkdir -p "$LOG_DIR"

SRCS="rtl/frontend/rv32_icache.v rtl/bus/rv32_axi_master.v sim/tb/sim_axi_slave.v sim/tests/unit/tb_icache.v"

echo "== 编译 (iverilog -g2005) =="
# shellcheck disable=SC2086
if ! iverilog -g2005 -Wall -Wno-timescale -I rtl/pkg -s tb_icache -o "$VVP" $SRCS >"$CLOG" 2>&1; then
  echo "ICACHE_UNIT: COMPILE_FAIL"
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
  echo "ICACHE_UNIT: RUN_FAIL (vvp exit=$rc_pipe)"
  exit 1
fi

if grep -q "^ICACHE_UNIT: PASS" "$LOG"; then
  grep "^ICACHE_UNIT: PASS" "$LOG"
  exit 0
fi

echo "ICACHE_UNIT: FAIL"
grep -aE "^  \[FAIL\]|^ICACHE_UNIT|=== 结果" "$LOG" | head -40
exit 1
