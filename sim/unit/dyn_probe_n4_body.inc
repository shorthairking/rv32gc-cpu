//==============================================================================
// sim/unit/dyn_probe_n4_body.inc —— EXP-N4 探针公共体（供 lockstep / ipc / core_top 复用）
//------------------------------------------------------------------------------
// 前提：被 include 的模块里已有
//   · `tb_back2_lockstep_top u_tb ();` / `tb_back2_ipc u_tb ();` /
//     `tb_core_top_2b u_tb ();`（三者都有可达的 backend_top 实例）
//   · `wire [31:0] dyn_bench;`（基准编号）
//   · `define DYN_BK <backend_top 层次路径>`
//   · `define DYN_FNAME "<输出 CSV 相对路径>"`
// 本文件只做**只读层次引用**与 `dyn_probe_n4_core` 例化；不改产品 RTL。
//
//   ★ 被引用的信号（唯一真源 = rtl/back2/backend_top.v）：
//       wbi_v    :1727（6 个整数写回有效）
//       wbi_keep :1738（写回项仍在 ROB 窗口内）
//       iprf_we  :2132（= wbi_v & wbi_keep；整数 PRF 写使能）
//       fprf_we  :2150（浮点 PRF 写使能，2 bit）
//     全部是 backend_top 内的具名 wire（连续赋值），层次读只读、无副作用。
//
//   ★ `wx`（未定 keep 的**有效**写回位）在**探针内**逐位用 case-equality 判别：
//       `wbi_keep` 的未定位只允许出现在 `wbi_v==0` 的无关位上（此时 0 & x = 0，
//       iprf_we 仍确定）；任何一个**有效**写回的 keep 未定都必须被本列抓出来，
//       由分析器 fail-closed 断言 `wx == 0`。
//     纯组合、无寄存器 ⇒ 不改变任何产品逻辑（本文件只做只读引用）。
//==============================================================================

    wire clk   = u_tb.clk;
    wire rst_n = u_tb.rst_n;

    wire [5:0] n4_wv = `DYN_BK.wbi_v;
    wire [5:0] n4_wk = `DYN_BK.wbi_keep;
    //   逐位"已定义"（0 或 1 皆为已定义；x/z 为未定义）
    wire [5:0] n4_wk_def = {
        (n4_wk[5] === 1'b0) || (n4_wk[5] === 1'b1),
        (n4_wk[4] === 1'b0) || (n4_wk[4] === 1'b1),
        (n4_wk[3] === 1'b0) || (n4_wk[3] === 1'b1),
        (n4_wk[2] === 1'b0) || (n4_wk[2] === 1'b1),
        (n4_wk[1] === 1'b0) || (n4_wk[1] === 1'b1),
        (n4_wk[0] === 1'b0) || (n4_wk[0] === 1'b1) };
    wire [5:0] n4_wx = n4_wv & ~n4_wk_def;   // 有效写回却带未定 keep ⇒ 必须恒 0

    dyn_probe_n4_core #(.FNAME(`DYN_FNAME)) u_probe_n4 (
        .clk(clk), .rst_n(rst_n), .bench(dyn_bench),
        .wv(n4_wv),
        .we(`DYN_BK.iprf_we),
        .wx(n4_wx),
        .fwe(`DYN_BK.fprf_we)
    );
