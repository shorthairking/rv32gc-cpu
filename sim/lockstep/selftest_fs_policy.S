#==============================================================================
# sim/lockstep/selftest_fs_policy.S —— FS 脏位策略差异边界演示（预期 DIVERGENCE）
#------------------------------------------------------------------------------
# 本程序把 FS 置 Initial(1) 后做只读 FP，再读回 mstatus。DUT 对 FPU 指令保守
# 置 FS=Dirty(3)/SD=1，Spike 可能保持 Initial(1)/Clean(2)/SD=0；这是**合法实现
# 映射差异**，不是数据错误，也不做归一化。锁步在该整数读值处如实 DIVERGENCE，
# 作为明确域边界记录；SD 叶本身（FS==3 才置 1）已由 fsread 前置读回覆盖。
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
    li      t0, 0x2000
    csrrs   x0, mstatus, t0
    li      t5, 0x3f800000
    fmv.w.x f1, t5
    li      t0, 0x6000
    csrrc   x0, mstatus, t0
    li      t0, 0x2000
    csrrs   x0, mstatus, t0
    csrr    a2, mstatus             # 前置：FS=1、SD=0
    fmv.x.w a0, f1
    fclass.s a1, f1
    csrr    a3, mstatus             # 只读 FP 后：DUT 保守 Dirty vs Spike Initial

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
