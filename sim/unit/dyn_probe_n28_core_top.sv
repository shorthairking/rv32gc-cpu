//==============================================================================
// sim/unit/dyn_probe_n28_core_top.sv —— EXP-N28A 探针：tb_core_top_2b 的 14 个程序
//------------------------------------------------------------------------------
// 用途：ROB 占用/分配停顿只读逐拍采样（core_top 14 程序：含 p2_branch 分支密集、
//       p7_trap/p8_int/p9_trapvec 异常与陷阱恢复、p14_storepf 访存压力）。
// 用法（cwd = 仓库根）：
//   source scripts/env.sh
//   iverilog "${RV32_IV_FLAGS[@]}" -g2012 -o /tmp/n28_ct.vvp -s dyn_probe_n28_core_top \
//            "${RTL[@]}" sim/unit/tb_core_top_2b.sv sim/unit/dyn_probe_n28_core.sv \
//            sim/unit/dyn_probe_n28_core_top.sv
//   vvp /tmp/n28_ct.vvp
// 产物：fpga/scratch/n28/n28_core_top.csv（bench 列 = pid）
// 纪律：只读层次引用；不改产品 RTL；不打印含 PASS 文案；不进 regress.sh。
//==============================================================================
`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"
`include "rtl/front4/front4_params.vh"
`include "rtl/back2/back2_params.vh"

module dyn_probe_n28_core_top;

    tb_core_top_2b u_tb ();

`define N28_BK    u_tb.u_dut.u_back
`define N28_FNAME "fpga/scratch/n28/n28_core_top.csv"
`define N28_BENCH u_tb.pid
`define N28_CLK   u_tb.clk
`define N28_RST   u_tb.rst_n
`define N28_EN    1'b1
`include "sim/unit/dyn_probe_n28_body.inc"
`undef N28_EN
`undef N28_RST
`undef N28_CLK
`undef N28_BENCH
`undef N28_FNAME
`undef N28_BK

endmodule
