//==============================================================================
// sim/unit/dyn_probe_n29b_lockstep.sv —— N29B 探针：tb_back2_lockstep 的 5 个程序
// bench 列 = TB 的 `pi`（逐程序一次复位）。
//==============================================================================
`timescale 1ns / 1ps
`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"
`include "rtl/front4/front4_params.vh"
`include "rtl/back2/back2_params.vh"

module dyn_probe_n29b_lockstep;
    tb_back2_lockstep_top u_tb ();
    wire [31:0] dyn_bench = u_tb.pi;
`define DYN_LSU u_tb.u_back.u_lsu
`include "sim/unit/dyn_probe_n29b_body.inc"
`undef DYN_LSU
endmodule
