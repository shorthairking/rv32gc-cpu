/*==============================================================================
 * sim/unit/prog/back2_p6_l1d.S —— 2B-4 第 3 段锁步程序⑥：**D-Cache 逐出**流
 *------------------------------------------------------------------------------
 * 目的：让 L1D 产生**真实脏行写回**（AXI 写通道流量），并验证 store 数据经
 *       L1D 写回后与 Spike 黄金一致：
 *   · 以 4 KB 步进向**同一组**（同一 set index）写入 5 条不同 tag 的行
 *     ⇒ 4 路组相联必然逐出 1 条**脏**行 ⇒ `l1d.wb_req` ⇒ AXI AW/W/B 写突发；
 *   · 每条行内写满 8 个字（32 B），确保整行脏；
 *   · 再回到最早那条地址读回（可能再次缺失 ⇒ 行填充 + 命中），验证数据往返；
 *   · 结果写 tohost 收尾。
 * 口径：`.option norvc`；只用基址 + 立即数（无 C 扩展）。
 *==============================================================================*/
    .section .text
    .option norvc
    .globl _start
_start:
1:  auipc x5, %pcrel_hi(darea)
    addi  x5, x5, %pcrel_lo(1b)      /* x5 = darea（4 KB 对齐点附近） */

    /* ---- 5 条同行（同 set）不同 tag 的写：每行 8 字 ---- */
    li    x7, 0                      /* line 计数 */
    li    x8, 5
2:
    slli  x9, x7, 12                 /* 4 KB 步进 ⇒ index 相同、tag 不同 */
    add   x10, x5, x9
    li    x11, 0                     /* 行内字计数 */
    li    x12, 8
3:
    slli  x13, x7, 4
    add   x13, x13, x11              /* 唯一数据 = line*16 + word */
    addi  x13, x13, 0x100
    slli  x14, x11, 2
    add   x15, x10, x14
    sw    x13, 0(x15)
    addi  x11, x11, 1
    bne   x11, x12, 3b
    addi  x7, x7, 1
    bne   x7, x8, 2b

    /* ---- 读回第 0 行的第 0 字（跨逐出后再次取行）---- */
    lw    x16, 0(x5)
    addi  x16, x16, 1
    sw    x16, 0(x5)                 /* 再写一次（脏）*/

    /* ---- 再写第 6 条同行地址 ⇒ 再逐出一条 ---- */
    slli  x9, x8, 12
    add   x10, x5, x9
    li    x13, 0x55
    sw    x13, 0(x10)

    /* ---- 收尾 ---- */
4:  auipc x30, %pcrel_hi(tohost)
    addi  x30, x30, %pcrel_lo(4b)
    li    x31, 1
    sw    x31, 0(x30)
    j     .

    .section .data,"aw"
    .align 12
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
