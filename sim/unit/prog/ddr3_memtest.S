#==============================================================================
# sim/unit/prog/ddr3_memtest.S —— M3 里程碑「DDR3 裸机内存测试」程序真源
#==============================================================================
# 项目  : rv32gc-cpu（阶段二 2A 单发射顺序 5 级基线核）
# 归属  : docs/design/08-baseline-5stage.md §8.4（裸机内存测试：模式集/判据）、
#         §8.5（反证实验：XIP 旁路、核内 MMIO 截获）、§5.4/§5.5（LSU/访存）、
#         §6.6（CLINT/PLIC 核内截获，写 0x1F00_0000 落地即"静默数据损坏"）
# TB    : sim/unit/tb_m3_ddr3.sv（自包含 core_top 级 TB；本文件与 TB 内嵌字数组
#         逐条一致，TB 的 C1 映像自检会核对首字/末字/非零字数）
#
#------------------------------------------------------------------------------
# 一、这个程序测什么（三件事，缺一不可）
#------------------------------------------------------------------------------
#   ① DDR3 裸机内存遍历（08 §8.4）：对缩减窗口做**全遍历**，模式集与 §8.4 一致：
#        0x0000_0000 / 0xFFFF_FFFF / 0x5555_5555 / 0xAAAA_AAAA
#        + 地址相关模式 0xA5A5_0000 | addr[15:0]
#        + 每 4 KB 页首/页尾专项
#        + （附加）字节/半字专项：逐字节写 + lbu/lb/lhu/lh 读回（wstrb 与字节道）
#      每模式显式计数：写次数 / 读次数 / 错数，逐模式落到结果区（TB 核对）；
#      错例记录**首个**错地址、期望值、实读值、模式号。
#   ② XIP 旁路反证（08 §8.4 判据②/§8.5 第 1 行）：程序**从 0x1C00_0000 取指启动**
#      （复位桩），并调用一段**驻留 Flash（XIP 窗口）** 的子程序；子程序内首字是
#      "可变指令"：
#        pass 1：执行可变指令（初值 addi a1,x0,0x111），把结果存结果区；
#                随后写 TB 邮箱 ⇒ **TB 在运行中把 Flash 该字改成 addi a1,x0,0x222**；
#                再跳回同一条可变指令（pass 2）。
#        pass 2：**必须**取到改后的新内容（结果区见 0x222）——这只有在"XIP 取指
#                绕过 I-Cache"时成立；关掉旁路（走 L1I）⇒ pass 2 命中陈旧行 ⇒
#                结果仍是 0x111 ⇒ 反证实验必红（RTL 变异见 TB 参数）。
#   ③ 核内 MMIO 截获反证（08 §8.4 判据③/§8.5 第 2 行）：先在 DDR3 内与 CLINT
#      寄存器**别名同址**的地址写探针并读回（before）→ 写 CLINT 窗口
#      （0x1F00_4000/0x1F00_4004/0x1F00_0000，核内截获、绝不发 AXI）→ 读回 CLINT
#      寄存器（正向证据：写进去的值能读回来）→ 再读 DDR3 探针（after）；
#      **before 必须逐字等于 after**（CLINT 写绝不落 AXI/DDR3 默认从设备）。
#      若核内截获被关掉（变异）⇒ CLINT 写由 AXI 落到平台默认从设备（TB 按平台
#      口径把 0x1F00_xxxx 混叠进 DDR3 低地址）⇒ 探针被改写 ⇒ 必红。
#
#------------------------------------------------------------------------------
# 二、内存布局（★ 仿真缩减窗口；板级口径见每处注释）
#------------------------------------------------------------------------------
#   XIP/Flash 窗口 0x1C00_0000（板级 SPI NOR，TB 用 4 KiB 阵列建模）：
#     +0x00  .boot 复位桩（2 字）：lui t0,0x00100 ; jalr x0,0(t0)  ⇒ 跳到 DDR3 主程序
#     +0x40  XIP 子程序（★ +0x40 是 32 B 行边界：可变指令所在行 = 该行首，便于
#            "关掉旁路 ⇒ L1I 命中陈旧行"的反证实验成立）
#   DDR3 默认从设备 0x0000_0000–0x07FF_FFFF（板级 128 MiB；TB 建模低 2 MiB）：
#     0x0000_0000 + 16 KiB   ★ 模式遍历窗口（板级 = 0x0 起 128 MiB **全遍历**，
#                              此处为仿真缩减窗口：iverilog 实测 ≈4.0–4.6 k 拍/秒，
#                              128 MiB 全遍历需数百小时量级）——M0..M4 全遍历
#     0x0000_0000 + 1 MiB    4 KB 页首/页尾专项覆盖区（M5：256 页，每页 2 字）
#     0x0000_3C00–0x0000_4000 字节/半字专项区（M6：窗口尾页内 1 KiB）
#     0x0000_4000 / 0x0000_4004 / 0x0000_BFF8
#                            CLINT +0x4000/+0x4004/+0xBFF8 的**别名探针**地址
#                            （CLINT 偏移 0x4000/0x4004/0xBFF8 在平台默认从设备
#                             上的混叠位置，见 TB 的地址混叠建模）
#     0x0010_0000            主程序 .main
#     0x0018_0000            结果区 RES_BASE（+0x100 = 完成标志 MAGIC）
#     0x001F_FF00            TB 邮箱：写 1 ⇒ TB 改写 Flash 可变字
#   核内截获窗口（**不参与** DDR3 遍历，08 §8.4 末条）：CLINT 0x1F00_0000、
#     PLIC 0x1F10_0000；平台外设 0x1FE0_01E0(UART)/0x1FE7_8000(NAND) 等同样不遍历。
#
#------------------------------------------------------------------------------
# 三、结果区布局（RES_BASE = 0x0018_0000；TB 逐字核对）
#------------------------------------------------------------------------------
#   0x00  R_WINWORDS  程序自报的窗口字数（= .equ WIN_WORDS；TB 参数核对，失配即红）
#   0x04  R_XIP1      XIP 可变指令 pass1 结果（期望 0x0000_0111）
#   0x08  R_XIP2      XIP 可变指令 pass2 结果（期望 0x0000_0222）
#   0x0C  R_XIP_OK    1 = 两遍结果都对（XIP 旁路生效）
#   0x10  R_TOTW      全部模式写次数合计        0x14 R_TOTR 读次数合计
#   0x18  R_TOTE      全部模式错数合计
#   0x20  R_MODETAB   7 模式 × 3 字 {写, 读, 错}（模式号见 §四）
#   0x80  R_FE_ADDR   首个错例：地址        0x84 R_FE_EXP 期望值
#   0x88  R_FE_ACT    首个错例：实读值      0x8C R_FE_MODE 模式号
#   0x90  R_PB0/1/2   写 CLINT 前的 DDR3 探针值
#   0x9C  R_PA0/1/2   写 CLINT 后的 DDR3 探针值（必须与 before 逐字相等）
#   0xA8  R_CLO       CLINT mtimecmp 低字回读   0xAC R_CHI 高字回读
#   0xB0  R_CMSIP     CLINT msip 回读
#   0xB4  R_CLINT_OK  1 = 探针不变 且 CLINT 写可读回
#   0x100 R_MAGIC     完成标志 0x5A5A_A5A5（最后一条 store；TB 见到它才判"跑完"）
#
#------------------------------------------------------------------------------
# 四、模式号（与 TB 的模式计数表一一对应）
#------------------------------------------------------------------------------
#   0: 0x0000_0000      1: 0xFFFF_FFFF      2: 0x5555_5555      3: 0xAAAA_AAAA
#   4: 0xA5A5_0000|addr[15:0]                5: 4 KB 页首/页尾（1 MiB 覆盖区）
#   6: 字节/半字（wstrb/字节道 + 符号扩展）
#
#------------------------------------------------------------------------------
# 五、汇编命令（真源可复现；.option norvc ⇒ 全 4 B 指令，无压缩）
#------------------------------------------------------------------------------
#   TC=/opt/riscv/bin/riscv32-unknown-linux-gnu-
#   ${TC}gcc -march=rv32i -mabi=ilp32 -mno-relax -nostdlib -nostartfiles \
#       -Wl,--section-start=.boot=0x1C000000,--section-start=.main=0x00100000 \
#       -o ddr3_memtest.elf sim/unit/prog/ddr3_memtest.S
#   ${TC}objdump -d ddr3_memtest.elf                 # 反汇编（见交付说明）
#   ${TC}objcopy -O binary --only-section=.boot boot.bin
#   ${TC}objcopy -O binary --only-section=.main main.bin
#   # TB 内嵌字数组 = boot.bin + main.bin 的两个 32 bit 小端字序列
#
# 约束（不许越界）：只用 RV32I；不用栈/不调 ABI 函数（只用 jal/ret 内部子程序）；
#   不开 MMU、不写 mstatus（无 FP 指令）；不改 mstatus.MIE/mie（CLINT 写不触发中断）。
#==============================================================================
    .option norvc

#------------------------------------------------------------------------------
# 0. 常量（★ 唯一真源：窗口口径改这里 + TB 的 WINDOW_WORDS 参数一起改）
#------------------------------------------------------------------------------
    .equ XIP_ENTRY,   0x1C000040       # XIP 子程序入口（= 可变指令地址，32 B 行首）
    .equ RAM_MAIN,    0x00100000       # 主程序基址（.main）
    .equ RES_BASE,    0x00180000       # 结果区基址
    .equ MAILBOX,     0x001FFF00       # TB 邮箱（写 1 ⇒ TB 改写 Flash 可变字）

    .equ WIN_BASE,    0x00000000       # ★ DDR3 遍历窗口基址（板级 = 0x0）
    .equ WIN_WORDS,   4096             # ★ 窗口字数 = 16 KiB（板级 = 128 MiB 全遍历）
    .equ WIN_END,     0x00004000       # = WIN_BASE + WIN_WORDS*4

    .equ PAGE_REGION, 0x00100000       # 页专项覆盖区（1 MiB = 256 页；板级 128 MiB）
    .equ PAGES,       256              # = PAGE_REGION / 4096

    .equ SUB_BASE,    0x00003C00       # 字节/半字专项（窗口尾页内 1 KiB）
    .equ SUB_END,     0x00004000

    .equ PROBE0,      0x00004000       # CLINT +0x4000 的别名探针
    .equ PROBE1,      0x00004004       # CLINT +0x4004 的别名探针
    .equ PROBE2,      0x0000BFF8       # CLINT +0xBFF8（mtime）的别名探针
    .equ P0_VAL,      0x5A5A1111
    .equ P1_VAL,      0x5A5A2222
    .equ P2_VAL,      0x5A5A3333
    .equ CM_LO,       0xDEADBEEF       # 写入 CLINT mtimecmp 低字
    .equ CM_HI,       0x0BADF00D       # 写入 CLINT mtimecmp 高字（恒 > mtime ⇒ 无定时中断）
    .equ MSIP_VAL,    0x00000001       # 写入 CLINT msip（mie=0 ⇒ 不触发中断）

    .equ R_WINWORDS,  0x00
    .equ R_XIP1,      0x04
    .equ R_XIP2,      0x08
    .equ R_XIP_OK,    0x0C
    .equ R_TOTW,      0x10
    .equ R_TOTR,      0x14
    .equ R_TOTE,      0x18
    .equ R_MODETAB,   0x20
    .equ R_FE_ADDR,   0x80
    .equ R_FE_EXP,    0x84
    .equ R_FE_ACT,    0x88
    .equ R_FE_MODE,   0x8C
    .equ R_PB0,       0x90
    .equ R_PB1,       0x94
    .equ R_PB2,       0x98
    .equ R_PA0,       0x9C
    .equ R_PA1,       0xA0
    .equ R_PA2,       0xA4
    .equ R_CLO,       0xA8
    .equ R_CHI,       0xAC
    .equ R_CMSIP,     0xB0
    .equ R_CLINT_OK,  0xB4
    .equ R_MAGIC,     0x100
    .equ MAGIC_VAL,   0x5A5AA5A5

    .equ XIP_V1,      0x00000111       # 可变指令 pass1 立即数（初值）
    .equ XIP_V2,      0x00000222       # 可变指令 pass2 立即数（TB 改写后）

#------------------------------------------------------------------------------
# 1. 复位桩 + XIP 子程序（Flash/XIP 窗口 0x1C00_0000）
#    板级复位取指只能落在这里（平台无 boot ROM），故首字必须是复位桩。
#------------------------------------------------------------------------------
    .section .boot, "ax", @progbits
    .globl _boot
_boot:
    lui   t0, 0x00100                  # t0 = 0x0010_0000（DDR3 主程序）
    jalr  x0, 0(t0)                    # 跳到主程序（其后的取指走 DDR3/L1I）

    .org  0x40, 0                      # ★ 占位到 +0x40（32 B 行边界）
    .globl xip_entry
xip_entry:
    # ★★ 可变指令（TB 在程序运行中改写这一字：0x111 版 → 0x222 版）★★
    #    pass1 与 pass2 都从这一条开始执行；关掉 XIP 旁路时 pass2 会命中 L1I 陈旧行。
    addi  a1, x0, XIP_V1               # a1 = 0x0000_0111（TB 改后 = 0x0000_0222）
    sw    a1, 0(a3)                    # 结果区[R_XIP1/R_XIP2] = a1（a3 由主程序给）
    addi  a3, a3, 4
    addi  a4, a4, 1                    # pass 计数：1 = 首遍，2 = 改后第二遍
    addi  t1, x0, 1
    beq   a4, t1, xip_mutate           # pass1 ⇒ 去触发"运行中改 Flash"
    jalr  x0, 0(ra)                    # pass2 ⇒ 返回主程序
xip_mutate:
    li    t2, MAILBOX                  # TB 邮箱
    sw    t1, 0(t2)                    # 写 1 ⇒ TB 改 Flash[xip_entry] = 0x222 版
    # 延迟环：邮箱写是 AXI store，指令按程序序退休 ⇒ 本环执行时该写已完成、
    #   TB 也已改完 Flash；随后的 jalr 才会重新取指 xip_entry（杜绝竞态）。
    li    t3, 16
1:  addi  t3, t3, -1
    bne   t3, x0, 1b
    li    t0, XIP_ENTRY
    jalr  x0, 0(t0)                    # 回到可变指令（pass2）

#------------------------------------------------------------------------------
# 2. 主程序（DDR3 0x0010_0000；取指走 L1I 可缓存通路）
#------------------------------------------------------------------------------
    .section .main, "ax", @progbits
    .globl _start
_start:
    li    s8, RES_BASE                 # s8 = 结果区基址（全程不换）
    li    s7, RES_BASE + R_MODETAB     # s7 = 模式计数表游标

    # ---- 结果区清零（0x140 B = 80 字；防 TB 读到 x）----
    li    a0, RES_BASE
    li    a1, RES_BASE + 0x140
1:  sw    x0, 0(a0)
    addi  a0, a0, 4
    blt   a0, a1, 1b

    # ---- 自报窗口字数（TB 用参数核对；失配 ⇒ TB 判红）----
    li    t0, WIN_WORDS
    sw    t0, R_WINWORDS(s8)

    # ---- 计数器清零：s0 总写 / s1 总读 / s2 总错 ----
    li    s0, 0
    li    s1, 0
    li    s2, 0

    #==========================================================================
    # 3. XIP 旁路子测试（取指启动 + 运行中改 Flash 内容）
    #==========================================================================
    li    a3, RES_BASE + R_XIP1        # 子程序结果指针
    li    a4, 0                        # pass 计数初值
    li    t0, XIP_ENTRY
    jalr  ra, 0(t0)                    # 调用 XIP 子程序（内部走两遍）
    li    t1, XIP_V1
    lw    t2, R_XIP1(s8)
    lw    t3, R_XIP2(s8)
    li    t4, XIP_V2
    li    t5, 0
    bne   t2, t1, 2f
    bne   t3, t4, 2f
    li    t5, 1
2:  sw    t5, R_XIP_OK(s8)

    #==========================================================================
    # 4. DDR3 内存遍历（7 个模式；逐模式计数 + 首个错例记录）
    #==========================================================================

# ---- 宏：模式前导（模式号 + 三个计数清零）----
.macro MODE_PROLOG idx
    li    s6, \idx
    li    s3, 0                        # 本模式写计数
    li    s4, 0                        # 本模式读计数
    li    s5, 0                        # 本模式错计数
.endm

# ---- 宏：模式收尾（落表 + 累加全局计数）----
.macro MODE_EPILOG
    sw    s3, 0(s7)
    sw    s4, 4(s7)
    sw    s5, 8(s7)
    addi  s7, s7, 12
    add   s0, s0, s3
    add   s1, s1, s4
    add   s2, s2, s5
.endm

# ---- 宏：常量模式（写相展开 4 字/迭代；读相逐字比对）----
#      写相只对**写计数**按块累加（每迭代 +4），读相逐字累加 ⇒ 计数与访问一一对应
.macro MT_CONST idx, pat
    MODE_PROLOG \idx
    li    a1, WIN_END
    li    a5, \pat
    li    a0, WIN_BASE
100:                                   # 写相（4 字/迭代）
    sw    a5, 0(a0)
    sw    a5, 4(a0)
    sw    a5, 8(a0)
    sw    a5, 12(a0)
    addi  a0, a0, 16
    addi  s3, s3, 4
    blt   a0, a1, 100b
    li    a0, WIN_BASE
101:                                   # 读相（逐字：读 -> 比对 -> 计数）
    lw    a6, 0(a0)
    addi  s4, s4, 1
    beq   a6, a5, 102f
    mv    a7, a0
    jal   ra, rec_err
102: addi  a0, a0, 4
    blt   a0, a1, 101b
    MODE_EPILOG
.endm

# ---- 宏：字节/半字读回专项的一个 pass（op / 偏移 / 期望值）----
.macro MT_SUB_PASS op, off, exp
    li    a0, SUB_BASE
    li    a1, SUB_END
    li    a5, \exp
200: \op   a6, \off(a0)
    addi  s4, s4, 1
    beq   a6, a5, 201f
    addi  a7, a0, \off
    jal   ra, rec_err
201: addi  a0, a0, 4
    blt   a0, a1, 200b
.endm

    #--------------------------------------------------------------------------
    # 4.1 模式 0..3：0x00 / 0xFF / 0x55 / 0xAA（窗口全遍历）
    #--------------------------------------------------------------------------
    MT_CONST 0, 0x00000000
    MT_CONST 1, 0xFFFFFFFF
    MT_CONST 2, 0x55555555
    MT_CONST 3, 0xAAAAAAAA

    #--------------------------------------------------------------------------
    # 4.2 模式 4：地址相关模式 0xA5A5_0000 | addr[15:0]（窗口全遍历）
    #     按 64 KiB 分段：段内 addr[15:0] 不回卷 ⇒ 模式寄存器可"随地址 +4"递增；
    #     段首按 (addr & 0xFFFF) 重新装载（窗口 > 64 KiB 时口径仍严格正确）。
    #--------------------------------------------------------------------------
    MODE_PROLOG 4
    li    a0, WIN_BASE
    li    t5, 0x10000                  # 段字节数 = 64 KiB
    li    t6, 1                        # 段数（窗口 ≤ 64 KiB 时为 1；见 §五 常量真源）
    .if WIN_WORDS > 16384
    li    t6, WIN_WORDS / 16384
    .endif
100:                                   # 段首：a5 = 0xA5A50000 | (a0 & 0xFFFF)
    lui   a5, 0xA5A50
    slli  t4, a0, 16
    srli  t4, t4, 16
    or    a5, a5, t4
    add   t4, a0, t5                   # 候选段末
    li    a1, WIN_END
    bge   a1, t4, 103f                 # WIN_END ≥ 候选 ⇒ 用候选
    mv    t4, a1                       # 否则用 WIN_END
103:
    sw    a5, 0(a0)
    addi  a5, a5, 4
    addi  a0, a0, 4
    addi  s3, s3, 1
    blt   a0, t4, 103b
    addi  t6, t6, -1
    bne   t6, x0, 100b
    # 读相（同一分段口径）
    li    a0, WIN_BASE
    li    t6, 1
    .if WIN_WORDS > 16384
    li    t6, WIN_WORDS / 16384
    .endif
104:
    lui   a5, 0xA5A50
    slli  t4, a0, 16
    srli  t4, t4, 16
    or    a5, a5, t4
    add   t4, a0, t5
    li    a1, WIN_END
    bge   a1, t4, 105f
    mv    t4, a1
105:
    lw    a6, 0(a0)
    addi  s4, s4, 1
    beq   a6, a5, 106f
    mv    a7, a0
    jal   ra, rec_err
106: addi  a5, a5, 4
    addi  a0, a0, 4
    blt   a0, t4, 105b
    addi  t6, t6, -1
    bne   t6, x0, 104b
    MODE_EPILOG

    #--------------------------------------------------------------------------
    # 4.3 模式 5：每 4 KB 页首/页尾专项（覆盖 1 MiB = 256 页）
    #     页首 = 0xA5A5_0000 | page，页尾 = ~页首（互补 ⇒ 相邻字不会"同错抵消"）
    #--------------------------------------------------------------------------
    MODE_PROLOG 5
    li    a1, PAGES
    li    t5, 4096                     # 页大小（寄存器：页尾偏移 4092/步长 4096 超 12 bit 立即数）
    li    a0, WIN_BASE
    li    a2, 0                        # 页号
100:                                   # 写相
    lui   a5, 0xA5A50
    or    a5, a5, a2
    sw    a5, 0(a0)                    # 页首
    addi  s3, s3, 1
    not   a6, a5
    add   t1, a0, t5                   # t1 = 页末
    sw    a6, -4(t1)                   # 页尾 = 页基址 + 4092
    addi  s3, s3, 1
    add   a0, a0, t5
    addi  a2, a2, 1
    blt   a2, a1, 100b
    li    a0, WIN_BASE
    li    a2, 0
101:                                   # 读相
    lui   a5, 0xA5A50
    or    a5, a5, a2
    add   t1, a0, t5
    lw    a6, 0(a0)
    addi  s4, s4, 1
    beq   a6, a5, 102f
    mv    a7, a0
    jal   ra, rec_err
102: not   a5, a5
    lw    a6, -4(t1)
    addi  s4, s4, 1
    beq   a6, a5, 103f
    addi  a7, t1, -4
    jal   ra, rec_err
103: add   a0, a0, t5
    addi  a2, a2, 1
    blt   a2, a1, 101b
    MODE_EPILOG

    #--------------------------------------------------------------------------
    # 4.4 模式 6：字节/半字专项（wstrb + 字节道 + 符号扩展）
    #     区 [0x3C00,0x4000)：清零（sw）→ 逐字节写 0x11/0x22/0x33/0x84
    #     （小端整字 = 0x8433_2211）→ 5 个读回 pass：lw/lbu/lb/lhu/lh
    #--------------------------------------------------------------------------
    MODE_PROLOG 6
    # (a) 清零：SUB_WORDS 次 sw
    li    a0, SUB_BASE
    li    a1, SUB_END
100: sw    x0, 0(a0)
    addi  a0, a0, 4
    addi  s3, s3, 1
    blt   a0, a1, 100b
    # (b) 逐字节写：SUB_WORDS × 4 次 sb
    li    t2, 0x11
    li    t3, 0x22
    li    t4, 0x33
    li    t5, 0x84
    li    a0, SUB_BASE
101: sb    t2, 0(a0)
    sb    t3, 1(a0)
    sb    t4, 2(a0)
    sb    t5, 3(a0)
    addi  a0, a0, 4
    addi  s3, s3, 4
    blt   a0, a1, 101b
    # (c) 读回（5 个 pass，逐字比对）
    MT_SUB_PASS lw,  0, 0x84332211     # 整字（小端装配）
    MT_SUB_PASS lbu, 1, 0x00000022     # 零扩展字节
    MT_SUB_PASS lb,  3, 0xFFFFFF84     # 符号扩展字节（bit7=1）
    MT_SUB_PASS lhu, 2, 0x00008433     # 零扩展半字
    MT_SUB_PASS lh,  2, 0xFFFF8433     # 符号扩展半字（bit15=1）
    MODE_EPILOG

    #==========================================================================
    # 5. 核内 MMIO（CLINT）截获反证：CLINT 写绝不落到 DDR3 默认从设备
    #==========================================================================
    # (1) 在 CLINT 寄存器的"别名地址"上写 DDR3 探针（这些地址就是 CLINT
    #     +0x4000/+0x4004/+0xBFF8 在平台默认从设备上的混叠位置）
    li    t0, P0_VAL
    li    t1, PROBE0
    sw    t0, 0(t1)
    li    t0, P1_VAL
    li    t1, PROBE1
    sw    t0, 0(t1)
    li    t0, P2_VAL
    li    t1, PROBE2
    sw    t0, 0(t1)
    # (2) 读回探针（before）
    li    t1, PROBE0
    lw    t2, 0(t1)
    sw    t2, R_PB0(s8)
    li    t1, PROBE1
    lw    t2, 0(t1)
    sw    t2, R_PB1(s8)
    li    t1, PROBE2
    lw    t2, 0(t1)
    sw    t2, R_PB2(s8)
    # (3) 写 CLINT 窗口（0x1F00_xxxx，核内截获 ⇒ 绝不发 AXI）
    li    t0, 0x1F004000               # mtimecmp 低字
    li    t3, CM_LO
    sw    t3, 0(t0)
    li    t0, 0x1F004004               # mtimecmp 高字
    li    t3, CM_HI
    sw    t3, 0(t0)
    li    t0, 0x1F000000               # msip
    li    t3, MSIP_VAL
    sw    t3, 0(t0)
    # (4) 读回 CLINT 寄存器（正向证据：核内设备真的被写进去了）
    li    t0, 0x1F004000
    lw    t2, 0(t0)
    sw    t2, R_CLO(s8)
    li    t0, 0x1F004004
    lw    t2, 0(t0)
    sw    t2, R_CHI(s8)
    li    t0, 0x1F000000
    lw    t2, 0(t0)
    sw    t2, R_CMSIP(s8)
    # (5) 读回探针（after）
    li    t1, PROBE0
    lw    t2, 0(t1)
    sw    t2, R_PA0(s8)
    li    t1, PROBE1
    lw    t2, 0(t1)
    sw    t2, R_PA1(s8)
    li    t1, PROBE2
    lw    t2, 0(t1)
    sw    t2, R_PA2(s8)
    # (6) 判定：探针 before == after（CLINT 写没落 DDR3）且 CLINT 回读 == 写入值
    li    t0, 1
    lw    t1, R_PB0(s8)
    lw    t2, R_PA0(s8)
    beq   t1, t2, 1f
    li    t0, 0
1:  lw    t1, R_PB1(s8)
    lw    t2, R_PA1(s8)
    beq   t1, t2, 2f
    li    t0, 0
2:  lw    t1, R_PB2(s8)
    lw    t2, R_PA2(s8)
    beq   t1, t2, 3f
    li    t0, 0
3:  lw    t1, R_CLO(s8)
    li    t2, CM_LO
    beq   t1, t2, 4f
    li    t0, 0
4:  lw    t1, R_CHI(s8)
    li    t2, CM_HI
    beq   t1, t2, 5f
    li    t0, 0
5:  lw    t1, R_CMSIP(s8)
    li    t2, MSIP_VAL
    beq   t1, t2, 6f
    li    t0, 0
6:  sw    t0, R_CLINT_OK(s8)

    #==========================================================================
    # 6. 汇总 + 完成标志（最后一条 store；TB 见到它才判"跑完"）
    #==========================================================================
    sw    s0, R_TOTW(s8)
    sw    s1, R_TOTR(s8)
    sw    s2, R_TOTE(s8)
    li    t1, MAGIC_VAL
    sw    t1, R_MAGIC(s8)
9:  j     9b                            # 死循环（不再产生新请求）

#------------------------------------------------------------------------------
# 7. 内部子程序：记录首个错例并计数（a7=地址，a5=期望，a6=实读，s6=模式号）
#    只记录**第一个**错例（s2==0 时），后续只计数；不破坏 a0/a1/a5/a6/a7/ra 之外的寄存器
#------------------------------------------------------------------------------
    .align 2
rec_err:
    bne   s2, x0, 1f                   # 已有错例 ⇒ 只计数
    sw    a7, R_FE_ADDR(s8)
    sw    a5, R_FE_EXP(s8)
    sw    a6, R_FE_ACT(s8)
    sw    s6, R_FE_MODE(s8)
1:  addi  s2, s2, 1
    addi  s5, s5, 1
    ret

#------------------------------------------------------------------------------
# 六、附：objdump 反汇编（与 TB 内嵌字数组逐条一致）
#------------------------------------------------------------------------------
#   ★ 用途：sim/unit/tb_m3_ddr3.sv 的 boot_prog[] / main_prog[] 就是下面这些
#     指令的 32 bit 机器码（小端字，按节区顺序）。改本文件后必须重生成 TB 数组，
#     否则 TB 的 C0 映像自检（首字/末字/非零字数/可变字）会判红。
#   生成命令（见 §五）：
#     /opt/riscv/bin/riscv32-unknown-linux-gnu-objdump -d ddr3_memtest.elf
#
#
#
#
# Disassembly of section .boot:
#
# 1c000000 <_boot>:
# 1c000000:	001002b7          	lui	t0,0x100
# 1c000004:	00028067          	jr	t0 # 100000 <_start>
# 	...
#
# 1c000040 <xip_entry>:
# 1c000040:	11100593          	li	a1,273
# 1c000044:	00b6a023          	sw	a1,0(a3)
# 1c000048:	00468693          	addi	a3,a3,4
# 1c00004c:	00170713          	addi	a4,a4,1
# 1c000050:	00100313          	li	t1,1
# 1c000054:	00670463          	beq	a4,t1,1c00005c <xip_mutate>
# 1c000058:	00008067          	ret
#
# 1c00005c <xip_mutate>:
# 1c00005c:	002003b7          	lui	t2,0x200
# 1c000060:	f0038393          	addi	t2,t2,-256 # 1fff00 <MAILBOX>
# 1c000064:	0063a023          	sw	t1,0(t2)
# 1c000068:	01000e13          	li	t3,16
# 1c00006c:	fffe0e13          	addi	t3,t3,-1
# 1c000070:	fe0e1ee3          	bnez	t3,1c00006c <xip_mutate+0x10>
# 1c000074:	1c0002b7          	lui	t0,0x1c000
# 1c000078:	04028293          	addi	t0,t0,64 # 1c000040 <xip_entry>
# 1c00007c:	00028067          	jr	t0
#
# Disassembly of section .main:
#
# 00100000 <_start>:
#   100000:	00180c37          	lui	s8,0x180
#   100004:	00180bb7          	lui	s7,0x180
#   100008:	020b8b93          	addi	s7,s7,32 # 180020 <RES_BASE+0x20>
#   10000c:	00180537          	lui	a0,0x180
#   100010:	001805b7          	lui	a1,0x180
#   100014:	14058593          	addi	a1,a1,320 # 180140 <RES_BASE+0x140>
#   100018:	00052023          	sw	zero,0(a0) # 180000 <RES_BASE>
#   10001c:	00450513          	addi	a0,a0,4
#   100020:	feb54ce3          	blt	a0,a1,100018 <_start+0x18>
#   100024:	000012b7          	lui	t0,0x1
#   100028:	005c2023          	sw	t0,0(s8) # 180000 <RES_BASE>
#   10002c:	00000413          	li	s0,0
#   100030:	00000493          	li	s1,0
#   100034:	00000913          	li	s2,0
#   100038:	001806b7          	lui	a3,0x180
#   10003c:	00468693          	addi	a3,a3,4 # 180004 <RES_BASE+0x4>
#   100040:	00000713          	li	a4,0
#   100044:	1c0002b7          	lui	t0,0x1c000
#   100048:	04028293          	addi	t0,t0,64 # 1c000040 <xip_entry>
#   10004c:	000280e7          	jalr	t0
#   100050:	11100313          	li	t1,273
#   100054:	004c2383          	lw	t2,4(s8)
#   100058:	008c2e03          	lw	t3,8(s8)
#   10005c:	22200e93          	li	t4,546
#   100060:	00000f13          	li	t5,0
#   100064:	00639663          	bne	t2,t1,100070 <_start+0x70>
#   100068:	01de1463          	bne	t3,t4,100070 <_start+0x70>
#   10006c:	00100f13          	li	t5,1
#   100070:	01ec2623          	sw	t5,12(s8)
#   100074:	00000b13          	li	s6,0
#   100078:	00000993          	li	s3,0
#   10007c:	00000a13          	li	s4,0
#   100080:	00000a93          	li	s5,0
#   100084:	000045b7          	lui	a1,0x4
#   100088:	00000793          	li	a5,0
#   10008c:	00000513          	li	a0,0
#   100090:	00f52023          	sw	a5,0(a0)
#   100094:	00f52223          	sw	a5,4(a0)
#   100098:	00f52423          	sw	a5,8(a0)
#   10009c:	00f52623          	sw	a5,12(a0)
#   1000a0:	01050513          	addi	a0,a0,16
#   1000a4:	00498993          	addi	s3,s3,4
#   1000a8:	feb544e3          	blt	a0,a1,100090 <_start+0x90>
#   1000ac:	00000513          	li	a0,0
#   1000b0:	00052803          	lw	a6,0(a0)
#   1000b4:	001a0a13          	addi	s4,s4,1
#   1000b8:	00f80663          	beq	a6,a5,1000c4 <_start+0xc4>
#   1000bc:	00050893          	mv	a7,a0
#   1000c0:	5dc000ef          	jal	10069c <rec_err>
#   1000c4:	00450513          	addi	a0,a0,4
#   1000c8:	feb544e3          	blt	a0,a1,1000b0 <_start+0xb0>
#   1000cc:	013ba023          	sw	s3,0(s7)
#   1000d0:	014ba223          	sw	s4,4(s7)
#   1000d4:	015ba423          	sw	s5,8(s7)
#   1000d8:	00cb8b93          	addi	s7,s7,12
#   1000dc:	01340433          	add	s0,s0,s3
#   1000e0:	014484b3          	add	s1,s1,s4
#   1000e4:	01590933          	add	s2,s2,s5
#   1000e8:	00100b13          	li	s6,1
#   1000ec:	00000993          	li	s3,0
#   1000f0:	00000a13          	li	s4,0
#   1000f4:	00000a93          	li	s5,0
#   1000f8:	000045b7          	lui	a1,0x4
#   1000fc:	fff00793          	li	a5,-1
#   100100:	00000513          	li	a0,0
#   100104:	00f52023          	sw	a5,0(a0)
#   100108:	00f52223          	sw	a5,4(a0)
#   10010c:	00f52423          	sw	a5,8(a0)
#   100110:	00f52623          	sw	a5,12(a0)
#   100114:	01050513          	addi	a0,a0,16
#   100118:	00498993          	addi	s3,s3,4
#   10011c:	feb544e3          	blt	a0,a1,100104 <_start+0x104>
#   100120:	00000513          	li	a0,0
#   100124:	00052803          	lw	a6,0(a0)
#   100128:	001a0a13          	addi	s4,s4,1
#   10012c:	00f80663          	beq	a6,a5,100138 <_start+0x138>
#   100130:	00050893          	mv	a7,a0
#   100134:	568000ef          	jal	10069c <rec_err>
#   100138:	00450513          	addi	a0,a0,4
#   10013c:	feb544e3          	blt	a0,a1,100124 <_start+0x124>
#   100140:	013ba023          	sw	s3,0(s7)
#   100144:	014ba223          	sw	s4,4(s7)
#   100148:	015ba423          	sw	s5,8(s7)
#   10014c:	00cb8b93          	addi	s7,s7,12
#   100150:	01340433          	add	s0,s0,s3
#   100154:	014484b3          	add	s1,s1,s4
#   100158:	01590933          	add	s2,s2,s5
#   10015c:	00200b13          	li	s6,2
#   100160:	00000993          	li	s3,0
#   100164:	00000a13          	li	s4,0
#   100168:	00000a93          	li	s5,0
#   10016c:	000045b7          	lui	a1,0x4
#   100170:	555557b7          	lui	a5,0x55555
#   100174:	55578793          	addi	a5,a5,1365 # 55555555 <xip_mutate+0x395554f9>
#   100178:	00000513          	li	a0,0
#   10017c:	00f52023          	sw	a5,0(a0)
#   100180:	00f52223          	sw	a5,4(a0)
#   100184:	00f52423          	sw	a5,8(a0)
#   100188:	00f52623          	sw	a5,12(a0)
#   10018c:	01050513          	addi	a0,a0,16
#   100190:	00498993          	addi	s3,s3,4
#   100194:	feb544e3          	blt	a0,a1,10017c <_start+0x17c>
#   100198:	00000513          	li	a0,0
#   10019c:	00052803          	lw	a6,0(a0)
#   1001a0:	001a0a13          	addi	s4,s4,1
#   1001a4:	00f80663          	beq	a6,a5,1001b0 <_start+0x1b0>
#   1001a8:	00050893          	mv	a7,a0
#   1001ac:	4f0000ef          	jal	10069c <rec_err>
#   1001b0:	00450513          	addi	a0,a0,4
#   1001b4:	feb544e3          	blt	a0,a1,10019c <_start+0x19c>
#   1001b8:	013ba023          	sw	s3,0(s7)
#   1001bc:	014ba223          	sw	s4,4(s7)
#   1001c0:	015ba423          	sw	s5,8(s7)
#   1001c4:	00cb8b93          	addi	s7,s7,12
#   1001c8:	01340433          	add	s0,s0,s3
#   1001cc:	014484b3          	add	s1,s1,s4
#   1001d0:	01590933          	add	s2,s2,s5
#   1001d4:	00300b13          	li	s6,3
#   1001d8:	00000993          	li	s3,0
#   1001dc:	00000a13          	li	s4,0
#   1001e0:	00000a93          	li	s5,0
#   1001e4:	000045b7          	lui	a1,0x4
#   1001e8:	aaaab7b7          	lui	a5,0xaaaab
#   1001ec:	aaa78793          	addi	a5,a5,-1366 # aaaaaaaa <MAGIC_VAL+0x50500505>
#   1001f0:	00000513          	li	a0,0
#   1001f4:	00f52023          	sw	a5,0(a0)
#   1001f8:	00f52223          	sw	a5,4(a0)
#   1001fc:	00f52423          	sw	a5,8(a0)
#   100200:	00f52623          	sw	a5,12(a0)
#   100204:	01050513          	addi	a0,a0,16
#   100208:	00498993          	addi	s3,s3,4
#   10020c:	feb544e3          	blt	a0,a1,1001f4 <_start+0x1f4>
#   100210:	00000513          	li	a0,0
#   100214:	00052803          	lw	a6,0(a0)
#   100218:	001a0a13          	addi	s4,s4,1
#   10021c:	00f80663          	beq	a6,a5,100228 <_start+0x228>
#   100220:	00050893          	mv	a7,a0
#   100224:	478000ef          	jal	10069c <rec_err>
#   100228:	00450513          	addi	a0,a0,4
#   10022c:	feb544e3          	blt	a0,a1,100214 <_start+0x214>
#   100230:	013ba023          	sw	s3,0(s7)
#   100234:	014ba223          	sw	s4,4(s7)
#   100238:	015ba423          	sw	s5,8(s7)
#   10023c:	00cb8b93          	addi	s7,s7,12
#   100240:	01340433          	add	s0,s0,s3
#   100244:	014484b3          	add	s1,s1,s4
#   100248:	01590933          	add	s2,s2,s5
#   10024c:	00400b13          	li	s6,4
#   100250:	00000993          	li	s3,0
#   100254:	00000a13          	li	s4,0
#   100258:	00000a93          	li	s5,0
#   10025c:	00000513          	li	a0,0
#   100260:	00010f37          	lui	t5,0x10
#   100264:	00100f93          	li	t6,1
#   100268:	a5a507b7          	lui	a5,0xa5a50
#   10026c:	01051e93          	slli	t4,a0,0x10
#   100270:	010ede93          	srli	t4,t4,0x10
#   100274:	01d7e7b3          	or	a5,a5,t4
#   100278:	01e50eb3          	add	t4,a0,t5
#   10027c:	000045b7          	lui	a1,0x4
#   100280:	01d5d463          	bge	a1,t4,100288 <_start+0x288>
#   100284:	00058e93          	mv	t4,a1
#   100288:	00f52023          	sw	a5,0(a0)
#   10028c:	00478793          	addi	a5,a5,4 # a5a50004 <MAGIC_VAL+0x4b4a5a5f>
#   100290:	00450513          	addi	a0,a0,4
#   100294:	00198993          	addi	s3,s3,1
#   100298:	ffd548e3          	blt	a0,t4,100288 <_start+0x288>
#   10029c:	ffff8f93          	addi	t6,t6,-1
#   1002a0:	fc0f94e3          	bnez	t6,100268 <_start+0x268>
#   1002a4:	00000513          	li	a0,0
#   1002a8:	00100f93          	li	t6,1
#   1002ac:	a5a507b7          	lui	a5,0xa5a50
#   1002b0:	01051e93          	slli	t4,a0,0x10
#   1002b4:	010ede93          	srli	t4,t4,0x10
#   1002b8:	01d7e7b3          	or	a5,a5,t4
#   1002bc:	01e50eb3          	add	t4,a0,t5
#   1002c0:	000045b7          	lui	a1,0x4
#   1002c4:	01d5d463          	bge	a1,t4,1002cc <_start+0x2cc>
#   1002c8:	00058e93          	mv	t4,a1
#   1002cc:	00052803          	lw	a6,0(a0)
#   1002d0:	001a0a13          	addi	s4,s4,1
#   1002d4:	00f80663          	beq	a6,a5,1002e0 <_start+0x2e0>
#   1002d8:	00050893          	mv	a7,a0
#   1002dc:	3c0000ef          	jal	10069c <rec_err>
#   1002e0:	00478793          	addi	a5,a5,4 # a5a50004 <MAGIC_VAL+0x4b4a5a5f>
#   1002e4:	00450513          	addi	a0,a0,4
#   1002e8:	ffd542e3          	blt	a0,t4,1002cc <_start+0x2cc>
#   1002ec:	ffff8f93          	addi	t6,t6,-1
#   1002f0:	fa0f9ee3          	bnez	t6,1002ac <_start+0x2ac>
#   1002f4:	013ba023          	sw	s3,0(s7)
#   1002f8:	014ba223          	sw	s4,4(s7)
#   1002fc:	015ba423          	sw	s5,8(s7)
#   100300:	00cb8b93          	addi	s7,s7,12
#   100304:	01340433          	add	s0,s0,s3
#   100308:	014484b3          	add	s1,s1,s4
#   10030c:	01590933          	add	s2,s2,s5
#   100310:	00500b13          	li	s6,5
#   100314:	00000993          	li	s3,0
#   100318:	00000a13          	li	s4,0
#   10031c:	00000a93          	li	s5,0
#   100320:	10000593          	li	a1,256
#   100324:	00001f37          	lui	t5,0x1
#   100328:	00000513          	li	a0,0
#   10032c:	00000613          	li	a2,0
#   100330:	a5a507b7          	lui	a5,0xa5a50
#   100334:	00c7e7b3          	or	a5,a5,a2
#   100338:	00f52023          	sw	a5,0(a0)
#   10033c:	00198993          	addi	s3,s3,1
#   100340:	fff7c813          	not	a6,a5
#   100344:	01e50333          	add	t1,a0,t5
#   100348:	ff032e23          	sw	a6,-4(t1)
#   10034c:	00198993          	addi	s3,s3,1
#   100350:	01e50533          	add	a0,a0,t5
#   100354:	00160613          	addi	a2,a2,1
#   100358:	fcb64ce3          	blt	a2,a1,100330 <_start+0x330>
#   10035c:	00000513          	li	a0,0
#   100360:	00000613          	li	a2,0
#   100364:	a5a507b7          	lui	a5,0xa5a50
#   100368:	00c7e7b3          	or	a5,a5,a2
#   10036c:	01e50333          	add	t1,a0,t5
#   100370:	00052803          	lw	a6,0(a0)
#   100374:	001a0a13          	addi	s4,s4,1
#   100378:	00f80663          	beq	a6,a5,100384 <_start+0x384>
#   10037c:	00050893          	mv	a7,a0
#   100380:	31c000ef          	jal	10069c <rec_err>
#   100384:	fff7c793          	not	a5,a5
#   100388:	ffc32803          	lw	a6,-4(t1)
#   10038c:	001a0a13          	addi	s4,s4,1
#   100390:	00f80663          	beq	a6,a5,10039c <_start+0x39c>
#   100394:	ffc30893          	addi	a7,t1,-4
#   100398:	304000ef          	jal	10069c <rec_err>
#   10039c:	01e50533          	add	a0,a0,t5
#   1003a0:	00160613          	addi	a2,a2,1
#   1003a4:	fcb640e3          	blt	a2,a1,100364 <_start+0x364>
#   1003a8:	013ba023          	sw	s3,0(s7)
#   1003ac:	014ba223          	sw	s4,4(s7)
#   1003b0:	015ba423          	sw	s5,8(s7)
#   1003b4:	00cb8b93          	addi	s7,s7,12
#   1003b8:	01340433          	add	s0,s0,s3
#   1003bc:	014484b3          	add	s1,s1,s4
#   1003c0:	01590933          	add	s2,s2,s5
#   1003c4:	00600b13          	li	s6,6
#   1003c8:	00000993          	li	s3,0
#   1003cc:	00000a13          	li	s4,0
#   1003d0:	00000a93          	li	s5,0
#   1003d4:	00004537          	lui	a0,0x4
#   1003d8:	c0050513          	addi	a0,a0,-1024 # 3c00 <SUB_BASE>
#   1003dc:	000045b7          	lui	a1,0x4
#   1003e0:	00052023          	sw	zero,0(a0)
#   1003e4:	00450513          	addi	a0,a0,4
#   1003e8:	00198993          	addi	s3,s3,1
#   1003ec:	feb54ae3          	blt	a0,a1,1003e0 <_start+0x3e0>
#   1003f0:	01100393          	li	t2,17
#   1003f4:	02200e13          	li	t3,34
#   1003f8:	03300e93          	li	t4,51
#   1003fc:	08400f13          	li	t5,132
#   100400:	00004537          	lui	a0,0x4
#   100404:	c0050513          	addi	a0,a0,-1024 # 3c00 <SUB_BASE>
#   100408:	00750023          	sb	t2,0(a0)
#   10040c:	01c500a3          	sb	t3,1(a0)
#   100410:	01d50123          	sb	t4,2(a0)
#   100414:	01e501a3          	sb	t5,3(a0)
#   100418:	00450513          	addi	a0,a0,4
#   10041c:	00498993          	addi	s3,s3,4
#   100420:	feb544e3          	blt	a0,a1,100408 <_start+0x408>
#   100424:	00004537          	lui	a0,0x4
#   100428:	c0050513          	addi	a0,a0,-1024 # 3c00 <SUB_BASE>
#   10042c:	000045b7          	lui	a1,0x4
#   100430:	843327b7          	lui	a5,0x84332
#   100434:	21178793          	addi	a5,a5,529 # 84332211 <MAGIC_VAL+0x29d87c6c>
#   100438:	00052803          	lw	a6,0(a0)
#   10043c:	001a0a13          	addi	s4,s4,1
#   100440:	00f80663          	beq	a6,a5,10044c <_start+0x44c>
#   100444:	00050893          	mv	a7,a0
#   100448:	254000ef          	jal	10069c <rec_err>
#   10044c:	00450513          	addi	a0,a0,4
#   100450:	feb544e3          	blt	a0,a1,100438 <_start+0x438>
#   100454:	00004537          	lui	a0,0x4
#   100458:	c0050513          	addi	a0,a0,-1024 # 3c00 <SUB_BASE>
#   10045c:	000045b7          	lui	a1,0x4
#   100460:	02200793          	li	a5,34
#   100464:	00154803          	lbu	a6,1(a0)
#   100468:	001a0a13          	addi	s4,s4,1
#   10046c:	00f80663          	beq	a6,a5,100478 <_start+0x478>
#   100470:	00150893          	addi	a7,a0,1
#   100474:	228000ef          	jal	10069c <rec_err>
#   100478:	00450513          	addi	a0,a0,4
#   10047c:	feb544e3          	blt	a0,a1,100464 <_start+0x464>
#   100480:	00004537          	lui	a0,0x4
#   100484:	c0050513          	addi	a0,a0,-1024 # 3c00 <SUB_BASE>
#   100488:	000045b7          	lui	a1,0x4
#   10048c:	f8400793          	li	a5,-124
#   100490:	00350803          	lb	a6,3(a0)
#   100494:	001a0a13          	addi	s4,s4,1
#   100498:	00f80663          	beq	a6,a5,1004a4 <_start+0x4a4>
#   10049c:	00350893          	addi	a7,a0,3
#   1004a0:	1fc000ef          	jal	10069c <rec_err>
#   1004a4:	00450513          	addi	a0,a0,4
#   1004a8:	feb544e3          	blt	a0,a1,100490 <_start+0x490>
#   1004ac:	00004537          	lui	a0,0x4
#   1004b0:	c0050513          	addi	a0,a0,-1024 # 3c00 <SUB_BASE>
#   1004b4:	000045b7          	lui	a1,0x4
#   1004b8:	000087b7          	lui	a5,0x8
#   1004bc:	43378793          	addi	a5,a5,1075 # 8433 <PROBE1+0x442f>
#   1004c0:	00255803          	lhu	a6,2(a0)
#   1004c4:	001a0a13          	addi	s4,s4,1
#   1004c8:	00f80663          	beq	a6,a5,1004d4 <_start+0x4d4>
#   1004cc:	00250893          	addi	a7,a0,2
#   1004d0:	1cc000ef          	jal	10069c <rec_err>
#   1004d4:	00450513          	addi	a0,a0,4
#   1004d8:	feb544e3          	blt	a0,a1,1004c0 <_start+0x4c0>
#   1004dc:	00004537          	lui	a0,0x4
#   1004e0:	c0050513          	addi	a0,a0,-1024 # 3c00 <SUB_BASE>
#   1004e4:	000045b7          	lui	a1,0x4
#   1004e8:	ffff87b7          	lui	a5,0xffff8
#   1004ec:	43378793          	addi	a5,a5,1075 # ffff8433 <CM_LO+0x2151c544>
#   1004f0:	00251803          	lh	a6,2(a0)
#   1004f4:	001a0a13          	addi	s4,s4,1
#   1004f8:	00f80663          	beq	a6,a5,100504 <_start+0x504>
#   1004fc:	00250893          	addi	a7,a0,2
#   100500:	19c000ef          	jal	10069c <rec_err>
#   100504:	00450513          	addi	a0,a0,4
#   100508:	feb544e3          	blt	a0,a1,1004f0 <_start+0x4f0>
#   10050c:	013ba023          	sw	s3,0(s7)
#   100510:	014ba223          	sw	s4,4(s7)
#   100514:	015ba423          	sw	s5,8(s7)
#   100518:	00cb8b93          	addi	s7,s7,12
#   10051c:	01340433          	add	s0,s0,s3
#   100520:	014484b3          	add	s1,s1,s4
#   100524:	01590933          	add	s2,s2,s5
#   100528:	5a5a12b7          	lui	t0,0x5a5a1
#   10052c:	11128293          	addi	t0,t0,273 # 5a5a1111 <P0_VAL>
#   100530:	00004337          	lui	t1,0x4
#   100534:	00532023          	sw	t0,0(t1) # 4000 <PROBE0>
#   100538:	5a5a22b7          	lui	t0,0x5a5a2
#   10053c:	22228293          	addi	t0,t0,546 # 5a5a2222 <P1_VAL>
#   100540:	00004337          	lui	t1,0x4
#   100544:	00430313          	addi	t1,t1,4 # 4004 <PROBE1>
#   100548:	00532023          	sw	t0,0(t1)
#   10054c:	5a5a32b7          	lui	t0,0x5a5a3
#   100550:	33328293          	addi	t0,t0,819 # 5a5a3333 <P2_VAL>
#   100554:	0000c337          	lui	t1,0xc
#   100558:	ff830313          	addi	t1,t1,-8 # bff8 <PROBE2>
#   10055c:	00532023          	sw	t0,0(t1)
#   100560:	00004337          	lui	t1,0x4
#   100564:	00032383          	lw	t2,0(t1) # 4000 <PROBE0>
#   100568:	087c2823          	sw	t2,144(s8)
#   10056c:	00004337          	lui	t1,0x4
#   100570:	00430313          	addi	t1,t1,4 # 4004 <PROBE1>
#   100574:	00032383          	lw	t2,0(t1)
#   100578:	087c2a23          	sw	t2,148(s8)
#   10057c:	0000c337          	lui	t1,0xc
#   100580:	ff830313          	addi	t1,t1,-8 # bff8 <PROBE2>
#   100584:	00032383          	lw	t2,0(t1)
#   100588:	087c2c23          	sw	t2,152(s8)
#   10058c:	1f0042b7          	lui	t0,0x1f004
#   100590:	deadce37          	lui	t3,0xdeadc
#   100594:	eefe0e13          	addi	t3,t3,-273 # deadbeef <CM_LO>
#   100598:	01c2a023          	sw	t3,0(t0) # 1f004000 <xip_mutate+0x3003fa4>
#   10059c:	1f0042b7          	lui	t0,0x1f004
#   1005a0:	00428293          	addi	t0,t0,4 # 1f004004 <xip_mutate+0x3003fa8>
#   1005a4:	0badfe37          	lui	t3,0xbadf
#   1005a8:	00de0e13          	addi	t3,t3,13 # badf00d <CM_HI>
#   1005ac:	01c2a023          	sw	t3,0(t0)
#   1005b0:	1f0002b7          	lui	t0,0x1f000
#   1005b4:	00100e13          	li	t3,1
#   1005b8:	01c2a023          	sw	t3,0(t0) # 1f000000 <xip_mutate+0x2ffffa4>
#   1005bc:	1f0042b7          	lui	t0,0x1f004
#   1005c0:	0002a383          	lw	t2,0(t0) # 1f004000 <xip_mutate+0x3003fa4>
#   1005c4:	0a7c2423          	sw	t2,168(s8)
#   1005c8:	1f0042b7          	lui	t0,0x1f004
#   1005cc:	00428293          	addi	t0,t0,4 # 1f004004 <xip_mutate+0x3003fa8>
#   1005d0:	0002a383          	lw	t2,0(t0)
#   1005d4:	0a7c2623          	sw	t2,172(s8)
#   1005d8:	1f0002b7          	lui	t0,0x1f000
#   1005dc:	0002a383          	lw	t2,0(t0) # 1f000000 <xip_mutate+0x2ffffa4>
#   1005e0:	0a7c2823          	sw	t2,176(s8)
#   1005e4:	00004337          	lui	t1,0x4
#   1005e8:	00032383          	lw	t2,0(t1) # 4000 <PROBE0>
#   1005ec:	087c2e23          	sw	t2,156(s8)
#   1005f0:	00004337          	lui	t1,0x4
#   1005f4:	00430313          	addi	t1,t1,4 # 4004 <PROBE1>
#   1005f8:	00032383          	lw	t2,0(t1)
#   1005fc:	0a7c2023          	sw	t2,160(s8)
#   100600:	0000c337          	lui	t1,0xc
#   100604:	ff830313          	addi	t1,t1,-8 # bff8 <PROBE2>
#   100608:	00032383          	lw	t2,0(t1)
#   10060c:	0a7c2223          	sw	t2,164(s8)
#   100610:	00100293          	li	t0,1
#   100614:	090c2303          	lw	t1,144(s8)
#   100618:	09cc2383          	lw	t2,156(s8)
#   10061c:	00730463          	beq	t1,t2,100624 <_start+0x624>
#   100620:	00000293          	li	t0,0
#   100624:	094c2303          	lw	t1,148(s8)
#   100628:	0a0c2383          	lw	t2,160(s8)
#   10062c:	00730463          	beq	t1,t2,100634 <_start+0x634>
#   100630:	00000293          	li	t0,0
#   100634:	098c2303          	lw	t1,152(s8)
#   100638:	0a4c2383          	lw	t2,164(s8)
#   10063c:	00730463          	beq	t1,t2,100644 <_start+0x644>
#   100640:	00000293          	li	t0,0
#   100644:	0a8c2303          	lw	t1,168(s8)
#   100648:	deadc3b7          	lui	t2,0xdeadc
#   10064c:	eef38393          	addi	t2,t2,-273 # deadbeef <CM_LO>
#   100650:	00730463          	beq	t1,t2,100658 <_start+0x658>
#   100654:	00000293          	li	t0,0
#   100658:	0acc2303          	lw	t1,172(s8)
#   10065c:	0badf3b7          	lui	t2,0xbadf
#   100660:	00d38393          	addi	t2,t2,13 # badf00d <CM_HI>
#   100664:	00730463          	beq	t1,t2,10066c <_start+0x66c>
#   100668:	00000293          	li	t0,0
#   10066c:	0b0c2303          	lw	t1,176(s8)
#   100670:	00100393          	li	t2,1
#   100674:	00730463          	beq	t1,t2,10067c <_start+0x67c>
#   100678:	00000293          	li	t0,0
#   10067c:	0a5c2a23          	sw	t0,180(s8)
#   100680:	008c2823          	sw	s0,16(s8)
#   100684:	009c2a23          	sw	s1,20(s8)
#   100688:	012c2c23          	sw	s2,24(s8)
#   10068c:	5a5aa337          	lui	t1,0x5a5aa
#   100690:	5a530313          	addi	t1,t1,1445 # 5a5aa5a5 <MAGIC_VAL>
#   100694:	106c2023          	sw	t1,256(s8)
#   100698:	0000006f          	j	100698 <_start+0x698>
#
# 0010069c <rec_err>:
#   10069c:	00091a63          	bnez	s2,1006b0 <rec_err+0x14>
#   1006a0:	091c2023          	sw	a7,128(s8)
#   1006a4:	08fc2223          	sw	a5,132(s8)
#   1006a8:	090c2423          	sw	a6,136(s8)
#   1006ac:	096c2623          	sw	s6,140(s8)
#   1006b0:	00190913          	addi	s2,s2,1
#   1006b4:	001a8a93          	addi	s5,s5,1
#   1006b8:	00008067          	ret
