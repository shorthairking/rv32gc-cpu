//==============================================================================
// sim/unit/dyn_probe_n29b_lsqfwd.sv —— N29B 探针：tb_back2_lsq_fwd（定向微基准）
//   LSQ 直驱（无 backend_top）；bench 恒 0。
//==============================================================================
`timescale 1ns / 1ps
`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"
`include "rtl/front4/front4_params.vh"
`include "rtl/back2/back2_params.vh"

module dyn_probe_n29b_lsqfwd;
    tb_back2_lsq_fwd_top u_tb ();
    wire [31:0] dyn_bench = 32'd0;
`define DYN_LSU u_tb.u_lsq
`include "sim/unit/dyn_probe_n29b_body.inc"
`undef DYN_LSU
endmodule
