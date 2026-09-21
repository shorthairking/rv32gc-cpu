//==============================================================================
// rtl/front4/bpu_local_hist.v —— 局部分量：LHT（每 PC 10 bit 历史）+ 局部 PHT
//==============================================================================
// 项目  : rv32gc-cpu（阶段二 2B-1：四发射顺序前端 + 锦标赛分支预测器）
// 规格  : docs/design/04-predictor.md
//           §3.1 结构参数：LHT **1024 项 × 10 bit**（索引 PC[11:2]）；
//                          LPHT **1024 项 × 2 bit**（索引 **LHT[PC] XOR PC[11:2]**）
//           §5.2 更新规则：LHT[PC] = {LHT[PC][8:0], taken}；
//                          LPHT 同 GPHT（taken⇒+1 饱和 3 / not-taken⇒−1 饱和 0）
//           §3.3 训练时机：提交点（W1）
//
// 【微架构决策：LHT 用**组合读**（distributed RAM），LPHT 用同步读存储】
//   局部预测是**两级查表**：LHT[PC] → 索引 → LPHT。04 §4.2 要求「F2 查表，F1 下一拍
//   用」，即整条链必须在 **1 拍**内出结果 ⇒ LHT 必须是组合读；若 LHT 也同步读，
//   两级串起来就是 2 拍，F2 的预测结果赶不上 F1（需要再加一级预测流水，改动更大）。
//   · IP 检索结论（AGENT.md 红线 1 要求的过程）：Vivado 的存储 IP（BMG / XPM）都是
//     **同步读**，无"组合读"的存储 IP ⇒ 本表用可综合 HDL 描述 + `ram_style =
//     "distributed"` 属性（Vivado 推断为 LUTRAM，10 Kbit ≈ 160 个 LUT6，不是触发器
//     阵列、也不是原语）。这条结论与 04 §2「禁止用寄存器阵列实现大表」并不冲突：
//     LHT 走的是**分布式 RAM**推断，不是寄存器阵列（后者才是被禁止的形态）。
//   · LPHT（2 Kbit）保持同步读 + 双副本（2 查表口 + 1 更新口），见
//     front4_table_2lu_1upd.v；综合走 XPM，仿真走行为模型。
//
// 【训练索引口径】同 bpu_gshare.v：**P1 —— 用提交点的架构值**（LHT 用"移位前"的值
//   算 LPHT 写索引），无需把预测时的历史携带到提交点。
//
// 组合逻辑风格（AGENT.md §4 红线 3）：只有状态/写口用 always，其余 assign/function。
//==============================================================================

`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"
`include "rtl/front4/front4_params.vh"

module bpu_local_hist #(
    parameter integer LHT_ENTRIES  = `FRONT4_LHT_ENTRIES,    // 1024
    parameter integer LHT_BITS     = `FRONT4_LHT_BITS,       // 10
    parameter integer LPHT_ENTRIES = `FRONT4_LPHT_ENTRIES,   // 1024
    parameter [1:0]   CTR_INIT     = `FRONT4_CTR_INIT
) (
    input  wire                  clk,
    input  wire                  rst_n,

    //------------------------------------------------------------------
    // 查表（F2，一拍 2 个 parcel；结果下一拍有效）
    //------------------------------------------------------------------
    input  wire                  lu_en,
    input  wire [31:0]           lu_pc0,
    input  wire [31:0]           lu_pc1,
    output wire                  lu_valid_o,
    output wire                  lu_taken0,     // 局部侧预测（LPHT 高位）
    output wire                  lu_taken1,
    // LHT 组合读值（同拍有效；供 TB/统计观察，也是 LPHT 索引的来源）
    output wire [LHT_BITS-1:0]   lht_rd0_o,
    output wire [LHT_BITS-1:0]   lht_rd1_o,

    //------------------------------------------------------------------
    // 提交点训练（条件分支；2 拍完成）
    //------------------------------------------------------------------
    input  wire                  upd_req,
    input  wire [31:0]           upd_pc,
    input  wire                  upd_taken,
    output wire                  upd_busy,

    output wire [31:0]           cnt_upd
);

    //--------------------------------------------------------------------------
    // 0. 常量
    //--------------------------------------------------------------------------
    localparam integer LHT_AW  = 10;      // log2(1024)
    localparam integer LPHT_AW = 10;
    localparam [1:0]   CTR_MIN = 2'b00;
    localparam [1:0]   CTR_MAX = 2'b11;

    //--------------------------------------------------------------------------
    // 1. 纯组合 function（先声明后使用）
    //--------------------------------------------------------------------------
    function [1:0] sat_upd;
        input [1:0] ctr;
        input       taken;
        begin
            if (taken) sat_upd = (ctr == CTR_MAX) ? CTR_MAX : (ctr + 2'd1);
            else       sat_upd = (ctr == CTR_MIN) ? CTR_MIN : (ctr - 2'd1);
        end
    endfunction

    //--------------------------------------------------------------------------
    // 2. LHT：1024 × 10 bit，组合读 + 同步写（distributed RAM）
    //--------------------------------------------------------------------------
    (* ram_style = "distributed" *) reg [LHT_BITS-1:0] lht_mem [0:LHT_ENTRIES-1];

    // 复位口径（04 §3.2 明文：复位后"局部历史表也为空"⇒ 全 0，预测不跳）
    //   · 仿真：initial 显式清零（否则组合读会在上电期读出 x）
    //   · 综合：distributed RAM 的 initial 会被 Vivado 转成 INIT 属性（上电清 0），
    //     与 GPHT/LPHT/选择器（front4_mem_* 的 INIT=弱不跳）口径一致。
    integer li;
    initial begin
        for (li = 0; li < LHT_ENTRIES; li = li + 1) lht_mem[li] = {LHT_BITS{1'b0}};
    end

    wire [LHT_AW-1:0] lu_lht_idx0 = lu_pc0[11:2];
    wire [LHT_AW-1:0] lu_lht_idx1 = lu_pc1[11:2];
    wire [LHT_BITS-1:0] lht_rd0 = lht_mem[lu_lht_idx0];
    wire [LHT_BITS-1:0] lht_rd1 = lht_mem[lu_lht_idx1];

    assign lht_rd0_o = lht_rd0;
    assign lht_rd1_o = lht_rd1;

    //--------------------------------------------------------------------------
    // 3. LPHT：1024 × 2 bit（2 查表口 + 1 更新口）
    //--------------------------------------------------------------------------
    wire [LPHT_AW-1:0] lu_lpht_idx0 = lht_rd0 ^ lu_lht_idx0;   // LHT[PC] XOR PC[11:2]
    wire [LPHT_AW-1:0] lu_lpht_idx1 = lht_rd1 ^ lu_lht_idx1;

    wire [1:0] lpht_dout0, lpht_dout1, lpht_upd_rd;

    // ---- 更新定序状态（先声明后例化：端口引用它们） ----
    reg               upd_s0_q, upd_s1_q;
    reg               upd_taken_q;
    reg  [LPHT_AW-1:0] upd_lpht_idx_q;

    // 更新读地址（S0 组合：用"移位前"的 LHT 值与 PC 算）
    wire [LHT_BITS-1:0] lht_upd_old = lht_mem[upd_pc[11:2]];
    wire [LPHT_AW-1:0]  upd_lpht_idx = lht_upd_old ^ upd_pc[11:2];

    front4_table_2lu_1upd #(
        .DW(2), .DEPTH(LPHT_ENTRIES), .AW(LPHT_AW), .INIT(CTR_INIT)
    ) u_lpht (
        .clk(clk), .rst_n(rst_n),
        .lu0_en(lu_en), .lu0_addr(lu_lpht_idx0), .lu0_dout(lpht_dout0),
        .lu1_en(lu_en), .lu1_addr(lu_lpht_idx1), .lu1_dout(lpht_dout1),
        .upd_rd_en(upd_s0_q), .upd_rd_addr(upd_lpht_idx_q), .upd_rd_dout(lpht_upd_rd),
        .upd_wr_en(upd_s1_q), .upd_wr_addr(upd_lpht_idx_q),
        .upd_wr_data(sat_upd(lpht_upd_rd, upd_taken_q))
    );

    assign lu_taken0 = lpht_dout0[1];
    assign lu_taken1 = lpht_dout1[1];

    //--------------------------------------------------------------------------
    // 4. 更新定序：S0（读 LPHT + 写 LHT）→ S1（写 LPHT）
    //--------------------------------------------------------------------------
    wire upd_fire = upd_req & ~upd_s0_q & ~upd_s1_q;

    reg lu_valid_q;
    assign lu_valid_o = lu_valid_q;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lu_valid_q      <= 1'b0;
            upd_s0_q        <= 1'b0;
            upd_s1_q        <= 1'b0;
            upd_taken_q     <= 1'b0;
            upd_lpht_idx_q  <= {LPHT_AW{1'b0}};
        end else begin
            lu_valid_q <= lu_en;

            // ---- S0：读 LPHT（地址组合得出） + 写 LHT（移位入 taken） ----
            if (upd_fire) begin
                upd_s0_q       <= 1'b1;
                upd_s1_q       <= 1'b0;
                upd_taken_q    <= upd_taken;
                upd_lpht_idx_q <= upd_lpht_idx;         // LHT_old XOR PC[11:2]
                lht_mem[upd_pc[11:2]] <= {lht_upd_old[LHT_BITS-2:0], upd_taken};
            end else if (upd_s0_q) begin
                upd_s0_q <= 1'b0;
                upd_s1_q <= 1'b1;                       // → S1 写 LPHT
            end else if (upd_s1_q) begin
                upd_s1_q <= 1'b0;
            end
        end
    end

    //--------------------------------------------------------------------------
    // 5. 统计
    //--------------------------------------------------------------------------
    reg [31:0] cnt_upd_q;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) cnt_upd_q <= 32'h0;
        else if (upd_fire) cnt_upd_q <= cnt_upd_q + 32'd1;
    end

    assign upd_busy = upd_s0_q | upd_s1_q;
    assign cnt_upd  = cnt_upd_q;

endmodule
