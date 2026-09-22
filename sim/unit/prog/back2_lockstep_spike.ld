/* Spike 侧链接脚本：同一份源码链到 Spike 默认内存基址（0x8000_0000），
 * 黄金轨迹按固定偏移（SPIKE_BASE - BASE = 0x7FFF_F000）重定位回 TB 侧基址。
 *
 * ★ 关键口径：**各段相对 .text 的偏移必须与 back2_lockstep.ld 完全一致**
 *   （TB 侧：.text@0x1000 → .tohost@0x1800(+0x800) / .data@0x2000(+0x1000) /
 *     .bss@0x2800(+0x1800)；本文件即 0x8000_0000 → +0x800 / +0x1000 / +0x1800）。
 *   否则 `%pcrel_hi/%pcrel_lo` 解析出的立即数在两次链接间不同，gen 脚本的
 *   "两次链接 .text 逐字节相同"自检会（正确地）报 FATAL —— 这正是该自检的用途。 */
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
