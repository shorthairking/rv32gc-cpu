//=============================================================================
// core_top.v —— chiplab 平台兼容的处理器顶层壳
//
// 端口与平台契约**逐位一致**（见 docs/design/spec/03-pipeline-regs.md §7.1 与
// chiplab/docs/Quick-Start.md）：aclk/aresetn/intrpt[7:0] + AXI4 主设备 + 平台调试信号。
//
// 内部结构：
//   core_top
//     ├── 复位同步器（aresetn 异步置位、同步释放）
//     ├── rv32_axi_master（取指 8 beat 整行读 + 数据单拍读写）
//     └── rv32gc_core（顺序 5 级基线核）
//=============================================================================
`include "rv32gc_defs.vh"

module core_top (
  input  wire         aclk,
  input  wire         aresetn,
  input  wire [7:0]   intrpt,

  // ---- AXI4 读地址 ----
  output wire [3:0]   arid,
  output wire [31:0]  araddr,
  output wire [3:0]   arlen,
  output wire [2:0]   arsize,
  output wire [1:0]   arburst,
  output wire [1:0]   arlock,
  output wire [3:0]   arcache,
  output wire [2:0]   arprot,
  output wire         arvalid,
  input  wire         arready,

  // ---- AXI4 读数据 ----
  input  wire [3:0]   rid,
  input  wire [31:0]  rdata,
  input  wire [1:0]   rresp,
  input  wire         rlast,
  input  wire         rvalid,
  output wire         rready,

  // ---- AXI4 写地址 ----
  output wire [3:0]   awid,
  output wire [31:0]  awaddr,
  output wire [3:0]   awlen,
  output wire [2:0]   awsize,
  output wire [1:0]   awburst,
  output wire [1:0]   awlock,
  output wire [3:0]   awcache,
  output wire [2:0]   awprot,
  output wire         awvalid,
  input  wire         awready,

  // ---- AXI4 写数据 ----
  output wire [3:0]   wid,
  output wire [31:0]  wdata,
  output wire [3:0]   wstrb,
  output wire         wlast,
  output wire         wvalid,
  input  wire         wready,

  // ---- AXI4 写响应 ----
  input  wire [3:0]   bid,
  input  wire [1:0]   bresp,
  input  wire         bvalid,
  output wire         bready,

  // ---- 平台串口调试单元 ----
  input  wire         break_point,
  input  wire         infor_flag,
  input  wire [4:0]   reg_num,
  output wire [31:0]  rf_rdata,
  output wire         ws_valid,

  // ---- 平台 difftest 端口 ----
  output wire [31:0]  debug0_wb_pc,
  output wire [3:0]   debug0_wb_rf_wen,
  output wire [4:0]   debug0_wb_rf_wnum,
  output wire [31:0]  debug0_wb_rf_wdata
);

  // ---------------------------------------------------------------- 复位同步
  reg [1:0] rst_sync_q;
  always @(posedge aclk or negedge aresetn) begin
    if (!aresetn) rst_sync_q <= 2'b00;
    else          rst_sync_q <= {rst_sync_q[0], 1'b1};
  end
  wire rst_n = rst_sync_q[1];

  // ---------------------------------------------------------------- AXI 主设备
  wire        if_req_valid, if_req_ready, if_rsp_valid, if_rsp_ready, if_rsp_err;
  wire [31:0] if_req_addr;
  wire [255:0] if_rsp_data;

  wire        d_req_valid, d_req_we, d_req_ready, d_rsp_valid, d_rsp_ready, d_rsp_err;
  wire [31:0] d_req_addr, d_req_wdata, d_rsp_rdata;
  wire [3:0]  d_req_wstrb;

  rv32_axi_master u_axi (
    .clk(aclk), .rst_n(rst_n),
    .if_req_valid(if_req_valid), .if_req_addr(if_req_addr), .if_req_ready(if_req_ready),
    .if_rsp_valid(if_rsp_valid), .if_rsp_data(if_rsp_data), .if_rsp_err(if_rsp_err),
    .if_rsp_ready(if_rsp_ready),
    .d_req_valid(d_req_valid), .d_req_we(d_req_we), .d_req_addr(d_req_addr),
    .d_req_wdata(d_req_wdata), .d_req_wstrb(d_req_wstrb), .d_req_ready(d_req_ready),
    .d_rsp_valid(d_rsp_valid), .d_rsp_rdata(d_rsp_rdata), .d_rsp_err(d_rsp_err),
    .d_rsp_ready(d_rsp_ready),
    .arid(arid), .araddr(araddr), .arlen(arlen), .arsize(arsize), .arburst(arburst),
    .arlock(arlock), .arcache(arcache), .arprot(arprot), .arvalid(arvalid), .arready(arready),
    .rid(rid), .rdata(rdata), .rresp(rresp), .rlast(rlast), .rvalid(rvalid), .rready(rready),
    .awid(awid), .awaddr(awaddr), .awlen(awlen), .awsize(awsize), .awburst(awburst),
    .awlock(awlock), .awcache(awcache), .awprot(awprot), .awvalid(awvalid), .awready(awready),
    .wid(wid), .wdata(wdata), .wstrb(wstrb), .wlast(wlast), .wvalid(wvalid), .wready(wready),
    .bid(bid), .bresp(bresp), .bvalid(bvalid), .bready(bready)
  );

  // ---------------------------------------------------------------- 处理器核
  wire [31:0] dbg_pc, dbg_wdata;
  wire        dbg_valid, dbg_wen, dbg_trap;
  wire [4:0]  dbg_rd;
  wire [3:0]  dbg_cause;
  wire [1:0]  dbg_priv;
  wire [31:0] dbg_reg_data;

  rv32gc_core u_core (
    .clk(aclk), .rst_n(rst_n),
    .if_req_valid(if_req_valid), .if_req_addr(if_req_addr), .if_req_ready(if_req_ready),
    .if_rsp_valid(if_rsp_valid), .if_rsp_data(if_rsp_data), .if_rsp_err(if_rsp_err),
    .if_rsp_ready(if_rsp_ready),
    .d_req_valid(d_req_valid), .d_req_we(d_req_we), .d_req_addr(d_req_addr),
    .d_req_wdata(d_req_wdata), .d_req_wstrb(d_req_wstrb), .d_req_ready(d_req_ready),
    .d_rsp_valid(d_rsp_valid), .d_rsp_rdata(d_rsp_rdata), .d_rsp_err(d_rsp_err),
    .d_rsp_ready(d_rsp_ready),
    .intrpt(intrpt),
    .dbg_commit_pc(dbg_pc), .dbg_commit_valid(dbg_valid), .dbg_commit_wen(dbg_wen),
    .dbg_commit_rd(dbg_rd), .dbg_commit_wdata(dbg_wdata), .dbg_priv(dbg_priv),
    .dbg_trap(dbg_trap), .dbg_trap_cause(dbg_cause),
    .dbg_reg_addr(reg_num), .dbg_reg_data(dbg_reg_data)
  );

  // ---------------------------------------------------------------- 平台调试/轨迹
  // ws_valid：提交一条写寄存器指令时置起（供平台串口调试单元采样）
  assign ws_valid = dbg_valid && dbg_wen;

  // rf_rdata：按 reg_num 读架构寄存器堆（组合读）
  assign rf_rdata = dbg_reg_data;

  // difftest：平台约定 wb_rf_wen 为 4 位（本核只用 bit0）
  assign debug0_wb_pc       = dbg_pc;
  assign debug0_wb_rf_wen   = {3'b000, dbg_wen};
  assign debug0_wb_rf_wnum  = dbg_rd;
  assign debug0_wb_rf_wdata = dbg_wdata;

  // 未使用输入（防止综合告警，保留平台语义）
  wire unused = break_point ^ infor_flag ^ (|intrpt) ^ (|dbg_priv) ^ dbg_trap ^ (|dbg_cause);

endmodule
