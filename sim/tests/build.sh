#!/usr/bin/env bash
#=============================================================================
# build.sh —— 编译 sim/tests/ 下的裸机测试程序
#
#   用法: sim/tests/build.sh [test_name ...]      （默认 hello memtest）
#   产物: sim/tests/out/<test>.elf
#         sim/tests/out/<test>.hex   （objcopy -O verilog --verilog-data-width=1，
#                                     字节宽度 + @地址，供 TB 的 $readmemh 直接用）
#         sim/tests/out/<test>.dump  （objdump -d，便于查错）
#
#   编译选项按要求固定：-march=rv32i -mabi=ilp32 -nostdlib -nostartfiles -O1 -T link.ld
#   （-march=rv32i 时不用 libgcc，故 C 代码不得使用除法/取模/64 位运算）
#=============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$HERE/out"
mkdir -p "$OUT"

# 工具链前缀：可用环境变量覆盖（CROSS=riscv64-unknown-elf- 等）
CROSS="${CROSS:-riscv32-unknown-linux-gnu-}"
CC="${CC:-${CROSS}gcc}"
OBJCOPY="${OBJCOPY:-${CROSS}objcopy}"
OBJDUMP="${OBJDUMP:-${CROSS}objdump}"

for tool in "$CC" "$OBJCOPY"; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: 找不到 $tool（用 CROSS= 指定前缀）" >&2; exit 1; }
done

CFLAGS=(-march=rv32i -mabi=ilp32 -nostdlib -nostartfiles -O1 -T "$HERE/link.ld"
        -ffreestanding -fno-builtin -fno-stack-protector -Wall -Wextra)

TESTS=("$@")
[ "${#TESTS[@]}" -eq 0 ] && TESTS=(hello memtest)

rc=0
for t in "${TESTS[@]}"; do
    src="$HERE/$t.c"
    [ -f "$src" ] || { echo "ERROR: 缺少源文件 $src" >&2; rc=1; continue; }

    echo "[build] $t"
    "$CC" "${CFLAGS[@]}" -o "$OUT/$t.elf" "$HERE/crt0.S" "$src"
    "$OBJCOPY" -O verilog --verilog-data-width=1 "$OUT/$t.elf" "$OUT/$t.hex"
    command -v "$OBJDUMP" >/dev/null 2>&1 && "$OBJDUMP" -d "$OUT/$t.elf" > "$OUT/$t.dump" || true

    size=$(stat -c%s "$OUT/$t.hex")
    echo "        ELF=$OUT/$t.elf  HEX=$OUT/$t.hex (${size} B)"
done

[ "$rc" -eq 0 ] && echo "[build] OK: ${TESTS[*]}"
exit "$rc"
