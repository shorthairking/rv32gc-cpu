//==============================================================================
// sim/unit/dyn_probe_n7_inject.sv —— EXP-N7/N10 **反证注入**探针（只读采集路径注入）
//------------------------------------------------------------------------------
// 用途：证明"采集路径被写坏/写空时，分析器会 fail-closed 抓住"（测试纪律 §3.3 正反证）。
//   本文件**不改任何产品 RTL**：注入点全部在 `dyn_probe_n7_body.inc` 的观测量上，由
//   iverilog 命令行 `-D` 选择：
//     · -DN7_INJECT_STQC  ⇒ 观测到的 stq_cnt_o 恒 +1
//       ⇒ 必违反 `popcount(stq_v) == stq_cnt_o`（分析器行内恒等式）
//     · -DN7_INJECT_IQWV0 ⇒ 观测到的 iq_wv_g 恒 0
//       ⇒ 必违反 `popcount(iq_wv_g) == disp ? popcount(d1_v_q) : 0`
//   两种注入的产物都写到 fpga/scratch/n7/inject/inject.csv；驱动见 `fpga/scratch/n7_run.sh
//   --inject`，判定见 `fpga/scratch/n7_analyze.py --expect-fail`。
//   ★ 若**不**定义任何注入宏，本文件等价于正常探针（用于自检"未注入数据不得 FAIL"）。
//
// 基准：tb_back2_ipc（最小、最快；测量窗 row>=202）。
//==============================================================================
`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"
`include "rtl/front4/front4_params.vh"
`include "rtl/back2/back2_params.vh"

module dyn_probe_n7_inject;

    tb_back2_ipc u_tb ();

    wire [31:0] dyn_bench = 32'd0;

`define DYN_BK u_tb.u_back
`define DYN_FNAME "fpga/scratch/n7/inject/inject.csv"
`include "sim/unit/dyn_probe_n7_body.inc"
`undef DYN_FNAME
`undef DYN_BK

endmodule
