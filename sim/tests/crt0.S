/*=============================================================================
 * crt0.S —— RV32GC 裸机启动代码（自研仿真平台）
 *-----------------------------------------------------------------------------
 *   1) 设置栈指针 sp = _stack_top (0x0008_0000)
 *   2) 清零 .bss
 *   3) call main
 *   4) 把 main 的返回值写到 IO_SIMU（0x1FAFFF00）作为退出码，然后自陷
 *
 * 退出约定见 docs/kb/07-sim-debug.md：写 0x1FAFFF00 = 退出码；
 * TB 打印 EXIT code=<n> 并结束仿真（code=0 视为通过）。
 *===========================================================================*/

  .section .text.init, "ax"
  .globl _start
  .type  _start, @function
_start:
  /* 1) 栈 */
  la      sp, _stack_top

  /* 2) 清零 bss */
  la      t0, _bss_start
  la      t1, _bss_end
1:
  bgeu    t0, t1, 2f
  sw      zero, 0(t0)
  addi    t0, t0, 4
  j       1b
2:

  /* 3) main() */
  call    main

  /* 4) 退出码 = main 返回值 → IO_SIMU */
  li      t0, 0x1FAFFF00
  sw      a0, 0(t0)
3:
  j       3b                    /* 兜底：模型未结束时停在原地 */

  .size _start, . - _start
  .end
