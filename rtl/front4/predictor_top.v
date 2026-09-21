//==============================================================================
// rtl/front4/predictor_top.v —— 锦标赛分支预测器顶层（Gshare + 局部 + 选择器 +
//                              BTB + RAS + GHR 推测/检查点 + 准确率统计）
//==============================================================================
// 项目  : rv32gc-cpu（阶段二 2B-1：四发射顺序前端 + 锦标赛分支预测器）
// 规格  : docs/design/04-predictor.md 全文——
//           §2      总体结构（F2 查表 → F1 下一拍用；表实现约束）
//           §3.1–3.3 三分量结构参数 / 选择器状态机 / **训练时机 = 提交点**
//           §4      BTB（2048×2 路）与 RAS（16 项，溢出不压入，D2 修复）
//           §5.2    各表更新规则；§5.3 GHR 与推测态恢复（默认方案 A，可选方案 B）
//           §5.4    误判恢复流程（与后端协同；本模块只管 RAS/GHR 快照）
//           §6.1    统计计数器口径（bpu_*）
//         docs/design/02-pipeline.md §3.2（F2）、§4.2（一拍错位）、§6.1（类别 A/D）
//
// 【接口三段（也是与 2B-2 的衔接点）】
//   ① 查表段 `lu_*`：给 ifetch4 用——一拍 1 个字（2 个 parcel），结果**下一拍**有效；
//      输出：两分量方向、选择器选择、最终方向（投票）、BTB 命中/目标/类型、RAS 顶。
//   ② 提交训练段 `train_*`：由 ROB 在 W1 驱动，**1 条/拍**语义（内部 8 项 FIFO 吸收
//      突发；溢出计数 bpu_train_overflow 可见）。事件必须携带"预测时"的信息：
//      {gpred, lpred, sel_global 已合成为最终预测}、{pred_target, btb_hit, btb_way}
//      ——理由见 04 §3.2/§3.3：计数器与选择器只能用**当时**的预测来训练，
//      否则学的是被后续训练改过的表。
//   ③ 检查点段 `ckpt_*`：分支推测点分配（16 项，03 §3.4），误判重定向按 id 恢复
//      RAS 深度（+ 方案 B 时的 GHR）；后端提交时释放。
//
// 【GHR 方案选择】`SPEC_GHR=0`（默认）= 04 §5.3 **方案 A**：GHR 只在提交点更新，
//   误判无需回滚（消除一整类恢复静默错）。`SPEC_GHR=1` = 方案 B：GHR 亦为推测态，
//   随预测推进，检查点保存/恢复 GHR 快照。**两种模式都实现并通过单元 TB**，
//   默认取方案 A（与文档定稿一致）。
//
// 【反证实验钩子】`SEL_FORCE`：0 = 正常投票；1 = 恒选 Gshare；2 = 恒选局部。
//   仅供**反证实验/TB**使用（默认 0，综合不使用）——见 README §6 的
//   "选择器恒接一侧 ⇒ 准确率必降、断言必红"证据。
//==============================================================================

`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"
`include "rtl/front4/front4_params.vh"

module predictor_top #(
    parameter integer SPEC_GHR  = 0,      // 0 = 方案 A（默认）；1 = 方案 B（推测 GHR + 回滚）
    parameter integer SEL_FORCE = 0,      // 0 = 正常；1 = 恒 Gshare；2 = 恒局部（反证用）
    parameter integer TRAIN_FIFO_DEPTH = `FRONT4_TRAIN_FIFO_DEPTH,
    parameter integer CKPT_NUM = `FRONT4_CKPT_NUM,
    parameter integer RAS_DEPTH = `FRONT4_RAS_DEPTH
) (
    input  wire         clk,
    input  wire         rst_n,

    //==================================================================
    // ① 查表段（F2）：一拍 1 个字（2 个 parcel）
    //==================================================================
    input  wire         lu_en,
    input  wire [31:0]  lu_pc0,
    input  wire [31:0]  lu_pc1,
    output wire         lu_valid_o,
    output wire         lu_taken0,          // 锦标赛最终方向（2 个 parcel 各一份）
    output wire         lu_taken1,
    output wire         lu_gdir0,           // Gshare 侧方向（统计/训练携带）
    output wire         lu_gdir1,
    output wire         lu_ldir0,           // 局部侧方向
    output wire         lu_ldir1,
    output wire         lu_selg0,           // 选择器选了全局侧
    output wire         lu_selg1,
    output wire         lu_btb_hit,
    output wire         lu_btb_way,
    output wire [31:0]  lu_btb_target,
    output wire         lu_btb_cond,
    output wire         lu_btb_call,
    output wire         lu_btb_ret,
    output wire [31:0]  lu_ras_top,         // 与查表结果同拍的 RAS 栈顶
    output wire         lu_ras_empty,
    output wire [`FRONT4_LU_PACK_W-1:0] lu_pack_o,   // 打包结果（位段见 front4_params.vh §8）

    //==================================================================
    // ② RAS 的 D2 侧（压/弹/修复；由译码确认后驱动）
    //==================================================================
    input  wire         ras_push_valid,
    input  wire [31:0]  ras_push_addr,
    input  wire         ras_pop_valid,
    input  wire [31:0]  ras_pop_addr,
    output wire         ras_repair_valid,
    output wire [31:0]  ras_repair_addr,
    input  wire         ras_flush_all,
    input  wire         ras_cmt_push_valid,
    input  wire         ras_cmt_pop_valid,

    //==================================================================
    // ③ 提交训练段（1 条/事件）
    //==================================================================
    input  wire         train_valid,
    input  wire [31:0]  train_pc,
    input  wire         train_is_cond,      // 条件分支（更新 GHR/GPHT/LHT/LPHT/选择器）
    input  wire         train_taken,        // 实际方向
    input  wire         train_is_indirect,  // 间接跳转（jalr 非返回）⇒ BTB 分配
    input  wire         train_is_call,      // jal/c.jal（rd=ra）⇒ BTB 分配
    input  wire         train_is_return,    // ret ⇒ BTB 分配
    input  wire [31:0]  train_target,       // 实际目标
    input  wire         train_pred_taken,   // 预测时的**最终**方向（锦标赛投票结果）
    input  wire         train_pred_sel_global, // 预测时选择器选了全局侧（统计 bpu_sel_*）
    input  wire         train_pred_gdir,    // 预测时的 Gshare 方向
    input  wire         train_pred_ldir,    // 预测时的局部方向
    input  wire [31:0]  train_pred_target,  // 预测时的目标（0 = 无预测）
    input  wire         train_pred_valid,   // 预测时是否有目标预测
    input  wire         train_btb_hit,      // 预测时 BTB 是否命中
    input  wire         train_btb_way,      // 预测时命中哪一路
    output wire         train_ready,        // FIFO 未满
    output wire         upd_busy,           // 训练引擎忙（TB 排空用）

    //==================================================================
    // ④ 检查点（分支推测点；RAS 深度 + 方案 B 的 GHR 快照）
    //==================================================================
    input  wire         ckpt_alloc_valid,
    input  wire [31:0]  ckpt_alloc_pc,      // 分配该检查点的分支 PC（诊断/统计）
    output wire [3:0]   ckpt_alloc_id,
    output wire         ckpt_full,
    input  wire         ckpt_free_valid,
    input  wire [3:0]   ckpt_free_id,
    input  wire         ckpt_restore_valid,
    input  wire [3:0]   ckpt_restore_id,

    //==================================================================
    // ⑤ 统计（04 §6.1 口径；自由运行 32 bit，软件读后清零）
    //==================================================================
    output wire [31:0]  bpu_br_total,
    output wire [31:0]  bpu_br_mispred,
    output wire [31:0]  bpu_dir_mispred,
    output wire [31:0]  bpu_target_mispred,
    output wire [31:0]  bpu_gshare_right,
    output wire [31:0]  bpu_local_right,
    output wire [31:0]  bpu_sel_global,
    output wire [31:0]  bpu_sel_local,
    output wire [31:0]  bpu_ras_push,
    output wire [31:0]  bpu_ras_pop,
    output wire [31:0]  bpu_ras_overflow,
    output wire [31:0]  bpu_ras_repair,
    output wire [31:0]  bpu_ckpt_full_stall,
    output wire [31:0]  bpu_train_overflow,
    output wire [31:0]  bpu_btb_alloc,
    output wire [15:0]  ghr_o              // GHR 观察（调试/统计接口）
);

    //--------------------------------------------------------------------------
    // 0. 常量
    //--------------------------------------------------------------------------
    localparam integer FIFO_AW = 3;        // TRAIN_FIFO_DEPTH=8 ⇒ 3 bit 指针（+1 bit 计数）

    //--------------------------------------------------------------------------
    // 1'. 前置声明（**必须先声明后使用**：Vivado xvlog 把隐式声明当错误，
    //     iverilog 只当警告 ⇒ 这条门禁只能靠 xvlog 把关，见 README §6）
    //--------------------------------------------------------------------------
    wire        g_lu_valid, l_lu_valid, s_lu_valid;
    wire        g_tk0, g_tk1, l_tk0, l_tk1, s_selg0, s_selg1;
    wire [1:0]  s_ctr0, s_ctr1;
    wire [9:0]  lht_rd0, lht_rd1;
    wire        g_upd_busy, l_upd_busy, s_upd_busy;
    wire        b_lu_valid, b_hit, b_way, b_cond, b_call, b_ret;
    wire [31:0] b_target;
    wire        ras_repair_w, ras_empty_w;
    wire [31:0] ras_top_w;
    wire [4:0]  ras_depth_w;
    wire [31:0] ras_push_c, ras_pop_c, ras_ovf_c, ras_rep_c;
    reg         b_upd_busy_q;            // BTB 更新占用（1 拍；声明前置于此，别处删除）

    //--------------------------------------------------------------------------
    // 3. 检查点表（16 项：{valid, ras_depth[4:0], ghr[15:0]}）
    //--------------------------------------------------------------------------
    reg        ck_valid_q [0:CKPT_NUM-1];
    reg [4:0]  ck_ras_q   [0:CKPT_NUM-1];
    reg [15:0] ck_ghr_q   [0:CKPT_NUM-1];
    reg [3:0]  ck_alloc_q;
    reg [31:0] cnt_ckfull_q;

    // 空闲项查找（**纯 assign + generate 位图 + packed 向量优先级编码**）
    //   ★ 不用"function 内部读存储器"的写法：iverilog 12.0 对该形态有组合求值缺陷
    //     （实测：16 项全空却返回"无空闲"），改用静态索引读 + 纯向量编码，
    //     语义相同（最低编号优先、同拍释放的项可被同拍复用），且可控可查。
    wire [CKPT_NUM-1:0] ck_valid_v;      // 打包视图
    wire [CKPT_NUM-1:0] ck_free_v;       // 逐项"空闲"标志
    genvar cg;
    generate
        for (cg = 0; cg < CKPT_NUM; cg = cg + 1) begin : g_ckv
            assign ck_valid_v[cg] = ck_valid_q[cg];
            assign ck_free_v[cg]  = ~ck_valid_q[cg] &
                                    ~(ckpt_free_valid & (ckpt_free_id == cg[3:0]));
        end
    endgenerate

    // 最低编号优先编码（纯 packed 向量输入 ⇒ 不触碰存储器）
    function [4:0] prio_low_enc;     // {found, id[3:0]}
        input [CKPT_NUM-1:0] m;
        integer pe;
        reg     pf;
        reg [3:0] pid;
        begin
            pf  = 1'b0;
            pid = 4'h0;
            for (pe = CKPT_NUM-1; pe >= 0; pe = pe - 1) begin
                if (m[pe]) begin pf = 1'b1; pid = pe[3:0]; end
            end
            prio_low_enc = {pf, pid};
        end
    endfunction

    wire [4:0] free_enc     = prio_low_enc(ck_free_v);
    wire       free_found_w = free_enc[4];
    wire [3:0] free_id_w    = free_enc[3:0];

    assign ckpt_alloc_id = free_id_w;
    assign ckpt_full     = ~free_found_w;

    wire ck_restore_ok = ckpt_restore_valid & (ckpt_restore_id < CKPT_NUM) &
                         ck_valid_v[ckpt_restore_id];
    wire [4:0]  ckpt_ras_depth = ck_ras_q[ckpt_restore_id];
    wire [15:0] ckpt_ghr_val   = ck_ghr_q[ckpt_restore_id];

    // 方案 B：误判恢复 GHR（方案 A 下 ghr_we 恒 0）
    wire        ghr_we_w    = (SPEC_GHR != 0) & ck_restore_ok;
    wire [15:0] ghr_wdata_w = (SPEC_GHR != 0) ? ckpt_ghr_val : 16'h0;

    integer ck_i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ck_alloc_q    <= 4'h0;
            cnt_ckfull_q  <= 32'h0;
            for (ck_i = 0; ck_i < CKPT_NUM; ck_i = ck_i + 1) begin
                ck_valid_q[ck_i] <= 1'b0;
                ck_ras_q[ck_i]   <= 5'h0;
                ck_ghr_q[ck_i]   <= 16'h0;
            end
        end else begin
            // ---- 释放 ----
            if (ckpt_free_valid && (ckpt_free_id < CKPT_NUM))
                ck_valid_q[ckpt_free_id] <= 1'b0;

            // ---- 分配（快照：RAS 深度 + GHR）----
            if (ckpt_alloc_valid) begin
                if (free_found_w) begin
                    ck_valid_q[free_id_w] <= 1'b1;
                    ck_ras_q[free_id_w]   <= ras_depth_w;
                    ck_ghr_q[free_id_w]   <= ghr_o;
                    ck_alloc_q            <= free_id_w;
                end else begin
                    cnt_ckfull_q <= cnt_ckfull_q + 32'd1;   // 检查点耗尽（前端会停顿）
                end
            end
        end
    end

    //--------------------------------------------------------------------------
    // 4. 训练 FIFO + 派发（1 事件/2 拍；对上层是 1 条/拍 + 8 深缓冲）
    //--------------------------------------------------------------------------
    //  事件字段（**必须携带预测时的记录**，理由见文件头 §2②）：
    //    pc / is_cond / taken / is_call / is_return / is_indirect / target
    //    / pred_taken（最终方向预测） / pred_sel_global / pred_target / pred_valid
    //    / pred_gdir / pred_ldir / btb_hit / btb_way
    localparam integer EV_W = 32 + 5 + 32 + 1 + 1 + 32 + 1 + 1 + 1 + 1 + 1;

    reg [EV_W-1:0] ev_mem [0:TRAIN_FIFO_DEPTH-1];
    reg [FIFO_AW-1:0] ev_wp_q, ev_rp_q;
    reg [FIFO_AW:0]   ev_cnt_q;

    initial begin
        if (TRAIN_FIFO_DEPTH != (1 << FIFO_AW)) begin
            $display("PREDICTOR_TOP FAIL: TRAIN_FIFO_DEPTH=%0d 与 FIFO_AW=%0d 不匹配",
                     TRAIN_FIFO_DEPTH, FIFO_AW);
            $fatal(1, "PREDICTOR_TOP TRAIN FIFO GEOMETRY MISMATCH");
        end
    end

    wire ev_empty = (ev_cnt_q == 0);
    wire ev_full  = (ev_cnt_q == TRAIN_FIFO_DEPTH);

    function [EV_W-1:0] pack_ev;
        input [31:0] pc;   input is_c;  input tk;    input is_call; input is_ret;
        input is_ind;      input [31:0] tgt;         input p_tk;     input p_selg;
        input [31:0] p_tgt;input p_valid;            input p_gd;     input p_ld;
        input bh;          input bw;
        begin
            pack_ev = {pc, is_c, tk, is_call, is_ret, is_ind, tgt,
                       p_tk, p_selg, p_tgt, p_valid, p_gd, p_ld, bh, bw};
        end
    endfunction

    wire [EV_W-1:0] ev_in = pack_ev(train_pc, train_is_cond, train_taken,
                                    train_is_call, train_is_return, train_is_indirect,
                                    train_target,
                                    train_pred_taken, train_pred_sel_global,
                                    train_pred_target, train_pred_valid,
                                    train_pred_gdir, train_pred_ldir,
                                    train_btb_hit, train_btb_way);

    // 解包（位段自高到低与 pack_ev 一致；用 function 反向切开，避免手算魔法数）
    wire [31:0] ev_pc            = ev_mem[ev_rp_q][EV_W-1 -: 32];
    wire        ev_is_cond       = ev_mem[ev_rp_q][EV_W-33];
    wire        ev_taken         = ev_mem[ev_rp_q][EV_W-34];
    wire        ev_is_call       = ev_mem[ev_rp_q][EV_W-35];
    wire        ev_is_ret        = ev_mem[ev_rp_q][EV_W-36];
    wire        ev_is_indir      = ev_mem[ev_rp_q][EV_W-37];
    wire [31:0] ev_target        = ev_mem[ev_rp_q][EV_W-38 -: 32];
    wire        ev_pred_taken    = ev_mem[ev_rp_q][EV_W-70];
    wire        ev_pred_selg     = ev_mem[ev_rp_q][EV_W-71];
    wire [31:0] ev_pred_target   = ev_mem[ev_rp_q][EV_W-72 -: 32];
    wire        ev_pred_valid    = ev_mem[ev_rp_q][EV_W-104];
    wire        ev_gdir          = ev_mem[ev_rp_q][EV_W-105];
    wire        ev_ldir          = ev_mem[ev_rp_q][EV_W-106];
    wire        ev_btb_hit       = ev_mem[ev_rp_q][EV_W-107];
    wire        ev_btb_way       = ev_mem[ev_rp_q][EV_W-108];

    wire all_idle = ~(g_upd_busy | l_upd_busy | s_upd_busy | b_upd_busy_q);
    wire ev_pop   = ~ev_empty & all_idle;

    wire ev_g_upd = ev_pop & ev_is_cond;
    wire ev_l_upd = ev_pop & ev_is_cond;
    wire ev_s_upd = ev_pop & ev_is_cond;
    // BTB 分配/更新：调用/返回/间接跳转，或"实际 taken 的条件分支"（04 §4.1/§5.2）
    wire ev_b_upd = ev_pop & (ev_is_call | ev_is_ret | ev_is_indir |
                              (ev_is_cond & ev_taken));

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) b_upd_busy_q <= 1'b0;
        else        b_upd_busy_q <= ev_b_upd;
    end

    assign train_ready = ~ev_full;
    assign upd_busy    = ~all_idle | ~ev_empty;

    //--------------------------------------------------------------------------
    // 1. 三个分量 + BTB + RAS 例化（其输出连线已在 §1' 前置声明）
    //--------------------------------------------------------------------------

    bpu_gshare #() u_gshare (
        .clk(clk), .rst_n(rst_n),
        .lu_en(lu_en), .lu_pc0(lu_pc0), .lu_pc1(lu_pc1),
        .lu_valid_o(g_lu_valid), .lu_taken0(g_tk0), .lu_taken1(g_tk1),
        .upd_req(ev_g_upd), .upd_pc(ev_pc), .upd_taken(ev_taken), .upd_busy(g_upd_busy),
        .ghr_we(ghr_we_w), .ghr_wdata(ghr_wdata_w), .ghr_o(ghr_o),
        .cnt_upd()
    );

    bpu_local_hist #() u_local (
        .clk(clk), .rst_n(rst_n),
        .lu_en(lu_en), .lu_pc0(lu_pc0), .lu_pc1(lu_pc1),
        .lu_valid_o(l_lu_valid), .lu_taken0(l_tk0), .lu_taken1(l_tk1),
        .lht_rd0_o(lht_rd0), .lht_rd1_o(lht_rd1),
        .upd_req(ev_l_upd), .upd_pc(ev_pc), .upd_taken(ev_taken), .upd_busy(l_upd_busy),
        .cnt_upd()
    );

    bpu_selector #() u_selector (
        .clk(clk), .rst_n(rst_n),
        .lu_en(lu_en), .lu_pc0(lu_pc0), .lu_pc1(lu_pc1),
        .lu_valid_o(s_lu_valid), .lu_sel_global0(s_selg0), .lu_sel_global1(s_selg1),
        .lu_ctr0(s_ctr0), .lu_ctr1(s_ctr1),
        .upd_req(ev_s_upd), .upd_pc(ev_pc),
        .upd_gpred(ev_gdir), .upd_lpred(ev_ldir), .upd_taken(ev_taken),
        .upd_busy(s_upd_busy), .cnt_upd()
    );


    bpu_btb #() u_btb (
        .clk(clk), .rst_n(rst_n),
        .lu_en(lu_en), .lu_pc(lu_pc0),
        .lu_valid_o(b_lu_valid), .lu_hit_o(b_hit), .lu_way_o(b_way),
        .lu_target_o(b_target), .lu_is_cond_o(b_cond), .lu_is_call_o(b_call),
        .lu_is_return_o(b_ret),
        .upd_req(ev_b_upd), .upd_pc(ev_pc), .upd_target(ev_target),
        .upd_is_cond(ev_is_cond), .upd_is_call(ev_is_call), .upd_is_return(ev_is_ret),
        .upd_hit(ev_btb_hit), .upd_way(ev_btb_way),
        .cnt_alloc(bpu_btb_alloc), .cnt_updhit()
    );


    bpu_ras #() u_ras (
        .clk(clk), .rst_n(rst_n),
        .push_valid(ras_push_valid), .push_addr(ras_push_addr),
        .pop_valid(ras_pop_valid), .pop_addr(ras_pop_addr),
        .repair_valid(ras_repair_w), .repair_addr(ras_repair_addr),
        .ras_top(ras_top_w), .ras_empty(ras_empty_w),
        .depth_o(ras_depth_w),
        // ★ 必须用 `ck_restore_ok`（含"该检查点确实已分配"校验）：否则用一个**无效 id**
        //   恢复会把 RAS 深度清成 snapshot 数组里的残留值（TB §A6 打过这条）。
        .restore_valid(ck_restore_ok),
        .depth_restore(ckpt_ras_depth),
        .flush_all(ras_flush_all),
        .cmt_push_valid(ras_cmt_push_valid), .cmt_pop_valid(ras_cmt_pop_valid),
        .cnt_push(ras_push_c), .cnt_pop(ras_pop_c),
        .cnt_ovf(ras_ovf_c), .cnt_repair(ras_rep_c)
    );

    // RAS 顶 / 空：与查表结果同拍（在 lu_en 请求拍采样）
    reg [31:0] lu_ras_top_q;
    reg        lu_ras_empty_q;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lu_ras_top_q   <= 32'h0;
            lu_ras_empty_q <= 1'b1;
        end else begin
            lu_ras_top_q   <= ras_top_w;
            lu_ras_empty_q <= ras_empty_w;
        end
    end

    //--------------------------------------------------------------------------
    // 2. 投票（04 §3.2）+ 反证钩子 SEL_FORCE
    //--------------------------------------------------------------------------
    //   ★ 反证钩子只作用于**投票**（取用哪一侧），**不影响**选择器表的观察口
    //     `lu_selg*`：后者恒为表的真实输出（单元 TB 的 §A3 状态机用例要读它；
    //     若把钩子也接到观察口，反证实验会在 A 段就 FAIL、拿不到 B 段的准确率数字）。
    wire sel_g0 = s_selg0;                  // 观察口：选择器表真实输出
    wire sel_g1 = s_selg1;

    wire tk0 = (SEL_FORCE == 1) ? g_tk0 : (SEL_FORCE == 2) ? l_tk0 : (sel_g0 ? g_tk0 : l_tk0);
    wire tk1 = (SEL_FORCE == 1) ? g_tk1 : (SEL_FORCE == 2) ? l_tk1 : (sel_g1 ? g_tk1 : l_tk1);

    assign lu_valid_o   = g_lu_valid & l_lu_valid & s_lu_valid;
    assign lu_taken0    = tk0;
    assign lu_taken1    = tk1;
    assign lu_gdir0     = g_tk0;
    assign lu_gdir1     = g_tk1;
    assign lu_ldir0     = l_tk0;
    assign lu_ldir1     = l_tk1;
    assign lu_selg0     = sel_g0;
    assign lu_selg1     = sel_g1;

    assign lu_btb_hit    = b_hit;
    assign lu_btb_way    = b_way;
    assign lu_btb_target = b_target;
    assign lu_btb_cond   = b_cond;
    assign lu_btb_call   = b_call;
    assign lu_btb_ret    = b_ret;
    assign lu_ras_top    = lu_ras_top_q;
    assign lu_ras_empty  = lu_ras_empty_q;

    // ---- 打包（位段宏在 front4_params.vh §8；ifetch4 按同一套宏解包） ----
    //   拼接自 LSB 起：tk0, tk1, g0, g1, l0, l1, s0, s1, hit, way, cond, call, ret, target
    assign lu_pack_o = { b_target[31:0], b_ret, b_call, b_cond, b_way, b_hit,
                         sel_g1, sel_g0, l_tk1, l_tk0, g_tk1, g_tk0, tk1, tk0 };
    //   ★ 宽度自检：拼接总宽 = 32+5+2+2+2+2 = 45 = `FRONT4_LU_PACK_W（宏与拼接必须同步改动）

    //--------------------------------------------------------------------------
    // 5. 统计（04 §6.1；在事件**出队拍**按预测时记录判定，见文件头 §2②）
    //--------------------------------------------------------------------------
    reg [31:0] c_brtot_q, c_brmis_q, c_dirmis_q, c_tgtmis_q;
    reg [31:0] c_gright_q, c_lright_q, c_selg_q, c_sell_q;
    reg [31:0] c_trovf_q;

    // 该事件的方向/目标正确性
    wire ev_dir_ok = (ev_pred_taken == (ev_is_cond ? ev_taken : 1'b1));
    //   目标检查只在"**确实有目标预测**"（pred_valid=1）时进行：04 §6.1 的
    //   bpu_target_mispred 定义是"方向对但**目标**错（BTB 未命中/陈旧）"，
    //   预测 not-taken（无目标）时不该记目标错。
    wire ev_tgt_ok = ~ev_pred_taken | ~ev_pred_valid | (ev_pred_target == ev_target);
    wire ev_all_ok = ev_dir_ok & ev_tgt_ok;

    //   ★ 口径（04 §6.1 明文）：`bpu_br_total` 的分母是**条件分支**，因此
    //     `bpu_br_mispred` / `bpu_dir_mispred` / `bpu_target_mispred` 也**只统计条件分支**
    //     （非条件调用/返回/间接跳转的目标预测失误不计入这三个计数器；其代价可从
    //     `bpu_btb_alloc` 与前端 `cnt_restart` 观察）。早期版本把非条件事件也计入
    //     `bpu_br_mispred`，会让分子超过"条件分支总数"的分母语义（集成 TB 打出）。

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            c_brtot_q  <= 32'h0;  c_brmis_q  <= 32'h0;
            c_dirmis_q <= 32'h0;  c_tgtmis_q <= 32'h0;
            c_gright_q <= 32'h0;  c_lright_q <= 32'h0;
            c_selg_q   <= 32'h0;  c_sell_q   <= 32'h0;
            c_trovf_q  <= 32'h0;
        end else begin
            if (ev_pop & ev_is_cond) begin
                c_brtot_q <= c_brtot_q + 32'd1;
                if (ev_gdir  == ev_taken) c_gright_q <= c_gright_q + 32'd1;
                if (ev_ldir  == ev_taken) c_lright_q <= c_lright_q + 32'd1;
                if (ev_pred_selg)         c_selg_q   <= c_selg_q + 32'd1;
                else                      c_sell_q   <= c_sell_q + 32'd1;
                if (!ev_dir_ok)           c_dirmis_q <= c_dirmis_q + 32'd1;
                else if (!ev_tgt_ok)      c_tgtmis_q <= c_tgtmis_q + 32'd1;
            end
            if (ev_pop & ev_is_cond & ~ev_all_ok) c_brmis_q <= c_brmis_q + 32'd1;
            if (train_valid && ev_full)            c_trovf_q <= c_trovf_q + 32'd1;
        end
    end

    //--------------------------------------------------------------------------
    // 6. FIFO 时序
    //--------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ev_wp_q  <= {FIFO_AW{1'b0}};
            ev_rp_q  <= {FIFO_AW{1'b0}};
            ev_cnt_q <= {(FIFO_AW+1){1'b0}};
        end else begin
            if (train_valid && !ev_full) begin
                ev_mem[ev_wp_q] <= ev_in;
                ev_wp_q <= ev_wp_q + 1'b1;
            end
            if (ev_pop) begin
                ev_rp_q <= ev_rp_q + 1'b1;
            end
            case ({train_valid & ~ev_full, ev_pop})
                2'b10:   ev_cnt_q <= ev_cnt_q + 1'b1;
                2'b01:   ev_cnt_q <= ev_cnt_q - 1'b1;
                default: ev_cnt_q <= ev_cnt_q;
            endcase
        end
    end

    //--------------------------------------------------------------------------
    // 7. 输出
    //--------------------------------------------------------------------------
    assign bpu_br_total       = c_brtot_q;
    assign bpu_br_mispred     = c_brmis_q;
    assign bpu_dir_mispred    = c_dirmis_q;
    assign bpu_target_mispred = c_tgtmis_q;
    assign bpu_gshare_right   = c_gright_q;
    assign bpu_local_right    = c_lright_q;
    assign bpu_sel_global     = c_selg_q;
    assign bpu_sel_local      = c_sell_q;
    assign bpu_ras_push       = ras_push_c;
    assign bpu_ras_pop        = ras_pop_c;
    assign bpu_ras_overflow   = ras_ovf_c;
    assign bpu_ras_repair     = ras_rep_c;
    assign bpu_ckpt_full_stall= cnt_ckfull_q;
    assign bpu_train_overflow = c_trovf_q;
    assign ras_repair_valid   = ras_repair_w;
    // （ras_repair_addr 由 bpu_ras 直接输出，见上方例化）

endmodule
