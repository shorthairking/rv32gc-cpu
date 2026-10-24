#==============================================================================
# sim/lockstep/selftest_warl.S —— 真实 2A CSR post-WARL 落地值探针（自测 helper）
#------------------------------------------------------------------------------
# 目的：验证 TB 的 cva 取自 csr_file wval_final（实际落盘值），不是 mw_csr_wdata
#       原始 operand，并且与 Spike c<num> 的 post-CSR 记录一致：
#       · mtvec 保留 MODE=2 ⇒ 保持旧 MODE、BASE 4B 对齐；
#       · mstatus MPP=2（H，未实现）⇒ WARL 合法化；
#       · pmpcfg0.L=1 后写 pmpaddr0 ⇒ 写被忽略，读回旧值。
# 结束协议同 lock_hello.S；短程序用 --min-commits 10。
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
    # ---- mtvec：先 Direct，再写保留 MODE=2 ----
    li      t0, 0x80000101
    csrrw   x0, mtvec, t0
    li      t1, 0x80000202
    csrrw   x0, mtvec, t1
    csrr    a0, mtvec

    # ---- mstatus MPP=2（未实现 H）→ WARL ----
    li      t2, 0x1000
    csrrw   x0, mstatus, t2
    csrr    a1, mstatus

    # ---- PMP 锁：cfg.L=1 后 pmpaddr0 写必须被忽略 ----
    li      t3, 0x80001000
    csrw    pmpaddr0, t3
    li      t4, 0x8F
    csrw    pmpcfg0, t4
    li      t5, 0x80002000
    csrw    pmpaddr0, t5
    csrr    a2, pmpaddr0

    # ---- 结束协议 ----
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
