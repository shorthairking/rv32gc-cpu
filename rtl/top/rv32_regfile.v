//=============================================================================
// rv32_regfile.v —— RV32I 架构寄存器堆（32 × 32bit）
//
// 功能：2 个组合读端口 + 1 个同步写端口；x0 恒为 0（读 x0 返回 0，写 x0 被忽略）。
// 时序：读为组合（同拍出数据）；写在 clk 上升沿生效。
// 说明：基线核（顺序 5 级）使用；乱序核改用物理寄存器堆 prf.v（阶段 2B）。
//=============================================================================
`include "rv32gc_defs.vh"

module rv32_regfile (
  input  wire        clk,
  input  wire        rst_n,

  // 读端口 A（rs1）
  input  wire [4:0]  raddr_a,
  output wire [31:0] rdata_a,
  // 读端口 B（rs2）
  input  wire [4:0]  raddr_b,
  output wire [31:0] rdata_b,

  // 写端口（WB 级）
  input  wire        wen,
  input  wire [4:0]  waddr,
  input  wire [31:0] wdata,

  // 调试读端口（平台 reg_num/rf_rdata）
  input  wire [4:0]  dbg_addr,
  output wire [31:0] dbg_rdata
);

  reg [31:0] regs [0:31];
  integer i;

  // 读：x0 恒 0
  assign rdata_a   = (raddr_a == 5'd0) ? 32'd0 : regs[raddr_a];
  assign rdata_b   = (raddr_b == 5'd0) ? 32'd0 : regs[raddr_b];
  assign dbg_rdata = (dbg_addr == 5'd0) ? 32'd0 : regs[dbg_addr];

  always @(posedge clk) begin
    if (!rst_n) begin
      for (i = 0; i < 32; i = i + 1) regs[i] <= 32'd0;
    end else if (wen && (waddr != 5'd0)) begin
      regs[waddr] <= wdata;
    end
  end

endmodule
