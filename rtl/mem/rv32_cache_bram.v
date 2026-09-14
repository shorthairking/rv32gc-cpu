//==============================================================================
// rv32_cache_bram.v —— Cache 数据阵列的 Block RAM 包装（**综合用 Vivado IP 核**）
//
// 用户口径（第 25 轮）：Cache 数据阵列必须用**板上的 BRAM 资源**实现；
//   不使用"靠 ram_style 属性让综合器推断原语"的做法，而是**直接例化 Vivado 自带的
//   `blk_mem_gen` IP 核**（Simple Dual Port、1024×32、字节写使能、读延迟 1 拍）。
//   tag / valid / 替换位等小阵列仍留在 LUTRAM/触发器（用户已同意）。
//
// 为什么必须同步读（不要再改回组合读）：
//   BRAM 的读端口带输出寄存器 ⇒ 只能同步读。时钟：
//     拍 N：给出 raddr；拍 N+1：rdata 有效。
//   若写成 `assign data = mem[addr];`（组合读），Vivado 会把整个阵列
//   "dissolved into registers"（本项目第 25 轮整板综合实测：48 KB 阵列 → 39 万触发器，
//   Artix-7 200T 只有 27 万 FF ⇒ 实现必然失败）。
//
// 仿真/综合一致性（重要）：
//   · 综合：`ifdef RV32_BRAM_IP` 走 IP 例化（由 fpga/tcl/create_cache_bram_ip.tcl 生成，
//     工程里用 `set_property verilog_define RV32_BRAM_IP` 打开）。
//   · 仿真（iverilog/Verilator，回归全套）：同一模块走下面的行为模型 —— 语义逐拍等价：
//       读端口**每拍无条件**读 raddr（对应 IP 的 `Enable_B = Always_Enabled`，无 enb 引脚）；
//       写端口字节使能；同拍同址读写 ⇒ 读到**旧值**（READ_FIRST）。
//     ⇒ 两个分支的端口行为一致，仿真结果可直接代表上板行为。
//
// ⚠ 使用约束（Cache 侧必须遵守，否则 READ_FIRST/WRITE_FIRST 语义会影响结果）：
//   若某拍**写口**与**读口**访问同一地址，则本拍读出的数据视为**不可用**；
//   Cache 侧必须显式做冒险检查（比较写地址与读地址，相同则丢弃本次读并重发）。
//   `rtl/mem/rv32_dcache.v` / `rtl/frontend/rv32_icache.v` 均按此实现。
//==============================================================================
`timescale 1ns/1ps

module rv32_cache_bram #(
  parameter integer DEPTH = 1024,   // 字数（= 组数 × 每行字数）
  parameter integer DW    = 32,     // 字宽
  parameter integer AW    = 10      // 地址位宽 = log2(DEPTH)
)(
  input  wire            clk,
  // ---- 写口（字节使能）----
  input  wire            we,
  input  wire [AW-1:0]   waddr,
  input  wire [DW-1:0]   wdata,
  input  wire [DW/8-1:0] wstrb,
  // ---- 读口（同步、无条件读：拍 N 给 raddr，拍 N+1 出 rdata）----
  input  wire [AW-1:0]   raddr,
  output wire [DW-1:0]   rdata
);

`ifdef RV32_BRAM_IP
  //---------------------------------------------------------------------------
  // 综合路径：Vivado blk_mem_gen IP（Simple Dual Port，端口 A 写 / 端口 B 读）
  //---------------------------------------------------------------------------
  bmg_cache_1024x32 u_bram (
    .clka  (clk),
    .ena   (we),
    .wea   (wstrb),
    .addra (waddr),
    .dina  (wdata),
    .clkb  (clk),
    .addrb (raddr),
    .doutb (rdata)
  );
`else
  //---------------------------------------------------------------------------
  // 仿真路径：行为模型（与 IP 逐拍等价；同拍同址读写 = 读旧值）
  //---------------------------------------------------------------------------
  reg [DW-1:0] mem [0:DEPTH-1];
  integer i;

  always @(posedge clk) begin
    if (we) begin
      for (i = 0; i < DW/8; i = i + 1) begin
        if (wstrb[i]) mem[waddr][i*8 +: 8] <= wdata[i*8 +: 8];
      end
    end
  end

  reg [DW-1:0] rdata_q;
  always @(posedge clk) begin
    rdata_q <= mem[raddr];      // 无条件读（对应 Enable_B = Always_Enabled）
  end
  assign rdata = rdata_q;
`endif

endmodule
