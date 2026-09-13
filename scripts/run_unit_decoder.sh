#!/usr/bin/env bash
#=============================================================================
# run_unit_decoder.sh —— rv32_decoder / rv32_imm_gen 单元测试
#
#   1) 生成测试向量（sim/tests/unit/gen_decoder_vectors.py → decoder_vectors.vh）
#      期望值来自独立参考模型 + 手写期望表 + as/objdump 交叉验证，不使用被测 RTL 输出
#   2) iverilog -g2005 编译 rtl/decode/rv32_imm_gen.v + rtl/decode/rv32_decoder.v
#      + sim/tests/unit/tb_decoder.v
#   3) vvp 运行；失败返回非零并打印第一个不匹配的字段与位号
#      成功打印：DECODER_UNIT_TESTS: PASS (N vectors)
#=============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

LOG_DIR="$ROOT/sim/log"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/tb_decoder.log"

AS=/opt/riscv/bin/riscv32-unknown-linux-gnu-as
OBJDUMP=/opt/riscv/bin/riscv32-unknown-linux-gnu-objdump
for t in python3 iverilog vvp "$AS" "$OBJDUMP"; do
  if ! command -v "$t" >/dev/null 2>&1; then
    echo "DECODER_UNIT_TESTS: ERROR 缺少工具 $t" | tee "$LOG"
    exit 3
  fi
done

echo "== [1/3] 生成测试向量 =="
if ! python3 sim/tests/unit/gen_decoder_vectors.py --out-dir sim/tests/unit 2>&1 | tee "$LOG"; then
  echo "DECODER_UNIT_TESTS: FAIL (向量生成失败，详见 $LOG)"
  exit 1
fi

echo "== [2/3] 编译 (iverilog -g2005) =="
if ! iverilog -g2005 -Wall -I rtl/pkg -I sim/tests/unit \
      -o "$LOG_DIR/tb_decoder.vvp" \
      rtl/decode/rv32_imm_gen.v rtl/decode/rv32_decoder.v sim/tests/unit/tb_decoder.v \
      2>&1 | tee -a "$LOG"; then
  echo "DECODER_UNIT_TESTS: FAIL (编译失败，详见 $LOG)"
  exit 1
fi
if [ ! -f "$LOG_DIR/tb_decoder.vvp" ]; then
  echo "DECODER_UNIT_TESTS: FAIL (未生成 vvp，详见 $LOG)"
  exit 1
fi

echo "== [3/3] 运行仿真 =="
vvp "$LOG_DIR/tb_decoder.vvp" 2>&1 | tee -a "$LOG"

if grep -q "DECODER_UNIT_TESTS: PASS" "$LOG"; then
  exit 0
fi
echo "DECODER_UNIT_TESTS: FAIL (见上方第一个不匹配字段；完整日志 $LOG)"
exit 1
