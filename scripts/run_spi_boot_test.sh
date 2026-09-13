#!/usr/bin/env bash
#=============================================================================
# run_spi_boot_test.sh —— 阶段 2A-7a：SPI-XIP 启动链路仿真验证
#
#   用法: bash scripts/run_spi_boot_test.sh [+wave]
#   成功: 打印 "SPI_BOOT: PASS" 并 exit 0；否则 "SPI_BOOT: FAIL ..." 且 exit 1
#
# 验证什么（验收语义）：
#   -DRESET_PC=32'h1C000000 复位 → 在 SPI Flash XIP 窗口（0x1C00_0000，1 MiB）取到并
#   执行首条指令 → SPI 内自检（PC 落窗 + 算术 + XIP 数据读）→ auipc+addi+jalr 跨约
#   448 MiB 跳到 DDR 0x0 的 ddr_stage → DDR 内自检（算术 + 写读回，含 store→load 同址
#   回读）→ 全通过写退出码 0，任一步失败写非零退出码。
#
# 为什么要独立脚本（不能直接复用 scripts/run_sim.sh）：
#   1) 本核 RTL 的复位 PC 由 `RESET_PC 宏决定（rtl/pkg/rv32gc_defs.vh:50，默认 0x0）。
#      平台实机是从 SPI Flash 复位取指的，所以这条链路必须**用 -DRESET_PC 重新编译
#      RTL**；其余回归（hello/memtest）仍用默认 0x0，互不影响。
#   2) 需要**同时**喂两个镜像：SPI 窗口镜像走 +SPI_INIT=（sim_axi_slave 的 mem_spi[]），
#      DDR 段镜像走 +MEM_LO_INIT=。run_sim.sh 只认识后者。
#   3) 判定要看"首笔取指落在 SPI 窗口 / 提交 PC 跨过两个窗口"，只有专用 TB
#      （sim/tb/tb_spi_boot.v）提供这些观测。
#
# 镜像怎么切（关键设计）：
#   sim/tests/spi_boot.S 一个源文件里有两段：
#       .text.spi → 0x1C00_0000（SPI XIP 窗口，复位入口）
#       .text.ddr → 0x0000_0000（DDR 窗口，跨窗口跳转落脚点）
#   sim/tests/spi_link.ld 把两段放到两个地址区，交叉引用（auipc %pcrel_hi/%pcrel_lo）
#   在同一个 ELF 里解析 —— 这是必须的：两个镜像的**相对距离**要由链接器算出。
#   然后**同一个 ELF 分成两份字节宽度 hex**（objcopy -O verilog --verilog-data-width=1，
#   即 $readmemh 能直接吃的 "@地址 + 每行 16 个字节" 格式）：
#       SPI 段：--only-section=.text.spi --change-section-address .text.spi=0
#               为什么要重定位到 0：$readmemh 的目标 mem_spi[] 是 0 基数组（1 MiB），
#               直接把带 @1C000000 记录的 hex 喂进去会越界，载不进去。
#       DDR 段：--only-section=.text.ddr（地址本来就是真实地址 0x0）
#   注意：objcopy 的 verilog 输出按 LMA 写地址，所以必须用 --change-section-address
#   （同时改 VMA+LMA）；只改 --change-section-vma 实测无效（输出仍是 @1C000000）。
#
# 怎么判定"退出码 0 = PASS"（确定性）：
#   程序把退出码写到 0x1FAF_FF00（平台 CONFREG 仿真的 IO_SIMU）。sim_axi_slave 在该
#   地址的**写 beat 落地**时置 1 拍 exit_we 并锁存 exit_wdata；tb_spi_boot.v 在
#   exit_we 有效的那一拍直接用**当前退出值**判定（0 → PASS/结束，非 0 → FAIL/$fatal），
#   所以"写 0"是被**确定性**检测到的，不存在"只有非零才停下、写 0 被判超时"的坑。
#   本脚本再做双保险：rc==0 且日志里出现 'SPI_BOOT: PASS'，且不得出现
#   TIMEOUT / SPI_BOOT: FAIL / %Error / Error: / $fatal 相关行。
#
# 环境变量：CROSS=<工具链前缀>（默认 riscv32-unknown-linux-gnu-）
#           SPI_BOOT_TIMEOUT=<拍数>（默认 200000，透传 TB 的 +timeout=）
#=============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

WAVE=0
for a in "$@"; do
    case "$a" in
        +wave|wave) WAVE=1 ;;
        *) echo "未知参数: $a" >&2; exit 2 ;;
    esac
done

CROSS="${CROSS:-riscv32-unknown-linux-gnu-}"
CC="${CROSS}gcc"
OBJCOPY="${CROSS}objcopy"
OBJDUMP="${CROSS}objdump"

for tool in "$CC" "$OBJCOPY" iverilog vvp; do
    command -v "$tool" >/dev/null 2>&1 || { echo "SPI_BOOT: FAIL (找不到 $tool)" >&2; exit 1; }
done

LOG_DIR="sim/log"
OUT_DIR="sim/tests/out"
mkdir -p "$LOG_DIR" "$OUT_DIR"

ELF="$OUT_DIR/spi_boot.elf"
DUMP="$OUT_DIR/spi_boot.dump"
SPI_HEX="$OUT_DIR/spi_boot.spi.hex"
DDR_HEX="$OUT_DIR/spi_boot.ddr.hex"
LOG="$LOG_DIR/spi_boot.log"
VVP="$LOG_DIR/spi_boot.vvp"
COMP_LOG="$LOG_DIR/spi_boot.comp.log"

RESET_PC="32'h1C000000"
SPI_WINDOW_BYTES=$((1024*1024))
TIMEOUT="${SPI_BOOT_TIMEOUT:-200000}"

fail() { echo "SPI_BOOT: FAIL ($*)"; exit 1; }

#------------------------------------------------------------------------------
# 1. 编译测试程序（两段式：.text.spi @0x1C000000 / .text.ddr @0x0）
#    -mno-relax：本测试要**验证 auipc+addi+jalr 这条跨 ~448 MiB 的地址组合**，
#    关掉链接松弛以免 auipc/addi 被改写成别的形态（源码里另有 .option norelax）。
#------------------------------------------------------------------------------
echo "[spi-boot] 1/4 编译测试程序 $ELF"
"$CC" -march=rv32i -mabi=ilp32 -nostdlib -nostartfiles -O1 -mno-relax \
      -ffreestanding -fno-builtin -fno-stack-protector -Wall -Wextra \
      -T sim/tests/spi_link.ld -o "$ELF" sim/tests/spi_boot.S \
      > "$COMP_LOG" 2>&1 || { cat "$COMP_LOG"; fail "spi_boot.S 编译失败"; }
command -v "$OBJDUMP" >/dev/null 2>&1 && "$OBJDUMP" -d "$ELF" > "$DUMP" 2>/dev/null || true

# 入口必须是 SPI 窗口的 0x1C000000
ENTRY_ADDR="$($OBJDUMP -f "$ELF" | awk '/start address/{print $NF}')"
[ "$ENTRY_ADDR" = "0x1c000000" ] || fail "ELF 入口 = $ENTRY_ADDR，应为 0x1c000000（SPI 窗口）"

#------------------------------------------------------------------------------
# 2. 切分两份字节宽度 hex（+SPI_INIT= 与 +MEM_LO_INIT= 各一份）
#------------------------------------------------------------------------------
echo "[spi-boot] 2/4 切分镜像 → $SPI_HEX / $DDR_HEX"
"$OBJCOPY" -O verilog --verilog-data-width=1 \
           --only-section=.text.spi --change-section-address .text.spi=0 \
           "$ELF" "$SPI_HEX" >> "$COMP_LOG" 2>&1 || fail "SPI 段 hex 生成失败"
"$OBJCOPY" -O verilog --verilog-data-width=1 \
           --only-section=.text.ddr \
           "$ELF" "$DDR_HEX" >> "$COMP_LOG" 2>&1 || fail "DDR 段 hex 生成失败"

[ -s "$SPI_HEX" ] || fail "SPI 镜像为空"
[ -s "$DDR_HEX" ] || fail "DDR 镜像为空"

# objcopy 的 verilog 输出是 CRLF 行尾；$readmemh 能吃，但这里统一规整成 LF，
# 方便下面的解析与人工核对（不影响任何既有构建脚本的行为）。
sed -i 's/\r$//' "$SPI_HEX" "$DDR_HEX"

# 2a) SPI 镜像必须落在 1 MiB 窗口内，且从 0 基开始（$readmemh 目标是 mem_spi[0:1MiB-1]）
N_AT="$(grep -c '^@' "$SPI_HEX" || true)"
[ "$N_AT" = "1" ] || fail "SPI hex 含有 $N_AT 个地址记录段（应为 1 段连续镜像）"
head -1 "$SPI_HEX" | grep -q '^@00000000$' || \
    fail "SPI hex 基地址不是 0（objcopy --change-section-address 没生效？）"
SPI_BYTES="$(awk 'NR>1 && $0 !~ /^@/{n+=NF} END{printf "%d", n+0}' "$SPI_HEX")"
[ "$SPI_BYTES" -le "$SPI_WINDOW_BYTES" ] || \
    fail "SPI 镜像 ${SPI_BYTES} B 超过 1 MiB 窗口"

# 2b) 首 4 字节必须是入口指令 auipc t0,0 = 0x00000297（小端 → 97 02 00 00），
#     同时验证 hex 的字节序/地址都正确（错了就说明镜像装反了）
FIRST4="$($OBJDUMP -d "$ELF" | awk '/^1c000000 </{getline; print $2; exit}')"
[ "$FIRST4" = "00000297" ] || fail "入口指令不是 auipc t0,0（实际 $FIRST4）"
HEAD_BYTES="$(sed -n 2p "$SPI_HEX" | awk '{printf "%s %s %s %s", $1, $2, $3, $4}')"
case "$HEAD_BYTES" in
    97\ 02\ 00\ 00) ;;
    *) fail "SPI 镜像首 4 字节 = '$HEAD_BYTES'，应为 '97 02 00 00'（字节序/重定位错误）" ;;
esac

echo "[spi-boot]    SPI 段 ${SPI_BYTES} B（1 MiB 窗口内，已重定位到 0 基）；入口指令 $FIRST4"

# 2b') DDR 段：必须从 0 基开始（$readmemh 目标是 mem_lo[0:16MiB-1]），且在 mem_lo 内
N_AT_DDR="$(grep -c '^@' "$DDR_HEX" || true)"
if [ "$N_AT_DDR" != "0" ]; then
    [ "$N_AT_DDR" = "1" ] || fail "DDR hex 含有 $N_AT_DDR 个地址记录段（应为 1 段连续镜像）"
    head -1 "$DDR_HEX" | grep -q '^@00000000$' || fail "DDR hex 基地址不是 0（应为 0x0）"
fi
DDR_BYTES="$(awk 'NR>1 && $0 !~ /^@/{n+=NF} END{printf "%d", n+0}' "$DDR_HEX")"
[ "$DDR_BYTES" -le $((16*1024*1024)) ] || fail "DDR 镜像 ${DDR_BYTES} B 超出 mem_lo（16 MiB）"
echo "[spi-boot]    DDR 段 ${DDR_BYTES} B（@0x0，载入 mem_lo[0:16MiB]）"

# 2c) 跨窗口跳转的编码必须是 auipc+addi+jalr 三连（-mno-relax + .option norelax）
XJ="$($OBJDUMP -d "$ELF" | awk '
  /Disassembly of section .text.spi:/ { in_spi=1; next }
  /Disassembly of section .text.ddr:/ { in_spi=0 }
  in_spi && /^[[:space:]]*[0-9a-f]+:/ { p0=p1; p1=p2; p2=$0;
      if ($0 ~ /[[:space:]]jalr/) { print p0; print p1; print p2; exit } }')"
XJ1="$(printf '%s\n' "$XJ" | sed -n 1p)"
XJ2="$(printf '%s\n' "$XJ" | sed -n 2p)"
XJ3="$(printf '%s\n' "$XJ" | sed -n 3p)"
case "$XJ1" in
    *auipc*) ;;
    *) fail "跨窗口跳转前一条不是 auipc（实际: $XJ1）" ;;
esac
case "$XJ2" in
    *addi*) ;;
    *) fail "跨窗口跳转前第二条不是 addi（实际: $XJ2）" ;;
esac
case "$XJ3" in
    *jalr*) ;;
    *) fail "跨窗口跳转第 3 条不是 jalr（实际: $XJ3）" ;;
esac
echo "[spi-boot]    跨窗口跳转编码（auipc+addi+jalr）："
printf '%s\n' "$XJ" | sed 's/^/      /'

#------------------------------------------------------------------------------
# 3. 编译 RTL + TB（-DRESET_PC=0x1C000000，top = tb_spi_boot）
#------------------------------------------------------------------------------
echo "[spi-boot] 3/4 编译 RTL（-DRESET_PC=$RESET_PC）+ TB tb_spi_boot"
RTL_SRCS=()
while IFS= read -r f; do RTL_SRCS+=("$f"); done < <(find rtl -name '*.v' -type f | sort)
TB_SRCS=()
while IFS= read -r f; do TB_SRCS+=("$f"); done < <(find sim/tb -maxdepth 1 -name '*.v' -type f | sort)

if ! iverilog -g2005 -Wall -I rtl/pkg -s tb_spi_boot -o "$VVP" \
        -DCORE_PRESENT -DRESET_PC="$RESET_PC" \
        "${RTL_SRCS[@]}" "${TB_SRCS[@]}" > "$COMP_LOG" 2>&1; then
    cat "$COMP_LOG"
    fail "iverilog 编译失败"
fi
echo "[spi-boot]    RTL=${#RTL_SRCS[@]} 个文件 TB=${#TB_SRCS[@]} 个文件"

#------------------------------------------------------------------------------
# 4. 跑仿真
#------------------------------------------------------------------------------
PLUSARGS=("+MEM_LO_INIT=$DDR_HEX" "+SPI_INIT=$SPI_HEX" "+timeout=$TIMEOUT")
[ "$WAVE" -eq 1 ] && PLUSARGS+=("+wave=$LOG_DIR/spi_boot.vcd")

echo "[spi-boot] 4/4 运行仿真"
echo "[spi-boot]   plusargs: ${PLUSARGS[*]}"
echo "-----------------------------------------------------------------"
set +e
vvp "$VVP" "${PLUSARGS[@]}" 2>&1 | tee "$LOG"
rc="${PIPESTATUS[0]}"
set -e
echo "-----------------------------------------------------------------"

#------------------------------------------------------------------------------
# 5. 判定
#------------------------------------------------------------------------------
if [ "$rc" -ne 0 ]; then
    echo "SPI_BOOT: FAIL (vvp rc=$rc, log=$LOG)"
    exit 1
fi
if grep -qE 'TIMEOUT|SPI_BOOT: FAIL|%Error|Error:|NO-CORE|FATAL' "$LOG"; then
    echo "SPI_BOOT: FAIL (日志中出现失败标记, log=$LOG)"
    exit 1
fi
if ! grep -q 'SPI_BOOT: PASS' "$LOG"; then
    echo "SPI_BOOT: FAIL (日志中没有 'SPI_BOOT: PASS', log=$LOG)"
    exit 1
fi
# CHECK-6 / XIP 不分配结构断言（第 18 轮新增）：必须**明确出现 PASS**。
# TB 内已判"空转"（要求同时观测到 alloc>0 与 xip_bypass>0），见 tb_spi_boot.v。
if ! grep -q 'CHECK-6 OK' "$LOG"; then
    echo "SPI_BOOT: FAIL (TB CHECK-6 失败：XIP 期间 L1I 发生了分配, log=$LOG)"
    exit 1
fi
if ! grep -q 'XIP_NOALLOC: PASS' "$LOG"; then
    echo "SPI_BOOT: FAIL (日志中没有 'XIP_NOALLOC: PASS', log=$LOG)"
    exit 1
fi

echo "SPI_BOOT: PASS"
echo "[spi-boot] 日志: $LOG  反汇编: $DUMP"
[ "$WAVE" -eq 1 ] && echo "[spi-boot] 波形: $LOG_DIR/spi_boot.vcd"
exit 0
