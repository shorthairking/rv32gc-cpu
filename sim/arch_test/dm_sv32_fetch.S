/*==============================================================================
 * sim/arch_test/dm_sv32_fetch.S —— 取指侧 Sv32 翻译的**定向直证**程序
 *------------------------------------------------------------------------------
 * 项目 : rv32gc-cpu（阶段二 2A；sfence.vma + 取指侧 Sv32 翻译解锁）
 * 复位桩 : sim/arch_test/boot_stub.S（提供 .boot 复位桩）；本文件提供 rvtest_entry_point。
 * 用法   : ./sim/arch_test/run.sh --directed dm_sv32_fetch
 *
 * 【它证什么（为什么是本任务验收③"取指翻译真实生效"的直证）】
 *   把**代码页**映射到**非恒等**虚拟地址：
 *       VA 0x4000_0000 + off  ⇒  PA 0x8000_0000 + off     （4 MiB 超级页）
 *   然后 mret 进 S 模式、PC = VA 0x4000_00xx，并在那里取指执行、用 VA 访存。
 *   ⇒ 若取指侧翻译**没生效**（PC 当物理地址用），取指会打到 PA 0x4000_00xx ——
 *     该区间不在 DUT RAM 内（RAM=[0x8000_0000,0x8010_0000)）⇒ 取指通路 DECERR
 *     ⇒ cause 1 陷入/签名不符 ⇒ 本程序必 FAIL。
 *   ⇒ 反之，本程序与 Spike 逐行一致 ⇒ 取指确实按 **翻译后 PA** 取指。
 *   同时覆盖：sfence.vma 译码与"写 satp 后冲刷"（本程序在 satp 写后执行 sfence.vma，
 *   且此时 TLB 里没有任何条目 ⇒ 冲刷路径被走到但不依赖旧条目）、
 *   S 模式下的数据 VA→PA 翻译、ecall(S→M) 的 cause 口径。
 *
 * 【签名（begin_signature 起 4 字，两侧应逐行一致）】
 *   [0]=0x5A5A1234（S 模式经 VA 存的常量）
 *   [1]=0x5A5A1234（S 模式经 VA 回读的值）
 *   [2]=0x5A5A1345（S 模式取指执行的 ALU 结果）
 *   [3]=0x00000009（ecall from S-mode 的 mcause）
 *============================================================================*/
    .section .text.init, "ax", @progbits
    .globl rvtest_entry_point
    .p2align 2
rvtest_entry_point:
    /*------------------------------------------------------------------
     * 1. 把"签名区/入口"的**偏移**换算成 VA（先算好，S 模式里直接用）
     *    x30 = 链接基址（PA）、x29 = 0x4000_0000、x31 = 签名区 VA、x28 = s_entry VA
     *----------------------------------------------------------------*/
    la      x30, rvtest_entry_point
    la      x31, begin_signature
    sub     x31, x31, x30                 /* 签名区相对入口的偏移 */
    la      x28, s_entry
    sub     x28, x28, x30                 /* s_entry 相对入口的偏移 */
    li      x29, 0x40000000
    add     x31, x31, x29                 /* x31 = 签名区 VA */
    add     x28, x28, x29                 /* x28 = s_entry VA（mret 目标）*/

    /*------------------------------------------------------------------
     * 2. 建根页表：root[VPN1(0x4000_0000)=0x100] = 4 MiB 超级页叶子
     *    PA = 0x8000_0000（4 MiB 对齐 ⇒ PPN[0]=0），flags=V|R|W|X|A|D
     *----------------------------------------------------------------*/
    la      x5, rvtest_sroot_pg_tbl
    li      x6, 0x80000000
    srli    x6, x6, 12                    /* PPN = 0x80000 */
    slli    x6, x6, 10                    /* PTE[31:10] = PPN */
    li      x7, 0xCF                      /* D|A|X|W|R|V */
    or      x6, x6, x7
    sw      x6, 0x400(x5)                 /* root + 0x100*4 */

    /*------------------------------------------------------------------
     * 2.1 PMP 背景区：pmpaddr0=-1 + pmpcfg0=0x0F（TOR RWX）
     *    ★ 必需：S/U 模式下"无匹配 PMP 项 ⇒ 拒绝"，页表隐式访存也要过 PMP
     *      （ptw.v W1）⇒ 不配 PMP 会得到 cause 1（instruction access fault），
     *      那是 PMP 口径而非翻译口径。
     *----------------------------------------------------------------*/
    li      x6, -1
    csrw    pmpaddr0, x6
    li      x6, 0x0F
    csrw    pmpcfg0, x6

    /*------------------------------------------------------------------
     * 3. 写 satp（MODE=Sv32, PPN=root）+ **sfence.vma**（被测指令）
     *----------------------------------------------------------------*/
    la      x6, rvtest_sroot_pg_tbl
    srli    x6, x6, 12
    li      x7, 0x80000000                /* satp.MODE=1（bit31）*/
    or      x6, x6, x7
    csrw    satp, x6
    sfence.vma                            /* ★ sfence.vma（rs1=x0, rs2=x0：全冲刷）*/

    /*------------------------------------------------------------------
     * 4. 准备陷回 M 模式的落点 + M 模式陷阱入口
     *----------------------------------------------------------------*/
    la      x7, m_trap_handler
    csrw    mtvec, x7

    /*------------------------------------------------------------------
     * 5. mret 进 S 模式，PC = x28（= VA 0x4000_00xx）
     *----------------------------------------------------------------*/
    csrw    mepc, x28
    li      x7, 0x1800                    /* mstatus.MPP 先清 0 */
    csrc    mstatus, x7
    li      x7, 0x0800                    /* MPP = S(01) */
    csrs    mstatus, x7
    mret

    /*==================================================================
     * S 模式代码：**运行在 VA**（PA = 0x8000_0000 + off）
     *================================================================*/
s_entry:
    li      x10, 0x5A5A1234
    sw      x10, 0(x31)                   /* 经 VA 存 ⇒ 数据侧翻译 */
    lw      x12, 0(x31)                   /* 经 VA 读回 */
    sw      x12, 4(x31)                   /* [1] */
    addi    x13, x10, 0x111               /* 取指在此区间执行 ⇒ 取指侧翻译 */
    sw      x13, 8(x31)                   /* [2] */
    ecall                                 /* 回 M 模式（cause 9）*/

    /*------------------------------------------------------------------
     * M 模式陷阱处理：记录 mcause，写 tohost=1 结束
     *----------------------------------------------------------------*/
    .p2align 2
m_trap_handler:
    csrr    x5, mcause
    la      x6, begin_signature
    sw      x5, 12(x6)                    /* [3] = mcause（期望 9）*/
    la      x6, tohost
    li      x7, 1
    /* HTIF 两写语义（见 tb_arch_test §4）：低字=payload，高字=device/cmd=0 ⇒ 退出 */
1:  sw      x7, 0(x6)                     /* tohost   = 1（PASS）*/
    sw      x0, 4(x6)                     /* tohost+4 = 0（device 0 / cmd 0 ⇒ 退出）*/
    j       1b

/*----------------------------------------------------------------------
 * 数据区：根页表（4 KiB 对齐）
 *--------------------------------------------------------------------*/
    .section .data, "aw", @progbits
    .p2align 12
    .globl rvtest_sroot_pg_tbl
rvtest_sroot_pg_tbl:
    .skip 4096

    /* ---- HTIF 终止口（与 dm_smoke 同口径）---- */
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
    .skip 16
    .globl end_signature
end_signature:
