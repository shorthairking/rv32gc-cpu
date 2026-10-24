#==============================================================================
# sim/lockstep/selftest_fp.S —— 真实 2A FP/FS 采样冒烟（自测 helper，不是产品程序）
#------------------------------------------------------------------------------
# 目的：用**真实 DUT/Spike**（不是 parser fixture）确认 v2 trace 的 FP64 / fflags /
#       fcsr / fsd 两相 store 字段确实来自 DUT 采样，而不是只由 parser 自洽生成。
# 口径：与 prog/lock_hello.S 相同的结束协议（magic → UART 结束铃 → lockstep_spin）；
#       程序很短，用 `run.sh --prog sim/lockstep/selftest_fp.S --march rv32imafdc_zicsr
#       --min-commits 10` 跑。它不替代默认 lock_hello（N>=60 的正式入口）。
#       FP 使能：M 模式写 mstatus.FS=Initial，随后 FP 写使 FS=Dirty（Spike 同口径）。
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
    # ---- 使能 FP（mstatus.FS=Initial；新 SD 叶已修 FS==3 才置 SD）----
    li      t0, 0x2000
    csrrs   x0, mstatus, t0

    # ---- S：fadd + 两次同 flags 的 fdiv（sticky DZ）----
    li      t5, 0x3f800000          # 1.0f
    fmv.w.x f1, t5
    li      t6, 0x40000000          # 2.0f
    fmv.w.x f2, t6
    fadd.s  f3, f1, f2              # 3.0f
    fcvt.s.w f6, x0                 # f6 = NaN-boxed +0.0（S 操作数必须 boxed）
    fdiv.s  f7, f1, f6              # 1/0 → +inf, DZ=1
    fdiv.s  f12, f1, f6             # 重复 sticky：Spike 仍记 c1_fflags=8
    frflags a1

    # ---- D：fld/fadd.d/fsd/fld（64 位 FP 写回 + fsd 两相 store）----
    lla     t0, d_one
    fld     f8, 0(t0)
    fld     f9, 8(t0)
    fadd.d  f10, f8, f9             # 3.0
    fsd     f10, 24(t0)
    fld     f11, 24(t0)

    # ---- FP load/store（fsw/flw，NaN-box 读回）----
    fsw     f3, 16(t0)
    flw     f5, 16(t0)

    # ---- 显式 fcsr / fflags 写（post-WARL 落地值 vs Spike c1/c2）----
    li      a4, 5
    csrrw   a5, fcsr, a4
    csrr    a6, fcsr
    li      a2, 0x13
    csrrw   a3, fflags, a2
    csrr    a7, fflags

    # ---- 结束协议 ----
    lui     t1, 0x80002             # 0x8000_2000
    li      t2, 0x600D5EED
    sw      t2, 0(t1)
    lui     t3, 0x1FE00
    addi    t3, t3, 480             # 0x1FE0_01E0
    li      t4, 0x5A
    sw      t4, 0(t3)

    .globl  lockstep_spin
lockstep_spin:
1:  j       1b

    .align  3
d_one:
    .double 1.0
d_two:
    .double 2.0
    .space  64
