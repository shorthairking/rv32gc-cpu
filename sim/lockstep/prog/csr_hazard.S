#==============================================================================
# sim/lockstep/prog/csr_hazard.S —— CSR 写→紧邻读 缺陷定向复现程序（锁步反证用例）
#==============================================================================
# 项目 : rv32gc-cpu（阶段二 2A）；配套 sim/lockstep/run.sh --prog csr_hazard
#
# 一、这个程序证明什么
#------------------------------------------------------------------------------
#   2A 当前 RTL 在 **CSR 写指令的紧邻下一条指令读同一 CSR**（距离 k=0）时返回
#   **旧值**（写尚未可见），与 Spike 分歧。距离 k>=1 时正确。
#
#   本会话实测（`./sim/lockstep/run.sh --prog csr_hazard` 的 CMP_DIVERGENCE）：
#     第 N 条：DUT rd=x10 写值=0x00000000  spike 写值=0x11111000
#   即 `csrrw t0,mscratch,s6` 之后的 `csrr a0,mscratch` 在 DUT 上读到 0（旧值），
#   在 Spike 上读到 0x1111_1000（新值）。
#
# 二、根因（只读走查结论，供 RTL 修复任务参考；本文件不改 rtl）
#------------------------------------------------------------------------------
#   · CSR 读在 **E 阶段** 组合产生（core_top.v:1113 `csr_rdata`，用 `de_csr_addr`
#     = D→E 寄存器里的 CSR 地址），结果随 `em_csr_rdata` 流入 M/W 级写回 rd。
#   · CSR 写在 **W 阶段** 落寄存器堆（core_top.v:1613 `csr_wen_w`，写口 1623）。
#   · 读旁路只有一级（core_top.v:1104）：
#         csr_base_rd = (csr_wen_w & (mw_csr_addr == de_csr_addr)) ? csr_rdata_w
#                                                                  : csr_rdata_raw;
#     即"W 阶段写 → E 阶段读"（对应距离 k=1）。**缺" M 阶段写 → E 阶段读"**
#     （距离 k=0：写指令在 M 时，读指令恰在 E）⇒ k=0 读到 csr_file 的旧值。
#   · 修复方向（示例，需实现者按异常/冲刷门控补齐语义）：
#     在 `csr_base_rd` 的优先链里补一级 M 阶段旁路——
#         (em_csr_we & <em 槽有效且未被冲刷/作废> & (em_csr_addr == de_csr_addr))
#         ? em_csr_wdata : ...
#     （`em_csr_wdata` = core_top.v:2392 锁存的 `csr_new_e`，即写指令的新值。）
#   · ISA 依据：CSR 写必须对**程序序在后的**读可见（Zicsr 顺序语义；arch-test 的
#     csrr 读回用例同样覆盖该点）。⇒ 这是真缺陷，不是"锁步程序口味"问题。
#
# 三、内容（刻意覆盖 k=0/1/2 三档距离，用交替值让"读到旧值"可见）
#------------------------------------------------------------------------------
#   k=0：csrrw（写 0x1111_1000）→ csrr 紧邻读       ⇒ **DUT 分歧点**
#   k=1：csrrw（写 0x2222_2000）→ 1 条间隔 → csrr   ⇒ 应一致
#   k=2：csrrw（写 0x1111_1000）→ 2 条间隔 → csrr   ⇒ 应一致
#   随后写魔数 0x600D_5EED → 0x8000_2000、写 UART 结束铃 0x5A → 0x1FE0_01E0，
#   进入死循环（与 lock_hello.S 同一结束协议，比对器锚点一致）。
#   程序与 lock_hello.S 共用：同一 link.ld、同一 TB、同一比对器；只有 MIN_COMMITS
#   门槛不同（本程序短，run.sh 用 --min-commits 10）。
#==============================================================================

    .option norvc

    .section .boot, "ax"
    .globl  _boot
    .align  2
_boot:
    lui     t0, 0x80000
    jalr    x0, 0(t0)

    .section .text, "ax"
    .globl  _start
    .align  2
_start:
    lui     s6, 0x11111             # s6 = 0x1111_1000
    lui     s7, 0x22222             # s7 = 0x2222_2000

    # ---- k=0：写后**紧邻**读（DUT 应在此分歧）----
    csrrw   t0, mscratch, s6        # mscratch ← 0x1111_1000
    csrr    a0, mscratch            # ← k=0 读：DUT 读旧值（缺陷点）

    # ---- k=1：写后隔 1 条（应一致）----
    csrrw   t0, mscratch, s7        # mscratch ← 0x2222_2000
    nop
    csrr    a1, mscratch            # k=1 读

    # ---- k=2：写后隔 2 条（应一致）----
    csrrw   t0, mscratch, s6        # mscratch ← 0x1111_1000
    nop
    nop
    csrr    a2, mscratch            # k=2 读

    # ---- 结束：魔数 + UART 结束铃 + 死循环 ----
    lui     t1, 0x80002             # 0x8000_2000
    li      t2, 0x600D5EED          # MAGIC
    sw      t2, 0(t1)
    lui     t3, 0x1FE00
    addi    t3, t3, 480             # 0x1FE0_01E0（UART 数据寄存器）
    addi    t4, x0, 90              # 0x5A 结束铃
    sw      t4, 0(t3)

    .globl  lockstep_spin
lockstep_spin:
1:  j       1b
