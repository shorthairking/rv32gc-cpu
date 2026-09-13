#!/usr/bin/env bash
#=============================================================================
# run_unit_dcache.sh —— L1 数据 Cache（rtl/mem/rv32_dcache.v）单元/定向测试
#
#   * iverilog -g2005 编译 rtl/mem/rv32_dcache.v + rtl/bus/rv32_axi_master.v
#     + sim/tb/sim_axi_slave.v + sim/tests/unit/tb_dcache.v
#     （行填充走真实的 AXI 主设备 8 beat 突发路径）
#   * vvp 运行，TB 打印 "DCACHE_UNIT: PASS (N checks)" 与 "DWRITE_THRU: PASS (n checks)"
#   * 编译失败、运行失败或任一 PASS 行缺失 ⇒ 退出码非 0
#
# 覆盖：缺失/命中、**store 缺失不分配（allocate 恒 0）**、**store 命中更新行数据**、
#       XIP 绕 Cache（不命中 + 不分配）、设备窗口不缓存、PTW/原子/CBO 旁路与失效、
#       RR 替换、总线错误（旁路 + 填充）、ENABLE=0 直通。
#       详见 sim/tests/unit/tb_dcache.v 头部。
#
# 用法：bash scripts/run_unit_dcache.sh
#=============================================================================
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2

LOG_DIR="$ROOT/sim/log"
VVP="$LOG_DIR/tb_dcache.vvp"
LOG="$LOG_DIR/tb_dcache.log"
CLOG="$LOG_DIR/tb_dcache.compile.log"
mkdir -p "$LOG_DIR"

SRCS="rtl/mem/rv32_dcache.v rtl/bus/rv32_axi_master.v sim/tb/sim_axi_slave.v sim/tests/unit/tb_dcache.v"

echo "== 编译 (iverilog -g2005) =="
# shellcheck disable=SC2086
if ! iverilog -g2005 -Wall -Wno-timescale -I rtl/pkg -s tb_dcache -o "$VVP" $SRCS >"$CLOG" 2>&1; then
  echo "DCACHE_UNIT: COMPILE_FAIL"
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
  echo "DCACHE_UNIT: RUN_FAIL (vvp exit=$rc_pipe)"
  exit 1
fi

ok=1
grep -q "^DCACHE_UNIT: PASS" "$LOG" || ok=0
grep -q "^DWRITE_THRU: PASS" "$LOG" || ok=0
if [ "$ok" -eq 1 ]; then
  grep "^DCACHE_UNIT: PASS" "$LOG"
  grep "^DWRITE_THRU: PASS" "$LOG"
  exit 0
fi

echo "DCACHE_UNIT: FAIL"
grep -aE "^  \[FAIL\]|^DCACHE_UNIT|^DWRITE_THRU|=== 结果" "$LOG" | head -40
exit 1
