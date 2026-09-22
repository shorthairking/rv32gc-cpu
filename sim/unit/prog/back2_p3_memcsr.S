/*==============================================================================
 * sim/unit/prog/back2_p3_memcsr.S —— 2B-2 锁步程序③：访存 + CSR 混合流
 *------------------------------------------------------------------------------
 * 目的：store→load 转发（不同宽度：sw/lw、sb/lbu、sh/lhu）、对齐访存序列、CSR 读改写
 *       （mscratch，按提交序可见）、fence（本里程碑按 no-op 口径）。地址走 %pcrel。
 *==============================================================================*/
    .section .text
    .option norvc              /* ★ 见 gen 脚本头注：2A 基线不支持奇 parcel 起 32 bit 指令 */
    .globl _start
_start:
1:  auipc x5, %pcrel_hi(darea)
    addi  x5, x5, %pcrel_lo(1b)
    csrw  mscratch, x0
    li    x6, 0
    li    x7, 8
2:
    sw    x6,  0(x5)
    lw    x8,  0(x5)
    addi  x8,  x8, 3
    sw    x8,  4(x5)
    lw    x9,  4(x5)
    sb    x9,  8(x5)
    lbu   x10, 8(x5)
    sh    x10, 12(x5)
    lhu   x11, 12(x5)
    csrrw x12, mscratch, x11
    csrrs x13, mscratch, x0
    add   x14, x12, x13
    addi  x6,  x6, 1
    bne   x6,  x7, 2b
    fence
    lw    x15, 4(x5)
    sw    x14, 16(x5)
    sw    x15, 20(x5)
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
