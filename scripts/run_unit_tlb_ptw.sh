#!/usr/bin/env bash
#=============================================================================
# run_unit_tlb_ptw.sh —— Sv32 MMU 模块层单元测试：rv32_ptw（两级页表遍历）
#                        + rv32_tlb（全相联 CAM）编译 + 运行 + 判定
#
#   * iverilog -g2005 编译 rtl/mmu/rv32_ptw.v + rtl/mmu/rv32_tlb.v
#     + sim/tests/unit/tb_unit_tlb_ptw.v（TB 内含 16 KiB 页表内存模型 + 可配延迟总线从设备）
#   * vvp 运行，testbench 打印 "TLB_PTW_UNIT: PASS (N checks)"
#   * 编译失败、运行失败或未打印 PASS 行 ⇒ 退出码非 0
#
# 产物：
#   sim/log/tb_unit_tlb_ptw.vvp           编译产物
#   sim/log/tb_unit_tlb_ptw.log           运行输出（含 PASS/FAIL 行）
#   sim/log/tb_unit_tlb_ptw.compile.log   编译告警/错误（失败时打印，成功且非空时回显）
#
# 用法：bash scripts/run_unit_tlb_ptw.sh
#=============================================================================
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2

LOG_DIR="$ROOT/sim/log"
VVP="$LOG_DIR/tb_unit_tlb_ptw.vvp"
LOG="$LOG_DIR/tb_unit_tlb_ptw.log"
CLOG="$LOG_DIR/tb_unit_tlb_ptw.compile.log"
mkdir -p "$LOG_DIR"

SRCS="rtl/mmu/rv32_tlb.v rtl/mmu/rv32_ptw.v sim/tests/unit/tb_unit_tlb_ptw.v"

echo "== 编译 (iverilog -g2005) =="
# shellcheck disable=SC2086
if ! iverilog -g2005 -Wall -Wno-timescale -I rtl/pkg -s tb_unit_tlb_ptw -o "$VVP" $SRCS >"$CLOG" 2>&1; then
  echo "TLB_PTW_UNIT: COMPILE_FAIL"
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
  echo "TLB_PTW_UNIT: RUN_FAIL (vvp exit=$rc_pipe)"
  exit 1
fi

if grep -q "^TLB_PTW_UNIT: PASS" "$LOG"; then
  grep "^TLB_PTW_UNIT: PASS" "$LOG"
  exit 0
fi

echo "TLB_PTW_UNIT: FAIL"
grep -E "^\[FAIL\]|^TLB_PTW_UNIT" "$LOG" | head -40
exit 1
