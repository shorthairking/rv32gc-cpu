//==============================================================================
// core_params.vh —— RV32-GC 项目「结构/平台参数」唯一真源（Unique Source of Truth）
//==============================================================================
// 项目    : rv32gc-cpu（阶段二 2A：单发射顺序 5 级基线核，见
//           docs/design/08-baseline-5stage.md；本文件所有取值与该文一致）
// 作用域  : 复位/取指地址、平台地址映射、流水级参数、Cache 参数、PMP 项数、
//           核内设备参数、IP 双分支开关、启动预期常量。
// 风格    : Verilog-2001 兼容；只允许 localparam / `define / `ifdef；
//           **本文件不得出现 always 块、模块或端口声明**（AGENT.md §4.3 红线）。
// 依赖    : 本文件可被独立 include；`RV32GC_USE_VIVADO_IP` 在综合脚本中定义、
//           在 iverilog/Verilator 回归中**从不定义**（默认走仿真行为模型）。
// 引用强度: [DOC] 项目文档口径 / [KB] 已核实的知识库事实 / [MEASURED] 本会话实测
//==============================================================================
`ifndef CORE_PARAMS_VH
`define CORE_PARAMS_VH

//==============================================================================
// 1. 复位与取指
//    [DOC:docs/design/08-baseline-5stage.md §4.3；DOC:docs/kb/platform-facts.md §7]
//    平台无硬件 boot ROM（soc_top.v:664-1885 无 ROM 例化）⇒ 上板复位取指必须落在
//    SPI Flash XIP 窗口；chiplab 侧佐证：software/bsp/env/convert.c:88 的 "@1c000000"、
//    sims/verilator/testbench/include/common.h:9 的 FIRST_INST_ADDRESS 0x1c000000。
//    ★ 依赖声明：本文件**自包含**（可单独 include，无需先 include 其它头文件）；
//      其常量不得反向依赖 `rtl/pkg/rv32_defs.vh` 的宏。若某常量两者都需要，
//      **定义在本文件**（参数/地址口径类），由 rv32_defs.vh 侧只做注释指引。
//      （推荐 include 顺序仍为 rv32_defs.vh → core_params.vh，但非强制。）
//==============================================================================
`define RV32GC_RESET_PC        32'h1C00_0000   // 复位取指 PC = SPI XIP 主窗口
`define RV32GC_BOOT_PC         `RV32GC_RESET_PC

// ---- SPI XIP 窗口与别名（同一片 SPI 存储体的两个视图） ----
//    [DOC:docs/kb/platform-facts.md §2.3] godson_sbridge_spi.v:192-194 做别名归一，
//    soc_top.v:1227 传入 spi_addr=16'h1fe8。
`define RV32GC_XIP_BASE        32'h1C00_0000   // 主窗口
`define RV32GC_XIP_ALIAS       32'h1FE8_0000   // 别名窗口
`define RV32GC_XIP_SIZE        32'h0010_0000   // 1 MiB（窗口 PA[19:0]）
`define RV32GC_XIP_WIDTH_BITS  20              // 窗口内偏移位宽（1 MiB）
// ---- XIP 主窗口高 12 位位段判定（**唯一定义处**；2026-09-14 由 rv32_defs.vh §10 迁入） ----
//      比较形式与 §2 MMIO 掩码统一为 ((PA[31:20] & MSK) == VAL)。
`define RV32GC_XIP_HI20_MSK    12'hFFF        // PA[31:20] 全比较（XIP 主窗口宽 1 MiB）
`define RV32GC_XIP_HI20_VAL    12'h1C0        // (PA[31:20] == 0x1C0) ⇒ XIP 主窗口
`define RV32GC_XIP_HI20        `RV32GC_XIP_HI20_VAL   // 12'h1C0（本文件内定义，勿再向外查找）

//==============================================================================
// 2. 平台地址映射（核内不实现外设；外设条目只作软件/注释口径）
//    [DOC:docs/kb/platform-facts.md §2；DOC:docs/design/05-cache-memory.md §5.1]
//==============================================================================
// ---- DDR3：平台默认从设备（axi_mux_syn.v:860/951 的 addr_hit[0]） ----
`define RV32GC_DDR_BASE       32'h0000_0000
`define RV32GC_DDR_SIZE_MB    128
`define RV32GC_DDR_SIZE       (RV32GC_DDR_SIZE_MB * 1024 * 1024)  // 0x0800_0000
`define RV32GC_DDR_LIMIT      32'h0800_0000                        // 开区间上界
`define RV32GC_DDR_HI4_VAL    4'h0                                 // PA[31:28]==0 判可缓存

// ---- 核内私有设备（必须核内截获；平台 axi_mux 未占用这些地址） ----
//    不截获的后果：静默落到 DDR3 默认通路 ⇒ 无声数据损坏。
`define RV32GC_CLINT_BASE     32'h1F00_0000
`define RV32GC_PLIC_BASE      32'h1F10_0000
`define RV32GC_CLINT_SIZE     (64 * 1024)      // 0x1_0000（寄存器稀疏映射，见 §5）
`define RV32GC_PLIC_SIZE      (4 * 1024 * 1024) // 0x40_0000（标准 PLIC 映射）

// ---- 平台外设/配置窗口（核内**不实现**，仅登记以统一软件口径与译码） ----
`define RV32GC_CONFREG_SIM_BASE 32'h1FAF_0000   // 仿真 confreg_sim（含 VIRTUAL_UART/IO_SIMU）
`define RV32GC_CONFREG_SYN_BASE 32'h1FD0_0000   // 上板 confreg_syn（LED/SWITCH/TIMER/FREQ）
`define RV32GC_UART_BASE        32'h1FE0_01E0   // 16550 风格 UART
`define RV32GC_NAND_BASE        32'h1FE7_8000   // NAND 控制器
`define RV32GC_NAND_DOORBELL    32'h1FE7_8040   // DMA 门铃（nand.v:128-129 + ls1a_nand.c:18）
`define RV32GC_MAC_BASE         32'h1FF0_0000   // MAC（不使用）

// ---- MMIO 判定掩码（译码只写一处；与 rv32_defs.vh §10 的 *_HIT_VAL 配套） ----
`define RV32GC_MMIO_HI16_MSK   16'hFFFF_0000   // PA[31:16] 窗口比较（高 16 位）
`define RV32GC_MMIO_HI16_LSB   16
`define RV32GC_MMIO_HI20_MSK   32'hFFF0_0000   // PA[31:20] 窗口比较（XIP 主窗口）
`define RV32GC_MMIO_HI20_LSB   20

//==============================================================================
// 3. 时钟与时间基准
//    [DOC:docs/kb/platform-facts.md §5；DOC:docs/design/01-overview-datapath.md §7.1]
//    上板口径：cpu_clk = uncore_clk = 33 MHz（clk_pll_33.clk_out2），同域无 CDC；
//    仿真按相同频率给时钟，不改变同域性质。
//==============================================================================
`define RV32GC_CLK_HZ         33000000         // 33 MHz（= config.h:33 的 FREQ=32'd33000000）
`define RV32GC_CLK_FREQ_HZ    `RV32GC_CLK_HZ
`define RV32GC_CLK_PERIOD_NS  30               // 1/33 MHz ≈ 30.3 ns
`define RV32GC_TIMEBASE_HZ    33000000         // CLINT mtime 计数频率（mtime 由 aclk 计数）

//==============================================================================
// 4. 流水线与微架构参数（**2A 口径**：单发射、顺序、5 级 F/D/E/M/W）
//    [DOC:docs/design/08-baseline-5stage.md §1.1、§5.0]
//    ★ 注意：2B（4 发射乱序、11 级）是后置里程碑，本文件不得预置其参数。
//==============================================================================
`define RV32GC_XLEN            32               // XLEN
`define RV32GC_STAGES          5                // 流水级数（F/D/E/M/W）
`define RV32GC_ISSUE_WIDTH     1                // 2A 单发射（2B 才提升为 4）
`define RV32GC_COMMIT_WIDTH    1                // 2A 每拍最多提交 1 条
`define RV32GC_IALIGN          16               // 实现 C 扩展 ⇒ IALIGN=16（最小指令 2 B）
`define RV32GC_ILEN            32               // 最大指令长度 32 bit
`define RV32GC_PARCEL_BITS     16               // 一次取指处理的 parcel 宽度
`define RV32GC_GPRS            32               // 通用寄存器个数
`define RV32GC_FPRS            32               // 浮点寄存器个数（FLEN=64 视图）
`define RV32GC_FLEN            64               // D 扩展：浮点寄存器 64 bit（F 视图 32）
`define RV32GC_MXL             1                // misa.MXL 编码：1 ⇒ MXLEN=32
`define RV32GC_MEMSHR_DEPTH    1                // 2A MSHR：每侧 1 项在途（§5.5 抉择 10）

// ---- 2A 性能非门禁项，登记以便跨阶段口径一致 ----
`define RV32GC_FPRIV           1                // 2A 不流水化 FPU（多拍定长）

//==============================================================================
// 5. 核内 CLINT / PLIC 参数
//    [DOC:docs/design/08-baseline-5stage.md §6.6；DOC:docs/design/06-csr-privilege.md §8]
//==============================================================================
// ---- CLINT 寄存器偏移（基址 RV32GC_CLINT_BASE） ----
`define RV32GC_CLINT_MSIP_OFF      32'h0000_0000   // msip       32 bit R/W
`define RV32GC_CLINT_MTIMECMP_OFF  32'h0000_4000   // mtimecmpL  低字（低地址）
`define RV32GC_CLINT_MTIMECMPH_OFF 32'h0000_4004   // mtimecmpH  高字
`define RV32GC_CLINT_MTIME_OFF     32'h0000_BFF8   // mtimeL
`define RV32GC_CLINT_MTIMEH_OFF    32'h0000_BFFC   // mtimeH
`define RV32GC_CLINT_MTIME_W       64              // mtime 64 bit（RV32 拆两个字）
`define RV32GC_CLINT_LOW_FIRST     1               // 低字在低地址
// ---- PLIC 参数（2 个上下文：0=M⇒MEIP、1=S⇒SEIP；源 1..5） ----
`define RV32GC_PLIC_NUM_SOURCES    5               // 源 1-5（源 0 保留为「无中断」）
`define RV32GC_PLIC_SOURCE_MIN     1
`define RV32GC_PLIC_SOURCE_MAX     5
`define RV32GC_PLIC_NUM_CONTEXTS   2
`define RV32GC_PLIC_CTX_M          0               // context 0 ⇒ MEIP
`define RV32GC_PLIC_CTX_S          1               // context 1 ⇒ SEIP
// ---- PLIC 寄存器映射（偏移） ----
`define RV32GC_PLIC_PRIORITY_OFF   32'h0000_0000   // + 4*id
`define RV32GC_PLIC_PENDING_OFF    32'h0000_1000   // + 4*(id/32)
`define RV32GC_PLIC_ENABLE_OFF     32'h0000_2000   // + 4*ctx
`define RV32GC_PLIC_THRESHOLD_OFF  32'h0020_0000   // + 4*ctx
`define RV32GC_PLIC_CLAIM_OFF      32'h0020_0004   // + 4*ctx（claim/complete 同址语义）
// ---- intrpt[4:0] → PLIC 源号 默认接线（**实现 plic.v 时定稿**，RTL 与 DTS 只写一处） ----
//      [DOC:docs/design/08-baseline-5stage.md §6.6 表；平台侧 intr_out 组成见 soc_top.v:725]
`define RV32GC_INTRPT_SRC_MAC     5     // intrpt[0] = mac_int
`define RV32GC_INTRPT_SRC_UART    1     // intrpt[1] = uart0_int（控制台，最高频）
`define RV32GC_INTRPT_SRC_SPI     4     // intrpt[2] = spi_inta_o
`define RV32GC_INTRPT_SRC_NAND    2     // intrpt[3] = nand_int
`define RV32GC_INTRPT_SRC_DMA     3     // intrpt[4] = dma_int
`define RV32GC_INTRPT_WIDTH       8     // 核端口 8 位；**仅 [4:0] 有效**，[7:5] 恒 0

//==============================================================================
// 6. PMP 参数（16 项，粒度 G=0 ⇒ 4 B，NA4 可用）
//    [DOC:docs/design/08-baseline-5stage.md §5.5 抉择 5/6；DOC:docs/kb/isa-notes.md §3.1]
//==============================================================================
`define RV32GC_PMP_ENTRIES       16      // 2A 实现 16 项（低编号项必须先实现）
`define RV32GC_PMP_GRANULARITY   0       // G=0
`define RV32GC_PMP_CFG_CSRS      4       // RV32：pmpcfg0..3 覆盖 16 项
`define RV32GC_PMP_ADDR_CSRS     16      // pmpaddr0..15
`define RV32GC_PMP_NA4_ENABLE    1       // G=0 ⇒ NA4 可用
`define RV32GC_PMP_ENTRY_W       8       // 每项 8 bit（pmpcfg 字段）

//==============================================================================
// 7. Cache / CMO 参数（2A）：L1I 16 KB（2 路/32 B 行）、L1D 32 KB（4 路/32 B 行）
//    [DOC:docs/design/05-cache-memory.md §3.1；DOC:docs/design/08-baseline-5stage.md §1.1]
//    ★ 2A **不实现 L2**；L2 参数仅作后置里程碑（M6）口径登记，下面均标注 L2_ 前缀。
//    ★ 用户裁决：CMO block size —— clean/flush = 64 B（L2 行）、zero = 32 B（L1D 行）；
//      发现路径为设备树属性，不新增 CSR（08 §6.5）。
//==============================================================================
// ---- L1I ----
`define RV32GC_L1I_SIZE_KB       16
`define RV32GC_L1I_SIZE_BYTES    (RV32GC_L1I_SIZE_KB * 1024)   // 16384
`define RV32GC_L1I_WAYS          2
`define RV32GC_L1I_LINE_BYTES    32
`define RV32GC_L1I_SETS          (RV32GC_L1I_SIZE_BYTES / (RV32GC_L1I_WAYS * RV32GC_L1I_LINE_BYTES))
`define RV32GC_L1I_INDEX_BITS    8       // VA[12:5]（256 组）
`define RV32GC_L1I_OFFSET_BITS   5       // 行内偏移 VA[4:0]
// ---- L1D ----
`define RV32GC_L1D_SIZE_KB       32
`define RV32GC_L1D_SIZE_BYTES    (RV32GC_L1D_SIZE_KB * 1024)   // 32768
`define RV32GC_L1D_WAYS          4
`define RV32GC_L1D_LINE_BYTES    32
`define RV32GC_L1D_SETS          (RV32GC_L1D_SIZE_BYTES / (RV32GC_L1D_WAYS * RV32GC_L1D_LINE_BYTES))
`define RV32GC_L1D_INDEX_BITS    8       // VA[12:5]（256 组）
`define RV32GC_L1D_OFFSET_BITS   5
`define RV32GC_L1_CACHEABLE      1       // L1 写回 + 写分配
`define RV32GC_L1_WRITEBACK      1
`define RV32GC_L1_WRITE_ALLOCATE 1
// ---- L2（2A 不实现；仅登记 M6 口径） ----
`define RV32GC_L2_SIZE_KB        256
`define RV32GC_L2_WAYS           8
`define RV32GC_L2_LINE_BYTES     64      // CMO clean/flush 的 block 粒度来源
`define RV32GC_L2_IMPLEMENTED    0       // 2A = 0（M6 才置 1）
// ---- CMO block size（用户裁决 2026-09-14，08 §6.5） ----
`define RV32GC_CBOM_BLOCK_SIZE   64      // cbo.clean / cbo.flush 的 block（= L2 行）
`define RV32GC_CBOZ_BLOCK_SIZE   32      // cbo.zero 的 block（= L1D 行）
`define RV32GC_CBOM_BLOCK_LSB    6       // 2^6 = 64 B（供 cmo_unit 向下对齐）
`define RV32GC_CBOZ_BLOCK_LSB    5       // 2^5 = 32 B

//==============================================================================
// 8. AXI 控制器参数（2A：核内手写主端口控制器，边界判定见 08 §7.1）
//==============================================================================
`define RV32GC_AXI_ID_I_FILL   4'd0     // 2A 单笔在途只发 ID 0；下列 ID 为 L2 阶段预留语义
`define RV32GC_AXI_ID_D_FILL    4'd1
`define RV32GC_AXI_ID_WRBACK    4'd2
`define RV32GC_AXI_ID_CMO       4'd3
`define RV32GC_AXI_MAX_BEATS    16      // 4 bit len ⇒ ≤16 beat = 64 B（32 bit 数据）
`define RV32GC_AXI_BEAT_BYTES   4       // 每 beat 4 B
`define RV32GC_AXI_LINE_FILL_LEN (RV32GC_L1I_LINE_BYTES / RV32GC_AXI_BEAT_BYTES)  // 8 beat
`define RV32GC_AXI_OUTSTANDING   1      // 2A：同一时刻只允许一笔读或一笔写在途

//==============================================================================
// 9. IP 双分支开关（AGENT.md §4 红线 1/2；08 §3.3、§7.3）
//    `RV32GC_USE_VIVADO_IP`：**综合脚本定义**（synth.tcl 走 Vivado IP）；
//    **iverilog / Verilator 回归从不定义**（走逐拍等价行为模型）。
//    宏名固定，不得改名（08 §3.3 第 3 条）。
//==============================================================================
// 提示：不要在此处 `define RV32GC_USE_VIVADO_IP——默认必须是"未定义=仿真行为模型"。
`ifdef RV32GC_USE_VIVADO_IP
  `define RV32GC_IP_SEL_VIVADO       1
  `define RV32GC_IP_SEL_BEHAVIOR     0
`else
  `define RV32GC_IP_SEL_VIVADO       0
  `define RV32GC_IP_SEL_BEHAVIOR     1
`endif
// 各类 IP 的归属登记（供综合脚本与评审核对；红线 1 要求留检索结论）
`define RV32GC_IP_BRAM          1       // Block Memory Generator：Cache 数据/Tag 阵列
`define RV32GC_IP_MULTIPLIER    1       // Multiplier：MDU 乘法
`define RV32GC_IP_DIVIDER       1       // Divider Generator：MDU 除法
`define RV32GC_IP_CLOCKING      0       // Clocking Wizard：**本项目不新造**（平台已例化 clk_pll_33）

//==============================================================================
// 10. 启动/回归预期常量（供 M1 TB 与后续自检脚本使用；不含任何行为逻辑）
//==============================================================================
`define RV32GC_FIRST_INST_ADDR  `RV32GC_RESET_PC   // chiplab common.h:9 口径
`define RV32GC_ISA_STRING       "RV32IMAFDCZicsr_Zifencei_Zicntr_Zicbom"
//      ^ 2A 实现的扩展集合（08 §1.1）。**仅作字符串标识**（报告/日志用）；
//        不得用于条件编译（Verilog 宏在 `ifdef` 中不能比较字符串内容）。
//        Spike 侧 --isa 字符串须另按 spike 实际接受的形式书写（08 §8.3）。
`define RV32GC_IMPLEMENTS_ZICSR    1
`define RV32GC_IMPLEMENTS_ZIFENCEI 1
`define RV32GC_IMPLEMENTS_ZICNTR   1
`define RV32GC_IMPLEMENTS_ZICBOM   1
`define RV32GC_IMPLEMENTS_ZICBOZ   0   // 2A 不含（08 §11 R1）
`define RV32GC_IMPLEMENTS_SV32     1
`define RV32GC_IMPLEMENTS_PMP16    1

`endif // CORE_PARAMS_VH
