//==============================================================================
// rtl/front4/bpu_ras.v —— 返回地址栈 RAS（16 项，推测推进 + 检查点恢复 + D2 修复）
//==============================================================================
// 项目  : rv32gc-cpu（阶段二 2B-1：四发射顺序前端 + 锦标赛分支预测器）
// 规格  : docs/design/04-predictor.md §4.2（**唯一取值来源**）：
//           · 深度 **16 项**；**溢出时不压入**（栈顶保持，保守但正确）
//           · 压入：`jal`（rd 为链接寄存器 x1/x5）、`c.jal` 在 **D2**（译码确认后）
//           · 弹出：`jalr` 且 rd==x0 且源是链接寄存器 ⇒ **F 级用栈顶作预测目标**；
//                   **架构弹出（栈顶移动）在 D2 确认后**执行
//           · 修复：D2 发现实际返回地址 ≠ 栈顶 ⇒ **用实际值覆盖栈顶 + 冲刷 D2 之后
//                   的取指**（02 §6.1 类别 D，本设计唯一在 D2 触发的重定向）
//           · 恢复：重定向时 RAS 恢复到检查点深度（与 RAT 检查点同一套机制）
//         docs/design/03-out-of-order.md §3.4（检查点 16 个）
//
// 【本模块的职责边界】
//   · 只做"栈 + 深度快照值"；**检查点表在 predictor_top**（同一个检查点还要存 GHR
//     快照，故集中管理）：本模块对外只暴露 `depth_o` 与 `restore_valid/depth_restore`。
//   · 压/弹/修复的**判决**（哪条指令是 call/ret）不在本模块：由 D1/D2 译码给出
//     `push_valid`/`pop_valid`（2B-1 期间由 TB 的"D2 模型"驱动，接口即 2B-2 的衔接点）。
//   · `flush_all`（异常/中断全冲刷）：推测深度回到**已提交深度** `depth_cmt_q`
//     （由 ROB 提交侧的 `cmt_push/cmt_pop` 维护）——这样 `ret` 在冲刷后不会跳飞。
//
// 存储：16 × 32 bit = 512 bit，寄存器阵列（**不是**大表，面积可忽略，故不涉 IP）。
//==============================================================================

`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"
`include "rtl/front4/front4_params.vh"

module bpu_ras #(
    parameter integer DEPTH      = `FRONT4_RAS_DEPTH,       // 16
    parameter integer PTR_BITS   = `FRONT4_RAS_PTR_BITS     // 5（0..16）
) (
    input  wire                 clk,
    input  wire                 rst_n,

    //------------------------------------------------------------------
    // 推测态压/弹（D2 确认后执行；F 级只"读栈顶"做预测）
    //------------------------------------------------------------------
    input  wire                 push_valid,
    input  wire [31:0]          push_addr,      // 返回地址（call 指令的下一条）
    input  wire                 pop_valid,      // 确认的 ret
    input  wire [31:0]          pop_addr,       // 实际返回地址（架构 ra 值）
    output wire                 repair_valid,   // 1 = 与栈顶不符 ⇒ 调用方需冲刷类别 D
    output wire [31:0]          repair_addr,    // 覆盖后的栈顶值（= pop_addr）

    //------------------------------------------------------------------
    // 预测读口（F 级）
    //------------------------------------------------------------------
    output wire [31:0]          ras_top,
    output wire                 ras_empty,

    //------------------------------------------------------------------
    // 检查点深度快照（表在 predictor_top）
    //------------------------------------------------------------------
    output wire [PTR_BITS-1:0]  depth_o,
    input  wire                 restore_valid,
    input  wire [PTR_BITS-1:0]  depth_restore,

    //------------------------------------------------------------------
    // 全冲刷（异常/中断）与提交侧深度跟踪
    //------------------------------------------------------------------
    input  wire                 flush_all,
    input  wire                 cmt_push_valid,
    input  wire                 cmt_pop_valid,

    //------------------------------------------------------------------
    // 统计（04 §6.1：bpu_ras_push/pop/overflow/repair）
    //------------------------------------------------------------------
    output wire [31:0]          cnt_push,
    output wire [31:0]          cnt_pop,
    output wire [31:0]          cnt_ovf,
    output wire [31:0]          cnt_repair
);

    //--------------------------------------------------------------------------
    // 0. 常量
    //--------------------------------------------------------------------------
    localparam integer MAX_DEPTH = DEPTH;                 // 16
    localparam [PTR_BITS-1:0] FULL_D = MAX_DEPTH[PTR_BITS-1:0];

    //--------------------------------------------------------------------------
    // 1. 栈体与状态
    //--------------------------------------------------------------------------
    reg [31:0]          stk [0:MAX_DEPTH-1];
    reg [PTR_BITS-1:0]  sp_q;          // 栈深（0 = 空；sp_q-1 = 栈顶下标）
    reg [PTR_BITS-1:0]  sp_cmt_q;      // 已提交深度
    reg [31:0]          cnt_push_q, cnt_pop_q, cnt_ovf_q, cnt_repair_q;

    // 组合读栈顶（AGENT.md §4 红线 3：组合逻辑用 assign/function）
    wire [31:0] top_w = (sp_q == {PTR_BITS{1'b0}}) ? 32'h0
                                                  : stk[sp_q - 1'b1];   // 空栈 ⇒ 0（不越界）

    // 修复判定（D2）：非空且实际返回地址 ≠ 栈顶
    wire repair_w = pop_valid & (sp_q != {PTR_BITS{1'b0}}) & (top_w != pop_addr);

    // 压/弹使能（同一拍只可能有其中一个：D2 每拍一条分支流经，TB/2B-2 保证；
    // 若同时为真，按"先弹后压"处理并在此处显式记录，避免静默不确定）
    wire do_pop  = pop_valid & (sp_q != {PTR_BITS{1'b0}});
    wire do_push = push_valid & ~(pop_valid & (sp_q == FULL_D));   // 满 ⇒ 不压

    //--------------------------------------------------------------------------
    // 2. 时序
    //--------------------------------------------------------------------------
    integer k;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sp_q         <= {PTR_BITS{1'b0}};
            sp_cmt_q     <= {PTR_BITS{1'b0}};
            cnt_push_q   <= 32'h0;
            cnt_pop_q    <= 32'h0;
            cnt_ovf_q    <= 32'h0;
            cnt_repair_q <= 32'h0;
            for (k = 0; k < MAX_DEPTH; k = k + 1) stk[k] <= 32'h0;
        end else begin
            // ---- ① 压栈（D2 确认的 call）----
            if (push_valid) begin
                if (sp_q == FULL_D) begin
                    cnt_ovf_q <= cnt_ovf_q + 32'd1;    // 溢出：不压入，栈顶保持
                end else begin
                    stk[sp_q] <= push_addr;
                    sp_q      <= sp_q + 1'b1;
                end
                cnt_push_q <= cnt_push_q + 32'd1;
            end

            // ---- ② 弹栈（D2 确认的 ret）与修复 ----
            if (do_pop) begin
                if (repair_w) begin
                    stk[sp_q - 1'b1] <= pop_addr;      // 用实际 ra 覆盖栈顶
                    cnt_repair_q     <= cnt_repair_q + 32'd1;
                end
                sp_q       <= sp_q - 1'b1;
                cnt_pop_q  <= cnt_pop_q + 32'd1;
            end

            // ---- ③ 同时压弹（罕见）：以"弹后压"合并为净深度不变 ----
            if (do_pop && do_push) begin
                stk[sp_q - 1'b1] <= push_addr;
            end

            // ---- ④ 检查点恢复（重定向：误判/RAS 修复）----
            if (restore_valid) begin
                sp_q <= depth_restore;
            end

            // ---- ⑤ 全冲刷（异常/中断）：回到已提交深度 ----
            if (flush_all) begin
                sp_q <= sp_cmt_q;
            end

            // ---- ⑥ 已提交深度跟踪 ----
            if (cmt_push_valid && (sp_cmt_q != FULL_D)) sp_cmt_q <= sp_cmt_q + 1'b1;
            if (cmt_pop_valid  && (sp_cmt_q != {PTR_BITS{1'b0}})) sp_cmt_q <= sp_cmt_q - 1'b1;
        end
    end

    //--------------------------------------------------------------------------
    // 3. 输出
    //--------------------------------------------------------------------------
    assign ras_top      = (sp_q == {PTR_BITS{1'b0}}) ? 32'h0 : top_w;
    assign ras_empty    = (sp_q == {PTR_BITS{1'b0}});
    assign repair_valid = repair_w;
    assign repair_addr  = pop_addr;

    assign depth_o      = sp_q;
    assign cnt_push     = cnt_push_q;
    assign cnt_pop      = cnt_pop_q;
    assign cnt_ovf      = cnt_ovf_q;
    assign cnt_repair   = cnt_repair_q;

endmodule
