/*=============================================================================
 * spi_boot.S —— SPI Flash XIP 启动链路自检（阶段 2A-7a）
 *-----------------------------------------------------------------------------
 * 为什么需要它：chiplab 平台的**复位取指地址是 0x1C00_0000**，不是 RISC-V
 * 习惯的 0x8000_0000。依据（平台硬事实，已核对源码）：
 *   chiplab `IP/AMBA/axi_mux_syn.v`:
 *     araddr[31:20]==12'h1c0                      → 判为 SPI Flash（XIP 窗口）
 *     wr_addr_hit[0] = ~|wr_addr_hit[4:1]         → DDR3 是 AXI 默认从设备（@0x0）
 *   即 0x1C00_0000 起 1 MiB 是可执行（XIP）的 SPI Flash 窗口，PMON/u-boot 就烧在
 *   那颗可插拔 SPI flash 上；DDR3 从 0x0000_0000 起。
 *   两个窗口相距约 448 MiB ⇒ 远超出 `auipc` 的 ±2 MiB 覆盖范围，跨窗口跳转必须
 *   用完整 32 位地址运算（auipc 取高位 + addi 补低位）再 jalr。
 *
 * 本测试按验收语义逐条自证：
 *   1) 复位（-DRESET_PC=32'h1C000000）后第一条指令就在 SPI XIP 窗口内执行
 *      —— 用 `auipc x, 0` 取当前 PC，断言 0x1C00_0000 ≤ PC < 0x1C10_0000；
 *   2) SPI 窗口内算术自检 + **XIP 数据读**自检（lw 读回烧在 SPI 里的魔数）；
 *   3) `auipc + addi + jalr` 跨约 448 MiB 跳到 DDR 0x0 的 ddr_stage；
 *   4) DDR 窗口内算术自检 + 写读回（含 store→load 同址回读、字节/半字窄写）；
 *   5) 任一步失败 → 写非零退出码；全部通过 → 写退出码 0（= PASS）。
 *
 * 「确实运行在 SPI 窗口」怎么被判定（两重、互相独立）：
 *   a) 程序内：`auipc x,0` 得到的 PC 必须落在 SPI 窗口内（本文件 CHECK-1）；
 *   b) TB 侧（sim/tb/tb_spi_boot.v）：观测 AXI 的**首笔取指请求地址**必须落在 SPI
 *      窗口，且提交级 PC 必须先后出现在 SPI 窗口与 DDR 窗口。
 *   两者任一不成立都不算通过。
 *
 * 约束标注（阶段 2A 的 I-Cache 未落地）：
 *   取指地址命中 SPI-XIP 窗口时必须**绕过 I-Cache**（XIP 窗口不可缓存；后续带 Cache
 *   的取指单元要用 `IS_SPI_XIP()` 判定走旁路，见 rtl/pkg/rv32gc_defs.vh 的
 *   `SPI_XIP_BASE/MASK`）。本核当前**无 Cache**（rtl/frontend/rv32_ifetch.v 是单行
 *   缓冲 + AXI 整行读），故本测试不需要额外的 cache 失效动作；此约束仅在此标注，
 *   RTL 判定点 `xip_bypass` 由主 Agent 维护，本测试不改 rtl 下任何文件。
 *
 * 已知不在本测试覆盖范围内的东西（不要把它当作已验过）：
 *   * 真实 SPI 控制器的**读写命令序列**（0x03 读 / 0x02 页编程 / WREN / 等待 WIP…）
 *     不在本仿真模型里。sim/tb/sim_axi_slave.v 的 mem_spi[] 是对 XIP 窗口的
 *     行为级模型：命中窗口即按字节返回，**写忽略**。因此本测试不对 SPI 写做任何断言。
 *   * Flash 上电延迟 / 时钟分频 / 命令握手的时序细节同样不在模型内。
 *
 * 构建/运行：bash scripts/run_spi_boot_test.sh（本文件不是 C，不走 sim/tests/build.sh）
 *=============================================================================*/

    .option norelax                 /* 保留 auipc/addi/jalr 原样，便于 objdump 核对 */

#define EXIT_ADDR   0x1FAFFF00      /* CONFREG(仿真) IO_SIMU：写 0 = PASS，非 0 = FAIL */
#define VUART_ADDR  0x1FAFFF10      /* CONFREG(仿真) 虚拟串口：写低 8 位 → TB 打印字符 */

/* ---- 失败退出码（非零，便于定位到底哪一步崩了） ---- */
#define E_NO_XIP    0x11            /* 复位后 PC 不在 SPI XIP 窗口（没从 SPI 启动） */
#define E_SPI_ALU   0x12            /* SPI 阶段算术自检失败 */
#define E_SPI_LOAD  0x13            /* SPI 窗口数据读（XIP lw）失败 */
#define E_DDR_MAGIC 0x21            /* 跨窗口后寄存器 a0 的存活标记丢了 */
#define E_DDR_RA    0x22            /* 跨窗口后 ra 不在 SPI 窗口内（跳转落点不对） */
#define E_DDR_ALU   0x23            /* DDR 阶段算术自检失败 */
#define E_DDR_MEM   0x24            /* DDR 写读回失败 */

/*=============================================================================
 * 第一段：SPI XIP 窗口（链接地址 0x1C00_0000）。复位后从这里开始执行。
 *===========================================================================*/
    .section .text.spi, "ax"
    .globl spi_entry
    .type  spi_entry, @function
spi_entry:
    /* ---- CHECK-1：当前 PC 必须落在 SPI XIP 窗口 [0x1C000000, 0x1C100000) ---- */
    auipc   t0, 0                   /* t0 = 本条 auipc 的 PC = spi_entry */
    li      t3, 0x1C000000
    bltu    t0, t3, fail_no_xip     /* PC < 0x1C00_0000 → 不是从 SPI 启动 */
    li      t3, 0x1C100000
    bgeu    t0, t3, fail_no_xip     /* PC ≥ 0x1C10_0000 → 出了 1 MiB 窗口 */

    /* ---- SPI 阶段存活/观测量：打印 'S' 到虚拟串口（日志里可见执行顺序） ---- */
    li      t2, VUART_ADDR
    li      t3, 'S'
    sw      t3, 0(t2)

    /* ---- CHECK-2：SPI 窗口内算术自检（RV32I 基础 ALU） ---- */
    li      t1, 3
    li      t2, 5
    add     t4, t1, t2  /* 8  */
    li      t5, 8
    bne     t4, t5, fail_spi_alu
    sub     t4, t1, t2  /* -2 */
    li      t5, -2
    bne     t4, t5, fail_spi_alu
    xor     t4, t1, t2  /* 6  */
    li      t5, 6
    bne     t4, t5, fail_spi_alu
    slli    t4, t1, 4   /* 48 */
    li      t5, 48
    bne     t4, t5, fail_spi_alu
    srli    t4, t4, 2   /* 12 */
    li      t5, 12
    bne     t4, t5, fail_spi_alu
    bne     t1, t1, fail_spi_alu    /* 恒不成立：确认不误跳 */

    /* ---- CHECK-3：XIP 窗口的**数据读**（不是取指）：lw 读回烧在 SPI 里的魔数 ---- */
    la      t1, spi_magic
    lw      t4, 0(t1)
    li      t5, 0xC0DEF00D
    bne     t4, t5, fail_spi_load

    /* ---- CHECK-4：跨窗口跳转前留下存活标记 ---- */
    li      a0, 0x5A5A5A5A
1:  /* 完整 32 位地址运算：auipc 取 PC 相对高位 + addi 补低位，再 jalr：
     * auipc 单独只覆盖 ±2 MiB，必须靠 addi 的低 12 位把地址组合到
     * 0x0000_0000（与当前 PC 相距约 -448 MiB）。relax 已关闭，编码原样保留。 */
    auipc   t0, %pcrel_hi(ddr_stage)
    addi    t0, t0, %pcrel_lo(1b)
    jalr    ra, 0(t0)

    /* jalr 若没能生效（顺序落到这里）就是跑飞了 */
    li      t3, E_DDR_RA
    j       fail_spi_common

/* ---- SPI 阶段失败处理（t3 = 失败码） ---- */
fail_no_xip:
    li      t3, E_NO_XIP
    j       fail_spi_common
fail_spi_alu:
    li      t3, E_SPI_ALU
    j       fail_spi_common
fail_spi_load:
    li      t3, E_SPI_LOAD
    j       fail_spi_common
fail_spi_common:
    li      t2, EXIT_ADDR
    sw      t3, 0(t2)               /* 非零退出码 → TB 判 FAIL 并打印 code */
4:  j       4b

    .align 2
spi_magic:
    .word   0xC0DEF00D              /* CHECK-3 的 XIP 数据读魔数 */

/*=============================================================================
 * 第二段：DDR 窗口（链接地址 0x0000_0000）。模拟"SPI 里的 boot stub 把 DDR 里的
 * 镜像接管过去"。跨窗口跳转用 auipc+addi+jalr 落到这里的 ddr_stage。
 *===========================================================================*/
    .section .text.ddr, "ax"
    .globl ddr_stage
    .type  ddr_stage, @function
ddr_stage:
    /* ---- CHECK-5：跨窗口后 a0 存活标记还在 ---- */
    li      t1, 0x5A5A5A5A
    bne     a0, t1, fail_ddr_magic

    /* ---- CHECK-6：ra（jalr 的返回地址）必须指向 SPI 窗口里的下一条指令，
     *      这是"确实从 SPI 跨到了 DDR"的第二个证据 ---- */
    li      t1, 0x1C000000
    bltu    ra, t1, fail_ddr_ra
    li      t1, 0x1C100000
    bgeu    ra, t1, fail_ddr_ra

    /* ---- DDR 阶段观测量：打印 'D' ---- */
    li      t2, VUART_ADDR
    li      t3, 'D'
    sw      t3, 0(t2)

    /* ---- CHECK-7：DDR 窗口内算术自检 ---- */
    li      t1, 0x1234
    slli    t4, t1, 4           /* 0x12340 */
    li      t5, 0x12340
    bne     t4, t5, fail_ddr_alu
    li      t1, 0x000000FF
    li      t2, 0x00000010
    or      t4, t1, t2          /* 0xFF */
    li      t5, 0x000000FF
    bne     t4, t5, fail_ddr_alu
    li      t1, -1
    srli    t4, t1, 31          /* 1 */
    li      t5, 1
    bne     t4, t5, fail_ddr_alu
    srai    t4, t1, 31          /* -1 */
    li      t5, -1
    bne     t4, t5, fail_ddr_alu
    lui     t4, 0x00001         /* 0x1000 */
    li      t5, 0x1000
    bne     t4, t5, fail_ddr_alu

    /* ---- CHECK-8：DDR 写读回（store → load 同址回读） ---- */
    li      t2, 0x00001000
    li      t3, 0xDEADBEEF
    sw      t3, 0(t2)
    lw      t4, 0(t2)
    bne     t4, t3, fail_ddr_mem

    /* 同址**连续**换值回读：若读通路返回的是"上一版"数据，这里必然失败 */
    li      t3, 0x0BADF00D
    sw      t3, 0(t2)
    lw      t4, 0(t2)
    bne     t4, t3, fail_ddr_mem

    /* 窄写（sb）+ 字读回：验证 wstrb 的字节 lane */
    li      t3, 0xFFFFFFFF
    sw      t3, 4(t2)
    sb      zero, 4(t2)
    lw      t4, 4(t2)
    li      t5, 0xFFFFFF00
    bne     t4, t5, fail_ddr_mem

    /* 窄写（sh）+ 字读回 */
    sw      zero, 8(t2)
    li      t3, 0x0000ABCD
    sh      t3, 8(t2)
    lw      t4, 8(t2)
    li      t5, 0x0000ABCD
    bne     t4, t5, fail_ddr_mem

    /* 半字读（lh）+ 无符号字节读（lbu） */
    lh      t4, 8(t2)
    li      t5, 0xFFFFABCD          /* 0xABCD 符号扩展 */
    bne     t4, t5, fail_ddr_mem
    lbu     t4, 8(t2)
    li      t5, 0x000000CD
    bne     t4, t5, fail_ddr_mem

    /* ---- 全部通过：打印 '!'，写退出码 0 = PASS ---- */
    li      t2, VUART_ADDR
    li      t3, '!'
    sw      t3, 0(t2)

    li      t2, EXIT_ADDR
    sw      zero, 0(t2)             /* 退出码 0 → TB 判 PASS（见 tb_spi_boot.v） */
ddr_pass_loop:
    j       ddr_pass_loop

/* ---- DDR 阶段失败处理 ---- */
fail_ddr_magic:
    li      t3, E_DDR_MAGIC
    j       fail_ddr_common
fail_ddr_ra:
    li      t3, E_DDR_RA
    j       fail_ddr_common
fail_ddr_alu:
    li      t3, E_DDR_ALU
    j       fail_ddr_common
fail_ddr_mem:
    li      t3, E_DDR_MEM
    j       fail_ddr_common
fail_ddr_common:
    li      t2, EXIT_ADDR
    sw      t3, 0(t2)               /* 非零退出码 → TB 判 FAIL 并打印 code */
5:  j       5b

    .end
