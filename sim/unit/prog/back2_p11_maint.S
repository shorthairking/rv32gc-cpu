/*==============================================================================
 * sim/unit/prog/back2_p11_maint.S —— 2B-4 第 4b-2a 段：**维护操作语义**（黄金可比）
 *------------------------------------------------------------------------------
 * 覆盖：`fence.i`（L1I 全阵列失效 + 冻结扫掠）与 `sfence.vma`（TLB 全失效 + L1D 失效），
 *       以及"维护操作按**提交序**执行"的核心语义：**紧跟其后的取指/访存必须看到新状态**。
 * 判据（TB C11'，见报告 §B4.9）：
 *   · 提交 PC 流 + 写回寄存器轨迹 = **Spike 黄金逐条一致**（维护操作本身照常提交；
 *     若"冲刷 + 重定向到头部 PC+4"写错，PC 流会丢/重一条 ⇒ C1' 当场分歧）
 *   · 维护动作脉冲计数：`maint_cmt` = 5（3×fence.i + 2×sfence.vma）、`maint_l1i_inval` ≥ 256×3、
 *     `maint_tlb_sfence` ≥ 2、`maint_l1d_inval` ≥ 2
 * Spike 可比性：`--isa=rv32imac_zicsr_zifencei`（本轮探针已实测两者均合法且正常提交）；
 *   `cbo.*` 因 Spike 不支持（探针实测：即使 --isa 含 zicbom 也判非法）另立程序 `p12_cbo.S`。
 * 风格：%pcrel 位置无关；`.option norvc`
 *==============================================================================*/
    .option norvc
    .section .text
    .globl _start
_start:
    /* ---- 0. 建立数据依赖（初始 0x11223344 存进 darea）---- */
    la    s0, darea
    li    t0, 0x11223344
    sw    t0, 0(s0)
    lw    s1, 0(s0)                 /* s1 = 0x11223344 */

    /* ---- 1. fence.i：L1I 全失效 + 冻结扫掠 + 重定向到下一条 ---- */
    fence.i
    lw    s2, 0(s0)                 /* 维护后访存照常：0x11223344 */
    addi  t2, x0, 1                 /* ★ 维护操作之间插入 ≥6 条无关指令：
    addi  t3, x0, 2                  *   避免两条维护操作落在**同一提交窗口**
    addi  t4, x0, 3                  *   （该情形命中本段定位的阻塞 K1，见报告 §B4.9.3）
    addi  t5, x0, 4                  */
    addi  t6, x0, 5
    addi  a0, x0, 6

    /* ---- 2. sfence.vma（rs1=rs2=x0：全失效）---- */
    sfence.vma x0, x0
    lw    s3, 0(s0)                 /* 0x11223344 */
    addi  t2, t2, 1
    addi  t3, t3, 1
    addi  t4, t4, 1
    addi  t5, t5, 1
    addi  t6, t6, 1
    addi  a1, x0, 7

    /* ---- 3. sfence.vma（带 rs1 变体：VA 精确形式）---- */
    la    t1, darea
    addi  a2, x0, 8
    addi  a3, x0, 9
    sfence.vma t1, x0
    lw    s4, 0(s0)                 /* 0x11223344 */
    addi  a4, x0, 10
    addi  a5, x0, 11
    addi  a6, x0, 12
    addi  a7, x0, 13
    addi  s7, x0, 14
    addi  s8, x0, 15

    /* ---- 4. 再一次 fence.i（与前一条已隔开）---- */
    fence.i
    addi  s5, s1, 1                 /* s5 = 0x11223345（后续指令照常执行） */
    lw    s6, 0(s0)                 /* 0x11223344 */
    addi  s9,  x0, 16
    addi  s10, x0, 17
    addi  s11, x0, 18

    /* ---- 收尾 ---- */
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
