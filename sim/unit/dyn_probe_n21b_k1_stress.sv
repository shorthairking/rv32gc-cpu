//==============================================================================
// sim/unit/dyn_probe_n21b_k1_stress.sv —— EXP-N21B-K1 探针：N15 定向压力档（只读复用）
//------------------------------------------------------------------------------
// 用途：K1 实施后，把 N15-STRESS 的 5 个定向负载（mixed/mixdep/fma/store/mdu）重跑一遍，
//       采 **x_i2_v / iwm_req / iwm_gnt / iwm_gnt_raw** 口径的逐拍位向量，用于
//       R3 判据「新让位实测 ≤ N15 边界（mixed/store 档 y5 ≤2.667%、mdu 档 y3 ≤7.39%、
//       最长连续等待不恶化超过 N15 的 7 拍）」的独立重算。
//
// 【为什么另起一个 wrapper 而不是复用 fpga/scratch/n21b_run.sh】
//   · n21b_run.sh 的输出路径固定落在 `fpga/scratch/n21b/n21b_stress_<tag>.csv`，
//     会**覆盖 N21B 轮归档的基线 CSV**（本任务明令禁止覆盖既有产物）；
//   · 本 wrapper 用**新目录** `fpga/scratch/n21b_k1/`，与基线数据并存，便于逐拍对照。
//   · 探针本体（`dyn_probe_n21b_body.inc`）与 N15/N21B 完全同源 ⇒ 位向量定义可交叉核对。
//
// 用法（与 fpga/scratch/n21b_k1_run.sh 一致；cwd 必须是仓库根）：
//   iverilog "${RV32_IV_FLAGS[@]}" -DN21B_BENCH_ID=1 -o /tmp/k1st.vvp \
//     -s dyn_probe_n21b_k1_stress "${RTL[@]}" \
//     sim/unit/n15s_fpstress_core.sv sim/unit/dyn_probe_n15s_core.sv \
//     sim/unit/dyn_probe_n21b_core.sv sim/unit/dyn_probe_n21b_k1_stress.sv
//   vvp /tmp/k1st.vvp
//
// ⚠ 只读：不修改任何产品 RTL、不修改任何既有 TB/探针文件。
//==============================================================================
`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"
`include "rtl/back2/back2_params.vh"

`ifndef N21B_BENCH_ID
  `define N21B_BENCH_ID 0
`endif

module dyn_probe_n21b_k1_stress;

    n15s_fpstress_core u_tb ();

    //   被复用 TB 的采样窗（probe_en）作为本探针的使能 ⇒ 两套数据窗口逐拍对齐
`define N21B_BK    u_tb.u_back
`define N21B_FNAME "fpga/scratch/n21b_k1/n21b_stress.csv"
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
