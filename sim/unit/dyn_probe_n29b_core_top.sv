//==============================================================================
// sim/unit/dyn_probe_n29b_core_top.sv —— N29B 探针：tb_core_top_2b 的 14 个程序
// 用法：iverilog -g2012 -I rtl/pkg -I . -o /tmp/n29b_ct.vvp -s dyn_probe_n29b_core_top \
//          "${RTL[@]}" sim/unit/tb_core_top_2b.sv sim/unit/dyn_probe_n29b_core.sv \
//          sim/unit/dyn_probe_n29b_core_top.sv && vvp /tmp/n29b_ct.vvp
// bench 列 = TB 的 `pid`（逐程序一次复位）。
//==============================================================================
`timescale 1ns / 1ps
`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"
`include "rtl/front4/front4_params.vh"
`include "rtl/back2/back2_params.vh"

module dyn_probe_n29b_core_top;
    tb_core_top_2b u_tb ();
    wire [31:0] dyn_bench = u_tb.pid;
`define DYN_LSU u_tb.u_dut.u_back.u_lsu
`include "sim/unit/dyn_probe_n29b_body.inc"
`undef DYN_LSU
endmodule
