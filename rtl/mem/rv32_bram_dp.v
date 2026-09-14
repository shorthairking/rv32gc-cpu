//==============================================================================
// rv32_bram_dp.v —— 简单双口 Block RAM（1 写口 + 1 **同步** 读口）
//
// 为什么需要它（第 25 轮实测结论，务必不要再退回组合读）：
//   · BRAM 的读端口**自带输出寄存器**，只能同步读；对 `mem[addr]` 做组合读的写法
//     Vivado 会判 "Block RAM or DRAM implementation is not possible" 并
//     `RAM "line_memX_reg" dissolved into registers` ⇒ 48 KB 阵列变成 39 万个触发器
//     （Artix-7 200T 只有 27 万个 FF）⇒ 实现必然失败。
//   · 同时 `(* ram_style = "block" *)` 一旦写了，Vivado 就不会退到 LUTRAM，
//     而是直接退化成触发器 —— 这是第 25 轮整板综合日志里真实发生的事。
//   ⇒ 数据阵列一律走本模块：**同步读**，综合成 RAMB36E1/RAMB18E1；
//     tag/valid/标记位仍留在 LUTRAM/触发器（小、且需要组合比较）。
//
// 语义（仿真与器件一致）：本模块是「两个 always 块 + 非阻塞赋值」的规范模板，
//   同拍同址读写 ⇒ 读到**旧值**（READ_FIRST）。Cache 侧的逻辑必须按这个语义设计。
//
// 用法（综合/仿真同一段 RTL，无需 ifdef，iverilog/Verilator 可直接编译）：
//   rv32_bram_dp #(.DEPTH(1024), .DW(32), .AW(10)) u_mem0 (
//       .clk(clk), .we(we0), .waddr(wa0), .wdata(wd0), .wstrb(ws0),
//       .re(re0), .raddr(ra0), .rdata(rd0));
//
// 参数约束：DEPTH 必须为 2 的幂；AW = log2(DEPTH)；DW 为 8 的倍数。
//==============================================================================
`timescale 1ns/1ps

module rv32_bram_dp #(
  parameter integer DEPTH = 1024,
  parameter integer DW    = 32,
  parameter integer AW    = 10
)(
  input  wire          clk,
  // ---- 写口（字节使能）----
  input  wire          we,
  input  wire [AW-1:0] waddr,
  input  wire [DW-1:0] wdata,
  input  wire [DW/8-1:0] wstrb,
  // ---- 读口（同步：raddr 在本拍，rdata 在下一拍）----
  input  wire          re,
  input  wire [AW-1:0] raddr,
  output reg  [DW-1:0] rdata
);

  (* ram_style = "block" *) reg [DW-1:0] mem [0:DEPTH-1];

  integer i;

  // 写（字节使能；UG901 的 byte-wide write enable 模板，BRAM 有对应 WE 引脚）
  always @(posedge clk) begin
    if (we) begin
      for (i = 0; i < DW/8; i = i + 1) begin
        if (wstrb[i]) mem[waddr][i*8 +: 8] <= wdata[i*8 +: 8];
      end
    end
  end

  // 读（同步 ⇒ BRAM 输出寄存器；与写口分离 ⇒ 简单双口）
  always @(posedge clk) begin
    if (re) rdata <= mem[raddr];
  end

endmodule
