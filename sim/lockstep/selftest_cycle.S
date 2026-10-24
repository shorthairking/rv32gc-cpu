#==============================================================================
# sim/lockstep/selftest_cycle.S —— 非确定 cycle 读的显式 UNSUPPORTED 探针（helper）
#------------------------------------------------------------------------------
# rdcycle 与 DUT 微架构周期数相关，不能与 Spike 逐条比较；比对器必须显式
# CMP_UNSUPPORTED（不是静默跳过，也不是泛化豁免所有 CSR）。结束协议同默认程序。
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
    rdcycle t0
    addi    t1, x0, 1
    rdtime  t2

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
