/* 2B-1 前端集成验证程序链接脚本：主体放在 0x8000_0000（Spike 习惯布局） */
OUTPUT_ARCH(riscv)
ENTRY(_start)
SECTIONS
{
  . = 0x80000000;
  .text : { *(.text*) }
  .rodata : { *(.rodata*) }
  .data : { *(.data*) }
  .bss : { *(.bss*) *(COMMON) }
  _end = .;
}
