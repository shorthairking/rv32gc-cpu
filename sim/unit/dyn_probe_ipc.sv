//==============================================================================
// sim/unit/dyn_probe_ipc.sv —— 动态行为探针：tb_back2_ipc（后端直驱 4 宽 ALU 流）
//------------------------------------------------------------------------------
// 用法（仓库根 = rv32gc-cpu/）：
//   source scripts/env.sh
//   iverilog -g2012 -I rtl/pkg -I . -o /tmp/dyn_ipc.vvp -s dyn_probe_ipc \
//            "${RTL[@]}" sim/unit/tb_back2_ipc.sv sim/unit/dyn_probe_core.sv \
//            sim/unit/dyn_probe_ipc.sv
//   vvp /tmp/dyn_ipc.vvp
// 产物：fpga/scratch/dyn/ipc.csv（每拍一行；bench 列恒 0）
//   · row 0..1     = 复位后的 2 拍
//   · row 2..201   = 预热窗（WARM_CYCLES=200，不计入 IPC）
//   · row 202..3201= 测量窗（MEAS_CYCLES=3000）
//
// 纪律：只读 TB/RTL 信号（层次引用），不改任何产品 RTL；不打印含 PASS 的文案。
//==============================================================================
`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"
`include "rtl/front4/front4_params.vh"
`include "rtl/back2/back2_params.vh"

module dyn_probe_ipc;

    tb_back2_ipc u_tb ();

    wire [31:0] dyn_bench = 32'd0;

`define DYN_BK u_tb.u_back
`define DYN_FNAME "fpga/scratch/dyn/ipc.csv"
`include "sim/unit/dyn_probe_back2_body.inc"
`undef DYN_FNAME
`undef DYN_BK

endmodule
