/*==============================================================================
 * sim/arch_test/dm_csr_raw.S —— CSR 写后读（RAW）定向微测试【缺陷定位/回归用】
 *------------------------------------------------------------------------------
 * 项目 : rv32gc-cpu（阶段二 2A）
 * 复位桩 : 由 sim/arch_test/boot_stub.S 提供（.boot @ 0x1C00_0000 → 0x8000_0000），
 *          本文件只提供入口 rvtest_entry_point @ 0x8000_0000。
 * 用法   : ./sim/arch_test/run.sh --directed dm_csr_raw
 *------------------------------------------------------------------------------
 * 用途 : arch-test 底座在跑第一个 rv32i 用例时暴露"CSR 写后紧跟读回旧值"的分歧
 *        （ACT 启动码 init_Mtramp 的 `csrw mtvec,t2; csrr a4,mtvec; beq` 自检失败
 *         ⇒ 框架判定 mtvec 不可写 ⇒ 走 abort 路径 ⇒ 后续取指跑到 0）。
 *        本程序把该现象压缩成 5 条独立判据，与 arch-test 框架无关，用于：
 *          ① 证明缺陷在 DUT 侧（不是底座/TB/环境问题）；
 *          ② 记录"写后读最小安全距离"，供修复方定位旁路/停顿逻辑。
 *
 * 判据（结果写入签名的 `begin_signature` 起 40 字节，每个判据 1 字；
 *       `begin_signature`/`end_signature` 符号与 ACT 用法一致，
 *       便于 Spike `+signature=` 与 TB 的签名导出直接复用同一套机制）：
 *   [0] 距离 1：csrw mtvec,x30  后紧跟 csrr 的读回值（期望 0x8000_06c0）
 *   [1] 距离 2：中间 1 条 nop（期望同上）
 *   [2] 距离 3：中间 2 条 nop（期望同上）
 *   [3] CSRRW 读旧值：csrw mtvec,0 后 csrrw x13,mtvec,x30 的 x13（期望 0）
 *   [4] CSRRW 之后距离 1 的回读（期望 0x8000_06c0）
 *   [5] 对照：普通 ALU 写后读（addi 后紧跟使用，期望 1；证明旁路网络本身可用）
 *   [6] 通过计数（4 条 CSR 判据中通过数）
 *   [7] 失败计数
 *   [8] 期望值标记 = 0x8000_06c0
 *   [9] 程序结束标记 = 0xA5A5_1234
 *
 * 运行：见 sim/arch_test/run.sh 的 `--directed` 用法说明（本文件不参与 arch-test 汇总）。
 *============================================================================*/
    .section .text.init, "ax", @progbits
    .globl rvtest_entry_point
    .p2align 2
rvtest_entry_point:
    la      x31, begin_signature     /* x31 = 结果/签名区基址（10 字）*/
    lui     x30, 0x80000
    addi    x30, x30, 0x6c0          /* x30 = 0x8000_06c0（合法 mtvec 值）*/

    /* ---- 判据 1：距离 1 ---- */
    csrw    mtvec, x30
    csrr    x10, mtvec
    sw      x10, 0(x31)

    /* ---- 判据 2：距离 2（1 条 nop）---- */
    csrw    mscratch, x30
    nop
    csrr    x11, mscratch
    sw      x11, 4(x31)

    /* ---- 判据 3：距离 3（2 条 nop）---- */
    csrw    mscratch, x30
    nop
    nop
    csrr    x12, mscratch
    sw      x12, 8(x31)

    /* ---- 判据 4：CSRRW 读旧值（先清零）---- */
    csrw    mtvec, x0
    csrrw   x13, mtvec, x30          /* x13 = 旧值（期望 0）*/
    csrr    x14, mtvec               /* 距离 1 回读（期望 0x8000_06c0）*/
    sw      x13, 12(x31)
    sw      x14, 16(x31)

    /* ---- 判据 5：对照 —— 普通 ALU 写后读 ---- */
    addi    x15, x0, 1
    sw      x15, 20(x31)

    /* ---- 统计 ---- */
    li      x21, 0                   /* 通过计数 */
    li      x24, 4                   /* 判据总数（4 条 CSR 判据）*/
    bne     x10, x30, 1f
    addi    x21, x21, 1
1:  bne     x11, x30, 2f
    addi    x21, x21, 1
2:  bne     x12, x30, 3f
    addi    x21, x21, 1
3:  bne     x14, x30, 4f
    addi    x21, x21, 1
4:
    sub     x22, x24, x21            /* 失败 = 总数 - 通过 */
    sw      x21, 24(x31)
    sw      x22, 28(x31)
    sw      x30, 32(x31)

    lui     x16, 0xA5A51
    addi    x16, x16, 0x234
    sw      x16, 36(x31)             /* 结束标记 */

    /* ---- HTIF 终止：tohost=1（PASS）/ 3（FAIL）⇒ 由结果区判据决定 ---- */
    li      x1, 1
    beqz    x22, 5f
    li      x1, 3
5:
    la      x2, tohost
6:  sw      x1, 0(x2)
    sw      x0, 4(x2)
    j       6b

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
    .skip 40                         /* 10 个 32 bit 字：见文件头判据表 */
    .globl end_signature
end_signature:
