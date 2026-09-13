/*=============================================================================
 * ddr_main.S —— 2A-7b「DDR 主镜像」阶段的**入口桩**（占位 OpenSBI/U-Boot 阶段）
 *-----------------------------------------------------------------------------
 * 真机上这一段是 NAND 的 `kernel` 分区内容（OpenSBI + U-Boot，或其打包体），
 * 由 SPI 小引导/前级加载器放到 DDR 并跳转到 **0x0000_0000**。
 * 本文件提供的就是那个"按 0x0 链接、被跳转进入"的入口：它
 *   ① 在 DDR 窗口内完成一次自检（PC 必须在 0x0–0x0800_0000）；
 *   ② 打印横幅（经平台 UART0；仿真下同时走虚拟串口）；
 *   ③ 真机行为：把控制权交给紧随其后的 OpenSBI（入口符号 `__opensbi_entry`，
 *      由最终镜像链接时提供；本占位版停在打印循环）；
 *      仿真行为（-DSIM_EXIT）：写 IO_SIMU=0 结束，供 `scripts/run_boot_chain_test.sh` 判 PASS。
 *
 * 与 SPI 桩一样：代码/数据引用全 PC 相对，唯一的绝对量是 MMIO 常量与
 * "OpenSBI 入口地址"这类**协议常量**。
 *===========================================================================*/

#define UART_BASE    0x1FE001E0
#define SIM_VUART    0x1FAFFF10
#define SIM_IO       0x1FAFFF00

#define DDR_BASE     0x00000000
#define DDR_SIZE     0x08000000        /* 128 MiB（与 DTS /memory 一致） */

    .section .text.ddr, "ax"
    .globl  _start
    .type   _start, @function
_start:
    /* ---- ① 必须落在 DDR 窗口内（0 ≤ PC < 128 MiB）---- */
    auipc   t0, 0
    li      t1, DDR_BASE
    bltu    t0, t1, panic
    li      t2, DDR_BASE + DDR_SIZE
    bgeu    t0, t2, panic

    /* 栈：DDR 顶端向下 64 KiB（真机由 OpenSBI 重新布局，这里只是可用的临时栈）*/
    li      sp, DDR_BASE + DDR_SIZE - 0x10000

    /* ---- ② UART0 已由 SPI 桩初始化；这里只打印横幅 ---- */
    lla     a1, msg_main
    jal     ra, puts

    /* ---- ③ 交给 OpenSBI（真机）：入口由链接脚本提供；缺省则停在这里 ---- */
    lla     t0, __opensbi_entry
    beqz    t0, sim_done               /* 没提供入口 ⇒ 只有当本镜像独占时才可能为 0 */
    mv      a0, zero                   /* hartid = 0 */
    /* a1 应为 DTB 地址：真机由前级加载器放入 a1；仿真/占位时用 0 */
    jr      t0

sim_done:
#ifdef SIM_EXIT
    li      t0, SIM_IO
    sw      zero, 0(t0)                /* 写 0 = PASS（tb_spi_boot / tb_smoke 约定）*/
#endif
1:  j       1b

panic:
    lla     a1, msg_panic
    jal     ra, puts
1:  j       1b

/* ---- puts(a1 = 字符串) ---- */
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
    lbu     t3, 5(a0)
    andi    t3, t3, 0x20
    beqz    t3, puts_wait
    sb      t2, 0(a0)
#ifdef SIM_VUART
    sb      t2, 0(t1)
#endif
    j       puts_loop
puts_done:
    ret

    /* 可写数据（栈/计数器）走 DDR；本占位版无 .data/.bss 需求 */
    .section .rodata.ddr, "a"
msg_main:
    .asciz "\r\n[RV32-GC] DDR main image @0x0 running (OpenSBI/U-Boot stage)\r\n"
msg_panic:
    .asciz "\r\n[RV32-GC] DDR main image PANIC: PC not in DDR window\r\n"
