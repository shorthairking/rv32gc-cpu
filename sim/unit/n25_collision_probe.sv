//==============================================================================
// sim/unit/n25_collision_probe.sv —— N25：BRAM 同址同拍读写（collision）实测探针
//------------------------------------------------------------------------------
// 目的（answer.md §五 N25 第 2/4 步）：
//   在**不改任何产品 RTL** 的前提下，对 2B 乱序核（tb_back2_lockstep_top 的 5 个锁步程序）
//   逐拍统计"同址同拍 读使能 ∧ 写使能"（下称 collision）的出现次数，并顺带统计
//   "read_first 语义 vs NO_CHANGE 语义"是否会给出**不同的读回值 / 不同的命中判决**。
//
// 被观测的存储实例（全部来自 fpga/out/synth.vivado.log 的 Block RAM Final Mapping Report）：
//   A. u_back.u_rob.u_wmem / g_bank[0..3].u_sdp   ROB 宽载荷 4 bank SDP，声明 read_first
//   B. u_back.u_iwmem      / g_bank[0..3].u_sdp   发射宽载荷 4 bank SDP，声明 read_first
//   C. u_front.u_bpu.u_btb.u_way0/u_way1          BTB 每路 SDP，**未传 WRITE_MODE_B**（默认
//                                                 no_change ⇒ 综合成 NO_CHANGE）
//   D. u_bpu.{u_gshare.u_gpht,u_local.u_lpht,u_selector.u_seltab}.u_mem0/u_mem1
//                                                 2 读 1 写 TDP 表，声明 read_first
//
// collision 判据（按端口语义，非按"数据是否出错"）：
//   · SDP（A/B）  ：bank 内 `we && re && woff==roff`
//   · SDP（C）    ：`a_en && b_en && a_addr==b_addr`（BTB 无 bank）
//   · TDP（D）    ：写口 A 与读口 B 同址 `a_en&a_we && b_en && a_addr==b_addr`
//
// 语义分叉判据（对每个 collision 拍 t）：
//   · 读回值：read_first 给 dout_rf = 行为模型在 t+1 沿**之前**输出的值（= 该拍发起读的结果，
//             因为模型 `if (en) dout <= mem[addr]`）；NO_CHANGE 硬件给 dout_held = t 沿**之前**
//             的输出（输出寄存器保持）。⇒ diff = (dout_rf !== dout_held)。
//             （re/en=0 时两边都保持 ⇒ 判据自动不计数，与模型 `if (re)` 口径一致。）
//   · BTB 另有"命中判决"分叉：命中 = 读回条目的 tag/valid 与打拍 tag 比较（bpu_btb.v:151-162），
//     故 hit_rf / hit_nc 分别用 dout_rf / dout_held 计算，统计不一致拍数。
//
// 时序：判据在**碰撞拍的下一沿**求值（那时 read_first 结果已出现在模型输出上）。
//
// 背压分类（answer.md §五 第 4 步）：collision 拍上记录 ROB/IQ/STQ 占用，回答
//   "IQ 满 / LSQ 满 / ROB 窗满时是否出现 collision"。
//
// 纪律：只读层次引用；文件名不以 tb_ 开头 ⇒ 不进 scripts/regress.sh；不打印任何含 PASS 的
//       兜底文案（判定由 fpga/scratch/n25_probe_check.py 做，fail-closed）。
//
// 用法（见 fpga/scratch/n25_run.sh）：
//   source scripts/env.sh; mapfile -t RTL < <(rv32_rtl_sources)
//   iverilog -g2012 -I rtl/pkg -I . -o /tmp/n25_ls.vvp -s n25_collision_probe \
//            "${RTL[@]}" sim/unit/tb_back2_lockstep.sv sim/unit/n25_collision_probe.sv
//   vvp /tmp/n25_ls.vvp
//==============================================================================
`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"
`include "rtl/front4/front4_params.vh"
`include "rtl/back2/back2_params.vh"

module n25_collision_probe;

    localparam integer NP = 5;      // tb_back2_lockstep 的程序数（P_NUM_L = 5）
    localparam integer NW = 4;      // 4 bank

    tb_back2_lockstep_top u_tb ();

    wire        clk   = u_tb.clk;
    wire        rst_n = u_tb.rst_n;
    wire [31:0] pi    = u_tb.pi;    // 当前程序号（TB 模块级整数）

    //==========================================================================
    // 0. 被观测量别名（层次引用，只读）
    //==========================================================================
    // ---- A：ROB 宽载荷 4 bank SDP ----
    wire [NW-1:0]      rw_we   = u_tb.u_back.u_rob.u_wmem.we;
    wire [NW*5-1:0]    rw_woff = u_tb.u_back.u_rob.u_wmem.woff;
    wire [NW-1:0]      rw_re   = u_tb.u_back.u_rob.u_wmem.re;
    wire [NW*5-1:0]    rw_roff = u_tb.u_back.u_rob.u_wmem.roff;
    wire [NW*225-1:0]  rw_rd   = u_tb.u_back.u_rob.u_wmem.rdata;

    // ---- B：发射宽载荷 4 bank SDP ----
    wire [NW-1:0]      iw_we   = u_tb.u_back.u_iwmem.we;
    wire [NW*4-1:0]    iw_woff = u_tb.u_back.u_iwmem.woff;
    wire [NW-1:0]      iw_re   = u_tb.u_back.u_iwmem.re;
    wire [NW*4-1:0]    iw_roff = u_tb.u_back.u_iwmem.roff;
    wire [NW*212-1:0]  iw_rd   = u_tb.u_back.u_iwmem.rdata;

    // ---- C：BTB 两路 SDP ----
    wire        b0_aen = u_tb.u_front.u_bpu.u_btb.u_way0.a_en;
    wire [9:0]  b0_aad = u_tb.u_front.u_bpu.u_btb.u_way0.a_addr;
    wire        b0_ben = u_tb.u_front.u_bpu.u_btb.u_way0.b_en;
    wire [9:0]  b0_bad = u_tb.u_front.u_bpu.u_btb.u_way0.b_addr;
    wire [65:0] b0_do  = u_tb.u_front.u_bpu.u_btb.u_way0.b_dout;
    wire        b1_aen = u_tb.u_front.u_bpu.u_btb.u_way1.a_en;
    wire [9:0]  b1_aad = u_tb.u_front.u_bpu.u_btb.u_way1.a_addr;
    wire        b1_ben = u_tb.u_front.u_bpu.u_btb.u_way1.b_en;
    wire [9:0]  b1_bad = u_tb.u_front.u_bpu.u_btb.u_way1.b_addr;
    wire [65:0] b1_do  = u_tb.u_front.u_bpu.u_btb.u_way1.b_dout;
    //   BTB 查表判决的两侧（bpu_btb.v:147-154 的打拍 tag/valid）
    wire [29:0] btq_tag = u_tb.u_front.u_bpu.u_btb.lu_tag_q;
    wire        btq_val = u_tb.u_front.u_bpu.u_btb.lu_valid_q;

    // ---- D：2 读 1 写 TDP 表（gpht / lpht / seltab，各 mem0/mem1）----
    //   mem0：A 口 = 更新（读写互斥）；mem1：A 口 = 只写。判据统一：写 A ∧ 读 B ∧ 同址。
    wire g0_w0 = u_tb.u_front.u_bpu.u_gshare.u_gpht.u_mem0.a_en & u_tb.u_front.u_bpu.u_gshare.u_gpht.u_mem0.a_we;
    wire g0_b0 = u_tb.u_front.u_bpu.u_gshare.u_gpht.u_mem0.b_en;
    wire [9:0] g0_wa0 = u_tb.u_front.u_bpu.u_gshare.u_gpht.u_mem0.a_addr;
    wire [9:0] g0_ra0 = u_tb.u_front.u_bpu.u_gshare.u_gpht.u_mem0.b_addr;
    wire [1:0] g0_d0  = u_tb.u_front.u_bpu.u_gshare.u_gpht.u_mem0.b_dout;
    wire g0_w1 = u_tb.u_front.u_bpu.u_gshare.u_gpht.u_mem1.a_en & u_tb.u_front.u_bpu.u_gshare.u_gpht.u_mem1.a_we;
    wire g0_b1 = u_tb.u_front.u_bpu.u_gshare.u_gpht.u_mem1.b_en;
    wire [9:0] g0_wa1 = u_tb.u_front.u_bpu.u_gshare.u_gpht.u_mem1.a_addr;
    wire [9:0] g0_ra1 = u_tb.u_front.u_bpu.u_gshare.u_gpht.u_mem1.b_addr;
    wire [1:0] g0_d1  = u_tb.u_front.u_bpu.u_gshare.u_gpht.u_mem1.b_dout;

    wire l0_w0 = u_tb.u_front.u_bpu.u_local.u_lpht.u_mem0.a_en & u_tb.u_front.u_bpu.u_local.u_lpht.u_mem0.a_we;
    wire l0_b0 = u_tb.u_front.u_bpu.u_local.u_lpht.u_mem0.b_en;
    wire [9:0] l0_wa0 = u_tb.u_front.u_bpu.u_local.u_lpht.u_mem0.a_addr;
    wire [9:0] l0_ra0 = u_tb.u_front.u_bpu.u_local.u_lpht.u_mem0.b_addr;
    wire [1:0] l0_d0  = u_tb.u_front.u_bpu.u_local.u_lpht.u_mem0.b_dout;
    wire l0_w1 = u_tb.u_front.u_bpu.u_local.u_lpht.u_mem1.a_en & u_tb.u_front.u_bpu.u_local.u_lpht.u_mem1.a_we;
    wire l0_b1 = u_tb.u_front.u_bpu.u_local.u_lpht.u_mem1.b_en;
    wire [9:0] l0_wa1 = u_tb.u_front.u_bpu.u_local.u_lpht.u_mem1.a_addr;
    wire [9:0] l0_ra1 = u_tb.u_front.u_bpu.u_local.u_lpht.u_mem1.b_addr;
    wire [1:0] l0_d1  = u_tb.u_front.u_bpu.u_local.u_lpht.u_mem1.b_dout;

    wire s0_w0 = u_tb.u_front.u_bpu.u_selector.u_seltab.u_mem0.a_en & u_tb.u_front.u_bpu.u_selector.u_seltab.u_mem0.a_we;
    wire s0_b0 = u_tb.u_front.u_bpu.u_selector.u_seltab.u_mem0.b_en;
    wire [9:0] s0_wa0 = u_tb.u_front.u_bpu.u_selector.u_seltab.u_mem0.a_addr;
    wire [9:0] s0_ra0 = u_tb.u_front.u_bpu.u_selector.u_seltab.u_mem0.b_addr;
    wire [1:0] s0_d0  = u_tb.u_front.u_bpu.u_selector.u_seltab.u_mem0.b_dout;
    wire s0_w1 = u_tb.u_front.u_bpu.u_selector.u_seltab.u_mem1.a_en & u_tb.u_front.u_bpu.u_selector.u_seltab.u_mem1.a_we;
    wire s0_b1 = u_tb.u_front.u_bpu.u_selector.u_seltab.u_mem1.b_en;
    wire [9:0] s0_wa1 = u_tb.u_front.u_bpu.u_selector.u_seltab.u_mem1.a_addr;
    wire [9:0] s0_ra1 = u_tb.u_front.u_bpu.u_selector.u_seltab.u_mem1.b_addr;
    wire [1:0] s0_d1  = u_tb.u_front.u_bpu.u_selector.u_seltab.u_mem1.b_dout;

    // ---- 背压观测量 ----
    wire [7:0] rob_cnt  = u_tb.u_back.rob_cnt_w;             // ROB 有效项数（0..64）
    wire [3:0] iq0_cnt  = u_tb.u_back.iq_cnt[0];             // 各 IQ 剩余空位（0 = 满）
    wire [3:0] iq1_cnt  = u_tb.u_back.iq_cnt[1];
    wire [3:0] iq2_cnt  = u_tb.u_back.iq_cnt[2];
    wire [3:0] iq3_cnt  = u_tb.u_back.iq_cnt[3];
    wire [3:0] iq4_cnt  = u_tb.u_back.iq_cnt[4];
    wire [3:0] iq5_cnt  = u_tb.u_back.iq_cnt[5];
    wire [7:0] stq_used = u_tb.u_back.u_lsu.stq_used;
    wire [7:0] cdq_cnt  = u_tb.u_back.u_lsu.cdq_cnt;

    wire iq_full_any = (iq0_cnt == 4'd0) || (iq1_cnt == 4'd0) || (iq2_cnt == 4'd0) ||
                       (iq3_cnt == 4'd0) || (iq4_cnt == 4'd0) || (iq5_cnt == 4'd0);
    wire rob_fullish = (rob_cnt >= 8'd56);
    wire lsq_fullish = (stq_used >= 8'd6) || (cdq_cnt >= 8'd8);
    wire bp_any      = iq_full_any | rob_fullish | lsq_fullish;

    // ---- 本拍 collision（组合），逐 bank / 逐实例 ----
    wire [NW-1:0] rob_hit_c;
    wire [NW-1:0] iwm_hit_c;
    wire [1:0]    btb_hit_c;
    wire [5:0]    tdp_hit_c;

    assign rob_hit_c[0] = rw_we[0] & rw_re[0] & (rw_woff[ 4: 0] == rw_roff[ 4: 0]);
    assign rob_hit_c[1] = rw_we[1] & rw_re[1] & (rw_woff[ 9: 5] == rw_roff[ 9: 5]);
    assign rob_hit_c[2] = rw_we[2] & rw_re[2] & (rw_woff[14:10] == rw_roff[14:10]);
    assign rob_hit_c[3] = rw_we[3] & rw_re[3] & (rw_woff[19:15] == rw_roff[19:15]);
    assign iwm_hit_c[0] = iw_we[0] & iw_re[0] & (iw_woff[ 3: 0] == iw_roff[ 3: 0]);
    assign iwm_hit_c[1] = iw_we[1] & iw_re[1] & (iw_woff[ 7: 4] == iw_roff[ 7: 4]);
    assign iwm_hit_c[2] = iw_we[2] & iw_re[2] & (iw_woff[11: 8] == iw_roff[11: 8]);
    assign iwm_hit_c[3] = iw_we[3] & iw_re[3] & (iw_woff[15:12] == iw_roff[15:12]);
    assign btb_hit_c[0] = b0_aen & b0_ben & (b0_aad == b0_bad);
    assign btb_hit_c[1] = b1_aen & b1_ben & (b1_aad == b1_bad);
    assign tdp_hit_c[0] = g0_w0 & g0_b0 & (g0_wa0 == g0_ra0);
    assign tdp_hit_c[1] = g0_w1 & g0_b1 & (g0_wa1 == g0_ra1);
    assign tdp_hit_c[2] = l0_w0 & l0_b0 & (l0_wa0 == l0_ra0);
    assign tdp_hit_c[3] = l0_w1 & l0_b1 & (l0_wa1 == l0_ra1);
    assign tdp_hit_c[4] = s0_w0 & s0_b0 & (s0_wa0 == s0_ra0);
    assign tdp_hit_c[5] = s0_w1 & s0_b1 & (s0_wa1 == s0_ra1);

    wire any_col_c = |rob_hit_c | |iwm_hit_c | |btb_hit_c | |tdp_hit_c;

    // ---- 机制核对（rob.v:383-384 的索引分解的**独立复算**）----
    //   写口 gw：wt = tail + ((gw - tail[1:0]) mod 4) ⇒ 低 2 位 = gw（bank 正确），
    //     而 bits[6:2] = (tail>>2) + 进位，进位 = (gw < tail[1:0]) ? 1 : 0；
    //   读口 gw：rt = hpred + ((gw - hpred[1:0]) mod 4) ⇒ 同理。
    //   ⇒ bank gw 的同址同拍 ⇔ eff_off(tail,gw) == eff_off(hpred,gw) ∧ we[gw] ∧ re[gw]。
    //   本式**不引用** rob_hit_c，用于与 RTL 端口上的实测碰撞逐位对齐（不一致即拆解有误）。
    wire [6:0] rb_tail_w  = u_tb.u_back.u_rob.tail_w;
    wire [6:0] rb_hpred_w = u_tb.u_back.u_rob.hpred_w;
    function [5:0] eff_off;
        input [6:0] idx;
        input [1:0] gw;
        begin eff_off = {1'b0, idx[6:2]} + {5'b0, (gw < idx[1:0])};
        end
    endfunction
    wire [NW-1:0] mech_hit;
    assign mech_hit[0] = (eff_off(rb_tail_w,2'd0) == eff_off(rb_hpred_w,2'd0)) & rw_we[0] & rw_re[0];
    assign mech_hit[1] = (eff_off(rb_tail_w,2'd1) == eff_off(rb_hpred_w,2'd1)) & rw_we[1] & rw_re[1];
    assign mech_hit[2] = (eff_off(rb_tail_w,2'd2) == eff_off(rb_hpred_w,2'd2)) & rw_we[2] & rw_re[2];
    assign mech_hit[3] = (eff_off(rb_tail_w,2'd3) == eff_off(rb_hpred_w,2'd3)) & rw_we[3] & rw_re[3];
    wire       we_nz         = |rw_we;
    wire       rob_col_cyc_c = |rob_hit_c;
    wire       mech_any_c    = |mech_hit;
    wire       mech_mismatch = (mech_hit !== rob_hit_c);

    //==========================================================================
    // 1. 打拍：碰撞拍 t 的判据 + 该拍的"保持值"（NO_CHANGE 会给出的值）
    //==========================================================================
    reg        rst_a, bp_a;
    reg        mech_any_a, mech_mm_a, we_nz_a, rob_col_cyc_a;
    reg [7:0]  rob_cnt_a;
    reg [NW-1:0] rob_hit_a, iwm_hit_a;
    reg [1:0]    btb_hit_a;
    reg [5:0]    tdp_hit_a;
    reg [NW*225-1:0] rob_hd_a;
    reg [NW*212-1:0] iwm_hd_a;
    reg [65:0]   btb_hd_a0, btb_hd_a1;
    reg [1:0]    tdp_hd_a0, tdp_hd_a1, tdp_hd_a2, tdp_hd_a3, tdp_hd_a4, tdp_hd_a5;

    always @(posedge clk) begin
        rst_a     <= rst_n;
        bp_a      <= bp_any;
        rob_cnt_a <= rob_cnt;
        mech_any_a     <= mech_any_c;
        mech_mm_a      <= mech_mismatch;
        we_nz_a        <= we_nz;
        rob_col_cyc_a  <= rob_col_cyc_c;
        rob_hit_a <= rob_hit_c;
        iwm_hit_a <= iwm_hit_c;
        btb_hit_a <= btb_hit_c;
        tdp_hit_a <= tdp_hit_c;
        rob_hd_a  <= rw_rd;
        iwm_hd_a  <= iw_rd;
        btb_hd_a0 <= b0_do;
        btb_hd_a1 <= b1_do;
        tdp_hd_a0 <= g0_d0;  tdp_hd_a1 <= g0_d1;
        tdp_hd_a2 <= l0_d0;  tdp_hd_a3 <= l0_d1;
        tdp_hd_a4 <= s0_d0;  tdp_hd_a5 <= s0_d1;
    end

    //==========================================================================
    // 2. 计数（逐程序）
    //==========================================================================
    integer rob_col  [0:NP-1];
    integer rob_diff [0:NP-1];
    integer iwm_col  [0:NP-1];
    integer iwm_diff [0:NP-1];
    integer btb_col  [0:NP-1];
    integer btb_diff [0:NP-1];
    integer btb_hd   [0:NP-1];
    integer tdp_col  [0:NP-1];
    integer tdp_diff [0:NP-1];
    integer cyc_cnt  [0:NP-1];
    integer bp_col   [0:NP-1];
    integer bp_cyc   [0:NP-1];
    integer rob_max  [0:NP-1];
    integer iqmin    [0:NP-1];
    integer bus_rob, bus_iwm, bus_btb, bus_tdp, bus_bthd, bus_tdpdf, bus_col, bus_bpcol;
    integer robcn_min, robcn_max;
    integer n_grp = 0, n_grp_we = 0, n_we = 0, n_col_cyc = 0, n_grp_nocol = 0;
    integer bus_cyc = 0;
    integer robh [0:7];          // 碰撞拍 ROB 占用直方图（8 桶 × 8）

    integer c;
    reg hit_rf, hit_nc;

    initial begin
        for (c = 0; c < NP; c = c + 1) begin
            rob_col[c]=0; rob_diff[c]=0; iwm_col[c]=0; iwm_diff[c]=0;
            btb_col[c]=0; btb_diff[c]=0; btb_hd[c]=0;
            tdp_col[c]=0; tdp_diff[c]=0; cyc_cnt[c]=0;
            bp_col[c]=0; bp_cyc[c]=0; rob_max[c]=0; iqmin[c]=99;
        end
        for (c = 0; c < 8; c = c + 1) robh[c] = 0;
        robcn_min = 999; robcn_max = 0;
        bus_rob=0; bus_iwm=0; bus_btb=0; bus_tdp=0; bus_bthd=0; bus_tdpdf=0;
        bus_col=0; bus_bpcol=0;
    end

    always @(posedge clk) if (rst_a) begin
        if (pi >= 0 && pi < NP) begin
            cyc_cnt[pi] = cyc_cnt[pi] + 1;
            // 机制核对（全程序累计）
            if (mech_any_a)    n_grp = n_grp + 1;
            if (we_nz_a)       n_we  = n_we + 1;
            if (mech_mm_a)     n_grp_we = n_grp_we + 1;
            if (rob_col_cyc_a) n_col_cyc = n_col_cyc + 1;
            if (mech_any_a & ~mech_mm_a) n_grp_nocol = n_grp_nocol + 1;
            if (rob_cnt > rob_max[pi]) rob_max[pi] = {24'd0, rob_cnt};
            if ({28'd0, iq0_cnt} < iqmin[pi]) iqmin[pi] = {28'd0, iq0_cnt};
            if (bp_any) bp_cyc[pi] = bp_cyc[pi] + 1;

            // ---------------- collision 计数（逐实例/逐 bank 事件）----------------
            for (c = 0; c < NW; c = c + 1) begin
                if (rob_hit_a[c]) begin
                    rob_col[pi] = rob_col[pi] + 1;
                    // 碰撞拍 ROB 占用直方图（8 桶 × 8；用打拍值 = 碰撞当拍的占用）
                    robh[rob_cnt_a[7:3]] = robh[rob_cnt_a[7:3]] + 1;
                    if ({24'd0, rob_cnt_a} < robcn_min) robcn_min = {24'd0, rob_cnt_a};
                    if ({24'd0, rob_cnt_a} > robcn_max) robcn_max = {24'd0, rob_cnt_a};
                end
                if (iwm_hit_a[c]) iwm_col[pi] = iwm_col[pi] + 1;
            end
            if (btb_hit_a[0]) btb_col[pi] = btb_col[pi] + 1;
            if (btb_hit_a[1]) btb_col[pi] = btb_col[pi] + 1;
            for (c = 0; c < 6; c = c + 1) if (tdp_hit_a[c]) tdp_col[pi] = tdp_col[pi] + 1;

            // ---------------- 语义分叉：读回值（read_first vs NO_CHANGE）----------------
            //   此刻 `rw_rd`/`iw_rd`/`b*_do`/… 仍是**上一拍碰撞读**的 read_first 结果；
            //   `*_hd_a` 是碰撞拍 t 的输出保持值（NO_CHANGE 语义）。
            for (c = 0; c < NW; c = c + 1) begin
                if (rob_hit_a[c] && (rw_rd[c*225 +: 225] !== rob_hd_a[c*225 +: 225]))
                    rob_diff[pi] = rob_diff[pi] + 1;
                if (iwm_hit_a[c] && (iw_rd[c*212 +: 212] !== iwm_hd_a[c*212 +: 212]))
                    iwm_diff[pi] = iwm_diff[pi] + 1;
            end
            if (btb_hit_a[0] && (b0_do !== btb_hd_a0)) btb_diff[pi] = btb_diff[pi] + 1;
            if (btb_hit_a[1] && (b1_do !== btb_hd_a1)) btb_diff[pi] = btb_diff[pi] + 1;
            if (tdp_hit_a[0] && (g0_d0 !== tdp_hd_a0)) tdp_diff[pi] = tdp_diff[pi] + 1;
            if (tdp_hit_a[1] && (g0_d1 !== tdp_hd_a1)) tdp_diff[pi] = tdp_diff[pi] + 1;
            if (tdp_hit_a[2] && (l0_d0 !== tdp_hd_a2)) tdp_diff[pi] = tdp_diff[pi] + 1;
            if (tdp_hit_a[3] && (l0_d1 !== tdp_hd_a3)) tdp_diff[pi] = tdp_diff[pi] + 1;
            if (tdp_hit_a[4] && (s0_d0 !== tdp_hd_a4)) tdp_diff[pi] = tdp_diff[pi] + 1;
            if (tdp_hit_a[5] && (s0_d1 !== tdp_hd_a5)) tdp_diff[pi] = tdp_diff[pi] + 1;

            // ---------------- BTB 命中判决分叉 ----------------
            if (btb_hit_a[0]) begin
                hit_rf = btq_val & b0_do[0]        & (b0_do[30:1]        == btq_tag);
                hit_nc = btq_val & btb_hd_a0[0]    & (btb_hd_a0[30:1]    == btq_tag);
                if (hit_rf !== hit_nc) btb_hd[pi] = btb_hd[pi] + 1;
            end
            if (btb_hit_a[1]) begin
                hit_rf = btq_val & b1_do[0]        & (b1_do[30:1]        == btq_tag);
                hit_nc = btq_val & btb_hd_a1[0]    & (btb_hd_a1[30:1]    == btq_tag);
                if (hit_rf !== hit_nc) btb_hd[pi] = btb_hd[pi] + 1;
            end

            // ---------------- 背压下的碰撞（回答第 4 步）----------------
            if (any_col_c && bp_a) bp_col[pi] = bp_col[pi] + 1;
        end
    end

    //==========================================================================
    // 3. 报告（CSV 行；不含 PASS 兜底文案）
    //==========================================================================
    final begin
        for (c = 0; c < NP; c = c + 1) begin
            $display("N25_PROBE,prog=%0d,cyc=%0d,bp_cyc=%0d,rob_max=%0d,iq_free_min=%0d,rob_col=%0d,rob_diff=%0d,iwm_col=%0d,iwm_diff=%0d,btb_col=%0d,btb_valdiff=%0d,btb_hitdiff=%0d,tdp_col=%0d,tdp_valdiff=%0d,bp_col=%0d",
                     c, cyc_cnt[c], bp_cyc[c], rob_max[c], iqmin[c],
                     rob_col[c], rob_diff[c], iwm_col[c], iwm_diff[c],
                     btb_col[c], btb_diff[c], btb_hd[c], tdp_col[c], tdp_diff[c], bp_col[c]);
            $fflush();
            bus_rob   = bus_rob   + rob_col[c];
            bus_iwm   = bus_iwm   + iwm_col[c];
            bus_btb   = bus_btb   + btb_col[c];
            bus_tdp   = bus_tdp   + tdp_col[c];
            bus_bthd  = bus_bthd  + btb_hd[c];
            bus_tdpdf = bus_tdpdf + tdp_diff[c];
            bus_col   = bus_col   + rob_col[c] + iwm_col[c] + btb_col[c] + tdp_col[c];
            bus_bpcol = bus_bpcol + bp_col[c];
            bus_cyc   = bus_cyc   + cyc_cnt[c];
        end
        $display("N25_PROBE_TOTAL,progs=%0d,col_events=%0d,bp_col=%0d,rob_col=%0d,iwm_col=%0d,btb_col=%0d,btb_hitdiff=%0d,tdp_col=%0d,tdp_valdiff=%0d",
                 NP, bus_col, bus_bpcol, bus_rob, bus_iwm, bus_btb, bus_bthd, bus_tdp, bus_tdpdf);
        $display("N25_PROBE_ROBOCC,at_col_min=%0d,at_col_max=%0d,h0_7=%0d,h8_15=%0d,h16_23=%0d,h24_31=%0d,h32_39=%0d,h40_47=%0d,h48_55=%0d,h56_63=%0d",
                 robcn_min, robcn_max, robh[0], robh[1], robh[2], robh[3],
                 robh[4], robh[5], robh[6], robh[7]);
        $display("N25_PROBE_MECH,cyc=%0d,mech_cyc=%0d,mech_bitexact_cyc=%0d,mech_mismatch_cyc=%0d,we_nz=%0d,rtl_col_cyc=%0d",
                 bus_cyc, n_grp, n_grp_nocol, n_grp_we, n_we, n_col_cyc);
        $fflush();
    end

endmodule
