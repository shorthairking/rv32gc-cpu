#==============================================================================
# sim/lockstep/selftest_fsread.S —— mstatus.FS 在 FP 只读指令上的推进探针
#------------------------------------------------------------------------------
# 目的：先真正清 FS mask→置 FS=Initial→独立读回（FS=1/SD=0），再置 Clean→
# 独立读回（FS=2/SD=0），最后测只读 FP 的整数结果。SD 叶已修为 FS==3 才置 SD，故前置读回应与 Spike 同为 0x2000；
# 本 helper 不读只读 FP 后的 mstatus（DUT 保守 Dirty 与 Spike 精确 Clean/Initial
# 的合法映射差异由 selftest_fs_policy.S 单独演示，不作为硬件错/不归一化）。
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
    li      t0, 0x2000              # FS=Initial
    csrrs   x0, mstatus, t0
    li      t5, 0x3f800000
    fmv.w.x f1, t5                  # FP 写：FS→Dirty
    li      t0, 0x6000              # 先真正清 FS mask（0x6000），不能只 OR 0x2000
    csrrc   x0, mstatus, t0
    li      t0, 0x2000              # 再置 FS=Initial
    csrrs   x0, mstatus, t0
    csrr    a2, mstatus             # 独立读回：FS=1、SD=0
    li      t0, 0x6000              # 先清 FS，再置 Clean（csrrs 是 OR，不能直接置 2）
    csrrc   x0, mstatus, t0
    li      t0, 0x4000
    csrrs   x0, mstatus, t0
    csrr    a3, mstatus             # Clean 读回：FS=2、SD=0
    fmv.x.w a0, f1                  # FP 只读：比对整数结果；不在此读回 FS
    fclass.s a1, f1                 # FP 只读：比对分类结果
    # 注意：只读 FP 之后不再 csrr mstatus。DUT 对 FPU 指令保守置 Dirty(3)，
    # Spike 可能保持 Initial(1)；这是合法 FS 脏位策略差异，不是数据错误。
    # 该边界由 selftest_fs_policy.S 单独演示（预期 DIVERGENCE），本 helper
    # 只验证 Initial（a2）/Clean（a3）的 SD=0 读回与 FMV/FCLASS 整数结果。

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
