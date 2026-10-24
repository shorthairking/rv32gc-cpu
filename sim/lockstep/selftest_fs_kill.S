#==============================================================================
# sim/lockstep/selftest_fs_kill.S —— 私有源 actual-update 变异用 FS 程序
#------------------------------------------------------------------------------
# 先置 mstatus.FS=Initial(1)，第一条 FP 写应使 FS→Dirty(3)，第二条 FP 保持。
# 配合私有 RTL 副本：SD 叶按 FS==3 修（模拟 e9），再对“首次 FS 更新”做
# disable/flip（保持 is_fp_instr/mw_is_fp_wr 源），要求逐提交观测 FAIL；
# 第二条仍正常更新，故 final-state-only 检查会漏。不是默认回归。
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
    li      t0, 0x2000              # FS=Initial(1)
    csrrs   x0, mstatus, t0
    li      t5, 0x3f800000
    .globl  first_fp
first_fp:
    fmv.w.x f1, t5                  # 第一条 FP 写：FS 1→3
    li      t6, 0x40000000
    fmv.w.x f2, t6                  # 第二条 FP 写：FS 保持 3
    fadd.s  f3, f1, f2

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
