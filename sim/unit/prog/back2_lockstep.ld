/* 2B-2 锁步验证程序链接脚本（DUT/TB 侧）：全部落 0x8000_0000 仿真布局
 * （`RV32GC_RESET_PC=0x1C00_0000` 处 2 条跳转桩 → 程序体 @0x8000_0000）。
 *
 * 段布局（相对 .text 的偏移是**硬口径**）：
 *   .text   @0x8000_0000
 *   .tohost @0x8000_0800  (+0x800)   写 1 ⇒ Spike HTIF 结束条件 / TB 终止锚点
 *   .data   @0x8000_1000  (+0x1000)
 *   .bss/栈 @0x8000_1800  (+0x1800)
 *
 * ★ back2_lockstep_spike.ld 必须给出**同样**的相对偏移（否则 `%pcrel_hi/lo` 立即数
 *   在两次链接间不同，gen 脚本的逐字节自检会判 FATAL）。
 * ★ 本布局同时受 TB 的 2A 侧地址翻译约束：0x8000_xxxx → 模型 DDR 窗口 0x0000_xxxx
 *   （sim_mem_model 的 ddr3_read 用绝对下标 ⇒ DDR3_BASE 必须为 0）。 */
OUTPUT_ARCH(riscv)
ENTRY(_start)
SECTIONS
{
  . = 0x80000000;
  .text : { *(.text) *(.text.*) }
  . = 0x80000800;
  .tohost : { *(.tohost) }
  . = 0x80001000;
  .data : { *(.data) *(.rodata) *(.rodata.*) *(.sdata) }
  . = 0x80001800;
  .bss  : { *(.bss) *(.sbss) *(COMMON) }
  _end = .;
}
