/*=============================================================================
 * spi_stub.ld —— SPI 小引导链接脚本（2A-7b）
 *-----------------------------------------------------------------------------
 * 复位取指窗口 = 0x1C00_0000（SPI-XIP，1 MiB，**只读**，D16），因此：
 *   · 代码/只读数据都放在 SPI 段内（XIP 可读）；
 *   · **不留 .data/.bss**（XIP 不可写）：需要可写数据时必须放 DDR（本桩不需要）；
 *   · 出口符号 `__spi_size` 供打包脚本做"≤1 MiB"硬判据。
 *===========================================================================*/
OUTPUT_ARCH("riscv")
ENTRY(_start)

MEMORY
{
  SPI (rx) : ORIGIN = 0x1C000000, LENGTH = 1M
}

SECTIONS
{
  .text : {
    *(.text.spi)
    *(.text .text.*)
    *(.rodata.rodata.spi .rodata .rodata.*)
  } > SPI

  /* 断言：整个桩必须落在 1 MiB 窗口内，且不含可写数据段 */
  __spi_size = SIZEOF(.text);

  /DISCARD/ : { *(.data*) *(.bss*) *(.comment) *(.riscv.attributes) }
}
