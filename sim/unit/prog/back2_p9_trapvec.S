/*==============================================================================
 * sim/unit/prog/back2_p9_trapvec.S —— 2B-4 第 4b 段（第一步）：
 *                          **mtvec 向量模式（MODE=1）语义实测**
 *------------------------------------------------------------------------------
 * 口径（依据 `docs/design/06-csr-privilege.md §3.2`，与 ISA 手册逐字同）：
 *   · MODE=0（Direct）  ：**所有**陷阱 pc ← BASE
 *   · MODE=1（Vectored）：**同步异常** pc ← BASE ；**中断** pc ← BASE + 4×cause
 *   ⇒ 本程序在 MODE=1 下制造**三条同步异常**（ecall 11 / 非法 2 / ebreak 3），
 *     正确实现必须**三次都落 BASE**（不是 BASE+4×cause）。
 *
 * 判据（TB C9'，见报告 §B4.5）：
 *   · mtvec[1:0] = 1（MODE=1 被接受）
 *   · 陷阱 3 次、cause 依次 11/2/3；**三次陷阱 PC 全等于 BASE**（向量化对异常不生效）
 *   · 提交 PC 流与写回寄存器轨迹逐条 = Spike 黄金（含 BASE 槽分发与 mret 返回）
 *
 * 反例防护：槽 1..11 全部塞 `j h_wrong`（标记 0xEE）⇒ 若实现把异常也向量化
 *           （4a 段的缺陷 D4），落点/标记与黄金不同，C1'/C3' 当场分歧。
 *   实测记录（本轮）：修正前 Spike 落 `vbase+0`、本核落 `vbase+44` ⇒ C1' 第 10 条分歧。
 *
 * 布局：`vbase` 按 **256 B 对齐**（2A 口径：Vectored 下 BASE 低 8 位为 0，
 *       便于用 `BASE | (cause<<2)` 合成向量目标，见 06 §11 P-3）。
 * 风格：%pcrel 位置无关；`.option norvc`；累加量全部基址无关（与 p7/p8 同口径）。
 *==============================================================================*/
    .option norvc
    .section .text
    .globl _start
_start:
    /* ---- 0. mtvec = vbase | MODE(1)；累加器清零 ---- */
    la    s0, vbase
    ori   s0, s0, 1                 /* MODE = 1（Vectored） */
    csrw  mtvec, s0

    li    s1, 0                     /* mcause 累加（xor） */
    li    s2, 0                     /* mepc 相对 vbase 累加（add） */
    li    s3, 0                     /* mtval 低 12 位累加（xor） */
    li    s4, 0                     /* 陷阱次数 */
    li    s5, 0                     /* mstatus 掩码累加（xor） */
    li    s7, 0                     /* 槽标记累加（xor：正解恒 0） */

    /* ---- 1. 三条同步异常（MODE=1 下应全部落 BASE）---- */
    ecall                           /* ① cause 11 */
    addi  a0, s4, 0
    .word 0x0000000b                /* ② cause 2（custom-0 未实现 ⇒ 非法） */
    addi  a1, s4, 0
    ebreak                          /* ③ cause 3 */
    addi  a2, s4, 0

    /* ---- 2. 收尾：累加器搬到 a3..a7（写回轨迹可见），写 tohost ---- */
    mv    a3, s1
    mv    a4, s2
    mv    a5, s3
    mv    a6, s5
    xor   a7, s7, s0                /* s7（槽标记，正解=0）^ mtvec */

1:  auipc x30, %pcrel_hi(tohost)
    addi  x30, x30, %pcrel_lo(1b)
    li    x31, 1
    sw    x31, 0(x30)
    j     .

/*------------------------------------------------------------------------------
 * 陷阱入口（Vectored 模式的 BASE，256 B 对齐）
 *   槽 0 = BASE：同步异常应落此处（标记 0x00）
 *   槽 1..11   ：中断槽（cause 1..11）—— 本程序不产生中断，落这里说明实现把
 *               **异常**也向量化了（标记 0xEE ⇒ 与黄金分歧）
 *------------------------------------------------------------------------------*/
    .align 8
vbase:
    li    t5, 0x00                  /* 槽 0：BASE（同步异常的正解落点） */
    j     h_common
    j     h_wrong                   /* 槽 1 */
    j     h_wrong                   /* 槽 2 */
    j     h_wrong                   /* 槽 3 */
    j     h_wrong                   /* 槽 4 */
    j     h_wrong                   /* 槽 5 */
    j     h_wrong                   /* 槽 6 */
    j     h_wrong                   /* 槽 7 */
    j     h_wrong                   /* 槽 8 */
    j     h_wrong                   /* 槽 9 */
    j     h_wrong                   /* 槽 10 */
    j     h_wrong                   /* 槽 11 */

h_wrong:
    li    t5, 0xEE
    j     h_common

/*------------------------------------------------------------------------------
 * 公共处理程序（M 模式）
 *   · 累加量基址无关：mepc 取"相对 vbase 的偏移"、mtval 取低 12 位
 *   · `mepc += 4` ⇒ mret 返回陷入指令的下一条
 *------------------------------------------------------------------------------*/
h_common:
    csrr  t0, mcause
    csrr  t1, mepc
    csrr  t2, mtval
    csrr  t3, mstatus
    li    t4, 0x1888                /* MPP[12:11] | MPIE[7] | MIE[3] */
    and   t3, t3, t4

    addi  t6, s0, -1                /* t6 = vbase（s0 = vbase|1） */
    sub   t1, t1, t6                /* mepc − vbase（基址无关） */
    xor   s1, s1, t0
    add   s2, s2, t1
    slli  t2, t2, 20
    srli  t2, t2, 20                /* mtval 低 12 位 */
    xor   s3, s3, t2
    xor   s5, s5, t3
    xor   s7, s7, t5                /* 槽标记（正解 0x00） */
    addi  s4, s4, 1

    addi  t1, t1, 4                 /* 相对偏移 +4 */
    add   t6, t6, t1                /* 还原绝对 PC = mepc + 4 */
    csrw  mepc, t6
    mret

    .section .tohost,"aw"
    .align 3
    .globl tohost
tohost:
    .word 0
    .align 3
    .globl fromhost
fromhost:
    .word 0
