#==============================================================================
# sim/lockstep/selftest_pmp.S —— PMP 锁写被忽略时的 CSR post-WARL 探针（helper）
#------------------------------------------------------------------------------
# 目的：pmpcfg0.L=1 后写 pmpaddr0，DUT 的 wval_final 应保持旧值并落盘；与 Spike
#       的 c<num> post-CSR 记录比较，确认 cva 不是原始 operand。
#==============================================================================
    .option norvc
    .section .boot, "ax"
    .globl  _boot
    .align  2
_boot:
    lui     t0, 0x80000
    jalr    x0, 0(t0)

    .section .text, "ax"
    .globl  _start
    .align  2
_start:
    li      t3, 0x80001000
    csrw    pmpaddr0, t3
    li      t4, 0x8F
    csrw    pmpcfg0, t4
    li      t5, 0x80002000
    csrw    pmpaddr0, t5
    csrr    a2, pmpaddr0
    csrr    a3, pmpcfg0

    lui     t1, 0x80002
    li      t2, 0x600D5EED
    sw      t2, 0(t1)
    lui     t3, 0x1FE00
    addi    t3, t3, 480
    li      t4, 0x5A
    sw      t4, 0(t3)

    .globl  lockstep_spin
lockstep_spin:
1:  j       1b
