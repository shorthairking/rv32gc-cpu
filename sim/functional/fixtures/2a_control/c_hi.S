#==============================================================================
# sim/functional/fixtures/2a_control/c_hi.S
#   IALIGN=16 合法 C 流取指矩阵（08-05/10-22 fetch_unit 高半起始修复的正控）
#------------------------------------------------------------------------------
# 编译期变体（-D 其一）：HH_JALR16 / HH_32X / HH_PAGETAIL / HH_CANCEL / HH_FAULT
# 规范：intro.adoc:443-582 / rv32.adoc:528-639 —— C 扩展把对齐放宽到 16 bit，
#   16/32 bit 指令都可从任意 16 bit 边界开始；IALIGN=16 无 misaligned。
# 结果字（TB 读 DDR 模型）：
#   0x2000 主标记：正确路径 0x600D；错路 0x0BAD
#   0x2010/0x2014/0x2018/0x201C（仅 HH_FAULT）：mcause/mepc/mtval/陷阱次数
#   0x2FFC DONE
# 链接=运行=0x0001_0000；XIP 仅 3 条跳板（TB 预置）。
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
    li   t4, 0x600d

#ifdef HH_JALR16
    # jalr 重定向到 2 mod 4 的**真 16 bit** 指令（c.j），再由它跳回正常路径
    la   t0, hi16
    jalr x0, 0(t0)
    j    bad
#endif

#ifdef HH_32X
    # jalr 重定向到 2 mod 4 的**32 bit** 指令：其第二 parcel 落在下一 4 B 字
    # （跨字拼接），随后 C16/32 交替 + 32 bit 指令混排
    la   t0, cross
    jalr x0, 0(t0)
    j    bad
#endif


#ifdef HH_HAZ
    # 高半 C 流里的三类"load→依赖用法"危险对（功能正控；若旧 latent 门控在
    # 高半新路径上可达，这里会直接给出错值）：
    #   ① lw(2mod4 跨字) → c.bnez 直接依赖（压缩分支）
    #   ② lw → mul 直接依赖（MDU）
    #   ③ flw(2mod4 跨字) → fadd.s 直接依赖（FP）
    li   t0, 0x2000
    csrw mstatus, t0            # FS=Initial（FP 合法）
    li   s0, 0x3000             # 长延迟 DDR（未命中 L1D ⇒ 真实 load 停顿）
    li   t1, 7
    sw   t1, 0(s0)
    li   s1, 0x3004
    li   t1, 0x3f800000         # 1.0f
    sw   t1, 0(s1)
    la   t0, haz
    jalr x0, 0(t0)
    j    bad
    .balign 32
haz:
    .option push
    .option rvc
    c.nop                       # 抬到 2 mod 4
    .option pop
    lw   s1, 0(s0)              # 2mod4 32bit 跨字 load（s0=0x3000）
    .option push
    .option rvc
    c.bnez s1, 1f               # 紧随其后的压缩分支，直接依赖 load 结果
    .option pop
    j    bad
1:  li   t3, 0x2004
    li   t4, 0x1111
    sw   t4, 0(t3)              # ① 分支取到
    .option push
    .option rvc
    c.nop                       # 2 mod 4
    .option pop
    lw   s1, 0(s0)              # 2mod4 跨字 load
    mul  t3, s1, s1             # ② 紧随其后的 MDU 直接依赖
    li   t4, 0x2008
    sw   t3, 0(t4)
    .option push
    .option rvc
    c.nop                       # 2 mod 4
    .option pop
    flw  ft0, 4(s0)             # 2mod4 跨字 FP load（0x3004）
    fadd.s ft1, ft0, ft0        # ③ 紧随其后的 FP 直接依赖
    li   t4, 0x200c
    fsw  ft1, 0(t4)
    j    ok
#endif

#ifdef HH_PAGETAIL
    # 重定向到 4 KiB 页尾的 2 mod 4 32 bit 指令 ⇒ 第二 parcel 落在**下一页**首个字
    la   t0, ptail
    jalr x0, 0(t0)
    j    bad
#endif

#ifdef HH_CANCEL
    # 外中断在"高半 32 bit 首 parcel 在途（hi32_q=1）"时到达：
    #   TB 观测 hi32_q 后拉 intrpt[1]（PLIC 锁存）⇒ 若此时有退休边界即取中断，
    #   重定向必须**清掉在途首 parcel**；handler mret 回 mepc 后同一取指流必须
    #   能重新拼出原指令（绝不把 stale parcel 当指令）。
    li   s0, 0x1f100000
    li   t1, 1
    sw   t1, 4(s0)
    li   t3, 0x1f102000
    li   t1, 2
    sw   t1, 0(t3)
    li   t3, 0x1f300000
    sw   x0, 0(t3)
    la   t0, handler
    csrw mtvec, t0
    li   t1, 0x800
    csrw mie, t1
    li   t2, 8
    csrs mstatus, t2
    la   t0, hh_start
    jalr x0, 0(t0)
    j    bad
#endif

#ifdef HH_FAULT
    # PMP：entry0（低号优先）= 第二 parcel 所在 4 B 字，NA4 无 X；
    #      entry1 = 整个 4 KiB 页 NAPOT，RWX。
    # 然后 mret 进 S 模式，jalr 到 2 mod 4 的 32 bit 指令 ⇒ 第二 parcel 取指被拒
    # ⇒ instruction access fault（cause 1），mtval = 故障 parcel 的 VA、mepc = 指令起始 VA。
    la   t0, fault_insn
    addi t0, t0, 2
    srli t1, t0, 2              # (A+4)>>2
    csrw pmpaddr0, t1
    li   t1, 0x000001FF
    la   t2, fault_insn
    srli t2, t2, 12
    slli t2, t2, 12             # 页基址
    srli t2, t2, 2
    or   t2, t2, t1             # NAPOT 4 KiB：9 个尾 1
    csrw pmpaddr1, t2
    li   t1, 0x00001F10         # cfg0: entry0=0x10(NA4,no X) | entry1=0x1F(NAPOT,RWX)
    csrw pmpcfg0, t1
    li   t1, 0x0800             # MPP=S, MIE=0, MPIE=0
    csrw mstatus, t1
    la   t0, s_entry
    csrw mepc, t0
    mret
    j    bad
#endif

bad:
    li   t3, 0x2000
    li   t4, 0xbad
    sw   t4, 0(t3)
    j    finish

ok:
    li   t3, 0x2000
    li   t4, 0x600d
    sw   t4, 0(t3)
    j    finish

finish:
    li   t4, 0x2ffc
    li   t5, 0xdeadbeef
    sw   t5, 0(t4)
2:  j 2b

#ifdef HH_JALR16
    .balign 4
    .option push
    .option rvc
    c.nop                       # 2 mod 4
    .option pop
hi16:
    .option push
    .option rvc
    c.j  hi16_ok                # 2 mod 4 上的 16 bit 指令
    c.nop
    .option pop
    j    bad
    .balign 2
hi16_ok:
    j    ok
#endif

#ifdef HH_32X
    .balign 4
    .option push
    .option rvc
    c.nop                       # 抬到 2 mod 4
    .option pop
cross:
    lui  t3, 0x2                # 32 bit，起始 2 mod 4 ⇒ 第二 parcel 在下一字
    .option push
    .option rvc
    c.addi t4, 0                # 紧随其后的 16 bit（C16/32 交替，值不变）
    .option pop
    addi t3, t3, 0              # 32 bit（低半起始）
    sw   t4, 0(t3)              # 0x2000 <- 0x600D
    j    ok
#endif



#ifdef HH_PAGETAIL
    # 页尾：页基址 + 0xFFE = 2 mod 4；第二 parcel 在下一页首个字
    .balign 4096
    .space 4094
ptail:
    lui  t3, 0x2                # 32 bit 跨页边界
    sw   t4, 0(t3)
    j    ok
#endif

#ifdef HH_CANCEL
    .balign 32
hh_start:                       # 32 B 行首（低半起始，逐条执行填充流水）
    .rept 7
    nop
    .endr
    .option push
    .option rvc
    c.nop                       # 抬到行尾前 2 B（= 2 mod 4）
    .option pop
hh_insn:                        # 首 parcel 在行尾高半 ⇒ 第二 parcel 落在**下一行**
    lui  t3, 0x2                # 跨字 32 bit；第二字取指被 TB 延迟
    sw   t4, 0(t3)              # 0x2000 <- 0x600D
    j    ok
#endif

#ifdef HH_FAULT
    .balign 4
s_entry:
    la   t0, fault_insn
    jalr x0, 0(t0)              # S 模式跳到 2 mod 4 的 32 bit 指令
    j    bad
    .balign 4
    .option push
    .option rvc
    c.nop                       # 抬到 2 mod 4
    .option pop
fault_insn:
    lui  t3, 0x2                # 首 parcel 允许、第二 parcel 被 PMP 拒 ⇒ AF
    sw   t3, 0(x0)
    j    ok
#endif

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
    li   s3, 0x201c
    lw   s2, 0(s3)
    addi s2, s2, 1
    sw   s2, 0(s3)
    li   s3, 0x1f302004
    lw   s2, 0(s3)
    li   s3, 0x1f302004
    sw   s2, 0(s3)
    csrw mie, x0
#ifdef HH_FAULT
    j    finish
#else
    mret
#endif
