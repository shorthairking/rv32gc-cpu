//==============================================================================
// rtl/front4/front4_top.v —— 2B-1 四发射顺序前端顶层（F1–F4 + 锦标赛预测器）
//==============================================================================
// 项目  : rv32gc-cpu（阶段二 2B-1：四发射顺序前端 + 锦标赛分支预测器）
// 规格  : docs/design/02-pipeline.md §2（F1–F4 全景）、§3.1–§3.4（逐级定义）、
//         §4（4 路取指停顿与冻结范围）、§5（顺序前端与乱序后端衔接）、
//         §6（重定向类别 A/C/D 与冲刷信号语义）；
//         docs/design/04-predictor.md §2–§6（预测器结构/训练/恢复/统计）；
//         docs/design/08-baseline-5stage.md §4.3/§5.1（2A 取指与 L1I 契约）。
//
// 【组成】
//   pc_gen4      —— F1：取指字地址生成（顺序推进 / 预测重启 / 重定向 / 页边界 / epoch）
//   predictor_top—— F2 查表 + 提交训练 + 检查点（Gshare + 局部 + 选择器 + BTB + RAS）
//   ifetch4      —— F3/F4：L1I/直连取字、parcel 缓冲、跨行拼接、4 路分组、取指 PMP
//
// 【与 2B-2（乱序后端）的接口（衔接点，全部在本文件端口上）】
//   ① 派发：`blk_valid/blk_ready/blk_mask` + 4 lane 明细（pc/pa/insn/长度/分支类别/
//      预测方向/预测目标/BTB 命中信息/检查点 id）。块内**严格顺序**，块间**整块停顿**
//      （02 §4.1：不做部分派发）。块尾为预测跳转时 `blk_taken=1`、`blk_next_pc` = 预测
//      目标（否则 = 顺序下一地址）。
//   ② 重定向：`redirect_valid/redirect_pc/redirect_use_ckpt/redirect_ckpt`
//      —— 类别 A（分支误判，带检查点 id ⇒ 恢复 RAS 深度/（方案 B 时）GHR）、
//         类别 C（异常/中断，`redirect_use_ckpt=0` ⇒ 全冲刷，RAS 回"已提交深度"）。
//   ③ 提交训练：`train_*`（1 条/事件；**必须携带预测时记录**：最终方向、选择器选择、
//      两分量方向、预测目标、BTB 命中/路号）——这是 04 §3.2/§3.3"只在提交点训练"
//      与 BTB"命中 ⇒ 原地更新"的必要条件。`train_ready` 低表示前端训练 FIFO 满
//      （2B-2 的 ROB 需保证有缓冲余量；持续 1 条/拍条件分支不现实，正常不会满）。
//   ④ 检查点生命周期：前端在"块尾预测跳转"时分配（04 §4.2/03 §3.4）；后端在提交或
//      冲刷丢弃时 `ckpt_free_valid/ckpt_free_id` 释放（**不释放会耗尽 ⇒ 前端停顿**，
//      统计 `bpu_ckpt_full_stall`）。
//   ⑤ RAS 的 D1/D2 侧：`d2_push_*`（jal/c.jal 且 rd 为链接寄存器）、`d2_pop_*`
//      （ret 的实际返回地址）；不一致 ⇒ `ras_repair_valid` + 前端**自行冲刷**到
//      实际返回地址（02 §6.1 类别 D，本设计唯一在 D2 触发的重定向）。
//   ⑥ 统计：`bpu_*`（04 §6.1 口径）+ `cnt_*`（取指侧计数），供核内 MMIO 暴露
//      （04 §6.2：不新增 core_top 端口；2B-2 落 MMIO 窗口）。
//
// 【本模块的组合逻辑】只有 mux/assign（红线 3）。
//==============================================================================

`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"
`include "rtl/front4/front4_params.vh"

module front4_top #(
    parameter integer SPEC_GHR    = 0,     // 0 = 04 §5.3 方案 A（默认）；1 = 方案 B
    parameter integer SEL_FORCE   = 0,     // 0 = 正常；1/2 = 反证实验（恒接一侧）
    parameter integer BUF_PARCELS = `FRONT4_BUF_PARCELS,
    parameter integer CKPT_NUM    = `FRONT4_CKPT_NUM,
    parameter integer RAS_DEPTH   = `FRONT4_RAS_DEPTH,
    parameter integer PMP_ENTRIES = `RV32GC_PMP_ENTRIES,
    parameter integer PMP_ENTRY_W = `RV32GC_PMP_ENTRY_W
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        rst_hold,          // 复位保持（取指停在 RESET_PC）

    //==================================================================
    // 后端 → 前端：重定向（类别 A / C）
    //==================================================================
    input  wire        redirect_valid,
    input  wire [31:0] redirect_pc,
    input  wire        redirect_use_ckpt, // 1 = 按检查点恢复（类别 A）
    input  wire [3:0]  redirect_ckpt,
    input  wire        break_point,       // 调试断点：冻结前端
    input  wire        fe_stall,          // 后端反压（额外冻结；块握手之外的口径）

    //==================================================================
    // 前端 → 后端：4 路块（派发接口）
    //==================================================================
    output wire        blk_valid,
    input  wire        blk_ready,
    output wire [3:0]  blk_mask,
    output wire [31:0] blk_next_pc,
    output wire        blk_taken,
    output wire [127:0] lane_pc,
    output wire [127:0] lane_pa,
    output wire [127:0] lane_insn,
    output wire [3:0]  lane_len32,
    output wire [11:0] lane_cls,
    output wire [3:0]  lane_pred_taken,
    output wire [3:0]  lane_pred_selg,
    output wire [3:0]  lane_pred_gdir,
    output wire [3:0]  lane_pred_ldir,
    output wire [127:0] lane_pred_target,
    output wire [3:0]  lane_btb_hit,
    output wire [3:0]  lane_btb_way,
    output wire [3:0]  lane_btb_cond,
    output wire [3:0]  lane_btb_call,
    output wire [3:0]  lane_btb_ret,
    output wire [127:0] lane_btb_target,
    output wire [3:0]  lane_fault,
    output wire [19:0] lane_fault_cause,
    output wire [127:0] lane_fault_tval,
    output wire [15:0] lane_ckpt,
    output wire [3:0]  lane_ckpt_valid,
    output wire        fe_fetch_fault,    // 本拍块含取指异常（后端据此生成异常）
    output wire        fe_frozen,         // 前端已冻结（取指异常保持/断点）

    //==================================================================
    // 后端 → 前端：提交训练（W1，1 条/事件）
    //==================================================================
    input  wire        train_valid,
    input  wire [31:0] train_pc,
    input  wire        train_is_cond,
    input  wire        train_taken,
    input  wire        train_is_indirect,
    input  wire        train_is_call,
    input  wire        train_is_return,
    input  wire [31:0] train_target,
    input  wire        train_pred_taken,
    input  wire        train_pred_sel_global,
    input  wire        train_pred_gdir,
    input  wire        train_pred_ldir,
    input  wire [31:0] train_pred_target,
    input  wire        train_pred_valid,
    input  wire        train_btb_hit,
    input  wire        train_btb_way,
    output wire        train_ready,

    //==================================================================
    // 后端 → 前端：检查点释放 / RAS 提交侧
    //==================================================================
    input  wire        ckpt_free_valid,
    input  wire [3:0]  ckpt_free_id,
    input  wire        ras_cmt_push_valid,
    input  wire        ras_cmt_pop_valid,

    //==================================================================
    // D1/D2 侧：RAS 压/弹/修复
    //==================================================================
    input  wire        d2_push_valid,
    input  wire [31:0] d2_push_addr,
    input  wire        d2_pop_valid,
    input  wire [31:0] d2_pop_addr,
    output wire        ras_repair_valid,
    output wire [31:0] ras_repair_addr,

    //==================================================================
    // MMU / PMP / L1I / XIP（与 2A fetch_unit 同口径）
    //==================================================================
    input  wire        sv32_translate_en,
    input  wire        sv32_translate_done,
    input  wire        sv32_translate_fault,
    input  wire [31:0] sv32_translate_paddr,
    output wire        tr_req_valid,
    output wire [31:0] tr_req_va,
    input  wire [1:0]  priv,
    input  wire [PMP_ENTRIES*PMP_ENTRY_W-1:0] pmpcfg_i,
    input  wire [PMP_ENTRIES*32-1:0]          pmpaddr_i,
    output wire        l1i_req_valid,
    output wire [31:0] l1i_req_addr,
    output wire [31:0] l1i_req_line,
    input  wire        l1i_ready,
    input  wire [31:0] l1i_rdata,
    input  wire        l1i_miss,
    input  wire        l1i_uncached,
    output wire        unc_req_valid,
    output wire [31:0] unc_req_pa,
    input  wire        unc_rsp_valid,
    input  wire [31:0] unc_rsp_pa,
    input  wire [31:0] unc_rsp_data,

    //==================================================================
    // 输出：观测/统计
    //==================================================================
    output wire [31:0] fetch_pc_o,        // 当前取指流字地址（调试探针）
    output wire [31:0] head_pc_o,
    output wire [1:0]  epoch_o,
    output wire [15:0] ghr_o,
    output wire [31:0] bpu_br_total,
    output wire [31:0] bpu_br_mispred,
    output wire [31:0] bpu_dir_mispred,
    output wire [31:0] bpu_target_mispred,
    output wire [31:0] bpu_gshare_right,
    output wire [31:0] bpu_local_right,
    output wire [31:0] bpu_sel_global,
    output wire [31:0] bpu_sel_local,
    output wire [31:0] bpu_ras_push,
    output wire [31:0] bpu_ras_pop,
    output wire [31:0] bpu_ras_overflow,
    output wire [31:0] bpu_ras_repair,
    output wire [31:0] bpu_ckpt_full_stall,
    output wire [31:0] bpu_train_overflow,
    output wire [31:0] bpu_btb_alloc,
    output wire [31:0] cnt_grp,
    output wire [31:0] cnt_parcels,
    output wire [31:0] cnt_fault,
    output wire [31:0] cnt_restart,
    output wire [31:0] cnt_stall,
    output wire [31:0] cnt_req,
    output wire [31:0] cnt_redirect
);

    //==========================================================================
    // 0. 内部互联
    //==========================================================================
    wire [31:0] f_pc, f_head_pc;
    wire [1:0]  f_epoch;
    wire        f_pipe_adv, f_head_adv;
    wire [4:0]  f_head_bytes;
    wire        f_rst_start;
    wire [31:0] f_rst_pc;

    wire        lu_en;
    wire [31:0] lu_pc0, lu_pc1;
    wire [`FRONT4_LU_PACK_W-1:0] lu_pack;
    wire [31:0] ras_top;
    wire        ras_empty;

    wire        ckpt_alloc_valid, ckpt_full;
    wire [3:0]  ckpt_alloc_id;

    wire        ckpt_restore_used = redirect_valid & redirect_use_ckpt;
    wire [31:0] ras_repair_addr_w;

    //==========================================================================
    // 1. F1：pc_gen4
    //==========================================================================
    // 统一重定向（后端重定向 优先于 RAS 修复；两者都要求本拍立刻换 PC）
    wire        redir_all_valid = redirect_valid | ras_repair_valid;
    wire [31:0] redir_all_pc    = redirect_valid ? redirect_pc : ras_repair_addr_w;

    pc_gen4 u_pc_gen4 (
        .clk            (clk),
        .rst_n          (rst_n),
        .rst_hold       (rst_hold),
        .fetch_stall    (1'b0),                 // 冻结由 ifetch4 的 f1_accept 侧实现
        .redirect_valid (redir_all_valid),
        .redirect_pc    (redir_all_pc),
        .restart_valid  (f_rst_start),
        .restart_pc     (f_rst_pc),
        .pipe_advance   (f_pipe_adv),
        .head_adv_valid (f_head_adv),
        .head_adv_bytes (f_head_bytes),
        .fetch_pc       (f_pc),
        .head_pc        (f_head_pc),
        .epoch          (f_epoch),
        .stream_phase1  (),
        .page_last_next ()
    );

    //==========================================================================
    // 2. F2：预测器（查表 / 训练 / 检查点 / RAS）
    //==========================================================================
    predictor_top #(
        .SPEC_GHR (SPEC_GHR),
        .SEL_FORCE(SEL_FORCE),
        .CKPT_NUM (CKPT_NUM),
        .RAS_DEPTH(RAS_DEPTH)
    ) u_bpu (
        .clk(clk), .rst_n(rst_n),
        .lu_en(lu_en), .lu_pc0(lu_pc0), .lu_pc1(lu_pc1),
        .lu_valid_o(), .lu_taken0(), .lu_taken1(),
        .lu_gdir0(), .lu_gdir1(), .lu_ldir0(), .lu_ldir1(),
        .lu_selg0(), .lu_selg1(),
        .lu_btb_hit(), .lu_btb_way(), .lu_btb_target(), .lu_btb_cond(),
        .lu_btb_call(), .lu_btb_ret(),
        .lu_ras_top(ras_top), .lu_ras_empty(ras_empty),
        .lu_pack_o(lu_pack),
        .ras_push_valid(d2_push_valid), .ras_push_addr(d2_push_addr),
        .ras_pop_valid(d2_pop_valid), .ras_pop_addr(d2_pop_addr),
        .ras_repair_valid(ras_repair_valid), .ras_repair_addr(ras_repair_addr_w),
        .ras_flush_all(redirect_valid & ~redirect_use_ckpt),
        .ras_cmt_push_valid(ras_cmt_push_valid), .ras_cmt_pop_valid(ras_cmt_pop_valid),
        .train_valid(train_valid), .train_pc(train_pc),
        .train_is_cond(train_is_cond), .train_taken(train_taken),
        .train_is_indirect(train_is_indirect), .train_is_call(train_is_call),
        .train_is_return(train_is_return), .train_target(train_target),
        .train_pred_taken(train_pred_taken), .train_pred_sel_global(train_pred_sel_global),
        .train_pred_gdir(train_pred_gdir), .train_pred_ldir(train_pred_ldir),
        .train_pred_target(train_pred_target), .train_pred_valid(train_pred_valid),
        .train_btb_hit(train_btb_hit), .train_btb_way(train_btb_way),
        .train_ready(train_ready), .upd_busy(),
        .ckpt_alloc_valid(ckpt_alloc_valid), .ckpt_alloc_pc(32'h0),
        .ckpt_alloc_id(ckpt_alloc_id), .ckpt_full(ckpt_full),
        .ckpt_free_valid(ckpt_free_valid), .ckpt_free_id(ckpt_free_id),
        .ckpt_restore_valid(ckpt_restore_used), .ckpt_restore_id(redirect_ckpt),
        .bpu_br_total(bpu_br_total), .bpu_br_mispred(bpu_br_mispred),
        .bpu_dir_mispred(bpu_dir_mispred), .bpu_target_mispred(bpu_target_mispred),
        .bpu_gshare_right(bpu_gshare_right), .bpu_local_right(bpu_local_right),
        .bpu_sel_global(bpu_sel_global), .bpu_sel_local(bpu_sel_local),
        .bpu_ras_push(bpu_ras_push), .bpu_ras_pop(bpu_ras_pop),
        .bpu_ras_overflow(bpu_ras_overflow), .bpu_ras_repair(bpu_ras_repair),
        .bpu_ckpt_full_stall(bpu_ckpt_full_stall),
        .bpu_train_overflow(bpu_train_overflow),
        .bpu_btb_alloc(bpu_btb_alloc),
        .ghr_o(ghr_o)
    );

    //==========================================================================
    // 3. F3/F4：ifetch4
    //==========================================================================
    ifetch4 #(
        .BUF_PARCELS(BUF_PARCELS),
        .PMP_ENTRIES(PMP_ENTRIES),
        .PMP_ENTRY_W(PMP_ENTRY_W)
    ) u_ifetch4 (
        .clk(clk), .rst_n(rst_n),
        .fetch_pc(f_pc), .head_pc(f_head_pc), .epoch(f_epoch),
        .freeze_in(fe_stall | break_point),
        .redirect_valid(redir_all_valid), .redirect_pc(redir_all_pc),
        .pipe_advance(f_pipe_adv),
        .head_adv_valid(f_head_adv), .head_adv_bytes(f_head_bytes),
        .restart_valid(f_rst_start), .restart_pc(f_rst_pc),
        .lu_en(lu_en), .lu_pc0(lu_pc0), .lu_pc1(lu_pc1), .lu_pack(lu_pack),
        .ras_top(ras_top), .ras_empty(ras_empty),
        .ckpt_alloc_valid(ckpt_alloc_valid), .ckpt_alloc_id(ckpt_alloc_id),
        .ckpt_full(ckpt_full),
        .sv32_translate_en(sv32_translate_en),
        .sv32_translate_done(sv32_translate_done),
        .sv32_translate_fault(sv32_translate_fault),
        .sv32_translate_paddr(sv32_translate_paddr),
        .tr_req_valid(tr_req_valid), .tr_req_va(tr_req_va),
        .l1i_req_valid(l1i_req_valid), .l1i_req_addr(l1i_req_addr),
        .l1i_req_line(l1i_req_line),
        .l1i_ready(l1i_ready), .l1i_rdata(l1i_rdata),
        .l1i_miss(l1i_miss), .l1i_uncached(l1i_uncached),
        .unc_req_valid(unc_req_valid), .unc_req_pa(unc_req_pa),
        .unc_rsp_valid(unc_rsp_valid), .unc_rsp_pa(unc_rsp_pa), .unc_rsp_data(unc_rsp_data),
        .priv(priv), .pmpcfg_i(pmpcfg_i), .pmpaddr_i(pmpaddr_i),
        .blk_valid(blk_valid), .blk_ready(blk_ready), .blk_mask(blk_mask),
        .blk_next_pc(blk_next_pc), .blk_taken(blk_taken),
        .lane_pc(lane_pc), .lane_pa(lane_pa), .lane_insn(lane_insn),
        .lane_len32(lane_len32), .lane_cls(lane_cls),
        .lane_pred_taken(lane_pred_taken), .lane_pred_selg(lane_pred_selg),
        .lane_pred_gdir(lane_pred_gdir), .lane_pred_ldir(lane_pred_ldir),
        .lane_pred_target(lane_pred_target),
        .lane_btb_hit(lane_btb_hit), .lane_btb_way(lane_btb_way),
        .lane_btb_cond(lane_btb_cond), .lane_btb_call(lane_btb_call),
        .lane_btb_ret(lane_btb_ret), .lane_btb_target(lane_btb_target),
        .lane_fault(lane_fault), .lane_fault_cause(lane_fault_cause),
        .lane_fault_tval(lane_fault_tval),
        .lane_ckpt(lane_ckpt), .lane_ckpt_valid(lane_ckpt_valid),
        .cnt_grp(cnt_grp), .cnt_parcels(cnt_parcels), .cnt_fault(cnt_fault),
        .cnt_restart(cnt_restart), .cnt_stall(cnt_stall), .cnt_req(cnt_req)
    );

    assign fe_fetch_fault = blk_valid & (|lane_fault);
    assign fe_frozen      = fe_fetch_fault | break_point | fe_stall;

    assign fetch_pc_o = f_pc;
    assign head_pc_o  = f_head_pc;
    assign epoch_o    = f_epoch;

    //==========================================================================
    // 4. 统计：重定向次数（后端重定向 + 前端 RAS 修复）
    //==========================================================================
    reg [31:0] cnt_redir_q;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) cnt_redir_q <= 32'h0;
        else if (redir_all_valid) cnt_redir_q <= cnt_redir_q + 32'd1;
    end
    assign cnt_redirect = cnt_redir_q;

endmodule
