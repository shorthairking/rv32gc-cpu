#!/usr/bin/env bash
#=============================================================================
# arch_test_build.sh —— 用 riscv-arch-test(ACT4) 的测试源构建"自校验 ELF"
#
# 参考签名由 **Spike** 生成（真实参考模型，不是占位值）：
#   phase 1: gcc -DSIGNATURE           -> <name>.sig.elf
#            spike --test-signature=…  -> <name>.sig   （参考签名）
#   phase 2: gcc -DRVTEST_SELFCHECK -DSIGNATURE_FILE="<name>.sig.results"
#            -> <name>.elf            （把参考签名编译进镜像，运行时自比对）
#
# 用法:
#   scripts/arch_test_build.sh <test.S 相对/绝对路径> [outdir] [march] [mabi]
# 例:
#   scripts/arch_test_build.sh riscv-arch-test/tests/rv32i/I/I-add-00.S
#   scripts/arch_test_build.sh riscv-arch-test/tests/rv32i/Zca/c.add-00.S "" rv32imac_zicsr_zifencei ilp32
#=============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WS_ROOT="$(cd "$ROOT/.." && pwd)"
AT_SRC="${AT_SRC:-$WS_ROOT/riscv-arch-test}"
CFG="$ROOT/sim/arch_test/config"
SPIKE="${SPIKE:-$ROOT/tools/spike-install/bin/spike}"
CC="${CC:-riscv32-unknown-linux-gnu-gcc}"

TEST_SRC="$1"
OUT="${2:-$ROOT/sim/arch_test/out}"
MARCH="${3:-rv32imac_zicsr_zifencei_zicntr}"
MABI="${4:-ilp32}"
NAME="$(basename "$TEST_SRC" .S)"

mkdir -p "$OUT"

if [ ! -x "$SPIKE" ]; then
  echo "ERROR: 未找到 Spike（$SPIKE）。请先编译：见 docs/kb/06-toolchain-build.md §3.1" >&2
  exit 1
fi

# Spike 的 --isa= 不接受全部扩展名，做一次映射
SPIKE_ISA="$(echo "$MARCH" | sed -e 's/_zicsr//' -e 's/_zifencei//' -e 's/_zicntr//' -e 's/_zmmul//' -e 's/_zca//' -e 's/_zcd//' -e 's/_zcf//')"
ISA_STR="rv32${SPIKE_ISA#rv32}"

COMMON=(-Wl,--no-warn-rwx-segments
        -I"$CFG" -I"$AT_SRC/tests/env" -T"$CFG/link.ld"
        -O0 -g -mcmodel=medany -nostdlib -nostartfiles
        -march="$MARCH" -mabi="$MABI"
        -DTEST_FLEN=32 "-DTEST_FILE=\"$NAME.S\"")

echo "[1/2] 构建签名 ELF: $NAME.sig.elf  (march=$MARCH)"
"$CC" "${COMMON[@]}" -DSIGNATURE \
      -DSAIL_CLINT_BASE_ADDRESS=0x02000000 \
      -DSAIL_SIMPLE_INTERRUPT_GENERATOR_BASE_ADDRESS=0x0c000000 \
      -o "$OUT/$NAME.sig.elf" "$TEST_SRC"

echo "[2/2] Spike 生成参考签名 -> $NAME.sig，再构建自校验 ELF: $NAME.elf"
timeout 300 "$SPIKE" --isa="$ISA_STR" "+signature=$OUT/$NAME.sig" \
         "+signature-granularity=4" "$OUT/$NAME.sig.elf" \
         > "$OUT/$NAME.spike.log" 2>&1 || true

if [ ! -s "$OUT/$NAME.sig" ]; then
  echo "ERROR: Spike 未生成签名文件（$OUT/$NAME.sig）。日志尾部：" >&2
  tail -20 "$OUT/$NAME.spike.log" >&2
  exit 1
fi

# ACT4 期望的 .results 文件：与框架 framework/src/act/sig_modify.py 完全一致的格式
#   - 每行加 ".word 0x" 前缀（XLEN=32）
#   - 最后一行前插入 sig_end_canary 标签
#   - 命中 canary 常量的行后插入 final_sig_offset / final_trap_sig_offset / trap_sigptr 标签
python3 - "$OUT/$NAME.sig" "$OUT/$NAME.results" <<'PY'
import sys, pathlib
sig_file, result_file = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
xlen = 32
datatype = ".word" if xlen == 32 else ".quad"
trap_canary           = "d3a91f6c"          if xlen == 32 else "d3a91f6c8b47e25d"
final_sig_canary      = "4b8e2d17"          if xlen == 32 else "4b8e2d17a6c0f953"
final_trap_canary     = "7a110ff5"          if xlen == 32 else "7a110ff5c0def00d"
lines = [l.strip() for l in sig_file.read_text().splitlines() if l.strip()]
with result_file.open("w") as f:
    for i, line in enumerate(lines):
        if i == len(lines) - 1:
            f.write("sig_end_canary:\n")
        f.write(f"{datatype} 0x{line}\n")
        if final_sig_canary in line:
            f.write("final_sig_offset:\n")
        if final_trap_canary in line:
            f.write("final_trap_sig_offset:\n")
        if trap_canary in line:
            f.write("trap_sigptr:\n")
PY

"$CC" "${COMMON[@]}" -DRVTEST_SELFCHECK -DSIGNATURE_FILE="\"$OUT/$NAME.results\"" -DXLEN=32 \
      -o "$OUT/$NAME.elf" "$TEST_SRC"

echo "OK: $OUT/$NAME.elf"
