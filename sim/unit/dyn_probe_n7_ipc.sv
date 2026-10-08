//==============================================================================
// sim/unit/dyn_probe_n7_ipc.sv —— EXP-N7/N10 探针：tb_back2_ipc（后端直驱 4 宽 ALU 流）
//------------------------------------------------------------------------------
// 用法（仓库根 = rv32gc-cpu/；见 fpga/scratch/n7_run.sh）：
//   source scripts/env.sh
//   iverilog "${RV32_IV_FLAGS[@]}" -o /tmp/n7_ipc.vvp -s dyn_probe_n7_ipc \
//            "${RTL[@]}" sim/unit/tb_back2_ipc.sv sim/unit/dyn_probe_n7_core.sv \
//            sim/unit/dyn_probe_n7_ipc.sv
//   vvp /tmp/n7_ipc.vvp
// 产物：fpga/scratch/n7/ipc.csv（bench 列恒 0）
//   · row 0..1     = 复位后的 2 拍
//   · row 2..201   = 预热窗（WARM_CYCLES=200）
//   · row 202..3201= 测量窗（MEAS_CYCLES=3000）
//   分析器按 row>=202 剔除预热窗（与 n4_analyze.py 同口径）。
//   ★ 本基准**不访存**（SQ 恒空）⇒ 只用于 IQ arrivals；SQ 统计由另两个基准承担。
//==============================================================================
`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"
`include "rtl/front4/front4_params.vh"
`include "rtl/back2/back2_params.vh"

module dyn_probe_n7_ipc;

    tb_back2_ipc u_tb ();

    wire [31:0] dyn_bench = 32'd0;

`define DYN_BK u_tb.u_back
`define DYN_FNAME "fpga/scratch/n7/ipc.csv"
`include "sim/unit/dyn_probe_n7_body.inc"
`undef DYN_FNAME
`undef DYN_BK

endmodule
