//==============================================================================
// core_top_synth_wrap.v —— 核级综合用包装（只为拿"本核自己"的时序/资源/BRAM 推断数据）
//
// 为什么需要：整板综合目前被平台缺件挡住（chiplab 的 axi_2x1_mux 自定义 IP 源缺失）。
// 本包装把 core_top 的 AXI 从设备侧输入按常量绑死，使本核**可以独立综合**，
// 从而先回答计划 §11.2 的两个未知：
//   ① 33 MHz（30.303 ns）下本核 WNS 是否 ≥ 0；
//   ② L1I/L1D 的 32 B×路阵列是否被正确推断成 Block RAM（而不是分布式 RAM）。
//
// ⚠ 口径声明：这是**核级**数据（不含平台互连/DDR/UART/NAND），不能替代整板时序判据；
//    整板数据仍要等平台 IP 补齐后跑 fpga/tcl/build_chiplab.tcl。
//==============================================================================
module core_top_synth_wrap (
  input  wire        aclk,
  input  wire        aresetn,
  input  wire [7:0]  intrpt
);
  // ---- AXI 从设备侧输入：绑常量（本包装不做功能仿真，只做综合）----
  wire        arready = 1'b1;
  wire [3:0]  rid     = 4'b0;
  wire [31:0] rdata   = 32'b0;
  wire [1:0]  rresp   = 2'b0;
  wire        rlast   = 1'b0;
  wire        rvalid  = 1'b0;
  wire        awready = 1'b1;
  wire        wready  = 1'b1;
  wire [3:0]  bid     = 4'b0;
  wire [1:0]  bresp   = 2'b0;
  wire        bvalid  = 1'b0;

  // ---- debug 组输入 ----
  wire        break_point = 1'b0;
  wire        infor_flag  = 1'b0;
  wire [4:0]  reg_num     = 5'd0;

  // 未用的 AXI 主设备输出（综合会优化/保留，仅用于观察资源）
  wire [3:0]  arid;    wire [31:0] araddr;  wire [3:0] arlen;  wire [2:0] arsize;
  wire [1:0]  arburst; wire [1:0]  arlock;  wire [3:0] arcache; wire [2:0] arprot;
  wire        arvalid; wire         rready;
  wire [3:0]  awid;    wire [31:0] awaddr;  wire [3:0] awlen;  wire [2:0] awsize;
  wire [1:0]  awburst; wire [1:0]  awlock;  wire [3:0] awcache; wire [2:0] awprot;
  wire        awvalid; wire [3:0]  wid;     wire [31:0] wdata; wire [3:0] wstrb;
  wire        wlast;   wire         wvalid; wire         bready;
  wire [31:0] rf_rdata; wire ws_valid; wire [31:0] debug0_wb_pc;
  wire [3:0]  debug0_wb_rf_wen; wire [4:0] debug0_wb_rf_wnum; wire [31:0] debug0_wb_rf_wdata;

  core_top u_core (
    .aclk(aclk), .aresetn(aresetn), .intrpt(intrpt),
    .arid(arid), .araddr(araddr), .arlen(arlen), .arsize(arsize), .arburst(arburst),
    .arlock(arlock), .arcache(arcache), .arprot(arprot), .arvalid(arvalid), .arready(arready),
    .rid(rid), .rdata(rdata), .rresp(rresp), .rlast(rlast), .rvalid(rvalid), .rready(rready),
    .awid(awid), .awaddr(awaddr), .awlen(awlen), .awsize(awsize), .awburst(awburst),
    .awlock(awlock), .awcache(awcache), .awprot(awprot), .awvalid(awvalid), .awready(awready),
    .wid(wid), .wdata(wdata), .wstrb(wstrb), .wlast(wlast), .wvalid(wvalid), .wready(wready),
    .bid(bid), .bresp(bresp), .bvalid(bvalid), .bready(bready),
    .break_point(break_point), .infor_flag(infor_flag), .reg_num(reg_num),
    .rf_rdata(rf_rdata), .ws_valid(ws_valid),
    .debug0_wb_pc(debug0_wb_pc), .debug0_wb_rf_wen(debug0_wb_rf_wen),
    .debug0_wb_rf_wnum(debug0_wb_rf_wnum), .debug0_wb_rf_wdata(debug0_wb_rf_wdata)
  );
endmodule
