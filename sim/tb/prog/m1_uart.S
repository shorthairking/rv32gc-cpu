#==============================================================================
# sim/tb/prog/m1_uart.S —— M1 里程碑判据汇编程序（裸机取指 + UART 回显）
#==============================================================================
# 项目  : rv32gc-cpu（阶段二 2A）
# 归属  : docs/design/08-baseline-5stage.md §2 M1（"核能从 RESET_PC=0x1C00_0000
#         取出第一条指令，执行足够的手写指令序列，向 UART 打印固定字符串"）
# 链接  : -Ttext=0x1C000000（SPI XIP 主窗口，见 docs/kb/platform-facts.md §2.3）
# 生成  : riscv32-unknown-linux-gnu-as -march=rv32im_zicsr -o m1_uart.o m1_uart.S
#         riscv32-unknown-linux-gnu-ld -Ttext=0x1C000000 -o m1_uart.elf m1_uart.o
#         riscv32-unknown-linux-gnu-objcopy -O verilog --verilog-data-width=4 \
#             m1_uart.elf sim/tb/prog/m1_uart.hex
#------------------------------------------------------------------------------
# 行为（与 M1 判据一一对应）：
#   ① 第一条指令就在 0x1C00_0000（复位取指地址 ⇒ TB 观察到首笔 AR 地址）；
#   ② 顺序执行，向 UART 数据寄存器 **0x1FE0_01E0** 逐字节写入
#      "RV32GC-M1-OK\r\n"（14 字符，每字符 1 次 sb）；
#   ③ 写完后进入 `1: j 1b` 死循环（不再产生任何副作用）。
#
# 约束遵守（不许越界）：
#   · **不依赖栈**：全程不使用 sp / 函数调用 / 保存恢复 ⇒ 无需初始化栈指针；
#   · **单段**：全部代码在 .text 一段内，链接到 0x1C00_0000；无 .rodata/.data
#     （字符串不用内存常量，改用"立即数 → 寄存器 → sb"逐字符直接构造，
#     因此程序里**没有任何 load**，不触碰 XIP 窗口的数据读通路）；
#   · **无 MMU / 无 CSR 复杂操作**：不写 satp/mstatus，不执行 ecall；
#   · 指令集合为 RV32I 基本子集：lui / addi / sb / jal（`j` 伪指令），
#     均为 32 bit 指令（`.option norvc` 显式关闭压缩，避免 C 展开参与 M1 判据）；
#   · 不依赖前一条指令的写回结果之外的任何时序假设（sb 逐条串行，无 RAW 冒险
#     需要的额外空转——流水线自身负责旁路/停顿）。
#
# 判据对照：TB（sim/tb/tb_core_top.sv）在 AXI 上观察到：
#   · 首笔 AR 地址 = 0x1C00_0000；
#   · 对 0x1FE0_01E0 的 AW/W 写，按序捕获到 14 个字节 = "RV32GC-M1-OK\r\n"。
#==============================================================================

    .section .text
    .globl   _start
    .option  norvc              # 全程 32 bit 指令（M1 不测压缩指令）
    .align   2                  # 4 B 对齐：一条指令 = 一个取指字，直视可取
_start:
    # ---- 构造 UART 数据寄存器地址 0x1FE0_01E0 ----
    #   lui  0x1FE00   ⇒ 0x1FE0_0000（高 20 位立即数，低 12 位补 0）
    #   addi 0x1E0     ⇒ +0x1E0（480，正数，无符号扩展歧义）
    lui    t0, 0x1FE00          # t0 = 0x1FE0_0000
    addi   t0, t0, 0x1E0        # t0 = 0x1FE0_01E0 = UART 数据寄存器

    # ---- "RV32GC-M1-OK\r\n" 逐字符写出 ----
    # 每字符 = addi(t1, x0, imm) + sb(t1, 0(t0))；imm 都在 0..127 内，addi 立即数安全
    addi   t1, x0, 0x52         # 'R'
    sb     t1, 0(t0)
    addi   t1, x0, 0x56         # 'V'
    sb     t1, 0(t0)
    addi   t1, x0, 0x33         # '3'
    sb     t1, 0(t0)
    addi   t1, x0, 0x32         # '2'
    sb     t1, 0(t0)
    addi   t1, x0, 0x47         # 'G'
    sb     t1, 0(t0)
    addi   t1, x0, 0x43         # 'C'
    sb     t1, 0(t0)
    addi   t1, x0, 0x2D         # '-'
    sb     t1, 0(t0)
    addi   t1, x0, 0x4D         # 'M'
    sb     t1, 0(t0)
    addi   t1, x0, 0x31         # '1'
    sb     t1, 0(t0)
    addi   t1, x0, 0x2D         # '-'
    sb     t1, 0(t0)
    addi   t1, x0, 0x4F         # 'O'
    sb     t1, 0(t0)
    addi   t1, x0, 0x4B         # 'K'
    sb     t1, 0(t0)
    addi   t1, x0, 0x0D         # '\r'
    sb     t1, 0(t0)
    addi   t1, x0, 0x0A         # '\n'
    sb     t1, 0(t0)

    # ---- 死循环（不再产生新请求；TB 在此期间完成 UART 判据）----
1:  j      1b                   # jal x0, 1b —— 原地自跳

    .size   _start, . - _start
