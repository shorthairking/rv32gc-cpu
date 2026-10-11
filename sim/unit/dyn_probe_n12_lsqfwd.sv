//==============================================================================
// sim/unit/dyn_probe_n12_lsqfwd.sv —— EXP-N12A 探针：tb_back2_lsq_fwd（**定向转发微基准**）
//------------------------------------------------------------------------------
// 用法（仓库根 = rv32gc-cpu/；见 fpga/scratch/n12_run.sh）：
//   source scripts/env.sh
//   iverilog "${RV32_IV_FLAGS[@]}" -o /tmp/n12_lf.vvp -s dyn_probe_n12_lsqfwd \
//            "${RTL[@]}" sim/unit/tb_back2_lsq_fwd.sv sim/unit/dyn_probe_n12_core.sv \
//            sim/unit/dyn_probe_n12_lsqfwd.sv
//   vvp /tmp/n12_lf.vvp
// 产物：fpga/scratch/n12/lsq_fwd.csv（bench 列恒 0；周期数很少，属**定向**样本）
//
// 为什么加它：C1/C2 正是 N12A 物品 2/3 的**稀缺场景**（部分掩码 / 两条 store 拼接覆盖），
//   端到端程序里很难高频出现 ⇒ 用定向夹具把这两类的“真值”钉住。
//   ★ 本夹具是 LSQ **直驱**（不经 backend_top）⇒ 定义 `DYN_NO_BK`，`ldblk` 恒 0
//     （队头阻塞统计由 lockstep / core_top 承担）。
//==============================================================================
`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"
`include "rtl/front4/front4_params.vh"
`include "rtl/back2/back2_params.vh"

module dyn_probe_n12_lsqfwd;

    tb_back2_lsq_fwd_top u_tb ();

    wire [31:0] dyn_bench = 32'd0;

`define DYN_LSU  u_tb.u_lsq
`define DYN_NO_BK
`define DYN_FNAME "fpga/scratch/n12/lsq_fwd.csv"
`include "sim/unit/dyn_probe_n12_body.inc"
`undef DYN_FNAME
`undef DYN_NO_BK
`undef DYN_LSU

endmodule
