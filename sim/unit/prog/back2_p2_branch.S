/*==============================================================================
 * sim/unit/prog/back2_p2_branch.S —— 2B-2 锁步程序②：分支密集流
 *------------------------------------------------------------------------------
 * 目的：条件分支方向混合（taken/not-taken 交替）+ direct/indirect 跳转 + 二级调用/返回，
 *       覆盖 BRU 判定重定向、检查点恢复与 RAS 压/弹口径。地址同样走 %pcrel ⇒ 可重定位。
 *==============================================================================*/
    .section .text
    .option norvc              /* ★ 见 gen 脚本头注：2A 基线不支持奇 parcel 起 32 bit 指令 */
    .globl _start
_start:
1:  auipc x5, %pcrel_hi(darea)
    addi  x5, x5, %pcrel_lo(1b)
    addi  x2, x5, 0x7f0          /* sp = darea + 0x7F0（栈向下生长；0x800 超 addi 12 bit 立即数范围） */
    li    x6, 0
    li    x7, 8
    li    x9, 0
    li    x8, 0
2:
    andi  x10, x6, 1
    beq   x10, x0, 4f
    addi  x9,  x9, 1
    j     5f
4:
    addi  x9,  x9, 2
5:
    andi  x11, x6, 3
    beq   x11, x0, 6f
    addi  x9,  x9, 3
    j     7f
6:
    addi  x9,  x9, 4
7:
    bne   x11, x0, 8f
    addi  x9,  x9, 5
8:
    jal   x1, sub1
    addi  x6,  x6, 1
    bne   x6,  x7, 2b
    sw    x9, 0(x5)
    sw    x8, 4(x5)
9:  auipc x30, %pcrel_hi(tohost)
    addi  x30, x30, %pcrel_lo(9b)
    li    x31, 1
    sw    x31, 0(x30)
    j     .
sub1:
    addi  x2, x2, -16
    sw    x1, 12(x2)
    addi  x8, x8, 1
    jal   x1, sub2
    lw    x1, 12(x2)
    addi  x2, x2, 16
    ret
sub2:
    addi  x8, x8, 2
    ret
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
