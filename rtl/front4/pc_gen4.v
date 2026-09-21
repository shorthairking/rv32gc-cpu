//==============================================================================
// rtl/front4/pc_gen4.v —— F1：4 路取指的 PC 生成（顺序推进 / 预测目标 / 重定向）
//==============================================================================
// 项目  : rv32gc-cpu（阶段二 2B-1：四发射顺序前端 + 锦标赛分支预测器）
// 规格  : docs/design/02-pipeline.md §3.1（F1 逐级定义）：
//           · 三种来源：① 顺序推进（上一拍取指块长度）、② 预测目标（BTB 命中/RAS 栈顶）、
//             ③ **重定向**（分支误判/异常/中断/RAS 修复/断点）
//           · **重定向优先级最高**：同拍既有重定向又有顺序推进 ⇒ 只有重定向生效
//           · **跨页**：本拍取指块跨页时只推进到页边界，绝不在同拍跨页取指
//           · `RESET_PC = 0x1C00_0000`（core_params.vh §1）
//         docs/design/02-pipeline.md §4.2（BTB/RAS 查询与取指一拍错位）、§6.2（冲刷语义）
//
// 【本设计的流式口径（与 02 文档"一拍取一个 4 路块"的对应关系）】
//   2A 的 L1I 接口是**一次一个字（4 B）**（rtl/cache/l1i.v 的 cs_req/cs_ready/cs_rdata，
//   命中 1 拍返回 1 个 32 bit 字），无法在一拍读出 32 B 整行。因此本前端把 F1 的取指
//   流做成**逐字的顺序流**：F1 维护"下一个要请求的取指字地址" `fetch_pc`（字对齐），
//   每成功推进一个字就 +4（页内最后一个字推进到**下一页首页**，不跨页一步推进）。
//   4 路分组由后级（ifetch4 的 parcel 缓冲 + 对齐器）完成：它把连续取回的字拆成
//   16 bit parcel 流，再按 16/32 bit 指令边界拼成 ≤4 条指令的块。
//   ⇒ 与文档的差异只在**取指带宽**（1 字/拍 vs 32 B/拍），已在 rtl/front4/README.md
//     §4 写明取舍；分组/终止/重定向语义与文档一致。
//
// 【两级 PC（都在这一个模块里，单点定义，避免两处口径）】
//   · `fetch_pc`（字对齐）  ：下一个要发起请求的取指字。
//   · `head_pc`（parcel 精度）：缓冲里**第一个未被消费**的 parcel 地址（块拼接/PC 口径）。
//   两者都由 ①重定向 ②前端预测重启 清到同一个新 PC 上（重启 = 预测跳转生效）。
//
// 【epoch（防陈旧响应）】每次"重定向/重启"把 epoch 加 1（2 bit 环形）。F3/F4 的
//   在途字带着自己的 epoch，只有 epoch 相等才允许写入 parcel 缓冲——被冲刷的旧字
//   即使从 L1I/直连通路返回也不会污染新路径（与 l1i 的"响应归属校验"同一精神）。
//   2 bit 足够：在途级数 ≤ 3 < 4。
//==============================================================================

`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"
`include "rtl/front4/front4_params.vh"

module pc_gen4 (
    input  wire        clk,
    input  wire        rst_n,

    //------------------------------------------------------------------
    // 复位/停顿
    //------------------------------------------------------------------
    input  wire        rst_hold,          // 复位保持（取指流停在上电 PC）
    input  wire        fetch_stall,       // 冻结：缓冲满 / L1I 未回 / 下游反压 / 断点

    //------------------------------------------------------------------
    // 重定向（**最高优先级**；来自后端：误判/异常/中断/RAS 修复）
    //------------------------------------------------------------------
    input  wire        redirect_valid,
    input  wire [31:0] redirect_pc,

    //------------------------------------------------------------------
    // 前端预测重启（对齐器消费到"预测跳转"的块尾时发出）
    //------------------------------------------------------------------
    input  wire        restart_valid,
    input  wire [31:0] restart_pc,

    //------------------------------------------------------------------
    // 顺序推进与消费
    //------------------------------------------------------------------
    input  wire        pipe_advance,      // 本拍成功把 F2 的字交给 F3（顺序 +4）
    input  wire        head_adv_valid,    // 本拍消费了 k 字节（head_pc 前移）
    input  wire [4:0]  head_adv_bytes,    // 消费字节数（2..16；一个 4 路块内）

    //------------------------------------------------------------------
    // 输出
    //------------------------------------------------------------------
    output wire [31:0] fetch_pc,          // 下一个取指字地址（字对齐）
    output wire [31:0] head_pc,           // 缓冲头 parcel 地址（parcel 精度）
    output wire [1:0]  epoch,
    output wire        stream_phase1,     // 当前流首 parcel 在字高半（PC[1]==1）
    output wire [31:0] page_last_next     // 页内最后一字时的下一页首字（供推进 mux 用）
);

    localparam [31:0] RESET_PC = `RV32GC_RESET_PC;

    reg [31:0] fetch_pc_q;
    reg [31:0] head_pc_q;
    reg [1:0]  epoch_q;
    reg        phase1_q;

    // 顺序推进目标：页内最后一个字（PC[11:0]==12'hFFC）⇒ 推进到**下一页首页**
    //   （不跨页一步推进；下一页首页由同一流的下一次请求再翻译，Sv32 下也安全）
    assign page_last_next = (fetch_pc_q[11:0] == 12'hFFC)
                            ? {fetch_pc_q[31:12] + 20'd1, 12'h000}
                            : (fetch_pc_q + 32'd4);

    // head 前移（parcel 精度；用于块的 next_pc 与缓冲消费）
    wire [31:0] head_next = head_pc_q + {27'b0, head_adv_bytes};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fetch_pc_q <= RESET_PC;
            head_pc_q  <= RESET_PC;
            epoch_q    <= 2'b00;
            phase1_q   <= 1'b0;
        end else if (rst_hold) begin
            fetch_pc_q <= RESET_PC;
            head_pc_q  <= RESET_PC;
            epoch_q    <= 2'b00;
            phase1_q   <= 1'b0;
        end else begin
            // ---- ① 重定向（最高优先级）----
            if (redirect_valid) begin
                fetch_pc_q <= {redirect_pc[31:2], 2'b00};
                head_pc_q  <= redirect_pc;
                phase1_q   <= redirect_pc[1];
                epoch_q    <= epoch_q + 2'd1;
            end
            // ---- ② 前端预测重启（消费到预测跳转）----
            else if (restart_valid) begin
                fetch_pc_q <= {restart_pc[31:2], 2'b00};
                head_pc_q  <= restart_pc;
                phase1_q   <= restart_pc[1];
                epoch_q    <= epoch_q + 2'd1;
            end
            // ---- ③ 顺序：字推进与 head 前移（可同拍发生）----
            else begin
                if (pipe_advance && !fetch_stall) fetch_pc_q <= page_last_next;
                if (head_adv_valid)               head_pc_q  <= head_next;
            end
        end
    end

    assign fetch_pc     = fetch_pc_q;
    assign head_pc      = head_pc_q;
    assign epoch        = epoch_q;
    assign stream_phase1= phase1_q;

endmodule
