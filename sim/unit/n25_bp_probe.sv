//==============================================================================
// sim/unit/n25_bp_probe.sv —— N25：满负载/背压场景下的 ROB/发射宽载荷 collision 实测
//------------------------------------------------------------------------------
// 为什么需要它（answer.md §五 N25 第 4 步"正常运行 + backpressure 均覆盖"）：
//   `n25_collision_probe.sv` 跑 5 个锁步程序，实测 ROB 占用峰值只有 44/64、
//   各 IQ 最少剩余 9 个空位 ⇒ 锁步程序**没有**把 ROB/IQ 压满，
//   "ROB 窗满（预取地址追上 tail）"这一最危险的 collision 场景没有被覆盖。
//   本探针挂到 `tb_back2_ipc`（**后端直驱**：每拍 4 宽派发流，刻意把 ROB/IQ 压满，
//   见 tb_back2_ipc.sv §"为什么必须后端直驱"），在满负载下实测同一批冲突。
//
// 观测范围：u_back.u_rob.u_wmem（ROB 宽载荷 4 bank SDP）+ u_back.u_iwmem（发射宽载荷）。
//   · 本 TB 不含前端（无 bpu_btb / 无 gpht/lpht/seltab）⇒ BTB/TDP 族的背压覆盖由
//     `n25_btb_collide_tb.sv`（定向反证）+ `n25_collision_probe.sv`（锁步实测）承担，
//     报告中会显式说明这一边界，不用本探针冒充。
//
// 背压判据（本文件"满"的口径，取自 back2_params：ROB_N=64、STQ_N=32、CDQ_N=8）：
//   iq_full  : 任一 IQ 的 free_cnt == 0（iq_cnt[q]，backend_top.v:520/1281-1371）
//   rob_full : rob_cnt_w >= 60（留 4 条余量，覆盖"预取窗口触及 tail"）
//   lsq_full : stq_used >= 30 或 cdq_cnt >= 7
//
// 纪律：只读层次引用；文件名不以 tb_ 开头 ⇒ 不进 scripts/regress.sh；不打印 PASS 兜底文案。
//
// 运行（见 fpga/scratch/n25_run.sh）：
//   iverilog -g2012 -I rtl/pkg -I . -o /tmp/n25_bp.vvp -s n25_bp_probe \
//            "${RTL[@]}" sim/unit/tb_back2_ipc.sv sim/unit/n25_bp_probe.sv && vvp /tmp/n25_bp.vvp
//==============================================================================
`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"
`include "rtl/front4/front4_params.vh"
`include "rtl/back2/back2_params.vh"

module n25_bp_probe;

    localparam integer NW = 4;

    tb_back2_ipc u_tb ();

    wire clk   = u_tb.clk;
    wire rst_n = u_tb.rst_n;

    // ---- ROB 宽载荷 4 bank SDP ----
    wire [NW-1:0]     rw_we   = u_tb.u_back.u_rob.u_wmem.we;
    wire [NW*5-1:0]   rw_woff = u_tb.u_back.u_rob.u_wmem.woff;
    wire [NW-1:0]     rw_re   = u_tb.u_back.u_rob.u_wmem.re;
    wire [NW*5-1:0]   rw_roff = u_tb.u_back.u_rob.u_wmem.roff;
    wire [NW*225-1:0] rw_rd   = u_tb.u_back.u_rob.u_wmem.rdata;
    // ---- 发射宽载荷 4 bank SDP ----
    wire [NW-1:0]     iw_we   = u_tb.u_back.u_iwmem.we;
    wire [NW*4-1:0]   iw_woff = u_tb.u_back.u_iwmem.woff;
    wire [NW-1:0]     iw_re   = u_tb.u_back.u_iwmem.re;
    wire [NW*4-1:0]   iw_roff = u_tb.u_back.u_iwmem.roff;
    wire [NW*212-1:0] iw_rd   = u_tb.u_back.u_iwmem.rdata;

    wire [7:0] rob_cnt  = u_tb.u_back.rob_cnt_w;
    wire [3:0] iq0 = u_tb.u_back.iq_cnt[0], iq1 = u_tb.u_back.iq_cnt[1];
    wire [3:0] iq2 = u_tb.u_back.iq_cnt[2], iq3 = u_tb.u_back.iq_cnt[3];
    wire [3:0] iq4 = u_tb.u_back.iq_cnt[4], iq5 = u_tb.u_back.iq_cnt[5];
    wire [5:0] stq_used = u_tb.u_back.u_lsu.stq_used;
    wire [7:0] cdq_cnt  = u_tb.u_back.u_lsu.cdq_cnt;

    wire iq_full  = (iq0==4'd0)|(iq1==4'd0)|(iq2==4'd0)|(iq3==4'd0)|(iq4==4'd0)|(iq5==4'd0);
    wire rob_full = (rob_cnt >= 8'd60);
    wire lsq_full = (stq_used >= 6'd30) | (cdq_cnt >= 8'd7);

    wire [NW-1:0] rob_hit_c;
    wire [NW-1:0] iwm_hit_c;
    assign rob_hit_c[0] = rw_we[0] & rw_re[0] & (rw_woff[ 4: 0] == rw_roff[ 4: 0]);
    assign rob_hit_c[1] = rw_we[1] & rw_re[1] & (rw_woff[ 9: 5] == rw_roff[ 9: 5]);
    assign rob_hit_c[2] = rw_we[2] & rw_re[2] & (rw_woff[14:10] == rw_roff[14:10]);
    assign rob_hit_c[3] = rw_we[3] & rw_re[3] & (rw_woff[19:15] == rw_roff[19:15]);
    assign iwm_hit_c[0] = iw_we[0] & iw_re[0] & (iw_woff[ 3: 0] == iw_roff[ 3: 0]);
    assign iwm_hit_c[1] = iw_we[1] & iw_re[1] & (iw_woff[ 7: 4] == iw_roff[ 7: 4]);
    assign iwm_hit_c[2] = iw_we[2] & iw_re[2] & (iw_woff[11: 8] == iw_roff[11: 8]);
    assign iwm_hit_c[3] = iw_we[3] & iw_re[3] & (iw_woff[15:12] == iw_roff[15:12]);

    reg rst_a, iq_full_a, rob_full_a, lsq_full_a;
    reg [NW-1:0] rob_hit_a, iwm_hit_a;
    reg [NW*225-1:0] rob_hd_a;
    reg [NW*212-1:0] iwm_hd_a;
    always @(posedge clk) begin
        rst_a <= rst_n; iq_full_a <= iq_full; rob_full_a <= rob_full; lsq_full_a <= lsq_full;
        rob_hit_a <= rob_hit_c; iwm_hit_a <= iwm_hit_c;
        rob_hd_a <= rw_rd; iwm_hd_a <= iw_rd;
    end

    integer rob_col=0, rob_diff=0, iwm_col=0, iwm_diff=0;
    integer iqf_col=0, rob_col_full=0, lsq_col_full=0, anycol_full=0;
    integer rob_max=0, iq_min=99, stq_max=0, cdq_max=0, cyc=0;
    integer c;

    always @(posedge clk) if (rst_a) begin
        cyc = cyc + 1;
        if (rob_cnt > rob_max) rob_max = {24'd0, rob_cnt};
        if ({28'd0, iq0} < iq_min) iq_min = {28'd0, iq0};
        if (stq_used > stq_max) stq_max = {26'd0, stq_used};
        if (cdq_cnt  > cdq_max) cdq_max = {24'd0, cdq_cnt};

        for (c = 0; c < NW; c = c + 1) begin
            if (rob_hit_a[c]) begin
                rob_col = rob_col + 1;
                if (rob_hd_a[c*225 +: 225] !== rw_rd[c*225 +: 225]) rob_diff = rob_diff + 1;
                if (rob_full_a) rob_col_full = rob_col_full + 1;
                if (iq_full_a)  iqf_col = iqf_col + 1;
                if (lsq_full_a) lsq_col_full = lsq_col_full + 1;
                if (rob_full_a | iq_full_a | lsq_full_a) anycol_full = anycol_full + 1;
            end
            if (iwm_hit_a[c]) begin
                iwm_col = iwm_col + 1;
                if (iwm_hd_a[c*212 +: 212] !== iw_rd[c*212 +: 212]) iwm_diff = iwm_diff + 1;
            end
        end
    end

    final begin
        $display("N25_BP_PROBE,cyc=%0d,rob_max=%0d,iq_free_min=%0d,stq_max=%0d,cdq_max=%0d,rob_col=%0d,rob_diff=%0d,iwm_col=%0d,iwm_diff=%0d,col_under_rob_full=%0d,col_under_iq_full=%0d,col_under_lsq_full=%0d,col_under_any_full=%0d",
                 cyc, rob_max, iq_min, stq_max, cdq_max, rob_col, rob_diff, iwm_col, iwm_diff,
                 rob_col_full, iqf_col, lsq_col_full, anycol_full);
        $fflush();
    end

endmodule
