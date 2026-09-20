#==============================================================================
# sw/m5_board/tb/ctrl/ct_selftest.S —— 控制实验 A：**测试台自检程序**
#==============================================================================
# 定位：这不是被测程序，而是"测试台的测试台"：用一个**独立编写的最小程序**把
#       TB 的三件能力一次性点亮，从而证明下面这条判定链真的有效：
#         ① CONFREG 地址过滤层能把 0x1FD0_xxxx 截下来并正确响应（LED 写/读、
#            数码管写/读、switch 只读、TIMER 自由运行+写清零、FREQ 只读常量）；
#         ② UART 0x1FE001E0 写捕获 → TB 的子串匹配（C2/C3 两条锚点串）；
#         ③ 复位取指 0x1C00_0000（C1）。
#       预期：TB 打印唯一 PASS 行（C0–C5 全过）。
# 说明：UART 直写 THR、**不查 LSR**（本程序只验证捕获通路；LSR 不是本 TB 的判据）。
# 编译：sw/m5_board/tb/ctrl/build_ctrl.sh（同一套 -march=rv32im -mno-relax 口径）
#==============================================================================
    .section .text
    .globl   _start
    .option  norvc
    .align   2

_start:
    # ---- 栈指针（本程序用栈保存 ra/串指针；放在 DDR3 顶部下方，与 m5_board.S 同口径）----
    lui   sp, 0x08000
    addi  sp, sp, -16

    # ---- UART 初始化（与 m5_board.S 同口径：FCR/DLAB/DLL/DLM/LCR）----
    lui   s0, 0x1FE00
    addi  s0, s0, 0x1E0
    addi  t0, x0, 0x47
    sb    t0, 2(s0)
    addi  t0, x0, 0x80
    sb    t0, 3(s0)
    addi  t0, x0, 18
    sb    t0, 0(s0)
    sb    x0, 1(s0)
    addi  t0, x0, 0x03
    sb    t0, 3(s0)

    # ---- C2 锚点串 ----
    lui   a0, %hi(m_c2)
    addi  a0, a0, %lo(m_c2)
    jal   ra, puts

    # ---- CONFREG 五寄存器：LED 写+回读 ----
    li    t6, 0x1FD0F000
    li    t0, 0x1234
    sw    t0, 0(t6)                 # LED <= 0x1234
    lw    s2, 0(t6)                 # LED 回读（期望 0x00001234）

    # ---- 数码管写 + 回读 ----
    li    t6, 0x1FD0F010
    sw    s2, 0(t6)                 # 数码管 <= LED 回读值
    lw    s3, 0(t6)                 # 回读（期望 0x00001234）

    # ---- switch 只读 ----
    li    t6, 0x1FD0F020
    lw    s4, 0(t6)                 # 期望 0x000000A5（TB 参数 SWITCH_VAL）

    # ---- TIMER 写清零 → 读 → 短延时 → 再读 ----
    li    t6, 0x1FD0E000
    sw    x0, 0(t6)                 # 写任意值即清零
    lw    s5, 0(t6)                 # 起始值（期望极小）
    li    a0, 300
    jal   ra, delay
    li    t6, 0x1FD0E000
    lw    s6, 0(t6)                 # 结束值
    sub   s6, s6, s5                # ticks（期望 > 0）

    # ---- FREQ 只读常量 ----
    li    t6, 0x1FD0F030
    lw    s7, 0(t6)                 # 期望 0x01F78A40 = 33000000

    # ---- 观测值打到 UART（供日志逐项核对）----
    lui   a0, %hi(m_led)
    addi  a0, a0, %lo(m_led)
    jal   ra, puts
    mv    a0, s2
    jal   ra, puts_hex

    lui   a0, %hi(m_seg)
    addi  a0, a0, %lo(m_seg)
    jal   ra, puts
    mv    a0, s3
    jal   ra, puts_hex

    lui   a0, %hi(m_sw)
    addi  a0, a0, %lo(m_sw)
    jal   ra, puts
    mv    a0, s4
    jal   ra, puts_hex

    lui   a0, %hi(m_tick)
    addi  a0, a0, %lo(m_tick)
    jal   ra, puts
    mv    a0, s6
    jal   ra, puts_hex

    lui   a0, %hi(m_freq)
    addi  a0, a0, %lo(m_freq)
    jal   ra, puts
    mv    a0, s7
    jal   ra, puts_hex

    # ---- C3 锚点串 ----
    lui   a0, %hi(m_ok)
    addi  a0, a0, %lo(m_ok)
    jal   ra, puts
    jal   ra, nl

hang:
    j     hang

#------------------------------------------------------------------------------
# puts：a0 = NUL 结尾串指针；直写 THR（不查 LSR）
#------------------------------------------------------------------------------
puts:
    addi  sp, sp, -16
    sw    ra, 12(sp)
    sw    a0, 8(sp)
ps_l:
    lw    a0, 8(sp)
    lbu   t0, 0(a0)
    beqz  t0, ps_e
    sb    t0, 0(s0)
    addi  a0, a0, 1
    sw    a0, 8(sp)
    j     ps_l
ps_e:
    lw    ra, 12(sp)
    addi  sp, sp, 16
    ret

#------------------------------------------------------------------------------
# puts_hex：a0 = 32 bit 值 → 8 位大写十六进制
#------------------------------------------------------------------------------
puts_hex:
    addi  sp, sp, -16
    sw    ra, 12(sp)
    sw    a0, 8(sp)
    addi  t3, x0, 8
ph_l:
    lw    t0, 8(sp)
    srli  t0, t0, 28
    addi  t1, x0, 10
    bltu  t0, t1, ph_d
    addi  t0, t0, 55
    j     ph_e
ph_d:
    addi  t0, t0, 48
ph_e:
    sb    t0, 0(s0)
    lw    t0, 8(sp)
    slli  t0, t0, 4
    sw    t0, 8(sp)
    addi  t3, t3, -1
    bnez  t3, ph_l
    lw    ra, 12(sp)
    addi  sp, sp, 16
    ret

#------------------------------------------------------------------------------
# nl：CRLF
#------------------------------------------------------------------------------
nl:
    addi  sp, sp, -16
    sw    ra, 12(sp)
    addi  t0, x0, 13
    sb    t0, 0(s0)
    addi  t0, x0, 10
    sb    t0, 0(s0)
    lw    ra, 12(sp)
    addi  sp, sp, 16
    ret

#------------------------------------------------------------------------------
# delay：忙等 a0 次迭代（2 条指令/迭代）
#------------------------------------------------------------------------------
delay:
    beqz  a0, de
dl:
    addi  a0, a0, -1
    bnez  a0, dl
de:
    ret

#==============================================================================
    .section .rodata
    .align   2
m_c2:
    .asciz "CT-SELFTEST(control A): RV32GC-M5 board test\r\n"
m_led:
    .asciz "  LED    readback = 0x"
m_seg:
    .asciz "\r\n  SEG    readback = 0x"
m_sw:
    .asciz "\r\n  SWITCH readback = 0x"
m_tick:
    .asciz "\r\n  TIMER  delta    = 0x"
m_freq:
    .asciz "\r\n  FREQ   readback = 0x"
m_ok:
    .asciz "\r\nRESULT: RV32GC-M5-OK (control A: harness self-test)\r\n"

    .end
