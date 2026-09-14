//==============================================================================
// fregfile.v —— 浮点寄存器堆 f0-f31（RV32 F/D：F 视图 32 bit / D 视图 64 bit）
//==============================================================================
// 项目  : rv32gc-cpu（2A 单发射顺序 5 级基线核）
// 规格  : docs/design/08-baseline-5stage.md §5.3（fregfile.v 行）
//         —— in: rs1/rs2/rs3/rd/we/wdata；out: rdata1/rdata2/rdata3
//         —— 写优先读口 + 旁路；f0-f31 在 D 视图下为 64 位
// 真源  : FLEN=64（core_params.vh §4 RV32GC_FLEN）、FPRS=32
// 行为  :
//   ① 物理上 32 × 64 bit（D 视图）；F 视图下每个寄存器只用低 32 bit。
//   ② **写优先（write-first）**：同一拍写 rd 与读同号 ⇒ 读口返回新值
//      （与 §3.3 "写优先寄存器堆" 教训一致），**不**额外叠加 WB 旁路——
//      写优先本身就是"寄存器堆内部的同拍旁路"。
//   ③ 三层旁路由 exe_ctrl 负责（W > M > 寄存器堆）；本模块只保证"写优先"。
//   ④ 复位后全 0（f0 无硬连零约束：RISC-V 的 f0 是普通寄存器，与 x0 不同）。
//   ⑤ 阵列用数组 + 同步写 / 组合读；D 视图读 64 bit 整体。
//      ★ 组合读大阵列在 Vivado 会退化成触发器（AGENT.md §3.3 / 红线 1）。
//        本设计按 2A 口径保留组合读（32×64 = 2048 bit，规模可控、不构成
//        BRAM 退化风险），并在综合报告中复核。如 M4 时序/面积需要，改
//        Block Memory Generator IP + 双分支（红线 1/2），接口不变。
//==============================================================================
`include "rv32_defs.vh"
`include "core_params.vh"

module fregfile #(
    parameter integer FPRS = `RV32GC_FPRS,     // 32
    parameter integer FLEN = `RV32GC_FLEN      // 64
) (
    input  wire                  clk,
    input  wire                  rst_n,
    // 读口（3 读：rs1/rs2/rs3；FMA 需要 rs3）
    input  wire [4:0]            rs1,
    input  wire [4:0]            rs2,
    input  wire [4:0]            rs3,
    output wire [FLEN-1:0]       rdata1,
    output wire [FLEN-1:0]       rdata2,
    output wire [FLEN-1:0]       rdata3,
    // 写口
    input  wire                  we,
    input  wire [4:0]            rd,
    input  wire [FLEN-1:0]       wdata
);

    // ---- 寄存器阵列 ----
    reg [FLEN-1:0] fpr [0:FPRS-1];

    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < FPRS; i = i + 1) begin
                fpr[i] <= {FLEN{1'b0}};
            end
        end else if (we) begin
            // 写 f0 合法：RISC-V 的 f0 不是硬连零寄存器。
            fpr[rd] <= wdata;
        end
    end

    // ---- 读口：写优先（同拍同号返回写入值） ----
    // 三个读口共用一个函数，保证口径唯一（避免三处各自实现漂移）。
    //
    // `always` 块用在这里的理由：这是**纯组合的读口 mux**，且需要"写优先"
    // 这一条件选择；用 assign + function 表达同一语义会让每个读口重复三遍
    // 三元表达式。此处保持 function 形式（无副作用、单输出），符合
    // AGENT.md §4.3 的精神（避免给多个 reg 赋值的 always @(*)）。
    function [FLEN-1:0] rd_port;
        input [4:0] idx;
        begin
            if (we && (rd == idx)) begin
                rd_port = wdata;          // 写优先旁路
            end else begin
                rd_port = fpr[idx];
            end
        end
    endfunction

    assign rdata1 = rd_port(rs1);
    assign rdata2 = rd_port(rs2);
    assign rdata3 = rd_port(rs3);

endmodule
