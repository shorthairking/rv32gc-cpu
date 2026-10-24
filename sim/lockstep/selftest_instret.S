#==============================================================================
# sim/lockstep/selftest_instret.S —— 真实 2A instret 可比性探针（自测 helper）
#------------------------------------------------------------------------------
# 目的：验证 DUT 与 Spike 在相同退休序下 `rdinstret` 是否逐条一致；比对器把
#       instret 当普通整数写回比较（不预先豁免）。若本探针 FAIL，说明两者计数
#       口径不同，必须在比对器/文档里逐项说明，而不是泛化豁免所有 counter。
# 结束协议与 lock_hello.S 相同；短程序用 --min-commits 10。
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
    rdinstret t0
    addi    t1, x0, 1
    addi    t2, x0, 2
    addi    t3, x0, 3
    rdinstret t4
    addi    t5, x0, 5
    rdinstret t6
    addi    s0, x0, 7
    addi    s1, x0, 8
    rdinstret s2

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
