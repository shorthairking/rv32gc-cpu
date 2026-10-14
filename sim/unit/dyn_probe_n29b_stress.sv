//==============================================================================
// sim/unit/dyn_probe_n29b_stress.sv —— N29B 探针：n12_memstress_lsq（构造压力上界）
//   bench 列 = 夹具的场景号 `bench_cur`（0..N_SC-1）；LSQ 直驱。
//==============================================================================
`timescale 1ns / 1ps
`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"
`include "rtl/front4/front4_params.vh"
`include "rtl/back2/back2_params.vh"

module dyn_probe_n29b_stress;
    n12_memstress_lsq_top u_tb ();
    wire [31:0] dyn_bench = u_tb.bench_cur;
`define DYN_LSU u_tb.u_lsq
`include "sim/unit/dyn_probe_n29b_body.inc"
`undef DYN_LSU
endmodule
