//==============================================================================
// rtl/front4/front4_table_2lu_1upd.v —— 预测表端口包装：2 查表口 + 1 更新口
//==============================================================================
// 项目  : rv32gc-cpu（阶段二 2B-1：四发射顺序前端 + 锦标赛分支预测器）
// 规格  : docs/design/04-predictor.md §2（表实现：Vivado 存储 IP + 仿真行为模型双
//         分支）、§5.2（提交点更新：GPHT/LPHT/选择器都是**读-改-写**饱和计数）。
//
// 【为什么需要这个包装（微架构理由，不是"为了用 IP"）】
//   4 路取指每拍要给 **2 个 parcel** 各做一次查表（= 2 个读口），而提交点训练是
//   **读-改-写**（还要 1 读 + 1 写）。若只用一个存储：3 读 1 写 ⇒ 端口不够；
//   若让更新借用查表口 ⇒ 训练会**停顿取指**（每提交一条分支丢 1–2 拍取指带宽）。
//   ⇒ 每个表用**两个存储副本**：
//       · mem0：A 口 = 更新 RMW 的读（+写），B 口 = 查表口 0
//       · mem1：A 口 = 更新写的镜像，          B 口 = 查表口 1
//     两份副本每个时钟沿收到**同一笔写**，因此内容恒一致；查表永远走 B 口，
//     训练读走 mem0 的 A 口 ⇒ **训练与取指互不抢端口**（面积换端口，教科书做法）。
//
// 【为什么不是"单存储 + 借用端口"】见上：会引入取指停顿（本项目取指 = 1 字/拍，
//   任何借用都是直接吞吐损失）。
//
// 【双分支】mem0/mem1 都由 front4_mem_2r1w 例化 ⇒ 综合走 XPM（xpm_memory_tdpram），
//   仿真走逐拍等价行为模型。见 front4_mem.v 的 IP 检索结论。
//==============================================================================

`timescale 1ns / 1ps

`include "rtl/front4/front4_params.vh"

module front4_table_2lu_1upd #(
    parameter integer DW    = 2,
    parameter integer DEPTH = 4096,
    parameter integer AW    = 12,
    parameter [DW-1:0] INIT = {DW{1'b0}}
) (
    input  wire          clk,
    input  wire          rst_n,

    // ---- 查表口 0（同步读，读数据 1 拍后有效） ----
    input  wire          lu0_en,
    input  wire [AW-1:0] lu0_addr,
    output wire [DW-1:0] lu0_dout,
    // ---- 查表口 1 ----
    input  wire          lu1_en,
    input  wire [AW-1:0] lu1_addr,
    output wire [DW-1:0] lu1_dout,

    // ---- 更新口（读：rd_en 后 1 拍给出 rd_dout；写：wr_en 当拍写两个副本） ----
    input  wire          upd_rd_en,
    input  wire [AW-1:0] upd_rd_addr,
    output wire [DW-1:0] upd_rd_dout,
    input  wire          upd_wr_en,
    input  wire [AW-1:0] upd_wr_addr,
    input  wire [DW-1:0] upd_wr_data
);

    // mem0：A 口 = 更新（读/写），B 口 = 查表口 0
    front4_mem_2r1w #(
        .DW(DW), .DEPTH(DEPTH), .AW(AW), .INIT(INIT)
    ) u_mem0 (
        .clk(clk), .rst_n(rst_n),
        .a_en  (upd_rd_en | upd_wr_en),
        .a_we  (upd_wr_en),
        .a_addr(upd_wr_en ? upd_wr_addr : upd_rd_addr),
        .a_din (upd_wr_data),
        .a_dout(upd_rd_dout),
        .b_en  (lu0_en),
        .b_addr(lu0_addr),
        .b_dout(lu0_dout)
    );

    // mem1：A 口 = 更新写的镜像（只写），B 口 = 查表口 1
    wire [DW-1:0] mem1_a_dout_unused;
    front4_mem_2r1w #(
        .DW(DW), .DEPTH(DEPTH), .AW(AW), .INIT(INIT)
    ) u_mem1 (
        .clk(clk), .rst_n(rst_n),
        .a_en  (upd_wr_en),
        .a_we  (upd_wr_en),
        .a_addr(upd_wr_addr),
        .a_din (upd_wr_data),
        .a_dout(mem1_a_dout_unused),
        .b_en  (lu1_en),
        .b_addr(lu1_addr),
        .b_dout(lu1_dout)
    );

endmodule
