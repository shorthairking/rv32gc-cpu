//==============================================================================
// rtl/front4/bpu_selector.v —— 选择器（锦标赛投票器，每 PC 一个 2 bit 偏向计数）
//==============================================================================
// 项目  : rv32gc-cpu（阶段二 2B-1：四发射顺序前端 + 锦标赛分支预测器）
// 规格  : docs/design/04-predictor.md
//           §3.1 结构参数：选择器表 **1024 项 × 2 bit**（索引 PC[11:2]）
//           §3.2 状态机（**只在分支提交后**用实际方向更新，避免错误路径污染）：
//                   两侧都对 / 两侧都错      ⇒ 计数器不变
//                   全局对、局部错           ⇒ 向"全局"方向 +1（饱和 3）
//                   局部对、全局错           ⇒ 向"局部"方向 −1（饱和 0）
//                 投票：高位 = 1（WEAK/STRONG_GLOBAL）⇒ 用 Gshare；高位 = 0 ⇒ 用局部
//                 复位值 = `FRONT4_SEL_INIT` = 2'b01（WEAK_LOCAL，04 §3.2 明文）
//           §6.1 统计：bpu_sel_global / bpu_sel_local（在 predictor_top 计数）
//
// 【更新事件的三个输入必须来自"预测那一刻的记录"】：
//   upd_gpred / upd_lpred 是**取指时两个分量各自的预测方向**（随指令带到 ROB，提交时
//   回传）。绝不能在提交点用当前表重新推——表已被后续训练改动，那样选择器学的是噪声。
//   对应 2B-2 衔接点：`train_*` 端口必须携带该分支的 {gpred, lpred}（见 front4_top.v）。
//
// 存储：1024 × 2 bit，2 查表口 + 1 更新口 ⇒ front4_table_2lu_1upd（双副本）。
//==============================================================================

`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"
`include "rtl/front4/front4_params.vh"

module bpu_selector #(
    parameter integer ENTRIES  = `FRONT4_SEL_ENTRIES,   // 1024
    parameter integer IDX_BITS = `FRONT4_SEL_IDX_BITS,  // 10
    parameter [1:0]   SEL_INIT = `FRONT4_SEL_INIT      // 2'b01 弱偏局部
) (
    input  wire                  clk,
    input  wire                  rst_n,

    //------------------------------------------------------------------
    // 查表（F2；结果下一拍有效）：输出"是否选全局侧"
    //------------------------------------------------------------------
    input  wire                  lu_en,
    input  wire [31:0]           lu_pc0,
    input  wire [31:0]           lu_pc1,
    output wire                  lu_valid_o,
    output wire                  lu_sel_global0,
    output wire                  lu_sel_global1,
    output wire [1:0]            lu_ctr0,          // 计数器原值（TB/统计观察）
    output wire [1:0]            lu_ctr1,

    //------------------------------------------------------------------
    // 提交点训练（条件分支；2 拍完成）
    //   upd_gpred/upd_lpred = 取指时两分量的预测方向（携带到提交点回传）
    //   upd_taken           = 实际方向
    //------------------------------------------------------------------
    input  wire                  upd_req,
    input  wire [31:0]           upd_pc,
    input  wire                  upd_gpred,
    input  wire                  upd_lpred,
    input  wire                  upd_taken,
    output wire                  upd_busy,

    output wire [31:0]           cnt_upd
);

    //--------------------------------------------------------------------------
    // 0. 常量与纯组合 function（先声明后使用）
    //--------------------------------------------------------------------------
    localparam integer AW      = IDX_BITS;
    localparam [1:0]   SEL_MIN = 2'b00;    // STRONG_LOCAL
    localparam [1:0]   SEL_MAX = 2'b11;    // STRONG_GLOBAL
    localparam integer SEL_GBIT = `FRONT4_SEL_GLOBAL_BIT;   // 1

    // 04 §3.2 状态转移：返回新的 2 bit 计数器值（纯组合）
    function [1:0] sel_next;
        input [1:0] ctr;
        input       g_ok;      // 全局侧预测正确
        input       l_ok;      // 局部侧预测正确
        begin
            if      (g_ok & ~l_ok) sel_next = (ctr == SEL_MAX) ? SEL_MAX : (ctr + 2'd1);
            else if (l_ok & ~g_ok) sel_next = (ctr == SEL_MIN) ? SEL_MIN : (ctr - 2'd1);
            else                   sel_next = ctr;      // 同对 / 同错 ⇒ 不变
        end
    endfunction

    //--------------------------------------------------------------------------
    // 1. 表（2 查表口 + 1 更新口）
    //--------------------------------------------------------------------------
    wire [1:0] lu_dout0, lu_dout1, upd_rd_dout;
    wire [AW-1:0] lu_sel_idx0 = lu_pc0[11:2];
    wire [AW-1:0] lu_sel_idx1 = lu_pc1[11:2];

    // ---- 更新定序状态（先声明后例化：端口引用它们） ----
    reg               upd_s1_q;
    reg  [AW-1:0]     upd_idx_q;
    reg               upd_gpred_q, upd_lpred_q, upd_taken_q;

    wire upd_fire  = upd_req & ~upd_s1_q;
    wire upd_g_ok  = (upd_gpred_q == upd_taken_q);
    wire upd_l_ok  = (upd_lpred_q == upd_taken_q);

    front4_table_2lu_1upd #(
        .DW(2), .DEPTH(ENTRIES), .AW(AW), .INIT(SEL_INIT)
    ) u_seltab (
        .clk(clk), .rst_n(rst_n),
        .lu0_en(lu_en), .lu0_addr(lu_sel_idx0), .lu0_dout(lu_dout0),
        .lu1_en(lu_en), .lu1_addr(lu_sel_idx1), .lu1_dout(lu_dout1),
        .upd_rd_en(upd_fire), .upd_rd_addr(upd_pc[11:2]), .upd_rd_dout(upd_rd_dout),
        .upd_wr_en(upd_s1_q), .upd_wr_addr(upd_idx_q),
        .upd_wr_data(sel_next(upd_rd_dout, upd_g_ok, upd_l_ok))
    );

    // 投票（04 §3.2）：高位 = 1 ⇒ 选 Gshare
    assign lu_sel_global0 = lu_dout0[SEL_GBIT];
    assign lu_sel_global1 = lu_dout1[SEL_GBIT];
    assign lu_ctr0        = lu_dout0;
    assign lu_ctr1        = lu_dout1;

    //--------------------------------------------------------------------------
    // 2. 更新定序（2 拍）
    //--------------------------------------------------------------------------
    reg lu_valid_q;
    assign lu_valid_o = lu_valid_q;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lu_valid_q  <= 1'b0;
            upd_s1_q    <= 1'b0;
            upd_idx_q   <= {AW{1'b0}};
            upd_gpred_q <= 1'b0;
            upd_lpred_q <= 1'b0;
            upd_taken_q <= 1'b0;
        end else begin
            lu_valid_q <= lu_en;

            if (upd_fire) begin
                upd_idx_q   <= upd_pc[11:2];
                upd_gpred_q <= upd_gpred;
                upd_lpred_q <= upd_lpred;
                upd_taken_q <= upd_taken;
                upd_s1_q    <= 1'b1;
            end else if (upd_s1_q) begin
                upd_s1_q    <= 1'b0;
            end
        end
    end

    //--------------------------------------------------------------------------
    // 3. 统计
    //--------------------------------------------------------------------------
    reg [31:0] cnt_upd_q;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) cnt_upd_q <= 32'h0;
        else if (upd_fire) cnt_upd_q <= cnt_upd_q + 32'd1;
    end

    assign upd_busy = upd_s1_q;
    assign cnt_upd  = cnt_upd_q;

endmodule
