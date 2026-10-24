/*==============================================================================
 * sim/functional/prog/data_bus_irq_only.S —— 数据总线 IRQ/PLIC 包定向程序（IRQ_ONLY）
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
    li   s2, PLIC
    li   t0, 1
    sw   t0, 4(s2)
    li   t4, 0x1F102000
    li   t0, 2
    sw   t0, 0(t4)
    li   t4, 0x1F300000
    sw   zero, 0(t4)
    li   t4, 0x1F102000
    lw   t3, 0(t4)
    li   t0, 0x800
    csrw 0x304, t0
    csrsi 0x300, 8
    li   a3, 0
    li   t5, 200
wait_loop:
    addi t5, t5, -1
    bne  t5, zero, wait_loop
    li   s1, 0x80002000
    li   t1, MAGIC
    sw   t1, 0(s1)
    addi s1, s1, 4
    li   t1, 13
    sw   t1, 0(s1)
    addi s1, s1, 4
    sw   a3, 0(s1)                  /* C1: IRQ handler 已运行且 claim==1 */
    addi s1, s1, 4
    .rept 12
    li   t1, 1
    sw   t1, 0(s1)
    addi s1, s1, 4
    .endr
    li   t1, DONE
    sw   t1, 0(s1)
    addi s1, s1, 4
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
    lw   t0, 0(t4)                  /* claim */
    li   t2, 1
    bne  t0, t2, 7f
    li   a3, 1
7:  sw   t0, 0(t4)                  /* complete */
    mret                            /* mepc 不变：回到被打断的循环指令，幂等重执行 */
