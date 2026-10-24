#==============================================================================
# sim/lockstep/selftest_mpp.S —— mstatus.MPP WARL 落地值探针（自测 helper）
#------------------------------------------------------------------------------
# 写 MPP=2（H，未实现）与 MPP=3（M）后读回；用于核对 DUT 的 mpp_warl 落盘值
# 与 Spike 的合法化口径是否一致（不一致即真实差异，不用原始 operand 掩盖）。
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
    li      t0, 0x1000              # MPP=2 (H)
    csrrw   x0, mstatus, t0
    csrr    a0, mstatus
    li      t1, 0x1800              # MPP=3 (M)
    csrrw   x0, mstatus, t1
    csrr    a1, mstatus

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
