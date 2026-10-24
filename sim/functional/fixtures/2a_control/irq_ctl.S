#==============================================================================
# sim/functional/fixtures/2a_control/irq_ctl.S
#   08-05 正控：中断取在**taken/not-taken 控制转移的 W 退休拍**，mepc 必须是
#   "本条之后要执行的下一条 PC"（taken ⇒ 目标；not-taken ⇒ link）。
#------------------------------------------------------------------------------
# 编译期变体（-D 其一）：CTL_JAL / CTL_JALR / CTL_CJ / CTL_BEQ / CTL_BNE / CTL_BEQ_NT
# 运行布局：链接=运行=0x0001_0000（DDR，L1I 可缓存）；XIP 仅 3 条跳板。
# 结果字（TB 读 DDR 模型）：
#   0x2000 目标/正确路径标记 0x600D；错误路径写 0x0BAD
#   0x2008 jal/jalr 的 link（= ctl_pc+4，验证 link 未被 arch-next 污染）
#   0x2010 mcause / 0x2014 mepc / 0x2018 mtval / 0x201C 中断次数
#   0x2FFC DONE 0xDEADBEEF
# 中断来源：外部 intrpt[1] → PLIC 源 1 → MEIP；TB 在 ctl 指令处于 E 的拍拉高引脚
# （PLIC 网关锁存），陷阱恰在该指令 W 退休拍取得。处理器侧只用合法 CSR/MMIO 配置。
# handler 末尾 mret 回 mepc ⇒ 只有 mepc 正确时才会执行目标/后继路径并写 0x600D。
#==============================================================================
    .option norvc
    .section .text
    .globl _start
_start:
    li   t0, 4
1:  addi t0, t0, -1
    bnez t0, 1b

    # ---- PLIC：源 1 优先级 1；ctx0 使能源 1；ctx0 阈值 0 ----
    li   s0, 0x1f100000
    li   t1, 1
    sw   t1, 4(s0)
    li   t3, 0x1f102000
    li   t1, 2                   # enable 位图：bit1 = 源 1（UART 引脚）
    sw   t1, 0(t3)
    li   t3, 0x1f300000
    sw   x0, 0(t3)

    la   t0, handler
    csrw mtvec, t0
    li   t1, 0x800
    csrw mie, t1
    li   t2, 8
    csrs mstatus, t2

    li   t0, 0x2ff8
    li   t1, 1
    sw   t1, 0(t0)              # 配置完成标记

    li   a1, 0
#ifdef CTL_JALR
    la   t2, target             # 目标先备好，ctl_pc 只落在 jalr 本身
#endif
#ifdef CTL_BNE
    li   a1, 1                  # 操作数先备好，ctl_pc 只落在 bne 本身
#endif
#ifdef CTL_BEQ_NT
    li   a1, 1
#endif
    .balign 4
ctl_pc:
#ifdef CTL_JAL
    jal  x1, target
#endif
#ifdef CTL_JALR
    jalr x1, 0(t2)
#endif
#ifdef CTL_CJ
    .option push
    .option rvc
    c.j  target
    c.nop
    .option pop
#endif
#ifdef CTL_BEQ
    beq  a1, x0, target         # a1 == 0 ⇒ taken
#endif
#ifdef CTL_BNE
    bne  a1, x0, target         # taken
#endif
#ifdef CTL_BEQ_NT
    beq  a1, x0, target         # a1 != 0 ⇒ NOT taken
#endif

#ifdef CTL_BEQ_NT
    j    nt_fall
#else
    j    fall
#endif

fall:                           # 错误路径：若 mepc 被写成 fall-through 会到这里
    li   t3, 0x2000
    li   t4, 0xbad
    sw   t4, 0(t3)
    j    finish

nt_fall:                        # not-taken 的正确后继
    li   t3, 0x2000
    li   t4, 0x600d
    sw   t4, 0(t3)
    j    finish

    .balign 2
target:
    li   t3, 0x2000
    li   t4, 0x600d
    sw   t4, 0(t3)
#ifdef CTL_JAL
    li   t3, 0x2008
    sw   x1, 0(t3)
#endif
#ifdef CTL_JALR
    li   t3, 0x2008
    sw   x1, 0(t3)
#endif

finish:
    li   t4, 0x2ffc
    li   t5, 0xdeadbeef
    sw   t5, 0(t4)
2:  j 2b

    .balign 4
handler:
    csrr t0, mcause
    li   t3, 0x2010
    sw   t0, 0(t3)
    csrr t0, mepc
    li   t3, 0x2014
    sw   t0, 0(t3)
    csrr t0, mtval
    li   t3, 0x2018
    sw   t0, 0(t3)
    li   t3, 0x201c
    lw   t0, 0(t3)
    addi t0, t0, 1
    sw   t0, 0(t3)
    # 合法收尾：claim + complete 源（清 pending）并关门（mie=0）
    li   t3, 0x1f302004
    lw   t0, 0(t3)
    li   t3, 0x1f302004
    sw   t0, 0(t3)
    csrw mie, x0
    mret
