//==============================================================================
// sim/unit/dyn_probe_n29b_body.inc —— EXP-N29B 探针公共体（只读层次引用）
//------------------------------------------------------------------------------
// 前提（被 include 的模块里已有）：
//   · `<TB> u_tb ();`
//   · `wire [31:0] dyn_bench;`
//   · `define DYN_LSU <lsq_simple 实例层次路径>`
//   · 已 include `rtl/back2/back2_params.vh`
//   ★ 只读；x 净化：`=== 1'b1`（空闲拍上游可能是 x）。
//==============================================================================

    wire n29b_clk  = u_tb.clk;
    wire n29b_rstn = u_tb.rst_n;

    wire n29b_e1v  = (`DYN_LSU.exe_valid === 1'b1);
    wire n29b_e1ld = n29b_e1v & (`DYN_LSU.exe_is_store === 1'b0);
    wire n29b_dep  = n29b_e1ld & (|`DYN_LSU.fwd_hit_w);
    wire n29b_wait = (|`DYN_LSU.ld_wait === 1'b1);

    dyn_probe_n29b_core u_probe_n29b (
        .clk(n29b_clk), .rst_n(n29b_rstn), .bench(dyn_bench),
        .e1ld(n29b_e1ld), .dep(n29b_dep), .any_wait(n29b_wait)
    );
