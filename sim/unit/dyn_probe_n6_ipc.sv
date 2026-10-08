//==============================================================================
// sim/unit/dyn_probe_n6_ipc.sv —— EXP-N6 探针：tb_back2_ipc（后端直驱 ALU 流，无 FP）
//------------------------------------------------------------------------------
// 产物：fpga/scratch/n6/ipc.csv（bench 列恒 0）
//   · row 0..1     = 复位后的 2 拍
//   · row 2..201   = 预热窗（WARM_CYCLES=200）
//   · row 202..    = 测量窗（MEAS_CYCLES=3000）
//   分析器按 row>=202 剔除预热窗（与 dyn_analyze_r.py / n4_analyze.py 同口径）。
//   本基准**不含 FP 指令** ⇒ 期望全部 FP 列为 0（分析器把它当**反证基准**）。
//==============================================================================
`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"
`include "rtl/front4/front4_params.vh"
`include "rtl/back2/back2_params.vh"

module dyn_probe_n6_ipc;

    tb_back2_ipc u_tb ();

    wire [31:0] dyn_bench = 32'd0;

`define DYN_BK u_tb.u_back
`define DYN_FNAME "fpga/scratch/n6/ipc.csv"
`include "sim/unit/dyn_probe_n6_body.inc"
`undef DYN_FNAME
`undef DYN_BK

endmodule
