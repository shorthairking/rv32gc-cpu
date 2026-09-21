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
#   · 指令集：**纯 RV32I**（外加步④ 只读的 `rdcycle` ⇒ Zicsr）。
#     ★ 2026-09-21 诊断版起：十进制/十六进制打印**全部改为纯寄存器路径**（比较-减法 +
#       常量幂链），**全程序不再含任何 M 扩展指令**（build.sh 判据⑪f 机器核对反汇编）；
#       编译开关仍写 `rv32im_zicsr` 只为与工具链历史口径一致（M 指令一条也不会生成）。
#     步④ 的**时序判据**用的是本文件自写的 `udiv`（移位减法），同样不依赖 M 扩展。
#   · Zicsr：**只有**步④ 的 `rdcycle`（CSR 0xC00，核内 cycle_cnt_r 每拍 +1）——
#     用于把 CONFREG TIMER 与核周期计数做**一致性对照**（Zicntr 已由 arch-test 验证：
#     构建用 `-march=rv32im_zicsr`；不写任何 CSR，只读 cycle）。
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
#      ③ 该拍数**依赖板上 SPI Flash 时序**、不可移植 ⇒ 步④ 的判据**不能**用"绝对拍数
#         对照仿真标定值 59"（2026-09-21 鲁棒化：改为 TIMER ↔ `rdcycle` 增量一致性，
#         对 Flash 延迟不敏感；见 §三 步④）。
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
#   步2.5 ★ DDR3 回环判别（2026-09-21 新增的**诊断步**，紧跟步② 之后）：
#        写 0x12345678 到 DDR3 固定地址 `R2_PROBE_ADDR = 0x0000_8000` → `lw` 读回 →
#        对 `0x0000_8003` 做 `sb 0x5A`→`lbu` 字节回环；两个读回值都用**十六进制**打印
#        （纯寄存器路径，不经任何缓冲），并在同一行给出判别结论：
#          · 新 bitstream（含 R2 修复）⇒ `word=0x12345678`、`byte=0x5A`、`R2FIX: yes`
#          · 旧 bitstream（R2 缺陷在位）⇒ 读回垃圾（≠ 期望）、`R2FIX: no`
#        判别原理：DDR3 数据访问在核内走 **MDTA（uncached 单 beat AXI）**，正是 R2 缺陷
#        （R 握手后第 2 拍才采样 rdata）所在的通路；写通路与该缺陷无关。
#   步2.6 ★ M 扩展探针（2026-09-21 新增）：9 个固定向量（divu/remu/mul/mulh/mulhu）
#        十六进制打印 + 与本文件内置期望值逐条比对 ⇒ `MEXT: ok / BAD`。
#        为什么：RTL 的 **IP 分支**（综合走 div_gen/mult_gen）在 iverilog 里跑不了
#        （网表加密）⇒ 历次仿真回归只覆盖行为分支；2026-09-21 用 xsim + 真实 IP 实测
#        发现 div_gen 的 tdata 字段序 = {商, 余数}（RTL 原来按 {余数, 商} 取）
#        ⇒ divu/remu 商余数互换 ⇒ 十进制打印全乱（= 上板现象）。本步让它在板上可判定。
#   步2.7 ★ 栈字节通路探针（2026-09-21 新增）：把 "0123456789ABCDEF" 写进栈缓冲
#        （sp-64，DDR3）再逐字节 `lbu` 读回、两位 hex 打印 ⇒ `STACKBF: ok / BAD`
#        （检查 DDR3 字节 lane / 读回是否错位；与步2.5 一起覆盖 R2 缺陷的两条 DDR3 通路）。
#   以上三个诊断步的结论**全部并入**最终判定（与步④、步⑤ 同为判据）。
#   步③ 开关回读：读 +0xF020 → 写 LED（低 8 位）与数码管（0x3000|switch<<16），并打印。
#   步④ TIMER ↔ 核周期一致性：TIMER 清零 → 记 `rdcycle` 与 TIMER 起点 →
#        `delay_loop` 跑 MEAS_ITER=2000 次迭代 → 记 `rdcycle` 与 TIMER 终点。
#        Δcycle = rdcycle 增量（核周期）；Δtimer = TIMER 增量；cycles/iter = Δcycle/MEAS_ITER。
#        判据 A（主判据）：|Δtimer − Δcycle| ≤ max(256, Δcycle/128) —— 两者都在核时钟域
#          每拍 +1，同一窗口内增量必须相等（对 SPI Flash 取指延迟**不敏感**）。
#        判据 B（健全性窗口，**信息性，不参与判定**）：cycles/iter ∈ [20, 20000] ——
#          只打印实测值与窗口，不再据此判 BAD（见 §四下 步④ "窗口为何只打印"）。
#        ★ 2026-09-21 鲁棒化前：判据 = |ticks − 2000×59| ≤ ±40%（59 为零延迟仿真标定值）
#          ⇒ 真机 Flash 时序下不可移植；放宽窗口会退化成"看着像过"。新判据不用任何
#          绝对拍数常量（`XIP_CPI=59` 仅在打印/文档里作参考，代码不引用它）。
#   步⑤ FREQ 回读：读 +0xF030（期望 0x01F78A40 = 33 000 000），打印十六进制与 div1e6。
#   结论：步④ 判定 ∧（FREQ 高 20 位 == 31）∧（步2.5 R2 回环通过）⇒ 打印
#         `RESULT: RV32GC-M5-OK`，否则 `...-BAD`。
#
#------------------------------------------------------------------------------
# 三点五、★ 打印路径与内存无关（诊断可读性的前提，2026-09-21 诊断版重写）
#------------------------------------------------------------------------------
#   问题：旧版 `puts_dec` 把每一位数字先 `sb` 进**栈缓冲**（sp = 0x07FF_FFF0，在 DDR3），
#   再 `lbu` 读回来打印；`puts_str`/`puts_hex8`/`udiv`/`delay_ticks` 也都用栈保存 ra。
#   而 R2 缺陷（旧 bitstream）下 **DDR3 读会返回垃圾** ⇒ 十进制打印全乱，且"乱码"这一
#   现象无法区分"核坏了"还是"跑的是旧 bitstream"—— 正是本诊断版要解决的事。
#   现口径（本文件）：
#     · `puts_dec`：比较-减法 + 10 的常量幂链（10^9…10^0），**无除法、无访存、无缓冲**；
#     · `puts_hex8`/`puts_hex2`：nibble 循环，值/计数全在寄存器；
#     · `puts_str`（用 tp 当串游标）/`puts_nl`/`udiv`（ra 存 a5）/`delay_ticks`（ra 存 a5）：
#       一律**不碰栈**；`sp` 仍在启动时按上板口径初始化，但全程序**一次都不访存它**
#       （build.sh 判据⑪a 机器核对反汇编里没有任何以 x2 为基址的访存）。
#   ⇒ 全程序**唯一的 DDR3 访问** = 步2.5 的回环探针（显式地址、读回值只进寄存器）。
#     依赖的外部通路只剩：UART MMIO（写 + 有上界的 LSR 等待）、CONFREG（平台**保持型**
#     寄存器读，`confreg_syn` 口径）⇒ 即使旧 bitstream 在位，本程序也能跑完全流程并
#     明确打印 `R2FIX: no`，而不是"乱码一堆"。
#
#------------------------------------------------------------------------------
# 四、编译（见 sw/m5_board/build.sh；工具链 /opt/riscv/bin/riscv32-unknown-linux-gnu-）
#------------------------------------------------------------------------------
#   -march=rv32im_zicsr -mabi=ilp32 -mno-relax -nostdlib -ffreestanding
#   -Wl,-Ttext=0x1C000000 -Wl,-e,_start -Wl,--build-id=none
#   产物：m5_board.elf / m5_board.bin（烧写镜像）/ m5_board.hex（仿真加载）/ m5_board.dis
#         + m5_diag.bin（**诊断版镜像，与 m5_board.bin 逐字节相同**的显式命名副本，
#           便于 runbook 诊断节引用；build.sh 判据⑪g 用 cmp 核对两者一致）
#==============================================================================

    .section .text
    .globl   _start
    .option  norvc              # 全程 32 bit 指令（与冻结核的取指口径一致）
    .align   2

#------------------------------------------------------------------------------
# 寄存器用途（全部在本文件内，直进直出；不遵守 ABI 调用约定）
#   s0 = UART 基址 0x1FE001E0     s1 = CONFREG 基址 0x1FD00000
#   s2 = ★ R2 回环判定（步2.5 起；1 = 坏 / 旧 bitstream）
#        （步① 期间 s2 暂作 LED 位模式 ⇒ 步2.5 才写入本判定，无冲突）
#   s3 = 步① 心跳拍计数 → 步2.5 借用存 word 读回值 → 步④ 重新占用为 Δcycle
#   s4 = 步2.5 借用存 re-read 值 → 步④ 重新占用为 rdcycle 起点
#   s5 = 步2.5 借用存 byte 读回值 → 步④ 重新占用为 TIMER 起点
#   s6 = 步④ Δtimer               s7 = 步④ cycles/iter
#   s8 = 步④ 判定（1 = 通过）     s9 = FREQ 值（跨 puts_* 保存）
#   s10 = 最终判定（坏=1；跨 puts_* 保存）   s11 = 步④ 坏标志（跨 udiv/puts_* 保存）
#   t0..t6 = 临时；a0..a1 = 参数/返回值；a2..a7 = 子程序内部（**不跨子程序存活**）
#   tp(x4) = puts_str 的串游标（本程序不用于任何 ABI 用途）
#   ★ 纪律：一切"跨子程序存活"的值放 s 系列 —— puts_dec/puts_hex8/udiv/delay_ticks
#     会破坏 a2..a7 与 t0/t1（不再有栈保存，见 §三点五）。
#------------------------------------------------------------------------------
.equ UART_BASE,      0x1FE001E0
.equ CONF_BASE,      0x1FD00000
.equ R2_PROBE_ADDR,  0x00008000    # ★ 步2.5 的 DDR3 回环地址（见 §三 步2.5 的选址论证：
                                   #   DDR3 内、远离 Flash 程序区与栈顶；本程序无 .data/.bss）
.equ R2_PROBE_PAT,   0x12345678    #   回环写入模式（word）
.equ R2_PROBE_BYTE,  0x5A          #   回环写入模式（byte，地址 = R2_PROBE_ADDR + 3）
.equ MEAS_ITER,      2000          # 步④ delay_loop 迭代数（×≈59 拍 ≈ 1.2e5 拍 ≈ 3.5 ms）
.equ XIP_CPI,        59            # ★ **参考**标定常量：零延迟仿真内存模型下 delay_loop 的
                                   #   "每迭代拍数"（核级仿真实测 59.02）。真机 SPI Flash XIP
                                   #   实测 ≈**4120**（≈458 拍/指令）⇒ 该常量**已不参与任何判定**，
                                   #   也**不再出现在代码里**（2026-09-21 起步④ 的打印改用字符串
                                   #   字面量同时给出两种口径：board-calib=4120 / sim-calib=59）。
                                   #   保留声明只为：① 留档"仿真标定值"；② build.sh 判据⑧c/⑨d
                                   #   仍机器核对它与 runbook 的标定值一致；③ 改 delay_loop 循环体
                                   #   时必须同步改它（判据⑧ 核对循环体结构与声明的一致性）。
.equ CPI_SANITY_LO,  20            # 步④ 健全性窗口下界（**信息性**）：低于它 ⇒ 核没按拍跑
.equ CPI_SANITY_HI,  20000         # 步④ 健全性窗口上界（**信息性**）：
                                   #   ★ 2026-09-21 放宽 300 → 20000 ——上板实测约 **4120**（真机 SPI Flash
                                   #     XIP 无缓存，每取指走平台 Flash 桥 ≈458 拍/指令），而上界原按
                                   #     零延迟仿真标定值 59 的量级定为 300 ⇒ 真实标定值被判 "BAD"。
                                   #     真实口径并存：板级 **4120** / 仿真 **59**。
                                   #   ★ 该窗口**不是**主频判据（主频由步⑤ FREQ 锚定），也**不再参与判定**
                                   #     ——只打印实测值与窗口，便于一眼分辨平台差异；BAD 只由
                                   #     判据 A（TIMER ↔ rdcycle 增量一致）与步⑤ FREQ 锚定共同决定。
.equ DELAY_HB_TICKS, 8000000       # 心跳间隔 = 8e6 拍 ≈ 0.24 s @33 MHz（TIMER 拍 = 核周期）
.equ DELAY_SW_TICKS, 10000000      # 步③ 停留 = 1e7 拍 ≈ 0.3 s（便于观察 LED 跟随开关）

_start:
    # ---- 0. 基址与栈指针 ----
    lui   s0, 0x1FE00
    addi  s0, s0, 0x1E0            # s0 = 0x1FE001E0（UART）
    lui   s1, 0x1FD00              # s1 = 0x1FD00000（CONFREG）
    lui   sp, 0x08000              # 栈顶 = DDR3 末尾（0x07FF_FFF0）
    addi  sp, sp, -16
    #   ★ 2026-09-21 诊断版：sp 仍按上板口径初始化，但**全程序不再访存栈**（见 §三点五）；
    #     保留它只为口径一致 + 万一将来需要，且不产生任何 DDR3 访问。

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
    # 步2.5 ★ DDR3 回环判别（R2 缺陷探针）—— 本程序**唯一**的 DDR3 访问
    #   通路：PA 0x0000_8000 在 DDR3 默认通路上 ⇒ mmio_route 判 ROUTE_AXI
    #         ⇒ 核内走 **MDTA（uncached 单 beat AXI）**，正是 R2 缺陷（R 握手后
    #         第 2 拍才采样 rdata）所在通路；写通路与该缺陷无关。
    #   选址：DDR3 内（0x0000_0000–0x07FF_FFFF）；本程序 .text/.rodata 都在 Flash XIP
    #         0x1C00_0000，**没有** .data/.bss（build.sh 判据⑪e 机器核对），栈顶
    #         0x07FF_FFF0 且全程序不访存栈 ⇒ 0x8000 绝对安全。
    #   读回值只进寄存器（s3/s4/s5），打印走纯寄存器路径 ⇒ 判据本身不依赖 DDR3 读。
    #--------------------------------------------------------------------------
    li    t0, R2_PROBE_ADDR        # t0 = 0x00008000（li 由汇编器展开 lui+addi）
    li    t1, R2_PROBE_PAT         # t1 = 0x12345678
    sw    t1, 0(t0)                # DDR3[0x8000] <= 0x12345678（写：与 R2 缺陷无关）
    lw    t2, 0(t0)                # ★ 读回（MDTA；旧 bitstream 下 = 垃圾）
    lw    t3, 0(t0)                # 再读一次（诊断：两次读是否一致）
    li    t1, R2_PROBE_BYTE        # t1 = 0x5A
    sb    t1, 3(t0)                # DDR3[0x8003] <= 0x5A（字节回环）
    lbu   t4, 3(t0)                # ★ 按字节读回
    #   ---- 判定（极性统一"坏 = 1"）：word 或 byte 任一不匹配 ⇒ s2 = 1 ----
    li    t1, R2_PROBE_PAT
    sub   t5, t2, t1
    sltu  t5, x0, t5               # t5 = 1 ⇔ word 读回 != 0x12345678
    li    t1, R2_PROBE_BYTE
    sub   t6, t4, t1
    sltu  t6, x0, t6               # t6 = 1 ⇔ byte 读回 != 0x5A
    or    s2, t5, t6               # ★ s2 = 1 ⇔ R2 回环失败（旧 bitstream 在位）
    #   ---- 打印（数值先搬 s 系列：跨 puts_* 存活；hex 打印无需任何缓冲）----
    mv    s3, t2                   # word 首读
    mv    s4, t3                   # word 再读
    mv    s5, t4                   # byte 读回
    lui   a0, %hi(str_ddr)
    addi  a0, a0, %lo(str_ddr)
    jal   ra, puts_str             # "step2.5 DDR3 loopback: word=0x"
    mv    a0, s3
    jal   ra, puts_hex8
    lui   a0, %hi(str_ddr2)
    addi  a0, a0, %lo(str_ddr2)
    jal   ra, puts_str             # " re-read=0x"
    mv    a0, s4
    jal   ra, puts_hex8
    lui   a0, %hi(str_ddr3)
    addi  a0, a0, %lo(str_ddr3)
    jal   ra, puts_str             # " byte=0x"
    mv    a0, s5
    jal   ra, puts_hex2
    lui   a0, %hi(str_ddr4)
    addi  a0, a0, %lo(str_ddr4)
    jal   ra, puts_str             # " (expect 12345678/5A) -> R2FIX: "
    bnez  s2, ddr_stale
    lui   a0, %hi(str_yes)
    addi  a0, a0, %lo(str_yes)
    jal   ra, puts_str             # "yes"（新 bitstream / R2 修复在位）
    j     ddr_done
ddr_stale:
    lui   a0, %hi(str_no)
    addi  a0, a0, %lo(str_no)
    jal   ra, puts_str             # "no"（旧 bitstream / R2 缺陷在位）
ddr_done:
    jal   ra, puts_nl

    #--------------------------------------------------------------------------
    # 步2.6 ★ M 扩展探针（IP 分支功能自检）——纯寄存器路径 + 十六进制打印
    #   9 个固定向量（**打印顺序即下表顺序**；期望值见 runbook §4 步2.6）：
    #     ① divu(59,10)                  期望 0x00000005
    #     ② remu(59,10)                  期望 0x00000009
    #     ③ divu(118049,2000)            期望 0x0000003B
    #     ④ remu(118049,2000)            期望 0x00000031
    #     ⑤ divu(0,10)                   期望 0x00000000
    #     ⑥ divu(1,10)                   期望 0x00000000
    #     ⑦ mul(6,7)                     期望 0x0000002A（乘法也走 IP 分支：mult_gen）
    #     ⑧ mulh(0x80000000,0x80000000)  期望 0x40000000（有符号高半）
    #     ⑨ mulhu(0xFFFFFFFF,0xFFFFFFFF) 期望 0xFFFFFFFE（无符号高半）
    #   ★ 为什么必须有这一步：RTL 的 **IP 分支**（综合走 div_gen/mult_gen）在 iverilog 里
    #     跑不了（IP 网表加密，见 fpga/ip/rv32_div 下的 "_sim_netlist.v" 里带 `pragma protect`）
    #     ⇒ 历次回归只覆盖**行为分支**。2026-09-21 用 xsim + 真实 IP 实测发现：
    #     div_gen 的 `m_axis_dout_tdata` 字段序是 {商[63:32], 余数[31:0]}，而 RTL 原来按
    #     {余数, 商} 取 ⇒ **divu/remu 商余数互换** ⇒ 十进制打印全乱（正是上板现象）。
    #     本步把这个结论做成"板上可判定"：全对 ⇒ `MEXT: ok`；任一不对 ⇒ `MEXT: BAD`，
    #     并**并入最终结论**（RESULT: …-BAD）。
    #--------------------------------------------------------------------------
    li    t2, 0                    # t2 = 本步坏标志（t2 不被任何打印子程序破坏）
    lui   a0, %hi(str_mext)
    addi  a0, a0, %lo(str_mext)
    jal   ra, puts_str             # "step2.6 MEXT="
    li    t0, 59                   # ① divu(59,10)
    li    t1, 10
    divu  t3, t0, t1
    li    t4, 5
    jal   ra, mx_vec
    li    t0, 59                   # ② remu(59,10)
    li    t1, 10
    remu  t3, t0, t1
    li    t4, 9
    jal   ra, mx_vec
    li    t0, 118049               # ③ divu(118049,2000)
    li    t1, 2000
    divu  t3, t0, t1
    li    t4, 59
    jal   ra, mx_vec
    li    t0, 118049               # ④ remu(118049,2000)
    li    t1, 2000
    remu  t3, t0, t1
    li    t4, 49
    jal   ra, mx_vec
    li    t0, 0                    # ⑤ divu(0,10)
    li    t1, 10
    divu  t3, t0, t1
    li    t4, 0
    jal   ra, mx_vec
    li    t0, 1                    # ⑥ divu(1,10)
    li    t1, 10
    divu  t3, t0, t1
    li    t4, 0
    jal   ra, mx_vec
    li    t0, 6                    # ⑦ mul(6,7)
    li    t1, 7
    mul   t3, t0, t1
    li    t4, 42
    jal   ra, mx_vec
    lui   t0, 0x80000              # ⑧ mulh(-2^31,-2^31) 高半
    mv    t1, t0
    mulh  t3, t0, t1
    lui   t4, 0x40000
    jal   ra, mx_vec
    li    t0, -1                   # ⑨ mulhu(2^32-1,2^32-1) 高半
    mulhu t3, t0, t0
    li    t4, -2
    jal   ra, mx_vec
    lui   a0, %hi(str_mextv)
    addi  a0, a0, %lo(str_mextv)
    jal   ra, puts_str             # "-> MEXT: "
    bnez  t2, mx_bad
    lui   a0, %hi(str_ok)
    addi  a0, a0, %lo(str_ok)
    jal   ra, puts_str             # "ok"
    j     mx_done
mx_bad:
    lui   a0, %hi(str_bad)
    addi  a0, a0, %lo(str_bad)
    jal   ra, puts_str             # "BAD"
mx_done:
    jal   ra, puts_nl
    or    s2, s2, t2               # ★ 并入总坏标志（s2 已在步2.5 初始化）

    #--------------------------------------------------------------------------
    # 步2.7 ★ 栈字节通路探针（DDR3 字节 lane / 读回检查）
    #   把 16 字节模式 "0123456789ABCDEF" 写进**栈缓冲**（sp-64：本程序不使用的 DDR3 空间，
    #   栈顶 0x07FF_FFF0 之下 64 B），再逐字节 `lbu` 读回并按两位 hex 打印 ⇒ 直接暴露
    #   "字节路径错位 / lane 串位 / 读回垃圾"。期望（ASCII）：
    #     30 31 32 33 34 35 36 37 38 39 41 42 43 44 45 46 -> STACKBF: ok
    #   与步2.5 一起，把"旧 bitstream（R2 缺陷在 DDR3 读通路上）"钉成可见现象。
    #--------------------------------------------------------------------------
    li    t2, 0                    # 本步坏标志
    addi  t3, sp, -64              # t3 = 栈缓冲指针（DDR3）
    li    t6, 0                    # t6 = k（0..15；★ 计数/指针放 t 系列中**打印子程序不碰**的
                                   #   t2..t6 —— t0/t1 会被 puts_* 破坏）
mk_loop:
    li    t0, 9                    # ascii(k)：k<10 ⇒ '0'+k；k≥10 ⇒ 'A'+(k-10)
    bltu  t0, t6, mk_up
    addi  t4, t6, 48
    j     mk_st
mk_up:
    addi  t4, t6, 55               # 'A' - 10 = 55
mk_st:
    sb    t4, 0(t3)                # 写 DDR3 栈缓冲
    addi  t3, t3, 1
    addi  t6, t6, 1
    li    t5, 16
    bltu  t6, t5, mk_loop
    lui   a0, %hi(str_stk)
    addi  a0, a0, %lo(str_stk)
    jal   ra, puts_str             # "step2.7 stack[16B]="
    addi  t3, sp, -64
    li    t6, 0
ck_loop:
    li    t0, 9
    bltu  t0, t6, ck_up
    addi  t4, t6, 48               # t4 = 期望字节
    j     ck_ld
ck_up:
    addi  t4, t6, 55
ck_ld:
    lbu   t5, 0(t3)                # t5 = 实读字节
    sub   t4, t5, t4
    sltu  t4, x0, t4
    or    t2, t2, t4               # 累加"不匹配"
    mv    a0, t5
    jal   ra, puts_hex2            # 两位 hex（低字节）
    lui   a0, %hi(str_sp)
    addi  a0, a0, %lo(str_sp)
    jal   ra, puts_str             # 空格分隔
    addi  t3, t3, 1
    addi  t6, t6, 1
    li    t5, 16
    bltu  t6, t5, ck_loop
    lui   a0, %hi(str_stkv)
    addi  a0, a0, %lo(str_stkv)
    jal   ra, puts_str             # "-> STACKBF: "
    bnez  t2, stk_bad
    lui   a0, %hi(str_ok)
    addi  a0, a0, %lo(str_ok)
    jal   ra, puts_str
    j     stk_done
stk_bad:
    lui   a0, %hi(str_bad)
    addi  a0, a0, %lo(str_bad)
    jal   ra, puts_str
stk_done:
    jal   ra, puts_nl
    or    s2, s2, t2               # ★ 并入总坏标志

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
    # 步④ TIMER ↔ 核周期计数一致性（对 Flash 取指延迟**不敏感**）
    #   ★ 2026-09-21 鲁棒化（M5 上板暴露"绝对拍数判据不可移植"）：
    #     旧口径是"实测 ticks ≈ MEAS_ITER × XIP_CPI(=59)"——而 59 是**零延迟仿真内存模型**
    #     下的标定值；真机 SPI Flash XIP 每笔读要几十拍，实测 cycles/iter 会明显更高
    #     ⇒ 绝对窗口不可移植（放宽窗口又会把判据变成"看着像过"）。
    #     新口径（与 Flash 时序无关、且仍是**真判据**）：
    #       判据 A（主判据）：CONFREG TIMER（confreg_syn.v:346 每 clk +1）与
    #         `rdcycle`（core_top.v:3555 cycle_cnt_r 每 clk +1）处于**同一时钟域**，
    #         同一窗口内两者增量必须相等：
    #             |Δtimer − Δcycle| ≤ tol = max(256, Δcycle/128)   （≈1%，足够钉住
    #             "TIMER 没按核周期走 / 分频 / 停摆"这类会让全部可见延时失效的错）
    #       判据 B（健全性窗口，**信息性：只打印，不参与 BAD 判定**）：cycles/iter =
    #         Δcycle / MEAS_ITER 落在 [CPI_SANITY_LO, CPI_SANITY_HI] = [20, 20000]；
    #         实测值原样打印，方便"一眼看出是不是换平台/换 Flash"。
    #         ★ 为什么降级为信息性（2026-09-21 上板实测；本文件 §四下"窗口为何只打印"）：
    #           真机 SPI Flash XIP（无缓存、每取指走平台 Flash 桥）实测 ≈**4120** 拍/迭代
    #           （≈458 拍/指令），而窗口上界原按**零延迟仿真**标定值 **59** 的量级定为 300
    #           ⇒ 真实标定值被误判 BAD。真实口径两者并存：板级 4120 / 仿真 59。
    #         ★ 窗口不再是判据 ⇒ BAD 判定只由两条**真判据**决定：
    #             ① 判据 A：|Δtimer − Δcycle| ≤ max(256, Δcycle/128)（同域两计数器必须同步）
    #             ② 步⑤ FREQ 锚定：div1e6 == 33 ∧ FREQ>>20 == 31（主频口径）
    #           —— 这正是"信息性窗口"与"放水判据"的区别：放水会削弱 BAD 的触发能力，
    #              而这里被降级的那条判据，其职责已由 A（计数器一致性）+ 步⑤（主频锚定）
    #              完全覆盖；窗口只留下"一眼可见"的诊断价值。
    #   为什么这样更严：旧判据在"TIMER 完全不走"或"TIMER 被分频"时可能仍然通过
    #   （只要绝对拍数落进 ±40% 窗口），新判据直接比较两个独立计数器的增量。
    #--------------------------------------------------------------------------
    li    t5, 57344                # 0xE000 TIMER
    add   t6, s1, t5
    sw    x0, 0(t6)                # TIMER <= 0（写即清零；核保证该写完成后才发下一笔）
    rdcycle s4                     # s4 = 窗口起点：核周期计数（Zicntr，CSR 0xC00）
    lw    s5, 0(t6)                # s5 = 窗口起点：TIMER
    li    a0, MEAS_ITER
    jal   ra, delay_loop           # 固定迭代数（每迭代 ≈XIP_CPI 拍，随 Flash 时序浮动）
    rdcycle s3                     # s3 = 窗口终点：核周期计数
    sub   s3, s3, s4               # ★ s3 = Δcycle（核周期增量；步④ 内部报废，下一轮重建）
    lw    s6, 0(t6)                # s6 = 窗口终点：TIMER
    sub   s6, s6, s5               # s6 = Δtimer

    #   ---- 判据 A：|Δtimer − Δcycle| ≤ max(256, Δcycle/128) ----
    sub   t0, s6, s3               # t0 = Δtimer − Δcycle
    bgez  t0, tl_abs
    sub   t0, x0, t0               # t0 = |Δtimer − Δcycle|
tl_abs:
    srli  t1, s3, 7                # t1 = Δcycle / 128（≈1%）
    li    t2, 256                  # 容差下限（覆盖两个读点之间几条指令的固有错位）
    bltu  t1, t2, tl_tol
    mv    t2, t1
tl_tol:
    sltu  s11, t2, t0              # ★ s11(x27) = (容差 < |差值|) ⇒ 步④ **坏**（跨子程序存活：
                                   #   步⑤ 打印 div1e6 时会再调一次 udiv，而 udiv 内部用 t2 存商
                                   #   ⇒ 坏标志绝不能放 t 系列，否则被覆盖成商值 ⇒ 恒判 BAD）

    #   ---- 健全性窗口（**信息性：只打印，不参与判定**）----
    #   cycles/iter = Δcycle / MEAS_ITER 仍然算出并原样打印（见下面 str_tpiwin 一行），
    #   但不与 CPI_SANITY_LO/HI 比较、不置任何坏标志 ⇒ BAD 只由判据 A 与步⑤ FREQ 决定。
    #   ★ 删除的原逻辑：`bltu s7,LO ⇒ tp_bad` / `bltu HI,s7 ⇒ tp_bad`（曾把 s11 置 1）
    #     —— 真机 4120 落在旧窗口 [20,300] 之外会被误判（见 §四下 步④ 注释）。
    #   ★ 注意 udiv 会破坏 t0..t6（t2/t3…），故此处**不得**再用 t 系列持有坏标志；
    #     s11 原样保留（判据 A 的结论）。
    mv    a0, s3
    li    a1, MEAS_ITER
    jal   ra, udiv                 # a0 = Δcycle / MEAS_ITER = cycles/iter
    mv    s7, a0                   # s7 = cycles/iter（现场实测值，**仅用于打印**）
    xori  s8, s11, 1               # ★ s8(x24) = 1 ⇒ 步④ 通过（只由判据 A 决定；供 LED/数码管显示）

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
    jal   ra, puts_str             # "step4 timer delta = "
    mv    a0, s6
    jal   ra, puts_dec
    lui   a0, %hi(str_tpi)
    addi  a0, a0, %lo(str_tpi)
    jal   ra, puts_str             # ", cycle delta = "
    mv    a0, s3
    jal   ra, puts_dec
    lui   a0, %hi(str_tpiavg)
    addi  a0, a0, %lo(str_tpiavg)
    jal   ra, puts_str             # ", cycles/iter = "
    mv    a0, s7
    jal   ra, puts_dec
    #   ---- 窗口/标定值（**信息性 only**）：一行打印完，避免把"窗口"误读成判据 ----
    #   ★ 2026-09-21：判据 B 窗口降级为信息性（不再参与 BAD 判定，见上）；这一行继续打印
    #     实测 cycles/iter 与窗口、并同时给出**两种标定口径**（板级 4120 / 仿真 59），
    #     便于以后换平台、换 Flash 时序时一眼看出差异。三个数值都是**打印专用**。
    lui   a0, %hi(str_tpiwin)
    addi  a0, a0, %lo(str_tpiwin)
    jal   ra, puts_str             # " (informational only; window 20..20000; board-calib=4120, sim-calib=59 cycles/iter)\r\n"

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
    #   ★ 2026-09-21 诊断版：再把 步2.5 的 R2 回环坏标志（s2）并进来 —— 判定链变为
    #     "步④ 通过 ∧ FREQ>>20 == 31 ∧ R2 回环通过"，即**旧 bitstream 必然打印 BAD**
    #     （用户不必在"乱码"里猜原因：`step2.5 ... R2FIX: no` 直接给出结论）。
    or    s10, s11, t4             # s10 = 1 ⇔ 任一子判据坏（s11=步④坏, t4=FREQ坏）（用 s10：跨 puts_str/puts_nl 存活）
    or    s10, s10, s2             # ★ 并入 步2.5 的 R2 回环坏标志（s2；见 §三 步2.5）
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
# puts_str：打印 a0 指向的 NUL 结尾字符串   ★ 纯寄存器路径（不碰栈）
#   串游标用 tp(x4)（本程序不用于 ABI 用途）；ra 存 a2（puts_char 不破坏 a2）。
#   注：串本身在 .rodata（Flash XIP ⇒ L1D/直连通路），与栈无关。
# 破坏：a0, a1, a2, t0, t1, ra（tp 为内部游标）
#------------------------------------------------------------------------------
puts_str:
    mv    a2, ra                   # a2 = 返回地址
    mv    tp, a0                   # tp = 串游标
ps_loop:
    lbu   a0, 0(tp)
    beqz  a0, ps_end
    jal   ra, puts_char
    addi  tp, tp, 1
    j     ps_loop
ps_end:
    mv    ra, a2
    ret

#------------------------------------------------------------------------------
# puts_nl：打印 CRLF   ★ 纯寄存器路径
# 破坏：a0, a1, a2, t0, t1, ra
#------------------------------------------------------------------------------
puts_nl:
    mv    a2, ra
    addi  a0, x0, 13
    jal   ra, puts_char
    addi  a0, x0, 10
    jal   ra, puts_char
    mv    ra, a2
    ret

#------------------------------------------------------------------------------
# puts_dec：打印 a0 的无符号十进制（无前导零）—— ★ 纯寄存器路径：无访存、无缓冲、无除法
#   算法：把 10 的幂（10^9 … 10^0）**逐条常量装载**（`li` = lui+addi：无查表、无访存），
#         每位调 pd_one —— digit = 余值里能减几次当前幂（p 是 10 的幂 ⇒ digit ≤ 9），
#         打印 '0'+digit；前导零抑制：digit==0 且尚未开始打印且 p != 1 ⇒ 跳过
#         （p == 1 必打印 ⇒ v=0 也印出 "0"）。
#   为什么必须这么写（本诊断版的根因之一）：见文件头 §三点五 —— 旧版把数字写进**栈缓冲**
#   （sp 在 DDR3）再用 lbu 读回，而 R2 缺陷（旧 bitstream）下 DDR3 读回垃圾 ⇒ 十进制全乱、
#   且掩盖"跑的是旧 bitstream"这一根因。现在十进制打印**与存储系统完全无关**。
#   历史（2026-09-20）：旧版还用 `or t6,t6,t5` 累积退出条件 ⇒ 商降到 0 后死循环、写穿
#   DDR3 上限；本次重写一并消除该类缺陷（无写指针、无缓冲、无越界可能）。
# 破坏：a0, a1, a2, a3, a4, a5, a6, a7, t0, t1, ra
#------------------------------------------------------------------------------
puts_dec:
    mv    a2, ra                   # a2 = 返回地址（寄存器保存；本程序不用栈）
    mv    a3, a0                   # a3 = 余值
    li    a5, 0                    # a5 = "已开始打印"标志（前导零抑制用）
    li    a4, 1000000000           # 10^9
    jal   ra, pd_one
    li    a4, 100000000
    jal   ra, pd_one
    li    a4, 10000000
    jal   ra, pd_one
    li    a4, 1000000
    jal   ra, pd_one
    li    a4, 100000
    jal   ra, pd_one
    li    a4, 10000
    jal   ra, pd_one
    li    a4, 1000
    jal   ra, pd_one
    li    a4, 100
    jal   ra, pd_one
    li    a4, 10
    jal   ra, pd_one
    li    a4, 1
    jal   ra, pd_one
    mv    ra, a2
    ret

#------------------------------------------------------------------------------
# pd_one：打印"一位"十进制数字（幂在 a4、余值在 a3、抑制标志在 a5）
#   digit = a3 里能连续减几次 a4；减完后的余值留在 a3（供更低位的幂继续用）。
# 破坏：a0, a1, a6, a7, t0, t1, ra（a2/a3/a4/a5 由调用者持有，本子程序不破坏）
#------------------------------------------------------------------------------
pd_one:
    mv    a7, ra                   # a7 = 返回地址（puts_char 只破坏 t0/t1/a1）
    li    a6, 0                    # a6 = 该位数字
pd_sub:
    bltu  a3, a4, pd_sub_end       # 余值 < 当前幂 ⇒ 该位减法结束
    sub   a3, a3, a4
    addi  a6, a6, 1
    j     pd_sub
pd_sub_end:
    bnez  a6, pd_emit              # digit != 0 ⇒ 打印（含中间位的 0）
    bnez  a5, pd_emit              # 已开始打印 ⇒ 这个 0 也要打印
    li    t0, 1
    bne   a4, t0, pd_one_end       # 既没开始、又不是最低位 ⇒ 前导零，跳过
pd_emit:
    li    a5, 1                    # 标记"已开始打印"
    addi  a0, a6, 48               # '0' + digit
    jal   ra, puts_char
pd_one_end:
    mv    ra, a7
    ret

#------------------------------------------------------------------------------
# mx_vec：打印一个 M 扩展探针向量（t3 = 实值、t4 = 期望值），
#         并以 `t2 |= (实值 != 期望)` 累加坏标志（t2 不被任何打印子程序破坏）。
#   ★ 入参走 t3/t4（**不是** a0/a1）：a 系列与 t0/t1 会被 puts_* 破坏，
#     而本程序坚持"跨子程序存活的值放打印子程序不碰的寄存器"（见 §三点五）。
# 破坏：a0, a1, a3, a4, a5, a6, a7, t0, t1, ra（t2/t3/t4 由调用者持有）
#------------------------------------------------------------------------------
mx_vec:
    mv    a5, ra                   # a5 = 返回地址
    sub   a6, t3, t4
    sltu  a6, x0, a6               # a6 = 1 ⇔ 实值 ≠ 期望
    or    t2, t2, a6               # 累加坏标志
    mv    a0, t3
    jal   ra, puts_hex8            # 打印 8 位 hex
    lui   a0, %hi(str_sp)
    addi  a0, a0, %lo(str_sp)
    jal   ra, puts_str             # 空格分隔
    mv    ra, a5
    ret

#------------------------------------------------------------------------------
# puts_hex8 / puts_hex2：打印 a0 的 8 位 / 2 位十六进制（大写，无前缀）
#   ★ 纯寄存器路径（不碰栈）：值放 a3、nibble 计数放 a4、ra 存 a7。
#   puts_hex2 只看**低 8 bit**（先左移 24 位，把目标字节移到最高 nibble 位置）。
# 破坏：a0, a1, a3, a4, a6, a7, t0, t1, ra
#------------------------------------------------------------------------------
puts_hex8:
    li    a4, 8                    # 8 个 nibble
    j     ph_enter
puts_hex2:
    slli  a0, a0, 24               # 低 8 bit ⇒ 最高字节（统一走 nibble 循环）
    li    a4, 2                    # 2 个 nibble
ph_enter:
    mv    a7, ra                   # a7 = 返回地址（puts_char 只破坏 t0/t1/a1）
    mv    a3, a0                   # a3 = 值
ph_loop:
    srli  a0, a3, 28               # 当前最高 nibble
    li    t0, 10
    bltu  a0, t0, ph_digit
    addi  a0, a0, 55               # 10..15 ⇒ 'A'..'F'
    j     ph_emit
ph_digit:
    addi  a0, a0, 48               # 0..9 ⇒ '0'..'9'
ph_emit:
    jal   ra, puts_char
    slli  a3, a3, 4                # 下一个 nibble 升到最高位
    addi  a4, a4, -1
    bnez  a4, ph_loop
    mv    ra, a7
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
    mv    a5, ra                   # ★ 返回地址存 a5（本程序不用栈）
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
    mv    ra, a5
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
    mv    a5, ra                   # ★ 返回地址存 a5（本程序不用栈；见文件头 §三点五）
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
    mv    ra, a5                   # ★ 从 a5 取回返回地址（不再从栈读 —— 旧 bitstream 下栈读会读回垃圾）
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
    .asciz "step4 timer delta = "
    .align   2
str_tpi:
    .asciz ", cycle delta = "
    .align   2
str_tpiavg:
    .asciz ", cycles/iter = "
    .align   2
str_tpiwin:
    #   ★ 一行打印完（**informational only** = 不参与 BAD 判定，只供人眼分辨平台差异）：
    #     实测 cycles/iter 已在前一条 puts_dec 打印；这里给窗口与**两种标定口径**：
    #       板级 board-calib = 4120（真机 SPI Flash XIP 实测，每取指 ≈458 拍）、
    #       仿真 sim-calib   = 59（零延迟仿真内存模型标定）。
    #     ★ 该 `.asciz` 必须在**同一条**里写完（GNU as 每条 `.asciz` 都补 NUL；见文件头 §三点五）。
    #     ★ 文本里**不得出现**被 build.sh 判据⑨d 正则（`cycles/iter[^0-9]*[0-9]+`）误抓的数字：
    #       仿真标定值 59 必须紧跟 "cycles/iter"（紧邻才是 XIP_CPI 口径）。
    .asciz " (informational only; window 20..20000; board-calib=4120, sim-calib=59 cycles/iter)\r\n"
    .align   2
#   ---- 步2.5 DDR3 回环判别的打印串（拼成一行；R2FIX 结论在行尾，便于 grep）----
str_ddr:
    .asciz "step2.5 DDR3 loopback: word=0x"
    .align   2
str_ddr2:
    .asciz " re-read=0x"
    .align   2
str_ddr3:
    .asciz " byte=0x"
    .align   2
str_ddr4:
    .asciz " (expect 12345678/5A) -> R2FIX: "
    .align   2
str_yes:
    .asciz "yes"
    .align   2
str_no:
    .asciz "no"
    .align   2
str_freq:
    .asciz "step5 FREQ = 0x"
    .align   2
#   ---- 步2.6 M 扩展探针 / 步2.7 栈字节探针的打印串 ----
str_mext:
    .asciz "step2.6 MEXT="
    .align   2
str_mextv:
    .asciz "-> MEXT: "
    .align   2
str_stk:
    .asciz "step2.7 stack[16B]="
    .align   2
str_stkv:
    .asciz "-> STACKBF: "
    .align   2
str_sp:
    .asciz " "
    .align   2
str_pat:
    .asciz "0123456789ABCDEF"     # 步2.7 的 16 字节模式（字节 = 位置指纹，便于发现 lane 错位）
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
    .asciz "step2 UART output alive; sequence = LED -> UART -> DDR3-R2-probe -> switch -> timer -> FREQ\r\n"
    .align   2
msg_boot:
    #   ★ 2026-09-21 修复（诊断版顺带暴露）：GNU as 的 `.asciz` **每条都会补一个 NUL**，
    #     所以下面这些行必须写在**同一条** `.asciz` 里（用 `\r\n` 转义），否则 `puts_str`
    #     读到第一个 NUL 就返回 —— 旧版把三行拆成三条 `.asciz` ⇒ 上板只打印第 1 行，
    #     runbook §4 期望的 `UART 115200 …` / `RESET_PC=…` 两行**从来没打出来过**。
    #     机器护栏：build.sh 判据⑪h 核对 .rodata 里横幅四行**首尾相接**（中间无 NUL）。
    .asciz "\r\nRV32GC-M5 board test (chiplab / xc7a200tfbg676-2) @ 33MHz\r\nBUILD=m5_board-diag-2026-09-21d (stack-free prints; R2+MEXT+stack probes; CPI window informational)\r\nUART 115200 8N1 (divisor=18, PCLK=33MHz -> 114583 Bd)\r\nRESET_PC=0x1C000000 (SPI XIP), MMU off, PC-relative only\r\n"

    .end
