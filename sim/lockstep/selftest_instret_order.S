#==============================================================================
# sim/lockstep/selftest_instret_order.S —— instret 程序序/半写/进位精确探针
#------------------------------------------------------------------------------
# 覆盖（与 Spike 逐条比较，不硬编码绝对计数）：
#   · 相邻两条 rdinstret 的差 = 1；
#   · 写 minstret 低半代替本条隐式 +1：写后紧邻读 == 写值，再下一条读 = 写值+1；
#   · 写 minstreth 高半保留低半、抑制本条 +1；
#   · low=0xFFFF_FFFF 后一条退休产生高半进位；
#   · 前一条写值被后一条精确读到（program order）。
# 本轮新 Top 已修程序序投影；minstret 读仍不在移出范围，本程序只写不读 minstret。
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
    # ---- 相邻读：差 1 ----
    csrr    t0, instret
    csrr    t1, instret
    sub     t2, t1, t0

    # ---- 低半写抑制自身 +1：写 0x100，紧邻读应 0x100，再读 0x101 ----
    li      t0, 0x100
    csrw    minstret, t0
    csrr    t3, instret
    csrr    t4, instret
    sub     t5, t4, t3

    # ---- 高半写：high=0（low 保留），抑制自身 +1 ----
    li      t0, 0
    csrw    minstreth, t0

    # ---- 高半进位：low=0xFFFF_FFFF，再退休一条 → high 进位 1 ----
    li      t0, 0xFFFFFFFF
    csrw    minstret, t0
    nop
    csrr    t6, instreth
    csrr    s0, instret

    # ---- 高半写 2：high=2，low 保留；再读 high/low ----
    li      t0, 2
    csrw    minstreth, t0
    csrr    s1, instreth
    csrr    s2, instret

    # ---- 结束协议 ----
    lui     t1, 0x80002
    li      t2, 0x600D5EED
    sw      t2, 0(t1)
    lui     t3, 0x1FE00
    addi    t3, t3, 480
    li      t4, 0x5A
    sw      t4, 0(t3)

    .globl  lockstep_spin
lockstep_spin:
1:  j       1b
