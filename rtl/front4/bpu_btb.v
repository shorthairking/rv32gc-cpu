//==============================================================================
// rtl/front4/bpu_btb.v —— 分支目标缓冲 BTB（2048 项 / 2 路组相联 / 提交点更新）
//==============================================================================
// 项目  : rv32gc-cpu（阶段二 2B-1：四发射顺序前端 + 锦标赛分支预测器）
// 规格  : docs/design/04-predictor.md §4.1（**唯一取值来源**）：
//           · 2048 项、**2 路组相联**（1024 组）；每路 tag **30 bit**（= PC[31:2]，
//             即**按 4 B 字**粒度 ⇒ 条目按 4 B 字唯一标识）
//           ★ 组索引口径澄清：04 §4.1 的「组索引 PC[12:2]（11 bit）」与「2048 项 /
//             1024 组」不自洽（11 bit ⇒ 2048 组）。本实现按**项数/相联度优先**取
//             索引 **PC[11:2]（10 bit）**，tag 仍取 PC[31:2]（全字地址校验）。
//             见 rtl/front4/front4_params.vh §5 与 README §3。
//           · 项字段：tag(30)、target(32)、is_call(1)、is_return(1)、is_cond(1)、valid(1)
//           · 命中用途：① 提供跳转目标；② 标记该取指块含分支/调用/返回
//           · 未命中：顺序推进（预测不跳），由 BRU 在 E1 纠正并在**提交时**分配
//           · 替换：组内 LRU（2 路，1 bit）
//           · 更新时机：分支**提交**时写入（避免错误路径分配）
//
// 【本模块对 04 §4.1 的两点工程化补充（写明白，避免与文档读者理解不一致）】
//   ① **"哪一路命中"由提交事件携带**（`upd_hit`/`upd_way`）：命中 ⇒ 原地更新该项；
//      未命中 ⇒ 写入组内 LRU 路。这样提交路径上**不需要再读一次 tag**（BTB 的读口
//      要留给每拍取指查表，提交读了就会停顿取指）。这两个信号在取指查出结果时随
//      指令一起流到 ROB，提交时回传——2B-2 的分支误判比对本来就需要携带预测信息
//      （target/way），不额外引入状态。
//   ② **"间接跳转"用三标志全 0 表示**：04 §4.1 的字段表没有单独的 is_indirect，本实现
//      约定 `valid & ~is_cond & ~is_call & ~is_return` = 间接跳转（`jalr` 非返回），
//      目标取 BTB target。直接跳转（`jal`/`c.j`/`c.jal`）与条件分支的目标是
//      PC+imm，由 ifetch4 直接算，不占 BTB（04 §4.1 "BTB 与 PHT 解耦"的同精神）。
//
// 存储：每路一个 front4_mem_1r1w（1024 × 66 bit）；LRU 位 = 1024 bit 寄存器阵列
//       （小元数据，非"大表"）。
//==============================================================================

`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"
`include "rtl/front4/front4_params.vh"

module bpu_btb #(
    parameter integer WAYS     = `FRONT4_BTB_WAYS,     // 2
    parameter integer SETS     = `FRONT4_BTB_SETS,     // 1024
    parameter integer IDX_BITS = `FRONT4_BTB_IDX_BITS, // 10（1024 组）
    parameter integer TAG_BITS = `FRONT4_BTB_TAG_BITS  // 30
) (
    input  wire                  clk,
    input  wire                  rst_n,

    //------------------------------------------------------------------
    // 查表（F2）：一拍一次（**按 4 B 字**）；结果下一拍有效
    //   同一个 4 B 字的两个 parcel 共享同一项（tag = PC[31:2] 对两个字半相同）
    //------------------------------------------------------------------
    input  wire                  lu_en,
    input  wire [31:0]           lu_pc,        // 取指字地址（建议 4 B 对齐）
    output wire                  lu_valid_o,   // 结果有效（与下面同拍）
    output wire                  lu_hit_o,
    output wire                  lu_way_o,
    output wire [31:0]           lu_target_o,
    output wire                  lu_is_cond_o,
    output wire                  lu_is_call_o,
    output wire                  lu_is_return_o,

    //------------------------------------------------------------------
    // 提交点更新（分配 / 原地更新；1 拍完成）
    //------------------------------------------------------------------
    input  wire                  upd_req,
    input  wire [31:0]           upd_pc,
    input  wire [31:0]           upd_target,
    input  wire                  upd_is_cond,
    input  wire                  upd_is_call,
    input  wire                  upd_is_return,
    input  wire                  upd_hit,      // 取指时是否命中（携带到提交点）
    input  wire                  upd_way,      // 取指时命中哪一路
    output wire [31:0]           cnt_alloc,    // 分配次数
    output wire [31:0]           cnt_updhit    // 原地更新次数
);

    //--------------------------------------------------------------------------
    // 0. 常量与条目位段（单点定义，禁止散落魔法数）
    //--------------------------------------------------------------------------
    localparam integer W   = WAYS;                 // 2
    localparam integer AW  = IDX_BITS;             // 11
    localparam integer ENT = TAG_BITS + 32 + 3 + 1;// 30+32+3+1 = 66

    localparam integer B_VALID  = 0;
    localparam integer B_TAG_LO = 1;
    localparam integer B_TAG_HI = B_TAG_LO + TAG_BITS - 1;   // 30
    localparam integer B_TGT_LO = B_TAG_HI + 1;              // 31
    localparam integer B_TGT_HI = B_TGT_LO + 31;             // 62
    localparam integer B_COND   = 63;
    localparam integer B_CALL   = 64;
    localparam integer B_RET    = 65;

    //--------------------------------------------------------------------------
    // 1. 纯组合 function（先声明后使用）：打包一个 BTB 项
    //--------------------------------------------------------------------------
    function [ENT-1:0] pack_entry;
        input              v;
        input [TAG_BITS-1:0] tg;
        input [31:0]       tgt;
        input              is_c;
        input              is_call;
        input              is_ret;
        begin
            pack_entry                  = {ENT{1'b0}};
            pack_entry[B_VALID]         = v;
            pack_entry[B_TAG_HI:B_TAG_LO] = tg;
            pack_entry[B_TGT_HI:B_TGT_LO] = tgt;
            pack_entry[B_COND]          = is_c;
            pack_entry[B_CALL]          = is_call;
            pack_entry[B_RET]           = is_ret;
        end
    endfunction

    //--------------------------------------------------------------------------
    // 2. LRU 位（1 bit/组；1 ⇒ way1 为 LRU）
    //--------------------------------------------------------------------------
    reg [SETS-1:0] lru_q;          // 1024 bit 小元数据（不是"大表"）

    wire [AW-1:0]     lu_set  = lu_pc[11:2];
    wire [TAG_BITS-1:0] lu_tag = lu_pc[31:2];

    //--------------------------------------------------------------------------
    // 3. 两路的存储（每路：1 读 1 写）
    //--------------------------------------------------------------------------
    wire [ENT-1:0] w0_dout, w1_dout;
    wire [ENT-1:0] w0_din, w1_din;
    wire           w0_we,  w1_we;

    front4_mem_1r1w #(.DW(ENT), .DEPTH(SETS), .AW(AW)) u_way0 (
        .clk(clk), .rst_n(rst_n),
        .a_en(w0_we), .a_addr(upd_pc[11:2]), .a_din(w0_din),
        .b_en(lu_en), .b_addr(lu_set), .b_dout(w0_dout)
    );

    front4_mem_1r1w #(.DW(ENT), .DEPTH(SETS), .AW(AW)) u_way1 (
        .clk(clk), .rst_n(rst_n),
        .a_en(w1_we), .a_addr(upd_pc[11:2]), .a_din(w1_din),
        .b_en(lu_en), .b_addr(lu_set), .b_dout(w1_dout)
    );

    //--------------------------------------------------------------------------
    // 4. 查表结果（寄存读数据的下一拍比较）
    //--------------------------------------------------------------------------
    //   ★ 读延迟口径：两路存储本身是**同步读**（读数据在请求的下一拍有效），
    //     因此这里**不再加寄存器**（加了就变成 2 拍，和 GPHT/LPHT/选择器的 1 拍
    //     对不齐）；直接用存储输出 + 打了一拍的 tag/valid 做比较 ⇒ 命中路径 1 拍。
    reg             lu_valid_q;
    reg  [TAG_BITS-1:0] lu_tag_q;
    reg  [AW-1:0]   lu_set_q;

    wire w0_v = w0_dout[B_VALID];
    wire w1_v = w1_dout[B_VALID];
    wire w0_t = (w0_dout[B_TAG_HI:B_TAG_LO] == lu_tag_q) & w0_v;
    wire w1_t = (w1_dout[B_TAG_HI:B_TAG_LO] == lu_tag_q) & w1_v;

    assign lu_valid_o    = lu_valid_q;
    assign lu_hit_o      = (w0_t | w1_t) & lu_valid_q;
    assign lu_way_o      = w0_t ? 1'b0 : 1'b1;      // w0 优先（组内两路不可能同 tag）
    assign lu_target_o   = w0_t ? w0_dout[B_TGT_HI:B_TGT_LO] : w1_dout[B_TGT_HI:B_TGT_LO];
    assign lu_is_cond_o  = w0_t ? w0_dout[B_COND] : w1_dout[B_COND];
    assign lu_is_call_o  = w0_t ? w0_dout[B_CALL] : w1_dout[B_CALL];
    assign lu_is_return_o= w0_t ? w0_dout[B_RET]  : w1_dout[B_RET];

    //--------------------------------------------------------------------------
    // 5. 提交点写（命中 ⇒ 原路更新；未命中 ⇒ LRU 路分配）
    //--------------------------------------------------------------------------
    wire upd_victim = upd_hit ? upd_way : lru_q[upd_pc[11:2]];

    assign w0_we = upd_req & ~upd_victim;
    assign w1_we = upd_req &  upd_victim;
    assign w0_din = pack_entry(1'b1, upd_pc[31:2], upd_target, upd_is_cond, upd_is_call, upd_is_return);
    assign w1_din = w0_din;     // 两路写入数据相同（victim 由 we 选择）

    //--------------------------------------------------------------------------
    // 6. 时序：查表打拍 + LRU 更新 + 统计
    //--------------------------------------------------------------------------
    reg [31:0] cnt_alloc_q, cnt_updhit_q;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lu_valid_q <= 1'b0;
            lu_tag_q   <= {TAG_BITS{1'b0}};
            lu_set_q   <= {AW{1'b0}};
            lru_q      <= {SETS{1'b0}};
            cnt_alloc_q  <= 32'h0;
            cnt_updhit_q <= 32'h0;
        end else begin
            // ---- 查表打拍（同步读数据） ----
            lu_valid_q <= lu_en;
            lu_tag_q   <= lu_tag;
            lu_set_q   <= lu_set;

            // ---- LRU：命中 ⇒ 另一路变 LRU；分配 ⇒ 被写路变 MRU ----
            //   ★ 必须用**打了一拍的** `lu_valid_q`（命中信息与存储读数据同拍有效），
            //     不能用当拍的 `lu_en`（那是"请求"拍，此时 hit 尚无意义）——
            //     TB 的 A4 用例正是靠"连续查表 ⇒ LRU 刷新"打出了这个错。
            if (lu_valid_q && (w0_t | w1_t)) begin
                lru_q[lu_set_q] <= ~(w0_t ? 1'b0 : 1'b1);
            end
            if (upd_req) begin
                lru_q[upd_pc[11:2]] <= ~upd_victim;
            end

            // ---- 统计 ----
            if (upd_req && !upd_hit) cnt_alloc_q  <= cnt_alloc_q + 32'd1;
            if (upd_req &&  upd_hit) cnt_updhit_q <= cnt_updhit_q + 32'd1;
        end
    end

    assign cnt_alloc  = cnt_alloc_q;
    assign cnt_updhit = cnt_updhit_q;

endmodule
