//==============================================================================
// sim/unit/dyn_probe_n12_stress.sv —— EXP-N12-STRESS 探针：memory stress workload
//------------------------------------------------------------------------------
// 用途：把 N12A 的**只读**逐拍采样探针（sim/unit/dyn_probe_n12_core.sv +
//   dyn_probe_n12_body.inc，**未改一字**）挂到新的 LSQ 直驱 memory stress
//   workload（sim/unit/n12_memstress_lsq.sv）上，产出逐拍 CSV 供
//   fpga/scratch/n12_stress_analyze.py 做 fail-closed 判定与直方图/置信区间。
//
// 与 lsq_fwd 探针（dyn_probe_n12_lsqfwd.sv）的差异（有意为之）：
//   · `DYN_BK` 指向**本夹具自己**的 `lsu_ld_block`（= 「有 load 就绪且 iss_ok=0」），
//     因为直驱夹具没有 backend_top。语义 = N12A `ldblk_iss` 口径（探针同时记录
//     `issok`，分析器用 `ldblk & ~issok` 归类）⇒ 该列在本夹具下**有定义**，
//     不再是常量 0（N12A 的 lsq_fwd.csv 恒 0）。
//   · 输出文件按注入宏分流（注入反证不得污染正式 CSV）：
//       默认                     → fpga/scratch/n12_stress/memstress.csv
//       -DN12_INJECT_LDM         → fpga/scratch/n12_stress/inject_ldm.csv
//       -DN12_INJECT_FWH         → fpga/scratch/n12_stress/inject_fwh.csv
//       -DN12_STRESS_CTRL        → fpga/scratch/n12_stress/control.csv（未注入对照）
//   · CSV 列契约与 N12A **逐字相同**（26 列），分析器可复用同一套行内恒等式。
//
// 用法（仓库根 = rv32gc-cpu/；见 fpga/scratch/n12_stress_run.sh）：
//   iverilog -g2012 -I rtl/pkg -I . -o /tmp/n12_st.vvp -s dyn_probe_n12_stress \
//            $(find rtl -name '*.v'|sort) sim/unit/n12_memstress_lsq.sv \
//            sim/unit/dyn_probe_n12_core.sv sim/unit/dyn_probe_n12_stress.sv
//   vvp /tmp/n12_st.vvp
// 纪律：本文件与 body.inc/core.sv 均**不改产品 RTL**；文件名不匹配 `tb_*.sv`
//   ⇒ 不进 regress.sh 的既有回归；探针本身不打印任何含 PASS 字样的文案。
//==============================================================================
`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"
`include "rtl/front4/front4_params.vh"
`include "rtl/back2/back2_params.vh"

module dyn_probe_n12_stress;

    n12_memstress_lsq_top u_tb ();

    wire [31:0] dyn_bench = u_tb.bench_cur;   // 场景编号（每场景一段，便于分桶）

`define DYN_LSU  u_tb.u_lsq
`define DYN_BK   u_tb
`ifdef N12_INJECT_LDM
`define DYN_FNAME "fpga/scratch/n12_stress/inject_ldm.csv"
`elsif N12_INJECT_FWH
`define DYN_FNAME "fpga/scratch/n12_stress/inject_fwh.csv"
`elsif N12_STRESS_CTRL
`define DYN_FNAME "fpga/scratch/n12_stress/control.csv"
`else
`define DYN_FNAME "fpga/scratch/n12_stress/memstress.csv"
`endif
`include "sim/unit/dyn_probe_n12_body.inc"
`undef DYN_FNAME
`undef DYN_BK
`undef DYN_LSU

endmodule
