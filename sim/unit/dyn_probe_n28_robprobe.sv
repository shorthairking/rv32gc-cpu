//==============================================================================
// sim/unit/dyn_probe_n28_robprobe.sv —— EXP-N28A 探针：n28_robcore 定向 ROB 压力档
//------------------------------------------------------------------------------
// 用途：把 `sim/unit/dyn_probe_n28_robcore.sv`（N15 直驱夹具的拷贝 + 新负载）跑起来，
//       采 ROB 占用/分配停顿逐拍数据。使能 = 被复用夹具的 `probe_en`（同一采样窗）。
// 用法（cwd = 仓库根）：
//   source scripts/env.sh
//   iverilog "${RV32_IV_FLAGS[@]}" -g2012 -DN28_VARIANT_DIV -DN28_BENCH_ID=201 \
//            -o /tmp/n28_div.vvp -s dyn_probe_n28_robprobe \
//            "${RTL[@]}" sim/unit/dyn_probe_n28_robcore.sv sim/unit/dyn_probe_n15s_core.sv \
//            sim/unit/dyn_probe_n28_core.sv sim/unit/dyn_probe_n28_robprobe.sv
//   vvp /tmp/n28_div.vvp
// 产物：fpga/scratch/n28/n28_robstress.csv（bench = `N28_BENCH_ID`）
// 纪律：只读层次引用；不改产品 RTL；不打印含 PASS 文案；不进 regress.sh。
//==============================================================================
`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"
`include "rtl/back2/back2_params.vh"

`ifndef N28_BENCH_ID
  `define N28_BENCH_ID 0
`endif

module dyn_probe_n28_robprobe;

    n28_robcore u_tb ();

`define N28_BK    u_tb.u_back
`define N28_FNAME "fpga/scratch/n28/n28_robstress.csv"
`define N28_BENCH `N28_BENCH_ID
`define N28_CLK   u_tb.clk
`define N28_RST   u_tb.rst_n
`define N28_EN    u_tb.probe_en
`include "sim/unit/dyn_probe_n28_body.inc"
`undef N28_EN
`undef N28_RST
`undef N28_CLK
`undef N28_BENCH
`undef N28_FNAME
`undef N28_BK

endmodule
