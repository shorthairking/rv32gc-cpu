/*=============================================================================
 * spi_link.ld —— SPI-XIP 启动链路测试专用链接脚本（2A-7a）
 *-----------------------------------------------------------------------------
 * 为什么需要独立链接脚本：chiplab 平台的**复位取指地址是 0x1C00_0000**
 *   （SPI Flash XIP 窗口，1 MiB；依据 chiplab/IP/AMBA/axi_mux_syn.v:946，
 *    araddr[31:20]==12'h1c0 → SPI），而 DDR 从 0x0000_0000 起。
 *   两个窗口相距约 448 MiB，必须让代码**同时**落在两个窗口里，
 *   因此需要两个独立的地址区域（普通 link.ld 只有 0x0 起的一块 RAM）。
 *
 * 布局（与任务 2A-7a 硬性要求一致）：
 *   .text.spi → ORIGIN(SPI) = 0x1C00_0000   （≤ 1 MiB；复位后从这里取第一条指令）
 *   .text.ddr → ORIGIN(DDR) = 0x0000_0000   （跨窗口跳转的落脚点）
 *
 * 镜像切分（由 scripts/run_spi_boot_test.sh 负责）：
 *   同一个 ELF 产出两份字节宽度 hex：
 *     spiboot.spi.hex ← 仅 .text.spi，地址重定位到 0x0 → TB 的 +SPI_INIT=
 *     spiboot.ddr.hex ← 仅 .text.ddr，保持真实地址 0x0 → TB 的 +MEM_LO_INIT=
 *   注意：$readmemh 的目标数组 mem_spi[] 是 0 基（1 MiB），所以 SPI 那份 hex
 *   的 @地址必须是 0 基，不能直接把含 0x1C00_0000 地址记录的 hex 喂给它。
 *===========================================================================*/
OUTPUT_ARCH("riscv")
ENTRY(spi_entry)

MEMORY
{
  /* SPI Flash XIP 窗口：复位取指处，只读（XIP） */
  SPI (rx)   : ORIGIN = 0x1C000000, LENGTH = 1M
  /* DDR3：AXI 默认从设备窗口，可读写（仿真里是 mem_lo，默认 16 MiB） */
  DDR (rwxa) : ORIGIN = 0x00000000, LENGTH = 16M
}

SECTIONS
{
  /* ---- SPI 窗口：复位后执行的第一段（boot stub）---- */
  . = ORIGIN(SPI);
  .text.spi : ALIGN(4)
  {
    KEEP(*(.text.spi))
    *(.text.spi.*)
    . = ALIGN(4);
    _spi_image_end = .;
  } > SPI

  /* ---- DDR 窗口：被 SPI stub 接管过去的第二段 ---- */
  . = ORIGIN(DDR);
  .text.ddr : ALIGN(4)
  {
    KEEP(*(.text.ddr))
    *(.text.ddr.*)
    . = ALIGN(4);
    _ddr_image_end = .;
  } > DDR

  /* ---- 不留任何其它分配段：本测试是纯汇编、单文件 ---- */
  /DISCARD/ : { *(.comment) *(.note*) *(.eh_frame*) *(.riscv.attributes) }
}
