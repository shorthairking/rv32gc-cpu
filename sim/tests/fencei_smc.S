/*=============================================================================
 * fencei_smc.S —— `fence.i` + 自修改代码（self-modifying code）定向自测
 *-----------------------------------------------------------------------------
 * 被验证的语义（RTL 侧见 rtl/top/rv32gc_core.v 的 fencei_take / rtl/frontend/
 * rv32_icache.v 的 invalidate）：
 *   `fence.i` 必须保证"其之前的 store 对其之后的**取指**可见"。本核第 18 轮起取指路径上
 *   有了 L1 指令 Cache（16 KB/128 组/4 路/32 B、VIPT、RR），若 `fence.i` 提交拍不做
 *   **整表失效**，则被改写过的那一行会从 Cache **命中旧指令**，本测试即失败。
 *
 * 为什么这条测试能抓住 Cache 未失效（构造要点）：
 *   ① 目标代码区（TARGET = 0x0004_0000）与测试代码（0x0 起）在**不同 32B 行** ⇒
 *      调用目标代码必定经"重定向 → 冲刷前端行缓冲 → 向 Cache 发起行请求"这条路，
 *      旧指令只可能来自 **Cache**（行缓冲已被冲刷）；
 *   ② 先执行一版代码（把该行**填入 Cache**），再改写同一行、`fence.i`、再执行同一地址；
 *      若 Cache 未失效 ⇒ 命中旧行 ⇒ 观察到的立即数是旧版。
 *
 * 观测手段：注入片段（4 条 RV32I，16 B）形如
 *       lui  a5, hi ; addi a5, a5, lo ; sw a5, 0(s5) ; jalr x0, 0(ra)
 *   执行后：a5 = 版本常量、内存 [MARKER] = 同一常量。因此"取到旧指令"与"取到新指令"
 *   在 a5 与内存标记上都可直接判定。
 *
 * 四个阶段（每阶段 2 条检查：a5 立即数 + 内存标记与 a5 相等）：
 *   阶段 1：TARGET+0  ← 版本 A，fence.i，调用 → 期望 A（同时把该行填进 Cache）
 *   阶段 2：TARGET+0  ← 版本 B，fence.i，调用 → 期望 B  ★关键检查（Cache 未失效必失败）
 *   阶段 3：TARGET+16 ← 版本 C（与阶段 1/2 **同一 32B 行**），fence.i，调用 → 期望 C
 *   阶段 4：TARGET+16 ← 版本 D，fence.i，调用 → 期望 D
 *
 * 运行约定（与 sim/tests/fetch_err.S 同范式）：
 *   链接布局 : sim/tests/link.ld（_start @0x0 = 复位 PC；sp = 0x0008_0000）
 *   打印     : 0x1FAF_FF10 虚拟串口（写一字节 → TB $write("%c")）
 *   退出码   : 0x1FAF_FF00（0 = 全部通过；非 0 = 首个失败项编号）
 *   陷阱向量 : mtvec = mh（direct）；本测试**不应**发生任何陷阱，
 *              一旦发生即记为失败并跳到汇总（避免死循环）。
 *   判定模型 : 非快速失败。通过 → t6++；失败 → s2++ 并打印 "[FAIL] check <id> got=<v> expect=<v>"。
 *              结束时 s2 == 0 → 打印 "FENCEI_SMC: PASS (<t6> checks)" 并写退出码 0。
 *   环境约束 : 纯 RV32I + Zicsr + Zifencei（不加 C、不放松链接），
 *              -mno-relax 保证 la/li 形态可控（本测试用 li 构造确定性立即数）。
 *
 * 寄存器约定：
 *   s0=VUART s1=EXIT s2=失败数 s3=首个失败 id s4=TARGET 入口 s5=MARKER 地址
 *   s6=阶段号 a4/a5=陷阱现场 a6/a7 由检查宏内部使用（不要跨调用保存活值）
 *   t0-t5,a0-a3 被 puts/puthex/检查宏 clobber
 *=============================================================================*/

#define VUART       0x1FAFFF10
#define EXIT_ADDR   0x1FAFFF00
#define TARGET      0x00040000          /* 注入代码区（32 B 对齐；在 .bss/栈之外） */
#define MARKER      0x00030000          /* 结果标记字（内存观测点） */

    .option norvc
    .section .text.init, "ax"
    .globl _start
    .type  _start, @function

/*=============================================================================
 * 宏：把一段 4 字片段写到 base+off（base 为寄存器，off 为字节偏移）
 *=============================================================================*/
.macro SNIPPET base, off, w0, w1, w2, w3
    li      t0, \w0
    sw      t0, \off+0(\base)
    li      t0, \w1
    sw      t0, \off+4(\base)
    li      t0, \w2
    sw      t0, \off+8(\base)
    li      t0, \w3
    sw      t0, \off+12(\base)
.endm

/* 检查宏（复刻 sim/tests/fetch_err.S 的 CKI/CKR） */
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

/*=============================================================================
 * 入口
 *=============================================================================*/
_start:
    li      sp, 0x00080000
    la      t0, mh
    csrw    mtvec, t0
    li      s0, VUART
    li      s1, EXIT_ADDR
    li      s2, 0                   /* 失败数 */
    li      s3, 0                   /* 首个失败 id */
    li      s4, TARGET
    li      s5, MARKER
    li      s6, 0                   /* 阶段号 */
    li      a4, 0
    li      a5, 0
    li      t6, 0                   /* 检查数 */
    csrw    mstatus, zero
    csrw    mie, zero

    la      a0, s_head
    call    puts

/*-----------------------------------------------------------------------------
 * 阶段 1：版本 A 写入 TARGET+0 → fence.i → 调用 → 期望 A
 *   片段：lui a5,0xAAAA1 / addi a5,a5,0x111 / sw a5,0(s5) / jalr x0,0(ra)
 *---------------------------------------------------------------------------*/
    li      s6, 1
    li      a5, 0
    SNIPPET s4, 0,  0xAAAA17B7, 0x11178793, 0x00FAA023, 0x00008067
    fence.i
    li      t0, TARGET
    jalr    ra, 0(t0)
    lw      t2, 0(s5)
    CKI     a5, 0xAAAA1111, 101
    CKR     t2, a5,         102

/*-----------------------------------------------------------------------------
 * 阶段 2 ★关键：同一地址改写为版本 B → fence.i → 再执行一次
 *   若 L1I 未失效，这里命中的是阶段 1 填入的旧行（a5 = 0xAAAA1111）
 *---------------------------------------------------------------------------*/
    li      s6, 2
    li      a5, 0
    SNIPPET s4, 0,  0xBBBB27B7, 0x22278793, 0x00FAA023, 0x00008067
    fence.i
    li      t0, TARGET
    jalr    ra, 0(t0)
    lw      t2, 0(s5)
    CKI     a5, 0xBBBB2222, 201
    CKR     t2, a5,         202

/*-----------------------------------------------------------------------------
 * 阶段 3：同一条 32B 行的**后半**（TARGET+16）写入版本 C → fence.i → 调用
 *---------------------------------------------------------------------------*/
    li      s6, 3
    li      a5, 0
    SNIPPET s4, 16, 0xCCCC37B7, 0x33378793, 0x00FAA023, 0x00008067
    fence.i
    li      t0, TARGET+16
    jalr    ra, 0(t0)
    lw      t2, 0(s5)
    CKI     a5, 0xCCCC3333, 301
    CKR     t2, a5,         302

/*-----------------------------------------------------------------------------
 * 阶段 4：同一条行后半再改写为版本 D → fence.i → 调用
 *---------------------------------------------------------------------------*/
    li      s6, 4
    li      a5, 0
    SNIPPET s4, 16, 0xDDDD47B7, 0x44478793, 0x00FAA023, 0x00008067
    fence.i
    li      t0, TARGET+16
    jalr    ra, 0(t0)
    lw      t2, 0(s5)
    CKI     a5, 0xDDDD4444, 401
    CKR     t2, a5,         402

/*-----------------------------------------------------------------------------
 * 对照：正常（非自修改）路径不受影响 —— 编译期常量代码照常执行
 *---------------------------------------------------------------------------*/
    li      s6, 5
    li      t3, 0x5A5A5A5A
    CKI     t3, 0x5A5A5A5A, 501

/*=============================================================================
 * 汇总与退出
 *=============================================================================*/
test_end:
    bnez    s2, fail_report
    la      a0, s_pass_head
    call    puts
    mv      a0, t6
    call    putu32
    la      a0, s_pass_tail
    call    puts
    sw      zero, 0(s1)
9:  j       9b

fail_report:
    la      a0, s_fail_head
    call    puts
    mv      a0, t6
    call    putu32
    la      a0, s_fails_eq
    call    puts
    mv      a0, s2
    call    putu32
    la      a0, s_first_eq
    call    puts
    mv      a0, s3
    call    putu32
    la      a0, s_rparen
    call    puts
    la      a0, s_stage
    call    puts
    mv      a0, s6
    call    putu32
    la      a0, s_nl
    call    puts
    la      a0, s_csr_head
    call    puts
    csrr    a2, mcause
    la      a0, s_mcause
    call    puts
    mv      a0, a2
    call    puthex8
    la      a0, s_nl
    call    puts
    csrr    a2, mepc
    la      a0, s_mepc
    call    puts
    mv      a0, a2
    call    puthex8
    la      a0, s_nl
    call    puts
    csrr    a2, mtval
    la      a0, s_mtval
    call    puts
    mv      a0, a2
    call    puthex8
    la      a0, s_nl
    call    puts
    sw      s3, 0(s1)               /* 退出码 = 首个失败项编号 */
8:  j       8b

/*=============================================================================
 * 陷阱处理：本测试不应发生陷阱；一旦发生即记失败并直接汇总（防死循环）
 *=============================================================================*/
    .p2align 2
mh:
    csrr    a4, mcause
    csrr    a5, mepc
    li      t0, 90
    blt     a4, t0, 1f
    li      t0, 99                  /* 中断：编号 99 */
    j       2f
1:  addi    t0, a4, 90              /* 同步异常：编号 = 90 + cause */
2:  li      s2, 1
    beqz    s3, 3f
    j       4f
3:  mv      s3, t0
4:  la      a0, s_trap
    call    puts
    mv      a0, t0
    call    putu32
    la      a0, s_nl
    call    puts
    j       test_end

/*=============================================================================
 * 辅助函数（与 sim/tests/fetch_err.S 同款，s0 = VUART）
 *=============================================================================*/
puts:
    mv      t0, a0
1:  lbu     t1, 0(t0)
    beqz    t1, 2f
    sb      t1, 0(s0)
    addi    t0, t0, 1
    j       1b
2:  ret

/* putu32(a0 = 无符号十进制) */
putu32:
    addi    sp, sp, -16
    sw      ra, 12(sp)
    la      t5, pows
    li      t4, 0
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

/* report_fail_reg(a0=实际值, a1=期望值, a2=检查编号) */
report_fail_reg:
    addi    sp, sp, -32
    sw      ra, 28(sp)
    sw      a0, 0(sp)
    sw      a1, 4(sp)
    sw      a2, 8(sp)
    addi    s2, s2, 1
    bnez    s3, 1f
    mv      s3, a2
1:  la      a0, s_fail_check
    call    puts
    mv      a0, a2
    call    putu32
    la      a0, s_fail_got
    call    puts
    lw      a0, 0(sp)
    call    puthex8
    la      a0, s_fail_exp
    call    puts
    lw      a0, 4(sp)
    call    puthex8
    la      a0, s_nl
    call    puts
    lw      ra, 28(sp)
    addi    sp, sp, 32
    ret

/*=============================================================================
 * 常量/字符串
 *=============================================================================*/
    .section .rodata
    .p2align 2
pows:
    .word   1000000000, 100000000, 10000000, 1000000, 100000, 10000, 1000, 100, 10, 1, 0
hexd:
    .asciz  "0123456789abcdef"
s_head:      .asciz  "\nFENCEI_SMC start (L1I self-modifying-code directed test)\n"
s_pass_head: .asciz  "\nFENCEI_SMC: PASS ("
s_pass_tail: .asciz  " checks)\n"
s_fail_head: .asciz  "\nFENCEI_SMC: FAIL (checks="
s_fails_eq:  .asciz  ", fails="
s_first_eq:  .asciz  ", first_id="
s_rparen:    .asciz  ")"
s_stage:     .asciz  " stage="
s_fail_check:.asciz  "\n[FAIL] check "
s_fail_got:  .asciz  " got="
s_fail_exp:  .asciz  " expect="
s_csr_head:  .asciz  "  traps: mcause="
s_mcause:    .asciz  " mcause="
s_mepc:      .asciz  " mepc="
s_mtval:     .asciz  " mtval="
s_trap:      .asciz  "\n[TRAP] unexpected trap, id="
s_nl:        .asciz  "\n"
