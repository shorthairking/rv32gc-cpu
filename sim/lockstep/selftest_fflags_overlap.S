#==============================================================================
# sim/lockstep/selftest_fflags_overlap.S —— E/W fflags 多 owner 重叠探针
#------------------------------------------------------------------------------
# 目的：尝试让 W 级显式 fflags 写与 E 级 FP flags 更新同拍（csrw fflags; nop; fadd）。
# 当前 2A FPU 多拍延迟下，实测未触发同拍重叠，因此本程序运行 PASS；TB 的 taint
# 条件仍保留（同拍 csr_wen_w flags 写 + e_fflags_we ⇒ 提交时 C7/obs_err 失败），
# FIFO 的 taint 位随 shift/pop 由 selftest_fflags_fifo.sv 覆盖。真实 consumer
# 重叠需 Top owner 的真实信号确认，不把本 PASS 当作"重叠已豁免"。
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
    li      t0, 0x6000              # FS=Dirty：避开 FS=1 的 SD 派生缺陷
    csrrs   x0, mstatus, t0
    li      t5, 0x7f800001          # sNaN
    fmv.w.x f1, t5
    li      t6, 0x3f800000
    fmv.w.x f2, t6
    li      a2, 0x13
    csrw    fflags, a2              # W 级显式 fflags 写
    nop
    fadd.s  f7, f1, f2              # sNaN 运算置 NV，E 级完成更快，尝试与 W 同拍
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
