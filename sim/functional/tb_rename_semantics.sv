//==============================================================================
// sim/functional/tb_rename_semantics.sv —— F2 重命名包定向功能 TB（fail-closed）
//==============================================================================
// 项目 : rv32gc-cpu（阶段二 2B-5）
// 依据 : sim/audit/global-2026-10-18/02-backend.md 条目 02-2 / 02-3；
//        prompts/common.md §3（判定靠确定性脚本/退出码/锚点；未捕获即失败）。
//
// 做什么 :
//   · 直接例化 rtl/back2/rename.v（整数域 NSRC=2 + 浮点域 NSRC=3 两实例），
//     **只用真实端口**驱动：派发（lane_valid/lane_fire/lane_dst_arn/lane_s_arn）、
//     按 ROB 索引登记快照（rob_snap_valid/rob_snap_idx）、提交释放（cmt_*/rel_*）、
//     检查点保存（snap_*）、两条回滚入口（restore_valid/restore_rob_valid）、全冲刷。
//   · TB 内建**黄金参考模型**（独立实现，非 DUT 复制）：架构 RAT + 投机 RAT +
//     环形 free list（head/tail/数组）+ 逐 ROB 索引完整快照（rat/fhead）。
//   · 每拍（每次时钟沿后）逐项比对 DUT 与模型：RAT 32 项、fhead、ftail、
//     free list 活窗口内容、ar_used；并跑不变式：
//       ① free 集合 ∩ (RAT 像 ∪ ar_used) = ∅（free 与 occupied 不冲突）
//       ② RAT 像无重复（活映射不重复）
//       ③ 每个**真正派发**的 lane 的 pd_dst 必须等于模型预测（恢复后继续分配不偷用活 PRF）
//       ④ 整数域读 arn=0 必须恒得 preg 0（x0 硬零）；浮点域 f0 是正常可写架构寄存器
//   · `+CASE=<n>` 选一个确定性向量；每次运行只跑一个向量并打印恰好一行
//       `CASE <n> <name> KIND=<trigger|control> VERDICT=<OK|DEFECT_SIG>`
//     以及（仅失败时）诊断行。**不打印 FAIL 字样**：判定由本行 + 退出码 + 脚本聚合给出。
//
// 说明（可达性）:
//   · 02-2 触发序列 = "错路在组内更年轻 lane 写目的 → 回滚到更早 lane → 正确路径在同一
//     lane 落不写目的的 nop → 再次回滚到更年轻 lane"。ROB 冲刷点 = 误判分支自身索引
//     （backend_top `squash_idx_w = x_i2_rob[2]`），回滚后 tail = squash_idx+1 ⇒ 重派发
//     正好落在同一 lane —— 与 `backend_top` 的真实顺序一致，非人为构造。
//   · 02-3 触发序列 = "tail 在 head 仍位于该组内时环绕回该组 lane 0"（head lane 1..3）。
//     ROB 允许 64 项全满（`rob.v`：`room_free = ROB_N - cnt_after_cmt`），故 tail 可在
//     组内旧 lane 仍活时回到 lane 0；`rob_snap_idx` 恒为连续索引（backend_top `rb_ix_w`）。
//     用**不写目的**的 nop 填满 ROB 以避免 free list 先耗尽（审计 02-3 原文口径）。
//
// 工具 : 只由 test_rename.sh 调用（iverilog -g2012），不自行依赖任何 build 夹具。
//==============================================================================
`timescale 1ns / 1ps
`include "rtl/back2/back2_params.vh"

module tb_rename_semantics;

    //--------------------------------------------------------------------------
    // 0. 冻结参数（与 back2_params.vh 一致；TB 内显式写死以防脚本/参数漂移）
    //--------------------------------------------------------------------------
    localparam integer W        = 4;   // `BACK2_DISP_W
    localparam integer CMW      = 2;   // `BACK2_COMMIT_W
    localparam integer PDW      = 6;   // `BACK2_PREG_I_W
    localparam integer NREG     = 64;  // `BACK2_PRF_I_N
    localparam integer FREE_N   = 32;  // `BACK2_FREE_I_N
    localparam integer ARCH_N   = 32;  // `BACK2_ARCH_N
    localparam integer ARN_W    = 5;   // `BACK2_ARN_W
    localparam integer FL_PTR_W = 8;   // `BACK2_FL_PTR_W
    localparam integer ROB_IDX_W= 6;   // `BACK2_ROB_IDX_W
    localparam integer ROBW     = 7;   // 年龄运算零扩展位宽
    localparam integer RN_SRC   = 2;   // 整数域源口数（NSRC）

    localparam integer TOTAL_CASES  = 20;
    // 触发例（旧源码必须 DEFECT_SIG）。控制例（新旧都必须 OK）。
    // 用常量表在本文件与脚本之间保持一致（脚本另有一份冻结清单，两边必须一致）。
    function integer is_trigger(input integer c);
        begin
            //   8/9  = 02-2（回滚后同组 dst 掩码残留）
            //   10/11/12/13 = 02-3（环绕分裂后旧段快照被覆盖）
            //   15   = 随机混合（含环绕分裂路径；固定种子 ⇒ 可复现）
            //   16/17/18 = 审阅 P1：**死组重入抢走仍活旧组的共享影子**
            //              （最短反证 / 同组二次 split 覆盖 / 死组重入后继续分配）
            is_trigger = (c==8)||(c==9)||(c==10)||(c==11)||(c==12)||(c==13)||(c==15)
                      || (c==16)||(c==17)||(c==18);
        end
    endfunction

    //--------------------------------------------------------------------------
    // 1. 时钟 / 复位
    //--------------------------------------------------------------------------
    reg clk;
    reg rst_n;
    initial clk = 1'b0;
    always #5 clk = ~clk;          // posedge @ 5,15,25…  negedge @ 10,20,30…

    //--------------------------------------------------------------------------
    // 2. DUT 端口
    //--------------------------------------------------------------------------
    reg  [W-1:0]              lane_valid;
    reg                       lane_fire;
    reg  [W-1:0]              lane_need_dst;
    reg  [W*ARN_W-1:0]        lane_dst_arn;
    reg  [W*RN_SRC-1:0]       lane_need_s;
    reg  [W*RN_SRC*ARN_W-1:0] lane_s_arn;
    wire [W*PDW-1:0]          lane_pd_dst;
    wire [W*PDW-1:0]          lane_pd_old;
    wire [W*RN_SRC*PDW-1:0]   lane_pd_s;
    wire                      free_ok;
    wire [7:0]                free_cnt_o;
    reg  [CMW-1:0]            cmt_we;
    reg  [CMW*ARN_W-1:0]      cmt_arn;
    reg  [CMW*PDW-1:0]        cmt_pd;
    reg  [CMW-1:0]            rel_we;
    reg  [CMW*PDW-1:0]        rel_preg;
    reg                       rob_snap_valid;
    reg  [W*ROB_IDX_W-1:0]    rob_snap_idx;
    reg                       snap_valid;
    reg  [3:0]                snap_id;
    reg  [1:0]                snap_lane;
    reg                       restore_valid;
    reg  [3:0]                restore_id;
    reg                       restore_rob_valid;
    reg  [ROB_IDX_W-1:0]      restore_rob_idx;
    reg                       flush_all;
    wire                      busy;
    wire [7:0]                log_wr_o;
    wire [15:0]               cnt_restore_o;

    rename #(.W(W), .CMW(CMW), .NSRC(RN_SRC), .PDW(PDW), .NREG(NREG), .FREE_N(FREE_N),
             .ARCH_N(ARCH_N), .ARN_W(ARN_W), .FL_PTR_W(FL_PTR_W), .ROB_IDX_W(ROB_IDX_W),
             .CHK(0), .TRACE(0), .TRB(0))
    dut (
        .clk(clk), .rst_n(rst_n),
        .lane_valid(lane_valid), .lane_fire(lane_fire),
        .lane_need_dst(lane_need_dst), .lane_dst_arn(lane_dst_arn),
        .lane_need_s(lane_need_s), .lane_s_arn(lane_s_arn),
        .lane_pd_dst(lane_pd_dst), .lane_pd_old(lane_pd_old), .lane_pd_s(lane_pd_s),
        .free_ok(free_ok), .free_cnt_o(free_cnt_o),
        .cmt_we(cmt_we), .cmt_arn(cmt_arn), .cmt_pd(cmt_pd),
        .rel_we(rel_we), .rel_preg(rel_preg),
        .rob_snap_valid(rob_snap_valid), .rob_snap_idx(rob_snap_idx),
        .snap_valid(snap_valid), .snap_id(snap_id), .snap_lane(snap_lane),
        .restore_valid(restore_valid), .restore_id(restore_id),
        .restore_rob_valid(restore_rob_valid), .restore_rob_idx(restore_rob_idx),
        .flush_all(flush_all), .busy(busy), .log_wr_o(log_wr_o), .cnt_restore_o(cnt_restore_o)
    );

    //--------------------------------------------------------------------------
    // 3. 黄金参考模型状态（独立实现）
    //--------------------------------------------------------------------------
    reg [PDW-1:0] m_rat  [0:ARCH_N-1];      // 投机 RAT
    reg [PDW-1:0] m_arat [0:ARCH_N-1];      // 架构 RAT
    reg [NREG-1:0] m_ar_used;
    reg [PDW-1:0] m_fl   [0:255];           // free list 数组（逻辑下标 mod 256）
    reg [FL_PTR_W-1:0] m_fhead, m_ftail;
    reg m_rb_act;
    reg [8:0] m_rb_cnt;
    reg [FL_PTR_W-1:0] m_rb_head;
    // 逐 ROB 索引完整快照（参考实现可承受）
    reg m_sv [0:63];
    reg [FL_PTR_W-1:0] m_sfhead [0:63];
    reg [PDW-1:0]      m_srat [0:63][0:ARCH_N-1];

    // 组合辅助（镜像 RTL 的提交侧组合逻辑）
    reg [NREG-1:0] m_ar_used_nx;
    reg [PDW-1:0]  m_arat_nx [0:ARCH_N-1];
    reg [PDW-1:0] m_chain [0:CMW];
    reg [2:0]     m_ordr [0:CMW-1];   // 释放写口压缩序号（与 RTL fl_wr_idx 同口径）

    integer mu, mv, mc, mg, mk;
    reg [PDW-1:0] m_clr;
    reg [2:0] m_ord [0:W-1];
    reg [PDW-1:0] m_apd [0:W-1];    // 本拍每 lane 的模型预测 pd_dst
    reg [7:0]     m_nd_sum;         // 本拍有效且需目的寄存器 lane 数

    always @(*) begin : m_comb
        // ---- 释放写口压缩序号（rel_we 前缀计数）----
        begin : m_ordrb
            integer o2;
            o2 = 0;
            for (mg = 0; mg < CMW; mg = mg + 1) begin
                m_ordr[mg] = o2[2:0];
                if (rel_we[mg]) o2 = o2 + 1;
            end
        end
        // ---- 提交侧 ar_used（组内同 ARN 年轻者胜；与 RTL §1.5 同口径）----
        m_ar_used_nx = m_ar_used;
        for (mu = 0; mu < CMW; mu = mu + 1) begin
            if (cmt_we[mu]) begin
                m_clr = m_arat[cmt_arn[mu*ARN_W +: ARN_W]];
                for (mv = 0; mv < CMW; mv = mv + 1) begin
                    if ((mv < mu) && cmt_we[mv] &&
                        (cmt_arn[mv*ARN_W +: ARN_W] == cmt_arn[mu*ARN_W +: ARN_W]))
                        m_clr = cmt_pd[mv*PDW +: PDW];
                end
                m_ar_used_nx = (m_ar_used_nx &
                                ~({{(NREG-1){1'b0}}, 1'b1} << m_clr))
                               | ({{(NREG-1){1'b0}}, 1'b1} << cmt_pd[mu*PDW +: PDW]);
            end
        end
        // ---- 架构 RAT（含本拍提交；高 lane 年轻者胜）----
        for (mc = 0; mc < ARCH_N; mc = mc + 1) begin : m_aratn
            m_chain[CMW] = m_arat[mc];
            //   必须**从高到低**构建链（chain[k] 依赖 chain[k+1]）；升序会用上一 arn 的残值。
            for (mk = CMW-1; mk >= 0; mk = mk - 1) begin : m_aratc
                m_chain[mk] = (cmt_we[CMW-1-mk] &&
                               (cmt_arn[(CMW-1-mk)*ARN_W +: ARN_W] == mc[ARN_W-1:0]))
                                  ? cmt_pd[(CMW-1-mk)*PDW +: PDW] : m_chain[mk+1];
            end
            m_arat_nx[mc] = m_chain[0];
        end
        // ---- 本拍派发预测（pd_dst 序列；供 ③ 断言）----
        begin : m_ordb
            integer o;
            o = 0;
            for (mg = 0; mg < W; mg = mg + 1) begin
                m_ord[mg] = o[2:0];
                if (lane_valid[mg] && lane_need_dst[mg]) o = o + 1;
            end
            m_nd_sum = o[7:0];
        end
    end

    //--------------------------------------------------------------------------
    // 4. 黄金模型时序（与 DUT 同沿、同优先级）
    //--------------------------------------------------------------------------
    integer j1, j2, j3, j4;
    reg [ROB_IDX_W-1:0] s_idx;
    reg [PDW-1:0]       s_val;
    reg                 s_hit;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (j1 = 0; j1 < ARCH_N; j1 = j1 + 1) begin
                m_rat [j1] <= j1[PDW-1:0];
                m_arat[j1] <= j1[PDW-1:0];
            end
            m_ar_used <= {{(NREG-ARCH_N){1'b0}}, {ARCH_N{1'b1}}};
            for (j1 = 0; j1 < 256; j1 = j1 + 1) m_fl[j1] <= {PDW{1'b0}};
            for (j1 = 0; j1 < FREE_N; j1 = j1 + 1) m_fl[j1] <= (ARCH_N + j1);
            m_fhead <= {FL_PTR_W{1'b0}};
            m_ftail <= FREE_N[FL_PTR_W-1:0];
            m_rb_act <= 1'b0; m_rb_cnt <= 9'd0; m_rb_head <= {FL_PTR_W{1'b0}};
            for (j1 = 0; j1 < 64; j1 = j1 + 1) m_sv[j1] <= 1'b0;
        end else begin
            // ---- 提交侧：无条件 ----
            for (j1 = 0; j1 < CMW; j1 = j1 + 1)
                if (cmt_we[j1]) m_arat[cmt_arn[j1*ARN_W +: ARN_W]] <= cmt_pd[j1*PDW +: PDW];
            m_ar_used <= m_ar_used_nx;
            for (j1 = 0; j1 < CMW; j1 = j1 + 1)
                if (rel_we[j1]) m_fl[(m_ftail + m_ordr[j1]) & 8'hff] <= rel_preg[j1*PDW +: PDW];
            m_ftail <= m_ftail + (rel_we[0] ? 8'd1 : 8'd0) + (rel_we[1] ? 8'd1 : 8'd0);

            if (flush_all) begin
                for (j1 = 0; j1 < ARCH_N; j1 = j1 + 1) m_rat[j1] <= m_arat_nx[j1];
                m_rb_act <= 1'b1; m_rb_cnt <= 9'd0; m_rb_head <= {FL_PTR_W{1'b0}};
                m_fhead  <= {FL_PTR_W{1'b0}};
            end else if (m_rb_act) begin
                if (m_rb_cnt < NREG) begin
                    if (!m_ar_used[m_rb_cnt[PDW-1:0]]) begin
                        m_fl[m_rb_head] <= m_rb_cnt[PDW-1:0];
                        m_rb_head <= m_rb_head + 1'b1;
                    end
                    m_rb_cnt <= m_rb_cnt + 9'd1;
                end else begin
                    m_rb_act <= 1'b0;
                    m_fhead  <= {FL_PTR_W{1'b0}};
                    m_ftail  <= m_rb_head;
                end
            end else if (restore_valid | restore_rob_valid) begin
                for (j1 = 0; j1 < ARCH_N; j1 = j1 + 1) m_rat[j1] <= m_srat[restore_rob_idx][j1];
                m_fhead <= m_sfhead[restore_rob_idx];
            end else begin
                if (lane_fire) begin
                    for (j1 = 0; j1 < W; j1 = j1 + 1) begin
                        if (lane_valid[j1]) begin
                            // 本 lane 的新物理号（读 free list）
                            if (lane_need_dst[j1])
                                m_apd[j1] = m_fl[(m_fhead + m_ord[j1]) & 8'hff];
                            // 先写"本 lane 之后"的快照（含本 lane 自己的消耗与 RAT 写）
                            s_idx = rob_snap_idx[j1*ROB_IDX_W +: ROB_IDX_W];
                            m_sv[s_idx] <= 1'b1;
                            m_sfhead[s_idx] <= m_fhead + m_ord[j1] +
                                               (lane_need_dst[j1] ? 8'd1 : 8'd0);
                            for (j2 = 0; j2 < ARCH_N; j2 = j2 + 1) begin
                                s_val = m_rat[j2];
                                for (j3 = 0; j3 <= j1; j3 = j3 + 1) begin
                                    if (lane_valid[j3] && lane_need_dst[j3] &&
                                        (lane_dst_arn[j3*ARN_W +: ARN_W] == j2[ARN_W-1:0]))
                                        s_val = m_apd[j3];
                                end
                                m_srat[s_idx][j2] <= s_val;
                            end
                            // 再更新投机 RAT（free list 消耗在循环外一次推进）
                            if (lane_need_dst[j1])
                                m_rat[lane_dst_arn[j1*ARN_W +: ARN_W]] <= m_apd[j1];
                        end
                    end
                    // 本拍总消耗 = 有效且需目的寄存器 lane 数（单次 NBA，避免同 reg 多写覆盖）
                    m_fhead <= m_fhead + m_nd_sum;
                end
            end
        end
    end

    //--------------------------------------------------------------------------
    // 5. 检查器（每拍逐项比对 + 不变式）
    //--------------------------------------------------------------------------
    integer errs;
    integer nchk;
    reg     chk_en;
    integer fi, fc, fa;
    reg [NREG-1:0] occ_mask, free_mask, dup_mask;
    reg [PDW-1:0]  pa, pb;
    reg            viol;

    reg errs_dumped;
    task chk_now;
        begin
            if (chk_en) begin
                nchk = nchk + 1;
                if ((errs > 0) && !errs_dumped) errs_dumped = 1'b1;
                // (0) 逐项状态比对
                for (fa = 0; fa < ARCH_N; fa = fa + 1) begin
                    if (dut.rat_q[fa] !== m_rat[fa]) begin
                        errs = errs + 1;
                        if (errs <= 6)
                            $display("CHK rat_q[%0d]=%0d model=%0d (t=%0t)",
                                     fa, dut.rat_q[fa], m_rat[fa], $time);
                    end
                end
                if (dut.fhead_q !== m_fhead) begin
                    errs = errs + 1;
                    if (errs <= 6) $display("CHK fhead=%0d model=%0d (t=%0t)",
                                            dut.fhead_q, m_fhead, $time);
                end
                if (dut.ftail_q !== m_ftail) begin
                    errs = errs + 1;
                    if (errs <= 6) $display("CHK ftail=%0d model=%0d (t=%0t)",
                                            dut.ftail_q, m_ftail, $time);
                end
                if (dut.ar_used_q !== m_ar_used) begin
                    errs = errs + 1;
                    if (errs <= 6) $display("CHK ar_used=%h model=%h (t=%0t)",
                                            dut.ar_used_q, m_ar_used, $time);
                end
                fc = (m_ftail - m_fhead) & 8'hff;
                if (fc > FREE_N + 4) begin
                    errs = errs + 1;
                    if (errs <= 6) $display("CHK free span=%0d > FREE_N=%0d (t=%0t)",
                                            fc, FREE_N, $time);
                end
                for (fi = 0; fi < fc; fi = fi + 1) begin
                    if (dut.flist_q[(m_fhead + fi) & 8'h3f] !== m_fl[(m_fhead + fi) & 8'hff]) begin
                        errs = errs + 1;
                        if (errs <= 6)
                            $display("CHK flist[fhead+%0d]=%0d model=%0d (t=%0t)",
                                     fi, dut.flist_q[(m_fhead + fi) & 8'h3f],
                                     m_fl[(m_fhead + fi) & 8'hff], $time);
                    end
                end
                // ③ 本拍真正派发 lane 的 pd_dst 必须等于模型预测
                if (lane_fire) begin
                    for (fa = 0; fa < W; fa = fa + 1) begin
                        if (lane_valid[fa] && lane_need_dst[fa] &&
                            (lane_pd_dst[fa*PDW +: PDW] !== m_apd[fa])) begin
                            errs = errs + 1;
                            if (errs <= 6)
                                $display("CHK lane%0d pd_dst=%0d model=%0d (偷用活 PRF/错误分配, t=%0t)",
                                         fa, lane_pd_dst[fa*PDW +: PDW], m_apd[fa], $time);
                        end
                    end
                end
                // ①② free ∩ (RAT 像 ∪ ar_used) = ∅；RAT 像无重复
                //   豁免整机冲刷拍与 free list 重建期（RTL FREE-OVER 同口径的已知过渡态：
                //   fhead 暂置 0 而 ftail/数组尚未同步）；模型在此期间仍逐拍镜像 DUT。
                occ_mask  = {NREG{1'b0}};
                dup_mask  = {NREG{1'b0}};
                free_mask = {NREG{1'b0}};
                for (fi = 0; fi < fc; fi = fi + 1)
                    free_mask[m_fl[(m_fhead + fi) & 8'hff]] = 1'b1;
                for (fa = 0; fa < ARCH_N; fa = fa + 1) begin
                    pa = m_rat[fa];
                    if (dup_mask[pa]) begin
                        errs = errs + 1;
                        if (errs <= 6) $display("CHK RAT 重复映射 preg=%0d (t=%0t)", pa, $time);
                    end
                    dup_mask[pa] = 1'b1;
                    occ_mask[pa] = 1'b1;
                end
                viol = |(free_mask & occ_mask) | |(free_mask & m_ar_used) |
                       |(free_mask & dup_mask & m_ar_used);
                if (busy) viol = 1'b0;          // 重建期豁免（见上）
                if (viol) begin
                    errs = errs + 1;
                    if (errs <= 6)
                        $display("CHK free/occupied 冲突 free=%h occ=%h ar_used=%h (t=%0t)",
                                 free_mask, occ_mask, m_ar_used, $time);
                end
            end
        end
    endtask

    //--------------------------------------------------------------------------
    // 6. ROB 模型（真实冲刷语义：保留 head..squash_idx 的**环弧**）
    //--------------------------------------------------------------------------
    reg [ROBW-1:0]      r_head, r_tail;
    reg                 r_v   [0:63];
    reg [ARN_W-1:0]     r_arn [0:63];
    reg                 r_nd  [0:63];
    reg [PDW-1:0]       r_pdd [0:63];
    reg [PDW-1:0]       r_pdo [0:63];

    function [ROBW-1:0] age_of(input [ROBW-1:0] idx, input [ROBW-1:0] hd);
        age_of = (idx - hd) & 7'h3f;
    endfunction

    //--------------------------------------------------------------------------
    // 7. 低层驱动原语
    //--------------------------------------------------------------------------
    reg               wait_commit_en;   // 派发停顿时允许自动退休（随机向量用）
    reg [W-1:0]       b_valid;
    reg [W-1:0]       b_nd;
    reg [ARN_W-1:0]   b_arn [0:W-1];
    reg [ARN_W-1:0]   b_s1  [0:W-1];
    reg [ARN_W-1:0]   b_s2  [0:W-1];
    integer           bi;

    task inputs_idle;
        begin
            lane_valid       = {W{1'b0}};
            lane_fire        = 1'b0;
            lane_need_dst    = {W{1'b0}};
            lane_dst_arn     = {(W*ARN_W){1'b0}};
            lane_need_s      = {(W*RN_SRC){1'b0}};
            lane_s_arn       = {(W*RN_SRC*ARN_W){1'b0}};
            cmt_we           = {CMW{1'b0}};
            cmt_arn          = {(CMW*ARN_W){1'b0}};
            cmt_pd           = {(CMW*PDW){1'b0}};
            rel_we           = {CMW{1'b0}};
            rel_preg         = {(CMW*PDW){1'b0}};
            rob_snap_valid   = 1'b0;
            rob_snap_idx     = {(W*ROB_IDX_W){1'b0}};
            snap_valid       = 1'b0;
            snap_id          = 4'd0;
            snap_lane        = 2'd0;
            restore_valid    = 1'b0;
            restore_id       = 4'd0;
            restore_rob_valid= 1'b0;
            restore_rob_idx  = {ROB_IDX_W{1'b0}};
            flush_all        = 1'b0;
            // 浮点域第二实例（避免 x 传播）
            f_lane_valid     = {W{1'b0}};
            f_lane_fire      = 1'b0;
            f_need_dst       = {W{1'b0}};
            f_dst_arn        = {(W*ARN_W){1'b0}};
            f_need_s         = {(W*3){1'b0}};
            f_s_arn          = {(W*3*ARN_W){1'b0}};
        end
    endtask

    task do_reset;
        begin
            rst_n = 1'b0;
            wait_commit_en = 1'b0;
            inputs_idle;
            repeat (4) @(posedge clk);
            r_head = {ROBW{1'b0}}; r_tail = {ROBW{1'b0}};
            for (bi = 0; bi < 64; bi = bi + 1) begin
                r_v[bi] = 1'b0; r_arn[bi] = 5'd0; r_nd[bi] = 1'b0;
                r_pdd[bi] = 6'd0; r_pdo[bi] = 6'd0;
            end
            @(negedge clk);
            rst_n = 1'b1;
            #1;
            @(posedge clk); #1;
        end
    endtask

    // 设本拍待派发块（lane 0 起连续有效；nd=0 表示不写目的）
    task build_block(input integer n, input [W-1:0] ndm, input [4:0] a0,
                     input [4:0] a1, input [4:0] a2, input [4:0] a3);
        begin
            b_valid = {W{1'b0}};
            b_nd    = ndm;
            b_arn[0]=a0[ARN_W-1:0]; b_arn[1]=a1[ARN_W-1:0];
            b_arn[2]=a2[ARN_W-1:0]; b_arn[3]=a3[ARN_W-1:0];
            for (bi = 0; bi < n; bi = bi + 1) b_valid[bi] = 1'b1;
            // 源口：取 arn 自身（用于观测；功能检查另做）
            for (bi = 0; bi < W; bi = bi + 1) begin
                b_s1[bi] = b_arn[bi];
                b_s2[bi] = b_arn[bi];
            end
        end
    endtask

    task drive_block;
        begin
            lane_valid    = b_valid;
            lane_need_dst = b_nd;
            lane_fire     = 1'b0;
            for (bi = 0; bi < W; bi = bi + 1) begin
                lane_dst_arn[bi*ARN_W +: ARN_W] = b_arn[bi];
                lane_s_arn[(bi*RN_SRC+0)*ARN_W +: ARN_W] = b_s1[bi];
                lane_s_arn[(bi*RN_SRC+1)*ARN_W +: ARN_W] = b_s2[bi];
            end
            lane_need_s = {(W*RN_SRC){1'b1}};   // 全部源都要读（观测 pd_s）
        end
    endtask

    // 等待资源允许后真正 fire 本拍块（模拟 backend_top `disp_ok` 的资源判据）
    reg [PDW-1:0] s_pdd [0:W-1];
    reg [PDW-1:0] s_pdo [0:W-1];
    task fire_block(input integer n);
        integer room;
        begin
            drive_block;
            //   ★ 必须让 DUT 的**组合**输出（free_ok/free_cnt/alloc_n）在 lane_valid 变更后
            //     重新求值再判资源，否则会读到上一拍的 stale 值 ⇒ 在空闲表不足时误派发
            //     （TB 侧假缺陷，与 DUT 无关）。
            #1;
            room = 64 - ((r_tail - r_head) & 7'h3f);
            while (busy || (room < n) || !free_ok) begin
                if (verbose)
                    $display("DBG t=%0t WAIT n=%0d nd=%b free_ok=%b free_cnt=%0d dutF/M=%0d/%0d dutT/M=%0d/%0d room=%0d busy=%b whe=%b rH=%0d rT=%0d rnd=%b rv=%b",
                             $time, n, lane_need_dst, free_ok, free_cnt_o,
                             dut.fhead_q, m_fhead, dut.ftail_q, m_ftail, room, busy,
                             wait_commit_en, r_head, r_tail, r_nd[r_head[5:0]], r_v[r_head[5:0]]);
                lane_fire = 1'b0; rob_snap_valid = 1'b0;
                //   派发停顿期间让 ROB 继续退休（真实后端里提交与派发互相独立）⇒ 空闲表
                //   能重新长出。定向向量里由 `wait_commit_en` 关闭，以免改变 head 位置。
                if (wait_commit_en && !busy && (((r_tail - r_head) & 7'h3f) > 0))
                    commit_n(1);
                else begin
                    @(posedge clk); #1;
                    chk_now();
                end
                #1;
                room = 64 - ((r_tail - r_head) & 7'h3f);
            end
            if (verbose)
                $display("DBG t=%0t FIRE n=%0d v=%b nd=%b free_ok=%b free_cnt=%0d dutF=%0d dutT=%0d allocn=%0d",
                         $time, n, lane_valid, lane_need_dst, free_ok, free_cnt_o,
                         dut.fhead_q, dut.ftail_q, dut.alloc_n_w);
            #0;
            lane_fire = 1'b1;
            rob_snap_valid = 1'b1;
            rob_snap_idx = {(W*ROB_IDX_W){1'b0}};
            for (bi = 0; bi < W; bi = bi + 1)
                rob_snap_idx[bi*ROB_IDX_W +: ROB_IDX_W] = (r_tail + bi[ROB_IDX_W-1:0]);
            //   ★ 组合输出必须在**时钟沿之前**采样：沿后再读会取到"已推进一拍"的新值。
            @(negedge clk);
            for (bi = 0; bi < W; bi = bi + 1) begin
                s_pdd[bi] = lane_pd_dst[bi*PDW +: PDW];
                s_pdo[bi] = lane_pd_old[bi*PDW +: PDW];
            end
            @(posedge clk); #1;
            if (verbose) begin
                $display("DBG t=%0t DISP n=%0d base=%0d nd=%b arn=%0d,%0d,%0d,%0d fhead(dut/mdl)=%0d/%0d",
                         $time, n, r_tail, b_nd, b_arn[0], b_arn[1], b_arn[2], b_arn[3],
                         dut.fhead_q, m_fhead);
            end
            lane_fire = 1'b0; rob_snap_valid = 1'b0; lane_valid = {W{1'b0}};
            // ROB 模型登记（用沿前采样值）
            for (bi = 0; bi < n; bi = bi + 1) begin
                r_v[(r_tail + bi) & 7'h3f]   = 1'b1;
                r_arn[(r_tail + bi) & 7'h3f] = b_arn[bi];
                r_nd[(r_tail + bi) & 7'h3f]  = b_nd[bi];
                r_pdd[(r_tail + bi) & 7'h3f] = s_pdd[bi];
                r_pdo[(r_tail + bi) & 7'h3f] = s_pdo[bi];
            end
            r_tail = (r_tail + n) & 7'h3f;
            chk_now();
        end
    endtask

    // 空转一拍（可带提交）
    task idle_cycle;
        begin
            lane_valid = {W{1'b0}}; lane_fire = 1'b0; rob_snap_valid = 1'b0;
            @(posedge clk); #1;
            cmt_we = {CMW{1'b0}}; rel_we = {CMW{1'b0}};
            chk_now();
        end
    endtask

    // 提交头部至多 n 项（模拟 ROB 退休 + 释放 pd_old）
    task commit_n(input integer n);
        integer u, idx, nc;
        begin
            cmt_we = {CMW{1'b0}}; rel_we = {CMW{1'b0}};
            nc = (r_tail - r_head) & 7'h3f;
            if (nc > n) nc = n;
            for (u = 0; u < CMW; u = u + 1) begin
                if (u < nc) begin
                    idx = (r_head + u) & 7'h3f;
                    if (r_v[idx]) begin
                        if (r_nd[idx]) begin
                            cmt_we[u] = 1'b1;
                            cmt_arn[u*ARN_W +: ARN_W] = r_arn[idx];
                            cmt_pd [u*PDW   +: PDW]   = r_pdd[idx];
                            rel_we[u] = 1'b1;
                            rel_preg[u*PDW +: PDW]    = r_pdo[idx];
                        end
                    end
                end
            end
            @(posedge clk); #1;
            for (u = 0; u < nc; u = u + 1) begin
                idx = (r_head + u) & 7'h3f;
                r_v[idx] = 1'b0;
            end
            r_head = (r_head + nc) & 7'h3f;
            if (verbose)
                $display("DBG t=%0t CMT nc=%0d head=%0d fhead(dut/mdl)=%0d/%0d ftail=%0d/%0d",
                         $time, nc, r_head, dut.fhead_q, m_fhead, dut.ftail_q, m_ftail);
            cmt_we = {CMW{1'b0}}; rel_we = {CMW{1'b0}};
            chk_now();
        end
    endtask

    // 回滚到 idx（ROB 环弧保留 head..idx）
    task rollback_to(input [ROB_IDX_W-1:0] idx, input use_ck, input [3:0] ckid);
        reg [ROBW-1:0] keep, cur;
        begin
            restore_rob_valid = ~use_ck;
            restore_valid     =  use_ck;
            restore_rob_idx   = idx;
            restore_id        = ckid;
            @(posedge clk); #1;
            restore_rob_valid = 1'b0;
            restore_valid     = 1'b0;
            if (verbose)
                $display("DBG t=%0t RB idx=%0d use_ck=%0b fhead(dut/mdl)=%0d/%0d snapF(mdl)=%0d",
                         $time, idx, use_ck, dut.fhead_q, m_fhead, m_sfhead[idx]);
            // ROB 环弧：保留 head..idx，其余作废；tail = idx+1
            keep = age_of({1'b0, idx}, r_head);
            for (cur = 0; cur < 64; cur = cur + 1) begin
                if (age_of(cur[ROBW-1:0], r_head) > keep) r_v[cur[5:0]] = 1'b0;
            end
            r_tail = (idx + 1'b1) & 7'h3f;
            chk_now();
        end
    endtask

    // 整机冲刷（陷阱/xRET）：同拍可带提交；ROB 清空到 trap_idx+1
    task do_flush(input [ROB_IDX_W-1:0] trap_idx);
        begin
            flush_all = 1'b1;
            @(posedge clk); #1;
            flush_all = 1'b0;
            for (bi = 0; bi < 64; bi = bi + 1) r_v[bi] = 1'b0;
            r_head = (trap_idx + 1'b1) & 7'h3f;
            r_tail = r_head;
            // 等 free list 重建结束
            while (busy) begin
                @(posedge clk); #1;
                chk_now();
            end
            chk_now();
        end
    endtask

    task wait_idle;
        begin
            while (busy) begin
                @(posedge clk); #1;
                chk_now();
            end
        end
    endtask

    //==========================================================================
    // 8. 定向 / 随机向量
    //==========================================================================
    reg [ROB_IDX_W-1:0] rk;
    integer             rr, seed;

    // ---- 0: 整数域 x0 硬零 ----
    task c_x0_hard_zero;
        begin
            build_block(4, 4'b0000, 5'd0, 5'd0, 5'd0, 5'd0);   // 全不写目的
            fire_block(4);
            // 读 arn=0：pd_s 必须恒为 0（x0 硬零）
            build_block(4, 4'b0000, 5'd0, 5'd0, 5'd0, 5'd0);
            drive_block;
            @(posedge clk); #1; chk_now();
            for (bi = 0; bi < W; bi = bi + 1) begin
                if (lane_pd_s[(bi*RN_SRC+0)*PDW +: PDW] !== 6'd0) begin
                    errs = errs + 1;
                    $display("CHK x0 读源 pd_s=%0d != 0", lane_pd_s[(bi*RN_SRC+0)*PDW +: PDW]);
                end
            end
            lane_valid = {W{1'b0}}; lane_need_s = {(W*RN_SRC){1'b0}};
            // 用真实规格重跑一段：只有 arn!=0 才写目的
            for (rr = 0; rr < 8; rr = rr + 1) begin
                build_block(2, 2'b01, 5'd7, 5'd0, 5'd0, 5'd0);
                fire_block(2);
                check_x0_reads;
            end
        end
    endtask

    task check_x0_reads;
        begin
            build_block(1, 1'b0, 5'd0, 5'd0, 5'd0, 5'd0);
            drive_block;
            @(posedge clk); #1; chk_now();
            if (lane_pd_s[0*PDW +: PDW] !== 6'd0) begin
                errs = errs + 1;
                $display("CHK x0 硬零破坏 pd_s=%0d", lane_pd_s[0*PDW +: PDW]);
            end
            lane_valid = {W{1'b0}}; lane_need_s = {(W*RN_SRC){1'b0}};
        end
    endtask

    // ---- 控制：基础提交/释放 ----
    task c_basic_commit;
        integer t;
        begin
            for (t = 0; t < 12; t = t + 1) begin
                build_block(2, 2'b11, (t%30)+1, (t%30)+2, 5'd0, 5'd0);
                fire_block(2);
                commit_n(2);
            end
            for (t = 0; t < 6; t = t + 1) commit_n(2);
            check_high_pregs_active;
        end
    endtask

    // 断言"高物理号（32..63）仍活跃时不得被误判 free"：由 free∩RAT=∅ 覆盖，
    // 此处额外统计活跃高物理号数量，确保用例确实构造了该条件。
    integer hi_active;
    task check_high_pregs_active;
        begin
            hi_active = 0;
            for (bi = 0; bi < ARCH_N; bi = bi + 1)
                if (m_rat[bi] >= 32) hi_active = hi_active + 1;
            if (hi_active == 0) begin
                errs = errs + 1;
                $display("CHK 用例未构造出活跃高物理号（hi_active=0）");
            end
        end
    endtask

    // ---- 控制：检查点保存 + 检查点回滚入口 ----
    task c_ckpt_save_restore;
        begin
            build_block(2, 2'b11, 5'd3, 5'd4, 5'd0, 5'd0);
            fire_block(2);
            // 保存检查点（snap_id=5，lane=1）
            snap_valid = 1'b1; snap_id = 4'd5; snap_lane = 2'd1;
            @(posedge clk); #1;
            snap_valid = 1'b0;
            chk_now();
            build_block(2, 2'b11, 5'd5, 5'd6, 5'd0, 5'd0);
            fire_block(2);
            // 检查点入口回滚到 lane1 的 ROB 索引（= 1）
            rollback_to(6'd1, 1'b1, 4'd5);
            build_block(2, 2'b11, 5'd9, 5'd10, 5'd0, 5'd0);
            fire_block(2);
            commit_n(2);
        end
    endtask

    // ---- 控制：ck_val 未保存（缺 checkpoint）时仍按 ROB 索引正确恢复 ----
    task c_missing_ckpt;
        begin
            build_block(3, 3'b110, 5'd11, 5'd12, 5'd13, 5'd0);
            fire_block(3);
            commit_n(1);
            build_block(2, 2'b11, 5'd14, 5'd15, 5'd0, 5'd0);
            fire_block(2);
            rollback_to(6'd3, 1'b1, 4'd9);   // ck id 9 从未保存（ck_val=0）
            build_block(2, 2'b11, 5'd16, 5'd17, 5'd0, 5'd0);
            fire_block(2);
        end
    endtask

    // ---- 控制：整机冲刷 + 高物理号活跃；按提交映射重建 free ----
    task c_flush_rebuild;
        begin
            build_block(4, 4'b1111, 5'd1, 5'd2, 5'd3, 5'd4);
            fire_block(4);
            build_block(4, 4'b1111, 5'd5, 5'd6, 5'd7, 5'd8);
            fire_block(4);
            commit_n(2);
            check_high_pregs_active;
            // 同拍"提交 + 冲刷"（xRET 顺序）：先驱动本拍提交再冲刷
            cmt_we = 2'b11;
            cmt_arn[0*ARN_W +: ARN_W] = r_arn[(r_head+0) & 7'h3f];
            cmt_pd [0*PDW   +: PDW]   = r_pdd[(r_head+0) & 7'h3f];
            cmt_arn[1*ARN_W +: ARN_W] = r_arn[(r_head+1) & 7'h3f];
            cmt_pd [1*PDW   +: PDW]   = r_pdd[(r_head+1) & 7'h3f];
            rel_we = {CMW{1'b0}};
            flush_all = 1'b1;
            @(posedge clk); #1;
            flush_all = 1'b0; cmt_we = {CMW{1'b0}};
            for (bi = 0; bi < 64; bi = bi + 1) r_v[bi] = 1'b0;
            r_head = (r_head + 2) & 7'h3f; r_tail = r_head;
            chk_now();
            while (busy) begin @(posedge clk); #1; chk_now(); end
            chk_now();
            // 重建后再派发，确认不偷用活 PRF
            build_block(3, 3'b111, 5'd20, 5'd21, 5'd22, 5'd0);
            fire_block(3);
        end
    endtask

    // ---- 控制：同拍"提交 + 回滚" ----
    task c_cmt_restore_same;
        begin
            build_block(4, 4'b1111, 5'd1, 5'd2, 5'd3, 5'd4);
            fire_block(4);
            commit_n(1);
            build_block(4, 4'b1111, 5'd5, 5'd6, 5'd7, 5'd8);
            fire_block(4);
            // 同拍提交 lane0 + 回滚到索引 5
            cmt_we = 2'b01;
            cmt_arn[0*ARN_W +: ARN_W] = r_arn[(r_head) & 7'h3f];
            cmt_pd [0*PDW   +: PDW]   = r_pdd[(r_head) & 7'h3f];
            rel_we = 2'b01;
            rel_preg[0*PDW +: PDW]    = r_pdo[(r_head) & 7'h3f];
            restore_rob_valid = 1'b1; restore_rob_idx = 6'd5;
            @(posedge clk); #1;
            restore_rob_valid = 1'b0; cmt_we = {CMW{1'b0}}; rel_we = {CMW{1'b0}};
            r_v[(r_head) & 7'h3f] = 1'b0;
            r_head = (r_head + 1) & 7'h3f;
            for (bi = 0; bi < 64; bi = bi + 1)
                if (age_of(bi[ROBW-1:0], r_head) > age_of({1'b0, 6'd5}, r_head)) r_v[bi] = 1'b0;
            r_tail = (6'd5 + 1'b1) & 7'h3f;
            chk_now();
            build_block(2, 2'b11, 5'd30, 5'd31, 5'd0, 5'd0);
            fire_block(2);
        end
    endtask

    //==========================================================================
    // 9. 触发向量（旧源码必须 DEFECT_SIG）
    //==========================================================================

    // ---- 8: 02-2 基础 —— 回滚后同组 dst 掩码残留 ----
    task c_t_mask_basic;
        begin
            // idx0 写目的（分支），idx1 错路写目的
            build_block(2, 2'b11, 5'd5, 5'd6, 5'd0, 5'd0);
            fire_block(2);
            rollback_to(6'd0, 1'b0, 4'd0);          // 回滚到 idx0
            // 正确路径：idx1 = 不写目的（nop，arn 字段=0，真实译码口径）
            build_block(2, 2'b00, 5'd0, 5'd9, 5'd0, 5'd0);
            fire_block(2);                           // idx1, idx2
            rollback_to(6'd2, 1'b0, 4'd0);           // 回滚到 idx2
        end
    endtask

    // ---- 9: 02-2 审计原始序列（再回滚一次 + 继续派发）----
    task c_t_mask_audit;
        begin
            build_block(2, 2'b11, 5'd5, 5'd6, 5'd0, 5'd0);
            fire_block(2);                           // idx0, idx1
            rollback_to(6'd0, 1'b0, 4'd0);
            build_block(3, 3'b000, 5'd0, 5'd0, 5'd9, 5'd0);
            fire_block(3);                           // idx1(nop), idx2(分支)
            rollback_to(6'd2, 1'b0, 4'd0);
            build_block(3, 3'b111, 5'd7, 5'd8, 5'd10, 5'd0);
            fire_block(3);
            commit_n(2);
            // 再次回到 idx2，验证 free-list 未被多计
            rollback_to(6'd2, 1'b0, 4'd0);
            build_block(2, 2'b11, 5'd11, 5'd12, 5'd0, 5'd0);
            fire_block(2);
        end
    endtask

    // 用 nop 填满 ROB，使 tail 环绕回组内 lane 0 而 head 仍在组内
    //   start = 起始分配索引；fill_n = 分配条数；dst_idx = 在哪个（模 64）索引写目的
    task fill_rob_nops(input integer start, input integer fill_n,
                        input integer dst_idx, input [4:0] dst_arn);
        integer t, base, nd;
        begin
            for (t = 0; t < fill_n; ) begin
                base = (start + t) & 7'h3f;
                // 每次派发至多 4 条；块内索引连续（真实 rb_ix_w 口径）
                if ((r_tail & 7'h3f) != base[5:0]) begin
                    // 需要对齐：逐条派发（块长按到 dst_idx 的距离裁剪）
                    build_block(1, 1'b0, 5'd0, 5'd0, 5'd0, 5'd0);
                    fire_block(1);
                    t = t + 1;
                end else begin
                    nd = 0;
                    if (dst_idx >= 0 && ((start + t) & 7'h3f) == (dst_idx & 7'h3f)) nd = 1;
                    if (nd) begin
                        build_block(1, 1'b1, dst_arn, 5'd0, 5'd0, 5'd0);
                    end else begin
                        build_block(1, 1'b0, 5'd0, 5'd0, 5'd0, 5'd0);
                    end
                    fire_block(1);
                    t = t + 1;
                end
            end
        end
    endtask

    // 以 64 bit "写目的" 位图逐条填 ROB：索引 idx ∈ [start, start+fill_n) 若 bmp[idx] 则
    // 该 lane 写目的（arn 从 arn_base 起循环 1..30），否则为不写目的的 nop。
    //   ★ 位图口径是为了让"中间分配"真的改变 fhead/RAT ⇒ 环绕重写组基后旧段快照与
    //     新世代状态可区分（否则两个状态恰好相同，缺陷不可观测）。
    task fill_rob_bmp(input integer start, input integer fill_n,
                      input [63:0] bmp, input integer arn_base);
        integer t, idx, nd, arn, ac;
        begin
            ac = 0;
            for (t = 0; t < fill_n; t = t + 1) begin
                idx = (start + t) & 7'h3f;
                nd  = bmp[idx];
                arn = 0;
                if (nd) begin
                    arn = ((arn_base - 1 + ac) % 30) + 1;
                    ac  = ac + 1;
                end
                build_block(1, nd ? 1'b1 : 1'b0, arn, 5'd0, 5'd0, 5'd0);
                fire_block(1);
            end
            if (ac > 32) begin
                errs = errs + 1;
                $display("CHK 向量构造错误：写目的 lane 数 %0d > 空闲容量 32", ac);
            end
        end
    endtask

    task commit_many(input integer n);
        integer t;
        begin
            t = 0;
            while (t < n) begin
                if ((n - t) >= 2) begin commit_n(2); t = t + 2; end
                else begin commit_n(1); t = t + 1; end
            end
        end
    endtask

    // ---- 10: 02-3 group0 —— head 在组 0 lane 1..3，tail 环绕回 lane 0 ----
    task c_t_wrap_group0;
        reg [63:0] bmp;
        begin
            // 分配 idx0..idx63：idx3..idx20 写目的（老段 + 中间差异），其余 nop；
            // 再提交 idx0 使 head=1（idx1..3 = 组 0 旧段仍活）
            bmp = 64'h0;
            for (rr = 3; rr <= 20; rr = rr + 1) bmp[rr] = 1'b1;
            fill_rob_bmp(0, 64, bmp, 1);
            commit_n(1);                       // head = 1
            // tail 环绕到 idx0：分配新 idx0（旧实现重写 group0 基/mask/RAT 快照）
            build_block(1, 1'b0, 5'd0, 5'd0, 5'd0, 5'd0);
            fire_block(1);
            // 老分支 idx3 误判 → 回滚到 idx3（旧段仍活）
            rollback_to(6'd3, 1'b0, 4'd0);
            build_block(2, 2'b11, 5'd6, 5'd7, 5'd0, 5'd0);
            fire_block(2);
        end
    endtask

    // ---- 11: 02-3 一般组（非 0 组）分裂 + 回滚进旧段 ----
    task c_t_wrap_midgroup;
        reg [63:0] bmp;
        begin
            // idx0..63：idx21/22/23（组 5 旧段）与 idx40..50 写目的 ⇒ 中间状态差异
            bmp = 64'h0;
            for (rr = 21; rr <= 23; rr = rr + 1) bmp[rr] = 1'b1;
            for (rr = 40; rr <= 50; rr = rr + 1) bmp[rr] = 1'b1;
            fill_rob_bmp(0, 64, bmp, 1);
            // 提交 idx0..20 使 head=21（组 5 lane 1）；尾部表项 21..63 仍活
            commit_many(21);
            // tail 环绕：重派发 idx0..idx20（全 nop，不额外消耗空闲表）；idx20 = 组 5 lane 0
            //   ⇒ 旧实现在此处重写组 5 基/mask/RAT 快照，抹掉旧段 [21..23]
            fill_rob_bmp(0, 21, 64'h0, 1);
            // 老段仍活 → 回滚到旧段首 lane（旧实现读到新世代基 ⇒ fhead/RAT 全错）
            rollback_to(6'd21, 1'b0, 4'd0);
            build_block(2, 2'b11, 5'd8, 5'd9, 5'd0, 5'd0);
            fire_block(2);
            // 再回滚到旧段中间 lane（走"影子整段搬回组表"路径）
            rollback_to(6'd22, 1'b0, 4'd0);
            build_block(2, 2'b11, 5'd10, 5'd11, 5'd0, 5'd0);
            fire_block(2);
        end
    endtask

    // ---- 12: 02-3 压力 —— 多次分裂 + 旧段/新段交替回滚 ----
    task c_t_wrap_stress;
        integer t;
        reg [63:0] bmp;
        begin
            // 两次"环绕分裂 + 进旧段（整体搬回）+ 再分裂"的交替序列
            bmp = 64'h0;
            for (rr = 3; rr <= 20; rr = rr + 1) bmp[rr] = 1'b1;
            for (rr = 40; rr <= 48; rr = rr + 1) bmp[rr] = 1'b1;
            fill_rob_bmp(0, 64, bmp, 1);
            commit_n(1);                          // head=1（组 0 旧段 1..3 活）
            fill_rob_bmp(0, 2, 64'h0, 1);         // 环绕回组 0 lane0 → 分裂
            rollback_to(6'd3, 1'b0, 4'd0);        // 进旧段 → 影子整段搬回
            fill_rob_bmp(4, 3, 64'h0, 1);         // 继续从 4 派发
            rollback_to(6'd5, 1'b0, 4'd0);        // 再进旧段
            for (t = 0; t < 5; t = t + 1) begin
                fill_rob_bmp(4 + t, 2, 64'h0, 1);
                if (((r_tail - r_head) & 7'h3f) > 4) begin
                    rk = (r_head + ((r_tail - r_head) & 7'h3f) - 1) & 7'h3f;
                    rollback_to(rk, 1'b0, 4'd0);
                end
                build_block(1, 1'b1, (14+t), 5'd0, 5'd0, 5'd0);
                fire_block(1);
            end
        end
    endtask

    // ---- 13: 高物理号活跃 + 回滚（不得一概置 free）----
    task c_t_high_preg_rollback;
        begin
            // 制造大量高物理号活跃：连续 16 条写目的（消耗 preg32..47）
            build_block(4, 4'b1111, 5'd1, 5'd2, 5'd3, 5'd4);
            fire_block(4);
            build_block(4, 4'b1111, 5'd5, 5'd6, 5'd7, 5'd8);
            fire_block(4);
            build_block(4, 4'b1111, 5'd9, 5'd10, 5'd11, 5'd12);
            fire_block(4);
            build_block(4, 4'b1111, 5'd13, 5'd14, 5'd15, 5'd16);
            fire_block(4);
            check_high_pregs_active;
            // 错路更年轻 lane 写目的，再回滚到更早 lane；随后正确路径落 nop
            build_block(2, 2'b11, 5'd20, 5'd21, 5'd0, 5'd0);
            fire_block(2);
            rollback_to(6'd16, 1'b0, 4'd0);          // 回滚到 lane 0 of group4 之前的索引
            //   正确路径在 idx17/18 落"不写目的"的 nop（真实 decode 口径 arn=0）
            build_block(2, 2'b00, 5'd0, 5'd0, 5'd0, 5'd0);
            fire_block(2);
            rollback_to(6'd18, 1'b0, 4'd0);
            // 恢复后继续分配：不得偷用活跃高物理号
            build_block(2, 2'b11, 5'd23, 5'd24, 5'd0, 5'd0);
            fire_block(2);
        end
    endtask

    // ---- 14/15: 随机混合（合法序列；14=轻量控制，15=含分裂控制）----
    //   `allow_wrap`=0 ⇒ 控制向量：把 ROB 占用压到 ≤40 项（分裂需要 cnt≥61）且**不做回滚**
    //   （避开 02-2 的"回滚后同组掩码残留"路径）⇒ 新旧实现都必须正确；
    //   `allow_wrap`=1 ⇒ 触发向量：允许占满并随机回滚，会走到环绕分裂 / 掩码残留路径。
    task rand_mix(input integer ncyc, input integer allow_wrap);
        integer t, n, ndm, live, npick, cap;
        begin
            cap = allow_wrap ? 64 : 40;
            wait_commit_en = 1'b1;
            fill_rob_nops(0, 8, -1, 5'd0);
            for (t = 0; t < ncyc; t = t + 1) begin
                npick = {$random(seed)} % 100;
                live = (r_tail - r_head) & 7'h3f;
                if ((npick < 45) && (live < cap)) begin
                    n = 1 + ({$random(seed)} % 4);
                    if ((live + n) > cap) n = cap - live;
                    ndm = {$random(seed)} & 4'hf;
                    if (ndm == 4'h0) ndm = 4'h1;
                    build_block(n, ndm[W-1:0],
                                ({$random(seed)} % 30) + 1,
                                ({$random(seed)} % 30) + 1,
                                ({$random(seed)} % 30) + 1,
                                ({$random(seed)} % 30) + 1);
                    fire_block(n);
                end else if (npick < 65 || (live >= cap)) begin
                    commit_n(1 + ({$random(seed)} % CMW));
                end else if (npick < 80) begin
                    live = (r_tail - r_head) & 7'h3f;
                    if (allow_wrap && (live > 0)) begin
                        rk = (r_head + ({$random(seed)} % live)) & 7'h3f;
                        rollback_to(rk, ({$random(seed)} % 2), 4'd1);
                    end else if (!allow_wrap) begin
                        commit_n(1);      // 控制模式：不产生回滚
                    end
                end else if (npick < (allow_wrap ? 92 : 88)) begin
                    idle_cycle;
                end else begin
                    // 检查点保存
                    snap_valid = 1'b1;
                    snap_id    = {$random(seed)} % 16;
                    snap_lane  = {$random(seed)} % 4;
                    @(posedge clk); #1;
                    snap_valid = 1'b0;
                    chk_now();
                end
            end
            commit_n(2);
            wait_commit_en = 1'b0;
        end
    endtask

    // ---- 16: 审阅 P1 最短反证 —— 死组重入抢走仍活旧组的共享影子 ----
    //   ① 分配 idx0..63（idx3 与中间若干 lane 写目的 ⇒ 状态差异），提交 idx0 ⇒ head=1；
    //   ② 新 idx0（group0 lane0，rb_g_init[0]=1）⇒ 真分裂：影子 = group0 旧段 [1..3]（仍活）；
    //   ③ 年轻老分支 idx31 误判 → rollback 到 31：新 idx0 被杀，旧 idx1..3 仍活；
    //   ④ 重派发 idx32（group8 lane0）。group8 在 ① 进入过（rb_g_init[8]=1），但其旧
    //      lane 33..35 已被 ③ 杀掉 —— 这是**死组重入**而非分裂；若仍判为 split 就会把
    //      group0 仍活的影子覆盖掉（审阅定性的 1746 候选缺陷）；
    //   ⑤ 老 idx3 回滚：只能读到 group0 的新段基 ⇒ fhead/RAT 全错（黄金模型即时报红）。
    task c_t_shadow_steal_min;
        reg [63:0] bmp;
        begin
            bmp = 64'h0;
            for (rr = 3; rr <= 20; rr = rr + 1) bmp[rr] = 1'b1;
            for (rr = 40; rr <= 50; rr = rr + 1) bmp[rr] = 1'b1;
            fill_rob_bmp(0, 64, bmp, 1);
            commit_n(1);
            fill_rob_bmp(0, 1, 64'h0, 1);
            rollback_to(6'd31, 1'b0, 4'd0);
            fill_rob_bmp(32, 1, 64'h0, 1);
            rollback_to(6'd3, 1'b0, 4'd0);
            build_block(2, 2'b11, 5'd6, 5'd7, 5'd0, 5'd0);
            fire_block(2);
        end
    endtask

    // ---- 17: 同组二次 split 覆盖仍活旧段（审阅"较长同组重入"）----
    task c_t_same_group_2nd;
        reg [63:0] bmp;
        begin
            bmp = 64'h0;
            for (rr = 21; rr <= 23; rr = rr + 1) bmp[rr] = 1'b1;
            for (rr = 40; rr <= 50; rr = rr + 1) bmp[rr] = 1'b1;
            fill_rob_bmp(0, 64, bmp, 1);
            commit_many(21);
            fill_rob_bmp(0, 20, 64'h0, 1);
            fill_rob_bmp(20, 1, 64'h0, 1);          // 第一次分裂
            rollback_to(6'd19, 1'b0, 4'd0);
            fill_rob_bmp(20, 1, 64'h0, 1);          // 同组二次 split（旧段 21..23 仍活）
            rollback_to(6'd21, 1'b0, 4'd0);
            build_block(2, 2'b11, 5'd8, 5'd9, 5'd0, 5'd0);
            fire_block(2);
        end
    endtask

    // ---- 18: 死组重入 + 回滚后继续分配（不偷活 PRF）----
    task c_t_dead_reentry_alloc;
        reg [63:0] bmp;
        begin
            bmp = 64'h0;
            for (rr = 3; rr <= 20; rr = rr + 1) bmp[rr] = 1'b1;
            fill_rob_bmp(0, 64, bmp, 1);
            commit_n(1);
            fill_rob_bmp(0, 1, 64'h0, 1);
            rollback_to(6'd31, 1'b0, 4'd0);
            fill_rob_bmp(32, 2, 64'h0, 1);
            rollback_to(6'd3, 1'b0, 4'd0);
            build_block(2, 2'b11, 5'd19, 5'd20, 5'd0, 5'd0);
            fire_block(2);
            fill_rob_bmp(4, 3, 64'h0, 1);
            commit_n(2);
            rollback_to(6'd5, 1'b0, 4'd0);
            build_block(3, 3'b111, 5'd21, 5'd22, 5'd23, 5'd0);
            fire_block(3);
        end
    endtask

    // ---- 19: 控制 —— 完全合法的"回滚后继续分配"（不触发环绕分裂）----
    task c_ctrl_post_rb_alloc;
        integer t;
        begin
            build_block(4, 4'b1111, 5'd1, 5'd2, 5'd3, 5'd4);
            fire_block(4);
            build_block(4, 4'b1111, 5'd5, 5'd6, 5'd7, 5'd8);
            fire_block(4);
            commit_n(2);
            rollback_to(6'd3, 1'b0, 4'd0);
            for (t = 0; t < 6; t = t + 1) begin
                build_block(2, 2'b11, (t % 28) + 1, ((t + 5) % 28) + 1, 5'd0, 5'd0);
                fire_block(2);
                commit_n(1);
            end
            rollback_to(6'd7, 1'b0, 4'd0);
            build_block(3, 3'b111, 5'd11, 5'd12, 5'd13, 5'd0);
            fire_block(3);
            commit_n(2);
            check_high_pregs_active;
        end
    endtask

    //==========================================================================
    // 10. 浮点域 f0 可写（第二实例：NSRC=3）
    //==========================================================================
    reg  [W-1:0]        f_lane_valid;
    reg                 f_lane_fire;
    reg  [W-1:0]        f_need_dst;
    reg  [W*ARN_W-1:0]  f_dst_arn;
    reg  [W*3-1:0]      f_need_s;
    reg  [W*3*ARN_W-1:0] f_s_arn;
    wire [W*PDW-1:0]    f_pd_dst, f_pd_old;
    wire [W*3*PDW-1:0]  f_pd_s;
    wire                f_free_ok;
    wire [7:0]          f_free_cnt;
    wire                f_busy;

    rename #(.W(W), .CMW(CMW), .NSRC(3), .PDW(PDW), .NREG(NREG), .FREE_N(FREE_N),
             .ARCH_N(ARCH_N), .ARN_W(ARN_W), .FL_PTR_W(FL_PTR_W), .ROB_IDX_W(ROB_IDX_W),
             .CHK(0), .TRACE(0), .TRB(0))
    dut_f (
        .clk(clk), .rst_n(rst_n),
        .lane_valid(f_lane_valid), .lane_fire(f_lane_fire),
        .lane_need_dst(f_need_dst), .lane_dst_arn(f_dst_arn),
        .lane_need_s(f_need_s), .lane_s_arn(f_s_arn),
        .lane_pd_dst(f_pd_dst), .lane_pd_old(f_pd_old), .lane_pd_s(f_pd_s),
        .free_ok(f_free_ok), .free_cnt_o(f_free_cnt),
        .cmt_we({CMW{1'b0}}), .cmt_arn({(CMW*ARN_W){1'b0}}), .cmt_pd({(CMW*PDW){1'b0}}),
        .rel_we({CMW{1'b0}}), .rel_preg({(CMW*PDW){1'b0}}),
        .rob_snap_valid(~f_busy), .rob_snap_idx({6'd3, 6'd2, 6'd1, 6'd0}),
        .snap_valid(1'b0), .snap_id(4'd0), .snap_lane(2'd0),
        .restore_valid(1'b0), .restore_id(4'd0),
        .restore_rob_valid(1'b0), .restore_rob_idx(6'd0),
        .flush_all(1'b0), .busy(f_busy), .log_wr_o(), .cnt_restore_o()
    );

    task c_fp_f0_writable;
        reg [PDW-1:0] fpd;
        begin
            // f0 是正常可写架构寄存器：需要目的即分配真实物理号（非 0）
            f_lane_valid = 4'b0001;
            f_lane_fire  = 1'b1;
            f_need_dst   = 4'b0001;         // arn=0（f0）需要目的
            f_dst_arn[0*ARN_W +: ARN_W] = 5'd0;
            f_need_s     = {(W*3){1'b0}};
            f_s_arn      = {(W*3*ARN_W){1'b0}};
            @(negedge clk);                  // 沿前采样组合输出
            fpd = f_pd_dst[0*PDW +: PDW];
            @(posedge clk); #1;
            chk_now();
            f_lane_fire = 1'b0;
            if (fpd === 6'd0) begin
                errs = errs + 1;
                $display("CHK f0 未被分配真实物理号（pd_dst=0）");
            end
            // 再派发一条读 f0 的指令：pd_s 必须等于刚才的新映射（确实可写）
            f_lane_valid = 4'b0001;
            f_lane_fire  = 1'b1;
            f_need_dst   = 4'b0000;
            f_dst_arn[0*ARN_W +: ARN_W] = 5'd0;
            f_need_s     = {(W*3){1'b0}};
            f_need_s[0*3 + 0] = 1'b1;
            f_s_arn[0*ARN_W +: ARN_W] = 5'd0;
            @(negedge clk);
            fpd = f_pd_s[0*PDW +: PDW];
            @(posedge clk); #1;
            chk_now();
            f_lane_fire = 1'b0;
            if (fpd !== 6'd32) begin
                // 复位后 f0..f31 映射 0..31，f0 新分配应为 free head = 32
                errs = errs + 1;
                $display("CHK f0 读源映射=%0d 期望 32（f0 可写）", fpd);
            end
            f_lane_valid = 4'b0000;
            f_need_s = {(W*3){1'b0}};
            // 对照：整数域 x0 不可写（nd 恒 0），读源恒 0
            check_x0_reads;
            idle_cycle;
        end
    endtask

    //==========================================================================
    // 11. 用例调度 + 输出
    //==========================================================================
    integer case_sel;
    integer case_arg;
    integer verbose;   // +VERBOSE：打印动作轨迹（诊断用；默认静默）
    reg [8*28-1:0] cname;
    reg [8*8-1:0]  ckind;

    // 所有向量跑完后再做一段常规活动：既提高每向量检查数（防"少跑"），
    // 又验证"恢复后继续分配"路径在收尾阶段仍不偷用活 PRF。
    task post_activity;
        integer t;
        begin
            wait_commit_en = 1'b1;     // 收尾活动同样允许停顿中退休，避免忙等
            for (t = 0; t < 10; t = t + 1) begin
                build_block(2, 2'b11, (t%29)+1, ((t+7)%29)+1, 5'd0, 5'd0);
                fire_block(2);
                commit_n(1);
            end
            commit_n(2);
            wait_commit_en = 1'b0;
        end
    endtask

    task run_case(input integer c);
        begin
            ckind = is_trigger(c) ? "trigger" : "control";
            case (c)
                0:  begin cname="int_x0_hard_zero";      c_x0_hard_zero;   end
                1:  begin cname="fp_f0_writable";        c_fp_f0_writable; end
                2:  begin cname="basic_commit_release";  c_basic_commit;   end
                3:  begin cname="ckpt_save_restore";     c_ckpt_save_restore; end
                4:  begin cname="missing_ckpt_rob";      c_missing_ckpt;   end
                5:  begin cname="flush_rebuild_high";    c_flush_rebuild;  end
                6:  begin cname="cmt_flush_same_cycle";  c_flush_rebuild;  end
                7:  begin cname="cmt_restore_same";      c_cmt_restore_same; end
                8:  begin cname="t_mask_residue_basic";  c_t_mask_basic;   end
                9:  begin cname="t_mask_residue_audit";  c_t_mask_audit;   end
                10: begin cname="t_wrap_group0";         c_t_wrap_group0;  end
                11: begin cname="t_wrap_midgroup";       c_t_wrap_midgroup; end
                12: begin cname="t_wrap_stress";         c_t_wrap_stress;  end
                13: begin cname="t_high_preg_rollback";  c_t_high_preg_rollback; end
                14: begin cname="rand_mix_light";        rand_mix(120, 0); end
                15: begin cname="rand_mix_split";        rand_mix(160, 1); end
                16: begin cname="t_shadow_steal_min";    c_t_shadow_steal_min; end
                17: begin cname="t_same_group_2nd";      c_t_same_group_2nd;   end
                18: begin cname="t_dead_reentry_alloc";  c_t_dead_reentry_alloc; end
                19: begin cname="ctrl_post_rb_alloc";    c_ctrl_post_rb_alloc; end
                default: begin cname="unknown"; end
            endcase
            post_activity;
        end
    endtask

    initial begin
        case_sel = 0;
        if (!$value$plusargs("CASE=%d", case_sel)) case_sel = 0;
        verbose = 0;
        if ($test$plusargs("VERBOSE")) verbose = 1;

        if (case_sel < 0 || case_sel >= TOTAL_CASES) begin
            $display("CASE %0d invalid_case VERDICT=DEFECT_SIG", case_sel);
            $finish;
        end
        seed = 32'hF2_0000 + case_sel;      // 固定种子 ⇒ 可复现
        errs = 0; nchk = 0; chk_en = 0; errs_dumped = 0;
        do_reset;
        chk_en = 1;
        run_case(case_sel);
        chk_en = 0;
        if (nchk < 20) begin
            errs = errs + 1;
            $display("CHK 用例过短 nchk=%0d（少跑即判失败）", nchk);
        end
        if (errs == 0)
            $display("CASE %0d %0s KIND=%0s VERDICT=OK nchk=%0d",
                     case_sel, cname, ckind, nchk);
        else
            $display("CASE %0d %0s KIND=%0s VERDICT=DEFECT_SIG nchk=%0d",
                     case_sel, cname, ckind, nchk);
        $finish;
    end

    // 超时兜底：脚本另有墙钟超时；此处防止 TB 自身死锁
    initial begin
        #2_000_000;
        $display("CASE %0d %0s KIND=%0s VERDICT=DEFECT_SIG reason=timeout",
                 case_sel, cname, ckind);
        $finish;
    end

endmodule
