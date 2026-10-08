//==============================================================================
// sim/unit/dyn_probe_n7_body.inc —— EXP-N7/N10 探针公共体（lockstep / ipc / core_top 复用）
//------------------------------------------------------------------------------
// 前提：被 include 的模块里已有
//   · `tb_back2_lockstep_top u_tb ();` / `tb_back2_ipc u_tb ();` / `tb_core_top_2b u_tb ();`
//   · `wire [31:0] dyn_bench;`
//   · `define DYN_BK <backend_top 层次路径>`
//   · `define DYN_FNAME "<输出 CSV 相对路径>"`
// 本文件只做**只读层次引用**与 `dyn_probe_n7_core` 例化；**不改产品 RTL**。
//
//   ★ 被引用的信号（唯一真源 = rtl/back2/lsq_simple.v 与 rtl/back2/backend_top.v）：
//       u_lsu.stq_v[0:31]   :189    STQ 占用位（分配期置 1、释放清 0）
//       u_lsu.stq_av[0:31]  :190    地址已生成（E1 唯一写点，:1117）
//       u_lsu.stq_a[0:31]   :192    存**虚拟地址**；字地址低位 = stq_a[i][3:2] ⇒ bank
//       u_lsu.stq_cnt_o     :958    = popcount(stq_v)（fail-closed 交叉源）
//       u_lsu.exe_valid/exe_is_store/exe_stq_idx/exe_addr : E1 唯一访存执行口（单发射）
//       u_lsu.alloc_valid/alloc_idx : D3 派发期为 store 分配的 STQ 槽（≤4/拍）
//       iq_wv_g             :1094   = disp_fire_w ? iq_wv : 0（每 IQ 4 写口）
//       iq_cnt[0:5]         :547    各 IQ 的 free_cnt（剩余空位）
//       disp_fire_w, d1_v_q :1011/:492
//     全部是具名端口/线网（reg/wire），层次读只读、无副作用。
//
//   ★ `stq_cnt_o` 与 `popcount(stq_v)` 的一致性、`popcount(iq_wv_g)` 与 `popcount(d1_v_q)`
//     的一致性由 `fpga/scratch/n7_analyze.py` fail-closed 断言（探针侧不做任何归约）。
//==============================================================================

    wire clk   = u_tb.clk;
    wire rst_n = u_tb.rst_n;

    // ---- SQ：占用 / 地址有效 / 逐槽 word-addr[1:0]（bank）----
    wire [31:0] n7_sqv;
    wire [31:0] n7_sqav;
    wire [31:0] n7_sqb0;      // 槽 0..15，每槽 2 bit
    wire [31:0] n7_sqb1;      // 槽 16..31，每槽 2 bit

    genvar n7_gv;
    generate
    for (n7_gv = 0; n7_gv < `BACK2_STQ_N; n7_gv = n7_gv + 1) begin : g_n7_sq
        assign n7_sqv [n7_gv] = `DYN_BK.u_lsu.stq_v [n7_gv];
        assign n7_sqav[n7_gv] = `DYN_BK.u_lsu.stq_av[n7_gv];
        if (n7_gv < 16) begin : g_n7_lo
            assign n7_sqb0[2*n7_gv +: 2] = `DYN_BK.u_lsu.stq_a[n7_gv][3:2];
        end else begin : g_n7_hi
            assign n7_sqb1[2*(n7_gv-16) +: 2] = `DYN_BK.u_lsu.stq_a[n7_gv][3:2];
        end
    end
    endgenerate

    // ---- E1（单发射）：store 写地址 / load 读 bank ----
    //   ★ 有效性门控（**不是统计**，只是"无效拍不把无关总线上的 x 写进 CSV"）：
    //     `exe_stq_idx` 只在 `exe_valid & exe_is_store` 时有意义（空闲拍它是 x，实测 row 0
    //     就是）。门控后：e1idx/e1bk 只在 e1st=1 时承载真值，e1lbk 只在 e1ld=1 时承载真值；
    //     若**有效拍**上仍是 x（即真值缺失），分析器照旧 fail-closed 判 FAIL（门控不会掩盖）。
    wire        n7_e1st  = `DYN_BK.u_lsu.exe_valid &  `DYN_BK.u_lsu.exe_is_store;
    wire        n7_e1ld  = `DYN_BK.u_lsu.exe_valid & ~`DYN_BK.u_lsu.exe_is_store;
    wire [4:0]  n7_e1idx = n7_e1st ? `DYN_BK.u_lsu.exe_stq_idx      : 5'd0;
    wire [1:0]  n7_e1bk  = n7_e1st ? `DYN_BK.u_lsu.exe_addr[3:2]    : 2'd0;
    wire [1:0]  n7_e1lbk = n7_e1ld ? `DYN_BK.u_lsu.exe_addr[3:2]    : 2'd0;

    // ---- D3 派发期 STQ 分配 ----
    wire [3:0]  n7_ast  = `DYN_BK.u_lsu.alloc_valid;
    wire [19:0] n7_aidx = `DYN_BK.u_lsu.alloc_idx;

    // ---- IQ 新派发（arrivals）+ 空位 ----
    wire [23:0] n7_iqwv  = `DYN_BK.iq_wv_g;
    wire [29:0] n7_iqcnt = { `DYN_BK.iq_cnt[5], `DYN_BK.iq_cnt[4], `DYN_BK.iq_cnt[3],
                             `DYN_BK.iq_cnt[2], `DYN_BK.iq_cnt[1], `DYN_BK.iq_cnt[0] };

    //==========================================================================
    // 反证注入点（**只在显式 -D 时生效**；默认两条 `_obs` = 真信号，产品 RTL 不受影响）
    //--------------------------------------------------------------------------
    //   目的：证明"采集路径写坏/写空时，分析器会 fail-closed 抓住"，而不是默默产结论。
    //     · -DN7_INJECT_STQC  ：把产品自带计数 stq_cnt_o 加 1 ⇒ 必违反
    //                           `popcount(stq_v) == stq_cnt_o` 行内恒等式。
    //     · -DN7_INJECT_IQWV0 ：把 IQ 写使能向量恒置 0 ⇒ 必违反
    //                           `popcount(iq_wv_g) == disp ? popcount(d1_v_q) : 0`。
    //   两者都**不改任何产品 RTL**（只改本探针的观测量），由 n7_run.sh --inject 驱动。
    //==========================================================================
`ifdef N7_INJECT_STQC
    wire [5:0]  n7_stqc_obs = `DYN_BK.u_lsu.stq_cnt_o + 6'd1;   // 注入：错误占用计数
`else
    wire [5:0]  n7_stqc_obs = `DYN_BK.u_lsu.stq_cnt_o;
`endif

`ifdef N7_INJECT_IQWV0
    wire [23:0] n7_iqwv_obs = 24'd0;                           // 注入：IQ 写使能恒 0
`else
    wire [23:0] n7_iqwv_obs = n7_iqwv;
`endif

    dyn_probe_n7_core #(.FNAME(`DYN_FNAME)) u_probe_n7 (
        .clk(clk), .rst_n(rst_n), .bench(dyn_bench),
        .sqv(n7_sqv), .sqav(n7_sqav), .sqb0(n7_sqb0), .sqb1(n7_sqb1),
        .stqc(n7_stqc_obs),
        .e1st(n7_e1st), .e1idx(n7_e1idx), .e1bk(n7_e1bk),
        .e1ld(n7_e1ld), .e1lbk(n7_e1lbk),
        .ast(n7_ast), .aidx(n7_aidx),
        .iqwv(n7_iqwv_obs), .iqcnt(n7_iqcnt),
        .disp(`DYN_BK.disp_fire_w), .d1v(`DYN_BK.d1_v_q)
    );
