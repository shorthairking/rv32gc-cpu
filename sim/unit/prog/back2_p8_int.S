/*==============================================================================
 * sim/unit/prog/back2_p8_int.S —— 2B-4 第 4a 段：**核内 CLINT + MTI 中断**程序
 *------------------------------------------------------------------------------
 * 目标：证明 `core_top_2b` 能把**核内 CLINT 的 MTIP** 经 mip/mie/mstatus 判定，
 *       在提交组边界取中断（cause 0x8000_0007）、跳到 mtvec 处理程序、`mret` 返回
 *       被中断指令继续执行。
 *
 * ★ 与 p1..p7 的**根本差异（口径登记，见报告 §B4.4.3）**：
 *   CLINT 的 `mtime` 是**自由计数器**（aclk 每拍 +1），"源拉高 → 取中断"的拍数
 *   依赖微架构时序（流水深度/访存延迟），**Spike 与本核不可能逐条一致**；
 *   且本 SoC 的 CLINT 窗口在 0x1F00_0000（Spike 默认 CLINT 在 0x0200_0000）
 *   ⇒ 本程序**不产生 Spike 黄金轨迹**（生成器按"仅映像"处理，P7_GOLD_N = 0），
 *   判据改由 TB 的 C8' 用"**程序自记录 + 硬编码期望**"给出：
 *     · 中断交付次数 = 1（后端 `irq_mti_w` 监视）
 *     · 陷阱 CSR：mcause = 0x8000_0007（MTI）、mepc = 循环内 PC
 *     · 处理程序自记录：s1（次数）= 1、s2（mcause 异或）= 0x8000_0007
 *     · 主程序观察到 s1≠0 后走 `done`（写 tohost）⇒ 证明 mret 精确返回
 *
 * 中断源：`mtimecmp = mtime + 200` ⇒ 约 200 拍后 MTIP↑（本核 ~200 拍；Spike 侧无意义）
 * 处理程序：记录现场 → 抬高 mtimecmp（0xFFFF_FFFF）+ 清 mie.MTIE 双保险 → mret
 *          **不改 mepc** ⇒ 返回到被中断的那条指令（可重启指令：bne/addi/j）
 * 风格：%pcrel 位置无关；基址无关记录量（与 p7 同口径）
 *==============================================================================*/
    .section .text
    .globl _start
_start:
    /* ---- 0. 陷阱向量 + 记录寄存器清零 ---- */
    la    s0, handler
    csrw  mtvec, s0

    li    s1, 0                     /* 中断交付次数 */
    li    s2, 0                     /* mcause 异或（期望 0x8000_0007） */
    li    s3, 0                     /* mepc 相对 handler 偏移异或 */
    li    s4, 0                     /* 等待循环圈数 */

    /* ---- 1. CLINT：mtimecmp = mtime + 200（低字；高字 0）---- */
    /*   ★ 偏移 0xBFF8/0x4000 超出 lw/sw 的 12 位有符号立即数 ⇒ 用 li 物化**绝对地址**
     *     （RV32GC_CLINT_BASE=0x1F00_0000 + MTIME_OFF 0xBFF8 / MTIMECMP_OFF 0x4000） */
    li    t5, 0x1F00BFF8            /* &mtime */
    lw    t1, 0(t5)                 /* mtime 低字 */
    addi  t1, t1, 200
    li    t6, 0x1F004000            /* &mtimecmp */
    sw    t1, 0(t6)                 /* mtimecmp 低字 */
    li    t5, 0x1F004004            /* &mtimecmpH */
    sw    x0, 0(t5)                 /* mtimecmp 高字 = 0 */

    /* ---- 2. 使能 MTI：mie.MTIE = 1、mstatus.MIE = 1 ---- */
    li    t2, 0x80
    csrw  mie, t2
    csrsi mstatus, 8

    /* ---- 3. 等待中断（可被中断的自旋；bne/addi/j 均可重启）---- */
wait:
    bne   s1, x0, done
    addi  s4, s4, 1
    j     wait

    /* ---- 4. 收尾：自记录搬到 a0..a3，写 tohost ---- */
done:
    mv    a0, s1
    mv    a1, s2
    mv    a2, s3
    mv    a3, s4
1:  auipc x30, %pcrel_hi(tohost)
    addi  x30, x30, %pcrel_lo(1b)
    li    x31, 1
    sw    x31, 0(x30)
    j     .

/*------------------------------------------------------------------------------
 * MTI 中断处理程序（M 模式）
 *   · mepc **不修改** ⇒ mret 返回到被中断的指令（精确中断语义：该指令重新执行）
 *   · 双保险关中断源：mtimecmp ← 0xFFFF_FFFF / mie.MTIE ← 0
 *------------------------------------------------------------------------------*/
    .align 2
handler:
    csrr  t0, mcause              /* 0x8000_0007 = MTI */
    csrr  t1, mepc                /* 被中断指令 PC */
    csrr  t2, mstatus             /* MIE←MPIE 由硬件做（这里只读，顺带留痕） */
    xor   s2, s2, t0
    sub   t1, t1, s0              /* 基址无关（mepc - handler） */
    xor   s3, s3, t1
    addi  s1, s1, 1

    li    t3, 0xFFFFFFFF
    li    t6, 0x1F004000
    sw    t3, 0(t6)               /* mtimecmp 低字 = 全 1 */
    li    t5, 0x1F004004
    sw    t3, 0(t5)               /* mtimecmp 高字 = 全 1 ⇒ MTIP 迟早自清 */
    csrw  mie, x0                 /* MTIE = 0（关源，防重入） */
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
