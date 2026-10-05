//==============================================================================
// sim/unit/dyn_probe_r_ipc.sv —— 容量探针：tb_back2_ipc（理想 4 宽 ALU 流）
//------------------------------------------------------------------------------
// 用法（**冻结树**编译；见 fpga/scratch/dyn_r_run.sh）：
//   iverilog -g2012 -I rtl/pkg -I . -o /tmp/dyn_r_ipc.vvp -s dyn_probe_r_ipc \
//            "${RTL[@]}" sim/unit/tb_back2_ipc.sv sim/unit/dyn_probe_r_core.sv \
//            sim/unit/dyn_probe_r_ipc.sv
// 产物：fpga/scratch/dyn_r/ipc.csv（bench 列恒 0；row 0..1 复位、2..201 预热、202..3201 测量窗）
//
// 纪律：只读 TB/RTL 信号（层次引用），不改任何产品 RTL；不打印含 PASS 的文案。
//==============================================================================
`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"
`include "rtl/front4/front4_params.vh"
`include "rtl/back2/back2_params.vh"

module dyn_probe_r_ipc;

    tb_back2_ipc u_tb ();

    wire [31:0] dyn_bench = 32'd0;

`define DYN_BK u_tb.u_back
`define DYN_NO_FE
`define DYN_FNAME "fpga/scratch/dyn_r/ipc.csv"
`include "sim/unit/dyn_probe_r_body.inc"
`undef DYN_FNAME
`undef DYN_NO_FE
`undef DYN_BK

endmodule
