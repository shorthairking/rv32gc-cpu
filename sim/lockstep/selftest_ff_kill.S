#==============================================================================
# sim/lockstep/selftest_ff_kill.S —— 私有源 actual-update 变异用 fflags 程序
#------------------------------------------------------------------------------
# 两条连续 fdiv 都置 DZ=8；私有 RTL 对第一条的 fflags 实际更新 disable/flip
# （保留 e_fflags_we 与 RHS），第二条仍可补成 8。逐提交比较必须在第一条红，
# final-state-only 会漏。不是默认回归。
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
    li      t0, 0x6000              # FS=Dirty（避开 SD 前置边界）
    csrrs   x0, mstatus, t0
    li      t5, 0x3f800000
    fmv.w.x f1, t5
    fcvt.s.w f6, x0
    .globl  first_fdiv
first_fdiv:
    fdiv.s  f7, f1, f6              # 首次 flags：DZ=8
    fdiv.s  f12, f1, f6             # 第二次同 flags：仍应写 8
    frflags a1

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
