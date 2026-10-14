//==============================================================================
// sim/unit/dyn_probe_n21b_stress.sv —— EXP-N21B 探针：N15 定向压力档（只读复用）
//------------------------------------------------------------------------------
// 用途：把 N15-STRESS 的 6 个定向负载（mixed/mixdep/fma/store/mdu/inj）重跑一遍，
//       采 **x_i2_v 口径** 的读数口需求（N15 报告用的是 iq_iss_v 口径），用于
//       "新合并对的让位实测 ≤ N15 边界（y5 档、最长连续等待）"的判定。
//
// 用法（与 fpga/scratch/n15_stress_run.sh 同一编译手法，另加本探针）：
//   iverilog "${RV32_IV_FLAGS[@]}" -g2012 -DN15S_VARIANT_MDU -DN21B_BENCH_ID=5 \
//            -o /tmp/n21b_st.vvp -s dyn_probe_n21b_stress \
//            "${RTL[@]}" sim/unit/n15s_fpstress_core.sv sim/unit/dyn_probe_n15s_core.sv \
//            sim/unit/dyn_probe_n21b_core.sv sim/unit/dyn_probe_n21b_stress.sv
//   vvp /tmp/n21b_st.vvp          # CWD 必须是仓库根（TB 用相对路径读 hex / 写 yield.csv）
// 产物：fpga/scratch/n21b/n21b_stress_<tag>.csv（bench 列 = `N21B_BENCH_ID`）
//
// ⚠ 副作用登记：被复用的 n15s TB 自带探针会把逐拍数据写到
//   `fpga/scratch/n15_stress/yield.csv`（固定路径）。本探针**不改** N15 任何文件；
//   运行脚本在每档结束后立即把该文件移出到 `fpga/scratch/n21b/`（不覆盖既有
//   `yield_<tag>.csv` 归档）。
//==============================================================================
`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"
`include "rtl/back2/back2_params.vh"

`ifndef N21B_BENCH_ID
  `define N21B_BENCH_ID 0
`endif
`ifndef N21B_TAG
  `define N21B_TAG "stress"
`endif

module dyn_probe_n21b_stress;

    n15s_fpstress_core u_tb ();

    //   被复用 TB 的采样窗（probe_en）作为本探针的使能 ⇒ 两套数据窗口逐拍对齐
`define N21B_BK    u_tb.u_back
`define N21B_FNAME "fpga/scratch/n21b/n21b_stress.csv"
`define N21B_BENCH `N21B_BENCH_ID
`define N21B_CLK   u_tb.clk
`define N21B_RST   u_tb.rst_n
`define N21B_EN    u_tb.probe_en
`include "sim/unit/dyn_probe_n21b_body.inc"
`undef N21B_EN
`undef N21B_RST
`undef N21B_CLK
`undef N21B_BENCH
`undef N21B_FNAME
`undef N21B_BK

endmodule
