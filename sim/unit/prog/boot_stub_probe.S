#==============================================================================
# rv32gc-cpu/sim/unit/prog/boot_stub_probe.S —— 引导桩 TB 的"迷你 OpenSBI"占位程序
#==============================================================================
# 项目 : rv32gc-cpu（阶段三 B-3.5 引导桩仿真验证）
# 用途 : 仿真里不跑真 OpenSBI。TB 把本程序的字**填进 SPI Flash 的 OpenSBI 段**
#        （偏移 = 引导桩段表里的 BOOT_SRC_OPENSBI），引导桩把它按**同一份段表**
#        拷到 DDR3 0x0100_0000 后跳过去执行。于是：
#          · 本程序**能跑起来** ⇒ 拷贝真的逐字节正确（指令错一条就会跑飞/超时）；
#          · 本程序把进入时的 a0/a1/a2 写进 DDR3 邮箱 ⇒ TB 可判定"入口寄存器口径"
#            （a0 = hartid = 0、a1 = DTB 物理地址 = 0x0300_0000、a2 = 0）；
#          · 邮箱里的 MAGIC 即"桩 → payload"整条链跑通的可观测终点。
#
# 约束（与引导桩同口径）：
#   · 纯 RV32I、norvc、**无 CSR 指令**、**无栈/无 ra**（不用 sp，不 call）；
#   · 只做 5 笔 sw 到 DDR3 邮箱，然后原地停机（不访问任何外设 ⇒ TB 侧可判定
#     "DDR 写只出现在预期区域"）。
#
# 邮箱（DDR3 0x0080_0000，远离三段 payload 目的区与本 TB 判定区）：
#   +0x00 a0（hartid）  +0x04 a1（DTB 物理地址）  +0x08 a2  +0x0C MAGIC  +0x10 SIG
#
# 编译（由 sw/boot/check_stub_layout.sh 的 --update-sim-words 调用；可手动复现）：
#   riscv32-unknown-linux-gnu-gcc -march=rv32i -mabi=ilp32 -mno-relax -nostdlib \
#     -nostartfiles -ffreestanding -Wl,-Ttext=0x01000000 -Wl,-e,_probe_start \
#     -Wl,--build-id=none -o probe.elf sim/unit/prog/boot_stub_probe.S
#   riscv32-unknown-linux-gnu-objcopy -O binary probe.elf probe.bin
#==============================================================================

    .equ PROBE_MBOX,   0x00800000      # DDR3 邮箱基址（本 TB 判定用；TB 侧独立复核）
    .equ PROBE_MAGIC,  0xB007A5A5      # "桩已把 payload 拷到 DDR 并跳转入执行"的终点标志
    .equ PROBE_SIG,    0x5A5AB007      # 附加签名（防"只有前 4 笔写、后面写丢"）

    .section .text.init, "ax", @progbits
    .globl   _probe_start
    .align   2
    .option  norvc

_probe_start:
    li      t0, PROBE_MBOX
    sw      a0, 0(t0)                  # 桩传的 a0（hartid）
    sw      a1, 4(t0)                  # 桩传的 a1（DTB 物理地址）
    sw      a2, 8(t0)                  # 桩传的 a2（平台私有信息）
    li      t1, PROBE_MAGIC
    sw      t1, 12(t0)                 # 终点标志：TB 轮询它判定"整条链跑通"
    li      t1, PROBE_SIG
    sw      t1, 16(t0)                 # 附加签名

_probe_halt:
    j       _probe_halt                # 原地停机（TB 在标志出现后再采样 DDR 内容）
