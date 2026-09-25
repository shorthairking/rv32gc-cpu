/*==============================================================================
 * sim/unit/prog/back2_p14_storepf.S —— 2B-4 第 4b-2c 段收口：**store 页错误精确化**
 *------------------------------------------------------------------------------
 * 目标（报告 §B4.26）：store 到**未映射页** ⇒ 经数据适配器的执行期翻译发现故障后，
 *   以 **cause 15（store/AMO page fault）+ mtval = 故障 VA** 在**故障指令处精确抛出**
 *   （mepc = 该 `sw` 的 PC），且**不写任何存储、不污染任何已提交状态**、陷阱返回后
 *   继续执行。对应 RTL 改动：`lsq_simple` 的"提交窗翻译定妥门" + `upd_exc` cause 15 通道。
 *
 * ★ 有 Spike 黄金（与本目录其它程序同法）：本程序**不含 A=0/SVADE、不含 sfence 重映射、
 *   不含 cbo/中断**等微架构相关形态 ⇒ 提交 PC 流与写回寄存器轨迹应与 Spike 逐条一致。
 *
 * 覆盖范围：
 *   · 两级页表自建（root/l1 各占独立 4 KB 页；l1[0] 为合法叶，**l1[1..2] 故意不建**）
 *   · 译后 load/store/load（VA 0x4000_0100 → PA l1 页 +0x100）—— 与 store 故障对照
 *   · **未映射 VA 的 store ⇒ cause 15、mtval = 0x4000_2000、mepc = 故障 `sw` 的 PC**
 *     （程序自证：handler 里 `sub a6, mepc, s8`，期望 4 = auipc 与 sw 的间距）
 *   · 陷阱精确返回后继续（a0 = 1 自记录）
 *   · 4 MB 恒等大页覆盖程序/页表自身（打开 satp 后在途的旧 store 仍能正确翻译）
 * 不覆盖（登记）：取指翻译（需 S 模式执行流）、A=0 的 SVADE 形态（p13 已覆盖）、
 *   AMO/LR-SC 的页错误（本里程碑无 AMO）。
 *
 * ★ 存储布局（`.bss`，不进映像）：root @链接 +0x2000 / l1 @+0x3000（4 KB 对齐）
 *   ⇒ 程序被 TB 装到基址 0x8002_8000 时两页 = 0x8002_A000 / 0x8002_B000。
 * 风格：%pcrel 位置无关；`.option norvc`
 *==============================================================================*/
    .option norvc
    .section .text
    .globl _start
_start:
    /* ---- 0. 陷阱入口 + PMP（PTE 读与数据访问按有效特权级过 PMP ⇒ 必须放行）---- */
    la    t0, trap_handler
    csrw  mtvec, t0
    li    t0, -1
    csrw  0x3b0, t0                 /* pmpaddr0 = 0xFFFF_FFFF（NAPOT ⇒ 覆盖全空间） */
    li    t0, 0x1F
    csrw  0x3a0, t0                 /* pmpcfg0 = A=NAPOT|X|W|R（不锁） */

    /* ---- 1. 建两级页表（satp=0 ⇒ Bare，访问不翻译）----
     *   ★★ 页表用**绝对地址**（`li` 立即数，不用 `la`/`auipc`）：本程序**有 Spike 黄金**，
     *     而 TB 的寄存器轨迹比对只能补偿"未做算术的 PC 相对量"（`+gold_delta`）；
     *     `la` 得到的基址若再经 `srli/slli` 造 PTE，位移会把 delta 也一起缩放 ⇒ 无法补偿。
     *     用绝对地址后，DUT（槽位基址 0x8002_8000）与 Spike（基址 0x8000_0000）执行的是
     *     **同一组立即数** ⇒ 写回轨迹逐位一致。布局：root = 槽位+0x2000、l1 = +0x3000。 */
    li    s0, 0x8002A000            /* root（4 KB 对齐）*/
    li    s1, 0x8002B000            /* l1  （4 KB 对齐）*/
    srli  t1, s1, 12
    slli  t1, t1, 10
    ori   t1, t1, 1                 /* 非叶项：PPN(l1)<<10 | V */
    li    t2, 0x100                 /* VPN1(0x4000_0000) = 0x100 */
    slli  t2, t2, 2
    add   t2, s0, t2
    sw    t1, 0(t2)                 /* root[0x100] → l1 */
    srli  t1, s1, 12
    slli  t1, t1, 10
    ori   t1, t1, 0xC7              /* 叶项：PPN(l1 页)<<10 | D|A|W|R|V（A/D 预置 1）*/
    sw    t1, 0(s1)                 /* l1[0] → l1 页 */
    /*   ★ TB 的 DDR 填充是 nop（0x0000_0013 = V=1/R=1/U=1/A=0）⇒ **必须显式清零**
     *     l1[1]/l1[2]，否则"未映射"会退化成"W=0 权限错/ A=0 页错误"（虽同为 cause 15，
     *     但不是本用例的"V=0 未映射"口径）。 */
    sw    x0, 8(s1)                 /* l1[1] = 0（未映射）*/
    sw    x0, 16(s1)                /* l1[2] = 0（未映射）*/
    /*   4 MB 恒等映射 VA 0x8000_0000 → PA 0x8000_0000（程序自身/页表所在段）*/
    li    t1, 0x80000000
    srli  t1, t1, 12
    slli  t1, t1, 10
    ori   t1, t1, 0xCF              /* D|A|X|W|R|V（PPN[0]=0 ⇒ 合法大页）*/
    li    t2, 0x200                 /* root[VPN1(0x8000_0000)=0x200] */
    slli  t2, t2, 2
    add   t2, s0, t2
    sw    t1, 0(t2)

    /* ---- 2. 数据槽初值（Bare 直写 PA）---- */
    li    t1, 0x11223344
    sw    t1, 0x100(s1)             /* l1 页 +0x100 */

    /* ---- 3. 打开数据侧翻译：MPRV=1、MPP=S；satp = Sv32(root) ---- */
    li    t1, 0x00020800            /* (1<<17) MPRV | (1<<11) MPP=01(S) */
    csrw  mstatus, t1
    srli  t1, s0, 12
    li    t2, 0x80000000
    or    t1, t1, t2
    csrw  satp, t1

    /* ---- 4. 对照：译后 load / store / load（VA 0x4000_0100 → PA l1 页 +0x100）---- */
    li    s4, 0x40000100
    lw    s5, 0(s4)                 /* s5 = 0x11223344 */
    li    t1, 0xDEADBEEF
    sw    t1, 0(s4)                 /* 译后 store（**成功**，用于"未污染"对照）*/
    lw    s6, 0(s4)                 /* s6 = 0xDEADBEEF */

    /* ---- 5. ★★ store 到未映射页 ⇒ **精确 store 页错误（cause 15）** ----
     *   VPN0=2 ⇒ l1[2]=0 ⇒ V=0 ⇒ 页错误。`auipc s8, 0` 记录本指令 PC ⇒
     *   陷阱处理里 `sub a6, mepc, s8` 期望 **4**（证明 mepc 恰为下面这条 `sw`）。*/
    li    s7, 0x40002000            /* 未映射 VA（l1[2] 未建）*/
    li    t1, 0xCAFEBABE            /* 待写值：**绝不允许**出现在任何存储里 */
    auipc s8, 0
    sw    t1, 0(s7)                 /* ← 故障指令：store page fault */
    li    a0, 0x1                   /* 陷阱精确返回后继续（自记录）*/

    /* ---- 6. 关翻译，直读 PA：确认"未污染 + 译后 store 已落地" ----
     *   ★★ **CSR 可见性串行化**（本程序实测踩到，属 RTL 已知边界，见报告 §B4.26.5）：
     *     本核 CSR 只在提交点更新，而访存的翻译上下文在**执行期**读取 ⇒ 若下面的 load
     *     在 `csrw mstatus` 提交**之前**执行，会按**旧的** MPRV=1/MPP=U 去翻译（而这段
     *     代码本应"Bare 直读 PA"）⇒ 误报 load 页错误。修法（程序侧、不改判据）：
     *     让访存地址**数据依赖**于一条 `csrr mstatus`（CSR 指令只在 ROB 头发射 ⇒ 其数据
     *     依赖者必然晚于更老的 `csrw` 提交）。 */
    li    t1, 0x00000800            /* MPRV=0 */
    csrw  mstatus, t1
    csrr  t2, mstatus               /* ★ 串行化读（ROB 头执行）*/
    andi  t2, t2, 0                 /* t2 = 0（依赖 CSR 读回值）*/
    add   s2, s1, t2                /* s2 = s1（地址依赖链）*/
    lw    s10, 0x100(s2)            /* s10 = 0xDEADBEEF（译后 store 落地）*/
    add   s3, s1, t2                /* s3 = s1 */
    lw    s11, 0(s3)                /* s11 = PTE 回读（未映射页的 store 不得改动它）*/

    /* ---- 7. 收尾：把自记录值送进写回轨迹（供 TB 硬编码判据 + 黄金比对）---- */
    mv    a1, s5                    /* a1 = 0x11223344 */
    mv    a2, s6                    /* a2 = 0xDEADBEEF */
    mv    a3, s10                   /* a3 = 0xDEADBEEF（直读 PA）*/
    mv    a4, s11                   /* a4 = PTE 回读 */
    mv    a5, s7                    /* a5 = 故障 VA（0x40002000）*/
1:  auipc x30, %pcrel_hi(tohost)
    addi  x30, x30, %pcrel_lo(1b)
    li    x31, 1
    sw    x31, 0(x30)
    j     .

    /* ---- 陷阱处理：自记录 mcause/mtval/mepc 后跳过故障指令 ---- */
    .align 2
trap_handler:
    csrr  t3, mcause                /* 期望 15（store/AMO page fault）*/
    csrr  t4, mtval                 /* 期望 0x4000_2000（故障**虚拟**地址）*/
    csrr  t5, mepc                  /* 故障指令 PC */
    sub   a6, t5, s8                /* 期望 4 = mepc − (auipc 的 PC) */
    addi  t5, t5, 4
    csrw  mepc, t5
    mret

    /* ---- 存储：**未使用**（页表用上面的绝对地址；此处保留段定义以满足链接脚本布局）---- */
    .section .bss,"aw",@nobits
    .align 12
    .globl root
root:
    .zero 4096                      /* 根页表（[0x100]/[0x200] 用；+0x100 备用）*/
    .globl l1
l1:
    .zero 4096                      /* 一级页表（[0] 用；+0x100 作数据槽）*/

    .section .tohost,"aw"
    .align 3
    .globl tohost
tohost:
    .word 0
    .align 3
    .globl fromhost
fromhost:
    .word 0
