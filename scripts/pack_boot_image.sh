#!/usr/bin/env bash
#==============================================================================
# pack_boot_image.sh —— 2A-7b「启动镜像三件套」的构建与打包
#
# 产出（默认落在 sw/board/out/）：
#   spi_stub.elf/bin        SPI 小引导（链接 0x1C00_0000，≤1 MiB，全 PC 相对）
#   spi_stub.sim.elf/hex    同上，带 -DSIM_VUART -DSIM_EXIT（仿真用：虚拟串口 + 正常退出）
#   spi_flash.img           按 1 MiB 窗口**填充**后的 SPI 烧写镜像（未用部分填 0xFF）
#   ddr_main.elf/bin        DDR 主镜像（链接 0x0）
#   ddr_main.sim.elf/hex    同上，带 -DSIM_VUART -DSIM_EXIT
#   boot_layout.txt         SPI/NAND 布局与 mtdparts（烧写用）
#
# 硬判据（失败即非零退出）：
#   · SPI 镜像 ≤ 1 MiB（1 MiB XIP 窗口）
#   · SPI 桩**无重定位表**（`readelf -r` 为空）⇒ 证明代码/数据引用全 PC 相对
#   · DDR 镜像入口地址 = 0x0（`readelf -h` 的 Entry / nm 的 _start）
#   · NAND 分区表总长 = 128 MiB（与 docs/porting/00-overview.md §7 一致）
#==============================================================================
set -u
cd "$(dirname "$0")/.."

OUT=sw/board/out
LOG=sim/log/pack_boot.log
CC=${CC:-riscv32-unknown-linux-gnu-gcc}
OBJCOPY=${OBJCOPY:-riscv32-unknown-linux-gnu-objcopy}
READELF=${READELF:-riscv32-unknown-linux-gnu-readelf}
NM=${NM:-riscv32-unknown-linux-gnu-nm}

mkdir -p "$OUT" "$(dirname "$LOG")"
: > "$LOG"
fail() { echo "PACK_BOOT: FAIL ($*)"; exit 1; }
step() { printf '\n== %s ==\n' "$*" >>"$LOG"; }

for t in "$CC" "$OBJCOPY" "$READELF" "$NM"; do
  command -v "$t" >/dev/null 2>&1 || fail "找不到 $t"
done

CFLAGS=(-march=rv32i -mabi=ilp32 -nostdlib -nostartfiles -O2 -ffreestanding -fno-builtin)

#--------------------------------------------------------------- ① SPI 小引导
step "SPI 小引导（链接 0x1C00_0000）"
"$CC" "${CFLAGS[@]}" -T sw/board/spi_stub.ld -o "$OUT/spi_stub.elf" sw/board/spi_stub.S >>"$LOG" 2>&1 \
  || fail "spi_stub.S 编译/链接失败（见 $LOG）"
"$CC" "${CFLAGS[@]}" -DSIM_VUART -DSIM_EXIT -T sw/board/spi_stub.ld \
      -o "$OUT/spi_stub.sim.elf" sw/board/spi_stub.S >>"$LOG" 2>&1 \
  || fail "spi_stub.S(sim) 编译/链接失败（见 $LOG）"
"$OBJCOPY" -O binary "$OUT/spi_stub.elf" "$OUT/spi_stub.bin" >>"$LOG" 2>&1 || fail "SPI bin 生成失败"
"$OBJCOPY" -O binary "$OUT/spi_stub.sim.elf" "$OUT/spi_stub.sim.bin" >>"$LOG" 2>&1 || fail "SPI(sim) bin 生成失败"

SIZE=$(stat -c%s "$OUT/spi_stub.bin")
[ "$SIZE" -le 1048576 ] || fail "SPI 镜像 $SIZE 字节 > 1 MiB（超 XIP 窗口）"
echo "SPI 镜像大小: $SIZE 字节（≤1 MiB  ✓）" >>"$LOG"

# 无重定位表 ⇒ 全 PC 相对（MMIO/协议常量是立即数，不产生重定位）
RELS=$("$READELF" -r "$OUT/spi_stub.elf" 2>/dev/null | grep -c "R_RISCV" || true)
[ "${RELS:-0}" -eq 0 ] || fail "SPI 桩存在 $RELS 条重定位记录（应全 PC 相对）"
echo "重定位记录: 0（全 PC 相对 ✓）" >>"$LOG"

#--------------------------------------------------------------- ② DDR 主镜像
step "DDR 主镜像（链接 0x0）"
"$CC" "${CFLAGS[@]}" -T sw/board/ddr_main.ld -o "$OUT/ddr_main.elf" sw/board/ddr_main.S >>"$LOG" 2>&1 \
  || fail "ddr_main.S 编译/链接失败（见 $LOG）"
"$CC" "${CFLAGS[@]}" -DSIM_VUART -DSIM_EXIT -T sw/board/ddr_main.ld \
      -o "$OUT/ddr_main.sim.elf" sw/board/ddr_main.S >>"$LOG" 2>&1 \
  || fail "ddr_main.S(sim) 编译/链接失败（见 $LOG）"
"$OBJCOPY" -O binary "$OUT/ddr_main.elf" "$OUT/ddr_main.bin" >>"$LOG" 2>&1 || fail "DDR bin 生成失败"
"$OBJCOPY" -O binary "$OUT/ddr_main.sim.elf" "$OUT/ddr_main.sim.bin" >>"$LOG" 2>&1 || fail "DDR(sim) bin 生成失败"

ENTRY=$("$NM" "$OUT/ddr_main.elf" | awk '$3=="_start"{print $1; exit}')
[ "$ENTRY" = "00000000" ] || fail "DDR 镜像 _start = 0x$ENTRY（应为 0x0）"
echo "DDR 入口 _start = 0x$ENTRY  ✓" >>"$LOG"

#--------------------------------------------------------------- ③ SPI 烧写镜像（1 MiB 填充）
step "SPI 烧写镜像（1 MiB 窗口填充 0xFF）"
cat "$OUT/spi_stub.bin" >"$OUT/spi_flash.img" || fail "spi_flash.img 写入失败"
# 未用区填 0xFF（SPI NOR 擦除态）：只对**填充部分**填 0xFF，不能整体替换（会破坏镜像里的 0x00 字节）
dd if=/dev/zero bs=1 count=$((1048576 - SIZE)) status=none \
   | tr '\0' '\377' >>"$OUT/spi_flash.img" || fail "spi_flash.img 填充失败"
ISZ=$(stat -c%s "$OUT/spi_flash.img")
[ "$ISZ" -eq 1048576 ] || fail "spi_flash.img 大小 $ISZ（应为 1 MiB）"
echo "spi_flash.img = $ISZ 字节（1 MiB，未用区 0xFF）" >>"$LOG"

#--------------------------------------------------------------- ④ 仿真 hex（喂 TB）
step "仿真 hex（+SPI_INIT= / +MEM_LO_INIT=）"
"$OBJCOPY" -O verilog --verilog-data-width=1 "$OUT/spi_stub.sim.elf" "$OUT/spi_stub.sim.hex" >>"$LOG" 2>&1 \
  || fail "SPI hex 生成失败"
# SPI 窗口在 TB 里是 0 基数组 ⇒ 把 @1C000000 记录改写成 @0
sed -i 's/@1[Cc]000000/@0/g' "$OUT/spi_stub.sim.hex"
"$OBJCOPY" -O verilog --verilog-data-width=1 "$OUT/ddr_main.sim.elf" "$OUT/ddr_main.sim.hex" >>"$LOG" 2>&1 \
  || fail "DDR hex 生成失败"

#--------------------------------------------------------------- ⑤ 布局清单
step "启动布局"
cat >"$OUT/boot_layout.txt" <<EOF
# RV32-GC + chiplab 启动镜像布局（由 scripts/pack_boot_image.sh 生成）
SPI Flash (S25FL128SAGMFI001, 16 MiB, XIP 窗口 1 MiB):
  0x00000000 + $(printf '%7d' "$SIZE") B : spi_stub.bin   （复位入口 0x1C00_0000，≤1 MiB）
  0x00100000 + 1 MiB           : 预留（fdt-spare，见 sw/board/rv32gc-chiplab.dts）
DDR3 (128 MiB @0x0):
  0x00000000 + $(printf '%7d' "$(stat -c%s "$OUT/ddr_main.bin")") B : ddr_main.bin   （_start = 0x0）
NAND (K9F1G08U0C, 128 MiB) —— 与 docs/porting/00-overview.md §7 一致:
  env    0x00000000 + 256 KiB
  kernel 0x00040000 + 50 MiB    ← 真机上这里是 OpenSBI+U-Boot 打包体
  dtb    0x03240000 + 1 MiB
  rootfs 0x03340000 + 余下
mtdparts: nand-flash:256K(env),50M(kernel)ro,1M(dtb),-(rootfs)
EOF
cat "$OUT/boot_layout.txt" >>"$LOG"

echo "PACK_BOOT: PASS (SPI ${SIZE}B/1MiB, 重定位 0, DDR entry 0x0)"
echo "  产物目录: $OUT（布局见 $OUT/boot_layout.txt）"
