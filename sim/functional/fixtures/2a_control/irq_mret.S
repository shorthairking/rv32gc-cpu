#==============================================================================
# sim/functional/fixtures/2a_control/irq_mret.S
#   08-05 正控：中断取在 **mret 的 W 退休拍** 时，mepc 必须是 mret 的返回目标
#   （= mepc 值），不是 mret+4；且 mret 必须能真正回到半字对齐的 C 指令流。
#------------------------------------------------------------------------------
# 编译期变体：
#   MRET_HI   ：返回目标放在 2 mod 4 的“高半”地址
#   MRET_MIE1 ：mstatus = MIE=1、MPIE=1、MPP=M（无歧义合法 mode）——同一 mret 退休/架构
#               下一边界上外部中断仍 eligible 时，落地 mstatus 必须 MIE=0/MPIE=1/MPP=M；
#               同时用只读层次观测同拍 xret 帧（不按测试猜顺序）。
# 运行布局：链接=运行=0x0001_0000；XIP 仅 3 条跳板。
# 结果字：
#   0x2004 C 流可达标记：先 mret 进 C 流（c.j）后写 0x600D
#   0x2008 若 mret 退休拍 EPC 错成 mret+4 会走到的错误路径（写 0x0BAD）
#   0x2010 mcause / 0x2014 mepc（必须 == ret_target）/ 0x2018 mtval / 0x201C 次数
#   0x2FFC DONE
# 关键合法软件设置：mstatus.MIE=1 且 MPIE=0、MPP=M ⇒ mret 后 MIE=0，
#   陷阱入口不会因“xret 与 trap 同拍”而残留 MIE=1（该组合是既有 priv_ctrl 边界，
#   不在本包修复范围；本用例只判 EPC/返回目标，不需要掩盖它）。
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

    #--------------------------------------------------------------------------
    # 步骤 1：mret 回到半字对齐 C 流（证明“返回目标可达 + c.j 真实取指”）
    #--------------------------------------------------------------------------
    la   t0, c_entry
    csrw mepc, t0
    li   t0, 0x1800             # MPP=M(11), MIE=0, MPIE=0
    csrw mstatus, t0
    csrw mie, x0
    mret                        # 期望跳到 c_entry（半字对齐）

    # 错路（mret 没回 c_entry）
    li   t3, 0x2004
    li   t4, 0xbad
    sw   t4, 0(t3)
    j    finish

    .balign 4
#ifdef MRET_HI
    .option push
    .option rvc
    c.nop                       # 让 c_entry 落在 2 mod 4（32 bit 字的“高半”）
    .option pop
#endif
c_entry:
    .option push
    .option rvc
    c.j  c_ok
    c.nop
    .option pop
    li   t3, 0x2004             # c.j 未生效（错路）
    li   t4, 0xbad
    sw   t4, 0(t3)
    j    finish

    .balign 2
c_ok:
    li   t3, 0x2004
    li   t4, 0x600d
    sw   t4, 0(t3)              # C 流可达 ✓

    #--------------------------------------------------------------------------
    # 步骤 2：mret 退休拍取外部中断 ⇒ mepc 必须 == ret_target
    #--------------------------------------------------------------------------
    la   t0, ret_target
    csrw mepc, t0
#ifdef MRET_MIE1
    li   t0, 0x1888            # MPP=M(11), MPIE=1, MIE=1（无歧义合法 mode）
#else
    li   t0, 0x1808            # MPP=M(11), MPIE=0, MIE=1
#endif
    csrw mstatus, t0
    li   t0, 0x800
    csrw mie, t0
    li   t0, 0x2ff8
    li   t1, 1
    sw   t1, 0(t0)              # 配置完成标记

    .balign 4
mret_pc:
    mret                        # TB 在本条处于 E 的拍拉高外部中断

    # 错路：EPC 若错成 mret_pc+4 就会被返回/继续到这里
    li   t3, 0x2008
    li   t4, 0xbad
    sw   t4, 0(t3)
    j    finish

    .balign 2
#ifdef MRET_HI
    .option push
    .option rvc
    c.nop                       # 返回目标也放高半（2 mod 4）
    .option pop
#endif
ret_target:
    li   t3, 0x2008
    li   t4, 0x600d
    sw   t4, 0(t3)
    # 资格语义复核（无陷阱路径）：mepc 必须仍是返回目标、mstatus 必须是 xret 落地值
    csrr t0, mepc
    li   t3, 0x2024
    sw   t0, 0(t3)
    csrr t0, mstatus
    li   t3, 0x2028
    sw   t0, 0(t3)
    j    finish

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
    csrr t0, mstatus           # 落盘后的实际 mstatus（软件独立观测）
    li   t3, 0x2020
    sw   t0, 0(t3)
    li   t3, 0x1f302004
    lw   t0, 0(t3)
    li   t3, 0x1f302004
    sw   t0, 0(t3)
    csrw mie, x0
    j    finish                 # 不返回：判定用存储的 mepc
