//==============================================================================
// sim/unit/dyn_probe_n28_stress.sv —— EXP-N28A 探针：N15 定向压力档（只读复用）
//------------------------------------------------------------------------------
// 用途：把 N15-STRESS 的 5 个既有定向负载（mixed/mixdep/fma/store/mdu）重跑一遍，
//       采 ROB 占用（**C5 五档**，见 answer.md §四 N28A 工作集要求）。
//       其中 store 档 = store 密集（32 笔，≲32 是 iverilog STQ 悬崖上界的克制取值）、
//       mdu 档 = 整数长延迟密集、fma/mixed/mixdep = FPU 高密度。
//
// 用法（与 fpga/scratch/n15_stress_run.sh 同一编译手法，另加本探针）：
//   source scripts/env.sh
//   iverilog "${RV32_IV_FLAGS[@]}" -g2012 -DN15S_VARIANT_MDU -DN28_BENCH_ID=105 \
//            -o /tmp/n28_st.vvp -s dyn_probe_n28_stress \
//            "${RTL[@]}" sim/unit/n15s_fpstress_core.sv sim/unit/dyn_probe_n15s_core.sv \
//            sim/unit/dyn_probe_n28_core.sv sim/unit/dyn_probe_n28_stress.sv
//   vvp /tmp/n28_st.vvp      # CWD 必须是仓库根（TB 用相对路径读 hex）
// 产物：fpga/scratch/n28/n28_stress.csv（bench 列 = `N28_BENCH_ID`）
// ⚠ 被复用 TB 自带探针只在 `+N15S_CSV` plusarg 下才写 yield.csv；本档不传该 plusarg
//   ⇒ n15_stress 目录零写入（脚本另做兜底搬运，见 n28_run.sh）。
// 纪律：只读层次引用；不改产品 RTL；不打印含 PASS 文案；不进 regress.sh。
//==============================================================================
`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"
`include "rtl/back2/back2_params.vh"

`ifndef N28_BENCH_ID
  `define N28_BENCH_ID 0
`endif

module dyn_probe_n28_stress;

    n15s_fpstress_core u_tb ();

    //   被复用 TB 的采样窗（probe_en）作为本探针的使能 ⇒ 两套数据窗口逐拍对齐
`define N28_BK    u_tb.u_back
`define N28_FNAME "fpga/scratch/n28/n28_stress.csv"
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
