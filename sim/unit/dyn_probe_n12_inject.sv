//==============================================================================
// sim/unit/dyn_probe_n12_inject.sv —— EXP-N12A **反证注入**探针（只读采集路径注入）
//------------------------------------------------------------------------------
// 用途：证明“采集路径被写坏时，分析器会 fail-closed 抓住”（测试纪律 §3.3 正反证）。
//   本文件**不改任何产品 RTL**：注入点全部在 `dyn_probe_n12_body.inc` 的观测量上，
//   由 iverilog 命令行 `-D` 选择：
//     · -DN12_INJECT_LDM ⇒ 观测到的 `lmask_w8` 异或 1
//       ⇒ 必违反 `ldm == mask(sz, a2)`（行内恒等式）
//     · -DN12_INJECT_FWH ⇒ 观测到的 `fwd_hit_w` 异或 1
//       ⇒ 必违反 `fwh[I] == |(c_I) & ldm[I]`（行内恒等式）
//   基准 = tb_back2_lsq_fwd（**最快且确有 load-E1** 的夹具）；未定义任何注入宏时
//   本文件等价于正常探针（用于自检“未注入数据不得 FAIL”）。
//   驱动见 `fpga/scratch/n12_run.sh --inject`，判定见 `n12_analyze.py --expect-fail`。
//==============================================================================
`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"
`include "rtl/front4/front4_params.vh"
`include "rtl/back2/back2_params.vh"

module dyn_probe_n12_inject;

    tb_back2_lsq_fwd_top u_tb ();

    wire [31:0] dyn_bench = 32'd0;

`define DYN_LSU  u_tb.u_lsq
`define DYN_NO_BK
`define DYN_FNAME "fpga/scratch/n12/inject/inject.csv"
`include "sim/unit/dyn_probe_n12_body.inc"
`undef DYN_FNAME
`undef DYN_NO_BK
`undef DYN_LSU

endmodule
