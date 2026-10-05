//==============================================================================
// sim/unit/dyn_probe_r_core_top.sv —— 容量探针：tb_core_top_2b 的 14 个程序（扩展集）
//------------------------------------------------------------------------------
// 用法（**冻结树**编译；见 fpga/scratch/dyn_r_run.sh）：
//   iverilog -g2012 -I rtl/pkg -I . -o /tmp/dyn_r_ct.vvp -s dyn_probe_r_core_top \
//            "${RTL[@]}" sim/unit/tb_core_top_2b.sv sim/unit/dyn_probe_r_core.sv \
//            sim/unit/dyn_probe_r_core_top.sv
// 产物：fpga/scratch/dyn_r/core_top_2b.csv（bench 列 = TB 的 pid 0..13）
//
//   口径注意：本 TB 逐程序一次复位（rst_n 在程序边界置 0）；探针只在 rst_n==1 时采样。
//==============================================================================
`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"
`include "rtl/front4/front4_params.vh"
`include "rtl/back2/back2_params.vh"

module dyn_probe_r_core_top;

    tb_core_top_2b u_tb ();

    wire [31:0] dyn_bench = u_tb.pid;

`define DYN_BK u_tb.u_dut.u_back
`define DYN_FE   u_tb.u_dut.u_front.u_bpu
`define DYN_FNAME "fpga/scratch/dyn_r/core_top_2b.csv"
`include "sim/unit/dyn_probe_r_body.inc"
`undef DYN_FNAME
`undef DYN_FE
`undef DYN_BK

endmodule
