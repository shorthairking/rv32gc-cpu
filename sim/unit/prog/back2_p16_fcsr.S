/*==============================================================================
 * sim/unit/prog/back2_p16_fcsr.S —— 4c(2/3)：**fcsr 完整提交通路 + D 精度算术**
 *------------------------------------------------------------------------------
 * 目的（对 Spike `--isa=rv32imafdc_zicsr` 逐条黄金比对）：
 *   · **fflags 提交通路**：`csrw fflags,0` ⇒ 读回 0；制造 **NX**（1.0/3.0）⇒
 *     `csrr fflags` = 0x01（"FPU done ⇒ 提交级累积"真的落到 fcsr）；
 *   · **frm 读写 + DYN 生效**：`csrwi frm,1`（RTZ）⇒ 读回 1、`fcsr` = 0x21；
 *     `fcvt.w.s 3.5` 在 **frm=RTZ** 下 = 3、在 **frm=RNE** 下 = 4
 *     （⇒ 证明"软件写 frm 对 FPU 的 DYN 解析可见"，即 `csr_frm_w` 回灌闭环）；
 *   · **fcsr 整体**：`csrw fcsr, <frm|fflags>` 后逐字段读回（WARL 掩码 0xFF）；
 *   · **D 精度算术**：`fcvt.d.w → fadd.d/fmul.d → fcvt.s.d → fmv.x.w` 的
 *     64 bit 域闭环（D 数据通路 + 64 bit FP 写回），并用 `feq.d` 自检。
 *
 * 口径：
 *   · `.option norvc`；只用**静态可预期**的舍入（除 DYN 验证那两条外显式给 rm）；
 *   · **不含 fld/fsd**：8B 访存拆笔属 4c(3/3)（`lsq_simple` 单笔 32 bit）⇒ 本程序只用
 *     flw/fsw（S 精度访存），D 值全部经寄存器/转换产生（避免用未实现的通路"蒙"黄金）；
 *   · 首两条置 `mstatus.FS`（2A 侧 FS=Off 判 FP 非法指令；乱序核无该门 ⇒ 显式打开）；
 *   · 自检失败 ⇒ 跳到 `fail`（黄金比对立即分歧）；成功 ⇒ 写 tohost 并自跳转。
 * 寄存器自记录（TB/C 判据用）：
 *   x18(s2)=fflags 清零后读回 0      x19(s3)=NX 后 fflags=0x01   x20(s4)=fcsr=0x01
 *   x21(s5)=frm 写 1 后读回 1        x22(s6)=fcsr=0x21          x23(s7)=fcvt.w.s(3.5)@RTZ=3
 *   x24(s8)=fcvt.w.s(3.5)@RNE=4      x25(s9)=D 闭环结果（2*(3.0d)⇒6.0f 位型 0x40C00000）
 *==============================================================================*/
    .section .text
    .option norvc
    .globl _start
_start:
    li    x5, 0x2000                /* mstatus.FS = 01 (Initial) */
    csrs  mstatus, x5

1:  auipc x6, %pcrel_hi(darea)
    addi  x6, x6, %pcrel_lo(1b)

    /* ---- 0. fflags 清零：读回必须为 0 ---- */
    csrw  fflags, x0
    csrr  x18, fflags               /* 期望 0 */

    /* ---- 1. 制造 NX（1.0/3.0 不精确）⇒ fflags.NX 置位 ---- */
    li    x7, 0x3F800000            /* 1.0f */
    sw    x7, 0(x6)
    li    x7, 0x40400000            /* 3.0f */
    sw    x7, 4(x6)
    flw   f1, 0(x6)
    flw   f2, 4(x6)
    fdiv.s f3, f1, f2               /* f3 = 1/3（不精确 ⇒ NX）*/
    csrr  x19, fflags               /* 期望 0x01（NX）*/
    csrr  x20, fcsr                 /* 期望 0x01（frm=0, fflags=1）*/

    /* ---- 2. frm 写 1（RTZ）⇒ 读回 1、fcsr = (1<<5)|1 = 0x21 ---- */
    csrwi frm, 1
    csrr  x21, frm                  /* 期望 1 */
    csrr  x22, fcsr                 /* 期望 0x21 */

    /* ---- 3. DYN 生效：fcvt.w.s(3.5) 在 RTZ 下 = 3（RNE 下 = 4）---- */
    li    x7, 0x40600000            /* 3.5f */
    sw    x7, 8(x6)
    flw   f4, 8(x6)
    fcvt.w.s x23, f4                /* rm=DYN ⇒ 取 frm=RTZ ⇒ 3 */
    li    x7, 0                     /* 复位 frm=RNE（0）*/
    csrw  frm, x7
    fcvt.w.s x24, f4                /* rm=DYN ⇒ RNE ⇒ 4 */

    /* ---- 4. D 精度：fcvt.d.w(3) ⇒ fadd.d(3+3) ⇒ fmul.d(6*1) ⇒ fcvt.s.d ⇒ 位型 ---- */
    li    x8, 3
    fcvt.d.w f5, x8                 /* f5 = 3.0d（rm=DYN=RNE，精确）*/
    fadd.d f6, f5, f5               /* 6.0d */
    li    x9, 0x3FF0000000000000    /* 不能用 64 bit 立即数 ⇒ 用 fmul.d 与 1.0d */
    /*   1.0d 由 fcvt.d.w(1) 造出，再 fmul.d：6.0d * 1.0d = 6.0d */
    li    x10, 1
    fcvt.d.w f7, x10                /* f7 = 1.0d */
    fmul.d f8, f6, f7               /* 6.0d */
    fcvt.s.d f9, f8                 /* 6.0f = 0x40C00000 */
    fmv.x.w x25, f9                 /* 期望 0x40C00000 */

    /* ---- 5. D 比较自检（走错立即分歧）---- */
    li    x11, 0x40C00000
    bne   x25, x11, fail
    li    x12, 3
    bne   x23, x12, fail
    li    x12, 4
    bne   x24, x12, fail
    li    x12, 0x21
    bne   x22, x12, fail
    li    x12, 1
    bne   x21, x12, fail
    li    x12, 1
    bne   x19, x12, fail

    /* ---- 6. fcsr 整体写读（WARL 0xFF）：写 {frm=2(RDN), fflags=0x1F} ---- */
    li    x13, 0x5F                 /* (2<<5)|0x1F */
    csrw  fcsr, x13
    csrr  x26, fcsr                 /* 期望 0x5F */
    li    x12, 0x5F
    bne   x26, x12, fail

    /* ---- 收尾：写 tohost 并自跳转 ---- */
2:  auipc x30, %pcrel_hi(tohost)
    addi  x30, x30, %pcrel_lo(2b)
    li    x31, 1
    sw    x31, 0(x30)
    j     .

fail:
    li    x31, 0xDEAD
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
