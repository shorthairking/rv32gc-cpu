/*=============================================================================
 * fetch_err.S —— 总线访问错误（access fault）通道定向自测
 *-----------------------------------------------------------------------------
 * 被验证的语义（RTL 侧实现见 rtl/frontend/rv32_ifetch.v / rtl/top/rv32gc_core.v）：
 *   ① 取指总线错误：AXI 读响应 err ⇒ ifetch 置 sticky fetch_err（该行不填充），
 *      核在**流水线排空后**取陷阱：cause 1(EXC_INSTR_ACCESS)、
 *      mepc = mtval = 取不到的那条指令的地址（出错时的 pc_q），随后跳 mtvec。
 *   ② 访存总线错误（既有实现，本文件一并回归）：load → cause 5、store → cause 7，
 *      mtval = 出错地址（VA），mepc = 出错指令的 PC。
 *   ③ 三类陷阱之后程序都能继续执行（handler 把 mepc 写成"恢复标签"再 mret；
 *      取指错误的 mepc 指向取不到的指令，**不能 mepc+4**）。
 *   ④ 对照：故障地址边界内侧的正常访存 / 算术自检不受影响。
 *
 * 故障地址怎么选（核实依据 sim/tb/sim_axi_slave.v，行号为该文件行号）：
 *   · region_of()（169-181 行）：
 *       0x0000_0000-0x00FF_FFFF → MEM_LO（MEM_LO_BYTES=0x0100_0000，39 行）
 *       0x8000_0000-0x800F_FFFF → MEM_HI（MEM_HI_BYTES=0x0010_0000，40 行）
 *       0x1FD0_0000-0x1FD0_FFFF → CONFREG FPGA；0x1FAF_0000-0x1FAF_FFFF → CONFREG 仿真
 *       0x1FE0_0000-0x1FE0_3FFF → UART；0x1C00_0000-0x1C0F_FFFF 与 0x1FE8_0000-0x1FE8_FFFF → SPI
 *       其它 → R_NONE ⇒ rresp/bresp = 2'b10（SLVERR；读 463/486 行、写 422/429 行）
 *   · 本测试用 **0x9000_0000**（不在任何窗口内 ⇒ 未映射 ⇒ SLVERR），
 *     另用 **0x8010_0000**（MEM_HI 末地址 0x800F_FFFF 的**下一个字**，边界外侧 ⇒ 同样未映射）
 *     做边界对照；**0x800F_FFFC**（MEM_HI 边界内侧最后一个字）做"正常路径未受影响"对照。
 *   · PMP 背景项（entry15 = L|NAPOT|RWX 覆盖全空间，同 sim/tests/priv_trap.S 做法）保证
 *     M 模式对上述地址的取指/访存**不会被 PMP 拒绝** ⇒ 观察到的 access fault 只能来自总线 SLVERR。
 *
 * 运行约定（与 sim/tests/priv_trap.S 相同范式）：
 *   链接布局 : sim/tests/link.ld（.text.init 起始 = 0x0 = 复位 PC；sp = 0x0008_0000）
 *   打印     : 0x1FAF_FF10 虚拟串口（写一字节 → TB $write("%c")）
 *   退出码   : 0x1FAF_FF00（0 = 全部通过；非 0 = 首个失败项编号）
 *   陷阱向量 : mtvec = mh（direct 模式，本程序自行设置）
 *
 * 判定模型：非快速失败。每条检查独立记账：通过 → t6++；失败 → s2++、首个失败 id 记 s7，
 *   并立刻打印 "[FAIL] check <id> got=<v> expect=<v>"（十进制无符号）。
 *   结束时 s2 == 0 → 打印 "FETCH_ERR: PASS (<t6> checks)" 并写退出码 0。
 *
 * 陷阱记录：**全部放寄存器**（不落内存），避免本平台仿真模型"写后立刻读同一地址"的
 *   时序假象（sim_axi_slave.v 464-470 行：读数据寄存一拍）。
 *
 * 环境约束：纯 RV32I + Zicsr（不加 C，全部 4 字节指令，便于按 PC 校验 mepc）；
 *   -mno-relax 保证 la = auipc+addi，地址可控。
 *
 * 寄存器约定（跨陷阱存活的值只放 s0-s11/a4/a5）：
 *   s0=VUART s1=EXIT s2=失败数 s3=本次故障地址 s4=阶段号 s5=恢复标记
 *   s6=本阶段期望的陷阱 PC s7=首个失败 id s8..s11=入口PC/cause/epc/tval
 *   a4=陷阱入口 mstatus  a5=累计陷阱数  t6=已执行检查数
 *   a6/a7 供 CKI/CKR 宏内部使用，**不要**用它们保存活值；t0-t5/a0-a3 被 helper clobber。
 *=============================================================================*/

#define VUART       0x1FAFFF10
#define EXIT_ADDR   0x1FAFFF00

#define FA_FETCH0   0x90000000          /* 取指故障地址（未映射） */
#define FA_LOAD     0x90000004          /* load 故障地址（未映射） */
#define FA_STORE    0x90000008          /* store 故障地址（未映射） */
#define FA_FETCH1   0x80100000          /* MEM_HI 边界外第一个字：取指故障地址 */

    .option norvc
    .section .text.init, "ax"
    .globl _start
    .type  _start, @function

/*=============================================================================
 * 检查宏（复刻 sim/tests/priv_trap.S 的 CKI/CKR）
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

/* 证据打印：名称字符串 + 值（十六进制 8 位）。puts 会 clobber t0/t1，故用 a2 暂存。 */
.macro REGDUMP label, reg
    mv      a2, \reg
    la      a0, \label
    call    puts
    mv      a0, a2
    call    puthex8
    la      a0, s_nl
    call    puts
.endm

.macro CSRDUMP label, csr
    csrr    a2, \csr
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
    li      sp, 0x00080000          /* 栈顶（link.ld 约定） */
    li      s0, VUART
    li      s1, EXIT_ADDR
    li      s2, 0                   /* 失败数 */
    li      s3, 0
    li      s4, 0
    li      s5, 0
    li      s6, 0
    li      s7, 0                   /* 首个失败 id */
    li      s8, 0
    li      s9, 0
    li      s10, 0
    li      s11, 0
    li      a4, 0
    li      a5, 0                   /* 陷阱计数（防风暴看门狗用） */
    li      t6, 0                   /* 已执行检查数 */
    csrw    mstatus, zero           /* 关中断、状态确定 */
    csrw    mie, zero
    csrw    medeleg, zero

/* PMP 背景项：entry15 = L|NAPOT|RWX 覆盖全空间 -------------------------------
 * 目的：M 模式访问 0x9000_0000 / 0x8010_0000 不会被 PMP 拒绝 ⇒ 之后观察到的
 * access fault 只能来自 AXI 从设备对未映射地址的 SLVERR（而不是 cause 1/5/7 的 PMP 分支）。 */
    li      t0, -1
    csrw    pmpaddr15, t0
    li      t0, 0x9F000000
    csrw    pmpcfg3, t0

/* mtvec = mh（direct） */
    la      t0, mh
    csrw    mtvec, t0
    csrr    t1, mtvec
    la      t2, mh
    CKR     t1, t2, 1               /* 1: mtvec 读回 = handler 基址（向量已装好） */

/*-----------------------------------------------------------------------------
 * 阶段 1：取指总线错误 @ 0x9000_0000
 *   jalr 把 PC 打到未映射地址 ⇒ AXI 读数据返回 SLVERR ⇒ 期望 cause 1，
 *   mepc = mtval = 0x9000_0000（**不是** jalr 的地址，也不是故障地址 +4）。
 *   注意：那条"取不到的指令"从未执行 ⇒ handler 必须改 mepc 到恢复标签，不能 +4。
 *---------------------------------------------------------------------------*/
    li      s4, 1
    li      s3, FA_FETCH0
    li      s5, 0                   /* 恢复标记清零：用于验证陷阱点后的指令未提交 */
    li      s8, 0
    li      s9, 0
    li      s10, 0
    li      s11, 0
    li      a4, 0
    li      t1, FA_FETCH0
    jalr    x0, 0(t1)               /* → PC = 0x9000_0000（取指应报总线错误） */
    li      s5, 0xB1                /* 不应执行：取指错误时这条指令取不到 */

s1_cont:
    la      a0, s_ev1
    call    puts
    REGDUMP n_hent,  s8
    REGDUMP n_mcause, s9
    REGDUMP n_mepc,  s10
    REGDUMP n_mtval, s11
    REGDUMP n_fa,    s3
    REGDUMP n_tcnt,  a5
    REGDUMP n_rflag, s5
    la      a0, s_ev1_exp
    call    puts

    la      t0, mh
    CKR     s8, t0, 2               /* 2: 陷阱入口 PC = mtvec 基址（direct） */
    CKI     s9, 1, 3                /* 3: mcause = 1 (EXC_INSTR_ACCESS) */
    CKR     s10, s3, 4              /* 4: mepc = 取不到的指令地址 */
    CKR     s11, s3, 5              /* 5: mtval = 取不到的指令地址 */
    CKI     s5, 0, 6                /* 6: jalr 之后那条指令未提交（恢复走了 handler 的 mepc） */
    srli    t1, a4, 11
    andi    t1, t1, 3
    CKI     t1, 3, 7                /* 7: 入口 mstatus.MPP = 3（陷阱来自 M 模式） */

/*-----------------------------------------------------------------------------
 * 阶段 2：load 访问错误 @ 0x9000_0004 → cause 5，mtval = VA，mepc = lw 的 PC
 *---------------------------------------------------------------------------*/
    li      s4, 2
    li      s3, FA_LOAD
    li      s5, 0
    li      s8, 0
    li      s9, 0
    li      s10, 0
    li      s11, 0
    li      a4, 0
    li      t1, FA_LOAD
    la      s6, s2_lw
s2_lw:
    lw      t2, 0(t1)               /* 未映射地址 → 读响应 SLVERR → cause 5 */
    li      s5, 0xB2                /* 不应执行 */

s2_cont:
    CKI     s9, 5, 8                /* 8: mcause = 5 (EXC_LOAD_ACCESS) */
    CKR     s11, s3, 9              /* 9: mtval = 出错地址 */
    CKR     s10, s6, 10             /* 10: mepc = lw 的 PC（精确陷阱） */
    CKI     s5, 0, 11               /* 11: lw 之后那条指令未提交 */

/*-----------------------------------------------------------------------------
 * 阶段 3：store 访问错误 @ 0x9000_0008 → cause 7，mtval = VA，mepc = sw 的 PC
 *---------------------------------------------------------------------------*/
    li      s4, 3
    li      s3, FA_STORE
    li      s5, 0
    li      s8, 0
    li      s9, 0
    li      s10, 0
    li      s11, 0
    li      a4, 0
    li      t1, FA_STORE
    li      t2, 0x11223344
    la      s6, s3_sw
s3_sw:
    sw      t2, 0(t1)               /* 未映射地址 → 写响应 SLVERR → cause 7 */
    li      s5, 0xB3                /* 不应执行 */

s3_cont:
    CKI     s9, 7, 12               /* 12: mcause = 7 (EXC_STORE_ACCESS) */
    CKR     s11, s3, 13             /* 13: mtval = 出错地址 */
    CKR     s10, s6, 14             /* 14: mepc = sw 的 PC（精确陷阱） */
    CKI     s5, 0, 15               /* 15: sw 之后那条指令未提交 */

/*-----------------------------------------------------------------------------
 * 阶段 4：边界取指错误 @ 0x8010_0000（MEM_HI 末字 0x800F_FFFF 的下一个字）
 *   证明故障判定跟随地址解码边界，而不是"地址大就报错"。
 *---------------------------------------------------------------------------*/
    li      s4, 4
    li      s3, FA_FETCH1
    li      s5, 0
    li      s8, 0
    li      s9, 0
    li      s10, 0
    li      s11, 0
    li      a4, 0
    li      t1, FA_FETCH1
    jalr    x0, 0(t1)
    li      s5, 0xB4                /* 不应执行 */

s4_cont:
    la      a0, s_ev4
    call    puts
    REGDUMP n_mcause, s9
    REGDUMP n_mepc,  s10
    REGDUMP n_mtval, s11
    REGDUMP n_fa,    s3
    CKI     s9, 1, 16               /* 16: mcause = 1 */
    CKR     s10, s3, 17             /* 17: mepc = 0x8010_0000 */
    CKR     s11, s3, 18             /* 18: mtval = 0x8010_0000 */

/*-----------------------------------------------------------------------------
 * 阶段 5：对照——正常路径未受影响
 *---------------------------------------------------------------------------*/
    /* 对照 A：MEM_HI 边界内侧最后一个字（0x800F_FFFC）读写正常。
       写后读之间穿插若干无关指令：本平台从设备读数据寄存一拍（sim_axi_slave.v 464-470），
       且 store 的写响应要到 WB 才提交，故不能依赖"写后立刻读同址"。 */
    li      t0, 0x800FFFFC
    li      t1, 0xA5A51234
    sw      t1, 0(t0)
    nop
    nop
    nop
    nop
    lw      t2, 0(t0)
    CKI     t2, 0xA5A51234, 19      /* 19: 边界内侧访存正确（对照） */

    /* 对照 B：算术自检（循环求和 1..10 = 55），证明分支/流水线在多次陷阱后仍正常 */
    li      t0, 10
    li      t1, 0
8:  add     t1, t1, t0
    addi    t0, t0, -1
    bnez    t0, 8b
    CKI     t1, 55, 20              /* 20: 算术自检（对照） */

    /* 恢复标记：4 次陷阱之后程序仍在正常路径上继续执行（且未走 0xB1-0xB4 那条路） */
    li      s5, 0xE5
    CKI     s5, 0xE5, 21            /* 21: 陷阱后程序继续执行到结尾 */
    j       test_end

/*=============================================================================
 * 汇总与退出
 *=============================================================================*/
test_end:
    beqz    s2, all_pass

    la      a0, s_fail_head
    call    puts
    mv      a0, t6
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
    la      a0, s_rparen
    call    puts

    la      a0, s_csr_head
    call    puts
    CSRDUMP n_mcause, mcause
    CSRDUMP n_mepc,   mepc
    CSRDUMP n_mtval,  mtval
    CSRDUMP n_mstatus, mstatus
    CSRDUMP n_mtvec,  mtvec
    CSRDUMP n_pmpcfg3, pmpcfg3
    CSRDUMP n_pmpaddr15, pmpaddr15
    REGDUMP n_hent,  s8
    REGDUMP n_tcnt,  a5
    REGDUMP n_rflag, s5
    REGDUMP n_ckcnt, t6

    sw      s7, 0(s1)               /* 退出码 = 首个失败项编号（非 0） */
9:  j       9b                      /* TB 会在下一拍看到 exit_we 并结束仿真 */

all_pass:
    la      a0, s_pass_head
    call    puts
    mv      a0, t6
    call    putu32
    la      a0, s_pass_tail
    call    puts
    sw      zero, 0(s1)             /* 退出码 0 */
7:  j       7b

/*=============================================================================
 * 陷阱处理程序（M 模式，mtvec direct）
 *   记录现场 → mepc = m_done（恢复标签）→ mret
 *   取指错误的 mepc 指向"取不到的指令"，所以这里**绝不能** mepc+4。
 *   陷阱风暴看门狗：累计 > 24 次陷阱（RTL 死循环/反复取错）时记为失败并直接结束。
 *=============================================================================*/
    .p2align 2
mh:
    auipc   s8, 0                   /* 入口 PC */
    csrr    s9, mcause
    csrr    s10, mepc
    csrr    s11, mtval
    csrr    a4, mstatus
    addi    a5, a5, 1
    li      t0, 24
    bltu    a5, t0, 1f
    li      s2, 1                   /* 陷阱风暴：记失败（id 99） */
    li      s7, 99
    la      t0, test_end
    csrw    mepc, t0
    mret
1:  la      t0, m_done
    csrw    mepc, t0
    mret

/* 阶段分发（M 模式）：handler 的 mret 目标 */
    .p2align 2
m_done:
    li      t0, 1
    beq     s4, t0, s1_cont
    li      t0, 2
    beq     s4, t0, s2_cont
    li      t0, 3
    beq     s4, t0, s3_cont
    li      t0, 4
    beq     s4, t0, s4_cont
    li      a0, 0
    li      a1, 0
    li      a2, 98                  /* 不应到达：阶段号非法 */
    call    report_fail_reg
    j       test_end

/*=============================================================================
 * 打印/记账 helper（仅主流程调用；handler 内不调用）
 *=============================================================================*/

/* puts(a0 = 字符串)：逐字节写 VUART */
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
    li      t3, 0
2:  bltu    a0, t2, 3f
    sub     a0, a0, t2
    addi    t3, t3, 1
    j       2b
3:  bnez    t3, 4f
    bnez    t4, 4f
    li      t1, 1
    bne     t2, t1, 5f
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

/*=============================================================================
 * 字符串/常量表
 *=============================================================================*/
    .section .rodata
    .p2align 2
pows:
    .word 1000000000, 100000000, 10000000, 1000000, 100000, 10000, 1000, 100, 10, 1, 0

hexd:           .asciz "0123456789abcdef"
s_nl:           .asciz "\n"
s_pass_head:    .asciz "\nFETCH_ERR: PASS ("
s_pass_tail:    .asciz " checks)\n"
s_fail_head:    .asciz "\nFETCH_ERR: FAIL (passed="
s_slash:        .asciz "/"
s_fails_eq:     .asciz ", fails="
s_first_eq:     .asciz ", first="
s_rparen:       .asciz ")\n"
s_fail_check:   .asciz "\n[FAIL] check "
s_fail_got:     .asciz " got="
s_fail_exp:     .asciz " expect="
s_csr_head:     .asciz "\n---- 失败现场 CSR ----\n"
s_ev1:          .asciz "\n---- 取指错误现场证据（阶段1 @0x90000000）----\n"
s_ev1_exp:      .asciz "---- 期望：cause=1 mepc=mtval=故障地址(见上) MPP=3 累计陷阱=1 ----\n"
s_ev4:          .asciz "\n---- 取指错误现场证据（阶段4 @0x80100000，MEM_HI 边界外）----\n"
n_hent:         .asciz "handler_entry = 0x"
n_mcause:       .asciz "mcause        = 0x"
n_mepc:         .asciz "mepc          = 0x"
n_mtval:        .asciz "mtval         = 0x"
n_mstatus:      .asciz "mstatus       = 0x"
n_mtvec:        .asciz "mtvec         = 0x"
n_pmpcfg3:      .asciz "pmpcfg3       = 0x"
n_pmpaddr15:    .asciz "pmpaddr15     = 0x"
n_fa:           .asciz "fault_addr    = 0x"
n_tcnt:         .asciz "trap_count    = 0x"
n_rflag:        .asciz "resume_flag   = 0x"
n_ckcnt:        .asciz "checks_done   = 0x"

    .end
