/*=============================================================================
 * ddr_main.ld —— DDR 主镜像链接脚本（按 0x0 链接，2A-7b 判据）
 *-----------------------------------------------------------------------------
 * DDR3 = 128 MiB，AXI **默认从设备**在 0x0（D15：不改互连编址）；
 * 复位后由 SPI 小引导跳入本镜像的 `_start`（0x0）。
 * 真机把 OpenSBI+U-Boot 链接进来时，用本脚本 + 追加目标文件即可；
 * 本仓库的仿真验收只需要 `ddr_main.S` 这一层。
 *===========================================================================*/
OUTPUT_ARCH("riscv")
ENTRY(_start)

MEMORY
{
  DDR (rwxa) : ORIGIN = 0x00000000, LENGTH = 128M
}

SECTIONS
{
  .text : { *(.text.ddr) *(.text .text.*) } > DDR
  .rodata : { *(.rodata.ddr) *(.rodata .rodata.*) } > DDR
  .data : { *(.data .data.*) } > DDR
  .bss  : { *(.bss .bss.*) *(COMMON) } > DDR

  /* 供 OpenSBI 链接时提供；未提供则本占位版走 sim_done */
  PROVIDE(__opensbi_entry = 0);
  __ddr_size = SIZEOF(.text) + SIZEOF(.rodata) + SIZEOF(.data) + SIZEOF(.bss);

  /DISCARD/ : { *(.comment) *(.riscv.attributes) }
}
