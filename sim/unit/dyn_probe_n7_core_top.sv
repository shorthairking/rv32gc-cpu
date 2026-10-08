//==============================================================================
// sim/unit/dyn_probe_n7_core_top.sv —— EXP-N7/N10 探针：tb_core_top_2b 的 14 个程序
//------------------------------------------------------------------------------
// 用法（仓库根 = rv32gc-cpu/；见 fpga/scratch/n7_run.sh）：
//   source scripts/env.sh
//   iverilog "${RV32_IV_FLAGS[@]}" -o /tmp/n7_ct.vvp -s dyn_probe_n7_core_top \
//            "${RTL[@]}" sim/unit/tb_core_top_2b.sv sim/unit/dyn_probe_n7_core.sv \
//            sim/unit/dyn_probe_n7_core_top.sv
//   vvp /tmp/n7_ct.vvp
// 产物：fpga/scratch/n7/core_top_2b.csv（bench 列 = TB 的 pid 0..13）
//
// 口径注意：本 TB 逐程序一次复位（rst_n 在程序边界置 0）；探针只在 rst_n==1 时采样，
//   故 bench 列即程序号。层次路径 = `u_tb.u_dut.u_back`（与 n4 同名探针一致）。
//==============================================================================
`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"
`include "rtl/front4/front4_params.vh"
`include "rtl/back2/back2_params.vh"

module dyn_probe_n7_core_top;

    tb_core_top_2b u_tb ();

    wire [31:0] dyn_bench = u_tb.pid;

`define DYN_BK u_tb.u_dut.u_back
`define DYN_FNAME "fpga/scratch/n7/core_top_2b.csv"
`include "sim/unit/dyn_probe_n7_body.inc"
`undef DYN_FNAME
`undef DYN_BK

endmodule
