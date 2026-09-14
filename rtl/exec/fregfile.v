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
//
// 勘误（2026-09-14，随 tb_fregfile.sv 首跑修复）：读口原用 `function rd_port`
//   读 `fpr[]` 实现；**iverilog 12.0 对"函数体内读模块级数组"不建立写依赖**
//   ⇒"读地址不变、只有阵列变化"时读口不重算，返回陈旧值（复位后表现为恒 x；
//   实测 dut.fpr[0]=0 而 rdata*=x）。已改为三条内联 `assign`（端口/语义不变，
//   两模拟器依赖均正确）；缺陷最小复现与回归哨兵见 sim/unit/tb_fregfile.sv。
//   规约依据：`docs/kb/tools-and-flow.md` §2.1「iverilog 表征缺陷规约」第 ① 条
//   ——被 `function` 读取的信号必须显式作为 `function` 的 `input` 传入，不得让
//   `function` 直接引用模块级 `reg`/`wire`。本文件比该条更严：读口**完全不用**
//   `function`，一律三条同构内联 `assign`（条件表达式 == 纯组合 mux，红线 3）。
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
    // 三条内联 `assign` + 条件表达式：纯组合读口 mux，无副作用（红线 3）。
    //
    // ★★ 必须内联，**不能**改写成"function 内读 fpr[]"（2026-09-14 实测缺陷）：
    //    iverilog 12.0 对**函数体内读模块级数组**不建立写依赖 ⇒ 读口在
    //    "读地址不变、只有阵列变化"时不重算，读到**陈旧值**（复位后表现为
    //    恒 `x`，实测：复位后固定读 f0 ⇒ rdata*=x，而层次引用 dut.fpr[0]=0）。
    //    最小复现（含 Verilator 对照）见 sim/unit/tb_fregfile.sv 头注；
    //    tb_fregfile.sv 的"复位后零抖动读"即为该缺陷的回归哨兵。
    //    内联写法在 iverilog 12.0 与 Verilator 5.020 下行为一致且正确。
    //
    // 口径唯一性由三条 assign 的同构写法保证（同一模板三处展开，改一处必
    // 三处同步——已由 tb_fregfile.sv 的"三读口并发/部分冲突"用例把住）。
    assign rdata1 = (we && (rd == rs1)) ? wdata : fpr[rs1];
    assign rdata2 = (we && (rd == rs2)) ? wdata : fpr[rs2];
    assign rdata3 = (we && (rd == rs3)) ? wdata : fpr[rs3];

endmodule
