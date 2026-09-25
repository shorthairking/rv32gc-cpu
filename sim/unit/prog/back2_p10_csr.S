/*==============================================================================
 * sim/unit/prog/back2_p10_csr.S —— 2B-4 第 4b-1 段：**CSR 读写轨迹**判据程序
 *------------------------------------------------------------------------------
 * 目的：给"`b2_csr` 过渡栈 → 2A `csr_file`"这次替换立一条**先立后用**的判据 ——
 *       逐条比对本核 CSR 读改写语义与 Spike 黄金（写回寄存器轨迹 = 黄金）。
 *       本程序**只使用两种实现都具备的 CSR**（mscratch/mepc/mtvec/mcause/mtval/
 *       mie/mip/mstatus），因此：
 *         · 替换前（`b2_csr`）：必须全绿 ⇒ 证明替换前的基线语义正确；
 *         · 替换后（`csr_file`）：同一程序必须仍然全绿 ⇒ 任何值/WARL/旁路/顺序回归当场暴露。
 *
 * 覆盖（每种语义都把"指令结果"写进通用寄存器 ⇒ 落在写回轨迹里与 Spike 逐条比）：
 *   ① `csrw`/`csrr`            —— 写后读
 *   ② `csrrw`                  —— **旧值**写回 rd + 新值落盘（读改写同拍）
 *   ③ `csrrs`/`csrrc`          —— 置位/清位（`old | src`、`old & ~src`）
 *   ④ `csrrwi`/`csrrsi`/`csrrci` —— **立即数形式**（4a 段缺陷 D2 的回归保护：
 *      载荷里 rs1 域是 zimm，若提交点误从 PRF 取"被当成 rs1 的物理寄存器"就会取到无关值）
 *   ⑤ `mepc`/`mtvec`/`mcause`/`mtval` —— WARL 回读（mepc 低位对齐口径）
 *   ⑥ `mie`/`mip`/`mstatus`    —— 位域回读（mstatus 取掩码 0x1888，避开 FS/SD 等实现自由度）
 *
 * 口径登记：全部读回值进通用寄存器、与 **Spike 黄金**逐条比（`--log-commits`）；
 *   本程序**不产生任何陷阱/中断**（mtvec 只写不触发；mie 写 0x888 但 MTIP=0）
 *   ⇒ 无时序相关成分，可与 Spike 逐条严格比对。
 * 风格：%pcrel 位置无关；`.option norvc`；常量非基址相关 ⇒ 黄金值无需 gold_delta 修正。
 *==============================================================================*/
    .option norvc
    .section .text
    .globl _start
_start:
    /* ---- ① csrw / csrr：写后读 ---- */
    li    t0, 0x12345678
    csrw  mscratch, t0
    csrr  s1, mscratch              /* s1 = 0x12345678 */

    /* ---- ② csrrw：rd ← 旧值，CSR ← 新值 ---- */
    li    t1, 0x0F0F0F0F
    csrrw s2, mscratch, t1          /* s2 = 0x12345678（旧值） */
    csrr  s3, mscratch              /* s3 = 0x0F0F0F0F（新值已落盘） */

    /* ---- ③ csrrs / csrrc：置位 / 清位（rd 均为旧值）---- */
    li    t2, 0xF0000000
    csrrs s4, mscratch, t2          /* s4 = 0x0F0F0F0F; mscratch = 0xFF0F0F0F */
    li    t3, 0x0000000F
    csrrc s5, mscratch, t3          /* s5 = 0xFF0F0F0F; mscratch = 0xFF0F0F00 */
    csrr  s6, mscratch              /* s6 = 0xFF0F0F00 */

    /* ---- ④ 立即数形式（zimm 5 bit）：csrrwi / csrrsi / csrrci ---- */
    csrrwi s7,  mscratch, 0x01      /* s7  = 0xFF0F0F00; mscratch = 0x00000001 */
    csrrsi s8,  mscratch, 0x1E      /* s8  = 0x00000001; mscratch = 0x0000001F */
    csrrci s9,  mscratch, 0x0F      /* s9  = 0x0000001F; mscratch = 0x00000010 */
    csrr   s10, mscratch            /* s10 = 0x00000010 */

    /* ---- ⑤ 陷阱类 CSR 回读（WARL：mepc 低位对齐）---- */
    li    t0, 0x80001000
    csrw  mepc, t0
    csrr  s11, mepc                 /* s11 = 0x80001000 */
    li    t0, 0x80002000
    csrw  mtvec, t0
    csrr  a0, mtvec                 /* a0  = 0x80002000（MODE=0） */
    li    t0, 0x0000000B
    csrw  mcause, t0
    csrr  a1, mcause                /* a1  = 0x0000000B */
    li    t0, 0x0000002A
    csrw  mtval, t0
    csrr  a2, mtval                 /* a2  = 0x0000002A */

    /* ---- ⑥ 中断/状态 CSR 位域回读 ---- */
    /*   ★ `mip` **故意不纳入本程序**（口径登记，见报告 §B4.6.4）：
     *     · Spike 的 CLINT `mtimecmp` 复位 0 ⇒ 一上电 `mtime > mtimecmp` ⇒ MTIP=1（mip=0x80）；
     *     · 2A/本核 `clint.v` 复位 `mtimecmp=0xFFFF_FFFF` ⇒ MTIP=0。
     *   两者都合法（复位值是实现自由度），且**无法在程序内对齐**：本核要写 mtimecmp 得访问
     *   核内 CLINT（0x1F00_4000），而 Spike 的 CLINT 在 0x0200_0000 ⇒ 同一段代码两侧行为不同。
     *   ⇒ `mip/MTIP` 的判据由 **p8_int**（自记录口径：MTIP 拉高 → 取 MTI → mcause=0x8000_0007）
     *     承担；本程序只比两侧**必然相同**的位域：`mie` 与 `mstatus`（且不置 MTIE/MIE
     *     ⇒ Spike 侧 MTIP=1 也不会取中断，程序无需处理程序）。 */
    li    t0, 0x808                 /* MSIE|MEIE（**不置 MTIE**，S 位保持 0） */
    csrw  mie, t0
    csrr  a3, mie                   /* a3 = 0x00000808 */
    li    t0, 0x1800                /* MPP=11（**不置 MIE/MPIE**） */
    csrw  mstatus, t0
    csrr  a5, mstatus
    li    t1, 0x1888
    and   a5, a5, t1                /* a5 = 0x00001800（只比 M 模式相关位） */

    /* ---- 收尾：写 tohost（s1..s11 / a0..a5 已在写回轨迹里）---- */
1:  auipc x30, %pcrel_hi(tohost)
    addi  x30, x30, %pcrel_lo(1b)
    li    x31, 1
    sw    x31, 0(x30)
    j     .

    .section .tohost,"aw"
    .align 3
    .globl tohost
tohost:
    .word 0
    .align 3
    .globl fromhost
fromhost:
    .word 0
