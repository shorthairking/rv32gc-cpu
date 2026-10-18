//==============================================================================
// rtl/front4/bpu_gshare.v —— 全局分量：GHR 16 bit + 全局 PHT（Gshare）
//==============================================================================
// 项目  : rv32gc-cpu（阶段二 2B-1：四发射顺序前端 + 锦标赛分支预测器）
// 规格  : docs/design/04-predictor.md
//           §3.1 结构参数：GPHT **4096 项 × 2 bit**；索引 **PC[13:2] XOR GHR[15:4]**；
//                          GHR **16 bit**（每次**提交的**条件分支移入实际方向）
//           §3.3 训练时机：**W1 提交点**（不在 F2/E1 训练）
//           §5.2 更新规则：实际 taken ⇒ +1（饱和 3）；not-taken ⇒ −1（饱和 0）
//           §5.3 GHR 恢复：**方案 A（默认）** GHR 只在提交点更新，误判无需回滚；
//                          方案 B（`SPEC_GHR=1`）GHR 随推测推进 + 检查点回滚
//           §6.1 统计：bpu_gshare_right（本模块只输出预测；计数在 predictor_top）
//         docs/design/02-pipeline.md §3.2（F2 查表）、§4.2（同步读 ⇒ 结果下一拍用）
//
// 【两端口径】4 路取指一拍处理 1 个字 = 2 个 parcel ⇒ 每拍 2 次查表（本模块 2 读口）。
// 【提交更新】1 条/事件，内部 2 拍定序：S0 读旧计数（用**当前** GHR 算索引）+ 移位
//   GHR；S1 写回饱和后的计数。取指查表与训练读走**不同存储副本**，互不抢端口
//   （见 front4_table_2lu_1upd.v 的口径说明）。
//
// 【"训练用哪个 GHR"的口径（重要，写下来以免后人与 TB 对不上）】
//   本设计采用 **P1：提交点用"架构 GHR"（即该分支移入前的 GHR）算 GPHT 写索引**。
//   理由：04 §5.3 方案 A 下 GHR 恒等于"已提交前缀的历史"，取指时同一 PC 在同一架构
//   历史下会索引到**同一项** ⇒ 训练与预测自洽，且无需把预测时的 GHR 一路携带到提交点
//   （否则每分支要带 26 bit 状态到 ROB）。代价：若同一分支在途多次，训练会写入"更
//   靠后"的历史项，属 04 §8 已登记的 "GHR 滞后" 风险，不在本模块消除。
//   备选 P2（用预测时的索引）已评估但未采用，理由如上（面积/接口代价）。
//
// 组合逻辑风格（AGENT.md §4 红线 3）：只有 2 个 always 块（状态寄存器 + GHR），
//   其余全是 assign/function。
//==============================================================================

`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"
`include "rtl/front4/front4_params.vh"

module bpu_gshare #(
    parameter integer       GHR_BITS = `FRONT4_GHR_BITS,        // 16
    parameter integer       ENTRIES  = `FRONT4_GPHT_ENTRIES,    // 4096
    parameter integer       IDX_BITS = `FRONT4_GPHT_IDX_BITS,   // 12
    parameter [1:0]         CTR_INIT = `FRONT4_CTR_INIT         // 2'b01 弱不跳
) (
    input  wire                  clk,
    input  wire                  rst_n,

    //------------------------------------------------------------------
    // 查表（F2）：一拍 2 个 parcel；结果在**下一拍**有效（同步读）
    //------------------------------------------------------------------
    input  wire                  lu_en,       // 本拍有查表请求
    input  wire [31:0]           lu_pc0,      // 字低半 parcel 的取指地址
    input  wire [31:0]           lu_pc1,      // 字高半 parcel 的取指地址（= lu_pc0+2）
    output wire                  lu_valid_o,  // 与 lu_taken* 同拍的"结果有效"
    output wire                  lu_taken0,   // 1 = 预测跳转（计数器高位 = 1）
    output wire                  lu_taken1,

    //------------------------------------------------------------------
    // 提交点训练（条件分支；单拍脉冲请求，内部 2 拍完成）
    //------------------------------------------------------------------
    input  wire                  upd_req,
    input  wire [31:0]           upd_pc,
    input  wire                  upd_taken,
    output wire                  upd_busy,

    //------------------------------------------------------------------
    // 推测态历史（仅 `SPEC_GHR=1` 方案 B 使用：检查点恢复/推测推进）
    //   方案 A（默认）时 ghr_we 恒 0，GHR 只由提交点移位
    //------------------------------------------------------------------
    input  wire                  ghr_we,
    input  wire [GHR_BITS-1:0]   ghr_wdata,
    output wire [GHR_BITS-1:0]   ghr_o,

    //------------------------------------------------------------------
    // 统计（只读；软件读后清零——计数器本身不清零，见 04 §6.2）
    //------------------------------------------------------------------
    output wire [31:0]           cnt_upd
);

    //--------------------------------------------------------------------------
    // 0. 常量
    //--------------------------------------------------------------------------
    localparam integer AW = IDX_BITS;                          // 地址位宽 = 索引位宽
    localparam [1:0]   CTR_MIN = 2'b00;
    localparam [1:0]   CTR_MAX = 2'b11;

    //--------------------------------------------------------------------------
    // 1. 纯组合 function（Verilog 要求先声明后使用，故置于所有例化之前）
    //--------------------------------------------------------------------------
    // 索引（04 §3.1 明文口径：PC[13:2] XOR GHR[15:4]）
    function [IDX_BITS-1:0] gs_index;
        input [31:0]         pc;
        input [GHR_BITS-1:0] ghr;
        reg   [11:0]         pc_f;
        reg   [11:0]         gh_f;
        begin
            pc_f     = pc[13:2];        // 12 bit（本设计 GPHT 索引口径）
            gh_f     = ghr[15:4];       // 12 bit（低 4 位不参与，04 §3.1 明文）
            gs_index = pc_f ^ gh_f;
        end
    endfunction

    function [1:0] sat_upd;
        input [1:0] ctr;
        input       taken;
        begin
            if (taken) sat_upd = (ctr == CTR_MAX) ? CTR_MAX : (ctr + 2'd1);
            else       sat_upd = (ctr == CTR_MIN) ? CTR_MIN : (ctr - 2'd1);
        end
    endfunction


    //--------------------------------------------------------------------------
    // 2. 状态：GHR + 2 拍更新定序
    //--------------------------------------------------------------------------
    reg  [GHR_BITS-1:0] ghr_q;
    reg                 upd_taken_q;
    reg  [IDX_BITS-1:0] upd_idx_q;
    reg                 upd_s1_q;       // 0 = 空闲；1 = S1（写回）
    reg  [31:0]         cnt_upd_q;

    wire upd_fire = upd_req & ~upd_s1_q;    // 空闲时接受新事件

    //--------------------------------------------------------------------------
    // 3. 查表（同步读）
    //--------------------------------------------------------------------------
    wire [IDX_BITS-1:0] lu_idx0 = gs_index(lu_pc0, ghr_q);
    wire [IDX_BITS-1:0] lu_idx1 = gs_index(lu_pc1, ghr_q);

    wire [1:0] lu_dout0, lu_dout1;
    wire [1:0] upd_rd_dout;

    front4_table_2lu_1upd #(
        .DW(2), .DEPTH(ENTRIES), .AW(AW), .INIT(CTR_INIT)
    ) u_gpht (
        .clk(clk), .rst_n(rst_n),
        .lu0_en(lu_en), .lu0_addr(lu_idx0), .lu0_dout(lu_dout0),
        .lu1_en(lu_en), .lu1_addr(lu_idx1), .lu1_dout(lu_dout1),
        .upd_rd_en(upd_fire), .upd_rd_addr(gs_index(upd_pc, ghr_q)), .upd_rd_dout(upd_rd_dout),
        .upd_wr_en(upd_s1_q), .upd_wr_addr(upd_idx_q),
        .upd_wr_data(sat_upd(upd_rd_dout, upd_taken_q))
    );

    // 预测 = 计数器高位（04 §3.2 投票口径同：高位 = 1 ⇒ taken/global）
    assign lu_taken0 = lu_dout0[1];
    assign lu_taken1 = lu_dout1[1];

    reg lu_valid_q;
    assign lu_valid_o = lu_valid_q;


    //--------------------------------------------------------------------------
    // 5. 时序：GHR 移位（提交点）+ 更新定序
    //--------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ghr_q      <= {GHR_BITS{1'b0}};
            upd_taken_q<= 1'b0;
            upd_idx_q  <= {IDX_BITS{1'b0}};
            upd_s1_q   <= 1'b0;
            lu_valid_q <= 1'b0;
        end else begin
            lu_valid_q <= lu_en;

            // ---- GHR：① 外部（推测态恢复）优先；② 提交点移位（04 §5.2） ----
            if (ghr_we)                ghr_q <= ghr_wdata;
            else if (upd_fire)         ghr_q <= {ghr_q[GHR_BITS-2:0], upd_taken};

            // ---- 更新定序：S0 发读（索引用"移位前"的架构 GHR）----
            if (upd_fire) begin
                upd_idx_q   <= gs_index(upd_pc, ghr_q);
                upd_taken_q <= upd_taken;
                upd_s1_q    <= 1'b1;
            end else if (upd_s1_q) begin
                upd_s1_q    <= 1'b0;
            end
        end
    end

    //--------------------------------------------------------------------------
    // 6. 统计
    //--------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) cnt_upd_q <= 32'h0;
        else if (upd_fire) cnt_upd_q <= cnt_upd_q + 32'd1;
    end

    assign upd_busy = upd_s1_q;
    assign ghr_o    = ghr_q;
    assign cnt_upd  = cnt_upd_q;

endmodule
