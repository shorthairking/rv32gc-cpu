#==============================================================================
# XIP same-word compressed load/branch hazard regression.
# This image runs directly at RV32GC_RESET_PC in XIP (not DDR/trampoline).
# c.lw at word[15:0] and c.bnez at word[31:16] exercise held-word XIP delivery.
# Build with OLD_ONE and EXPECT_TAKEN defining exactly one expected direction.
#==============================================================================
    .option rvc
    .section .text
    .globl _start
_start:
    li   s0, 0x3000
#ifdef OLD_ONE
    li   s1, 1
#else
    li   s1, 0
#endif
    .balign 4
load_pc:
    c.lw  s1, 0(s0)
branch_pc:
    c.bnez s1, taken

not_taken:
#ifdef EXPECT_TAKEN
    li   t0, 0x2000
    li   t1, 0x0bad
    sw   t1, 0(t0)
    li   t0, 0x2004
    li   t1, 1
    sw   t1, 0(t0)
#else
    li   t0, 0x2000
    li   t1, 0x1111
    sw   t1, 0(t0)
    li   t0, 0x2004
    sw   x0, 0(t0)
#endif
    j    finish

taken:
#ifdef EXPECT_TAKEN
    li   t0, 0x2000
    li   t1, 0x600d
    sw   t1, 0(t0)
    li   t0, 0x2004
    sw   x0, 0(t0)
#else
    li   t0, 0x2000
    li   t1, 0x0bad
    sw   t1, 0(t0)
    li   t0, 0x2004
    li   t1, 1
    sw   t1, 0(t0)
#endif

finish:
    li   t0, 0x2ffc
    li   t1, 0xdeadbeef
    sw   t1, 0(t0)
1:  j    1b
