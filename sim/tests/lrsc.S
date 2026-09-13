/*=============================================================================
 * lrsc.S —— Zalrsc（LR/SC 保留集）+ Zaamo（AMO）执行通路定向自测（纯汇编）
 *
 * 为什么用汇编：保留集语义依赖**指令序列**（LR→SC 之间不能插入会清保留集的访存），
 * 且要覆盖 `sc.w rd, rs2, (rs1)` 中 rd/rs1/rs2 任意相同的情形。C 内联汇编会让 GCC
 * 插入 li/lw（普通访存 → 清保留集），测不到目标行为，故全部手写。
 *
 * 地址约定（固定，不依赖链接器布局）：
 *   SCRATCH  = 0x00080000（4 KiB 处，远离代码与栈 0x00080000 以下）
 *   SCRATCH2 = 0x00080010
 *   EXIT     = 0x1FAFFF00（平台退出码：0 = pass）
 *   陷阱处理程序记录 mcause/mtval 到 t3/t4（本测试专用观察寄存器）
 *
 * 判定：全部通过 → 退出码 0；任一失败 → 退出码 1 并停在失败标签处（可用调试 TB 看 PC）
 *=============================================================================*/

#define EXIT_ADDR  0x1FAFFF00

    .section .text.init, "ax"
    .globl _start
_start:
    lui     s0, 0x00080          /* s0 = 0x00080000 (SCRATCH)  */
    addi    s1, s0, 16           /* s1 = 0x00080010 (SCRATCH2) */
    la      t0, trap_handler
    csrw    mtvec, t0
    li      t3, 0
    li      t4, 0

/* 1) 同地址 LR→SC：rd=0（成功），内存 = rs2 */
    li      t0, 0x11111111
    sw      t0, 0(s0)
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    lr.w    t1, (s0)
    li      t2, 0x11111111
    bne     t1, t2, fail_1
    li      t1, 0xA5A5A5A5
    sc.w    a1, t1, (s0)
    bnez    a1, fail_2
    lw      t1, 0(s0)
    li      t2, 0xA5A5A5A5
    bne     t1, t2, fail_3

/* 2) rd = rs2 = 同一寄存器（arch-test Zalrsc-sc.w-00 cmp_rd_rs2 形态） */
    li      t0, 0x22222222
    sw      t0, 0(s0)
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    lr.w    a1, (s0)
    li      a1, 0x72926D9B
    sc.w    a1, a1, (s0)
    bnez    a1, fail_4
    lw      t1, 0(s0)
    li      t2, 0x72926D9B
    bne     t1, t2, fail_5

/* 3) rd = rs1 = rs2 = 同一寄存器（同时充当基址与数据） */
    li      t0, 0x33333333
    sw      t0, 0(s0)
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    lr.w    a1, (s0)
    mv      a1, s0
    sc.w    a1, a1, (a1)
    bnez    a1, fail_6
    lw      t1, 0(s0)
    mv      t2, s0
    bne     t1, t2, fail_7

/* 4) 地址不同：SC 失败（rd=1）且不写内存 */
    li      t0, 0x44444444
    sw      t0, 0(s0)
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    li      t0, 0x55555555
    sw      t0, 0(s1)
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    lr.w    a1, (s0)
    li      t1, 0xDEADBEEF
    sc.w    a2, t1, (s1)
    li      t2, 1
    bne     a2, t2, fail_8
    lw      t1, 0(s1)
    li      t2, 0x55555555
    bne     t1, t2, fail_9

/* 5) 普通 store 必须清保留集 */
    li      t0, 0x11111111
    sw      t0, 0(s0)
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    lr.w    a1, (s0)
    li      t0, 0x66666666
    sw      t0, 0(s0)
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    li      t1, 0x77777777
    sc.w    a2, t1, (s0)
    li      t2, 1
    bne     a2, t2, fail_10
    lw      t1, 0(s0)
    li      t2, 0x66666666
    bne     t1, t2, fail_11

/* 6) 成功的 SC 消费保留集：第二个（无新 LR）必须失败 */
    li      t0, 0x12121212
    sw      t0, 0(s0)
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    lr.w    a1, (s0)
    li      t1, 0x88888888
    sc.w    a2, t1, (s0)
    bnez    a2, fail_12
    li      t1, 0x99999999
    sc.w    a2, t1, (s0)
    li      t2, 1
    bne     a2, t2, fail_13
    lw      t1, 0(s0)
    li      t2, 0x88888888
    bne     t1, t2, fail_14

/* 7) 失败的 SC 也消费保留集 */
    li      t0, 0x13131313
    sw      t0, 0(s0)
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    li      t0, 0x14141414
    sw      t0, 0(s1)
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    lr.w    a1, (s0)
    li      t1, 0xAAAAAAAA
    sc.w    a2, t1, (s1)
    beqz    a2, fail_15
    sc.w    a2, t1, (s0)
    beqz    a2, fail_16
    lw      t1, 0(s0)
    li      t2, 0x13131313
    bne     t1, t2, fail_17

/* 8) 两次 LR：只有最后一次地址有效 */
    li      t0, 0x15151515
    sw      t0, 0(s0)
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    li      t0, 0x16161616
    sw      t0, 0(s1)
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    lr.w    a1, (s0)
    lr.w    a1, (s1)
    li      t1, 0xBBBBBBBB
    sc.w    a2, t1, (s0)
    beqz    a2, fail_18
    lw      t1, 0(s0)
    li      t2, 0x15151515
    bne     t1, t2, fail_19
    li      t1, 0xBBBBBBBB        /* 该值必须晚于上面那条 lw 载入，否则测的是旧 t1 */
    lr.w    a1, (s1)
    sc.w    a2, t1, (s1)
    bnez    a2, fail_20
    lw      t5, 0(s1)
    li      t2, 0xBBBBBBBB
    bne     t5, t2, fail_21

/* 9) AMO 读-改-写 */
    li      t0, 1
    sw      t0, 0(s0)
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    li      t1, 0x10
    amoadd.w a2, t1, (s0)
    li      t2, 1
    bne     a2, t2, fail_22
    lw      t1, 0(s0)
    li      t2, 0x11
    bne     t1, t2, fail_23
    li      t1, 0xFFFFFFFF
    amoswap.w a2, t1, (s0)
    li      t2, 0x11
    bne     a2, t2, fail_24
    lw      t1, 0(s0)
    li      t2, 0xFFFFFFFF
    bne     t1, t2, fail_25

/* 10) 原子地址非自然对齐 → cause=6，tval=原始 VA */
    li      t3, 0
    li      t4, 0
    addi    t0, s0, 2
    li      t1, 0x1234
    amoadd.w a2, t1, (t0)
    li      t2, 6
    bne     t3, t2, fail_26
    addi    t0, s0, 2
    bne     t4, t0, fail_27

/* 11) SC 地址非自然对齐 → cause=6（原子不可拆分） */
    lr.w    a1, (s0)             /* 先建保留集（对齐地址） */
    li      t3, 0
    addi    t0, s0, 2
    sc.w    a2, t1, (t0)
    li      t2, 6
    bne     t3, t2, fail_28

/* ---- 全部通过 ---- */
    li      t0, EXIT_ADDR
    sw      zero, 0(t0)
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    /* 同时写 tohost(0x80001000)：Spike 见到该写会正常退出（便于锁步比对）；
       低地址布局下该地址未映射，本核侧无副作用 */
    lui     t0, 0x80001
    sw      zero, 0(t0)
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
pass_loop:
    j       pass_loop

/* 失败标签统一宏：写平台退出码 1，再写 tohost(0x80001000) = 0x80000000+2*n
   （Spike 见此写会正常退出，锁步比对即可给出"第一个失败用例编号"）；
   随后死循环，PC 亦可用于定位。 */
.macro FAILTAG n
fail_\n:
    li      t0, EXIT_ADDR
    li      t1, 1
    sw      t1, 0(t0)
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    lui     t0, 0x80001
    li      t1, 0x80000000 + 2*\n
    sw      t1, 0(t0)
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
9:
    j       9b
.endm

FAILTAG 1
FAILTAG 2
FAILTAG 3
FAILTAG 4
FAILTAG 5
FAILTAG 6
FAILTAG 7
FAILTAG 8
FAILTAG 9
FAILTAG 10
FAILTAG 11
FAILTAG 12
FAILTAG 13
FAILTAG 14
FAILTAG 15
FAILTAG 16
FAILTAG 17
FAILTAG 18
FAILTAG 19
FAILTAG 20
FAILTAG 21
FAILTAG 22
FAILTAG 23
FAILTAG 24
FAILTAG 25
FAILTAG 26
FAILTAG 27
FAILTAG 28

/* 陷阱处理程序：记录 mcause/mtval 到 t3/t4，返回时越过 faulting 指令 */
    .p2align 2
trap_handler:
    csrr    t3, mcause
    csrr    t4, mtval
    csrr    t0, mepc
    addi    t0, t0, 4
    csrw    mepc, t0
    mret

    .end
