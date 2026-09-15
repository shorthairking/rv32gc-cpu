/*==============================================================================
 * sim/arch_test/dm_htif.S —— HTIF 控制台写（tohost 窗口）最小复现程序【缺陷定位用】
 *------------------------------------------------------------------------------
 * 项目 : rv32gc-cpu（阶段二 2A）
 * 复位桩 : 由 sim/arch_test/boot_stub.S 提供；本文件提供 rvtest_entry_point。
 * 用法   : ./sim/arch_test/run.sh --directed dm_htif
 *
 * 背景（2026-09-15 实测）：arch-test 用例（I-nop-00 / I-add-00）跑到 sig 版启动码的
 *   第一个 HTIF 控制台字符时，DUT **前端停摆**：AXI 五通道全部空闲
 *   （AR v/r=0/1、AW v/r=0/1、W/R/B 全 0）、提交数冻结、不再发任何取指请求
 *   （Spike 参考模型同一份 ELF 正常跑完 ⇒ 程序本身没问题）。
 *   本程序把"HTIF 控制台写"从 2000+ 行 ACT 启动码里**摘出来**，只保留：
 *     写基线值 → 写 1 个字符（低字=字符，高字=0x01010000）→ 再写第 2 个字符
 *     → 写后续标记值 → 正常终止。
 *   判据（与 Spike 参考签名逐行比对）：
 *     [0] = 0x123  （控制台写之前写的基线）
 *     [1] = 0x456  （第 1 次控制台写之后写）
 *     [2] = 0x789  （第 2 次控制台写之后写）
 *   若 DUT 在第 1 个字符处停摆 ⇒ [1]/[2] 保持 0 且超时 ⇒ 复现成立（本程序即最小用例）。
 *============================================================================*/
    .section .text.init, "ax", @progbits
    .globl rvtest_entry_point
    .p2align 2
rvtest_entry_point:
    la      x31, begin_signature          /* 结果区（10 字）*/

    /* ---- ① 控制台写之前的基线值 ---- */
    li      x5, 0x123
    sw      x5, 0(x31)

    /* ---- ② 第 1 个 HTIF 控制台字符：低字 = 字符，高字 = 0x01010000 ---- */
    la      x2, tohost
    li      x6, 0x41                      /* 'A' */
    sw      x6, 0(x2)
    lui     x7, 0x1010                    /* x7 = 0x01010000（device=1 终端，cmd=1 输出）*/
    sw      x7, 4(x2)

    /* ---- ③ 第 1 个字符之后的标记值 ---- */
    li      x8, 0x456
    sw      x8, 4(x31)

    /* ---- ④ 第 2 个 HTIF 控制台字符 ---- */
    li      x6, 0x42                      /* 'B' */
    sw      x6, 0(x2)
    sw      x7, 4(x2)

    /* ---- ⑤ 第 2 个字符之后的标记值 ---- */
    li      x9, 0x789
    sw      x9, 8(x31)

    /* ---- ⑥ 正常终止：tohost=1（PASS）---- */
    li      x1, 1
1:  sw      x1, 0(x2)
    sw      x0, 4(x2)
    j       1b

    .section .tohost, "aw", @progbits
    .balign 8
    .globl tohost
tohost:   .dword 0
    .balign 8
    .globl fromhost
fromhost: .dword 0

    .section .data, "aw", @progbits
    .balign 8
    .globl begin_signature
begin_signature:
    .skip 40
    .globl end_signature
end_signature:
