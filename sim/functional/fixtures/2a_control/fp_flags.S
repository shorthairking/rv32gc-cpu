#==============================================================================
# sim/functional/fixtures/2a_control/fp_flags.S
#   fflags 的**年龄/退休顺序**边界（08-05 附带确证；链接=运行=0x0001_0000）
#------------------------------------------------------------------------------
# 口径（zicsr.adoc:166-184；machine.adoc 的 F 扩展）：fflags 是 FP 指令的
#   sticky-OR；**被杀（未退休）的 FP 指令不得留下 flag**；更老的显式 fflags 写
#   与更年轻在途 FP 指令并存时，最终值 = 写值 | 年轻 flag（不丢 flag）。
# 结果字：
#   0x2000 老写(0x01) | 年轻 fdiv 0/0 的 NV(0x10) ⇒ 必须 0x11（不丢年轻 flag）
#   0x2004 ecall 陷阱拍（紧随其后的 fadd 被 kill_young 作废）时 fflags ⇒ 必须 0
#   0x2008 基本 NV：fdiv 0/0 ⇒ 0x10
#   0x2020 陷阱处理读到的 fflags（留档）
#   0x2FFC DONE
#==============================================================================
    .option norvc
    .section .text
    .globl _start
_start:
    li   t0, 4
1:  addi t0, t0, -1
    bnez t0, 1b
    la   t0, handler
    csrw mtvec, t0
    csrw mie, x0
    li   t0, 0x2000             # mstatus.FS=Initial（否则 FP/FP-CSR 访问合法判为非法）
    csrw mstatus, t0

    # ---- f1：更老显式写 0x01 紧邻更年轻 fdiv（慢 FP ⇒ 写落盘时 fdiv 在 M，NV 在途）----
    li   t0, 0
    fmv.w.x ft0, t0
    fmv.w.x ft1, t0
    li   t0, 0x01
    csrw fflags, t0
    fdiv.s ft2, ft0, ft1        # 0/0 ⇒ NV；慢指令把更老写拖在 M，落盘拍并入年轻 NV
    csrr t1, fflags
    li   t3, 0x2000
    sw   t1, 0(t3)

    # ---- f3：基本 NV ----
    csrw fflags, x0
    fdiv.s ft3, ft0, ft1
    csrr t1, fflags
    li   t3, 0x2008
    sw   t1, 0(t3)

    # ---- f2：ecall 陷阱拍紧随 fadd（sNaN ⇒ NV）——该 fadd 必须被作废，不得留 flag ----
    csrw fflags, x0
    li   t0, 0x7F800001          # sNaN
    fmv.w.x ft0, t0
    li   t0, 0
    fmv.w.x ft1, t0
    ecall                        # 陷阱在 W 拍取；其上一条 FP 指令已退休，其下一条被 kill
    fadd.s ft2, ft0, ft1         # 被 kill_young 作废（陷阱后 mepc=此地址，会重新执行）
    csrr t1, fflags              # 重新执行后（mret 回来）正常置 NV
    li   t3, 0x200C
    sw   t1, 0(t3)

    li   t4, 0x2ffc
    li   t5, 0xdeadbeef
    sw   t5, 0(t4)
2:  j 2b

    .balign 4
handler:
    csrr s2, mcause
    li   s3, 0x2010
    sw   s2, 0(s3)
    csrr s2, mepc
    li   s3, 0x2014
    sw   s2, 0(s3)
    csrr s2, mtval
    li   s3, 0x2018
    sw   s2, 0(s3)
    # 陷阱拍读 fflags：被杀 FP 指令不得留 flag ⇒ 必须 0
    csrr s2, fflags
    li   s3, 0x2004
    sw   s2, 0(s3)
    li   s3, 0x2020
    sw   s2, 0(s3)
    li   s3, 0x201c
    lw   s2, 0(s3)
    addi s2, s2, 1
    sw   s2, 0(s3)
    # 让 ecall 不停在自身：mepc += 4（32 bit ecall）；随后紧邻的 fadd 重新取指执行
    csrr s2, mepc
    addi s2, s2, 4
    csrw mepc, s2
    mret
