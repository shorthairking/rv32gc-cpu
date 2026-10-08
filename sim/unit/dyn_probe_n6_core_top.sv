//==============================================================================
// sim/unit/dyn_probe_n6_core_top.sv —— EXP-N6 探针：tb_core_top_2b 的 14 个程序
//------------------------------------------------------------------------------
// 产物：fpga/scratch/n6/core_top_2b.csv（bench 列 = TB 的 pid 0..13）
// 口径：本 TB 逐程序一次复位（rst_n 在程序边界置 0）；探针只在 rst_n==1 时采样，
//       故 bench 列即程序号。
//==============================================================================
`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"
`include "rtl/front4/front4_params.vh"
`include "rtl/back2/back2_params.vh"

module dyn_probe_n6_core_top;

    tb_core_top_2b u_tb ();

    wire [31:0] dyn_bench = u_tb.pid;

`define DYN_BK u_tb.u_dut.u_back
`define DYN_FNAME "fpga/scratch/n6/core_top_2b.csv"
`include "sim/unit/dyn_probe_n6_body.inc"
`undef DYN_FNAME
`undef DYN_BK

endmodule
