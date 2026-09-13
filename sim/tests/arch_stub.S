/* arch_stub.S —— 0x0 处跳转桩：把控制权交给 arch-test 入口 rvtest_entry_point(0x8000_2000) */
    .section .text
    .globl _start
_start:
    lui  t0, 0x80002          /* t0 = 0x8000_2000 */
    jr   t0
