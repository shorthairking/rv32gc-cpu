/*=============================================================================
 * link.ld —— RV32GC 裸机测试链接脚本（自研仿真平台）
 *-----------------------------------------------------------------------------
 * 约定来源 docs/kb/07-sim-debug.md：
 *   入口 _start，加载地址 0x0000_0000（DDR 窗口，mem_lo[]）
 *   段：.text / .rodata / .data / .bss，栈顶 0x0008_0000（512 KiB 处）
 *   提供 _end（bss 结束地址）
 *===========================================================================*/
OUTPUT_ARCH("riscv")
ENTRY(_start)

MEMORY
{
  RAM (rwxa) : ORIGIN = 0x00000000, LENGTH = 16M
}

SECTIONS
{
  . = 0x00000000;

  .text : ALIGN(4)
  {
    *(.text.init)          /* crt0 的 _start 必须最先，PC=0 复位向量 */
    *(.text .text.*)
  } > RAM

  .rodata : ALIGN(16)
  {
    _rodata_start = .;
    *(.rodata .rodata.*)
    *(.srodata .srodata.*)
    *(.srodata.cst*)
    _rodata_end = .;
  } > RAM

  .data : ALIGN(16)
  {
    _data_start = .;
    *(.data .data.*)
    *(.sdata .sdata.*)
    . = ALIGN(8);
    _data_end = .;
  } > RAM

  .bss : ALIGN(16)
  {
    _bss_start = .;
    *(.sbss .sbss.*)
    *(.bss .bss.*)
    *(COMMON)
    . = ALIGN(8);
    _bss_end = .;
  } > RAM

  . = ALIGN(16);
  _end = .;
  PROVIDE(end = .);
  PROVIDE(__global_pointer$ = . + 0x800);

  /* 栈：向下增长，栈顶 0x0008_0000（避开 0x0001_0000 起的 memtest 区） */
  _stack_top = 0x00080000;
  PROVIDE(__stack_top = _stack_top);

  /DISCARD/ : { *(.comment) *(.note*) *(.eh_frame*) *(.riscv.attributes) }
}
