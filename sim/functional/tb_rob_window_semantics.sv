//==============================================================================
// sim/functional/tb_rob_window_semantics.sv —— ROB 头部窗口语义定向单测
//==============================================================================
// 项目 : rv32gc-cpu（阶段二后端 / P1「ROB 窗口接收未分配槽旧宽存数据」根修）
//
// 【被测对象】`rtl/back2/rob.v` + `rtl/back2/rob_wide_mem.v`（真实 RTL，非镜像窗口实现）。
//
// 【独立参考模型（不复用 DUT 的窗口逻辑）】
//   · 维护一张"代数队列"：q_pc/q_exc/q_live/q_ac[idx]（idx = 绝对 ROB 索引）；
//   · 分配：按**观测到的 alloc_fire** 把 payload 记入 old_tail 连续项；
//   · 提交：按**观测到的 cmt_valid 前缀**弹出，并逐 lane 比对 `cmt_payload.PC`
//     == q_pc[idx]；若 DUT 在空/越界/错项上提交 ⇒ 直接失配；
//   · trap：`trap_pc/trap_cause` 必须等于 q_pc/q_exc[m_head]；
//   · 指针：head/cnt 逐拍与模型比对（模型只按 DUT 的 cmt/flush/squash 语义推进，
//     不消费窗口内部信号）。
//
// 【根因不变式（P1 的真实证据，不是"输出非空"）】
//   对每个**本拍真正在提交组内**的窗口槽（slot < cnt）：
//     若 `win_val[slot]` 为 1 且 `win_idx[slot]` 命中该槽目标索引，则该索引的
//     最近一次 alloc 必须发生在 **≥2 拍之前**（alloc 沿 A ⇒ 读命令沿 ≥A+1 ⇒
//     当前 ≥A+2）。否则说明窗口吃进了"读命令早于 alloc"的旧 BRAM 载荷 —— 这正是
//     旧实现只比 index（fhit/win_val）而不看读命令拍 live 的根因。
//   该检查在 fixed RTL 上必须恒 0 次；反证候选（去掉 e_ok/e_bad 门）会命中。
//
// 【四态覆盖（每拍分类，汇总打印）】
//   empty : cnt==0（窗口内容一律不得当 PC 用）
//   hit   : cnt>0 且 win_lane_ok[0]（窗口命中且已过 e_ok/e_bad）⇒ head_pc_valid 必须 1
//   miss  : cnt>0 但窗口未命中（标签失配/未填/RAW 丢弃）⇒ head_pc_valid 必须 0
//   raw   : 上述"在提交组内但 alloc 龄 <2"的非法有效窗口 ⇒ 必须 0 次
//   ★ case8（squash 跨代）在 warm-up 段用 win_check_en=0 隔离"通用未分配旧值"根因
//     （case1..7 已覆盖），开闸后**逐拍**检查 head_pc_valid/PC 与 RAW 龄；case9 为
//     同族正控（squash 保留读目标 idx1，旧/新候选都必须绿）。
//
// 【用例/锚点】脚本 `test_rob_window.sh` 逐 `+CASE=<n>` 独立进程运行；本 TB 只打印
//   恰好一行 `CASE <n> <name> KIND=<trigger|control> VERDICT=<OK|DEFECT_SIG> nchk=<N>`，
//   失配诊断一律用 `MISMATCH`（不打印 FAIL，避免与总入口判定混淆）。
//==============================================================================
`timescale 1ns / 1ps

`include "rtl/back2/back2_params.vh"

module tb_rob_window_semantics;

    localparam integer ROB_N   = `BACK2_ROB_N;          // 64
    localparam integer IDX_W   = `BACK2_ROB_IDX_W;      // 6
    localparam integer ALLOC_W = `BACK2_ALLOC_W;        // 4
    localparam integer CMT_W   = `BACK2_COMMIT_W;       // 2
    localparam integer RB_W    = `BACK2_RB_W;           // 225
    localparam integer WB_N    = 7;                     // 与 backend_top 实际例化一致
    localparam integer POISON  = 32'hA5A5_0000;

    //==========================================================================
    // 0. DUT 端口
    //==========================================================================
    reg clk = 1'b0;
    reg rst_n = 1'b0;

    reg                     alloc_valid;
    reg  [2:0]              alloc_n;
    reg  [ALLOC_W-1:0]      alloc_lane_valid;
    reg  [ALLOC_W*RB_W-1:0] alloc_payload;
    reg  [`BACK2_EPOCH_W-1:0] alloc_epoch;

    reg  [WB_N-1:0]                      wb_valid;
    reg  [WB_N*IDX_W-1:0]                wb_rob_idx;
    reg  [WB_N*`BACK2_EPOCH_W-1:0]       wb_epoch;

    reg                     upd_tr_valid;   reg [IDX_W-1:0] upd_tr_idx;
    reg                     upd_tr_taken;   reg [31:0]      upd_tr_target;
    reg                     upd_ff_valid;   reg [IDX_W-1:0] upd_ff_idx;
    reg  [4:0]              upd_ff_flags;
    reg                     upd_exc_valid;  reg [IDX_W-1:0] upd_exc_idx;
    reg  [3:0]              upd_exc_code;   reg [31:0]      upd_exc_tval;

    reg                     mem_wr_ready;
    reg  [IDX_W-1:0]        csr_lane_idx;
    reg  [ALLOC_W*5-1:0]    alloc_pre;

    reg                     squash_valid;
    reg  [IDX_W-1:0]        squash_idx;
    reg                     flush_all;
    reg                     trap_retire;

    wire [CMT_W-1:0]        cmt_valid;
    wire [CMT_W*RB_W-1:0]   cmt_payload;
    wire [CMT_W*`BACK2_NQ_W-1:0] cmt_narrow;
    wire [`BACK2_CMT_CSR_W-1:0]  csr_pay;
    wire [CMT_W-1:0]        cmt_st_drain, cmt_st_ckpt, cmt_st_branch;
    wire                    alloc_ready;
    wire [IDX_W-1:0]        alloc_idx0;

    wire                    trap_valid;
    wire [31:0]             trap_pc;
    wire [3:0]              trap_cause;
    wire [31:0]             trap_tval;
    wire                    head_pc_valid_o;

    wire [IDX_W-1:0]        head_o;
    wire [IDX_W:0]          cnt_o;
    wire [IDX_W-1:0]        squash_age_o;
    wire                    empty_o, head_done_o;
    wire [3:0]              head_exc_o;
    wire [31:0]             cmt_cnt_o;
    wire [`BACK2_EPOCH_W-1:0] epoch_o;

    rob #(.WB_N(WB_N)) u_dut (
        .clk(clk), .rst_n(rst_n),
        .alloc_valid(alloc_valid), .alloc_n(alloc_n),
        .alloc_ready(alloc_ready), .alloc_idx0(alloc_idx0),
        .alloc_lane_valid(alloc_lane_valid), .alloc_payload(alloc_payload),
        .alloc_epoch(alloc_epoch), .alloc_pre(alloc_pre),
        .wb_valid(wb_valid), .wb_rob_idx(wb_rob_idx), .wb_epoch(wb_epoch),
        .upd_tr_valid(upd_tr_valid), .upd_tr_idx(upd_tr_idx),
        .upd_tr_taken(upd_tr_taken), .upd_tr_target(upd_tr_target),
        .upd_ff_valid(upd_ff_valid), .upd_ff_idx(upd_ff_idx), .upd_ff_flags(upd_ff_flags),
        .upd_exc_valid(upd_exc_valid), .upd_exc_idx(upd_exc_idx),
        .upd_exc_code(upd_exc_code), .upd_exc_tval(upd_exc_tval),
        .mem_wr_ready(mem_wr_ready),
        .cmt_valid(cmt_valid), .cmt_payload(cmt_payload), .cmt_narrow(cmt_narrow),
        .csr_lane_idx(csr_lane_idx), .csr_pay(csr_pay),
        .cmt_st_drain(cmt_st_drain), .cmt_st_ckpt(cmt_st_ckpt), .cmt_st_branch(cmt_st_branch),
        .trap_valid(trap_valid), .trap_pc(trap_pc),
        .trap_cause(trap_cause), .trap_tval(trap_tval),
        .head_pc_valid_o(head_pc_valid_o),
        .squash_valid(squash_valid), .squash_idx(squash_idx),
        .flush_all(flush_all), .trap_retire(trap_retire),
        .head_o(head_o), .cnt_o(cnt_o), .squash_age_o(squash_age_o),
        .empty_o(empty_o), .head_done_o(head_done_o), .head_exc_o(head_exc_o),
        .cmt_cnt_o(cmt_cnt_o), .epoch_o(epoch_o)
    );

    always #5 clk = ~clk;

    //==========================================================================
    // 1. 独立参考模型（代数队列；不读窗口内部状态）
    //==========================================================================
    reg  [31:0] q_pc  [0:ROB_N-1];
    reg  [3:0]  q_exc [0:ROB_N-1];
    reg         q_live[0:ROB_N-1];
    integer     q_ac  [0:ROB_N-1];

    integer m_head, m_cnt, cyc, committed;
    integer errs, nchk, errs_dumped;
    integer st_empty, st_hit, st_miss, st_raw;
    //   ★★ 独审补洞用例（case8/9）的 warm-up 门：只对"架构可消费的窗口"做逐拍
    //      head_pc_valid/PC 与 RAW 龄检查。warm-up 段关闭该门是为了把“旧实现的通用
    //      未分配旧值根因”（已由 case1..7 覆盖）与“squash 跨代根因”（case8）隔离；
    //      warm-up 只做 alloc 且 done 延迟，窗口刷新后立刻开闸，squash 交错段逐拍检查。
    integer win_check_en;

    // 完成队列：alloc 之后逐拍最多 7 项置 done
    integer dq [0:255];
    integer dq_h, dq_t;

    // 每拍锁存的 DUT 输出/输入条件（check 后、posedge 后据此推进模型）
    reg [CMT_W-1:0] l_cmt;
    reg             l_trv;
    reg [31:0]      l_trpc;
    reg [3:0]       l_trcause;
    reg             l_hpv;
    reg             l_flush, l_squash, l_tr;
    reg [IDX_W-1:0] l_sqidx;
    reg             l_alloc_fire;
    integer         l_alloc_n, l_pop;
    integer         l_new_idx [0:ALLOC_W-1];

    //==========================================================================
    // 2. 基础工具
    //==========================================================================
    function [31:0] pc_of(input [RB_W-1:0] p);
        pc_of = p[`BACK2_RB_PC_MSB:`BACK2_RB_PC_LSB];
    endfunction

    function [3:0] exc_of(input [RB_W-1:0] p);
        exc_of = p[`BACK2_RB_EXC_MSB:`BACK2_RB_EXC_LSB];
    endfunction

    function [CMT_W-1:0] pop_to_mask(input integer n);
        if (n <= 0)      pop_to_mask = 2'b00;
        else if (n == 1) pop_to_mask = 2'b01;
        else             pop_to_mask = 2'b11;
    endfunction

    task automatic set_payload(input integer lane, input [31:0] pc,
                               input [3:0] exc, input is_st, input is_br);
        reg [RB_W-1:0] p;
        begin
            p = {RB_W{1'b0}};
            p[`BACK2_RB_PC_MSB:`BACK2_RB_PC_LSB] = pc;
            p[`BACK2_RB_EXC_MSB:`BACK2_RB_EXC_LSB] = exc;
            p[`BACK2_UB_IS_STORE]  = is_st;
            p[`BACK2_UB_IS_BRANCH] = is_br;
            p[`BACK2_RB_TVAL_MSB:`BACK2_RB_TVAL_LSB] = 32'h0;
            alloc_payload[lane*RB_W +: RB_W] = p;
        end
    endtask

    task automatic push_done(input integer idx);
        begin
            if (dq_t < 256) begin
                dq[dq_t] = idx;
                dq_t = dq_t + 1;
            end
        end
    endtask

    task automatic drive_wb;
        integer j;
        begin
            wb_valid = {WB_N{1'b0}};
            wb_rob_idx = {(WB_N*IDX_W){1'b0}};
            wb_epoch   = {(WB_N*`BACK2_EPOCH_W){1'b0}};
            for (j = 0; j < WB_N; j = j + 1) begin
                if (dq_h < dq_t) begin
                    wb_valid[j] = 1'b1;
                    wb_rob_idx[j*IDX_W +: IDX_W] = dq[dq_h][IDX_W-1:0];
                    wb_epoch[j*`BACK2_EPOCH_W +: `BACK2_EPOCH_W] = {`BACK2_EPOCH_W{1'b0}};
                    dq_h = dq_h + 1;
                end
            end
        end
    endtask

    task automatic note_mismatch(input [8*96-1:0] what);
        begin
            errs = errs + 1;
            if (errs_dumped < 24) begin
                errs_dumped = errs_dumped + 1;
                $display("MISMATCH case=%0d cyc=%0d %0s", case_sel, cyc, what);
            end
        end
    endtask

    //==========================================================================
    // 3. 逐拍检查（negdege：DUT 组合输出稳定；模型仍是本拍状态）
    //==========================================================================
    task automatic latch_cycle;
        begin
            l_cmt        = cmt_valid;
            l_trv        = trap_valid;
            l_trpc       = trap_pc;
            l_trcause    = trap_cause;
            l_hpv        = head_pc_valid_o;
            l_flush      = flush_all;
            l_squash     = squash_valid;
            l_tr         = trap_retire;
            l_sqidx      = squash_idx;
            l_alloc_n    = alloc_n;
            l_pop        = (cmt_valid[0] ? 1 : 0) + (CMT_W > 1 && cmt_valid[1] ? 1 : 0);
            //   DUT 的 alloc_fire 口径（rob.v §2）：room = N − (cnt − cmt_n)
            l_alloc_fire = alloc_valid &&
                           ((ROB_N - ({1'b0, cnt_o} - l_pop)) >= alloc_n);
        end
    endtask

    task automatic check_cycle;
        integer gi, k, idx, age, target;
        reg [31:0] gotpc;
        begin
            nchk = nchk + 1;

            // ---- 3.1 指针/空标志 ----
            if ({1'b0, head_o} !== m_head[IDX_W:0]) begin
                errs = errs + 1;
                if (errs_dumped < 24) begin errs_dumped = errs_dumped + 1;
                    $display("MISMATCH case=%0d cyc=%0d head got=%0d exp=%0d",
                             case_sel, cyc, head_o, m_head); end
            end
            if ({1'b0, cnt_o} !== m_cnt) begin
                errs = errs + 1;
                if (errs_dumped < 24) begin errs_dumped = errs_dumped + 1;
                    $display("MISMATCH case=%0d cyc=%0d cnt got=%0d exp=%0d",
                             case_sel, cyc, cnt_o, m_cnt); end
            end
            if (empty_o !== (m_cnt == 0)) begin
                errs = errs + 1;
                if (errs_dumped < 24) begin errs_dumped = errs_dumped + 1;
                    $display("MISMATCH case=%0d cyc=%0d empty_o=%b cnt=%0d",
                             case_sel, cyc, empty_o, m_cnt); end
            end

            // ---- 3.2 提交：前缀连续 + 逐 lane 载荷比对 ----
            if (cmt_valid !== pop_to_mask(l_pop)) begin
                errs = errs + 1;
                if (errs_dumped < 24) begin errs_dumped = errs_dumped + 1;
                    $display("MISMATCH case=%0d cyc=%0d cmt not prefix cmt=%b pop=%0d",
                             case_sel, cyc, cmt_valid, l_pop); end
            end
            for (gi = 0; gi < CMT_W; gi = gi + 1) begin
                if (l_cmt[gi]) begin
                    nchk = nchk + 1;
                    if (gi >= m_cnt) begin
                        errs = errs + 1;
                        if (errs_dumped < 24) begin errs_dumped = errs_dumped + 1;
                            $display("MISMATCH case=%0d cyc=%0d commit lane=%0d on empty model (cnt=%0d)",
                                     case_sel, cyc, gi, m_cnt); end
                    end else begin
                        idx = (m_head + gi) & (ROB_N-1);
                        gotpc = pc_of(cmt_payload[gi*RB_W +: RB_W]);
                        if (q_live[idx] !== 1'b1) begin
                            errs = errs + 1;
                            if (errs_dumped < 24) begin errs_dumped = errs_dumped + 1;
                                $display("MISMATCH case=%0d cyc=%0d commit lane=%0d idx=%0d not live",
                                         case_sel, cyc, gi, idx); end
                        end
                        if (gotpc !== q_pc[idx]) begin
                            errs = errs + 1;
                            if (errs_dumped < 24) begin errs_dumped = errs_dumped + 1;
                                $display("MISMATCH case=%0d cyc=%0d commit lane=%0d idx=%0d got_pc=%h exp_pc=%h",
                                         case_sel, cyc, gi, idx, gotpc, q_pc[idx]); end
                        end
                    end
                end
            end

            // ---- 3.3 trap：PC/cause 必须是当前头项的真实载荷 ----
            if (l_trv) begin
                nchk = nchk + 1;
                if (m_cnt <= 0) begin
                    errs = errs + 1;
                    if (errs_dumped < 24) begin errs_dumped = errs_dumped + 1;
                        $display("MISMATCH case=%0d cyc=%0d trap_valid on empty ROB", case_sel, cyc); end
                end else begin
                    if (l_trpc !== q_pc[m_head & (ROB_N-1)]) begin
                        errs = errs + 1;
                        if (errs_dumped < 24) begin errs_dumped = errs_dumped + 1;
                            $display("MISMATCH case=%0d cyc=%0d trap pc got=%h exp=%h",
                                     case_sel, cyc, l_trpc, q_pc[m_head & (ROB_N-1)]); end
                    end
                    if (l_trcause !== q_exc[m_head & (ROB_N-1)]) begin
                        errs = errs + 1;
                        if (errs_dumped < 24) begin errs_dumped = errs_dumped + 1;
                            $display("MISMATCH case=%0d cyc=%0d trap cause got=%0d exp=%0d",
                                     case_sel, cyc, l_trcause, q_exc[m_head & (ROB_N-1)]); end
                    end
                end
            end

            // ---- 3.4 head_pc_valid：为 1 ⇒ 真实头 PC 可安全采样 ----
            if (win_check_en && l_hpv) begin
                nchk = nchk + 1;
                if (m_cnt <= 0) begin
                    errs = errs + 1;
                    if (errs_dumped < 24) begin errs_dumped = errs_dumped + 1;
                        $display("MISMATCH case=%0d cyc=%0d head_pc_valid=1 on empty ROB",
                                 case_sel, cyc); end
                end else if (l_trpc !== q_pc[m_head & (ROB_N-1)]) begin
                    errs = errs + 1;
                    if (errs_dumped < 24) begin errs_dumped = errs_dumped + 1;
                        $display("MISMATCH case=%0d cyc=%0d head_pc_valid=1 but PC stale got=%h exp=%h",
                                 case_sel, cyc, l_trpc, q_pc[m_head & (ROB_N-1)]); end
                end
            end

            // ---- 3.5 窗口四态 + RAW 根因不变式 ----
            if (win_check_en)
            for (k = 0; k < CMT_W; k = k + 1) begin
                target = (m_head + k) & (ROB_N-1);
                if ((u_dut.win_val[k] === 1'b1) &&
                    (u_dut.win_idx[k] === target[IDX_W-1:0])) begin
                    nchk = nchk + 1;
                    //   只有"在该槽真正属于本拍提交组"时才要求语义正确；
                    //   slot1 在 cnt==1 时可能是已杀项（slot_in_range 已挡住），不算错。
                    if (k < m_cnt) begin
                        if (q_live[target] !== 1'b1) begin
                            errs = errs + 1;
                            if (errs_dumped < 24) begin errs_dumped = errs_dumped + 1;
                                $display("MISMATCH case=%0d cyc=%0d win slot=%0d idx=%0d valid but not live",
                                         case_sel, cyc, k, target); end
                        end else begin
                            age = cyc - q_ac[target];
                            if (age < 2) begin
                                st_raw = st_raw + 1;
                                errs = errs + 1;
                                if (errs_dumped < 24) begin errs_dumped = errs_dumped + 1;
                                    $display("MISMATCH case=%0d cyc=%0d RAW win slot=%0d idx=%0d age=%0d (<2) pc=%h",
                                             case_sel, cyc, k, target, age, pc_of(u_dut.win_q[k])); end
                            end
                        end
                    end
                end
            end

            //   四态（槽 0 = 头项；只统计，判决看上面的硬检查）
            if (m_cnt == 0)              st_empty = st_empty + 1;
            else if (u_dut.win_lane_ok[0] === 1'b1) st_hit = st_hit + 1;
            else                         st_miss = st_miss + 1;
        end
    endtask

    //==========================================================================
    // 4. 模型推进（posedge 后；只消费"本拍锁存"的 DUT 输出语义）
    //==========================================================================
    task automatic update_model;
        integer i, k, idx, age;
        begin
            if (l_flush) begin
                for (i = 0; i < ROB_N; i = i + 1) q_live[i] = 1'b0;
                m_cnt = 0;
                m_head = l_tr ? ((m_head + 1) & (ROB_N-1)) : 0;
            end else if (l_squash) begin
                age = (l_sqidx - m_head[IDX_W-1:0]) & (ROB_N-1);
                m_cnt = age + 1;
                for (i = 0; i < ROB_N; i = i + 1)
                    if ((((i - m_head) & (ROB_N-1))) >= m_cnt) q_live[i] = 1'b0;
            end else begin
                m_head = (m_head + l_pop) & (ROB_N-1);
                m_cnt  = m_cnt - l_pop;
                if (l_alloc_fire) begin
                    for (k = 0; k < l_alloc_n; k = k + 1) begin
                        if (alloc_lane_valid[k]) begin
                            idx = (m_head + m_cnt) & (ROB_N-1);
                            q_pc[idx]  = pc_of(alloc_payload[k*RB_W +: RB_W]);
                            q_exc[idx] = exc_of(alloc_payload[k*RB_W +: RB_W]);
                            q_live[idx] = 1'b1;
                            q_ac[idx]  = cyc;
                            l_new_idx[k] = idx;
                            m_cnt = m_cnt + 1;
                        end
                    end
                end
                committed = committed + l_pop;
            end
        end
    endtask

    task automatic step;
        begin
            drive_wb();
            @(negedge clk); #1;
            latch_cycle();
            check_cycle();
            @(posedge clk); #1;
            update_model();
            cyc = cyc + 1;
        end
    endtask

    //==========================================================================
    // 5. 刺激原语
    //==========================================================================
    task automatic alloc_group_core(input integer n, input [31:0] pcbase,
                                    input [3:0] exc, input is_st, input is_br,
                                    input integer do_done);
        integer k, guard, fired;
        begin
            alloc_valid      = 1'b1;
            alloc_n          = n[2:0];
            alloc_lane_valid = (1 << n) - 1;
            for (k = 0; k < ALLOC_W; k = k + 1) begin
                if (k < n) set_payload(k, pcbase + 4*k, exc, is_st, is_br);
                else       set_payload(k, 32'h0, 4'd0, 1'b0, 1'b0);
            end
            guard = 0; fired = 0;
            while (!fired && guard < 200) begin
                step();
                if (l_alloc_fire) begin
                    fired = 1;
                    if (do_done)
                        for (k = 0; k < n; k = k + 1) push_done(l_new_idx[k]);
                end
                guard = guard + 1;
            end
            alloc_valid      = 1'b0;
            alloc_n          = 3'd0;
            alloc_lane_valid = {ALLOC_W{1'b0}};
            if (!fired) note_mismatch("alloc never fired (room/starvation)");
        end
    endtask

    //   正常分配：分配后立即把各 lane 置 done
    task automatic alloc_group(input integer n, input [31:0] pcbase,
                               input [3:0] exc, input is_st, input is_br);
        begin
            alloc_group_core(n, pcbase, exc, is_st, is_br, 1'b1);
        end
    endtask

    //   延迟 done：只分配、不置 done（给窗口足够时间在 alloc 后重读；
    //   用于 case8/9 的 warm-up 与"读前已 live"前置条件）
    task automatic alloc_group_nd(input integer n, input [31:0] pcbase,
                                  input [3:0] exc, input is_st, input is_br);
        begin
            alloc_group_core(n, pcbase, exc, is_st, is_br, 1'b0);
        end
    endtask

    task automatic do_flush(input tr);
        begin
            flush_all   = 1'b1;
            trap_retire = tr;
            step();
            flush_all   = 1'b0;
            trap_retire = 1'b0;
        end
    endtask

    task automatic do_squash(input [IDX_W-1:0] idx);
        begin
            squash_valid = 1'b1;
            squash_idx   = idx;
            step();
            squash_valid = 1'b0;
            squash_idx   = {IDX_W{1'b0}};
        end
    endtask

    task automatic wait_commits(input integer target, input integer maxsteps);
        integer guard;
        begin
            guard = 0;
            while (committed < target && guard < maxsteps) begin
                step();
                guard = guard + 1;
            end
            if (committed < target) note_mismatch("timeout waiting commits");
        end
    endtask

    task automatic wait_trap(input integer maxsteps);
        integer guard;
        begin
            guard = 0;
            while (!trap_valid && guard < maxsteps) begin
                step();
                guard = guard + 1;
            end
            if (!trap_valid) note_mismatch("timeout waiting trap");
        end
    endtask

    //==========================================================================
    // 6. 复位/初始化
    //==========================================================================
    task automatic do_reset;
        integer i, t;
        begin
            rst_n = 1'b0;
            alloc_valid = 1'b0; alloc_n = 3'd0; alloc_lane_valid = 4'd0;
            alloc_payload = {(ALLOC_W*RB_W){1'b0}}; alloc_epoch = 2'd0;
            alloc_pre = {(ALLOC_W*5){1'b0}};
            wb_valid = {WB_N{1'b0}}; wb_rob_idx = {(WB_N*IDX_W){1'b0}};
            wb_epoch = {(WB_N*`BACK2_EPOCH_W){1'b0}};
            upd_tr_valid = 0; upd_tr_idx = 0; upd_tr_taken = 0; upd_tr_target = 0;
            upd_ff_valid = 0; upd_ff_idx = 0; upd_ff_flags = 0;
            upd_exc_valid = 0; upd_exc_idx = 0; upd_exc_code = 0; upd_exc_tval = 0;
            mem_wr_ready = 1'b1; csr_lane_idx = {IDX_W{1'b0}};
            squash_valid = 0; squash_idx = 0; flush_all = 0; trap_retire = 0;
            m_head = 0; m_cnt = 0; cyc = 0; committed = 0;
            dq_h = 0; dq_t = 0;
            win_check_en = 1;
            for (i = 0; i < ROB_N; i = i + 1) begin
                q_pc[i] = 32'h0; q_exc[i] = 4'd0; q_live[i] = 1'b0; q_ac[i] = -1;
            end
            for (t = 0; t < 4; t = t + 1) step();
            rst_n = 1'b1;
            step();
        end
    endtask

    //==========================================================================
    // 7. 用例
    //==========================================================================
    integer case_sel;
    reg [8*28-1:0] cname;
    reg [8*8-1:0]  ckind;

    function is_trigger(input integer c);
        //   case0（完全不分配）与 case9（squash 保留读目标 idx1 的同族正控）是
        //   "两版都正确"的对照；其余用例把 alloc/读回打到旧载荷/杀伤代际上 ⇒
        //   旧窗口实现必然把它们标成有效（根因），全部是 trigger（旧红/新绿）。
        //   case4/case6 在新树上分别承担回滚正确性与 16 拍 2 条/拍正控。
        case (c)
            0, 9, 10: is_trigger = 1'b0;
            default: is_trigger = 1'b1;
        endcase
    endfunction

    //   case0：空 ROB 时窗口内容一律不得当 PC（含预取旧数据拍）
    task automatic c_empty;
        integer t;
        begin
            cname = "empty_no_stale_pc";
            for (t = 0; t < 10; t = t + 1) begin
                step();
                if (head_pc_valid_o !== 1'b0) begin
                    errs = errs + 1;
                    if (errs_dumped < 24) begin errs_dumped = errs_dumped + 1;
                        $display("MISMATCH case=0 cyc=%0d head_pc_valid=1 while cnt=0", cyc); end
                end
                nchk = nchk + 1;
            end
        end
    endtask

    //   case1：p8 形态 —— 先写旧程序载荷 → flush → 空窗预取旧数据 → 同槽再 alloc。
    //          旧 data 绝不能被提交；新项必须等到"分配后重读"的窗口才可提交。
    task automatic c_stale_realloc;
        integer t;
        begin
            cname = "prefetch_stale_realloc";
            alloc_group(4, 32'hA000_0000, 4'd0, 1'b0, 1'b0);
            wait_commits(4, 60);
            do_flush(1'b0);
            for (t = 0; t < 6; t = t + 1) begin
                step();
                if (head_pc_valid_o !== 1'b0) begin
                    errs = errs + 1;
                    if (errs_dumped < 24) begin errs_dumped = errs_dumped + 1;
                        $display("MISMATCH case=1 cyc=%0d head_pc_valid=1 after flush/empty", cyc); end
                end
                nchk = nchk + 1;
            end
            alloc_group(4, 32'hB000_0000, 4'd0, 1'b0, 1'b0);
            wait_commits(8, 80);
        end
    endtask

    //   case2：浅 ROB 连续 alloc/commit（预取目标频繁落在未分配 tail；RAW 高发）。
    task automatic c_shallow_race;
        integer t, base;
        begin
            cname = "shallow_alloc_raw";
            for (t = 0; t < 24; t = t + 1) begin
                base = 32'hC000_0000 + t*16;
                alloc_group(1, base, 4'd0, 1'b0, 1'b0);
                wait_commits(committed + 1, 30);
                if (t == 7 || t == 15) do_flush(1'b0);
            end
        end
    endtask

    //   case3：索引 60..63 → 0..3 环绕；组内 flush 后同槽复用。
    task automatic c_wrap_reuse;
        integer t;
        begin
            cname = "wrap_flush_reuse";
            for (t = 0; t < 15; t = t + 1) begin
                alloc_group(4, 32'hD000_0000 + t*16, 4'd0, 1'b0, 1'b0);
                wait_commits(4*(t+1), 200);
            end
            alloc_group(4, 32'hE000_0000, 4'd0, 1'b0, 1'b0);   // 60..63
            alloc_group(4, 32'hE000_0010, 4'd0, 1'b0, 1'b0);   // 0..3（wrap）
            wait_commits(committed + 8, 120);
            alloc_group(4, 32'hE000_0020, 4'd0, 1'b0, 1'b0);   // 4..7（尚未提交）
            do_flush(1'b0);
            for (t = 0; t < 4; t = t + 1) step();
            alloc_group(4, 32'hE000_0030, 4'd0, 1'b0, 1'b0);   // 0..3 复用
            wait_commits(committed + 4, 80);
        end
    endtask

    //   case4：squash 回滚（保留 [head, squash_idx]），被杀项绝不能再提交；之后复用。
    task automatic c_squash;
        integer t;
        begin
            cname = "squash_kill_reuse";
            alloc_group(4, 32'hF000_0000, 4'd0, 1'b0, 1'b0);
            do_squash(6'd1);                    // 保留 0/1，杀 2/3
            wait_commits(committed + 2, 60);
            alloc_group(4, 32'hF000_0010, 4'd0, 1'b0, 1'b0);   // 2..5 复用
            wait_commits(committed + 4, 80);
            for (t = 0; t < 2; t = t + 1) step();
        end
    endtask

    //   case5：头部异常项 —— trap PC 必须来自分配后的载荷（旧窗口 PC 不得进 EPC）。
    task automatic c_trap_pc;
        integer t;
        begin
            cname = "stale_trap_pc";
            alloc_group(4, 32'hD000_0000, 4'd0, 1'b0, 1'b0);
            wait_commits(4, 60);
            do_flush(1'b0);
            for (t = 0; t < 5; t = t + 1) step();
            alloc_group(1, 32'hE000_0000, 4'd2, 1'b0, 1'b0);   // illegal
            wait_trap(40);
            if (trap_valid) begin
                nchk = nchk + 1;
                if (trap_pc !== 32'hE000_0000) begin
                    errs = errs + 1;
                    if (errs_dumped < 24) begin errs_dumped = errs_dumped + 1;
                        $display("MISMATCH case=5 trap pc got=%h exp=E0000000", trap_pc); end
                end
                if (trap_cause !== 4'd2) begin
                    errs = errs + 1;
                    if (errs_dumped < 24) begin errs_dumped = errs_dumped + 1;
                        $display("MISMATCH case=5 trap cause got=%0d exp=2", trap_cause); end
                end
            end
            //   陷阱退役：flush_all + trap_retire 同拍（rob.v 契约）
            flush_all = 1'b1; trap_retire = 1'b1; step();
            flush_all = 1'b0; trap_retire = 1'b0;
            alloc_group(4, 32'hE000_0010, 4'd0, 1'b0, 1'b0);
            wait_commits(committed + 4, 80);
        end
    endtask

    //   case6：两宽连续提交正控（不允许根修把提交串行化；IPC2 硬约束）。
    task automatic c_two_wide;
        integer t, guard;
        begin
            cname = "two_wide_sustained";
            for (t = 0; t < 14; t = t + 1)
                alloc_group(4, 32'h8000_0000 + t*16, 4'd0, 1'b0, 1'b0);
            guard = 0;
            while (cmt_valid !== 2'b11 && guard < 40) begin
                step(); guard = guard + 1;
            end
            if (cmt_valid !== 2'b11) note_mismatch("two-wide: never reached 2 commits/cycle");
            for (t = 0; t < 16; t = t + 1) begin
                step();
                nchk = nchk + 1;
                if (cmt_valid !== 2'b11) begin
                    errs = errs + 1;
                    if (errs_dumped < 24) begin errs_dumped = errs_dumped + 1;
                        $display("MISMATCH case=6 cyc=%0d sustained window cmt=%b (expect 11)",
                                 cyc, cmt_valid); end
                end
            end
        end
    endtask

    //   case7：同拍 alloc/commit/flush 边界（flush 不得让旧世代窗口给新 head 贴标签）。
    task automatic c_same_cycle;
        integer t;
        begin
            cname = "alloc_commit_flush_same";
            alloc_group(4, 32'h9000_0000, 4'd0, 1'b0, 1'b0);   // 0..3
            alloc_group(4, 32'h9000_0010, 4'd0, 1'b0, 1'b0);   // 4..7
            wait_commits(2, 60);
            //   同拍 alloc + commit（alloc 写在 old tail，提交读窗口，互不冲突）
            alloc_group(4, 32'h9000_0020, 4'd0, 1'b0, 1'b0);   // 8..11
            //   同拍 alloc + flush（ROB 丢弃本次 alloc；旧世代读命令不得入新窗）
            alloc_valid = 1'b1; alloc_n = 3'd4; alloc_lane_valid = 4'hF;
            for (t = 0; t < 4; t = t + 1) set_payload(t, 32'h9000_0030 + 4*t, 4'd0, 1'b0, 1'b0);
            flush_all = 1'b1;
            step();
            flush_all = 1'b0; alloc_valid = 1'b0; alloc_n = 3'd0; alloc_lane_valid = 4'h0;
            for (t = 0; t < 4; t = t + 1) step();
            alloc_group(4, 32'hA000_0000, 4'd0, 1'b0, 1'b0);
            wait_commits(committed + 4, 80);
        end
    endtask

    //   case8（独审 P1 确定反例）：读 idx1 拍 idx1 仍 live（e_ok=1），同沿 squash
    //   保 head0、杀 idx1；T+1 撤 squash 同拍 commit 旧 head0 + alloc 复用 idx1=PC B。
    //   T 拍旧 idx1=A 的读回在 T+1 沿仍 fhit/ e_ok=1/ fdang=0（prevalloc 在 T 拍=0）
    //   ⇒ 若 e_bad 只记 flush，会把 win0=idx1/A 标成有效；T+2 新 head=idx1 即
    //   head_pc_valid=1/trap_pc=A，次沿才清已晚。本用例要求**逐拍** safevalid/PC：
    //   开闸后每一拍都走 §3.4/§3.5（不是只看最终提交）。
    task automatic c_squash_read_cross;
        integer t, w0, b_target;
        begin
            cname = "squash_read_cross";
            //   warm-up：alloc idx0/idx1（A0/A），done 延迟；窗口刷新前关闭架构门，
            //   以隔离“通用未分配旧值”根因（已由 case1..7 覆盖），只测 squash 跨代。
            win_check_en = 0;
            alloc_group_nd(2, 32'hB000_0000, 4'd0, 1'b0, 1'b0);
            w0 = l_new_idx[0];
            for (t = 0; t < 5; t = t + 1) step();
            win_check_en = 1;
            //   只置 head0 done ⇒ 本拍 cmt_n=1、读命令基址 = idx1（且 idx1 pre-live=1）
            push_done(w0);
            step();
            //   T 拍：读 idx1；同沿 squash 保 head0/kill idx1（填窗禁用，e_bad_q<=1）
            squash_valid = 1'b1; squash_idx = 6'd0;
            step();
            squash_valid = 1'b0; squash_idx = 6'd0;
            //   T+1：撤 squash 同拍 commit head0 + alloc 复用 idx1=PC B
            alloc_group(1, 32'hB000_0100, 4'd0, 1'b0, 1'b0);
            //   T+2 起逐拍检查（win_check_en=1）：旧候选在此拍暴露 A，新树必须 bubble
            //   ★ 目标必须用**分配后立刻捕获的绝对计数**（不能等 4 拍后再用相对 +1，
            //     否则 B 已提交会把目标推高到永不达到的值 → 假 timeout）。
            b_target = committed + 1;
            for (t = 0; t < 4; t = t + 1) step();
            wait_commits(b_target, 60);        // B 必须提交（PC 由通用提交检查逐 lane 比对）
        end
    endtask

    //   case9（同族正控）：同样的 warm-up/读 idx1/squash 拍，但 squash_idx=1
    //   （保留 head0 和读目标 idx1，不杀）⇒ 新 e_bad 只多 1 拍重读，旧/新都必须绿。
    task automatic c_squash_diff_idx_ctrl;
        integer t, w0, w1, h0_target, a_target, b_target;
        begin
            cname = "squash_diff_idx_ctrl";
            win_check_en = 0;
            alloc_group_nd(2, 32'hC000_0000, 4'd0, 1'b0, 1'b0);
            w0 = l_new_idx[0]; w1 = l_new_idx[1];
            for (t = 0; t < 5; t = t + 1) step();
            win_check_en = 1;
            push_done(w0);
            step();
            //   T：squash_idx=1（不同 idx；读目标 idx1 存活）
            squash_valid = 1'b1; squash_idx = 6'd1;
            step();
            squash_valid = 1'b0; squash_idx = 6'd0;
            //   T+1：head0 commit；idx1=A 仍 live，稍后置 done 提交 A
            h0_target = committed + 1;
            for (t = 0; t < 3; t = t + 1) step();
            wait_commits(h0_target, 60);
            push_done(w1);
            a_target = committed + 1;
            wait_commits(a_target, 60);
            //   再分配 B 到 idx2 并提交（同族后续正控）
            alloc_group(1, 32'hC000_0100, 4'd0, 1'b0, 1'b0);
            b_target = committed + 1;
            wait_commits(b_target, 60);
        end
    endtask

    //   case10（审阅 P1：safe-head 正活性）：**未 done 的驻留头**也必须 hpv=1 且 PC 正确
    //   —— 中断 EPC 只需要"下一条未执行指令"的 PC，不要求该指令已完成。旧测试只查
    //   内部 win_lane_ok，hpv 恒 0 或 `& done` 的变异仍能全绿；本用例显式逐拍要求
    //   hpv===1 + trap_pc===q_pc[head] + head_done==0，且不把内部窗口当独立活性证据。
    task automatic c_hpv_nondone;
        integer t;
        begin
            cname = "hpv_live_nondone";
            //   warm-up 只为隔离“通用未分配旧值”根因（case1..7 覆盖）；本用例不开 done。
            win_check_en = 0;
            alloc_group_nd(2, 32'hD000_0000, 4'd0, 1'b0, 1'b0);
            for (t = 0; t < 6; t = t + 1) step();
            win_check_en = 1;
            //   头项未 done、驻留多拍：读回延迟后每一拍都必须 hpv=1 且 PC 正确。
            for (t = 0; t < 8; t = t + 1) begin
                nchk = nchk + 1;
                if (cnt_o == 0) begin
                    errs = errs + 1;
                    if (errs_dumped < 24) begin errs_dumped = errs_dumped + 1;
                        $display("MISMATCH case=10 cyc=%0d live-head liveness: cnt=0", cyc); end
                end
                if (head_done_o !== 1'b0) begin
                    errs = errs + 1;
                    if (errs_dumped < 24) begin errs_dumped = errs_dumped + 1;
                        $display("MISMATCH case=10 cyc=%0d head unexpectedly done", cyc); end
                end
                if (head_pc_valid_o !== 1'b1) begin
                    errs = errs + 1;
                    if (errs_dumped < 24) begin errs_dumped = errs_dumped + 1;
                        $display("MISMATCH case=10 cyc=%0d hpv=0 while head live and not done", cyc); end
                end else if (trap_pc !== q_pc[m_head & (ROB_N-1)]) begin
                    errs = errs + 1;
                    if (errs_dumped < 24) begin errs_dumped = errs_dumped + 1;
                        $display("MISMATCH case=10 cyc=%0d hpv=1 PC got=%h exp=%h",
                                 cyc, trap_pc, q_pc[m_head & (ROB_N-1)]); end
                end
                step();
            end
        end
    endtask

    task automatic run_case(input integer c);
        begin
            ckind = is_trigger(c) ? "trigger" : "control";
            case (c)
                0: c_empty;
                1: c_stale_realloc;
                2: c_shallow_race;
                3: c_wrap_reuse;
                4: c_squash;
                5: c_trap_pc;
                6: c_two_wide;
                7: c_same_cycle;
                8: c_squash_read_cross;
                9: c_squash_diff_idx_ctrl;
                10: c_hpv_nondone;
                default: begin cname = "unknown"; note_mismatch("unknown case"); end
            endcase
        end
    endtask

    //==========================================================================
    // 8. 入口
    //==========================================================================
    initial begin
        errs = 0; nchk = 0; errs_dumped = 0;
        st_empty = 0; st_hit = 0; st_miss = 0; st_raw = 0;
        case_sel = 0;
        if (!$value$plusargs("CASE=%d", case_sel)) case_sel = 0;
        cname = "invalid_case"; ckind = "control";
        if (case_sel < 0 || case_sel > 10) begin
            $display("CASE %0d invalid_case VERDICT=DEFECT_SIG", case_sel);
            $finish;
        end
        do_reset();
        run_case(case_sel);
        //   过短/空跑防线：每用例必须产生足量真实检查（脚本另有冻结下限）
        if (nchk < 20) begin
            errs = errs + 1;
            $display("MISMATCH case=%0d nchk=%0d too few checks", case_sel, nchk);
        end
        $display("ROB_WINDOW_COV case=%0d empty=%0d hit=%0d miss=%0d raw=%0d",
                 case_sel, st_empty, st_hit, st_miss, st_raw);
        if (errs == 0)
            $display("CASE %0d %0s KIND=%0s VERDICT=OK nchk=%0d",
                     case_sel, cname, ckind, nchk);
        else
            $display("CASE %0d %0s KIND=%0s VERDICT=DEFECT_SIG nchk=%0d",
                     case_sel, cname, ckind, nchk);
        $finish;
    end

    //   超时兜底（脚本另有墙钟超时）
    initial begin
        #2_000_000;
        $display("CASE %0d %0s KIND=%0s VERDICT=DEFECT_SIG reason=timeout",
                 case_sel, cname, ckind);
        $finish;
    end

endmodule
