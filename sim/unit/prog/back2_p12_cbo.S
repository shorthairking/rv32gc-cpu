/*==============================================================================
 * sim/unit/prog/back2_p12_cbo.S —— 2B-4 第 4b-2a 段：**cbo.* 语义**（仅映像，自记录口径）
 *------------------------------------------------------------------------------
 * ★ 为什么没有 Spike 黄金（口径登记）：Spike（本仓 /opt/riscv/bin/spike）**不支持 Zicbom**
 *   —— 探针实测：即使 `--isa=rv32imac_zicsr_zifencei_zicbom`，`cbo.inval` 仍触发非法指令陷阱
 *   ⇒ cbo 无法逐条黄金比对。判据改由 TB 的 C12' 用"**自记录 + 硬编码期望 + 维护口探针**"：
 *     · 先写 `menvcfg`（CBCFE=1、CBIE=11）⇒ cbo.* 合法（2A `dec_csr.v:222-237` 口径）
 *     · cbo.inval/clean/flush 各自触发对应的 L1D 维护脉冲（TB 计数探针）
 *     · 每次维护后 load 必须仍读到正确数据（0x55667788）
 *     · 全程**无陷阱**（若合法性没放开，第一条 cbo 就会变 cause 2 ⇒ n_trap ≠ 0 当场暴露）
 * 风格：%pcrel 位置无关；`.option norvc`
 *==============================================================================*/
    .option norvc
    .section .text
    .globl _start
_start:
    /* ---- 0. 放开 cbo 门控：menvcfg.CBCFE=1、CBIE=11 ----
     *     menvcfg[6]=CBCFE、menvcfg[5:4]=CBIE ⇒ 0x70 */
    li    t0, 0x00000070
    csrw  menvcfg, t0

    la    s0, darea
    li    t0, 0x55667788
    sw    t0, 0(s0)
    lw    s1, 0(s0)                 /* s1 = 0x55667788 */

    /* ---- 1. cbo.inval（funct3=000）⇒ L1D inval_all ---- */
    cbo.inval (s0)
    lw    s2, 0(s0)                 /* 0x55667788 */

    /* ---- 2. cbo.clean（funct3=001）⇒ L1D clean_all ---- */
    cbo.clean (s0)
    lw    s3, 0(s0)                 /* 0x55667788 */

    /* ---- 3. cbo.flush（funct3=010）⇒ L1D clean_all + inval_all ---- */
    cbo.flush (s0)
    lw    s4, 0(s0)                 /* 0x55667788 */

    mv    a0, s1
    mv    a1, s2
    mv    a2, s3
    mv    a3, s4
1:  auipc x30, %pcrel_hi(tohost)
    addi  x30, x30, %pcrel_lo(1b)
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
