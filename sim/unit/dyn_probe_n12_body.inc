//==============================================================================
// sim/unit/dyn_probe_n12_body.inc —— EXP-N12A 探针公共体（lockstep / core_top / lsq_fwd 复用）
//------------------------------------------------------------------------------
// 前提：被 include 的模块里已有
//   · `tb_back2_lockstep_top u_tb ();` / `tb_core_top_2b u_tb ();` / `tb_back2_lsq_fwd_top u_tb ();`
//   · `wire [31:0] dyn_bench;`
//   · `define DYN_LSU <lsq_simple 实例层次路径>`
//   · `define DYN_FNAME "<输出 CSV 相对路径>"`
//   · （可选）`define DYN_BK <backend_top 实例路径>`；若定义 `DYN_NO_BK`
//     则不引用 backend_top（直驱 LSQ 的夹具没有该层），`ldblk` 恒 0。
//   ★ 必须先把 `include "rtl/back2/back2_params.vh"` 引入（STQ 深度等）。
//   本文件只做**只读层次引用**与 `dyn_probe_n12_core` 例化；**不改产品 RTL**。
//
//   ★ 被引用的信号（唯一真源 = rtl/back2/lsq_simple.v）：
//       exe_valid / exe_is_store / exe_addr / exe_size   E1 唯一访存执行口（单发射）
//       fw_live_e[0:31]   :432   更老 且 地址已确认（转发树有效性门）
//       stq_v[0:31] :189 / stq_av[0:31] :190 / stq_age[0:31] :256
//       unk_v[0:31] :380        = v & ~av & (age < age_iss)（发射闸门口径）
//       age_rob :272            E1 项年龄（转发窗口基准）
//       fw_eqm_e/fw_eq0_e/fw_eqp_e/fw_eqp2_e :443  逐 store 字数等值（w0-1/w0/w0+1/w0+2）
//       stq_msk[0:31][3:0] :200 / stq_hi[0:31] :199 / stq_mh[0:31][3:0] :204
//                                  store 低字掩码 / 拆两笔标志 / 高字掩码（D1-fix 新增）
//       lmask_w8 :425 / fwd_hit_w :499 / fwd_all_w :592
//       iss_ok :863             = ~any_unk_w（load 发射闸门）
//       （backend_top）lsu_ld_block :1228 —— 队头是 load 且被 iss_ok/csr 挡住
//     全部是具名端口/线网（reg/wire），层次读只读、无副作用。
//
//   ★ **x 净化口径**（与 RTL 自身对不可靠输入的 `=== 1'b1` 净化同一纪律，
//     见 lsq_simple §0b）：
//       · `e1ld/e1st/ldblk/issok/unkv` 是**逐拍常开**的观测量，空闲拍上其上游
//         （`exe_valid`/`iss_rob`/`iq_sel_nq`）可能是 x ⇒ 逐位 `=== 1'b1` 净化成数字。
//       · `live/unke/ldm/sz/a2/a3/fwh/fwa/c0..c7` **只在 `e1ld=1` 拍承载真值**
//         （ternary 门控）：有效拍上若仍是 x，CSV 里就会出现 x ⇒ 分析器 fail-closed
//         的“只含数字与逗号”校验必然抓住。**门控不掩盖真值缺失**。
//
//   ★ **反证注入点**（只在显式 `-D` 时生效；默认两条 `_obs` = 真信号，产品不受影响）：
//       · `-DN12_INJECT_LDM` : 观测量 `ldm` 异或 1 ⇒ 必违反
//                              `ldm == mask(sz, a2)`（无论 sz/a2 为何，bit0 必翻转）
//       · `-DN12_INJECT_FWH` : 观测量 `fwh` 异或 1 ⇒ 必违反
//                              `fwh[I] == |(c_I) & ldm[I]`（行内恒等式）
//     两者都**不改任何产品 RTL**（只改本探针的观测量），由 n12_run.sh --inject 驱动。
//==============================================================================

    wire clk   = u_tb.clk;
    wire rst_n = u_tb.rst_n;

    genvar n12_gv, n12_gb, n12_gj;

    // ---- E1 有效性（数字门控；见头注“x 净化口径”）----
    wire n12_e1v  = (`DYN_LSU.exe_valid === 1'b1);
    wire n12_e1st = n12_e1v & (`DYN_LSU.exe_is_store === 1'b1);
    wire n12_e1ld = n12_e1v & (`DYN_LSU.exe_is_store === 1'b0);

    // ---- STQ 占用 / 地址有效 / 更老未定址 ----
    //   unkv = 产品 `unk_v`（以 `age_iss` = I1 候选为基准；发射闸门口径），逐位净化；
    //   unke = 以**正在 E1 的这条 load**（`age_rob`）为基准的同一集合
    //          （原始量，只在 e1ld 拍有意义 ⇒ 门控）。
    wire [31:0] n12_sqv, n12_sqav, n12_unkv, n12_unke_raw;
    generate
    for (n12_gv = 0; n12_gv < 32; n12_gv = n12_gv + 1) begin : g_n12_st
        if (n12_gv < `BACK2_STQ_N) begin : g_on
            assign n12_sqv [n12_gv] = (`DYN_LSU.stq_v [n12_gv] === 1'b1);
            assign n12_sqav[n12_gv] = (`DYN_LSU.stq_av[n12_gv] === 1'b1);
            assign n12_unkv[n12_gv] = (`DYN_LSU.unk_v[n12_gv] === 1'b1);
            assign n12_unke_raw[n12_gv] = `DYN_LSU.stq_v[n12_gv] & ~`DYN_LSU.stq_av[n12_gv] &
                                          (`DYN_LSU.stq_age[n12_gv*8 +: 8] < `DYN_LSU.age_rob);
        end else begin : g_off
            assign n12_sqv [n12_gv] = 1'b0;
            assign n12_sqav[n12_gv] = 1'b0;
            assign n12_unkv[n12_gv] = 1'b0;
            assign n12_unke_raw[n12_gv] = 1'b0;
        end
    end
    endgenerate
    wire [31:0] n12_unke = n12_e1ld ? n12_unke_raw : 32'd0;

    // ---- 物品 1/2/3 的原始位向量（只在 e1ld 拍有意义 ⇒ 门控）----
    wire [31:0] n12_live = n12_e1ld ? `DYN_LSU.fw_live_e : 32'd0;
    wire [7:0]  n12_ldm  = n12_e1ld ? `DYN_LSU.lmask_w8   : 8'd0;
    wire [2:0]  n12_sz   = n12_e1ld ? `DYN_LSU.exe_size   : 3'd0;
    wire [1:0]  n12_a2   = n12_e1ld ? `DYN_LSU.exe_addr[1:0] : 2'd0;
    wire        n12_a3   = n12_e1ld ? `DYN_LSU.exe_addr[2]   : 1'b0;
    //   `fp` 只为把 size 拆成 LB/LH/LW/LD（整数）与 FLW/FLD（浮点）——`exe_size` 不区分两者。
    wire        n12_fp   = n12_e1ld ? (`DYN_LSU.exe_is_fp === 1'b1) : 1'b0;
    wire [7:0]  n12_fwh  = n12_e1ld ? `DYN_LSU.fwd_hit_w  : 8'd0;
    wire        n12_fwa  = n12_e1ld ? `DYN_LSU.fwd_all_w  : 1'b0;

    // ---- 逐窗口字节 I 的 store 覆盖向量 c_I（与产品叶子 `mt_w` 逐位同构，去掉 `in_w`）----
    //   c_I[gj] = fw_live_e[gj] & (lo_w | hi_w)
    //     其中 gcar = I[3:2]、lane = I[1:0]，
    //     lo_eq = (gcar==0)?eq0:(gcar==1)?eqp:eqp2   （store 低字对齐本字节所在字）
    //     hi_eq = (gcar==0)?eqm:(gcar==1)?eq0:eqp    （8 B store 的高字 = 低字地址+4）
    //     lo_w  = lo_eq & stq_msk[gj][lane]；hi_w = stq_hi[gj] & hi_eq & stq_mh[gj][lane]
    //     （★ D1-fix 同步：高字覆盖按该项**自己的高字掩码** `stq_mh` 判 —— 8 B store
    //       `stq_mh=4'hF` ⇒ 与旧“恒覆盖 4 道”逐位等价；≤4 B 跨字 store 只覆盖越界道。）
    //   打包成 8×32 bit（与 n7 探针的打包口径一致，避免非可综合的 unpacked wire 数组）。
    wire [8*32-1:0] n12_cov;
    generate
    for (n12_gb = 0; n12_gb < 8; n12_gb = n12_gb + 1) begin : g_n12_cov
        wire [1:0] lane_w = n12_gb[1:0];
        wire [1:0] gcar_w = n12_gb[3:2];
        for (n12_gj = 0; n12_gj < 32; n12_gj = n12_gj + 1) begin : g_n12_j
            if (n12_gj < `BACK2_STQ_N) begin : g_on
                wire lo_eq_w = (gcar_w == 2'd0) ? `DYN_LSU.fw_eq0_e [n12_gj] :
                               (gcar_w == 2'd1) ? `DYN_LSU.fw_eqp_e [n12_gj] :
                                                  `DYN_LSU.fw_eqp2_e[n12_gj];
                wire hi_eq_w = (gcar_w == 2'd0) ? `DYN_LSU.fw_eqm_e [n12_gj] :
                               (gcar_w == 2'd1) ? `DYN_LSU.fw_eq0_e [n12_gj] :
                                                  `DYN_LSU.fw_eqp_e [n12_gj];
                wire lo_w = lo_eq_w & `DYN_LSU.stq_msk[n12_gj][lane_w];
                wire hi_w = `DYN_LSU.stq_hi[n12_gj] & hi_eq_w & `DYN_LSU.stq_mh[n12_gj][lane_w];
                assign n12_cov[(n12_gb*32) + n12_gj] = `DYN_LSU.fw_live_e[n12_gj] & (lo_w | hi_w);
            end else begin : g_off
                assign n12_cov[(n12_gb*32) + n12_gj] = 1'b0;
            end
        end
    end
    endgenerate
    wire [31:0] n12_c0 = n12_e1ld ? n12_cov[0*32 +: 32] : 32'd0;
    wire [31:0] n12_c1 = n12_e1ld ? n12_cov[1*32 +: 32] : 32'd0;
    wire [31:0] n12_c2 = n12_e1ld ? n12_cov[2*32 +: 32] : 32'd0;
    wire [31:0] n12_c3 = n12_e1ld ? n12_cov[3*32 +: 32] : 32'd0;
    wire [31:0] n12_c4 = n12_e1ld ? n12_cov[4*32 +: 32] : 32'd0;
    wire [31:0] n12_c5 = n12_e1ld ? n12_cov[5*32 +: 32] : 32'd0;
    wire [31:0] n12_c6 = n12_e1ld ? n12_cov[6*32 +: 32] : 32'd0;
    wire [31:0] n12_c7 = n12_e1ld ? n12_cov[7*32 +: 32] : 32'd0;

    // ---- 队头 load 被闸门挡住（性能代价；直驱夹具恒 0）----
`ifdef DYN_NO_BK
    wire n12_ldblk = 1'b0;
`else
    wire n12_ldblk = (`DYN_BK.lsu_ld_block === 1'b1);
`endif
    wire n12_issok = (`DYN_LSU.iss_ok === 1'b1);

    // ---- 反证注入（只改观测量）----
`ifdef N12_INJECT_LDM
    wire [7:0] n12_ldm_obs = n12_e1ld ? (n12_ldm ^ 8'h01) : 8'd0;
`else
    wire [7:0] n12_ldm_obs = n12_ldm;
`endif
`ifdef N12_INJECT_FWH
    wire [7:0] n12_fwh_obs = n12_e1ld ? (n12_fwh ^ 8'h01) : 8'd0;
`else
    wire [7:0] n12_fwh_obs = n12_fwh;
`endif

    dyn_probe_n12_core #(.FNAME(`DYN_FNAME)) u_probe_n12 (
        .clk(clk), .rst_n(rst_n), .bench(dyn_bench),
        .e1ld(n12_e1ld), .e1st(n12_e1st), .ldblk(n12_ldblk), .issok(n12_issok),
        .sqv(n12_sqv), .sqav(n12_sqav), .unkv(n12_unkv), .unke(n12_unke), .live(n12_live),
        .ldm(n12_ldm_obs), .sz(n12_sz), .a2(n12_a2), .a3(n12_a3), .fp(n12_fp),
        .fwh(n12_fwh_obs), .fwa(n12_fwa),
        .c0(n12_c0), .c1(n12_c1), .c2(n12_c2), .c3(n12_c3),
        .c4(n12_c4), .c5(n12_c5), .c6(n12_c6), .c7(n12_c7)
    );
