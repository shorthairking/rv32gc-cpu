//==============================================================================
// core_top_synth_wrap.v —— 核级综合用包装（只为拿"本核自己"的时序/资源/BRAM 数据）
//
// 为什么需要：整板综合耗时长（还要跑平台 11 个 IP），核级综合能在几分钟内先回答：
//   ① 33 MHz（30.303 ns 周期）下本核 WNS 是否 ≥ 0；
//   ② Cache 数据阵列是否真的落在 BRAM（`RAMB36` 计数 > 0，且看不到大阵列退化成触发器）。
//
// ⚠ 关键：AXI 主设备侧输出**必须作为模块端口引出**！
//   第 25 轮实测踩到的坑：把这些输出写成内部 `wire`（悬空）时，整个核被综合器优化掉，
//   综合"成功"但网表是空的（利用率全 0、Place 报 `The design is empty`），
//   于是"没有任何 RAM 推断错误"这种结论完全是假象。引出端口后设计才是真的。
//
// 口径声明：核级数据（不含平台互连/DDR/UART/NAND）不能替代整板判据；
//   整板仍需 `fpga/tcl/build_chiplab.tcl`。
//==============================================================================
`timescale 1ns/1ps

module core_top_synth_wrap (
  input  wire        aclk,
  input  wire        aresetn,
  input  wire [7:0]  intrpt,
  // ---- AXI4 主设备侧输出（全部引出，保证逻辑不被优化）----
  output wire [3:0]  arid,
  output wire [31:0] araddr,
  output wire [3:0]  arlen,
  output wire [2:0]  arsize,
  output wire [1:0]  arburst,
  output wire [1:0]  arlock,
  output wire [3:0]  arcache,
  output wire [2:0]  arprot,
  output wire        arvalid,
  output wire        rready,
  output wire [3:0]  awid,
  output wire [31:0] awaddr,
  output wire [3:0]  awlen,
  output wire [2:0]  awsize,
  output wire [1:0]  awburst,
  output wire [1:0]  awlock,
  output wire [3:0]  awcache,
  output wire [2:0]  awprot,
  output wire        awvalid,
  output wire [3:0]  wid,
  output wire [31:0] wdata,
  output wire [3:0]  wstrb,
  output wire        wlast,
  output wire        wvalid,
  output wire        bready,
  // ---- 调试组输出 ----
  output wire [31:0] debug0_wb_pc,
  output wire [3:0]  debug0_wb_rf_wen,
  output wire [4:0]  debug0_wb_rf_wnum,
  output wire [31:0] debug0_wb_rf_wdata
);
  // ---- AXI 从设备侧输入：绑常量（本包装只做综合，不做功能仿真）----
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

  // ---- 调试组输入 ----
  wire        break_point = 1'b0;
  wire        infor_flag  = 1'b0;
  wire [4:0]  reg_num     = 5'd0;

  // 内部调试/回读信号（不引出，避免影响被优化判断）
  wire [31:0] rf_rdata;
  wire        ws_valid;

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
