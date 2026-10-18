//==============================================================================
// rtl/fetch/pc_gen.v —— PCC（Program Counter Generator，F 级 PC 生成与选择）
//==============================================================================
// 项目  : rv32gc-cpu（阶段二 2A：单发射顺序 5 级基线核）
// 规格  : docs/design/08-baseline-5stage.md §5.1（F 级）行为要点 ①、③、⑥；
//         §4.3「RESET_PC 与取指口径」；§4.4「break_point 在 F 级制造重定向」。
// 依据  : §5.1 ① 「PCC：PC 来源优先级 = 复位（RESET_PC）> 重定向（异常/中断/
//         BRU 误判/断点）> 顺序推进（pc+2 或 pc+4，取决于指令长度）」
//         §4.3 「RESET_PC = 0x1C00_0000（SPI Flash XIP 窗口）」——
//         取值只从 rtl/pkg/core_params.vh 的 `RV32GC_RESET_PC 取，不在此硬编码。
//
// 【与规格的一处显式取舍：复位优先级 = 冻结 PC，不跳到 RESET_PC 本身】
//   §5.1 ① 写的是 "复位优先级最高"；若照字面把 aresetn 有效期间的 pc 更新为
//   `RV32GC_RESET_PC，则 aresetn 一释放，顺序推进会把 pc 变成 RESET_PC+2，
//   第一条取回窗口的指令地址将不是 RESET_PC，与 §4.3 / §8.2（M1 首条取指 =
//   0x1C00_0000）以及「复位取指必须落在 XIP 窗口」的硬事实冲突。
//   因此本实现令复位**冻结** PC（`pc_r` 在异步复位置 `RV32GC_RESET_PC，
//   aresetn 有效期间不推进），使 aresetn 释放后的下一次取指恰为 RESET_PC。
//   该取舍在 sim/unit/tb_pc_gen.sv 中有专门的锁定用例（RSTFREEZE）。
//
// 【MMU 口径】§5.1 行为要点 ④/⑥：开 MMU（satp.MODE=Sv32）前的取指不加任何
//   自动修正，PC 流水直接使用 `redirect_pc` 原值。故本模块**不含**任何
//   「跨窗口跳转自动修正」逻辑；窗内对齐（把跳转目标拉回 4 B 对齐的包含字）
//   是取指流水本身的职责边（§5.1 ⑤ 一次取回 32 B），实现于 fetch_unit.v。
//
// 【组合逻辑风格（AGENT.md §4 红线 3 / 08 §7.4）】
//   全部组合逻辑用 assign + function 表达；本模块**只有一处** always 块，
//   内容是同步时序元件（异步复位 D 触发器），注释见该处。
//
// 【未例化任何 FPGA 原语（AGENT.md §4 红线 1）】
//   PC 是 32 bit 寄存器 + 4 bit 进位加法，属最普通触发器/进位链：Xilinx 无
//   对应「PC 生成」IP（Vivado IP 目录只有 DSP/BRAM/FIFO/Clocking/Protocol 类），
//   故按红线允许的例外写可综合 HDL，无任何 primitive 例化。
//==============================================================================

`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"

module pc_gen (
    input  wire        aclk,
    input  wire        aresetn,        // 低有效异步复位

    // ---- 复位来源 ----
    input  wire        rst_hold,       // 软/外部复位保持：阻塞推进并冻结 PC（见下）
    input  wire        rst_valid,      // 软复位请求：重载 PC <- `RV32GC_RESET_PC
                                       //   （与 aresetn 的差别：它受时钟沿采样，
                                       //     便于将来由 W 级统一异常入口发起）

    // ---- 重定向来源（优先级：异常/中断 > BRU > 断点；§5.1 ① 只规定
    //      「重定向」整体高于顺序推进，其内部三者的相对次序由 §4.4 与
    //      02-pipeline.md:243 决定：redirect_pc 是 W 级统一异常入口 / BRU
    //      产生的「新取指 PC」，break_point 是平台调试探针，故最低） ----
    input  wire        redirect_exc_valid,  // 异常/中断/断点冲刷（W 级统一入口）
    input  wire [31:0] redirect_exc_pc,     // 目标 = *tvec/stvec（虚拟地址）
    input  wire        redirect_bru_valid,  // BRU 分支/JAL/JALR 重定向
    input  wire [31:0] redirect_bru_pc,
    input  wire        break_point,         // 平台断点探针（§4.4：F 级制造重定向）

    // ---- 顺序推进（§5.1 ①：pc+2 或 pc+4，取决于上一拍取指长度） ----
    input  wire        seq_adv_valid,       // 本拍允许顺序推进
    input  wire        seq_len32,           // 1 ⇒ 推进 4 B；0 ⇒ 推进 2 B（IALIGN=16）

    // ---- 观察输出 ----
    output wire [31:0] pc,              // 当前取指 PC（虚拟地址）
    output wire [31:0] pc_next,         // 本拍选的下一 PC（= 下拍 pc）
    output wire [3:0]  pc_sel,          // 0=保持 1=复位 2=异常/中断 3=BRU 4=断点 5=顺序
    output wire [31:0] pc_plus2,
    output wire [31:0] pc_plus4
);

    //--------------------------------------------------------------------------
    // 0. 复位常量（唯一真源：rtl/pkg/core_params.vh §1）
    //    08 §4.3 / §5.1 ①：RESET_PC = 0x1C00_0000（SPI Flash XIP 主窗口）
    //--------------------------------------------------------------------------
    localparam [31:0] RESET_PC = `RV32GC_RESET_PC;

    //--------------------------------------------------------------------------
    // 0.1 取值口径的**编译期自检**（把规格字面值写进可执行代码，而非只写在注释里）
    //     08 §4.3 / §5.1 ①：RESET_PC 必须 = 32'h1C00_0000（SPI Flash XIP 主窗口）。
    //     真源仍在 core_params.vh；此处只做「真源 == 规格字面值」的等价断言：
    //     有人误改真源时 RESET_PC_OK 立刻变 0（下游 TB/顶层可引用它做 fail-closed 检查）。
    //--------------------------------------------------------------------------
    localparam [31:0] RESET_PC_SPEC = 32'h1C00_0000;   // 规格字面值（08 §4.3）
    localparam        RESET_PC_OK   = (RESET_PC == RESET_PC_SPEC);

    //--------------------------------------------------------------------------
    // 1. PC 选择类型（给 pc_sel 以可读名字；不用枚举/typedef，保持 Verilog-2001）
    //--------------------------------------------------------------------------
    localparam [2:0] SEL_HOLD   = 3'd0;   // 冻结（复位保持 / 无推进且无重定向）
    localparam [2:0] SEL_RST    = 3'd1;   // 复位
    localparam [2:0] SEL_EXC    = 3'd2;   // 异常 / 中断
    localparam [2:0] SEL_BRU    = 3'd3;   // BRU 重定向
    localparam [2:0] SEL_BRK    = 3'd4;   // 断点
    localparam [2:0] SEL_SEQ    = 3'd5;   // 顺序推进

    //--------------------------------------------------------------------------
    // 2. 顺序推进量：pc+2 / pc+4（§5.1 ①）
    //--------------------------------------------------------------------------
    // 说明：两条加法都用 assign + 显式位宽写；不使用 {carry, ...} 手写加法器
    //       （+ 运算符即由综合器映射到器件进位链，无需也不得用原语）。
    wire [31:0] pc_plus2_i = pc + 32'd2;
    wire [31:0] pc_plus4_i = pc + 32'd4;
    wire [31:0] pc_seq     = seq_len32 ? pc_plus4_i : pc_plus2_i;

    assign pc_plus2 = pc_plus2_i;
    assign pc_plus4 = pc_plus4_i;

    //--------------------------------------------------------------------------
    // 3. PC 来源优先级（§5.1 ①；用 function 表达优先级 mux，避免 always @(*)）
    //     复位 > 异常/中断 > BRU > 断点 > 顺序推进 > 保持
    //     `rst_hold` 属复位类来源，与 `rst_valid` 同为最高优先级。
    //--------------------------------------------------------------------------
    function [2:0] pc_sel_f;
        input rst_hold_i;
        input rst_valid_i;
        input exc_valid_i;
        input bru_valid_i;
        input brk_i;
        input seq_valid_i;
        begin
            if (rst_hold_i || rst_valid_i)      pc_sel_f = SEL_RST;
            else if (exc_valid_i)               pc_sel_f = SEL_EXC;
            else if (bru_valid_i)               pc_sel_f = SEL_BRU;
            else if (brk_i)                     pc_sel_f = SEL_BRK;
            else if (seq_valid_i)               pc_sel_f = SEL_SEQ;
            else                                pc_sel_f = SEL_HOLD;
        end
    endfunction

    wire [2:0] sel = pc_sel_f(rst_hold, rst_valid, redirect_exc_valid,
                              redirect_bru_valid, break_point, seq_adv_valid);

    // 断点目标 = 当前 PC（§4.4：2A 允许「停在 F 级不再推进」，实现为把 PC
    // 重定向回自身 ⇒ 反复取同一条指令，不前进且不越界；完整断点处理在 M2+）。
    function [31:0] pc_next_f;
        input [2:0]  sel_i;
        input [31:0] pc_i;
        input [31:0] exc_pc_i;
        input [31:0] bru_pc_i;
        input [31:0] seq_pc_i;
        begin
            case (sel_i)
                SEL_RST : pc_next_f = RESET_PC;    // 复位：RESET_PC = 0x1C00_0000
                SEL_EXC : pc_next_f = exc_pc_i;    // 异常/中断：*tvec（VA）
                SEL_BRU : pc_next_f = bru_pc_i;    // BRU（VA）
                SEL_BRK : pc_next_f = pc_i;        // 断点：停在当前 PC
                SEL_SEQ : pc_next_f = seq_pc_i;    // 顺序推进
                default : pc_next_f = pc_i;        // SEL_HOLD：冻结
            endcase
        end
    endfunction

    wire [31:0] pc_next_i = pc_next_f(sel, pc, redirect_exc_pc,
                                      redirect_bru_pc, pc_seq);

    assign pc_next = pc_next_i;
    assign pc_sel  = {1'b0, sel};   // 4 bit：便于波形/断言直接看来源编号

    //--------------------------------------------------------------------------
    // 4. PC 寄存器：**本模块唯一的 always 块**
    //    理由（AGENT.md §4 红线 3 / 08 §7.4 要求「确有必要并注释」）：
    //    这是不可用 assign 表达的时序元件（异步低有效复位的 D 触发器组）。
    //    块内只做一个数据源的寄存器更新，不含任何组合译码。
    //--------------------------------------------------------------------------
    reg [31:0] pc_r;

    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) pc_r <= RESET_PC;   // 异步复位 ⇒ PC = RESET_PC（0x1C00_0000）
        else          pc_r <= pc_next_i;
    end

    assign pc = pc_r;

    // 注：`rst_hold` 在 aresetn 有效（低）期间没有观测意义（异步复位已把 PC
    //     置为 RESET_PC）；它只作用于 aresetn 已释放之后的"软复位保持"，此时
    //     PC 停在 RESET_PC 直到 rst_hold 撤销，随后从 RESET_PC 开始顺序取指。

endmodule
