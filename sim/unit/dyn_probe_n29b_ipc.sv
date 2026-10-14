//==============================================================================
// sim/unit/dyn_probe_n29b_ipc.sv —— N29B 探针：tb_back2_ipc（后端 4 宽直驱，bench 恒 0）
//==============================================================================
`timescale 1ns / 1ps
`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"
`include "rtl/front4/front4_params.vh"
`include "rtl/back2/back2_params.vh"

module dyn_probe_n29b_ipc;
    tb_back2_ipc u_tb ();
    wire [31:0] dyn_bench = 32'd0;
`define DYN_LSU u_tb.u_back.u_lsu
`include "sim/unit/dyn_probe_n29b_body.inc"
`undef DYN_LSU
endmodule
