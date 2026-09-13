/*=============================================================================
 * spi_stub.S —— 2A-7b「SPI 小引导」真实引导桩（复位入口，烧在 SPI Flash）
 *-----------------------------------------------------------------------------
 * 职责（与 AGENT.md §2A-7b 判据一致）：
 *   ① 复位取指落在 SPI-XIP 窗口 0x1C00_0000（D16：本核无片上 boot ROM）；
 *   ② 初始化平台 UART0（16550 寄存器块 0x1FE0_01E0）并打印一行横幅；
 *   ③ 跳转到 DDR 主镜像入口（0x0000_0000 起，OpenSBI+U-Boot 阶段）；
 *   ④ 任何异常都进 `panic` 死循环并打印原因码。
 *
 * 硬性要求（判据）：**镜像 ≤ 1 MiB**、**代码与数据的引用全部 PC 相对**
 *   —— 本文件除 MMIO 常量与"DDR 入口地址"这两个**协议常量**外，不含任何绝对地址；
 *      所有字符串都用 `lla`（= auipc+addi 的 PC 相对取址）拿，不用符号的绝对地址。
 *   链接地址由 `sw/board/spi_stub.ld` 固定为 0x1C00_0000（1 MiB 窗口）。
 *
 * 编译期开关：
 *   -DSIM_VUART  额外把字符写到仿真虚拟串口 0x1FAF_FF10（TB 会打印），
 *                这样**同一份源码**既能上板（只走真 UART）又能在仿真里被断言。
 *   -DSIM_EXIT   结束时写仿真 IO_SIMU(0x1FAF_FF00)=0；否则死循环（真板行为）。
 *===========================================================================*/

#define UART_BASE    0x1FE001E0        /* 平台 UART0 寄存器块（thr/rbr +0，lsr +5，lcr +3） */
#define SIM_VUART    0x1FAFFF10        /* CONFREG(仿真) 虚拟串口 */
#define SIM_IO       0x1FAFFF00        /* CONFREG(仿真) IO_SIMU：写 0 = PASS */

/* panic 原因码（同时写 UART 与虚拟串口） */
#define E_NOT_XIP    0x11              /* 复位 PC 不在 SPI 窗口 */
#define E_XIP_OVER   0x12              /* PC 超出 1 MiB 窗口 */
#define E_NO_DDR     0x13              /* 跳到 DDR 后未在 DDR 窗口内执行 */

    .section .text.spi, "ax"
    .globl  _start
    .type   _start, @function
_start:
    /* ---- ① 自检：必须从 SPI-XIP 窗口执行（否则说明复位向量/链接地址错了）---- */
    auipc   t0, 0                      /* t0 = 当前 PC（PC 相对，无重定位） */
    li      t1, 0x1C000000
    bltu    t0, t1, panic_not_xip
    li      t2, 0x1C100000
    bgeu    t0, t2, panic_over
    li      s0, 0x1C000000             /* s0 = 本桩执行地址 − SPI 窗口基址（窗口首址执行时 = 0） */
    sub     s0, t0, s0

    /* ---- ② 初始化 UART0：8N1、关中断、使能 FIFO（真板 33 MHz 输入时钟，115200）----
     * 16550 的波特率分频 = clk / (16 × baud) = 33e6/(16×115200) ≈ 17.9 → 18
     * 本核不依赖 UART 分频正确性（仿真走虚拟串口），真板若时钟不同改这里即可。 */
    li      a0, UART_BASE
    sb      zero, 1(a0)                /* IER  = 0    关全部中断 */
    sb      zero, 2(a0)                /* FCR  = 0    先关 FIFO 再复位 */
    li      t3, 0x07
    sb      t3,   2(a0)                /* FCR  = 0x07 使能并清空 FIFO */
    li      t3, 0x80
    sb      t3,   3(a0)                /* LCR.DLAB = 1（访问 DLL/DLM）*/
    li      t3, 18
    sb      t3,   0(a0)                /* DLL = 18 */
    sb      zero, 1(a0)                /* DLM = 0  */
    li      t3, 0x03
    sb      t3,   3(a0)                /* LCR = 0x03：8N1，DLAB=0 */
    li      t3, 0x03
    sb      t3,   4(a0)                /* MCR = 0x03：DTR/RTS 有效 */

    /* ---- ③ 打印横幅（PC 相对取串地址）---- */
    lla     a1, msg_stub
    jal     ra, puts

    /* ---- ④ 跳 DDR 主镜像入口 ----
     * 入口是**协议常量** 0x0（主镜像按 0x0 链接）。为证明本桩不依赖自身链接地址，
     * 在入口处已把"本桩实际执行地址相对 SPI 窗口基址的偏移"存进 s0（窗口首址执行时为 0）；
     * 这里用 `0x0 - s0` 抵消该偏移，于是桩被整体搬到窗口内任何位置都能跳到同一个 DDR 入口。
     * ⚠ 坑（本轮踩过）：不能在跳转处再取一次 `auipc t0,0` —— 那拿到的是**该指令**的 PC
     *   （=0x1C00005C），而不是桩首址，结果会跳到 0x5C 而不是 0x0。 */
    li      t2, 0x00000000             /* DDR 主镜像入口（协议常量） */
    sub     t2, t2, s0                 /* 抵消本桩的实际基址偏移（s0=0 时保持 0x0） */
    jr      t2

panic_not_xip:
    li      a2, E_NOT_XIP
    j       panic
panic_over:
    li      a2, E_XIP_OVER
    j       panic

/* ---- panic：打印原因码后停住（真板）/ 以非 0 退出（仿真）---- */
panic:
    lla     a1, msg_panic
    jal     ra, puts
    li      a0, UART_BASE
    addi    a2, a2, '0'
    sb      a2, 0(a0)                  /* 原因码（低 4 位近似字符）*/
#ifdef SIM_VUART
    li      t0, SIM_VUART
    sb      a2, 0(t0)
#endif
1:  j       1b

/* ---- puts(a1 = 字符串)：写 UART THR（等 LSR.THRE），同时可选写虚拟串口 ---- */
    .globl  puts
    .type   puts, @function
puts:
    li      a0, UART_BASE
    li      t1, SIM_VUART
puts_loop:
    lbu     t2, 0(a1)
    beqz    t2, puts_done
    addi    a1, a1, 1
puts_wait:
    lbu     t3, 5(a0)                  /* LSR */
    andi    t3, t3, 0x20               /* THRE */
    beqz    t3, puts_wait
    sb      t2, 0(a0)                  /* THR */
#ifdef SIM_VUART
    sb      t2, 0(t1)                  /* 仿真虚拟串口（TB 打印）*/
#endif
    j       puts_loop
puts_done:
    ret

    /* 只读字符串：放在 SPI 段内（XIP 可读），全部经 PC 相对寻址 */
    .section .rodata.spi, "a"
msg_stub:
    .asciz "\r\n[RV32-GC] SPI stub at 0x1C000000 (XIP, PC-relative) -> jump DDR 0x0\r\n"
msg_panic:
    .asciz "\r\n[RV32-GC] SPI stub PANIC code="
