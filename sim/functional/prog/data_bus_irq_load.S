/*==============================================================================
 * sim/functional/prog/data_bus_irq_load.S —— 数据总线 IRQ/PLIC 包定向程序（IRQ_LOAD）
 * 真实外部 intrpt[1]→PLIC 源 1；结果经 DDR 邮箱 + cbo.flush 写回。
 * 由 sim/functional/test_data_bus_irq.sh 用 /opt/riscv 工具链汇编；
 * A_load/wait_loop 符号由 nm 取出后以 -P 注入 TB（不在脚本里硬编码地址）。
 *============================================================================*/
    .section .text.init,"ax",@progbits
    .globl _start
    .option norvc
    .equ UART,    0x1FE001E0
    .equ PLIC,    0x1F100000
    .equ MAGIC,   0x54433031
    .equ DONE,    0xDEADBEEF
    .equ AVAL,    0xA5A5000A
    .equ BVAL,    0xB6B6000B
_start:
    li   s0, UART
    li   t0, 0x00000070
    csrw 0x30A, t0
    la   t0, trap_handler
    csrw 0x305, t0
    nop
    .rept 8
    li   t0, 0x1234
    csrw 0xB02, t0
    addi t0, t0, 1
    .endr
    /* PLIC：source 1（intrpt[1]）priority=1、ctx0 enable bit1、threshold=0 */
    li   s2, PLIC
    li   t0, 1
    sw   t0, 4(s2)                  /* priority[1] @ 0x1F100004 */
    li   t4, 0x1F102000
    li   t0, 2
    sw   t0, 0(t4)                  /* enable ctx0 = 1<<1 */
    li   t4, 0x1F300000
    sw   zero, 0(t4)                /* threshold ctx0 = 0 */
    li   t4, 0x1F102000
    lw   t3, 0(t4)                  /* 回读 enable：等前面 MMIO 写排空落地 */
    /* mie.MEIE=1, mstatus.MIE=1 */
    li   t0, 0x800
    csrw 0x304, t0
    csrsi 0x300, 8
    /* A：普通 DRAM cache-miss load（TB 在真实 AR 后从外部拉 intrpt[1]） */
    li   s3, 0x80003000
A_load:
    lw   a1, 0(s3)
    /* handler 把 mepc 改成 resume_B（跳过 A） */
resume_B:
    li   s4, 0x80004000
    lw   a2, 0(s4)                  /* B：不同 PA，已知值 BVAL */
    /* 检查：B 值正确且不等于 A；claim 恰返回 1；IRQ 的 mepc == A_load */
    li   a0, 0
    li   t0, BVAL
    bne  a2, t0, 1f
    li   t0, AVAL
    beq  a2, t0, 1f
    li   a0, 1
1:  li   s1, 0x80002000
    li   t1, MAGIC
    sw   t1, 0(s1)
    addi s1, s1, 4
    li   t1, 13
    sw   t1, 0(s1)
    addi s1, s1, 4
    sw   a0, 0(s1)                  /* C1: B 数据正确 */
    addi s1, s1, 4
    sw   a3, 0(s1)                  /* C2: PLIC claim == 1 */
    addi s1, s1, 4
    sw   a5, 0(s1)                  /* C3: mepc == A_load */
    addi s1, s1, 4
    .rept 10
    li   t1, 1
    sw   t1, 0(s1)
    addi s1, s1, 4
    .endr
    li   t1, DONE
    sw   t1, 0(s1)
    addi s1, s1, 4
    /* 等排空 + 写回 */
    li   t5, 256
2:  addi t5, t5, -1
    bne  t5, zero, 2b
    li   t6, 0x80002000
    cbo.flush (t6)
    addi t6, t6, 32
    cbo.flush (t6)
    addi t6, t6, 32
    cbo.flush (t6)
    li   t5, 64
3:  addi t5, t5, -1
    bne  t5, zero, 3b
    li   t6, 0x80002000
    cbo.flush (t6)
    addi t6, t6, 32
    cbo.flush (t6)
    addi t6, t6, 32
    cbo.flush (t6)
4:  j 4b

    .align 4
trap_handler:
    li   t4, 0x1F300004
    lw   t0, 0(t4)                  /* claim（读清 pending） */
    csrr a4, mepc
    la   t3, A_load
    li   a3, 0
    li   a5, 0
    li   t2, 1
    bne  t0, t2, 5f
    li   a3, 1                      /* claim 返回 source 1 */
5:  bne  a4, t3, 6f
    li   a5, 1                      /* IRQ mepc == A_load */
6:  sw   t0, 0(t4)                  /* complete（同 ID） */
    la   t1, resume_B
    csrw 0x341, t1                  /* mepc = resume_B，跳过 A */
    mret
