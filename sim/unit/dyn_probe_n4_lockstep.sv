//==============================================================================
// sim/unit/dyn_probe_n4_lockstep.sv —— EXP-N4 探针：tb_back2_lockstep 的 5 个程序
//------------------------------------------------------------------------------
// 用法（仓库根 = rv32gc-cpu/）：
//   source scripts/env.sh
//   iverilog -g2012 -I rtl/pkg -I . -o /tmp/n4_ls.vvp -s dyn_probe_n4_lockstep \
//            "${RTL[@]}" sim/unit/tb_back2_lockstep.sv sim/unit/dyn_probe_n4_core.sv \
//            sim/unit/dyn_probe_n4_lockstep.sv
//   vvp /tmp/n4_ls.vvp
// 产物：fpga/scratch/n4/lockstep.csv（每拍一行；bench 列 = TB 的程序号 pi）
//
// 纪律：只读 TB/RTL 信号（层次引用），不改任何产品 RTL；不打印含 PASS 的文案。
//       文件名不匹配 tb_*.sv ⇒ 不进 regress.sh 的既有回归。
//==============================================================================
`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"
`include "rtl/front4/front4_params.vh"
`include "rtl/back2/back2_params.vh"

module dyn_probe_n4_lockstep;

    tb_back2_lockstep_top u_tb ();

    wire [31:0] dyn_bench = u_tb.pi;   // 程序号（每程序一次复位 ⇒ 逐程序切分）

`define DYN_BK u_tb.u_back
`define DYN_FNAME "fpga/scratch/n4/lockstep.csv"
`include "sim/unit/dyn_probe_n4_body.inc"
`undef DYN_FNAME
`undef DYN_BK

endmodule
