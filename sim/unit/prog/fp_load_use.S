#==============================================================================
# fp_load_use.S —— FP load-use 互锁回归程序（单元 TB tb_fp_load_use.sv 的程序真源）
#==============================================================================
# 目标：任何「FP load（flw/fld）后紧邻消费其结果」的程序都必须得到正确结果。
#
# 分区（关键，别改成单区）：
#   · `.boot` 放复位向量窗口 0x1C00_0000（板级 XIP）——RESET_PC 只能在这里；
#   · `.main` 放 RAM 0x8000_0000 —— 取指走 L1I（可缓存区）；数据区 0x8000_0400。
#
# ★ 为什么每组前面都有一条 `div t2,t5,t6`（本测试能生效的关键，别删）：
#   本基线核的取指单元"一次只取一条、且响应只在 pipe_adv=1 的拍才被接收"
#   （实测取指吞吐 ≈ 1 条 / 2 拍）⇒ 只要流水一停（如访存占住 M），E 槽后一位
#   必然插进一个取指气泡，于是"load 后紧邻的消费者"实际总在 load 完成之后
#   才进 E —— 缺陷被取指气泡掩蔽（实测：整段无停顿的相邻序列测不出洞）。
#   在每组前放一条多拍除法（MDU 34 拍 E 级停顿）即可让取指把
#   「fld」与「消费者」都送进 F/D 缓冲，从而真实出现
#   「消费者在 E、生产者在 M 且未完成」的状态（TB 判据 C6 会显式检查该状态
#   确实出现过；不出现则 TB FAIL，绝不静默空跑）。
#   `div t2,t5,t6`（100/7=14）无任何副作用，只提供停顿。
#
# 数据布局（a0 = 0x8000_0400；小端：低字在低地址）：
#   +0  : D3 = 3.0  = {hi 0x4008_0000, lo 0x0000_0000}   ⇒ +0=0, +4=0x40080000
#   +8  : S3 = 3.0f = 0x4040_0000
#   +16 : A  = fld→fadd.d  (fs1=fs2=载入值，紧邻)       期望 6.0  = 0x4018_0000_0000_0000
#   +24 : B  = flw→fadd.s  (fs1=fs2=载入值，紧邻)       期望 6.0f = 0x40C0_0000
#   +32 : C  = fld→fmadd.d (fs1/fs2 与 fs3 都是载入值)  期望 12.0 = 0x4028_0000_0000_0000
#   +48 : D1 = fld→fsd     (load→FP store 存数，紧邻)   期望 3.0
#   +56 : D2 = flw→fsw     (load→FP store 存数，紧邻)   期望 3.0f
#   +64 : E  = flw→fmv.x.w (load→FP→整数搬移，紧邻)     期望 0x4040_0000
#   +72 : F  = fld→(1 条间隔)→fadd.d（写优先旁路既有通路）期望 6.0
#   +96 : 完成标志 0x5A5A_A5A5（最后一条 store）
#
# 汇编（真源可复现；.option norvc ⇒ 全 4 B 指令）：
#   riscv32-unknown-linux-gnu-gcc -march=rv32imafdc -mabi=ilp32d -mno-relax \
#       -nostdlib -nostartfiles \
#       -Wl,--section-start=.boot=0x1C000000,--section-start=.main=0x80000000 \
#       -o fp_load_use.elf sim/unit/prog/fp_load_use.S
#   riscv32-unknown-linux-gnu-objcopy -O binary --only-section=.boot ... boot.bin（2 字）
#   riscv32-unknown-linux-gnu-objcopy -O binary --only-section=.main ... main.bin（44 字）
#==============================================================================
    .option norvc

#------------------------------------------------------------------------------
# 复位桩（XIP 窗口 0x1C00_0000）：跳到 RAM 里的主程序
#------------------------------------------------------------------------------
    .section .boot, "ax", @progbits
    .globl _boot
_boot:
    lui   t0, 0x80000            # t0 = 0x8000_0000
    jalr  x0, 0(t0)              # 跳到主程序（取指随之切入可缓存区）

#------------------------------------------------------------------------------
# 主程序（RAM 0x8000_0000；取指走 L1I）
#------------------------------------------------------------------------------
    .section .main, "ax", @progbits
    .globl _start
_start:
    #---- 使能 FP：复位后 mstatus.FS = OFF，任何 FP 指令都会触发非法指令陷阱 ----
    li    t0, 0x6000             # mstatus.FS = 3（Dirty）
    csrw  mstatus, t0
    lui   a0, 0x80000
    addi  a0, a0, 0x400          # a0 = 0x8000_0400（数据区）
    sw    x0, 0(a0)              # D3 低字 = 0
    lui   t0, 0x40080
    sw    t0, 4(a0)              # D3 高字 ⇒ 3.0
    lui   t1, 0x40400
    sw    t1, 8(a0)              # S3 = 3.0f
    li    t5, 100
    li    t6, 7                  # div 操作数（结果写 t2，无副作用）

    #---- A: fld → fadd.d（紧邻；fs1=fs2=载入值）----
    div   t2, t5, t6
    fld   f0, 0(a0)
    fadd.d f2, f0, f0
    fsd   f2, 16(a0)

    #---- B: flw → fadd.s（紧邻；fs1=fs2=载入值）----
    div   t2, t5, t6
    flw   f3, 8(a0)
    fadd.s f4, f3, f3
    fsw   f4, 24(a0)

    #---- C: fld → fmadd.d（紧邻；fs1/fs2/fs3 都是载入值）----
    div   t2, t5, t6
    fld   f5, 0(a0)
    fmadd.d f6, f5, f5, f5
    fsd   f6, 32(a0)

    #---- D1: fld → fsd（紧邻；load→FP store 存数）----
    div   t2, t5, t6
    fld   f7, 0(a0)
    fsd   f7, 48(a0)

    #---- D2: flw → fsw（紧邻）----
    div   t2, t5, t6
    flw   f8, 8(a0)
    fsw   f8, 56(a0)

    #---- E: flw → fmv.x.w（紧邻；FP→整数搬移）----
    div   t2, t5, t6
    flw   f9, 8(a0)
    fmv.x.w t3, f9
    sw    t3, 64(a0)

    #---- F: fld → 1 条间隔 → fadd.d（走 fregfile 写优先旁路；回归"不误伤"）----
    div   t2, t5, t6
    fld   f10, 0(a0)
    addi  t4, x0, 123
    fadd.d f11, f10, f10
    fsd   f11, 72(a0)

    #---- 完成标志（最后一条 store；TB 见到它即判"程序跑完"）----
    lui   t5, 0x5A5AA
    addi  t5, t5, 0x5A5
    sw    t5, 96(a0)
1:  j     1b
