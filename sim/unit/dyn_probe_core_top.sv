//==============================================================================
// sim/unit/dyn_probe_core_top.sv —— 动态行为探针：tb_core_top_2b 的 14 个程序
//------------------------------------------------------------------------------
// 目的：在**更多访存 / FP / 陷阱 / CSR / Sv32 混合**的程序集上补足动态行为数据
//       （锁步 5 程序之外的加强覆盖；任务书"若能顺带跑…更好"）。
//
// 用法（仓库根 = rv32gc-cpu/）：
//   source scripts/env.sh
//   iverilog -g2012 -I rtl/pkg -I . -o /tmp/dyn_ct.vvp -s dyn_probe_core_top \
//            "${RTL[@]}" sim/unit/tb_core_top_2b.sv sim/unit/dyn_probe_core.sv \
//            sim/unit/dyn_probe_core_top.sv
//   vvp /tmp/dyn_ct.vvp
// 产物：fpga/scratch/dyn/core_top_2b.csv（bench 列 = TB 的 pid 0..13）
//
// 口径注意：本 TB 逐程序一次复位（rst_n 在程序边界置 0）；探针只在 rst_n==1 时采样，
//   故 bench 列即程序号。程序 → 源文件映射见 tb_core_top_2b.sv:511-517 的 pidx[]。
//==============================================================================
`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"
`include "rtl/front4/front4_params.vh"
`include "rtl/back2/back2_params.vh"

module dyn_probe_core_top;

    tb_core_top_2b u_tb ();

    wire [31:0] dyn_bench = u_tb.pid;

`define DYN_BK u_tb.u_dut.u_back
`define DYN_FNAME "fpga/scratch/dyn/core_top_2b.csv"
`include "sim/unit/dyn_probe_back2_body.inc"
`undef DYN_FNAME
`undef DYN_BK

endmodule
