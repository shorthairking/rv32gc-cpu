/*==============================================================================
 * sim/unit/prog/back2_p17_fld_fsd.S —— 4c(3/3)：**D 访存（fld/fsd 8B 拆两笔）**
 *------------------------------------------------------------------------------
 * 覆盖（对 Spike `--isa=rv32imafdc_zicsr` 逐条黄金比对 + TB 的 C18' 自记录判据）：
 *   ① **8B 对齐往返**：整数造 64 bit 位型 → `fld`（两拍拆笔）→ `fsd`（提交后拆两条 CDQ
 *      项落地）→ 整数 `lw` 两半核对；并含 `fcvt.d.w`→`fsd` 的 D 算术落盘；
 *   ② **非对齐异常**：`fld`/`fsd` 用 `va[2:0]!=0` ⇒ **cause 4 / cause 6**、`mtval` = VA
 *      （自记录 `mtval − darea` 的**偏移**，与链接基址无关）⇒ 与 2A `m_fp8_misalign` 同口径；
 *   ③ **跨 4K 页第二笔**：8B 对齐但页内偏移 0xFF8（第二笔落到下一页）⇒ 本核第二拍按
 *      **VA+4 完整翻译**（母代理裁决；2A 的 `PA+4` 连续物理假设不降级）；
 *   ④ **8B 覆盖转发**：`fsd`（未提交）→ 更年轻的 `sw` 只覆盖高 4 B → `fld` 必须**按字节道
 *      合并**（低半来自 fsd、高半来自更年轻的 sw）。
 *
 * 寄存器约定（★ 避免踩掉基址：**`x6` 的 ABI 名就是 `t1`**，故基址改用 x27）：
 *   x27(s11) = darea 基址（全程不变）    x5/x6/x7 = t0/t1/t2 临时
 *   自记录：x18/x19=①低/高半  x20/x21=②load/store mcause(4/6)  x22=②load mtval−darea(=12)
 *           x23/x24=③低/高半  x25/x26=④低/高半
 *==============================================================================*/
    .section .text
    .option norvc
    .globl _start
_start:
    li    x5, 0x2000                /* mstatus.FS = 01 (Initial) */
    csrs  mstatus, x5
    la    x5, handler
    csrw  mtvec, x5

1:  auipc x27, %pcrel_hi(darea)
    addi  x27, x27, %pcrel_lo(1b)   /* x27 = darea（16 B 对齐，全程不变）*/

    /* ---- ①-a 8B 对齐往返：1.5d = 0x3FF80000_00000000 ---- */
    sw    x0, 8(x27)                /* 低字 = 0 */
    li    x5, 0x3FF80000
    sw    x5, 12(x27)               /* 高字 = 0x3FF80000 */
    fld   f1, 8(x27)                /* 两拍：8(x27) 与 12(x27) */
    fsd   f1, 16(x27)               /* 两笔 CDQ：16(x27) 与 20(x27) */
    lw    x18, 16(x27)              /* 期望 0 */
    lw    x19, 20(x27)              /* 期望 0x3FF80000 */
    bne   x18, x0, fail
    li    x5, 0x3FF80000
    bne   x19, x5, fail

    /* ---- ①-b D 算术落盘：fcvt.d.w(2) ⇒ 2.0d ⇒ fsd 两半 ---- */
    li    x6, 2
    fcvt.d.w f3, x6
    fsd   f3, 24(x27)
    lw    x6, 24(x27)               /* 期望 0 */
    lw    x7, 28(x27)               /* 期望 0x40000000 */
    li    x5, 0x40000000
    bne   x7, x5, fail
    bne   x6, x0, fail

    /* ---- ② 非对齐：fld/fsd 的 va[2:0]!=0 ⇒ cause 4 / 6 ---- */
    fld   f5, 12(x27)               /* 4 字节对齐 ⇒ 非对齐装载异常（cause 4）*/
    fsd   f5, 12(x27)               /* 非对齐存储异常（cause 6）*/
    li    x5, 4
    bne   x20, x5, fail             /* 装载 cause 必须 = 4 */
    li    x5, 6
    bne   x21, x5, fail             /* 存储 cause 必须 = 6 */
    li    x5, 12
    bne   x22, x5, fail             /* mtval − darea 必须 = 12 */

    /* ---- ③ 跨 4K 页：**由 darea 算出** 4K 对齐 + 0xFF8 的地址 ----
     *   不占 4K 映像：`((darea + 0xFFF) & ~0xFFF) + 0xFF8` = 程序窗口内、
     *   映像之后的 DDR3 区（TB 的 clear_mem 已填 0x13）⇒ 可安全写读，
     *   且该 8 B（0xFF8..0x1003）**跨 4K 页**：第二笔必须取出下一页的数据。*/
    la    x6, darea
    li    x5, 0xFFF
    add   x6, x6, x5                /* +0xFFF（addi 立即数只有 12 bit 有符号）*/
    li    x5, -4096
    and   x6, x6, x5                /* x6 = darea 之后第一个 4K 边界 */
    li    x5, 0xFF8
    add   x6, x6, x5                /* x6 = 页内偏移 0xFF8（8B 对齐、跨页）*/
    li    x5, 0x11223344
    sw    x5, 0(x6)                 /* 低字（第 1 页）*/
    li    x5, 0x55667788
    sw    x5, 4(x6)                 /* 高字（第 2 页）*/
    fld   f6, 0(x6)                 /* 第二拍地址 = VA+4 ⇒ 落在下一页 */
    fsd   f6, 32(x27)
    lw    x23, 32(x27)              /* 期望 0x11223344 */
    lw    x24, 36(x27)              /* 期望 0x55667788 */
    li    x5, 0x11223344
    bne   x23, x5, fail
    li    x5, 0x55667788
    bne   x24, x5, fail

    /* ---- ④ 8B 覆盖转发：fsd（未提交）+ 更年轻的 sw 只覆盖高 4 B ---- */
    sw    x0, 40(x27)               /* 低字 = 0 */
    li    x5, 0x40000000
    sw    x5, 44(x27)               /* 高字 = 2.0d */
    fld   f7, 40(x27)
    fsd   f7, 48(x27)               /* 8B store（未提交）*/
    li    x5, 0xDEADBEEF
    sw    x5, 52(x27)               /* 只覆盖高 4 B（更年轻）*/
    fld   f8, 48(x27)               /* 须按字节道合并 */
    fsd   f8, 56(x27)
    lw    x25, 56(x27)              /* 期望 0（低半来自 fsd）*/
    lw    x26, 60(x27)              /* 期望 0xDEADBEEF（高半来自 sw）*/
    bne   x25, x0, fail
    li    x5, 0xDEADBEEF
    bne   x26, x5, fail

    /* ---- 收尾 ---- */
2:  auipc x30, %pcrel_hi(tohost)
    addi  x30, x30, %pcrel_lo(2b)
    li    x31, 1
    sw    x31, 0(x30)
    j     .

fail:
    li    x31, 0xDEAD
    j     .

    /* ---- 陷阱处理：只服务 ②（非对齐）；记录 cause 与 mtval 偏移后跳过该指令 ---- */
    .align 2
handler:
    csrr  t0, mcause
    csrr  t1, mtval
    sub   t1, t1, x27               /* mtval − darea（与基址无关的自记录）*/
    csrr  t2, mepc
    addi  t2, t2, 4
    csrw  mepc, t2
    li    t3, 4
    beq   t0, t3, h_ld
    mv    x21, t0                   /* cause 6 ⇒ 存到 x21 */
    mret
h_ld:
    mv    x20, t0                   /* cause 4 ⇒ 存到 x20 */
    mv    x22, t1                   /* 装载的 mtval 偏移 */
    mret

    .section .data,"aw"
    .align 4
    .globl darea
darea:
    .space 64
    .section .tohost,"aw"
    .align 3
    .globl tohost
tohost:
    .word 0
    .align 3
    .globl fromhost
fromhost:
    .word 0
