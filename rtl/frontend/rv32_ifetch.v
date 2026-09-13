//=============================================================================
// rv32_ifetch.v —— 取指单元（基线核：单行缓冲 + AXI 整行读）
//
// 功能：缓存当前 PC 所在的 32 B 行（16 个半字），向流水线提供 pc 处的两个半字：
//   hw0 = 半字[pc]，hw1 = 半字[pc+2]；若 hw0[1:0] != 2'b11 则为 16 位压缩指令，
//   否则由上层拼成 32 位指令（见 rv32gc_core.v）。
// 时序：line_valid=0 时发起 AXI 8-beat 读；数据返回后同拍/次拍可用。
// 说明：阶段 2A 后续会用带 TLB 的 I-Cache 替换本模块（接口保持不变）。
//=============================================================================
`include "rv32gc_defs.vh"

module rv32_ifetch (
  input  wire         clk,
  input  wire         rst_n,

  input  wire [31:0]  pc,             // 当前取指地址（任意对齐，2 字节粒度）
  output wire [15:0]  hw0,
  output wire [15:0]  hw1,
  output wire         line_valid,     // 该 PC 所在行已就绪

  input  wire         flush,          // 重定向/异常：丢弃当前行

  // ---- AXI 取指客户端（rv32_axi_master） ----
  output reg          if_req_valid,
  output reg  [31:0]  if_req_addr,
  input  wire         if_req_ready,
  input  wire         if_rsp_valid,
  input  wire [255:0] if_rsp_data,
  input  wire         if_rsp_err,
  output wire         if_rsp_ready
);

  reg [255:0] line_q;
  reg [31:0]  line_tag_q;      // PC[31:5]
  reg         line_vld_q;
  reg         busy_q;          // 正在等待 AXI 返回

  wire        hit = line_vld_q && (pc[31:5] == line_tag_q[31:5]);   // 比较行号（line_tag_q 存的是完整字节地址）
  assign line_valid = hit;
  assign if_rsp_ready = 1'b1;  // 收到即接收

  // 行内选择：半字索引 = pc[4:1]，第 idx 个半字位于位偏移 idx*16
  wire [3:0]  idx = pc[4:1];
  assign hw0 = line_q[{idx, 4'b0000} +: 16];
  assign hw1 = (idx == 4'd15) ? 16'd0 : line_q[{idx, 4'b0000} + 16 +: 16];

  always @(posedge clk) begin
    if (!rst_n) begin
      line_q      <= 256'd0;
      line_tag_q  <= 32'hFFFF_FFFF;
      line_vld_q  <= 1'b0;
      busy_q      <= 1'b0;
      if_req_valid<= 1'b0;
      if_req_addr <= 32'd0;
    end else begin
      // 1) 接收 AXI 数据（即使同拍发生 flush 也要接收，否则 busy_q 会永久卡住）
      if (if_rsp_valid) begin
        line_q     <= if_rsp_data;
        line_tag_q <= if_req_addr;
        line_vld_q <= 1'b1;
        busy_q     <= 1'b0;
      end

      // 2) 冲刷：使当前行失效（后赋值优先），但不清 busy_q
      if (flush) begin
        line_vld_q   <= 1'b0;
        if_req_valid <= 1'b0;
      end

      // 3) 发起新取指（未命中、无在途请求、且本拍未冲刷）
      if (!hit && !busy_q && !if_req_valid && !flush) begin
        if_req_valid <= 1'b1;
        if_req_addr  <= {pc[31:5], 5'b0};
        busy_q       <= 1'b1;
      end

      // 4) 请求被接受
      if (if_req_valid && if_req_ready) begin
        if_req_valid <= 1'b0;
      end
    end
  end

endmodule
