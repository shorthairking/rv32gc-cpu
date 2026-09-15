/*==============================================================================
 * sim/arch_test/dm_smoke.S —— 底座"PASS 通道"自证用最小定向程序（无 CSR 访问）
 *------------------------------------------------------------------------------
 * 项目 : rv32gc-cpu（阶段二 2A）
 * 复位桩 : 由 sim/arch_test/boot_stub.S 提供；本文件提供 rvtest_entry_point。
 * 用法   : ./sim/arch_test/run.sh --directed dm_smoke
 *------------------------------------------------------------------------------
 * 为什么需要它：
 *   本底座交付时 DUT 侧存在"CSR 写后读（距离 1）读到旧值"的 RTL 缺陷（见
 *   sim/arch_test/dm_csr_raw.S），导致**任何 arch-test 用例**都在 ACT 启动自检处失败。
 *   为把"底座自身是否可用"与"DUT 是否有缺陷"这两件事分开证明，本程序只做
 *   **不触碰 CSR** 的整数运算 + 签名区写 + tohost 终止：
 *     · 若它在 DUT 与 Spike 上跑出的签名逐行一致 ⇒ **底座 PASS 通道成立**
 *       （编译 / 参考模型 / DUT 仿真 / 签名导出 / 逐行比对 全链路可用）；
 *     · 与 dm_csr_raw 的失败对照 ⇒ 缺陷范围被钉死在 CSR 写后读旁路，而非底座。
 *
 * 判据（写入 begin_signature 起 10 字；两侧应逐行一致）：
 *   [0]=1+2  [1]=0x12345678-0x00000001  [2]=左移 8  [3]=逻辑右移 4  [4]=按位与
 *   [5]=按位或 [6]=按位异或 [7]=有符号比较结果 [8]=载入回读值 [9]=结束标记
 *============================================================================*/
    .section .text.init, "ax", @progbits
    .globl rvtest_entry_point
    .p2align 2
rvtest_entry_point:
    la      x31, begin_signature          /* 结果区（10 字）*/
    la      x30, scratch_value            /* 待载入的初值 */

    addi    x5, x0, 1
    addi    x6, x0, 2
    add     x7, x5, x6
    sw      x7, 0(x31)                    /* [0] = 3 */

    lui     x8, 0x12345
    addi    x8, x8, 0x678                 /* x8 = 0x12345678 */
    addi    x9, x8, -1
    sw      x9, 4(x31)                    /* [1] */

    slli    x10, x5, 8
    sw      x10, 8(x31)                   /* [2] = 0x100 */

    srli    x11, x8, 4
    sw      x11, 12(x31)                  /* [3] */

    lui     x12, 0xF0F0F
    addi    x12, x12, 0x0F0               /* x12 = 0x0F0F00F0 */
    and     x13, x8, x12
    sw      x13, 16(x31)                  /* [4] */

    or      x14, x8, x12
    sw      x14, 20(x31)                  /* [5] */

    xor     x15, x8, x12
    sw      x15, 24(x31)                  /* [6] */

    slt     x16, x6, x5                   /* 2 < 1 ⇒ 0 */
    sw      x16, 28(x31)                  /* [7] = 0 */

    lw      x17, 0(x30)
    sw      x17, 32(x31)                  /* [8] = scratch_value */

    lui     x18, 0x5A5A5
    addi    x18, x18, 0x5A5
    sw      x18, 36(x31)                  /* [9] = 结束标记 */

    /* ---- HTIF 终止：tohost=1（PASS）---- */
    li      x1, 1
    la      x2, tohost
1:  sw      x1, 0(x2)
    sw      x0, 4(x2)
    j       1b

    .section .data, "aw", @progbits
    .balign 4
scratch_value:
    .word 0xDEADBEEF

    .section .tohost, "aw", @progbits
    .balign 8
    .globl tohost
tohost:   .dword 0
    .balign 8
    .globl fromhost
fromhost: .dword 0

    /* ---- 签名/结果区（符号与 ACT 一致：Spike `+signature=` 与 TB 导出都用它）---- */
    .section .data, "aw", @progbits
    .balign 8
    .globl begin_signature
begin_signature:
    .skip 40
    .globl end_signature
end_signature:
