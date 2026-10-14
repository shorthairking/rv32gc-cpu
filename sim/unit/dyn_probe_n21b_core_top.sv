//==============================================================================
// sim/unit/dyn_probe_n21b_core_top.sv —— EXP-N21B 探针：tb_core_top_2b 的 14 个程序
//------------------------------------------------------------------------------
// 用法：
//   source scripts/env.sh
//   iverilog "${RV32_IV_FLAGS[@]}" -g2012 -o /tmp/n21b_ct.vvp -s dyn_probe_n21b_core_top \
//            "${RTL[@]}" sim/unit/tb_core_top_2b.sv sim/unit/dyn_probe_n21b_core.sv \
//            sim/unit/dyn_probe_n21b_core_top.sv
//   vvp /tmp/n21b_ct.vvp
// 产物：fpga/scratch/n21b/n21b_core_top.csv（bench 列 = TB 的 pid 0..13）
//==============================================================================
`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"
`include "rtl/front4/front4_params.vh"
`include "rtl/back2/back2_params.vh"

module dyn_probe_n21b_core_top;

    tb_core_top_2b u_tb ();

`define N21B_BK    u_tb.u_dut.u_back
`define N21B_FNAME "fpga/scratch/n21b/n21b_core_top.csv"
`define N21B_BENCH u_tb.pid
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
