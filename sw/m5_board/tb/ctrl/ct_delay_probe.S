#==============================================================================
# sw/m5_board/tb/ctrl/ct_delay_probe.S —— 控制实验 C：步④ 延时循环的"每轮周期数"实测
#==============================================================================
# 定位：不是被测程序。目的只有一个 —— 用**与 m5_board.S 逐字相同的 delay_loop**
#       （7×nop + addi + bnez = 9 条指令）配合 CONFREG TIMER（0x1FD0E000，自由运行、
#       写清零）实测 `cycles/iter`，从而给出步④ 判据 `|tpi16−524288| ≤ 131072`
#       （⇒ cycles/iter ∈ [6,10]）在本核 + 本仿真环境下是否可满足的硬数据。
# 输出：UART 上打印 "CT-DELAY-PROBE ticks=0x<hex> cycles/iter x100=0x<hex>"
#       （cycles/iter × 100，避免小数）。
# 说明：UART 直写 THR、不查 LSR；不做任何判定 ⇒ 本程序**不是** TB 的 PASS 目标
#       （TB 会因 C3 未命中等判 FAIL，这是预期的）。
#==============================================================================
    .section .text
    .globl   _start
    .option  norvc
    .align   2

.equ N_PROBE, 2000

_start:
    lui   sp, 0x08000
    addi  sp, sp, -16

    # UART 初始化
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

    # TIMER 清零 → 起始值
    li    t6, 0x1FD0E000
    sw    x0, 0(t6)
    lw    s4, 0(t6)

    # ★ 与 m5_board.S 逐字相同的 delay_loop
    li    a0, N_PROBE
    jal   ra, delay_loop

    li    t6, 0x1FD0E000
    lw    s5, 0(t6)
    sub   s6, s5, s4                # ticks

    # cycles/iter × 100 = ticks × 100 / N_PROBE
    li    t0, 100
    mul   a0, s6, t0
    li    a1, N_PROBE
    divu  a0, a0, a1                # a0 = tpi × 100

    # 打印 ticks
    lui   a0, %hi(m_pre)
    addi  a0, a0, %lo(m_pre)
    jal   ra, puts
    mv    a0, s6
    jal   ra, puts_hex
    lui   a0, %hi(m_mid)
    addi  a0, a0, %lo(m_mid)
    jal   ra, puts
    li    t0, 100
    mul   a0, s6, t0
    li    a1, N_PROBE
    divu  a0, a0, a1
    jal   ra, puts_hex
    lui   a0, %hi(m_end)
    addi  a0, a0, %lo(m_end)
    jal   ra, puts

hang:
    j     hang

#------------------------------------------------------------------------------
# delay_loop：与 m5_board.S 逐字相同（7×nop + addi + bnez）
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
# puts / puts_hex
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

#==============================================================================
    .section .rodata
    .align   2
m_pre:
    .asciz "CT-DELAY-PROBE ticks=0x"
m_mid:
    .asciz " cycles_per_iter_x100=0x"
m_end:
    .asciz "\r\n"

    .end
