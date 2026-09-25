/*==============================================================================
 * sim/unit/prog/back2_p15_priv.S —— 2B-4 第 4b-3 段（2/2）：**S 模式完整链 + PLIC**
 *------------------------------------------------------------------------------
 * ★ **无 Spike 黄金**（口径登记，与 p8/p12/p13 同法）：Spike **不建模 PLIC** ⇒ 含
 *   claim/complete 的整链无法逐条黄金比对。判据由 TB 的 C16' 用"**程序自记录 + 硬编码期望**"给出。
 *
 * 覆盖（按任务书 ①）：
 *   · M 装 `mtvec/stvec/medeleg` + PMP 全放行 + PLIC（priority/enable/threshold）
 *   · `mret` **进 S**（mstatus.MPP=S + mepc=s_entry）
 *   · S 下 `ecall` ⇒ 经 `medeleg[9]` **委托回 S** ⇒ `scause=9`、`sepc`=ecall 的 PC（自记录）
 *   · `sret` 返回（sepc+=4）⇒ 下一条是**非法指令**（`.word 0`）⇒ 无委托 ⇒ **M 处理 cause 2**、
 *     `mtval`=指令字、`mepc`=该指令 PC（自记录）⇒ `mret` 回 S 继续
 *   · **PLIC 外部中断一条链**：TB 在程序运行到等待循环后按阶段驱动 `intrpt[0]`（= mac_int）
 *     ⇒ PLIC 源 5 ⇒ `mip.MEIP` ⇒ M 取中断（cause 11）⇒ 处理程序经
 *     `PLIC_BASE+0x0020_0004` **claim**（读回源号 5，自记录）→ **complete**（写回同一值）
 *   · 收尾：自记录值进写回轨迹 + 写 tohost ⇒ `j .`（TB 以固定拍数收束）
 *
 * 寄存器自记录约定（TB 按写回轨迹硬编码比对）：
 *   x28(t3)=S handler 的 scause(9) / M handler 的 mcause(2 然后 11)
 *   x29(t4)=非法指令的 mtval(0)      x30(t5)=sepc/mepc 现场      x31(t6)=PLIC claim 值(5)
 *   x10(a0)=非法指令后继续的标记(1)  x11(a1)=MEI 后继续的标记(1)  x12(a2)=PLIC complete 回写值
 * 风格：`.option norvc`；绝对地址（无黄金 ⇒ 不涉及基址平移，TB 用"映像内 PC"判据）
 *==============================================================================*/
    .option norvc
    .section .text
    .globl _start
_start:
    /* ---- 0. 陷阱入口：M 用 m_handler / S 用 s_handler ---- */
    la    t0, m_handler
    csrw  mtvec, t0
    la    t0, s_handler
    csrw  stvec, t0

    /* ---- 1. 委托：把 ecall-from-S（cause 9）委托给 S（mideleg 不动 ⇒ MEI 恒进 M）---- */
    li    t0, 0x200                 /* (1<<9) */
    csrw  medeleg, t0

    /* ---- 2. PMP 全放行（S 模式访存/取指需要）---- */
    li    t0, -1
    csrw  0x3b0, t0                 /* pmpaddr0 = 0xFFFF_FFFF（NAPOT 全空间）*/
    li    t0, 0x1F
    csrw  0x3a0, t0                 /* pmpcfg0 = A=NAPOT|X|W|R */

    /* ---- 3. PLIC 初始化（窗口 0x1F10_0000；ctx0 = M）---- */
    li    t0, 0x1F100000
    li    t1, 1
    sw    t1, 0x14(t0)              /* priority[5] = 1（源 5 = mac_int = intrpt[0]）*/
    li    t1, 32                    /* (1<<5) */
    li    t2, 0x1F102000            /* enable[ctx0]（+0x2000 超出 sw 的 12 bit 立即数）*/
    sw    t1, 0(t2)                 /* enable[ctx0] = bit5 */
    li    t2, 0x1F300000
    sw    x0, 0(t2)                 /* threshold[ctx0] = 0 */

    /* ---- 4. 开 M 外部中断（MEIE），**不开 MIE**（进 S 后再由 mret 置 MIE）---- */
    li    t0, 0x800                 /* (1<<11) MEIE */
    csrw  mie, t0

    /* ---- 5. mret 进 S：MPP=01(S)、MPIE=1 ⇒ mret 后 MIE=1、特权级 = S ---- */
    li    t0, 0x880                 /* MPP=01 (bit11) | MPIE (bit7) */
    csrw  mstatus, t0
    la    t0, s_entry
    csrw  mepc, t0
    mret                            /* → S 模式执行 s_entry */

    /* ---- S 模式入口 ---- */
    .align 2
s_entry:
    ecall                           /* ⇒ 委托（medeleg[9]）⇒ S 的 s_handler */
    /*   `sret` 返回到这里（sepc+=4）⇒ 下一条是**非法指令** ⇒ 无委托 ⇒ M 处理 */
    .word 0
    li    a0, 1                     /* 非法指令 trap 后继续的标记 */

    /* ---- 6. 等 PLIC 中断（TB 在固定拍数后拉 intrpt[0]）----
     *   ★ 2A 偏差规避（口径登记，见报告 §B4.32）：2A `trap_ctrl.irq_visible` 的"全局使能"
     *     对**非 M 特权级**统一取 `mstatus.SIE`，而 ISA 规定 **M 级中断在下特权级恒开放**
     *     （`priv < M` 时不受 MIE/SIE 掩蔽）⇒ 在 S 模式等 MEI 必须显式置 SIE=1。
     *     （本核 2B 侧不改 2A；修法登记：`irq_visible` 的全局使能应按 `is_s_irq` 分派
     *       —— M 级恒为 `(priv==M) ? MIE : 1'b1`。） */
    csrsi sstatus, 2                /* sstatus.SIE = 1（见上：2A 偏差规避）*/
    li    s3, 0
wait_irq:
    beq   s3, x0, wait_irq          /* MEI 处理程序把 s3 置 1 ⇒ 跳出 */

    /* ---- 7. 收尾：自记录值进写回轨迹 ---- */
    mv    a3, s3                    /* 中断后继续的标记（= 1）*/
1:  auipc x30, %pcrel_hi(tohost)
    addi  x30, x30, %pcrel_lo(1b)
    li    x31, 1
    sw    x31, 0(x30)
    j     .

    /* ---- M 陷阱处理：cause 2（非法指令）/ cause 11（MEI）---- */
    .align 2
m_handler:
    csrr  t3, mcause
    li    t4, 11
    beq   t3, t4, mei_path
    /* --- cause 2：非法指令 --- */
    csrr  t4, mtval                 /* 期望 0x0000_0000（指令字）*/
    csrr  t5, mepc                  /* 故障指令 PC */
    addi  t5, t5, 4
    csrw  mepc, t5
    mret                            /* 回 S（继续 a0=1 之后）*/

mei_path:
    /* --- cause 11：PLIC 外部中断 —— claim → complete --- */
    li    t0, 0x1F300004            /* claim/complete（ctx0）*/
    lw    t6, 0(t0)                 /* claim（期望 5）*/
    sw    t6, 0(t0)                 /* complete（写回同一值）*/
    mv    a2, t6                    /* 自记录 claim/complete 值 */
    li    s3, 1                     /* 通知 S 的等待循环跳出 */
    li    a1, 1                     /* MEI 后继续的标记 */
    csrr  t5, mepc                  /* 被中断的 PC（S 等待循环内）*/
    mret                            /* 回 S */

    /* ---- S 陷阱处理：委托来的 ecall（cause 9）---- */
    .align 2
s_handler:
    csrr  t3, scause                /* 期望 9 */
    csrr  t5, sepc                  /* ecall 的 PC */
    addi  t5, t5, 4
    csrw  sepc, t5
    sret                            /* 回 ecall 之后（= 非法指令处）*/

    .section .tohost,"aw"
    .align 3
    .globl tohost
tohost:
    .word 0
    .align 3
    .globl fromhost
fromhost:
    .word 0
