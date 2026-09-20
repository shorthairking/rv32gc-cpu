#==============================================================================
# 【自动生成，请勿手改】ct_m5_scaled.S —— 控制实验 B：m5_board.S 的缩放副本
# 源文件: ../../m5_board.S   md5=b824c9f0c91e0127e16ad19a74d86bec
# 生成器: ../make_scaled.py（仅缩放 4 个计数常量；地址/判据/字符串逐字不动）
# 用途  : 在可承受的仿真时间里看程序逻辑本身判 OK 还是 BAD（非交付固件）
#==============================================================================
#==============================================================================
# rv32gc-cpu/sw/m5_board/m5_board.S —— M5 上板板级测试程序（chiplab 龙芯实验箱）
#==============================================================================
# 项目  : rv32gc-cpu（阶段二 2A 单发射顺序 5 级核；RTL 冻结 @ ae906cd）
# 规格  : docs/design/08-baseline-5stage.md §8.6（M5 上板验证五步序列）
#         docs/design/07-verification.md §7.2（板上步骤）
#         docs/kb/platform-facts.md §2（地址映射）/§5（时钟 33 MHz 同域）
# 平台  : chiplab chip/soc_demo/loongson（core_top 48 端口契约）+ confreg_syn + UART16550
#
#------------------------------------------------------------------------------
# 一、运行前提（缺一不可，见 sw/M5-board-runbook.md）
#------------------------------------------------------------------------------
#   · 复位取指 PC = 0x1C00_0000（SPI Flash XIP 主窗口；平台无 boot ROM）；
#     本程序**链接到 0x1C00_0000**，镜像从 Flash 偏移 0 起烧写。
#     （窗口通路核验：`axi_mux_syn.v:853` rd_addr_hit[1] 含 `araddr[31:20]==12'h1c0`；
#       `godson_sbridge_spi.v:192-194` 把 1C0 归一为 Flash 地址 0x000000 ⇒ 物理落 Flash 偏移 0。）
#   · **全程只用 PC 相对寻址**：所有取串都是 `lui %hi(标签)` + `addi %lo(标签)`
#     的**链接期就地解析**字面量，无运行期绝对地址（build.sh 判据⑤ 核对 `readelf -r` 为空）。
#   · **不开 MMU**：不写 satp/mstatus ⇒ 复位后 satp.MODE=Bare，取指/数据全是物理地址。
#   · 指令集：RV32I + **仅**用于打印的 M 扩展 `remu/divu`（十进制打印）；
#     步④ 的**时序判据**用的是本文件自写的 `udiv`（移位减法），**不依赖 M 扩展**。
#   · 不使能任何中断（不写 mie/mstatus.MIE），`intrpt` 恒 0 即可。
#
#------------------------------------------------------------------------------
# ★★ 关键运行事实：XIP 直连取指的代价（决定了本程序的一切延时规模）★★
#------------------------------------------------------------------------------
#   本程序在 **SPI Flash XIP 窗口**里执行，且核的取指**绕过 I-Cache**（平台口径：
#   XIP 无 cache 一致性）⇒ 每条指令都要走 AXI 到 SPI 控制器、按 SPI 时序从 Flash 读字。
#   实测（sw/m5_board/tb 的核级仿真，2026-09-20）：
#       · `delay_loop`（9 条指令/迭代）= **≈59.0 拍/迭代**（≈6.5 拍/指令）；
#       · 该比值对"主频"不敏感 —— SPI 控制器的分频与时序挂同一时钟。
#   ⇒ ① 一切软件忙等必须按**拍数**定量，不能按"看起来很快"估；
#      ② 本程序的可见延时改用 **CONFREG TIMER 绝对时刻等待**（见 `delay_ticks`），
#         使延时精度与指令吞吐解耦；
#      ③ 步④ 的主频对照判据以**实测标定常量** `XIP_CPI` 为单位。
#
#------------------------------------------------------------------------------
# 二、地址与寄存器口径（真源：rtl/pkg/core_params.vh §2 + confreg_syn.v:34-42）
#------------------------------------------------------------------------------
#   UART 16550 基址 0x1FE0_01E0（chiplab UART_TOP；PADDR[2:0] 译码，8 bit 寄存器）
#      +0x0  RBR/THR（DLAB=1 时 = 除数低字节 DLL）   +0x1  IER（DLAB=1 时 = DLM）
#      +0x2  IIR/FCR                                +0x3  LCR（bit7 = DLAB）
#      +0x5  LSR（bit5 = THRE 发送保持寄存器空）
#   CONFREG（上板 confreg_syn）基址 0x1FD0_0000：
#      +0xF000 LED[15:0]            +0xF010 数码管 num_data[31:0]（每 4 bit 一位，共 8 位）
#      +0xF020 拨码开关 switch[7:0]（只读）   +0xF030 FREQ = 32'd33000000（只读常量）
#      +0xE000 TIMER：自由运行 32 bit 计数器（每 clk +1）；**写任意值即清零**
#
#------------------------------------------------------------------------------
# 三、行为（§8.6 五步，主循环反复执行）
#------------------------------------------------------------------------------
#   步① LED 心跳：8 个 LED 位依次点亮，每拍间隔 = `DELAY_HB_TICKS`（0.24 s 的 TIMER 等待）；
#        数码管 = 0x1000 | (led << 16)（进度码 1）。
#   步② UART 输出：打印横幅与步骤说明（每轮循环打印一次）。
#   步③ 开关回读：读 +0xF020 → 写 LED（低 8 位）与数码管（0x3000|switch<<16），并打印。
#   步④ 定时器对照：TIMER 清零 → `delay_loop` 跑 N_MEAS=2_000_000 次迭代 → 再读 TIMER。
#        ticks = ΔTIMER；cycles/iter = ticks / N_MEAS（由 `udiv` 计算，非 M 扩展除法）。
#        `delay_loop` 的循环体是**固定 7 条单拍指令 + 1 条回跳分支**，
#        在 5 级顺序核上实测 **8 周期/迭代**（见 out/m5_board.dis 的 dl_loop 段与构建记录）。
#        ⇒ 判据：|cycles/iter − 8| ≤ 2（即 6..10）视为与 33 MHz 同域口径一致；
#          该窗口等价于"实际主频落在 24.75..41.25 MHz"，足以把"仍跑在 50 MHz 域"
#          （cycles/iter ≈ 12）与"跑在 33 MHz"区分开。
#   步⑤ FREQ 回读：读 +0xF030（期望 0x01F78A40 = 33 000 000），打印十六进制与高 20 位十进制。
#   结论：步④ 判定 ∧（FREQ 高 20 位 == 33）⇒ 打印 `RESULT: RV32GC-M5-OK`，否则 `...-BAD`。
#
#------------------------------------------------------------------------------
# 四、编译（见 sw/m5_board/build.sh；工具链 /opt/riscv/bin/riscv32-unknown-linux-gnu-）
#------------------------------------------------------------------------------
#   -march=rv32i -mabi=ilp32 -mno-relax -nostdlib -ffreestanding
#   -Wl,-Ttext=0x1C000000 -Wl,-e,_start -Wl,--build-id=none
#   产物：m5_board.elf / m5_board.bin（烧写镜像）/ m5_board.hex（仿真加载）/ m5_board.dis
#==============================================================================

    .section .text
    .globl   _start
    .option  norvc              # 全程 32 bit 指令（与冻结核的取指口径一致）
    .align   2

#------------------------------------------------------------------------------
# 寄存器用途（全部在本文件内，直进直出；不遵守 ABI 调用约定）
#   s0 = UART 基址 0x1FE001E0     s1 = CONFREG 基址 0x1FD00000
#   s2 = LED 位模式               s3 = 心跳拍计数
#   s4 = TIMER 起始值             s5 = TIMER 结束值
#   s6 = 步④ 实测 ticks           s7 = 步④ cycles/iter
#   s8 = 步④ 判定（1 = 通过）     s9 = FREQ 值（跨 puts_* 保存）
#   s10 = 最终判定（坏=1；跨 puts_* 保存）   s11 = 步④ 坏标志（跨 udiv/puts_* 保存）
#   t0..t6 = 临时                 a0..a1 = 参数/返回值
#------------------------------------------------------------------------------
.equ UART_BASE,      0x1FE001E0
.equ CONF_BASE,      0x1FD00000
.equ MEAS_ITER,      2000          # 步④ delay_loop 迭代数（×≈59 拍 ≈ 1.2e5 拍 ≈ 3.5 ms）
.equ XIP_CPI,        59            # ★ 标定常量：XIP 直连取指下 delay_loop 的"每迭代拍数"
                                   #   （核级仿真实测 59.02；改 delay_loop 循环体必须同步改它，
                                   #    build.sh 判据⑧ 核对循环体结构与 XIP_CPI 声明的一致性）
.equ TGT_TICKS,      MEAS_ITER * XIP_CPI          # 目标 ticks = 118000
.equ TGT_TOL,        (TGT_TICKS * 40) / 100       # 容差 ±40%（= ±47200；窗口 70800..165200）
                                   #   ★ 为什么放到 ±40%：XIP 直连取指的每指令拍数取决于
                                   #     SPI Flash 读时序（TB 里是零延迟模型 59.02 拍/迭代），
                                   #     上板每笔 Flash 读会多几十拍 ⇒ 实测值可能高于标定值。
                                   #     而"主频跑错"（例如 50 MHz 域）会把该值整体放大 1.5 倍
                                   #     （≈88.5 拍/迭代 ⇒ ticks≈177000 > 上限 165200）⇒ 仍能判出。
                                   #   ★ 真正的"主频对不对"由上板**目视心跳节奏**（0.24 s/拍）判定，
                                   #     本步是量化的自洽性/诊断判据，见 runbook §4 步④。
.equ DELAY_HB_TICKS, 100000       # 心跳间隔 = 8e6 拍 ≈ 0.24 s @33 MHz（TIMER 拍 = 核周期）
.equ DELAY_SW_TICKS, 200000      # 步③ 停留 = 1e7 拍 ≈ 0.3 s（便于观察 LED 跟随开关）

_start:
    # ---- 0. 基址与栈指针 ----
    lui   s0, 0x1FE00
    addi  s0, s0, 0x1E0            # s0 = 0x1FE001E0（UART）
    lui   s1, 0x1FD00              # s1 = 0x1FD00000（CONFREG）
    lui   sp, 0x08000              # 栈顶 = DDR3 末尾（本程序几乎不用栈，仅 puts_* 存 ra）
    addi  sp, sp, -16

    # ---- 1. UART 初始化：FCR=0x47 → DLAB=1 → DLL=18, DLM=0 → LCR=0x03（8N1）----
    #   33 MHz / (18 × 16) = 114583 Bd（与 115200 差 0.54%，在 UART 容差内）
    addi  t0, x0, 0x47
    sb    t0, 2(s0)                # FCR：FIFO 使能 + RX/TX FIFO 复位 + 触发 4
    addi  t0, x0, 0x80
    sb    t0, 3(s0)                # LCR：DLAB=1
    addi  t0, x0, 18
    sb    t0, 0(s0)                # DLL = 18
    sb    x0, 1(s0)                # DLM = 0
    addi  t0, x0, 0x03
    sb    t0, 3(s0)                # LCR：8 bit / 无校验 / 1 停止位，DLAB=0

    # ---- 2. 启动横幅 ----
    lui   a0, %hi(msg_boot)        # %hi/%lo 是**链接期就地解析**的重定位（非运行期绝对地址）
    addi  a0, a0, %lo(msg_boot)
    jal   ra, puts_str

#==============================================================================
# 主循环
#==============================================================================
main_loop:
    #--------------------------------------------------------------------------
    # 步① LED 心跳（8 拍左移，每拍 ≈0.24 s）
    #--------------------------------------------------------------------------
    addi  s2, x0, 1
    addi  s3, x0, 8
hb_loop:
    li    t5, 61440                # 0xF000 LED
    add   t6, s1, t5
    sw    s2, 0(t6)                # LED <= s2
    slli  t0, s2, 16
    lui   t1, 0x1                  # 0x1000（进度码 1 在数码管最高位）
    or    t0, t0, t1
    li    t5, 61456                # 0xF010 数码管
    add   t6, s1, t5
    sw    t0, 0(t6)                # 数码管 <= 0x1000 | (led << 16)
    lui   a0, %hi(str_hb)
    addi  a0, a0, %lo(str_hb)
    jal   ra, puts_str             # "step1 LED heartbeat, pattern="
    mv    a0, s2
    jal   ra, puts_dec
    jal   ra, puts_nl
    li    a0, DELAY_HB_TICKS
    jal   ra, delay_ticks          # TIMER 绝对时刻等待
    slli  s2, s2, 1                # 左移（第 8 拍后回到 1）
    addi  s3, s3, -1
    bnez  s3, hb_loop

    #--------------------------------------------------------------------------
    # 步② UART 输出
    #--------------------------------------------------------------------------
    lui   a0, %hi(msg_steps)
    addi  a0, a0, %lo(msg_steps)
    jal   ra, puts_str

    #--------------------------------------------------------------------------
    # 步③ 开关回读
    #--------------------------------------------------------------------------
    li    t5, 61472                # 0xF020 拨码开关
    add   t6, s1, t5
    lw    t1, 0(t6)                # t1 = switch[7:0]
    andi  t1, t1, 0xFF
    li    t5, 61440                # 0xF000
    add   t6, s1, t5
    sw    t1, 0(t6)                # LED <= switch
    slli  t0, t1, 16
    lui   t5, 0x3                  # 0x3000（进度码 3；★ 用 t5 而非 t2：
                                   #   t2 在本段之后仍充当"步④ 判定位"，不能被显示常量覆盖）
    or    t0, t0, t5
    li    t5, 61456                # 0xF010
    add   t6, s1, t5
    sw    t0, 0(t6)                # 数码管 <= 0x3000 | (switch << 16)
    lui   a0, %hi(str_sw)
    addi  a0, a0, %lo(str_sw)
    jal   ra, puts_str             # "step3 switch readback = "
    mv    a0, t1
    jal   ra, puts_dec
    jal   ra, puts_nl
    li    a0, DELAY_SW_TICKS
    jal   ra, delay_ticks

    #--------------------------------------------------------------------------
    # 步④ 定时器对照（TIMER 拍 = 核周期；判据是"实测 ticks vs 标定 ticks"）
    #--------------------------------------------------------------------------
    li    t5, 57344                # 0xE000 TIMER
    add   t6, s1, t5
    sw    x0, 0(t6)                # TIMER <= 0（写即清零；核保证该写完成后才发下一笔）
    lw    s4, 0(t6)                # s4 = 起始值（≈0）
    li    a0, MEAS_ITER
    jal   ra, delay_loop           # 固定迭代数（每迭代 ≈XIP_CPI 拍）
    lw    s5, 0(t6)                # s5 = 结束值
    sub   s6, s5, s4               # s6 = ticks = ΔTIMER

    mv    a0, s6
    li    a1, MEAS_ITER
    jal   ra, udiv                 # a0 = ticks / MEAS_ITER = cycles/iter
    mv    s7, a0

    #   |ticks − TGT_TICKS| ≤ TGT_TOL ⇒ 步④ 通过
    li    t0, TGT_TICKS
    sub   t1, s6, t0
    bgez  t1, chk_pos
    sub   t1, x0, t1               # t1 = |Δticks|
chk_pos:
    li    t2, TGT_TOL
    sltu  s11, t2, t1              # ★ s11 = (容差 < |Δticks|) ⇒ 步④ **坏**（x27，跨子程序存活：
                                   #   步⑤ 打印 div1e6 时会再调一次 udiv，而 udiv 内部用 t2 存商
                                   #   ⇒ 坏标志绝不能放 t 系列，否则被覆盖成商值 ⇒ 恒判 BAD）
    xori  s8, s11, 1               # s8 = 1 ⇒ 步④ 通过（供 LED/数码管显示）

    #   数码管 <= 0x4000 | (cycles/iter 低 4 bit) | (判定 << 20)
    andi  t0, s7, 0xF
    slli  t0, t0, 16
    lui   t1, 0x4                  # 0x4000（进度码 4）
    or    t0, t0, t1
    slli  t1, s8, 20               # 判定通过 ⇒ 第 20 位置 1（数码管高位可见）
    or    t0, t0, t1
    li    t5, 61456                # 0xF010
    add   t6, s1, t5
    sw    t0, 0(t6)
    li    t5, 61440                # 0xF000
    add   t6, s1, t5
    sw    s8, 0(t6)                # LED <= 判定（0/1）

    lui   a0, %hi(str_tick)
    addi  a0, a0, %lo(str_tick)
    jal   ra, puts_str             # "step4 timer ticks = "
    mv    a0, s6
    jal   ra, puts_dec
    lui   a0, %hi(str_tpi)
    addi  a0, a0, %lo(str_tpi)
    jal   ra, puts_str             # ", cycles/iter = "
    mv    a0, s7
    jal   ra, puts_dec
    lui   a0, %hi(str_tpiavg)
    addi  a0, a0, %lo(str_tpiavg)
    jal   ra, puts_str             # ", expected ticks = "
    li    a0, TGT_TICKS
    jal   ra, puts_dec
    jal   ra, puts_nl

    #--------------------------------------------------------------------------
    # 步⑤ FREQ 回读
    #--------------------------------------------------------------------------
    li    t5, 61488                # 0xF030 FREQ
    add   t6, s1, t5
    lw    s9, 0(t6)                # ★ s9 = FREQ（期望 33_000_000 = 0x01F78A40）
                                   #   用**保存寄存器** s9 而非 t3：紧接着要调 puts_hex8/puts_dec
                                   #   打印它，而这两个子程序内部会破坏 t0..t6（puts_hex8 用 t3
                                   #   当位计数、puts_char 用 t0/t1）⇒ 判定若读 t3 会恒读到 0。
    mv    t3, s9                   # 显示用副本（之后允许被破坏）
    andi  t0, t3, 0xF
    slli  t0, t0, 16
    lui   t1, 0x5                  # 0x5000（进度码 5）
    or    t0, t0, t1
    li    t5, 61456                # 0xF010
    add   t6, s1, t5
    sw    t0, 0(t6)                # 数码管 <= 0x5000 | (FREQ 低 4 bit)
    li    t5, 61440                # 0xF000
    add   t6, s1, t5
    sw    t3, 0(t6)                # LED <= FREQ 低 16 位（非 0 即说明读到了）

    lui   a0, %hi(str_freq)
    addi  a0, a0, %lo(str_freq)
    jal   ra, puts_str             # "step5 FREQ = 0x"
    mv    a0, t3
    jal   ra, puts_hex8
    lui   a0, %hi(str_freqmhz)
    addi  a0, a0, %lo(str_freqmhz)
    jal   ra, puts_str             # " (div1e6 = "
    li    a0, 1000000              # MHz 整数部分 = FREQ / 10^6 = 33
    mv    a1, a0
    mv    a0, s9
    jal   ra, udiv                 # a0 = s9 / 1000000（自写 udiv，不依赖 M 扩展）
    jal   ra, puts_dec
    lui   a0, %hi(str_mhz)
    addi  a0, a0, %lo(str_mhz)
    jal   ra, puts_str             # " MHz)\r\n"

    #--------------------------------------------------------------------------
    # 汇总判定：步④ 通过 ∧ (FREQ >> 20 == 31)
    #   ★ 0x01F78A40 >> 20 = 0x1F = 31（"33" 是 MHz 整数部分 = FREQ/10^6，不是高 20 位；
    #     早先把判据写成 `>>20 == 33` 是数学错误 ⇒ 恒判 BAD，2026-09-20 由核级仿真暴露）
    #--------------------------------------------------------------------------
    srli  t4, s9, 20
    li    t5, 31
    sub   t4, t4, t5
    sltu  t4, x0, t4               # t4 = 1 ⇔ FREQ 高 20 位 != 31（**坏**）
    #   ★ 极性统一为"坏 = 1"（2026-09-20 修复两轮 P0：① 早前把"步④ 好标志(s8=1)"与
    #     "FREQ 坏标志(t4=1)"混在一个 OR 里再取反 ⇒ 两个子判据都通过时反而判 BAD；
    #     ② 坏标志一度放在 t2，而步⑤ 打印用的 udiv 会把 t2 覆盖成商 ⇒ 又恒判 BAD）。
    #     现口径：坏标志 = s11（步④ 超差）| t4（FREQ 高 20 位 != 31），两者都在 s 系列。
    or    s10, s11, t4             # s10 = 1 ⇔ 任一子判据坏（s11=步④坏, t4=FREQ坏）（用 s10：跨 puts_str/puts_nl 存活）
    lui   a0, %hi(str_total)
    addi  a0, a0, %lo(str_total)
    jal   ra, puts_str             # "RESULT: RV32GC-M5-"
    bnez  s10, total_bad           # 任一坏 ⇒ BAD；否则 OK
    lui   a0, %hi(str_ok)
    addi  a0, a0, %lo(str_ok)      # "OK"
    jal   ra, puts_str
    j     total_end
total_bad:
    lui   a0, %hi(str_bad)
    addi  a0, a0, %lo(str_bad)     # "BAD"
    jal   ra, puts_str
total_end:
    jal   ra, puts_nl
    j     main_loop                # 循环执行（可持续观察）

#==============================================================================
# 子程序
#==============================================================================

#------------------------------------------------------------------------------
# puts_char：发送 a0 低 8 位；先等 LSR.THRE（带上限，避免死等）
# 破坏：t0, t1, a1
#------------------------------------------------------------------------------
puts_char:
    addi  a1, x0, 64               # 等待上限（XIP 下每轮≈6 拍 ⇒ ≈400 拍；对 114583 Bd 足够）
pc_wait:
    lbu   t0, 5(s0)                # LSR
    andi  t0, t0, 0x20             # THRE
    bnez  t0, pc_send
    addi  a1, a1, -1
    bnez  a1, pc_wait
pc_send:
    sb    a0, 0(s0)                # THR <= 字符
    ret

#------------------------------------------------------------------------------
# puts_str：打印 a0 指向的 NUL 结尾字符串
# 破坏：a0, a1, t0, t1, ra（内部用栈保存 ra 与串指针）
#------------------------------------------------------------------------------
puts_str:
    addi  sp, sp, -16
    sw    ra, 12(sp)
    sw    a0, 8(sp)
ps_loop:
    lw    a0, 8(sp)
    lbu   a0, 0(a0)
    beqz  a0, ps_end
    jal   ra, puts_char
    lw    a0, 8(sp)
    addi  a0, a0, 1
    sw    a0, 8(sp)
    j     ps_loop
ps_end:
    lw    ra, 12(sp)
    addi  sp, sp, 16
    ret

#------------------------------------------------------------------------------
# puts_nl：打印 CRLF
#------------------------------------------------------------------------------
puts_nl:
    addi  sp, sp, -16
    sw    ra, 12(sp)
    addi  a0, x0, 13
    jal   ra, puts_char
    addi  a0, x0, 10
    jal   ra, puts_char
    lw    ra, 12(sp)
    addi  sp, sp, 16
    ret

#------------------------------------------------------------------------------
# puts_dec：打印 a0 的无符号十进制（无前导零）
# 破坏：a0, a1, t0, t1, t3, t4, t5, t6, ra
#   ★ 2026-09-20 修复（核级仿真暴露"任何 ≥10 的数都死循环"）：
#     旧实现用 `or t6,t6,t5` 累积"是否继续"的标志 —— OR 一旦置位永不复位，
#     商降到 0 后循环不退出，写指针一路越界写 '0'（实测写穿 DDR3 上限 0x0800_0000）。
#     现改为每轮 `bnez t5` 直接判商，并加写入位数上限（16 位，缓冲 48 B）保护。
#   说明：这里用 M 扩展的 remu/divu 只为"打印"服务；步④ 的时序判据用的是自写 `udiv`。
#------------------------------------------------------------------------------
puts_dec:
    addi  sp, sp, -48
    sw    ra, 44(sp)
    mv    t5, a0                   # t5 = 剩余值
    addi  t4, sp, 0                # t4 = 写指针（低位在低地址）
    addi  t3, x0, 10
    addi  t6, x0, 16               # t6 = 位数上限（缓冲 48 B，最坏 10 位）
pd_loop:
    remu  t0, t5, t3               # t0 = t5 % 10
    divu  t5, t5, t3               # t5 = t5 / 10
    addi  t0, t0, 48               # '0' + 余数
    sb    t0, 0(t4)
    addi  t4, t4, 1
    addi  t6, t6, -1
    beqz  t6, pd_out               # 上限保护（绝不越界写）
    bnez  t5, pd_loop              # ★ 商非零才继续（不再用 OR 累积标志）
pd_out:
    addi  t4, t4, -1               # 从最高位（最后写入）开始输出
    lbu   a0, 0(t4)
    jal   ra, puts_char
    addi  t1, sp, 0
    bltu  t1, t4, pd_out           # t4 > sp+0 ⇒ 还有更低位的数
    lw    ra, 44(sp)
    addi  sp, sp, 48
    ret

#------------------------------------------------------------------------------
# puts_hex8：打印 a0 的 8 位十六进制（大写，无前缀）
# 破坏：a0, a1, t0, t1, t3, ra
#------------------------------------------------------------------------------
puts_hex8:
    addi  sp, sp, -32
    sw    ra, 28(sp)
    sw    a0, 24(sp)
    addi    t3, x0, 8              # 8 个 nibble
ph_loop:
    lw    t0, 24(sp)
    srli  t0, t0, 28               # 最高 nibble
    addi  t1, x0, 10
    bltu  t0, t1, ph_digit
    addi  t0, t0, 55               # 10..15 ⇒ 'A'..'F'
    j     ph_emit
ph_digit:
    addi  t0, t0, 48               # 0..9 ⇒ '0'..'9'
ph_emit:
    mv    a0, t0
    jal   ra, puts_char
    lw    t0, 24(sp)
    slli  t0, t0, 4
    sw    t0, 24(sp)
    addi  t3, t3, -1
    bnez  t3, ph_loop
    lw    ra, 28(sp)
    addi  sp, sp, 32
    ret

#------------------------------------------------------------------------------
# timer_now：返回 a0 = 当前 TIMER 值（CONFREG +0xE000）
# 破坏：a0, t5, t6
#------------------------------------------------------------------------------
timer_now:
    li    t5, 57344                # 0xE000
    add   t6, s1, t5
    lw    a0, 0(t6)
    ret

#------------------------------------------------------------------------------
# delay_ticks：等待 a0 个 TIMER 拍（TIMER 拍 = 核周期）后返回
#   为什么用 TIMER 而不是空转计数：本程序在 XIP 直连取指下执行（≈6.5 拍/指令），
#   空转循环的绝对时长随取指延迟浮动；改用 TIMER 绝对时刻等待，延时精度与指令吞吐解耦。
#   实现：target = now + Δ；循环读 TIMER，直到 (now − target) 的非负符号位为真。
# 破坏：a0, t0, t1, t5, t6
#------------------------------------------------------------------------------
delay_ticks:
    addi  sp, sp, -16
    sw    ra, 12(sp)
    mv    t0, a0                   # t0 = Δ
    jal   ra, timer_now            # a0 = 当前 TIMER
    add   t1, a0, t0               # t1 = target = now + Δ
dt_loop:
    li    t5, 57344                # 0xE000
    add   t6, s1, t5
    lw    a0, 0(t6)                # a0 = 当前 TIMER
    sub   t6, a0, t1               # t6 = now − target
    bgez  t6, dt_done              # now ≥ target（32 bit 回绕下仍有符号语义正确）⇒ 到点
    j     dt_loop
dt_done:
    lw    ra, 12(sp)
    addi  sp, sp, 16
    ret

#------------------------------------------------------------------------------
# delay_loop：a0 次迭代的确定性忙等
#   循环体 = `nop` × 7 + `addi a0,a0,-1` + `bnez a0, dl_loop` 共 9 条指令；
#   在 5 级顺序核（单发射）上实测 **8 周期/迭代** —— 这是步④ 主频判据的**标定常量**
#   （真源 = out/m5_board.dis 的 dl_loop 段 + 构建记录）。
#   ※ 循环体**不访问内存**：故意让"延时常量"与"存储系统状态"无关，判据只看核的时钟。
# 破坏：a0
#------------------------------------------------------------------------------
delay_loop:
    beqz  a0, dl_end
dl_loop:
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    addi  a0, a0, -1
    bnez  a0, dl_loop
dl_end:
    ret

#------------------------------------------------------------------------------
# udiv：a0 = a0 / a1（无符号 32 位除法，移位-减法），商在 a0（余数丢弃）
#   ※ 刻意不用 `divu`：使步④ 的主频判据与打印都不依赖 M 扩展。
#   ★ 2026-09-20 **重写**（核级仿真暴露 P0）：旧实现把余数与被除数共用同一个寄存器
#     （`r = x; if (r >= d<<i) r -= d<<i`），而 `d<<i` 用的是**移位后的** d ⇒ 当 i 较大时
#     `d<<i` 溢出为小值、条件恒真却减了个错数 ⇒ 实测 `udiv(118043,2000)` 返回 118043
#     （即"商恒等于被除数"）。现改用教科书长除法：被除数逐位左移进**独立余数寄存器**，
#     与**原始除数**比较后决定商位。
#   算法（32 位，MSB 先行）—— 伪码用 '- ' 起行，避免行首 '#' 被当作 cpp 指令：
#     - q = 0; r = 0
#     - for i in 31..0:
#     -     r = (r << 1) | ((x >> i) & 1)
#     -     if (r >= d) then r -= d; q |= (1 << i)
#     - result = q
# 破坏：a0, a1, t0, t1, t2, t3, t4, t5, t6, ra
#------------------------------------------------------------------------------
udiv:
    addi  sp, sp, -32
    sw    ra, 28(sp)
    mv    t0, a0                   # t0 = 被除数 x
    mv    t1, a1                   # t1 = 除数 d
    li    t2, 0                    # t2 = 商 q
    li    t3, 0                    # t3 = 余数 r
    li    t5, 0                    # t5 = 轮数 i
    li    t4, 32
    beqz  t1, ud_zero
    #   ---- 教科书"恢复余数法"长除法（32 位无符号，MSB 先行）----
    #   每轮：q<<=1; r=(r<<1)|被除数最高位; if (r>=d) { r-=d; q+=1 }
    #   ★ 关键：商的左移必须与"把被除数位送进余数"**同拍配对**，这样第 k 个商位
    #     自然落在 bit(31-k)。位序由循环轮次决定，**不需要**任何 (1<<i) 位掩码 —— 
    #     这正是前两版出错的原因（用位掩码 + 变位序 ⇒ 商位镜像）。
ud_loop:
    slli  t2, t2, 1                # q <<= 1
    slli  t3, t3, 1                # r <<= 1
    srli  t6, t0, 31               # 被除数当前最高位
    or    t3, t3, t6               # r |= 该位
    slli  t0, t0, 1                # x <<= 1
    bltu  t3, t1, ud_skip          # r < d ⇒ 商位 0
    sub   t3, t3, t1               # r -= d
    addi  t2, t2, 1                # q 最低位置 1
ud_skip:
    addi  t5, t5, 1
    bltu  t5, t4, ud_loop
    mv    a0, t2
    j     ud_ret
ud_zero:
    li    a0, 0xFFFFFFFF           # 除零：返回全 1（本程序不会走到）
ud_ret:
    lw    ra, 28(sp)
    addi  sp, sp, 32
    ret

#==============================================================================
# 只读数据 —— ★ 所有取串都用 `lui+addi` 的**绝对地址字面量**（无重定位），
#   因此每处字符串的地址必须与 out/m5_board.dis 的 .rodata 布局**逐字对齐**
#   （build.sh 的地址自检会核对每个字符串标签的地址与源码常量一致）。
#==============================================================================
    .section .rodata
    .align   2
str_hb:
    .asciz "step1 LED heartbeat, pattern="
    .align   2
str_sw:
    .asciz "step3 switch readback = "
    .align   2
str_tick:
    .asciz "step4 timer delta ticks = "
    .align   2
str_tpi:
    .asciz ", cycles/iter = "
    .align   2
str_tpiavg:
    .asciz ", expected ticks = "
    .align   2
str_freq:
    .asciz "step5 FREQ = 0x"
    .align   2
str_freqmhz:
    .asciz " (div1e6 = "
    .align   2
str_mhz:
    .asciz " MHz)\r\n"
    .align   2
str_total:
    .asciz "RESULT: RV32GC-M5-"
    .align   2
str_ok:
    .asciz "OK"
    .align   2
str_bad:
    .asciz "BAD"
    .align   2
str_nl:
    .asciz "\r\n"
    .align   2
msg_steps:
    .asciz "step2 UART output alive; sequence = LED -> UART -> switch -> timer -> FREQ\r\n"
    .align   2
msg_boot:
    .asciz "\r\nRV32GC-M5 board test (chiplab / xc7a200tfbg676-2) @ 33MHz\r\n"
    .asciz "UART 115200 8N1 (divisor=18, PCLK=33MHz -> 114583 Bd)\r\n"
    .asciz "RESET_PC=0x1C000000 (SPI XIP), MMU off, PC-relative only\r\n"

    .end
