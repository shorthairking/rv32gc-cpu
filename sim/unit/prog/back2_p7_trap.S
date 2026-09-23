/*==============================================================================
 * sim/unit/prog/back2_p7_trap.S —— 2B-4 第 4a 段：**特权/陷阱路径**锁步程序
 *------------------------------------------------------------------------------
 * 目标：让 `core_top_2b` 真正走完「异常 → mtvec → 处理程序 → mret → 返回」，
 *       并把**每条异常指令现场**（mcause / mepc / mtval / mstatus[掩码] /
 *       mepc 写后读）以**累加器**形式落在通用寄存器写回轨迹里
 *       ⇒ TB 的 C3'（写回寄存器 = Spike 黄金）逐条比中，任何口径错都当场暴露。
 *
 * 三类陷阱（OoO 后端在 **ROB 头**精确抛出，提交点特权动作）：
 *   ① ecall  ：cause = 11（M 模式），mepc = ecall PC，mtval = 0
 *   ② 非法指令（.word 0x0000000b，custom-0 未实现）：cause = 2，
 *              mtval = **指令编码**（Spike 实测口径，见报告 §B4.4.2）
 *   ③ ebreak ：cause = 3，mtval = **ebreak 的 PC**（Spike 实测口径）
 *
 * 处理程序（M 模式、direct mtvec）：
 *   · 现场累加：s1 ^= mcause、s2 += mepc、s3 ^= mtval、s5 ^= mstatus&0x1888、
 *     s6 ^= (mepc 写回后再读)
 *   · `mepc += 4` 后 mret（跳过陷阱指令；返回点由程序显式给出，
 *     不含任何时间相关量 ⇒ 与 Spike 逐条可比）
 *   · s0..s6 全为 callee-saved 且入口显式清零 ⇒ 与 Spike 的寄存器初值口径无关
 *
 * 风格：%pcrel 位置无关（TB 分基址装载，黄金 PC 整体平移 gold_delta）
 *==============================================================================*/
    .section .text
    .globl _start
_start:
    /* ---- 0. 陷阱向量 + 累加器清零 ---- */
    la    s0, handler
    csrw  mtvec, s0                 /* mtvec = handler（MODE=0 直接） */

    li    s1, 0                     /* mcause 累加（xor） */
    li    s2, 0                     /* mepc   累加（add） */
    li    s3, 0                     /* mtval  累加（xor） */
    li    s4, 0                     /* 陷阱次数 */
    li    s5, 0                     /* mstatus[12:11,7,3] 累加（xor） */
    li    s6, 0                     /* mepc 写后读累加（xor） */
    li    s7, 0

    /* ---- 1. ecall（cause 11）---- */
    ecall
    addi  a0, s7, 1                 /* 返回点：a0 = 1 */

    /* ---- 2. 非法指令（cause 2）---- */
    .word 0x0000000b
    addi  a1, s7, 2                 /* 返回点：a1 = 2 */

    /* ---- 3. ebreak（cause 3）---- */
    ebreak
    addi  a2, s7, 3                 /* 返回点：a2 = 3 */

    /* ---- 4. 收尾：把累加器搬进 a3..a6（轨迹可见），并写 tohost ---- */
    mv    a3, s1
    mv    a4, s2
    mv    a5, s3
    mv    a6, s4
    xor   a7, s5, s6

1:  auipc x30, %pcrel_hi(tohost)
    addi  x30, x30, %pcrel_lo(1b)
    li    x31, 1
    sw    x31, 0(x30)
    j     .

/*------------------------------------------------------------------------------
 * 陷阱处理程序（M 模式）
 *   · 只用 t0..t6 + s 累加器（s0 是 mtvec 用的 handler 地址，不再改写）
 *   · 结束时 `mepc += 4` ⇒ 返回陷入指令的**下一条**
 *------------------------------------------------------------------------------*/
    .align 2
handler:
    csrr  t0, mcause
    csrr  t1, mepc
    csrr  t2, mtval
    csrr  t3, mstatus
    li    t4, 0x1888                /* MPP[12:11] | MPIE[7] | MIE[3] */
    and   t3, t3, t4

    /*   ★ 累加量一律先化成**基址无关**量：本核装载基址 = 黄金基址 + gold_delta
     *     （TB 分基址装 4 个程序），绝对 PC 类量累加后**不等于** 黄金+gold_delta，
     *     故 mepc 取"相对 handler 的偏移"、mtval 取低 12 位（PC/0/指令编码均可比）。 */
    sub   t1, t1, s0                /* mepc - handler（基址无关） */
    slli  t2, t2, 20                /* mtval 取低 12 位（0 / 指令编码 / 断点 PC 低 12 位） */
    srli  t2, t2, 20

    xor   s1, s1, t0                /* 现场累加（写回轨迹 ⇒ 与 Spike 逐条比） */
    add   s2, s2, t1
    xor   s3, s3, t2
    xor   s5, s5, t3
    addi  s4, s4, 1

    addi  t1, t1, 4                 /* 相对偏移 +4 */
    add   t6, s0, t1                /* 还原绝对 PC = mepc + 4 */
    csrw  mepc, t6
    csrr  t5, mepc                  /* 写后读：验证提交点 CSR 写路径 */
    sub   t5, t5, s0                /* 同样化基址无关 */
    xor   s6, s6, t5
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
