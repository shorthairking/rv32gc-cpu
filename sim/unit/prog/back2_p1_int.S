/*==============================================================================
 * sim/unit/prog/back2_p1_int.S —— 2B-2 锁步程序①：整数运算流（4 条独立依赖链）
 *------------------------------------------------------------------------------
 * 目的：给乱序调度提供高 ILP 的整数指令流，用于证明 IPC > 1.0（乱序真实生效）。
 * 结构：4 个互不相干的累加器链（x8/x9/x10/x11）× 4 条算术/逻辑/移位 + 计数与回边。
 * 可重定位：数据区/tohost 一律用 %pcrel 取址 ⇒ 同一份源码在任意链接基址下指令字节相同
 *           （TB 侧链到 0x1000、Spike 侧链到 0x8000_0000，黄金轨迹按固定偏移重定位）。
 *==============================================================================*/
    .section .text
    .option norvc              /* ★ 见 gen 脚本头注：2A 基线不支持奇 parcel 起 32 bit 指令 */
    .globl _start
_start:
1:  auipc x5, %pcrel_hi(darea)
    addi  x5, x5, %pcrel_lo(1b)
    li    x6, 0
    li    x7, 8
    li    x8, 1
    li    x9, 2
    li    x10, 3
    li    x11, 4
2:
    addi  x8,  x8,  5
    xori  x8,  x8,  0x11
    slli  x8,  x8,  1
    srli  x8,  x8,  1
    addi  x9,  x9,  7
    xori  x9,  x9,  0x33
    slli  x9,  x9,  2
    srli  x9,  x9,  1
    addi  x10, x10, 9
    xori  x10, x10, 0x55
    and   x10, x10, x8
    or    x10, x10, x9
    addi  x11, x11, 11
    xori  x11, x11, 0x77
    add   x11, x11, x10
    slt   x11, x11, x8
    addi  x6,  x6,  1
    bne   x6,  x7,  2b
    add   x12, x8, x9
    add   x13, x10, x11
    sw    x12, 0(x5)
    sw    x13, 4(x5)
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
