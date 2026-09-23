/*==============================================================================
 * sim/unit/prog/back2_p5_mdu.S —— 2B-4 锁步程序⑤：MDU（乘 / 除 / 余）流
 *------------------------------------------------------------------------------
 * 目的：把乱序核的 **MDU 执行 / 写回 / 唤醒**（单部件串行 + busy/done 握手）纳入锁步比对
 *       （2B-2/2B-3 三个程序未使用乘除法）：
 *   · 乘法四种：mul / mulh / mulhsu / mulhu（含负数与无符号解释的组合）；
 *   · 除法四种：div / divu / rem / remu，覆盖两个规范边界：
 *       - **除零**：商 = -1（全 1）、余 = 被除数（divu/remu 同理）；
 *       - **INT_MIN ÷ -1 溢出**：商 = INT_MIN、余 = 0；
 *   · RAW 依赖链：MDU 结果喂给下一条 MDU（唤醒/在途登记通路）+ 外层循环 7 次；
 *   · 结果全部落数据区（C4 存储映像比对）并逐条产生整数写回（C1 写回比对）。
 *
 * 口径：`.option norvc`（2A 不支持奇 parcel 起 32 bit 指令）；不碰 CSR。
 *==============================================================================*/
    .section .text
    .option norvc
    .globl _start
_start:
1:  auipc x6, %pcrel_hi(darea)
    addi  x6, x6, %pcrel_lo(1b)

    li    x7,  7                /* 循环次数 + 除数 */
    li    x8,  -3               /* 负数被除数 */
    li    x9,  0x80000000       /* INT_MIN */
    li    x10, -1
    li    x11, 0                /* 除零 */
    li    x5,  0                /* 循环计数 */

2:
    mul    x12, x7,  x8
    mulh   x13, x7,  x8
    mulhsu x14, x7,  x8
    mulhu  x15, x7,  x8
    div    x16, x8,  x7
    divu   x17, x8,  x7
    rem    x18, x8,  x7
    remu   x19, x8,  x7
    div    x20, x9,  x10        /* 溢出：商 = INT_MIN */
    rem    x21, x9,  x10        /* 溢出：余 = 0 */
    div    x22, x7,  x11        /* 除零：商 = -1 */
    rem    x23, x7,  x11        /* 除零：余 = 7 */
    divu   x24, x7,  x11        /* 除零：商 = 2^32-1 */
    remu   x25, x7,  x11        /* 除零：余 = 7 */
    /* ---- RAW 依赖链：MDU → 加 → MDU → 加 → MDU ---- */
    add    x26, x12, x13
    mul    x27, x26, x14
    add    x28, x27, x16
    divu   x29, x28, x7

    /* ---- 结果落数据区（每轮同址覆盖 ⇒ 也验"提交序排空"的写覆盖语义）---- */
    sw     x12, 0(x6)
    sw     x13, 4(x6)
    sw     x14, 8(x6)
    sw     x15, 12(x6)
    sw     x16, 16(x6)
    sw     x17, 20(x6)
    sw     x18, 24(x6)
    sw     x19, 28(x6)
    sw     x20, 32(x6)
    sw     x21, 36(x6)
    sw     x22, 40(x6)
    sw     x23, 44(x6)
    sw     x24, 48(x6)
    sw     x25, 52(x6)
    sw     x27, 56(x6)
    sw     x29, 60(x6)
    addi   x5, x5, 1
    bne    x5, x7, 2b           /* 7 次 */

    /* ---- 收尾：写 tohost 并自跳转 ---- */
3:  auipc x30, %pcrel_hi(tohost)
    addi  x30, x30, %pcrel_lo(3b)
    li    x31, 1
    sw    x31, 0(x30)
    j     .

    .section .data,"aw"
    .align 3
    .globl darea
darea:
    .word 0
    .section .tohost,"aw"
    .align 3
    .globl tohost
tohost:
    .word 0
    .align 3
    .globl fromhost
fromhost:
    .word 0
