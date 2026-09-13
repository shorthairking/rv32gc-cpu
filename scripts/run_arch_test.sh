#!/usr/bin/env bash
#=============================================================================
# run_arch_test.sh —— 构建并运行一个 ACT4 arch-test 用例（在本核仿真平台上）
#
# 流程：
#   1) scripts/arch_test_build.sh 生成自校验 ELF（参考签名来自 Spike）
#   2) 生成 0x0 处跳转桩（本核复位 PC=0）→ sim/tests/out/<name>.hex
#   3) 把测试 ELF 重定位到 mem_hi → sim/tests/out/<name>.hi.hex
#   4) 调 scripts/run_sim.sh <name>（TB 监视 tohost：1=PASS 3=FAIL，并 dump 签名）
#
# 用法:
#   scripts/run_arch_test.sh <group>/<name>            例: I/I-add-00
#   scripts/run_arch_test.sh I/I-add-00 rv32i_zicsr ilp32
# 环境变量:
#   RV32GC_TIMEOUT=<拍数>   覆盖仿真超时（arch-test 规模较大，建议 ≥ 3e7）
#   SKIP_BUILD=1            复用已有的 sim/arch_test/out/<name>.elf
#=============================================================================
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AT_SRC="${AT_SRC:-$(cd "$ROOT/.." && pwd)/riscv-arch-test}"
REL="$1"                                   # 例: I/I-add-00
# MARCH：显式第 2 参数 > 环境变量 MARCH > 留空（由 arch_test_build.sh 从用例头部的
# `# MARCH:` 自动解析，例如 Zicbom 需要 rv32i_zicbom_zicsr_zifencei）。留空可避免用错 ISA
# 串导致 "unrecognized opcode ... extension required"。
MARCH="${2:-${MARCH:-}}"
MABI="${3:-ilp32}"
MABI="${3:-ilp32}"
NAME="$(basename "$REL")"
SRC="$AT_SRC/tests/rv32i/$REL.S"
OUT="$ROOT/sim/arch_test/out"
CC=riscv32-unknown-linux-gnu-gcc
OBJCOPY=riscv32-unknown-linux-gnu-objcopy

[ -f "$SRC" ] || { echo "ERROR: 找不到测试源 $SRC"; exit 2; }

if [ "${SKIP_BUILD:-0}" != "1" ]; then
  if [ -n "$MARCH" ]; then
    bash "$ROOT/scripts/arch_test_build.sh" "$SRC" "$OUT" "$MARCH" "$MABI" >/dev/null
  else
    bash "$ROOT/scripts/arch_test_build.sh" "$SRC" "$OUT" "" "$MABI" >/dev/null
  fi
  echo "[arch-test] 构建完成: $OUT/$NAME.elf"
fi

# 2) 0x0 跳转桩
"$CC" -march=rv32i -mabi=ilp32 -nostdlib -nostartfiles \
      -Wl,-Ttext=0x0 -Wl,--no-warn-rwx-segments \
      "$ROOT/sim/tests/arch_stub.S" -o "$OUT/$NAME.stub.elf" 2>/dev/null
"$OBJCOPY" -O verilog --verilog-data-width=1 "$OUT/$NAME.stub.elf" "$ROOT/sim/tests/out/$NAME.hex"

# 3) 测试镜像重定位到 0x8000_0000
"$OBJCOPY" -O verilog --verilog-data-width=1 --change-addresses=-0x80000000 \
           "$OUT/$NAME.elf" "$ROOT/sim/tests/out/$NAME.hi.hex"

# 4) 运行
#    参考模型 Spike（本版本）对非自然对齐访存一律报 cause 4/6，本核默认是"硬件拆分"（Linux/uboot
#    需要）。arch-test 的 trap 签名比对要求两边一致，故这里默认加 -DMISALIGNED_TRAP
#    （规格 00-conventions 定义的 bring-up/arch-test 模式）；要跑默认拆分行为设
#    RV32GC_NO_MISALIGNED_TRAP=1。
cd "$ROOT"
if [ "${RV32GC_NO_MISALIGNED_TRAP:-0}" != "1" ]; then
  RV32GC_DEFS="${RV32GC_DEFS:--DMISALIGNED_TRAP}"
fi
RV32GC_TIMEOUT="${RV32GC_TIMEOUT:-30000000}" RV32GC_DEFS="${RV32GC_DEFS:-}" bash scripts/run_sim.sh "$NAME"
