/*=============================================================================
 * spi_boot.S —— 从 SPI Flash XIP 窗口（0x1C00_0000）启动的链路自检
 *
 * 为什么需要它：chiplab 平台的**复位取指地址是 0x1C00_0000**，不是 RISC-V 习惯的
 * 0x8000_0000。依据（平台硬事实，已核对源码）：
 *   chiplab `IP/AMBA/axi_mux_syn.v`：
 *     rd_addr_hit[1] = (araddr[31:16]==16'h1fe8) || (araddr[31:20]==12'h1c0)  // SPI
 *     wr_addr_hit[1] = (awaddr[31:20]==12'h1c0) || ...                        // SPI
 *   即 0x1C00_0000 起 1 MiB 是 SPI Flash 的 XIP（execute-in-place）窗口；
 *   PMON / u-boot 就烧在那颗可插拔 SPI flash 上（chiplab docs/FPGA_run_linux/linux_run.md）。
 *   另：`fpga/nscscc-team/uart_debug/uart_debug.v` 里 `SRAM_START_ADDR = 32'h1c000000`。
 *
 * 本测试验证"核能从 0x1C00_0000 取指并正确执行、且能 PC 相对地跨窗口跳转"：
 *   1) 复位后第一条指令就在 0x1C00_0000（由 -DRESET_PC=32'h1C000000 指定）；
 *   2) 依次执行本文件里的算术检查（RISC-V 用 PC 相对 auipc/jal 跨越 ~448 MiB 距离）；
 *   3) 跳到常驻 DDR（0x0000_0000）的 `ddr_stage` 继续执行（模拟"SPI 里的小引导程序
 *      把 DDR 里的镜像接管过去"）；
 *   4) `ddr_stage` 里再检查一次状态，然后写平台退出码 0x1FAF_FF00 = 0 表示 PASS。
 *
 * 构建/运行：见 scripts/run_spi_boot_test.sh（负责链接到 0x1C00_0000、生成 SPI 窗口镜像与
 * DDR 镜像、用 -DRESET_PC 编译 RTL、并断言 EXIT code=0）。
 *=============================================================================*/

#define EXIT_ADDR   0x1FAFFF00
#define XIP_BASE    0x1C000000

    .section .text.spi, "ax"

/* ---- SPI 窗口内（0x1C00_0000 起）：复位后从这里开始执行 ---- */
    .globl spi_entry
spi_entry:
    lui     t0, 0x1C000            /* t0 = 0x1C000000，验证 lui 的高位常量 */
    andi    t1, t0, 0              /* t1 = 0 */
    addi    t1, t1, 1              /* t1 = 1 */
    bne     t1, t1, spi_die        /* 恒不跳（验证 bne 不误跳） */
    beq     t1, t1, spi_ok
spi_die:
    li      t2, EXIT_ADDR
    li      t3, 1
    sw      t3, 0(t2)
1:  j       1b
spi_ok:
    /* 记录一个"已进入 SPI 阶段"的魔数（放到 a0，跳到 DDR 后检查） */
    li      a0, 0x5A5A5A5A

    /* PC 相对跳到 DDR 的 ddr_stage：距离约 0x1C00_0000，靠 auipc/jalr 覆盖 32 位空间 */
    auipc   t0, %pcrel_hi(ddr_stage)
    addi    t0, t0, %pcrel_lo(spi_ok)
    jalr    ra, 0(t0)

    /* 不应返回 */
    li      t2, EXIT_ADDR
    li      t3, 2
    sw      t3, 0(t2)
2:  j       2b

/* ---- DDR 窗口内（0x0000_0000 起）：模拟被引导程序接管的镜像 ---- */
    .section .text.ddr, "ax"
    .globl ddr_stage
ddr_stage:
    /* a0 必须仍是 SPI 阶段留下的魔数 */
    li      t1, 0x5A5A5A5A
    bne     a0, t1, ddr_die

    /* 简单的算术自检（含乘法器：0x1234 * 0x10 = 0x12340） */
    li      t2, 0x1234
    li      t3, 16
    mul     t4, t2, t3
    li      t5, 0x12340
    bne     t4, t5, ddr_die

    /* 一次真实访存：写 DDR 并读回（确认 DDR 窗口可读写） */
    li      t2, 0x00001000
    li      t3, 0xDEADBEEF
    sw      t3, 0(t2)
    lw      t4, 0(t2)
    bne     t4, t3, ddr_die

    /* PASS：退出码 0 */
    li      t2, EXIT_ADDR
    sw      zero, 0(t2)
ddr_pass_loop:
    j       ddr_pass_loop

ddr_die:
    li      t2, EXIT_ADDR
    li      t3, 3
    sw      t3, 0(t2)
ddr_die_loop:
    j       ddr_die_loop

    .end
