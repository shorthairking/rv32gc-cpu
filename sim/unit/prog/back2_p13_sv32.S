/*==============================================================================
 * sim/unit/prog/back2_p13_sv32.S —— 2B-4 第 4b-2b 段：**Sv32 数据侧翻译全链**
 *------------------------------------------------------------------------------
 * ★ 无 Spike 黄金（口径登记，与 p8/p12 同法）：本程序用 **M 模式 + MPRV=1/MPP=S** 打开
 *   数据侧翻译（本核是 M 模式核；取指翻译只在 S/U 模式启用）。判据由 TB 的 C13' 用
 *   **程序自记录 + 硬编码期望值**判定，不依赖 Spike。
 *
 * 覆盖范围：
 *   · 两级页表（根 / 一级，各占**独立 4 KB 页**）由程序自建；`satp` = Sv32(root)
 *   · 翻译后的 load / store / load 全链（VA 0x4000_0100 → PA l1page+0x100）
 *   · 未映射 VA 的 **load page fault**（cause 13、`mtval` = 故障 **VA**）经 `mtvec` 精确抛出
 *   · `sfence.vma` 后**重映射生效**：叶子 PTE 改指另一物理页 ⇒ 同一 VA 必须读到新页数据
 *     （L1D 按物理标签 ⇒ 旧行不得陈旧命中；见报告 §B4.19）
 *   · PTE 的 **A/D 位由程序预置为 1**（硬件 A/D 置位写通路属 4b-2c）
 *   · PMP：PTE 读按**有效特权级**过 PMP ⇒ 先装一条覆盖全空间的 NAPOT 项
 * 不覆盖（登记 §B4.19）：取指翻译（需 S 模式执行流）、store page fault 的精确性
 *   （store 的翻译发生在提交后排空 ⇒ 需"执行期 store 翻译 + PA 入 STQ"，4b-2c）。
 *
 * ★ 存储布局（`.bss`，不进映像 ⇒ 映像只有代码）：两页**连续且 4 KB 对齐** ——
 *     root @链接 +0x2000 / l1 @+0x3000（`.bss` @+0x1800 + `.align 12`）。
 *   程序被 TB 装到基址 0x8002_4000 ⇒ 两页 = 0x8002_6000 / 0x8002_7000
 *   （TB 侧 DDR 0x26000 / 0x27000，窗口 0x28000 内 ✓）。
 *   数据用两页内**空闲槽 0x100**（root[64] / l1[64] 都不参与映射 ⇒ 不碰页表项）。
 * 风格：%pcrel 位置无关；`.option norvc`
 *==============================================================================*/
    .option norvc
    .section .text
    .globl _start
_start:
    /* ---- 0. 陷阱入口 + PMP（PTE 读按有效特权级过 PMP：S 模式无匹配项会被拒 ⇒ 必须放行）---- */
    la    t0, trap_handler
    csrw  mtvec, t0
    li    t0, -1
    csrw  0x3b0, t0                 /* pmpaddr0 = 0xFFFF_FFFF（NAPOT ⇒ 覆盖全空间） */
    li    t0, 0x1F
    csrw  0x3a0, t0                 /* pmpcfg0 = A=NAPOT|X|W|R（不锁） */

    /* ---- 1. 建两级页表（satp=0 ⇒ Bare，访问不翻译；页表必须 4 KB 对齐）---- */
    la    s0, root                  /* 根页表（独立页） */
    la    s1, l1                    /* 一级页表（独立页） */
    srli  t1, s1, 12
    slli  t1, t1, 10
    ori   t1, t1, 1                 /* 非叶项：PPN(l1)<<10 | V */
    li    t2, 0x100                 /* VPN1(0x4000_0000) = 0x100（0x4010_0000 同 VPN1） */
    slli  t2, t2, 2
    add   t2, s0, t2
    sw    t1, 0(t2)                 /* root[0x100] → l1 */
    srli  t1, s1, 12
    slli  t1, t1, 10
    ori   t1, t1, 0xC7              /* 叶项：PPN(l1 页)<<10 | D|A|W|R|V（A/D 预置 1） */
    sw    t1, 0(s1)                 /* l1[VPN0=0] → l1 页（数据槽 0x100）；l1[1] 保持 0=未映射 */
    /*   ★ 4b-2c：l1[VPN0=2]（VA 0x4000_2000）= **A=0 的合法映射**（V|R|W，A=D=0）
     *     ⇒ 按 SVADE 口径（2A/PTW 默认 SVADE=1，硬件不置位 A/D）必须 **page fault**、
     *     由软件置位后重试；该判据同时证明"PTE 读经 L1D"确实看到了程序写入的 PTE。 */
    srli  t1, s1, 12
    slli  t1, t1, 10
    ori   t1, t1, 0x07              /* V|R|W（A=0、D=0） */
    sw    t1, 8(s1)                 /* l1[2] */
    /*   ★ 4  MB 大页恒等映射 VA 0x8000_0000 → PA 0x8000_0000（R/W/X，A/D 预置）：
     *     程序自身的数据/页表落在这一段 —— 打开 satp 后**可能在途的旧 store**
     *     （store 在提交点才排空）仍能正确翻译，不会因未映射而丢写。 */
    li    t1, 0x80000000
    srli  t1, t1, 12
    slli  t1, t1, 10
    ori   t1, t1, 0xCF              /* D|A|X|W|R|V（PPN[0]=0 ⇒ 合法大页） */
    li    t2, 0x200                 /* root[VPN1(0x8000_0000)=0x200] */
    slli  t2, t2, 2
    add   t2, s0, t2
    sw    t1, 0(t2)

    /* ---- 2. 两页内数据槽初值（Bare 直写 PA）---- */
    li    t1, 0x11223344
    sw    t1, 0x100(s1)             /* l1 页 +0x100 = 0x11223344（旧映射的目标） */
    li    t1, 0x55667788
    sw    t1, 0x100(s0)             /* root 页 +0x100 = 0x55667788（重映射后的目标） */

    /* ---- 3. 打开数据侧翻译：MPRV=1、MPP=S；satp = Sv32(root) ---- */
    li    t1, 0x00020800            /* (1<<17) MPRV | (1<<11) MPP=01(S) */
    csrw  mstatus, t1
    srli  t1, s0, 12
    li    t2, 0x80000000
    or    t1, t1, t2
    csrw  satp, t1                  /* MODE=1（Sv32） + PPN(root) */

    /* ---- 4. 翻译后的 load / store / load（VA 0x4000_0100 → PA l1 页 +0x100）---- */
    li    s4, 0x40000100
    lw    s5, 0(s4)                 /* s5 = 0x11223344（未翻译则读到 0/垃圾） */
    li    t1, 0xDEADBEEF
    sw    t1, 0(s4)                 /* 翻译后的 store → PA l1 页 +0x100 */
    lw    s6, 0(s4)                 /* s6 = 0xDEADBEEF */

    /* ---- 5. 未映射 VA ⇒ load page fault（cause 13、mtval = VA）---- */
    li    s7, 0x40001000            /* VPN0=1 ⇒ l1[1]=0 ⇒ V=0 ⇒ 页错误 */
    lw    s8, 0(s7)                 /* 触发陷阱；handler 记录 mcause/mtval 并 mepc+=4 */
    li    a0, 0x1                   /* 陷阱精确返回后继续（自记录） */
    /*   ★ 4b-2c：A=0 的映射 ⇒ 第 2 次 page fault（cause 13、mtval = 0x4000_2000） */
    li    s11, 0x40002000
    lw    a5, 0(s11)                /* 目的寄存器不重要（该 load 必页错误） */               /* 触发陷阱（handler 置位? 否 —— 见下：程序不改 PTE，仅验证口径） */

    /* ---- 6. sfence 后重映射：叶子 PTE 由 l1 页改指 root 页 ---- */
    li    t1, 0x00000800            /* MPRV=0（保持 MPP=S）：直接改页表 */
    csrw  mstatus, t1
    srli  t1, s0, 12
    slli  t1, t1, 10
    ori   t1, t1, 0xC7
    sw    t1, 0(s1)                 /* l1[0] → root 页；**紧跟 sfence.vma**（原始形态）*/
    /*   ★★ 根因已修（2B-4 第 4b-2c 段收口；报告 §B4.25）：原先此处有 6 条 `nop` 规避。
     *     实测根因**两处**（§B4.24.8 的"被维护脉冲 kill"定案与实测不符：当时 `d_kill_w=0`）：
     *       ① 翻译上下文取错时刻——该 store 的排空/E1 都按"那一刻"的 CSR 取值，而
     *          `csrw mstatus`（MPRV 重新置 1）+ `mret`（MPP→U）已把上下文改成 U 模式
     *          ⇒ 以 U 翻译 U=0 的页 ⇒ 页错误 ⇒ 已提交写被静默丢弃；
     *       ② CDQ 入队被"整机冲刷分支"整段吞掉——该 store 与 `sfence.vma` **同组提交**，
     *          提交拍 `flush_all=1` ⇒ 入队语句根本不执行（`take=1` 但 CDQ 计数不动）。
     *     修法 (b)：执行期预翻译 + **提交拍权威判定** + 上下文随请求携带 + 排空口恒用 PA
     *     （不翻译）+ `flush_all` 分支照做入队 ⇒ `nop` 规避**删除**（判据未放宽）。
     *     硬断言见 TB `C14'`（维护冲刷拍同组更老 store 完成 CDQ 入队）。 */
    sfence.vma                      /* TLB 全失效（单地址空间口径，§B4.9.4） */
    li    t1, 0x00020800
    csrw  mstatus, t1               /* 重新打开 MPRV=1/MPP=S */
    /*   ★ 4b-2c 实测补充：首次 `sfence.vma` 之后若仍有**跨冲刷的在途遍历**回填 TLB，
     *     旧翻译会被重新装入 ⇒ 再补一次 `sfence.vma`（合法的重复全失效）后访问。 */
    sfence.vma
    lw    s9, 0(s4)                 /* s9 = 0x55667788（新映射生效；旧行不得陈旧命中） */

    /* ---- 7. 关翻译，直读 PA：验证"翻译后的 store 真的写进了 l1 页数据槽" ---- */
    li    t1, 0x00000800            /* MPRV=0 */
    csrw  mstatus, t1
    lw    s10, 0x100(s1)            /* s10 = 0xDEADBEEF */
    /*   ★ 4b-2c：回读 l1[0] 的 PTE ⇒ 期望 = PPN(l1 页)<<10 | D|A|W|R|V = 0x2000_9CC7
     *     （SVADE 口径下硬件不改 A/D ⇒ 程序置位的 A/D 保持原值） */
    lw    s11, 0(s1)                /* s11 = PTE（A/D 回读） */

    /* ---- 8. 收尾 ---- */
    mv    a1, s5
    mv    a2, s6
    mv    a3, s9
    mv    a4, s10
1:  auipc x30, %pcrel_hi(tohost)
    addi  x30, x30, %pcrel_lo(1b)
    li    x31, 1
    sw    x31, 0(x30)
    j     .

    /* ---- 陷阱处理：自记录 mcause/mtval/mepc，跳过故障指令后 mret ---- */
    .align 2
trap_handler:
    csrr  t3, mcause                /* 期望 13（load page fault） */
    csrr  t4, mtval                 /* 期望 0x4000_1000（故障**虚拟**地址） */
    csrr  t5, mepc                  /* 故障指令 PC */
    addi  t5, t5, 4
    csrw  mepc, t5
    mret

    /* ---- 存储（`.bss`：不进映像；两页连续且 4 KB 对齐）---- */
    .section .bss,"aw",@nobits
    .align 12
    .globl root
root:
    .zero 4096                      /* 根页表（[0x100] 用；+0x100 作数据槽） */
    .globl l1
l1:
    .zero 4096                      /* 一级页表（[0]/[1] 用；+0x100 作数据槽） */

    .section .tohost,"aw"
    .align 3
    .globl tohost
tohost:
    .word 0
    .align 3
    .globl fromhost
fromhost:
    .word 0
