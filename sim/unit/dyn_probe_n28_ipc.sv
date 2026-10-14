//==============================================================================
// sim/unit/dyn_probe_n28_ipc.sv —— EXP-N28A 探针：tb_back2_ipc（理想 4 宽 addi 链）
//------------------------------------------------------------------------------
// 用途：ROB 占用/分配停顿只读逐拍采样。IPC 档是**纯分配压力对照**（4 条/拍前端、
//       2 条/拍提交 ⇒ 稳态占用应 = 流水深度而非容量上限）。
// 用法（cwd = 仓库根）：
//   source scripts/env.sh
//   iverilog "${RV32_IV_FLAGS[@]}" -g2012 -o /tmp/n28_ipc.vvp -s dyn_probe_n28_ipc \
//            "${RTL[@]}" sim/unit/tb_back2_ipc.sv sim/unit/dyn_probe_n28_core.sv \
//            sim/unit/dyn_probe_n28_ipc.sv
//   vvp /tmp/n28_ipc.vvp
// 产物：fpga/scratch/n28/n28_ipc.csv（bench = 0）
// 纪律：只读层次引用；不改产品 RTL；不打印含 PASS 文案；不进 regress.sh。
//==============================================================================
`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"
`include "rtl/front4/front4_params.vh"
`include "rtl/back2/back2_params.vh"

module dyn_probe_n28_ipc;

    tb_back2_ipc u_tb ();

`define N28_BK    u_tb.u_back
`define N28_FNAME "fpga/scratch/n28/n28_ipc.csv"
`define N28_BENCH 32'd0
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
