//==============================================================================
// sim/unit/dyn_probe_n21b_ipc.sv —— EXP-N21B 探针：tb_back2_ipc（后端直驱 4 宽 ALU 流）
//------------------------------------------------------------------------------
// 目的：**"多 ALU lane 同发"** 的极端负载（IPC 基准 = 理想 4 宽 addi 链）——
//       它是"ALU0∪ALU1 绝对不能合并"（同拍 100%）的正对照，也是 C1/C4 候选
//       （涉及 ALU0）能否保住 `IPC=2.0000` 的判定负载。
// 用法：
//   iverilog "${RV32_IV_FLAGS[@]}" -g2012 -o /tmp/n21b_ipc.vvp -s dyn_probe_n21b_ipc \
//            "${RTL[@]}" sim/unit/tb_back2_ipc.sv sim/unit/dyn_probe_n21b_core.sv \
//            sim/unit/dyn_probe_n21b_ipc.sv
//   vvp /tmp/n21b_ipc.vvp
// 产物：fpga/scratch/n21b/n21b_ipc.csv（bench 列恒 0；1 次运行）
//==============================================================================
`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"
`include "rtl/front4/front4_params.vh"
`include "rtl/back2/back2_params.vh"

module dyn_probe_n21b_ipc;

    tb_back2_ipc u_tb ();

`define N21B_BK    u_tb.u_back
`define N21B_FNAME "fpga/scratch/n21b/n21b_ipc.csv"
`define N21B_BENCH 32'd0
`define N21B_CLK   u_tb.clk
`define N21B_RST   u_tb.rst_n
`define N21B_EN    1'b1
`include "sim/unit/dyn_probe_n21b_body.inc"
`undef N21B_EN
`undef N21B_RST
`undef N21B_CLK
`undef N21B_BENCH
`undef N21B_FNAME
`undef N21B_BK

endmodule
