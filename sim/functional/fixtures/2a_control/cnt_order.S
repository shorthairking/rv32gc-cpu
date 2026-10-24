#==============================================================================
# sim/functional/fixtures/2a_control/cnt_order.S
#   计数器读的**程序序投影**正控（2A 单退休；链接=运行=0x0001_0000）。
#------------------------------------------------------------------------------
# 规范口径（zicsr.adoc:166-184 / norm:csraccessorder；machine.adoc:1523-1561）：
#  · instret 读 = **本条执行前**已退休条数（相邻两读差 = 之间的退休条数）；
#    显式写 minstret 的半字**替代本条自身 +1**，其值就是后条读到的值。
#  · mcycle 为时钟计数：半字写只改选中半；同沿 tick 的自然进位必须体现在
#    随后读到的高半（含“更早一次写改了低半 ⇒ 后一次 tick 的进位不同”）。
# 结果字（TB 读 DDR 模型；每项 = 1 表示软件自检通过）+ 实测值留档：
#   0x2000 相邻两读差 == 1            0x2004 隔 2 条读差 == 2
#   0x2008 写 minstret 低半后紧邻读 == 写值（差 0）
#   0x200C 写 minstreth 后紧邻读高半 == 写值（差 0）
#   0x2010 低半写 FFFF_FFFF + 1 条退休后读高半 == 之前高半 + 1（半字 carry）
#   0x2014 两读之间夹一次未缓存 load（长停顿）差 == 2
#   0x2018 csrrs 的读 == 更老 csrw 的写值（0x1000）
#   0x201C csrrs 之后紧邻读 == 新值（0x1002）
#   0x2020 mcycle 双写者跨半 carry：读 cycleh == 3（4 种对齐覆盖）
#   0x2024 mcycle 单写者控制：读 cycleh == 2；低半在写值小窗口内
#   0x2100+ 实测值
#   0x2FFC DONE
#==============================================================================
    .option norvc
    .section .text
    .globl _start

    .macro STBOOL addr, reg, want
        li   t5, 0
        li   t6, \want
        bne  \reg, t6, 89f
        li   t5, 1
89:     li   t3, \addr
        sw   t5, 0(t3)
    .endm

    .macro STVAL addr, reg
        li   t3, \addr
        sw   \reg, 0(t3)
    .endm

_start:
    li   t0, 4
1:  addi t0, t0, -1
    bnez t0, 1b

    # ---- P1 相邻两读：差必须恰 1 ----
    rdinstret t0
    rdinstret t1
    sub t2, t1, t0
    STBOOL 0x2000, t2, 1
    STVAL  0x2100, t0
    STVAL  0x2104, t2

    # ---- P2 中间隔 1 条（nop）：两读差必须恰 2 ----
    rdinstret t0
    nop
    rdinstret t1
    sub t2, t1, t0
    STBOOL 0x2004, t2, 2

    # ---- P3 写 minstret 低半 → 紧邻读：== 写值（写替代自身 +1）----
    li   t0, 0x00010000
    csrw minstret, t0
    csrr t1, minstret
    sub  t2, t1, t0
    STBOOL 0x2008, t2, 0
    STVAL  0x2108, t1

    # ---- P4 写 minstreth → 紧邻读 instreth：== 写值 ----
    li   t0, 0x0000ABCD
    csrw minstreth, t0
    csrr t1, instreth
    sub  t2, t1, t0
    STBOOL 0x200C, t2, 0

    # ---- P5 低半写 FFFF_FFFF → 至少一条退休 → 高半 +1（半字 carry）----
    csrr s0, instreth
    li   t0, 0xFFFFFFFF
    csrw minstret, t0
    nop
    csrr t1, instreth
    sub  t2, t1, s0
    STBOOL 0x2010, t2, 1
    csrr t2, instret
    STVAL  0x210C, t2

    # ---- P6 与更老普通提交交错 + 长停顿：读/load/读 差必须恰 2 ----
    rdinstret t0
    li   t3, 0x3000
    lw   t4, 0(t3)               # 未缓存 DDR 读（TB 注入长延迟）
    rdinstret t1
    sub  t2, t1, t0
    STBOOL 0x2014, t2, 3
    STVAL  0x2110, t4
    STVAL  0x211C, t2

    # ---- P7 RMW 先后：csrrs 的读必须看到更老 csrw 的写值 ----
    li   t1, 2
    li   t0, 0x00001000
    csrw minstret, t0
    csrrs t2, minstret, t1       # 读 == 0x1000；写 == 0x1002
    csrr t3, minstret            # == 0x1002
    # Preserve both samples across STBOOL's documented scratch set (t3/t5/t6).
    mv   s4, t2                  # actual old RMW read, survives both macros
    mv   s5, t3                  # actual post-RMW read, survives both macros
    li   t4, 0x00001000
    sub  t2, s4, t4
#ifdef P7_NEG_OLD
    addi t2, t2, 1               # negative control: break only the old-read relation
#endif
    STBOOL 0x2018, t2, 0
    li   t4, 0x00001002
    sub  t2, s5, t4
#ifdef P7_NEG_POST
    addi t2, t2, 1               # negative control: break only the post-read relation
#endif
    STBOOL 0x201C, t2, 0
    STVAL  0x2114, s4
    STVAL  0x2118, s5

    # ---- P8 mcycle 跨半 carry 扫描（合法软件驱动，不 force）----
    #   每个 d：先写 high=2、low=0，再写 low=0xFFFFFFFF-d（一条更早的写），
    #   随后 A=csrw mcycle,x0 与 B=rdcycleh 相邻（A 在 B 的 E 拍处于 W 槽）。
    #   A 落盘沿的 tick 输入是它覆盖前的 low：
    #     · 若该 low==0xFFFFFFFF ⇒ 自然进位使 high 2→3（"更早写改变 lo 影响后 tick
    #       进位"的真实窗口）⇒ B 必须读到 3；
    #     · 否则 high 保持 2。
    #   用 D=再读一次 cycleh 作"落地后真值"：D==3 的 d 上必须 B==3（否则即漏进位）。
    #   d 扫描 0..15 补偿 2 拍/条取指的固定相位（不 force、不直写 RTL 内部）。
    li   s1, 0                 # d
    li   s2, 0                 # mismatch 标志
    li   s3, 0                 # carry 曾发生
p8_scan:
    csrw mcycle, x0
    li   t0, 2
    csrw mcycleh, t0
    li   t0, 0xFFFFFFFF
    sub  t0, t0, s1
    csrw mcycle, t0            # 更早的写：low = 0xFFFFFFFF-d
    csrw mcycle, x0            # A：相邻写（在 B 的 E 拍处于 W 槽）
    csrr t1, cycleh            # B：跨半读（必须含 A 落盘沿的进位）
    csrr t2, mcycle            # 中间读，保持 A/B 相邻关系
    csrr t3, cycleh            # D：落地后的真值
    li   t4, 3
    bne  t3, t4, p8_next       # 本 d 无进位
    li   s3, 1
    beq  t1, t4, p8_next       # B 也读到 3 ⇒ 正确
    li   s2, 1                 # D 有进位而 B 漏 ⇒ 记错
p8_next:
    addi s1, s1, 1
    li   t4, 16
    bne  s1, t4, p8_scan
    # s2==0 ⇒ 无漏进位；s3==1 ⇒ 确实触发过进位
    STBOOL 0x2020, s2, 0
    STBOOL 0x2024, s3, 1

    # ---- P9 mcycle 单写者控制：写低半 0x12345678 ⇒ 高半不变（2），低半可读 ----
    csrw mcycle, x0
    li   t0, 2
    csrw mcycleh, t0
    li   t0, 0x12345678
    csrw mcycle, t0
    csrr t1, cycleh
    csrr t6, cycle
    # 高半 == 2；低半在 [写值, 写值+8) 窗口内（时钟计数允许少量 tick）
    li   t2, 0
    li   t4, 2
    bne  t1, t4, 82f
    li   t4, 0x12345678
    bltu t6, t4, 82f
    li   t5, 0x12345680
    bgeu t6, t5, 82f
    li   t2, 1
82: STBOOL 0x2028, t2, 1
    STVAL  0x2130, t6
    STVAL  0x2134, t1

    # ---- DONE ----
    li   t4, 0x2ffc
    li   t5, 0xdeadbeef
    sw   t5, 0(t4)
2:  j 2b
