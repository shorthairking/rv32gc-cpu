/*==============================================================================
 * sim/unit/prog/back2_p4_fpu.S —— 2B-4 锁步程序④：RV32F 算术 / 比较 / 访存混合流
 *------------------------------------------------------------------------------
 * 目的：把乱序核的 **FPU 执行 / 写回 / 唤醒** 与 **FP 访存（flw/fsw）** 路径纳入锁步比对
 *       （2B-2/2B-3 的三个程序全是整数流，FP 通路从未被锁步覆盖）：
 *   · 单精度算术：FADD / FSUB / FMUL / FDIV / FSQRT / FMIN / FMAX / FSGNJ*；
 *   · FMA 族：FMADD / FMSUB / FNMADD / FNMSUB（单次舍入，与 fpu.v 的 26–29 扩展编码对应）；
 *   · 比较（feq/flt/fle ⇒ **整数**寄存器）与搬移/转换（fmv.x.w / fmv.w.x / fcvt.s.w / fcvt.w.s）；
 *   · flw / fsw 访存 + **同址 flw 读回**（FP 数据域的 store→load 转发）+ 依赖链循环。
 *
 * 口径（与 gen_back2_lockstep_data.py 头注同步）：
 *   · `.option norvc`：2A 基线核不支持"32 bit 指令起始于奇 parcel"（C 混合流会永久停住）；
 *   · 只用**静态舍入 RNE**（复位默认 frm=0）：不写 frm；
 *   · **不读/写 fflags / fcsr**：2B-3 未验证其"FPU done ⇒ 提交级累积"路径，留作后续段
 *     （本程序因此只覆盖"结果/写回/访存"，不覆盖浮点异常标志）；
 *   · 首两条先置 `mstatus.FS = Initial`：2A 侧 FS=Off 会把 FP 指令判非法指令
 *     （core_top.v `d_fs_off_ill`），而乱序核无该门 ⇒ 必须显式打开，两核才同语义。
 *==============================================================================*/
    .section .text
    .option norvc
    .globl _start
_start:
    li    x5, 0x2000            /* mstatus.FS = 01 (Initial) */
    csrs  mstatus, x5           /* rd = x0 ⇒ 不产生架构写回（C1 不受影响） */

1:  auipc x6, %pcrel_hi(darea)
    addi  x6, x6, %pcrel_lo(1b)

    /* ---- 常数（用整数 store 造 FP 位型，再 flw 取回）---- */
    li    x7, 0x3F800000        /* 1.0f  */
    sw    x7, 0(x6)
    li    x7, 0x40000000        /* 2.0f  */
    sw    x7, 4(x6)
    li    x7, 0x40600000        /* 3.5f  */
    sw    x7, 8(x6)
    li    x7, 0xBF000000        /* -0.5f */
    sw    x7, 12(x6)
    sw    x0, 16(x6)            /* 0.0f  */

    flw   f1,  0(x6)            /* 1.0  */
    flw   f2,  4(x6)            /* 2.0  */
    flw   f3,  8(x6)            /* 3.5  */
    flw   f4,  12(x6)           /* -0.5 */
    flw   f5,  16(x6)           /* 0.0  */
    flw   f22, 16(x6)           /* 累加器 = 0.0 */

    /* ---- 算术链（含 RAW 依赖 ⇒ 走 FPU done/wakeup 通路）---- */
    fadd.s   f6,  f1,  f2       /* 3.0        */
    fsub.s   f7,  f3,  f1       /* 2.5        */
    fmul.s   f8,  f2,  f3       /* 7.0        */
    fdiv.s   f9,  f3,  f2       /* 1.75       */
    fsqrt.s  f10, f2            /* sqrt(2)    */
    fadd.s   f11, f6,  f7       /* 5.5        */
    fmul.s   f12, f11, f4       /* -2.75      */
    fsub.s   f13, f12, f1       /* -3.75      */
    fmin.s   f14, f1,  f4       /* -0.5       */
    fmax.s   f15, f1,  f4       /* 1.0        */
    fsgnj.s  f16, f1,  f4       /* -1.0（取 f4 符号位）*/
    fsgnjn.s f17, f1,  f4       /* 1.0        */
    fsgnjx.s f18, f1,  f4       /* -1.0       */
    fmadd.s  f19, f2,  f3, f1   /* 2*3.5+1 = 8.0    */
    fmsub.s  f20, f2,  f3, f1   /* 2*3.5-1 = 6.0    */
    fnmadd.s f21, f2,  f3, f1   /* -(2*3.5)-1 = -8.0 */
    fnmsub.s f23, f2,  f3, f1   /* -(2*3.5)+1 = -6.0 */

    /* ---- 比较 ⇒ 整数寄存器 ---- */
    feq.s  x8,  f1, f2          /* 0 */
    flt.s  x9,  f1, f2          /* 1 */
    fle.s  x10, f3, f3          /* 1 */
    feq.s  x11, f5, f5          /* 1（+0 == +0）*/

    /* ---- 搬移 / 转换 ---- */
    fmv.x.w  x12, f6            /* 0x40400000 */
    fcvt.w.s x13, f9, rtz       /* 1  */
    li       x14, 5
    fcvt.s.w f24, x14           /* 5.0 */
    fmv.w.x  f25, x14           /* 位型 0x00000005 */
    fcvt.w.s x15, f12, rtz      /* -2 */

    /* ---- FP 访存：fsw 落数据区 ---- */
    fsw   f6,  20(x6)
    fsw   f8,  24(x6)
    fsw   f9,  28(x6)
    fsw   f10, 32(x6)
    fsw   f19, 36(x6)
    fsw   f24, 40(x6)
    fsw   f25, 44(x6)
    sw    x15, 48(x6)

    /* ---- 同址 flw 读回（FP store→load 转发）+ 依赖 ---- */
    flw   f26, 20(x6)           /* 应等于 f6（3.0）*/
    flw   f27, 24(x6)           /* 应等于 f8（7.0）*/
    feq.s x16, f26, f6          /* 1 ⇒ 转发正确 */
    fadd.s f28, f26, f27        /* 10.0 */
    fsw   f28, 52(x6)

    /* ---- 依赖链循环：f22 = 2*(f22+1)，6 次 ⇒ 126.0 ---- */
    li    x17, 0
    li    x18, 6
2:
    fadd.s f22, f22, f1
    fmul.s f22, f22, f2
    addi  x17, x17, 1
    bne   x17, x18, 2b
    fsw   f22, 56(x6)

    /* ---- 收尾：写 tohost 并自跳转 ---- */
3:  auipc x30, %pcrel_hi(tohost)
    addi  x30, x30, %pcrel_lo(3b)
    li    x31, 1
    sw    x31, 0(x30)
    j     .

    .section .data,"aw"
    .align 3
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
