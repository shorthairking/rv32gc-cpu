/*=============================================================================
 * priv_trap.S —— 特权级 / 陷阱路径定向自测（RV32：M/S/U 三态 + 陷阱 + 委托）
 *-----------------------------------------------------------------------------
 * 为什么需要它：现有 123 个 arch-test 用例全部在 M 模式跑同步异常，从未覆盖
 *   "mret 切特权级 / 委托 medeleg / stvec / sret / M 模式中断进入" 这条通路，
 *   而后续 78 个特权 PMP 用例（全部 #define BOOT_TO_MMODE）依赖它。
 *
 * 运行约定（与 sim/tests/lrsc.S 相同的"裸机自测"范式）：
 *   链接布局 : sim/tests/link.ld（.text.init 起始 = 0x0 = 复位 PC；sp = 0x0008_0000）
 *   打印     : 0x1FAF_FF10 虚拟串口（写一字节 → TB $write("%c")）
 *   退出码   : 0x1FAF_FF00（0 = 全部通过；非 0 = 首个失败项的检查编号）
 *   陷阱向量 : mtvec / stvec 由本程序自行设置
 *
 * 判定模型：**非快速失败**。每条检查独立记账：
 *   · 通过 → t6++；失败 → 累计到 s2、记录首个失败 id 到 s7，并立刻打印
 *     "[FAIL] check <id> got=<v> expect=<v>"（got/expect 用十进制无符号打印）；
 *   · 前置条件不成立的检查（如"中断未进入"时的 5 项中断 CSR 检查）计为 SKIP，
 *     单独打印区间，不与 PASS/FAIL 混同（不伪造通过）。
 *   结束时若 s2、s3 均为 0 → 打印 PRIV_TRAP: PASS (<t6> checks) 并写退出码 0。
 *
 * 陷阱记录的存放：**全部放寄存器**（不落内存），避免本平台仿真模型
 *   "写后立刻读同一地址可能读到上一版数据"的时序假象影响自校验。
 *   s8=进入的处理程序入口 PC，s9=cause，s10=epc，s11=tval，a4=入口时刻的 status(CSR)。
 *
 * 环境约束：纯 RV32I + Zicsr（不加 C，全部 4 字节指令，便于按 PC 校验 mepc/sepc）；
 *   -mno-relax 保证 la = auipc+addi，地址可控。
 *=============================================================================*/

#define VUART       0x1FAFFF10
#define EXIT_ADDR   0x1FAFFF00

    .option norvc
    .section .text.init, "ax"
    .globl _start
    .type  _start, @function

/*=============================================================================
 * 检查宏
 *   寄存器约定（跨陷阱必须存活的值只放 s0-s11/a4/a5）：
 *     s0=VUART s1=EXIT s2=失败数 s3=跳过数 s4=阶段号 s5=恢复标志槽
 *     s6=本阶段期望的陷阱 PC  s7=首个失败 id  s8..s11=陷阱记录
 *     a4=陷阱入口 status      a5=辅助记录      t6=已执行检查数
 *   a6/a7 供 CKI 宏内部使用，**不要**用它们保存活值。
 *=============================================================================*/
.macro CKI r, imm, id
    li      a6, \imm
    beq     \r, a6, 991f
    mv      a0, \r
    li      a1, \imm
    li      a2, \id
    call    report_fail_reg
991:
    addi    t6, t6, 1
.endm

.macro CKR r1, r2, id
    beq     \r1, \r2, 992f
    mv      a0, \r1
    mv      a1, \r2
    li      a2, \id
    call    report_fail_reg
992:
    addi    t6, t6, 1
.endm

/* CSR/寄存器证据打印：名称字符串 + 值（十六进制 8 位）
 * 注意 puts 会 clobber t0/t1，故先用 a2 暂存待打印值（调用方不使用 a2）。 */
.macro CSRDUMP label, csr
    csrr    a2, \csr
    la      a0, \label
    call    puts
    mv      a0, a2
    call    puthex8
    la      a0, s_nl
    call    puts
.endm

.macro REGDUMP label, reg
    mv      a2, \reg
    la      a0, \label
    call    puts
    mv      a0, a2
    call    puthex8
    la      a0, s_nl
    call    puts
.endm

/*=============================================================================
 * 入口
 *=============================================================================*/
_start:
    li      sp, 0x00080000          /* 栈顶（link.ld 约定，helper 调用用） */
    li      s0, VUART
    li      s1, EXIT_ADDR
    li      s2, 0                   /* 失败数 */
    li      s3, 0                   /* 跳过数 */
    li      s4, 0
    li      s5, 0
    li      s6, 0
    li      s7, 0                   /* 首个失败 id */
    li      t6, 0                   /* 已执行检查数 */
    csrw    mstatus, zero           /* MIE/MPIE/MPP/SIE/SPIE/SPP 全清，状态确定 */

/*-----------------------------------------------------------------------------
 * 阶段 A：mtvec 写/读回（direct / vectored，MODE 保留）
 *---------------------------------------------------------------------------*/
    li      t0, 0x00002000          /* direct：MODE=00，基址 4 字节对齐 */
    csrw    mtvec, t0
    csrr    t1, mtvec
    CKI     t1, 0x00002000, 1       /* A: direct 模式基址读回 */

    li      t0, 0x00002001          /* vectored：MODE=01（基址 0x2000，64B 对齐） */
    csrw    mtvec, t0
    csrr    t1, mtvec
    CKI     t1, 0x00002001, 2       /* A: MODE=01 写回后低位保留 */

    la      t2, vec_table           /* 64 字节对齐的向量表基址 */
    csrw    mtvec, t2
    csrr    t1, mtvec
    CKR     t1, t2, 3               /* A: direct 写 64B 对齐基址读回 */

    la      t2, vec_table
    ori     t2, t2, 1
    csrw    mtvec, t2
    csrr    t1, mtvec
    CKR     t1, t2, 4               /* A: vectored 写 64B 对齐基址，MODE 保留 */

/*-----------------------------------------------------------------------------
 * 阶段 B：M 模式 ecall → mtvec(direct) → 改 mepc 跳过 → mret 继续
 *---------------------------------------------------------------------------*/
    la      t0, mh_m
    csrw    mtvec, t0
    li      s8, 0
    li      s9, 0
    li      s10, 0
    li      s11, 0
    li      a4, 0
    li      s5, 0
    la      s6, b_ecall
b_ecall:
    ecall
    li      s5, 0x5C                /* 只有正确跳过并 mret 才会执行到这条 */

    la      t0, mh_m
    CKR     s8, t0, 5               /* B: 取到 mtvec 基址（direct），M handler 入口 */
    CKI     s9, 11, 6               /* B: mcause = 11 (ECALL_M) */
    CKR     s10, s6, 7              /* B: mepc = 该 ecall 的 PC */
    CKI     s11, 0, 8               /* B: mtval = 0 */
    srli    t1, a4, 11
    andi    t1, t1, 3
    CKI     t1, 3, 9                /* B: mstatus.MPP = 11（来自 M） */
    CKI     s5, 0x5C, 10            /* B: 改 mepc 后 mret 从 ecall 下一条继续 */

/*-----------------------------------------------------------------------------
 * 阶段 C：mret 切 S 模式；S 模式 ecall 未委托 → M 陷阱（mcause=9, MPP=01）
 *---------------------------------------------------------------------------*/
    csrw    medeleg, zero           /* 关闭委托 */
    la      t0, mh_back_m
    csrw    mtvec, t0
    li      s4, 1                   /* 阶段号 1 */
    li      s8, 0
    li      s5, 0
    la      t0, s_seg
    csrw    mepc, t0
    csrr    t0, mstatus
    li      t1, 0xFFFFE7FF          /* ~(MPP) */
    and     t0, t0, t1
    li      t1, 0x800               /* MPP = 01 → S */
    or      t0, t0, t1
    csrw    mstatus, t0
    mret                            /* → S 模式，PC = s_seg */

    .p2align 2
s_seg:
    li      s5, 0
    la      s6, c_ecall
c_ecall:
    ecall                           /* S 模式、未委托 → M 陷阱 */
    li      s5, 0x5A                /* handler 改 mepc=m_done ⇒ 不应执行到这条 */

c_done:                             /* m_done 分发回到这里（已在 M 模式） */
    la      t0, mh_back_m
    CKR     s8, t0, 11              /* C: 未委托 ⇒ 走 mtvec */
    CKI     s9, 9, 12               /* C: mcause = 9 (ECALL_S) ⇒ 触发时 priv=S */
    srli    t1, a4, 11
    andi    t1, t1, 3
    CKI     t1, 1, 13               /* C: mstatus.MPP = 01（触发时的模式 S） */
    CKR     s10, s6, 14             /* C: mepc = S 段 ecall 的 PC */
    csrr    t1, mstatus
    srli    t1, t1, 11
    andi    t1, t1, 3
    CKI     t1, 0, 15               /* C: mret 后 MPP 回 U（规范），证明 mret 生效 */
    CKI     s5, 0, 16               /* C: ecall 后的指令被跳过（改 mepc 生效） */

/*-----------------------------------------------------------------------------
 * 阶段 D：U 模式 ecall 未委托 → M 陷阱（mcause=8, MPP=00）
 *---------------------------------------------------------------------------*/
    li      s4, 2
    li      s8, 0
    li      s5, 0
    la      t0, u_seg
    csrw    mepc, t0
    csrr    t0, mstatus
    li      t1, 0xFFFFE7FF
    and     t0, t0, t1              /* MPP = 00 → U */
    csrw    mstatus, t0
    mret                            /* → U 模式，PC = u_seg */

    .p2align 2
u_seg:
    li      s5, 0
    la      s6, d_ecall
d_ecall:
    ecall                           /* U 模式、未委托 → M 陷阱 */
    li      s5, 0x5A

d_done:
    CKI     s9, 8, 17               /* D: mcause = 8 (ECALL_U) ⇒ 触发时 priv=U */
    srli    t1, a4, 11
    andi    t1, t1, 3
    CKI     t1, 0, 18               /* D: mstatus.MPP = 00（触发时的模式 U） */
    CKR     s10, s6, 19             /* D: mepc = U 段 ecall 的 PC */
    CKI     s5, 0, 20               /* D: ecall 后的指令被跳过 */

/*-----------------------------------------------------------------------------
 * 阶段 E：委托 medeleg[9] → S 模式 ecall 走 stvec；sret；SPP/SPIE/SIE 保存恢复
 *---------------------------------------------------------------------------*/
    li      t0, 0x300               /* medeleg: cause 8|9 → S */
    csrw    medeleg, t0
    la      t0, sh_ecall
    csrw    stvec, t0
    la      t0, mh_back_m
    csrw    mtvec, t0
    li      s4, 3
    li      s8, 0
    li      s5, 0
    la      t0, e_seg
    csrw    mepc, t0
    csrr    t0, mstatus
    li      t1, 0xFFFFE7FF
    and     t0, t0, t1
    li      t1, 0x800               /* MPP = 01 → S */
    or      t0, t0, t1
    csrw    mstatus, t0
    mret                            /* → S 模式，PC = e_seg */

    .p2align 2
e_seg:
    li      t0, 2
    csrs    sstatus, t0             /* sstatus.SIE = 1（用于验证 SPIE←SIE） */
    li      s8, 0                   /* 清记录：若走 mtvec 会被 mh_back_m 覆盖 */
    li      s5, 0
    la      s6, e_ecall
e_ecall:
    ecall                           /* S 模式、已委托 → stvec */
    li      s5, 0x5A                /* sret 后从这里继续（SPP=1 → 回 S 模式） */
    csrr    a5, sstatus             /* sret 之后的 sstatus */

    la      t0, sh_ecall
    CKR     s8, t0, 21              /* E: 委托生效 ⇒ 走 stvec（未走 mtvec） */
    CKI     s9, 9, 22               /* E: scause = 9 */
    CKR     s10, s6, 23             /* E: sepc = ecall 的 PC */
    CKI     s11, 0, 24              /* E: stval = 0 */
    srli    t1, a4, 8
    andi    t1, t1, 1
    CKI     t1, 1, 25               /* E: 入口 sstatus.SPP = 1（来自 S） */
    srli    t1, a4, 5
    andi    t1, t1, 1
    CKI     t1, 1, 26               /* E: 入口 sstatus.SPIE ← 旧 SIE(=1) */
    srli    t1, a4, 1
    andi    t1, t1, 1
    CKI     t1, 0, 27               /* E: 入口 sstatus.SIE ← 0 */
    CKI     s5, 0x5A, 28            /* E: sret 后继续在 S 模式执行 */
    srli    t1, a5, 8
    andi    t1, t1, 1
    CKI     t1, 0, 29               /* E: sret 后 SPP ← 0 */
    srli    t1, a5, 5
    andi    t1, t1, 1
    CKI     t1, 1, 30               /* E: sret 后 SPIE ← 1 */
    srli    t1, a5, 1
    andi    t1, t1, 1
    CKI     t1, 1, 31               /* E: sret 后 SIE ← 旧 SPIE(=1) */
    ebreak                          /* 未委托 → M → mh_back_m → m_done */

e_done:
    csrr    t1, mstatus
    srli    t1, t1, 11
    andi    t1, t1, 3
    CKI     t1, 0, 32               /* E: 返回 M 后 MPP 回 U（mret 已执行） */

/*-----------------------------------------------------------------------------
 * 阶段 F：委托下 U 模式 ecall → stvec（SPP=0）→ sret 回 U
 *---------------------------------------------------------------------------*/
    li      s4, 4
    li      s8, 0
    li      s5, 0
    la      t0, u2_seg
    csrw    mepc, t0
    csrr    t0, mstatus
    li      t1, 0xFFFFE7FF
    and     t0, t0, t1              /* MPP = 00 → U */
    csrw    mstatus, t0
    mret                            /* → U 模式，PC = u2_seg */

    .p2align 2
u2_seg:
    li      s8, 0
    li      s5, 0
    la      s6, f_ecall
f_ecall:
    ecall                           /* U 模式、已委托 → stvec（S 陷阱） */
    li      s5, 0x5B                /* sret（SPP=0）→ 回 U 模式，从这里继续 */

    la      t0, sh_ecall
    CKR     s8, t0, 33              /* F: U 模式 ecall 也走 stvec */
    CKI     s9, 8, 34               /* F: scause = 8 (ECALL_U) */
    CKR     s10, s6, 35             /* F: sepc = ecall 的 PC */
    srli    t1, a4, 8
    andi    t1, t1, 1
    CKI     t1, 0, 36               /* F: 入口 sstatus.SPP = 0（来自 U） */
    CKI     s5, 0x5B, 37            /* F: sret 回 U 后继续执行 */
    ebreak                          /* 未委托 → M → mh_back_m → m_done */

f_done:
    csrr    t1, mstatus
    srli    t1, t1, 11
    andi    t1, t1, 3
    CKI     t1, 0, 38               /* F: 返回 M 后 MPP 回 U */

/*-----------------------------------------------------------------------------
 * 阶段 I：M 模式软件中断进入（mip.MSIP + mie.MSIE + mstatus.MIE）
 *   取指点 = i_marker（让中断在 mip 写提交后的第一条指令处被取）
 *---------------------------------------------------------------------------*/
    li      t0, 8                   /* MSIP = MIE.MSIE = mstatus.MIE = bit3 */
    csrc    mip, t0
    csrw    mie, t0                 /* mie.MSIE = 1 */
    csrs    mstatus, t0             /* mstatus.MIE = 1 */
    li      s5, 0
    li      s8, 0
    li      s9, 0
    li      s10, 0
    li      s11, 0
    li      a4, 0
    la      t1, vec_table           /* 向量模式（MODE=01）分发 */
    ori     t1, t1, 1
    csrw    mtvec, t1
    la      s6, i_marker
    li      t0, 8
    csrw    mip, t0                 /* 置 MSIP=1（挂起）；下一条指令即打断点 */
i_marker:
    li      s5, 0x1D                /* 被打断的指令：mret 后重新执行 */

    la      t1, vec_table
    addi    t1, t1, 12              /* MSIP(cause=3) 向量 = base + 4*3 */
    CKR     s8, t1, 39              /* I: M 模式中断进入且走 vectored 分发 */
    la      t1, vec_table           /* 失败路径会 clobber t，此处重算门控比较值 */
    addi    t1, t1, 12
    beq     s8, t1, i_ok            /* 未进入 ⇒ 后续中断检查无判定依据 */
    la      a0, s_i_ev
    call    puts
    CSRDUMP n_mtvec, mtvec
    CSRDUMP n_mstatus, mstatus
    CSRDUMP n_mie, mie
    CSRDUMP n_mip, mip
    REGDUMP n_hent, s8
    REGDUMP n_tcause, s9
    REGDUMP n_tepc, s10
    REGDUMP n_tstat, a4
    la      a0, s_i_exp
    call    puts
    la      t1, vec_table
    addi    t1, t1, 12
    REGDUMP n_vexp, t1
    li      a0, 40
    li      a1, 5
    call    report_skip_range       /* 40..44 见 SKIP 说明 */
    j       i_cleanup

i_ok:
    li      t1, 0x80000003
    CKR     s9, t1, 40              /* I: mcause 最高位=1，cause=3(MSIP) */
    CKR     s10, s6, 41             /* I: mepc = 被打断指令的 PC */
    srli    t1, a4, 7
    andi    t1, t1, 1
    CKI     t1, 1, 42               /* I: 入口 mstatus.MPIE ← 旧 MIE(=1) */
    srli    t1, a4, 3
    andi    t1, t1, 1
    CKI     t1, 0, 43               /* I: 入口 mstatus.MIE ← 0 */
    CKI     s5, 0x1D, 44            /* I: mret 后重跑被打断指令并继续 */

i_cleanup:
    li      t0, 8
    csrc    mip, t0                 /* 清挂起，保证后续阶段状态确定 */
    csrc    mstatus, t0             /* MIE = 0 */

/*-----------------------------------------------------------------------------
 * 阶段 G：mepc/sepc 低位对齐
 *---------------------------------------------------------------------------*/
    li      t0, 0x00001001
    csrw    mepc, t0
    csrr    t1, mepc
    CKI     t1, 0x00001000, 45      /* G: mepc[0] 恒为 0 */
    li      t0, 0x00002003
    csrw    sepc, t0
    csrr    t1, sepc
    CKI     t1, 0x00002002, 46      /* G: sepc[0] 恒为 0 */

/*-----------------------------------------------------------------------------
 * 汇总与退出
 *---------------------------------------------------------------------------*/
test_end:
    or      t0, s2, s3
    beqz    t0, all_pass

    la      a0, s_fail_head
    call    puts
    mv      a0, t6
    sub     a0, a0, s2
    call    putu32
    la      a0, s_slash
    call    puts
    mv      a0, t6
    call    putu32
    la      a0, s_fails_eq
    call    puts
    mv      a0, s2
    call    putu32
    la      a0, s_first_eq
    call    puts
    mv      a0, s7
    call    putu32
    la      a0, s_skip_eq
    call    puts
    mv      a0, s3
    call    putu32
    la      a0, s_rparen
    call    puts

    la      a0, s_csr_head
    call    puts
    CSRDUMP n_mcause, mcause
    CSRDUMP n_mepc,   mepc
    CSRDUMP n_mtval,  mtval
    CSRDUMP n_mstatus, mstatus
    CSRDUMP n_mtvec,  mtvec
    CSRDUMP n_medeleg, medeleg
    CSRDUMP n_mie,    mie
    CSRDUMP n_mip,    mip
    CSRDUMP n_scause, scause
    CSRDUMP n_sepc,   sepc
    CSRDUMP n_stval,  stval
    CSRDUMP n_sstatus, sstatus
    CSRDUMP n_stvec,  stvec
    la      a0, s_i_regs
    call    puts
    REGDUMP n_hent,  s8
    REGDUMP n_tcause, s9
    REGDUMP n_tepc,  s10
    REGDUMP n_tval,  s11
    REGDUMP n_tstat, a4
    REGDUMP n_astat, a5
    REGDUMP n_rflag, s5

    sw      s7, 0(s1)               /* 退出码 = 首个失败项编号（非 0） */
    j       test_end

all_pass:
    la      a0, s_pass_head
    call    puts
    mv      a0, t6
    call    putu32
    la      a0, s_pass_tail
    call    puts
    sw      zero, 0(s1)             /* 退出码 0 */
    j       all_pass

/*=============================================================================
 * 陷阱处理程序
 *=============================================================================*/

/* M 模式：阶段 B（ecall → 跳过 4 字节 → mret 回 M） */
    .p2align 2
mh_m:
    auipc   s8, 0                   /* 入口 PC（本 handler 基址） */
    csrr    s9, mcause
    csrr    s10, mepc
    csrr    s11, mtval
    csrr    a4, mstatus
    addi    t0, s10, 4              /* mepc += 4：跳过 ecall */
    csrw    mepc, t0
    mret

/* M 模式：阶段 C-F（记录后返回 m_done，主流程按 s4 分发） */
    .p2align 2
mh_back_m:
    auipc   s8, 0
    csrr    s9, mcause
    csrr    s10, mepc
    csrr    s11, mtval
    csrr    a4, mstatus
    la      t0, m_done
    csrw    mepc, t0
    csrr    t0, mstatus
    li      t1, 0xFFFFE7FF          /* ~(MPP) */
    and     t0, t0, t1
    li      t1, 0x1800              /* MPP = 11 → M */
    or      t0, t0, t1
    csrw    mstatus, t0
    mret

/* S 模式：委托后的 ecall（记录 → sepc += 4 → sret） */
    .p2align 2
sh_ecall:
    auipc   s8, 0
    csrr    s9, scause
    csrr    s10, sepc
    csrr    s11, stval
    csrr    a4, sstatus
    addi    t0, s10, 4
    csrw    sepc, t0
    sret

/* 阶段分发（M 模式） */
    .p2align 2
m_done:
    li      t0, 1
    beq     s4, t0, c_done
    li      t0, 2
    beq     s4, t0, d_done
    li      t0, 3
    beq     s4, t0, e_done
    li      t0, 4
    beq     s4, t0, f_done
    li      a0, 0
    li      a1, 0
    li      a2, 90                  /* 不应到达：阶段号非法 */
    call    report_fail_reg
    j       test_end

/*-----------------------------------------------------------------------------
 * 向量表（64 字节对齐）：+0 通用入口，+12 = cause 3 (MSIP)
 *---------------------------------------------------------------------------*/
    .p2align 6
vec_table:
    auipc   t0, 0                   /* +0：记录入口 PC */
    j       vec_common
    nop                             /* +8：填充，保证 +12 为 cause=3 入口 */
    auipc   t0, 0                   /* +12：cause 3 (MSIP) 入口 */
    j       vec_common

    .p2align 2
vec_common:
    mv      s8, t0                  /* s8 = 陷阱入口 PC（t0 由 auipc 给出） */
    csrr    s9, mcause
    csrr    s10, mepc
    csrr    s11, mtval
    csrr    a4, mstatus
    li      t1, 8
    csrc    mip, t1                 /* 清 MSIP，避免重复进入 */
    mret

/*=============================================================================
 * 打印/记账 helper（仅主流程调用；handler 内不调用）
 *=============================================================================*/

/* puts(a0 = 字符串)：写 VUART */
puts:
    mv      t0, a0
1:  lbu     t1, 0(t0)
    beqz    t1, 2f
    sb      t1, 0(s0)
    addi    t0, t0, 1
    j       1b
2:  ret

/* putu32(a0 = 无符号十进制打印) */
putu32:
    addi    sp, sp, -16
    sw      ra, 12(sp)
    la      t5, pows
    li      t4, 0                   /* 已打印非零位标志 */
1:  lw      t2, 0(t5)
    beqz    t2, 9f
    li      t3, 0                   /* 本位数字 */
2:  bltu    a0, t2, 3f
    sub     a0, a0, t2
    addi    t3, t3, 1
    j       2b
3:  bnez    t3, 4f
    bnez    t4, 4f
    li      t1, 1
    bne     t2, t1, 5f              /* 前导零且除数≠1 → 跳过 */
4:  li      t4, 1
    addi    t1, t3, 48
    sb      t1, 0(s0)
5:  addi    t5, t5, 4
    j       1b
9:  lw      ra, 12(sp)
    addi    sp, sp, 16
    ret

/* puthex8(a0 = 8 位十六进制) */
puthex8:
    la      t0, hexd
    li      t1, 8
1:  srli    t2, a0, 28
    slli    a0, a0, 4
    add     t2, t0, t2
    lbu     t3, 0(t2)
    sb      t3, 0(s0)
    addi    t1, t1, -1
    bnez    t1, 1b
    ret

/* report_fail_reg(a0=实际值, a1=期望值, a2=检查编号)：记账 + 立刻打印 */
report_fail_reg:
    addi    sp, sp, -32
    sw      ra, 28(sp)
    sw      a0, 0(sp)
    sw      a1, 4(sp)
    sw      a2, 8(sp)
    addi    s2, s2, 1
    bnez    s7, 1f
    mv      s7, a2
1:  la      a0, s_fail_check
    call    puts
    lw      a0, 8(sp)
    call    putu32
    la      a0, s_fail_got
    call    puts
    lw      a0, 0(sp)
    call    putu32
    la      a0, s_fail_exp
    call    puts
    lw      a0, 4(sp)
    call    putu32
    la      a0, s_nl
    call    puts
    lw      ra, 28(sp)
    addi    sp, sp, 32
    ret

/* report_skip_range(a0=首个编号, a1=个数)：记账 + 打印区间 */
report_skip_range:
    addi    sp, sp, -16
    sw      ra, 12(sp)
    sw      a0, 0(sp)
    sw      a1, 4(sp)
    add     s3, s3, a1
    la      a0, s_skip_head
    call    puts
    lw      a0, 0(sp)
    call    putu32
    la      a0, s_skip_mid
    call    puts
    lw      t0, 0(sp)               /* puts/putu32 会 clobber t，故此处重算区间末值 */
    lw      t1, 4(sp)
    addi    t1, t1, -1
    add     t0, t0, t1
    mv      a0, t0
    call    putu32
    la      a0, s_skip_tail
    call    puts
    lw      ra, 12(sp)
    addi    sp, sp, 16
    ret

/*=============================================================================
 * 字符串/常量表
 *=============================================================================*/
    .section .rodata
    .p2align 2
pows:
    .word 1000000000, 100000000, 10000000, 1000000, 100000, 10000, 1000, 100, 10, 1, 0

hexd:           .asciz "0123456789abcdef"
s_nl:           .asciz "\n"
s_pass_head:    .asciz "\nPRIV_TRAP: PASS ("
s_pass_tail:    .asciz " checks)\n"
s_fail_head:    .asciz "\nPRIV_TRAP: FAIL (passed="
s_slash:        .asciz "/"
s_fails_eq:     .asciz ", fails="
s_first_eq:     .asciz ", first="
s_skip_eq:      .asciz ", skipped="
s_rparen:       .asciz ")\n"
s_fail_check:   .asciz "\n[FAIL] check "
s_fail_got:     .asciz " got="
s_fail_exp:     .asciz " expect="
s_skip_head:    .asciz "\n[SKIP] checks "
s_skip_mid:     .asciz ".."
s_skip_tail:    .asciz " (precondition failed, not judged)\n"
s_csr_head:     .asciz "\n---- 失败现场 CSR ----\n"
s_i_regs:       .asciz "\n---- 陷阱记录（寄存器）----\n"
s_i_ev:         .asciz "\n---- 中断现场证据 ----\n"
s_i_exp:        .asciz "---- 期望：中断入口 = mtvec base + 4*3 ----\n"
n_mcause:       .asciz "mcause   = 0x"
n_mepc:         .asciz "mepc     = 0x"
n_mtval:        .asciz "mtval    = 0x"
n_mstatus:      .asciz "mstatus  = 0x"
n_mtvec:        .asciz "mtvec    = 0x"
n_medeleg:      .asciz "medeleg  = 0x"
n_mie:          .asciz "mie      = 0x"
n_mip:          .asciz "mip      = 0x"
n_scause:       .asciz "scause   = 0x"
n_sepc:         .asciz "sepc     = 0x"
n_stval:        .asciz "stval    = 0x"
n_sstatus:      .asciz "sstatus  = 0x"
n_stvec:        .asciz "stvec    = 0x"
n_hent:         .asciz "handler_entry = 0x"
n_tcause:       .asciz "trap_cause    = 0x"
n_tepc:         .asciz "trap_epc      = 0x"
n_tval:         .asciz "trap_tval     = 0x"
n_tstat:        .asciz "trap_status   = 0x"
n_astat:        .asciz "aux_status    = 0x"
n_rflag:        .asciz "resume_flag   = 0x"
n_vexp:         .asciz "expected_ent  = 0x"

    .end
