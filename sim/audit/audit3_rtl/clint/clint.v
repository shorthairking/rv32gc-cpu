//==============================================================================
// rtl/clint/clint.v —— 核内 CLINT（Core-Local Interruptor）
//==============================================================================
// 项目    : rv32gc-cpu（阶段二 2A：单发射顺序 5 级基线核）
// 规格    : docs/design/08-baseline-5stage.md §6.6「核内 CLINT / PLIC 与 intrpt[4:0] 接线」
// 真源    : rtl/pkg/core_params.vh §5（CLINT 寄存器偏移）、rv32_defs.vh §6.2（cause 码）
//
// 职责    : 实现 RISC-V ACLINT / SiFive CLINT 惯例的三个寄存器：
//             msip       @ 基址 + 0x0000   32 bit  R/W
//             mtimecmp   @ 基址 + 0x4000   64 bit  R/W（RV32 拆两个 32 位字，低字在低地址）
//             mtime      @ 基址 + 0xBFF8   64 bit  R/W（由 aclk 计数）
//           基址 = RV32GC_CLINT_BASE = 0x1F00_0000（core_params.vh §2）。
//
// 行为口径:
//   1. msip：软件写 1 ⇒ MSIP 置位（mip.MSIP 源，cause 3 MSI）；写 0 ⇒ 清位。
//      只有 bit0 有语义（SiFive CLINT 口径：msip 为 32 位寄存器，仅 bit0 有效）。
//   2. mtime：**由 aclk 每拍 +1** 的自由计数器（RV32GC_TIMEBASE_HZ = 33 MHz，
//      1 tick ≈ 30.3 ns）。软件可写（整 64 位可读写）。
//   3. mtimecmp：64 位可写比较值。当 mtime > mtimecmp（**无符号、严格大于**，
//      SiFive/ACLINT 口径）⇒ MTIP 置位（cause 7 MTI）。软件写 mtimecmp 使
//      mtime <= mtimecmp 后 MTIP 随之清 0 —— 这是**纯组合**的
//      `mtip = (mtime > mtimecmp)`，因此"写 mtimecmp 清 MTIP"天然成立，
//      无需任何状态机，也**杜绝了"清中断需要额外写 CLINT 寄存器"的偏差**。
//
// 中断输出（只出核内总线侧信号，**不产生任何 AXI 请求**）:
//   msip_o —— 接 mip.MSIP（rv32_defs.vh RV32GC_MIP_MSIP_BIT = 3）
//   mtip_o —— 接 mip.MTIP（RV32GC_MIP_MTIP_BIT = 7）
//
// ★ 红线遵守声明（AGENT.md §4）:
//   - 本模块**不含任何 FPGA 原语**，也不含任何 IP 例化：全部为可综合 RTL 行为描述。
//   - 本模块**没有 AXI 端口**（无 aw/w/b/ar/r）：CLINT 是核内设备，其寄存器访问
//     由 `rtl/mem/mmio_route.v` 在核内截获（08 §6.6 的 NOC 分支）；
//     因此"CLINT 访问绝不产生 AXI 请求"在**端口层面即天然满足**。
//   - 组合逻辑风格（AGENT.md §4 红线 3）：译码/比较全部用 `assign`/`function`
//     连续赋值表达；`always` 块**只有一处**（mtime 自由计数器与寄存器更新），
//     且不含"多个 reg 的组合赋值"写法。
//
// 端口约定:
//   aclk / aresetn —— 低有效异步复位、上升沿同步（与核内其余模块一致）；
//   req_valid/req_write/req_addr/req_wdata/req_wstrb —— 核内 MMIO 请求（单拍握手）；
//   resp_rdata/resp_hit —— 组合读数据与命中指示（命中即本模块属主）。
//   请求侧地址 req_addr 为**本 CLINT 窗口内的偏移**（由 mmio_route.v 减基址后送来）。
//==============================================================================
`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"

module clint (
    input  wire        aclk,
    input  wire        aresetn,

    // ---- 核内 MMIO 请求（来自 mmio_route.v；地址已减去 CLINT 基址） ----
    input  wire        req_valid,
    input  wire        req_write,              // 1=写, 0=读
    input  wire [31:0] req_addr,               // 窗口内偏移
    input  wire [31:0] req_wdata,
    input  wire [3:0]  req_wstrb,              // 字节使能（本设计只用 32 位对齐访问）

    // ---- 读响应（组合） ----
    output wire [31:0] resp_rdata,
    output wire        resp_hit,               // 1=本模块响应该请求

    // ---- 中断输出（汇入 mip） ----
    output wire        msip_o,                 // ⇒ mip.MSIP（cause 3 MSI）
    output wire        mtip_o                  // ⇒ mip.MTIP（cause 7 MTI）
);

    //--------------------------------------------------------------------------
    // 1. 寄存器偏移（真源：core_params.vh §5；本模块内取局部别名便于阅读）
    //--------------------------------------------------------------------------
    localparam [31:0] MSIP_OFF      = `RV32GC_CLINT_MSIP_OFF;       // 0x0000_0000
    localparam [31:0] MTIMECMP_OFF  = `RV32GC_CLINT_MTIMECMP_OFF;   // 0x0000_4000
    localparam [31:0] MTIMECMPH_OFF = `RV32GC_CLINT_MTIMECMPH_OFF;  // 0x0000_4004
    localparam [31:0] MTIME_OFF     = `RV32GC_CLINT_MTIME_OFF;      // 0x0000_BFF8
    localparam [31:0] MTIMEH_OFF    = `RV32GC_CLINT_MTIMEH_OFF;     // 0x0000_BFFC

    //--------------------------------------------------------------------------
    // 2. 译码（纯组合；只写一处，读与写共用）
    //--------------------------------------------------------------------------
    wire sel_msip      = (req_addr == MSIP_OFF);
    wire sel_mtimecmp  = (req_addr == MTIMECMP_OFF);
    wire sel_mtimecmph = (req_addr == MTIMECMPH_OFF);
    wire sel_mtime     = (req_addr == MTIME_OFF);
    wire sel_mtimeh    = (req_addr == MTIMEH_OFF);

    // 地址对齐口径：只有 32 位字对齐的这四个/五个地址被响应；
    // 其余偏移（含未实现空洞）不命中 ⇒ 由 mmio_route 按平台默认通路处理。
    assign resp_hit = sel_msip | sel_mtimecmp | sel_mtimecmph | sel_mtime | sel_mtimeh;

    // 写命中选择（组合）
    wire wr_msip      = req_valid & req_write & sel_msip;
    wire wr_mtimecmp  = req_valid & req_write & sel_mtimecmp;
    wire wr_mtimecmph = req_valid & req_write & sel_mtimecmph;
    wire wr_mtime     = req_valid & req_write & sel_mtime;
    wire wr_mtimeh    = req_valid & req_write & sel_mtimeh;

    // 读命中选择（组合）
    wire rd_msip      = req_valid & ~req_write & sel_msip;
    wire rd_mtimecmp  = req_valid & ~req_write & sel_mtimecmp;
    wire rd_mtimecmph = req_valid & ~req_write & sel_mtimecmph;
    wire rd_mtime     = req_valid & ~req_write & sel_mtime;
    wire rd_mtimeh    = req_valid & ~req_write & sel_mtimeh;

    // 字节使能合并 —— 本设计只支持 32 位整字访问（核内 MMIO 一律字对齐、
    // 由 lsu 保证），故用"任一字节使能有效即整字写"的简化口径；
    // 该口径在注释中固定，避免后续被误当通用字节写实现。
    wire wr_en = |req_wstrb;

    //--------------------------------------------------------------------------
    // 3. 状态寄存器
    //--------------------------------------------------------------------------
    reg        msip_r;           // msip bit0
    reg [63:0] mtime_r;          // mtime 自由计数器
    reg [63:0] mtimecmp_r;       // mtimecmp 比较值

    //--------------------------------------------------------------------------
    // 4. 组合输出（只出核内总线侧信号；**无 AXI 端口 ⇒ 绝不产生 AXI 请求**）
    //--------------------------------------------------------------------------
    assign msip_o = msip_r;
    // MTIP = (mtime > mtimecmp)，无符号严格大于（SiFive / ACLINT 口径）。
    // 纯组合 ⇒ 软件写 mtimecmp 抬高比较值后 MTIP 立刻自清（08 §6.6 / 验收判据 ③）。
    assign mtip_o = (mtime_r > mtimecmp_r);

    // 读数据：多路选择用连续赋值（红线 3）
    assign resp_rdata = rd_msip      ? {31'b0, msip_r}          :
                        rd_mtimecmp  ? mtimecmp_r[31:0]         :
                        rd_mtimecmph ? mtimecmp_r[63:32]        :
                        rd_mtime     ? mtime_r[31:0]            :
                        rd_mtimeh    ? mtime_r[63:32]           :
                                       32'h0000_0000;

    //--------------------------------------------------------------------------
    // 5. 时序：寄存器更新
    //    ★ 唯一的 always 块（AGENT.md §4 红线 3 允许的"少量必要场合"）：
    //      mtime 是**自由计数器**，必须在一个时钟沿对自身 +1 并由软写覆盖，
    //      这是状态保持语义，不能写成连续赋值；其余逻辑全部在 assign 中。
    //--------------------------------------------------------------------------
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            msip_r     <= 1'b0;
            mtime_r    <= 64'd0;
            mtimecmp_r <= 64'hFFFF_FFFF_FFFF_FFFF;   // 复位取最大值 ⇒ MTIP 不置位
        end else begin
            // ---- mtime：每拍 +1（33 MHz 自由计数） ----
            //      软件写 mtime（低字/高字）优先于自增。
            if (wr_mtime) begin
                mtime_r[31:0] <= req_wdata;
            end else if (wr_mtimeh) begin
                mtime_r[63:32] <= req_wdata;
            end else begin
                mtime_r <= mtime_r + 64'd1;
            end

            // ---- mtimecmp：低字/高字各自可写 ----
            if (wr_mtimecmp)  mtimecmp_r[31:0]  <= req_wdata;
            if (wr_mtimecmph) mtimecmp_r[63:32] <= req_wdata;

            // ---- msip：写 1 置位（MSI），写 0 清位 ----
            if (wr_msip && wr_en) msip_r <= req_wdata[0];
        end
    end

endmodule
