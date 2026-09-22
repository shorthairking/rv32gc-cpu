//==============================================================================
// sim/unit/tb_back2_iq.sv —— 2B-2 分布式发射队列单元验证（6 个队列全部实例化）
//==============================================================================
// 被测  : rtl/back2/iq.v ×6（ALU0/ALU1/BRU/MDU/LSU/FPU 深度 16/16/8/8/12/8）
// 判据（全部 $fatal；未捕获即失败）：
//   C1 入队/空位计数：逐拍入队后 free_cnt 精确递减，按深度封顶
//   C2 未就绪不发射：源未唤醒 ⇒ sel/iss 恒 0（不投机发射，03 §4.3）
//   C3 唤醒广播：写回广播命中该源 ⇒ **当拍即可被选出**（唤醒-选择同拍，03 §4.3）
//   C4 最老优先：多项就绪时选中年龄最小者（按 ROB 索引比较，03 §4.3）
//   C5 单端口：每拍至多发射 1 条（iss_ready=0 时不出队且选择稳定）
//   C6 年龄序与 rob 回绕：rob 索引跨 128 回绕时仍按"距 head 最远"选最老
//   C7 冲刷按序号作废：`squash` 只作废**比 squash_idx 更年轻**的项；更老的项
//     必须照常可发射且**不标 dead**（回归用例：旧实现按 epoch 丢弃全部过期项，
//      导致 ROB 保留的更老项永不写回 ⇒ ROB 头卡死）
//   C7b flush_all 之外的项不得被误杀（数量精确）
//   C8 无活锁：随机唤醒/发射序列下，队列在有限拍内排空（有界性）
//   C9 flush_all：整队列清空
// 顶层  : tb_back2_iq
// 锚点  : TB_BACK2_IQ: PASS（整行恰好一次）
//==============================================================================
`timescale 1ns / 1ps

`include "rtl/back2/back2_params.vh"

module tb_back2_iq;

    localparam integer CLK_P  = 10;
    localparam integer NI     = 6;
    localparam integer UOPW   = `BACK2_UOP_W;
    localparam integer SRC_N  = 5;

    reg clk, rst_n;
    initial begin clk = 1'b0; forever #(CLK_P/2) clk = ~clk; end

    integer n_checks;
    task automatic chk(input cond, input string msg);
        begin
            n_checks = n_checks + 1;
            if (!cond) begin
                $display("FAIL: %s（第 %0d 项检查）", msg, n_checks);
                $fatal(1, "TB_BACK2_IQ 判据不满足");
            end
        end
    endtask

    //--------------------------------------------------------------------------
    // 激励（同一激励驱动 6 个队列；除容量外期望一致）
    //--------------------------------------------------------------------------
    reg  [NI-1:0]        wr_v;
    reg  [NI*4*UOPW-1:0] wr_uop;              // 4 写口 × UOPW
    reg  [NI*4*7-1:0]    wr_rob;
    reg  [NI*4*SRC_N-1:0] wr_rdy;
    reg  [NI-1:0][6:0]   rob_head;            // 各队列同值
    reg  [NI-1:0][1:0]   epoch;
    reg  [NI-1:0]        flush_all;
    reg  [NI-1:0]        squash;
    reg  [NI-1:0][6:0]   squash_idx;
    reg  [NI-1:0][7:0]   rob_cnt;   // ROB 窗口大小（0..128）
    reg  [NI-1:0]        iss_ready;
    reg  [NI-1:0][5:0]   wki_v;               // 6 个整数唤醒道
    reg  [NI-1:0][5:0]   wkf_v;
    wire [NI-1:0]        iss_v, iss_dead;
    wire [NI*7-1:0]      iss_rob;
    wire [NI*UOPW-1:0]   iss_uop;
    wire [NI*5-1:0]      free_cnt;
    wire [NI*5-1:0]      cnt_o;
    wire [NI-1:0]        sel_v;
    wire [NI*UOPW-1:0]   sel_uop;
    wire [NI*7-1:0]      sel_rob;

    // 整数唤醒标签：道 k 广播 tag = {1, ps[5:0]}（6 bit → 7 bit 物理号低位）
    wire [6*7-1:0] wki_tag;
    wire [6*6-1:0] wkf_tag;
    // 道 j 的标签 = j+1（打包向量低位 = 道 0）
    assign wki_tag = { 7'd6, 7'd5, 7'd4, 7'd3, 7'd2, 7'd1 };
    assign wkf_tag = { 6'd6, 6'd5, 6'd4, 6'd3, 6'd2, 6'd1 };

    iq #(.DEPTH(`BACK2_IQ_ALU0_D)) u_iq0 (
        .clk(clk), .rst_n(rst_n), .flush_all(flush_all[0]), .squash(squash[0]), .squash_idx(squash_idx[0]), .rob_cnt(rob_cnt[0]),
        .epoch(epoch[0]),
        .wr_valid({3'b0, wr_v[0]}),
        .wr_uop(wr_uop[0*4*UOPW +: 4*UOPW]),
        .wr_rob(wr_rob[0*4*7 +: 4*7]),
        .wr_rdy(wr_rdy[0*4*SRC_N +: 4*SRC_N]),
        .free_cnt(free_cnt[0*5 +: 5]),
        .wki_v(wki_v[0]), .wki_tag(wki_tag),
        .wkf_v(wkf_v[0]), .wkf_tag(wkf_tag),
        .rob_head(rob_head[0]), .iss_ready(iss_ready[0]),
        .iss_valid(iss_v[0]), .iss_uop(iss_uop[0*UOPW +: UOPW]),
        .iss_rob(iss_rob[0*7 +: 7]), .iss_epoch(), .iss_dead(iss_dead[0]),
        .cnt_o(cnt_o[0*5 +: 5]),
        .o_sel_v(sel_v[0]), .o_sel_uop(sel_uop[0*UOPW +: UOPW]),
        .o_sel_rob(sel_rob[0*7 +: 7])
    );
    iq #(.DEPTH(`BACK2_IQ_ALU1_D)) u_iq1 (
        .clk(clk), .rst_n(rst_n), .flush_all(flush_all[1]), .squash(squash[1]), .squash_idx(squash_idx[1]), .rob_cnt(rob_cnt[1]),
        .epoch(epoch[1]),
        .wr_valid({3'b0, wr_v[1]}),
        .wr_uop(wr_uop[1*4*UOPW +: 4*UOPW]),
        .wr_rob(wr_rob[1*4*7 +: 4*7]),
        .wr_rdy(wr_rdy[1*4*SRC_N +: 4*SRC_N]),
        .free_cnt(free_cnt[1*5 +: 5]),
        .wki_v(wki_v[1]), .wki_tag(wki_tag),
        .wkf_v(wkf_v[1]), .wkf_tag(wkf_tag),
        .rob_head(rob_head[1]), .iss_ready(iss_ready[1]),
        .iss_valid(iss_v[1]), .iss_uop(iss_uop[1*UOPW +: UOPW]),
        .iss_rob(iss_rob[1*7 +: 7]), .iss_epoch(), .iss_dead(iss_dead[1]),
        .cnt_o(cnt_o[1*5 +: 5]),
        .o_sel_v(sel_v[1]), .o_sel_uop(sel_uop[1*UOPW +: UOPW]),
        .o_sel_rob(sel_rob[1*7 +: 7])
    );
    iq #(.DEPTH(`BACK2_IQ_BRU_D)) u_iq2 (
        .clk(clk), .rst_n(rst_n), .flush_all(flush_all[2]), .squash(squash[2]), .squash_idx(squash_idx[2]), .rob_cnt(rob_cnt[2]),
        .epoch(epoch[2]),
        .wr_valid({3'b0, wr_v[2]}),
        .wr_uop(wr_uop[2*4*UOPW +: 4*UOPW]),
        .wr_rob(wr_rob[2*4*7 +: 4*7]),
        .wr_rdy(wr_rdy[2*4*SRC_N +: 4*SRC_N]),
        .free_cnt(free_cnt[2*5 +: 5]),
        .wki_v(wki_v[2]), .wki_tag(wki_tag),
        .wkf_v(wkf_v[2]), .wkf_tag(wkf_tag),
        .rob_head(rob_head[2]), .iss_ready(iss_ready[2]),
        .iss_valid(iss_v[2]), .iss_uop(iss_uop[2*UOPW +: UOPW]),
        .iss_rob(iss_rob[2*7 +: 7]), .iss_epoch(), .iss_dead(iss_dead[2]),
        .cnt_o(cnt_o[2*5 +: 5]),
        .o_sel_v(sel_v[2]), .o_sel_uop(sel_uop[2*UOPW +: UOPW]),
        .o_sel_rob(sel_rob[2*7 +: 7])
    );
    iq #(.DEPTH(`BACK2_IQ_MDU_D)) u_iq3 (
        .clk(clk), .rst_n(rst_n), .flush_all(flush_all[3]), .squash(squash[3]), .squash_idx(squash_idx[3]), .rob_cnt(rob_cnt[3]),
        .epoch(epoch[3]),
        .wr_valid({3'b0, wr_v[3]}),
        .wr_uop(wr_uop[3*4*UOPW +: 4*UOPW]),
        .wr_rob(wr_rob[3*4*7 +: 4*7]),
        .wr_rdy(wr_rdy[3*4*SRC_N +: 4*SRC_N]),
        .free_cnt(free_cnt[3*5 +: 5]),
        .wki_v(wki_v[3]), .wki_tag(wki_tag),
        .wkf_v(wkf_v[3]), .wkf_tag(wkf_tag),
        .rob_head(rob_head[3]), .iss_ready(iss_ready[3]),
        .iss_valid(iss_v[3]), .iss_uop(iss_uop[3*UOPW +: UOPW]),
        .iss_rob(iss_rob[3*7 +: 7]), .iss_epoch(), .iss_dead(iss_dead[3]),
        .cnt_o(cnt_o[3*5 +: 5]),
        .o_sel_v(sel_v[3]), .o_sel_uop(sel_uop[3*UOPW +: UOPW]),
        .o_sel_rob(sel_rob[3*7 +: 7])
    );
    iq #(.DEPTH(`BACK2_IQ_LSU_D)) u_iq4 (
        .clk(clk), .rst_n(rst_n), .flush_all(flush_all[4]), .squash(squash[4]), .squash_idx(squash_idx[4]), .rob_cnt(rob_cnt[4]),
        .epoch(epoch[4]),
        .wr_valid({3'b0, wr_v[4]}),
        .wr_uop(wr_uop[4*4*UOPW +: 4*UOPW]),
        .wr_rob(wr_rob[4*4*7 +: 4*7]),
        .wr_rdy(wr_rdy[4*4*SRC_N +: 4*SRC_N]),
        .free_cnt(free_cnt[4*5 +: 5]),
        .wki_v(wki_v[4]), .wki_tag(wki_tag),
        .wkf_v(wkf_v[4]), .wkf_tag(wkf_tag),
        .rob_head(rob_head[4]), .iss_ready(iss_ready[4]),
        .iss_valid(iss_v[4]), .iss_uop(iss_uop[4*UOPW +: UOPW]),
        .iss_rob(iss_rob[4*7 +: 7]), .iss_epoch(), .iss_dead(iss_dead[4]),
        .cnt_o(cnt_o[4*5 +: 5]),
        .o_sel_v(sel_v[4]), .o_sel_uop(sel_uop[4*UOPW +: UOPW]),
        .o_sel_rob(sel_rob[4*7 +: 7])
    );
    iq #(.DEPTH(`BACK2_IQ_FPU_D)) u_iq5 (
        .clk(clk), .rst_n(rst_n), .flush_all(flush_all[5]), .squash(squash[5]), .squash_idx(squash_idx[5]), .rob_cnt(rob_cnt[5]),
        .epoch(epoch[5]),
        .wr_valid({3'b0, wr_v[5]}),
        .wr_uop(wr_uop[5*4*UOPW +: 4*UOPW]),
        .wr_rob(wr_rob[5*4*7 +: 4*7]),
        .wr_rdy(wr_rdy[5*4*SRC_N +: 4*SRC_N]),
        .free_cnt(free_cnt[5*5 +: 5]),
        .wki_v(wki_v[5]), .wki_tag(wki_tag),
        .wkf_v(wkf_v[5]), .wkf_tag(wkf_tag),
        .rob_head(rob_head[5]), .iss_ready(iss_ready[5]),
        .iss_valid(iss_v[5]), .iss_uop(iss_uop[5*UOPW +: UOPW]),
        .iss_rob(iss_rob[5*7 +: 7]), .iss_epoch(), .iss_dead(iss_dead[5]),
        .cnt_o(cnt_o[5*5 +: 5]),
        .o_sel_v(sel_v[5]), .o_sel_uop(sel_uop[5*UOPW +: UOPW]),
        .o_sel_rob(sel_rob[5*7 +: 7])
    );

    localparam integer D0 = `BACK2_IQ_ALU0_D, D1 = `BACK2_IQ_ALU1_D,
                       D2 = `BACK2_IQ_BRU_D,  D3 = `BACK2_IQ_MDU_D,
                       D4 = `BACK2_IQ_LSU_D,  D5 = `BACK2_IQ_FPU_D;
    function [4:0] dpt(input integer ix);
        begin
            dpt = (ix == 0) ? D0[4:0] : (ix == 1) ? D1[4:0] : (ix == 2) ? D2[4:0] :
                  (ix == 3) ? D3[4:0] : (ix == 4) ? D4[4:0] : D5[4:0];
        end
    endfunction

    //--------------------------------------------------------------------------
    // uop 构造：源 1 用整数 ps1i，可选 5 个源
    //--------------------------------------------------------------------------
    function [UOPW-1:0] mk_uop(input [6:0] ps1i, input [6:0] ps2i, input [5:0] ps1f,
                               input [5:0] ps2f, input [5:0] ps3f,
                               input use1i, input use2i, input use1f, input use2f, input use3f,
                               input [31:0] tag32);
        reg [UOPW-1:0] u;
        begin
            u = {UOPW{1'b0}};
            u[`BACK2_U_PS1I_MSB:`BACK2_U_PS1I_LSB] = ps1i;
            u[`BACK2_U_PS2I_MSB:`BACK2_U_PS2I_LSB] = ps2i;
            u[`BACK2_U_PS1F_MSB:`BACK2_U_PS1F_LSB] = ps1f;
            u[`BACK2_U_PS2F_MSB:`BACK2_U_PS2F_LSB] = ps2f;
            u[`BACK2_U_PS3F_MSB:`BACK2_U_PS3F_LSB] = ps3f;
            u[`BACK2_UB_S1_I_USE] = use1i;
            u[`BACK2_UB_S2_I_USE] = use2i;
            u[`BACK2_UB_S1_F_USE] = use1f;
            u[`BACK2_UB_S2_F_USE] = use2f;
            u[`BACK2_UB_S3_F_USE] = use3f;
            u[`BACK2_U_PC_MSB:`BACK2_U_PC_LSB] = tag32;
            mk_uop = u;
        end
    endfunction

    // 就绪掩码：未用源恒 1
    function [SRC_N-1:0] rdy_mask(input use1i, input use2i, input use1f, input use2f, input use3f,
                                   input r1i, input r2i, input r1f, input r2f, input r3f);
        begin
            rdy_mask = { use3f ? r3f : 1'b1,
                         use2f ? r2f : 1'b1,
                         use1f ? r1f : 1'b1,
                         use2i ? r2i : 1'b1,
                         use1i ? r1i : 1'b1 };
        end
    endfunction

    // 入队一条（1 拍，写口 0）
    task automatic push(input integer idx, input [6:0] rob, input [UOPW-1:0] u,
                        input [SRC_N-1:0] rdy);
        begin
            @(negedge clk);
            wr_v[idx] = 1'b1;
            wr_uop[idx*4*UOPW +: UOPW] = u;
            wr_rob[idx*4*7 +: 7] = rob;
            wr_rdy[idx*4*SRC_N +: SRC_N] = rdy;
            @(posedge clk);
            @(negedge clk);
            wr_v[idx] = 1'b0;
        end
    endtask

    // 全体入队（6 个队列同拍）
    task automatic push_all(input [6:0] rob, input [UOPW-1:0] u, input [SRC_N-1:0] rdy);
        integer i;
        begin
            @(negedge clk);
            for (i = 0; i < NI; i = i + 1) begin
                wr_v[i] = 1'b1;
                wr_uop[i*4*UOPW +: UOPW] = u;
                wr_rob[i*4*7 +: 7] = rob;
                wr_rdy[i*4*SRC_N +: SRC_N] = rdy;
            end
            @(posedge clk);
            @(negedge clk);
            for (i = 0; i < NI; i = i + 1) wr_v[i] = 1'b0;
        end
    endtask

    integer i2;
    initial begin
        n_checks = 0;
        wr_v = {NI{1'b0}};
        wr_uop = {(NI*4*UOPW){1'b0}};
        wr_rob = {(NI*4*7){1'b0}};
        wr_rdy = {(NI*4*SRC_N){1'b0}};
        for (i2 = 0; i2 < NI; i2 = i2 + 1) rob_head[i2] = 7'd0;
        for (i2 = 0; i2 < NI; i2 = i2 + 1) epoch[i2] = 2'd0;
        flush_all = {NI{1'b0}};
        squash    = {NI{1'b0}};
        for (i2 = 0; i2 < NI; i2 = i2 + 1) squash_idx[i2] = 7'd0;
        for (i2 = 0; i2 < NI; i2 = i2 + 1) rob_cnt[i2] = 8'd128;   // 默认：窗口全开
        iss_ready = {NI{1'b1}};
        wki_v = {NI{6'b0}};
        wkf_v = {NI{6'b0}};

        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        //---- C1 空位计数 ----
        for (i2 = 0; i2 < NI; i2 = i2 + 1)
            chk(free_cnt[i2*5 +: 5] == dpt(i2), "C1 复位后 free_cnt == 深度");

        //---- C2 未就绪不发射 ----
        push_all(7'd1, mk_uop(7'd1, 7'd0, 6'd0, 6'd0, 6'd0, 1'b1, 1'b0, 1'b0, 1'b0, 1'b0, 32'hA1),
                 rdy_mask(1'b1, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b1, 1'b1, 1'b1, 1'b1));
        repeat (3) @(posedge clk);
        for (i2 = 0; i2 < NI; i2 = i2 + 1) begin
            chk(sel_v[i2] === 1'b0, "C2 源未就绪 ⇒ 无选择");
            chk(iss_v[i2] === 1'b0, "C2 源未就绪 ⇒ 无发射");
            chk(cnt_o[i2*5 +: 5] == 4'd1, "C2 队列内有 1 项");
        end

        //---- C3 唤醒广播：当拍即可被选出（iss_ready=0 时观察选择口）----
        iss_ready = {NI{1'b0}};
        @(negedge clk); wki_v = {NI{6'b000001}};       // 道 0 广播 tag=1（所有实例同激励）
        @(negedge clk);
        for (i2 = 0; i2 < NI; i2 = i2 + 1) begin
            chk(sel_v[i2] === 1'b1, $sformatf("C3 唤醒当拍即可选出（实例 %0d）", i2));
            chk(sel_rob[i2*7 +: 7] == 7'd1, "C3 选出的是被唤醒项");
            chk(iss_v[i2] === 1'b0, "C3 iss_ready=0 ⇒ 未出队");
            chk(cnt_o[i2*5 +: 5] == 5'd1, "C3 未出队 ⇒ 仍 1 项");
        end
        @(negedge clk); wki_v = {NI{6'b0}}; iss_ready = {NI{1'b1}};
        repeat (2) @(posedge clk);
        for (i2 = 0; i2 < NI; i2 = i2 + 1)
            chk(cnt_o[i2*5 +: 5] == 5'd0, "C3 发射后出队（队列空）");

        //---- C4 最老优先（3 条就绪项，年龄 5/3/4 ⇒ 选 3）----
        iss_ready = {NI{1'b0}};
        push_all(7'd5, mk_uop(7'd1, 7'd0, 6'd0, 6'd0, 6'd0, 1'b1,1'b0,1'b0,1'b0,1'b0, 32'h05),
                 rdy_mask(1'b1,1'b0,1'b0,1'b0,1'b0, 1'b1,1'b1,1'b1,1'b1,1'b1));
        push_all(7'd3, mk_uop(7'd1, 7'd0, 6'd0, 6'd0, 6'd0, 1'b1,1'b0,1'b0,1'b0,1'b0, 32'h03),
                 rdy_mask(1'b1,1'b0,1'b0,1'b0,1'b0, 1'b1,1'b1,1'b1,1'b1,1'b1));
        push_all(7'd4, mk_uop(7'd1, 7'd0, 6'd0, 6'd0, 6'd0, 1'b1,1'b0,1'b0,1'b0,1'b0, 32'h04),
                 rdy_mask(1'b1,1'b0,1'b0,1'b0,1'b0, 1'b1,1'b1,1'b1,1'b1,1'b1));
        repeat (2) @(posedge clk);
        for (i2 = 0; i2 < NI; i2 = i2 + 1) begin
            chk(sel_v[i2] === 1'b1, "C4 有就绪项 ⇒ 有选择");
            chk(sel_rob[i2*7 +: 7] == 7'd3, "C4 最老优先（选 rob=3）");
            chk(cnt_o[i2*5 +: 5] == 5'd3, "C4 三项均在队");
        end
        //---- C5 单端口：iss_ready=0 时选择稳定且不出队；恢复后逐拍排空 ----
        repeat (3) @(posedge clk);
        for (i2 = 0; i2 < NI; i2 = i2 + 1) begin
            chk(iss_v[i2] === 1'b0, "C5 iss_ready=0 ⇒ 不发射");
            chk(cnt_o[i2*5 +: 5] == 5'd3, "C5 不出队（仍 3 项）");
            chk(sel_rob[i2*7 +: 7] == 7'd3, "C5 选择稳定（最老项不变）");
        end
        iss_ready = {NI{1'b1}};
        repeat (5) @(posedge clk);
        for (i2 = 0; i2 < NI; i2 = i2 + 1)
            chk(cnt_o[i2*5 +: 5] == 5'd0, "C5 恢复后逐拍排空");

        //---- C6 rob 回绕（head=120，项 124/121/126 ⇒ 选 121）----
        iss_ready = {NI{1'b0}};
        for (i2 = 0; i2 < NI; i2 = i2 + 1) rob_head[i2] = 7'd120;
        push_all(7'd124, mk_uop(7'd2, 7'd0, 6'd0, 6'd0, 6'd0, 1'b1,1'b0,1'b0,1'b0,1'b0, 32'h124),
                 rdy_mask(1'b1,1'b0,1'b0,1'b0,1'b0, 1'b1,1'b1,1'b1,1'b1,1'b1));
        push_all(7'd121, mk_uop(7'd2, 7'd0, 6'd0, 6'd0, 6'd0, 1'b1,1'b0,1'b0,1'b0,1'b0, 32'h121),
                 rdy_mask(1'b1,1'b0,1'b0,1'b0,1'b0, 1'b1,1'b1,1'b1,1'b1,1'b1));
        push_all(7'd126, mk_uop(7'd2, 7'd0, 6'd0, 6'd0, 6'd0, 1'b1,1'b0,1'b0,1'b0,1'b0, 32'h126),
                 rdy_mask(1'b1,1'b0,1'b0,1'b0,1'b0, 1'b1,1'b1,1'b1,1'b1,1'b1));
        repeat (2) @(posedge clk);
        for (i2 = 0; i2 < NI; i2 = i2 + 1)
            chk(sel_rob[i2*7 +: 7] == 7'd121, "C6 回绕下最老优先（选 rob=121）");
        iss_ready = {NI{1'b1}};
        repeat (6) @(posedge clk);
        for (i2 = 0; i2 < NI; i2 = i2 + 1) rob_head[i2] = 7'd0;

        //---- C7 冲刷按序号作废：只杀比 squash_idx 更年轻的项 ----
        //   ★ 回归要点（实测缺陷）：ROB 冲刷会**保留**比分支更老的项，这些项可能
        //     还在队列里等唤醒。若队列按 epoch 一律丢弃"过期项"，它们就永远不发射、
        //     永不写回 ⇒ ROB 头 hdone=0 永久卡死。故判据 = 更老项**照常发射**。
        iss_ready = {NI{1'b0}};
        // 三条都挂在 tag=1 的源上（等唤醒），ROB 序号 20/21/22
        push_all(7'd20, mk_uop(7'd1, 7'd0, 6'd0, 6'd0, 6'd0, 1'b1,1'b0,1'b0,1'b0,1'b0, 32'h20),
                 rdy_mask(1'b1,1'b0,1'b0,1'b0,1'b0, 1'b0,1'b1,1'b1,1'b1,1'b1));
        push_all(7'd21, mk_uop(7'd1, 7'd0, 6'd0, 6'd0, 6'd0, 1'b1,1'b0,1'b0,1'b0,1'b0, 32'h21),
                 rdy_mask(1'b1,1'b0,1'b0,1'b0,1'b0, 1'b0,1'b1,1'b1,1'b1,1'b1));
        push_all(7'd22, mk_uop(7'd1, 7'd0, 6'd0, 6'd0, 6'd0, 1'b1,1'b0,1'b0,1'b0,1'b0, 32'h22),
                 rdy_mask(1'b1,1'b0,1'b0,1'b0,1'b0, 1'b0,1'b1,1'b1,1'b1,1'b1));
        repeat (2) @(posedge clk);
        for (i2 = 0; i2 < NI; i2 = i2 + 1)
            chk(cnt_o[i2*5 +: 5] == 5'd3, "C7 三项在队");
        // 冲刷：squash_idx = 21（分支自身保留；22 更年轻 ⇒ 作废）
        @(negedge clk);
        for (i2 = 0; i2 < NI; i2 = i2 + 1) begin
            squash[i2] = 1'b1; squash_idx[i2] = 7'd21;
        end
        @(negedge clk);
        for (i2 = 0; i2 < NI; i2 = i2 + 1) squash[i2] = 1'b0;
        repeat (1) @(posedge clk);
        for (i2 = 0; i2 < NI; i2 = i2 + 1) begin
            chk(cnt_o[i2*5 +: 5] == 5'd2, $sformatf("C7 只作废比 squash_idx 更年轻的项（实测 cnt=%0d）", cnt_o[i2*5 +: 5]));
            chk(sel_v[i2] === 1'b0, "C7 保留项仍未就绪 ⇒ 不得投机选出");
        end
        // 唤醒 tag=1（道 0）⇒ 保留的两项都就绪，最老者（20）先出队，且**不标 dead**
        iss_ready = {NI{1'b1}};
        @(negedge clk); wki_v = {NI{6'b000001}};
        repeat (1) @(posedge clk);
        @(negedge clk); wki_v = {NI{6'b0}};
        for (i2 = 0; i2 < NI; i2 = i2 + 1) begin
            chk(cnt_o[i2*5 +: 5] == 5'd1, "C7 更老的两项之一已发射（2→1）");
            chk(iss_dead[i2] === 1'b0, "C7 保留项不得标 dead（必须真正执行）");
        end
        repeat (3) @(posedge clk);
        for (i2 = 0; i2 < NI; i2 = i2 + 1)
            chk(cnt_o[i2*5 +: 5] == 5'd0, "C7 保留项全部发射完（队列空）");

        //---- C8 无活锁：连续 200 拍随机唤醒 ⇒ 排空时间有界 ----
        begin : live_lock
            integer t, k;
            for (k = 0; k < 12; k = k + 1) begin
                @(negedge clk);
                push_all(k[6:0] + 7'd20,
                         mk_uop((k % 5) + 7'd1, 7'd0, 6'd0, 6'd0, 6'd0,
                                1'b1, 1'b0, 1'b0, 1'b0, 1'b0, 32'h200 + k),
                         rdy_mask(1'b1,1'b0,1'b0,1'b0,1'b0, 1'b0,1'b1,1'b1,1'b1,1'b1));
            end
            // 全部唤醒
            @(negedge clk); wki_v = {NI{6'b111111}};
            t = 0;
            while ((cnt_o[0*5 +: 5] != 4'd0) && (t < 200)) begin
                @(posedge clk); t = t + 1;
            end
            chk(t < 200, "C8 唤醒后队列在有界拍数内排空（无活锁）");
            for (i2 = 0; i2 < NI; i2 = i2 + 1)
                chk(cnt_o[i2*5 +: 5] == 4'd0, "C8 全部队列排空");
        end

        //---- C9 flush_all ----
        push_all(7'd30, mk_uop(7'd1, 7'd0, 6'd0, 6'd0, 6'd0, 1'b1,1'b0,1'b0,1'b0,1'b0, 32'h30),
                 rdy_mask(1'b1,1'b0,1'b0,1'b0,1'b0, 1'b0,1'b1,1'b1,1'b1,1'b1));
        push_all(7'd31, mk_uop(7'd1, 7'd0, 6'd0, 6'd0, 6'd0, 1'b1,1'b0,1'b0,1'b0,1'b0, 32'h31),
                 rdy_mask(1'b1,1'b0,1'b0,1'b0,1'b0, 1'b0,1'b1,1'b1,1'b1,1'b1));
        @(negedge clk); flush_all = {NI{1'b1}};
        @(posedge clk); @(negedge clk); flush_all = {NI{1'b0}};
        repeat (2) @(posedge clk);
        for (i2 = 0; i2 < NI; i2 = i2 + 1)
            chk(cnt_o[i2*5 +: 5] == 4'd0, "C9 flush_all 清空队列");

        $display("== 检查项合计 %0d 项全部满足（6 个队列 × 深度 %0d/%0d/%0d/%0d/%0d/%0d）",
                 n_checks, D0, D1, D2, D3, D4, D5);
        $display("TB_BACK2_IQ: PASS");
        $finish;
    end

    initial begin
        #(CLK_P * 2000000);
        $display("FAIL: TB 超时");
        $fatal(1, "TB_BACK2_IQ 超时");
    end

endmodule
