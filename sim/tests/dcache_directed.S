/*=============================================================================
 * dcache_directed.S —— L1 数据 Cache（rtl/mem/rv32_dcache.v）定向自测（纯汇编）
 *-----------------------------------------------------------------------------
 * 为什么用汇编：本测试要精确控制"同一地址的 store/load 交替""AMO 前后的 Cache 状态"
 * "CBO 作用在**已缓存**的行上""自改码 + fence.i"这些序列；C 编译器会插入额外的访存
 * 与重排，观察不到目标行为。
 *
 * 覆盖（对应 AGENT.md §7 ④ / 本轮任务的 5 条验证里的定向部分）：
 *   A 写直达一致性：store 后**立刻**读同址（字/半字/字节）
 *   B 同址 store→load→store→load 四次交替：每次都必须读到最新值（不能读到 Cache 旧值）
 *   C 跨行/非对齐：32 B 行边界附近的非对齐字写/读（核内拆成两次单拍），两侧哨兵不得被改
 *   D 原子（Zaamo/Zalrsc）在**已缓存行**上仍正确：
 *       · 先把该行读进 Cache（load 填充）
 *       · amoswap/amoadd/lr+sc 在该行上执行（RTL 里原子访问**整体绕 Cache**）
 *       · 随后 load 必须读到新值 —— 若 AMO/SC 的写完成没有**失效被写行**，这里会读到
 *         Cache 旧值 ⇒ FAIL（★ 标记的检查就是这条）
 *   E 自改码 + fence.i：先执行一版代码（把该行填入 I-Cache），用 store 改写同一地址
 *       （经 D 侧写直达落内存），fence.i 后执行同一地址必须看到**新版本**
 *   F CBO（Zicbom/Zicboz）作用在**已缓存**的行上：
 *       · cbo.zero：整块 32 B 清零，随后 load 必须读到 0
 *         （若 cbo.zero 只写内存、不更新/失效 Cache 行，load 会命中旧行读到旧图案 ⇒ FAIL）
 *       · cbo.inval / cbo.clean / cbo.flush：数据不得被破坏，失效后重取仍是写入值
 *
 * 运行约定（与 sim/tests/fencei_smc.S 同范式）：
 *   链接布局 : sim/tests/link.ld（_start @0x0 = 复位 PC）
 *   打印     : 0x1FAF_FF10 虚拟串口；退出码 : 0x1FAF_FF00（0 = 全过）
 *   判定模型 : 非快速失败。检查计数 s3；失败计数 s2（首个失败打印 id/got/exp）
 *   结束打印 : "DCACHE_DIRECTED: PASS (<n> checks)"
 *
 * 寄存器约定：s0=VUART s1=EXIT s2=失败数 s3=检查计数 s4=D1 s5=D2 s6=D3 s7/s8=失败现场
 *=============================================================================*/

#define VUART       0x1FAFFF10
#define EXIT_ADDR   0x1FAFFF00
#define D1          0x00080000      /* 主测试区（32 B 行对齐） */
#define D2          0x00080020      /* 第二行（跨行/非对齐） */
#define D3          0x00080100      /* CBO 块（32 B 对齐；块外哨兵在 D3+32） */

    .option norvc
    .section .text.init, "ax"
    .globl _start
    .type  _start, @function
_start:
    la      sp, _stack_top
    li      s0, VUART
    li      s1, EXIT_ADDR
    li      s2, 0
    li      s3, 0
    li      s4, D1
    li      s5, D2
    li      s6, D3

    la      t0, puts_
    la      a0, msg_title
    jal     ra, puts_tramp

/*--------------------------------------------------------------- A 写直达一致性 */
    li      t0, 0x11223344
    sw      t0, 0(s4)
    lw      t1, 0(s4)                 /* 立刻读同址 */
    li      a1, 0x11223344
    mv      a0, t1
    jal     ra, ck                    /* A1 写后立刻读（字） */

    lh      t1, 2(s4)
    li      a1, 0x1122
    mv      a0, t1
    jal     ra, ck                    /* A2 半字 */

    lbu     t1, 0(s4)
    li      a1, 0x44
    mv      a0, t1
    jal     ra, ck                    /* A3 字节 */

    li      t0, 0x99
    sb      t0, 1(s4)                 /* 只改字节 1：0x11223344 → 0x11229944 */
    lw      t1, 0(s4)
    li      a1, 0x0000FFFF
    and     a0, t1, a1
    li      a1, 0x9944
    jal     ra, ck                    /* A4 store 字节后立刻读 */

/*--------------------------------------------------------------- B 同址交替 4 轮 */
    li      t2, 0x0A0A0A0A
1:  sw      t2, 4(s4)
    lw      t1, 4(s4)
    mv      a0, t1
    mv      a1, t2
    jal     ra, ck                    /* B 每轮：store→load 必须一致 */
    addi    t2, t2, 1
    li      t3, 0x0A0A0A0E
    bne     t2, t3, 1b

/*--------------------------------------------------------------- C 跨行/非对齐 */
    /* D2 行 = [D2, D2+32)；在 D2+30 写非对齐字（字节 30..33，跨 32 B 行边界） */
    li      t1, 0xC0C0C0C0
    sw      t1, 28(s5)                /* 哨兵字（低侧） */
    sw      t1, 34(s5)                /* 哨兵字（高侧，紧贴非对齐字上沿） */
    li      t0, 0x55667788
    sw      t0, 30(s5)                /* 非对齐字，跨行 */
    lw      t1, 30(s5)
    mv      a0, t1
    li      a1, 0x55667788
    jal     ra, ck                    /* C1 非对齐跨行写后立刻读 */

    lbu     t1, 29(s5)
    li      a1, 0xC0
    mv      a0, t1
    jal     ra, ck                    /* C2 低侧哨兵未被越界写 */

    lbu     t1, 34(s5)
    li      a1, 0xC0
    mv      a0, t1
    jal     ra, ck                    /* C3 高侧哨兵未被越界写 */

/*--------------------------------------------------------------- D 原子在已缓存行上 */
    li      t0, 0x1000
    sw      t0, 8(s4)
    lw      t1, 8(s4)                 /* 读一遍：该行现在在 D-Cache 里 */
    mv      a0, t1
    li      a1, 0x1000
    jal     ra, ck                    /* D0 前置读回（该行已缓存） */

    li      a2, 0xB000B000
    amoswap.w a3, a2, (s4)            /* D1+0 ↔ a2；a3 = 旧值 */
    li      a1, 0x11229944
    mv      a0, a3
    jal     ra, ck                    /* D1 amoswap 返回旧值 */
    lw      t1, 0(s4)
    li      a1, 0xB000B000
    mv      a0, t1
    jal     ra, ck                    /* ★D2 AMO 后 load 必须看到新值（绕 Cache + 失效被写行） */

    li      a2, 0x00000010
    amoadd.w a3, a2, (s4)
    li      a1, 0xB000B000
    mv      a0, a3
    jal     ra, ck                    /* D3 amoadd 返回旧值 */
    lw      t1, 0(s4)
    li      a1, 0xB000B010
    mv      a0, t1
    jal     ra, ck                    /* ★D4 amoadd 后 load 看到新值 */

    lr.w    a3, (s4)
    li      a1, 0xB000B010
    mv      a0, a3
    jal     ra, ck                    /* D5 lr.w 读值 */
    li      a2, 0xCAFED00D
    sc.w    a4, a2, (s4)              /* 应成功 ⇒ a4 = 0 */
    mv      a0, a4
    li      a1, 0
    jal     ra, ck                    /* D6 sc.w 成功 */
    lw      t1, 0(s4)
    li      a1, 0xCAFED00D
    mv      a0, t1
    jal     ra, ck                    /* ★D7 SC 后 load 看到新值 */

/*--------------------------------------------------------------- E 自改码 + fence.i */
    la      t0, snip_a
    jalr    ra, 0(t0)                 /* 执行第一版（同时把该取指行填入 I-Cache） */
    li      a1, 0x000AA0AA
    mv      a0, a5
    jal     ra, ck                    /* E1 第一版立即数 */

    la      t0, snip_a
    la      t1, snip_b
    lw      t2, 0(t1)                 /* 把新版 16 B 拷到 snip_a 位置（D 侧写直达落内存） */
    sw      t2, 0(t0)
    lw      t2, 4(t1)
    sw      t2, 4(t0)
    lw      t2, 8(t1)
    sw      t2, 8(t0)
    lw      t2, 12(t1)
    sw      t2, 12(t0)
    fence.i                           /* I-Cache 整表失效 */
    la      t0, snip_a
    jalr    ra, 0(t0)
    li      a1, 0x000BB0BB
    mv      a0, a5
    jal     ra, ck                    /* ★E2 fence.i 后必须看到新版本 */

/*--------------------------------------------------------------- F CBO 作用在已缓存行 */
    li      t1, 0x77777777
    sw      t1, 32(s6)                /* 块外哨兵（下一 32 B 块首字） */
    li      t0, 0
2:  slli    t1, t0, 4
    ori     t1, t1, 0x0A5
    add     t1, t1, t0
    slli    t2, t0, 2
    add     t2, s6, t2
    sw      t1, 0(t2)
    addi    t0, t0, 1
    li      t3, 8
    blt     t0, t3, 2b
    lw      t1, 0(s6)
    li      a1, 0x00000A5
    mv      a0, t1
    jal     ra, ck                    /* F0 图案写入并读回（该行已在 Cache） */

    cbo.inval (s6)                    /* 失效该行（本设计无脏行 ⇒ 数据仍应正确） */
    lw      t1, 0(s6)
    li      a1, 0x00000A5
    mv      a0, t1
    jal     ra, ck                    /* F1 cbo.inval 后重取仍是写入值（无损坏） */

    cbo.clean (s6)
    lw      t1, 4(s6)
    li      a1, 0x00000B6
    mv      a0, t1
    jal     ra, ck                    /* F2 cbo.clean 后数据不变 */

    cbo.flush (s6)
    lw      t1, 8(s6)
    li      a1, 0x00000A7
    mv      a0, t1
    jal     ra, ck                    /* F3 cbo.flush 后数据不变 */

    lw      t1, 0(s6)                 /* 读一遍确保该行在 Cache 里 */
    cbo.zero (s6)                     /* ★ 32 B 清零：必须**穿过/更新 Cache** */
    lw      t1, 0(s6)
    mv      a0, t1
    li      a1, 0
    jal     ra, ck                    /* ★F4 cbo.zero 后 load 读到 0（块首） */
    lw      t1, 28(s6)
    mv      a0, t1
    li      a1, 0
    jal     ra, ck                    /* ★F5 cbo.zero 后 load 读到 0（块尾） */
    lw      t1, 32(s6)
    li      a1, 0x77777777
    mv      a0, t1
    jal     ra, ck                    /* F6 cbo.zero 不得动块外哨兵 */

/*--------------------------------------------------------------- 汇总 */
    beqz    s2, pass
    la      t0, puts_
    la      a0, msg_fail
    jal     ra, puts_tramp
    mv      a0, s2
    jal     ra, putdec
    la      t0, puts_
    la      a0, msg_of
    jal     ra, puts_tramp
    mv      a0, s3
    jal     ra, putdec
    la      t0, puts_
    la      a0, msg_nl
    jal     ra, puts_tramp
    li      a0, 1
    sw      a0, 0(s1)
3:  j       3b

pass:
    la      t0, puts_
    la      a0, msg_pass
    jal     ra, puts_tramp
    mv      a0, s3
    jal     ra, putdec
    la      t0, puts_
    la      a0, msg_nl
    jal     ra, puts_tramp
    li      a0, 0
    sw      a0, 0(s1)
4:  j       4b

/*--------------------------------------------------------------- 自改码片段（各 16 B，布局一致） */
    .balign 16
snip_a:
    lui     a5, 0x000AA
    addi    a5, a5, 0x0AA
    ret
    nop
    .balign 16
snip_b:
    lui     a5, 0x000BB
    addi    a5, a5, 0x0BB
    ret
    nop

/*--------------------------------------------------------------- 工具子程序 */
/* ck：a0 = got, a1 = exp；检查计数 s3++；不一致则 s2++，首个失败打印现场 */
    .type ck, @function
ck:
    addi    s3, s3, 1
    beq     a0, a1, ck_ret
    addi    s2, s2, 1
    li      t5, 1
    bne     s2, t5, ck_ret            /* 只打印第一个失败 */
    addi    sp, sp, -4                /* ★ 保存 ra：下面每个 jal 都会覆盖它 */
    sw      ra, 0(sp)
    mv      s7, a0
    mv      s8, a1
    la      t0, puts_
    la      a0, msg_ck
    jal     ra, puts_tramp
    mv      a0, s3
    jal     ra, putdec
    la      t0, puts_
    la      a0, msg_got
    jal     ra, puts_tramp
    mv      a0, s7
    jal     ra, puthex
    la      t0, puts_
    la      a0, msg_exp
    jal     ra, puts_tramp
    mv      a0, s8
    jal     ra, puthex
    la      t0, puts_
    la      a0, msg_nl
    jal     ra, puts_tramp
    lw      ra, 0(sp)
    addi    sp, sp, 4
ck_ret:
    ret

puts_tramp:
    jalr    zero, 0(t0)               /* t0 = 目标函数地址；被调函数 ret 回到本调用点 */

    .type puts_, @function
puts_:
    lbu     t1, 0(a0)
    beqz    t1, puts_ret
    sb      t1, 0(s0)
    addi    a0, a0, 1
    j       puts_
puts_ret:
    ret

    .type putdec, @function
putdec:                               /* 十进制打印（RV32M：divu/remu） */
    mv      t4, a0
    bnez    t4, pd_loop
    li      t1, 48
    sb      t1, 0(s0)
    ret
pd_loop:
    li      t3, 0
pd_collect:
    li      t2, 10
    remu    t1, t4, t2
    addi    t1, t1, 48
    addi    sp, sp, -4
    sw      t1, 0(sp)
    addi    t3, t3, 1
    divu    t4, t4, t2
    bnez    t4, pd_collect
pd_out:
    lw      t1, 0(sp)
    sb      t1, 0(s0)
    addi    sp, sp, 4
    addi    t3, t3, -1
    bnez    t3, pd_out
    ret

    .type puthex, @function
puthex:
    mv      t4, a0
    li      t3, 28
5:  srl     t1, t4, t3
    andi    t1, t1, 15
    li      t2, 10
    blt     t1, t2, 6f
    addi    t1, t1, 87                /* 'a' - 10 */
    j       7f
6:  addi    t1, t1, 48               /* '0' */
7:  sb      t1, 0(s0)
    addi    t3, t3, -4
    bgez    t3, 5b
    ret

    .section .rodata
msg_title:  .asciz "dcache directed: L1D tests\n"
msg_pass:   .asciz "DCACHE_DIRECTED: PASS ("
msg_fail:   .asciz "DCACHE_DIRECTED: FAIL ("
msg_ck:     .asciz "  [ck "
msg_got:    .asciz "] got="
msg_exp:    .asciz " exp="
msg_of:     .asciz " failed of "
msg_nl:     .asciz " checks)\n"
    .end
