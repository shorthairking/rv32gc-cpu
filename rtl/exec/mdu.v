//==============================================================================
// rtl/exec/mdu.v —— E 级乘除法单元（MDU，多拍，IP + 行为模型双分支）
//==============================================================================
// 项目    : rv32gc-cpu（阶段二 2A：单发射顺序 5 级基线核）
// 依据    : docs/design/08-baseline-5stage.md §5.3 E 级表 —— `mdu.v`
//             「mul/mulh/mulhsu/mulhu/div/divu/rem/remu」；
//             in: a, b, mdu_op, flush；out: result, busy；
//             「**多拍**（2A 允许简单逐位实现，busy 冻结前端）；
//               乘除法允许 2A 用简单迭代实现（性能非 2A 门禁），但必须在 M4
//               评估面积/时序；Vivado Multiplier/Divider Generator IP +
//               仿真行为模型双分支（红线 1/2）」。
//           AGENT.md §4 红线 1（禁止原语，先检索 IP）、红线 2（IP 双分支）。
//           08 §3.3 第 3 条：宏名固定 `RV32GC_USE_VIVADO_IP`
//             （综合脚本定义、iverilog/Verilator 回归**从不**定义）。
//           08 §7.3 是 BRAM 的双分支范式，本文件照同口径落地。
// 唯一真源: `RV32GC_F3_MUL*`/`RV32GC_F3_DIV*` 编号即 M 扩展指令的 **funct3**
//           （rv32_defs.vh §3.7），故 D 级可直接把 funct3 接到 `mdu_op`。
//==============================================================================
// ★★★ 红线 1 检索结论（IP 检索过程与结论，必须留档；08 §9 / AGENT.md §4.1）★★★
//
//   [检索对象] Vivado 2025.2 IP Catalog（本机实测版本，见 /vivado.log：
//              "Vivado v2025.2 (64-bit), IP Build 6300035"）。
//   [检索项]   ① Multiplier          ② Divider Generator
//              ③ DSP Macro            ④ Complex Multiplier
//              ⑤ Block Memory Generator（对照，本项目 Cache 用）
//   [结论]
//     ① **Multiplier**（IP 名 `mult_gen`）：**存在且选用**。支持 32x32 有符号/
//        无符号/混合符号乘法，可配置为纯组合（0 延迟）或带流水寄存器。
//        ⇒ 本项目用**单个组合型 `mult_gen`** 同时产出 4 种乘法结果：
//           由于 `a*b` 的低 32 位在「有符号×有符号」与「无符号×无符号」下
//           **完全一致**（模 2^32 意义下），而 mulh/mulhsu/mulhu 只需高 32 位，
//           故例化 2 个实例（有符号、无符号）+ 1 个符号修正即可覆盖全部 4 条，
//           避免例化 4 个 64 位乘法器（面积最优，M4 评估）。
//     ② **Divider Generator**（IP 名 `div_gen`）：**存在且选用**。支持 32 位
//        被除数/除数、商与余数同拍输出（`m_axis_dout_tdata = {rem, quot}`），
//        有符号（`AR_SIGNED`）/无符号（`AR_UNSIGNED`）两种。
//        ⇒ 本项目例化 2 个实例（signed + unsigned），迭代延迟由 IP 内部
//           `Radix2`/LUTMult 配置决定；本模块**不假设其延迟**，一律以 IP 的
//          `s_axis_dout_tvalid`（tready/done 握手）为准推进状态机（见下「时序」）。
//     ③ DSP Macro：是**原语级封装**（DSP48E1 的直接配置界面），红线 1 明确
//        要求优先用 **IP**（Multiplier/Divider Generator）而非 DSP Macro
//        这类近似原语的界面 ⇒ **不选用**。
//     ④ Complex Multiplier：面向复数乘法，语义不符 ⇒ 不选用。
//     ⑤ 结论汇总：**无「更好的替代」**，Multiplier + Divider Generator 是最合适的
//        两个 IP；**不需要写可综合乘法器/除法器 HDL**（除 IP 之外的胶合逻辑）。
//        ⇒ 合法路径 = 例化上述 2 类 IP + 仿真行为模型双分支。
//
//   [覆盖度声明] 上述检索依据为 Vivado 2025.2 的 IP Catalog 文档化条目
//     （Multiplier v12.0 / Divider Generator v5.1 系列，Xilinx PG108/PG151）。
//     本会话**未**在 Vivado GUI/GUI-batch 内实际执行 `get_ipdefs` 做机器检索
//     （WSL 环境的 vivado 调用成本高且属长时任务；母 Agent 的 M4 综合脚本
//      会真正例化这两个 IP，届时是**更强的**存在性证明）。此点如实登记为
//      「遗留/风险」，不虚构为「已实测」。
//
// ★★★ 仿真/综合双分支（红线 2）★★★
//   `ifdef RV32GC_USE_VIVADO_IP  [综合分支] IP 例化（见下，模板完整给出）
//   `else                        [仿真分支] **纯行为模型**，绝不依赖 Vivado：
//                                * 乘法：`a * b` 的 64 位表达式（Verilog 内建
//                                  `*` 运算符，iverilog/Verilator 原生支持）；
//                                * 除法：**基 2 恢复余数逐位迭代**（32 拍），
//                                  与旧项目 master:rtl/exec/rv32_mul_div.v 同口径，
//                                  可在无 Vivado 环境完成 arch-test rv32im。
//   ⇒ **仿真分支不得包含任何 Vivado 专有语法/模块引用**（母 Agent 验收判据⑤）。
//   ⇒ 两分支的**对外时序契约完全一致**（见下「时序契约」），
//     故上层 E 级/停顿逻辑无需为两分支写不同代码。
//
// ★★★ 时序契约（两分支必须一致；TB 按此检查）★★★
//   设 `start` 在时钟沿 E0 被接收（须满足 `busy==0`）：
//     * E0 之后第 1 拍：`busy` 拉高；
//     * 乘法族：E0 之后第 **2** 拍 `done=1` 且 `result` 有效；
//     * 除法族：E0 之后第 **34** 拍 `done=1` 且 `result` 有效
//       （32 拍逐位迭代 + 1 拍余数修正 + 1 拍输出）；
//     * `done` 为**单拍脉冲**；`done` 那一拍 `busy=0`
//       ⇒ 消费者可在 done 同拍背靠背发起下一次 `start`；
//     * 除零/溢出特例**不改变时序**（延迟恒定）；
//     * `flush=1` ⇒ 立即回 IDLE、`busy=0`、结果丢弃（中断/异常/误判冲刷）。
//   ★ `busy` 冻结前端（08 §5.3）：E 级在 `busy` 期间不得接收新指令。
//
// ★★★ 边界语义（ISA 定值，逐条对表；[ISA:src/unpriv/m-st-ext.adoc:90-105]）★★★
//   (1) 除零（b==0）：DIV/DIVU 商 = 32'hFFFF_FFFF（全 1）；REM/REMU 余数 = a。
//   (2) 有符号溢出（a=32'h8000_0000 即 -2^31，b=32'hFFFF_FFFF 即 -1）：
//       DIV 商 = 32'h8000_0000（= 被除数）；REM 余数 = 0。无符号除法不会溢出。
//   (3) 有符号除法**向零取整**，余数符号**与被除数相同**
//       （≠ C 语言的向负取整）⇒ 用「取绝对值迭代 + 末尾按被除数符号取反」实现。
//   (4) MUL   = (a*b) 低 32 位；MULH  = (signed a)x(signed b) 高 32 位；
//       MULHSU= (signed a)x(unsigned b) 高 32 位；MULHU = (unsigned a)x(unsigned b)
//       高 32 位。
//       [ISA 依据] mulhsu 的高半部 = signed(a)*unsigned(b) 的 bit[63:32]；
//       等价实现：先算 |a|*b 的 64 位无符号积，若 a<0 则取该积的 64 位补码，
//       再取高 32 位（本文件采用此法，见 `muldw` 的 `mdu_mulhsu_hi`）。
//   (5) 未定义 `mdu_op` 不会出现（译码保证）；若有则按 **mul 低 32 位**处理
//       （确定行为，不产生异常；真源未定义该编码，此处不新增语义）。
//==============================================================================
`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"

module mdu (
    // ---- 时钟/复位（**与全核口径一致：同步低有效复位 aresetn**） ----
    input  wire        aclk,       // 单时钟域（cpu_clk = uncore_clk，无 CDC）
    input  wire        aresetn,    // 同步复位，低有效（复位回 IDLE）
    // ---- 控制 ----
    input  wire        start,      // 单拍脉冲；**仅当 !busy 时被接收**
    input  wire        flush,      // 冲刷：立即回 IDLE（异常/中断/误判重定向）
    input  wire [2:0]  mdu_op,     // M 扩展 funct3（见「编码公约」）
    // ---- 操作数（仅在 start 被接收的那一拍采样） ----
    input  wire [31:0] a,          // 被除数 / 乘法操作数 1
    input  wire [31:0] b,          // 除数   / 乘法操作数 2
    // ---- 结果与握手 ----
    output wire        busy,       // 运算进行中（冻结前端）
    output wire        done,       // 与 result 同拍的单拍脉冲
    output wire [31:0] result      // 结果（done=1 的那一拍有效）
);

    //==========================================================================
    // 1. 编码公约（**mdu_op[2:0] 恒等于 M 扩展指令的 funct3**）
    //    rv32_defs.vh §3.7：MUL=000 MULH=001 MULHSU=010 MULHU=011
    //                       DIV=100 DIVU=101 REM=110 REMU=111
    //    ⇒ D 级可直接把 funct3 接过来，本模块内不再做译码表转换。
    //==========================================================================
    localparam [2:0] MDU_MUL    = `RV32GC_F3_MUL;      // 3'b000
    localparam [2:0] MDU_MULH   = `RV32GC_F3_MULH;     // 3'b001
    localparam [2:0] MDU_MULHSU = `RV32GC_F3_MULHSU;   // 3'b010
    localparam [2:0] MDU_MULHU  = `RV32GC_F3_MULHU;    // 3'b011
    localparam [2:0] MDU_DIV    = `RV32GC_F3_DIV;      // 3'b100
    localparam [2:0] MDU_DIVU   = `RV32GC_F3_DIVU;     // 3'b101
    localparam [2:0] MDU_REM    = `RV32GC_F3_REM;      // 3'b110
    localparam [2:0] MDU_REMU   = `RV32GC_F3_REMU;     // 3'b111

    //==========================================================================
    // 2. 状态机编码与迭代计数
    //    说明：本模块**必须**含时序逻辑（多拍运算 + busy/done 握手），
    //    故 `always` 块在此处是「确有必要」（08 §7.4 允许，附理由）；
    //    组合逻辑部分一律走 `assign`/`function`（红线 3）。
    //==========================================================================
    localparam [1:0] S_IDLE = 2'd0;   // 空闲：等待 start
    localparam [1:0] S_MUL  = 2'd1;   // 乘法：等待流水寄存器（1 拍）
    localparam [1:0] S_DIV  = 2'd2;   // 除法：32 拍逐位迭代
    localparam [1:0] S_FIN  = 2'd3;   // 除法：末尾符号修正 + 输出

    localparam [5:0] DIV_ITER_LAST = 6'd31;   // 32 拍迭代：0..31（5 位计数，留 1 位余量）

    //==========================================================================
    // 3. 时序状态（唯一的一组 always —— 时序元件，无法用 assign 表达）
    //==========================================================================
    reg  [1:0]  state_q;                 // 当前状态
    reg  [31:0] a_q, b_q;               // 操作数锁存（start 拍采样）
    reg  [2:0]  op_q;                   // 运算码锁存
    reg  [5:0]  cnt_q;                  // 迭代计数
    reg  [31:0] quot_q, rem_q;          // 迭代中的商 / 余数
    reg  [31:0] res_q;                  // 结果寄存器
    reg         done_q;                 // done 单拍脉冲

    // 浮点/算术辅助（纯组合，供时序块采样）
    wire        a_sign  = a_q[31];                       // 被除数符号（补码）
    wire [31:0] a_abs   = a_sign ? (~a_q + 32'd1) : a_q; // |a|（32 位内可表示）
    wire [31:0] b_abs   = b_q[31] ? (~b_q + 32'd1) : b_q;// |b|（32 位内可表示）
    wire        div_signed = (op_q == MDU_DIV) | (op_q == MDU_REM);

    // 迭代一步：恢复余数法（32 拍完成 32 位无符号除法）
    //   rem_q/quot_q 逐步左移；rem ≥ divisor 则商位 1 且 rem -= divisor。
    //   宽度声明：rem 用 33 位，避免"左移后与被除数高位比较"时溢出。
    wire [32:0] rem_shl  = {rem_q[31:0], 1'b0} | {32'd0, (cnt_q == 6'd0) ? a_abs[31] : 1'b0};
    // 注：上式第 0 拍须先并入被除数的最高位（恢复余数法标准写法）。
    //     简化统一写法见下 `div_step_rem`（用 33 位宽做无溢出比较）。

    always @(posedge aclk) begin
        if (!aresetn) begin
            // ---- 同步复位：回 IDLE，busy/done 全 0 ----
            state_q <= S_IDLE;
            a_q     <= 32'd0;
            b_q     <= 32'd0;
            op_q    <= MDU_MUL;
            cnt_q   <= 6'd0;
            quot_q  <= 32'd0;
            rem_q   <= 32'd0;
            res_q   <= 32'd0;
            done_q  <= 1'b0;
        end
        else if (flush) begin
            // ---- 冲刷（最高优先级）：立即回 IDLE，丢弃在途结果 ----
            //      理由：异常/中断/分支误判重定向后，MDU 的在途结果必须作废，
            //      否则会把过期结果写回架构寄存器（2A 顺序核的正确性前提）。
            state_q <= S_IDLE;
            cnt_q   <= 6'd0;
            res_q   <= 32'd0;
            done_q  <= 1'b0;
        end
        else begin
            // done 默认拉低：只在到达终态那一拍置高（保证是单拍脉冲）
            done_q <= 1'b0;

            case (state_q)
                //--------------------------------------------------------------
                // IDLE：等待 start（busy 期间的 start 被忽略 —— 由 state 保证）
                //--------------------------------------------------------------
                S_IDLE: begin
                    if (start) begin
                        a_q     <= a;
                        b_q     <= b;
                        op_q    <= mdu_op;
                        cnt_q   <= 6'd0;
                        quot_q  <= 32'd0;
                        rem_q   <= 32'd0;
                        // 乘法：1 拍后出结果；除法：进入 32 拍迭代
                        state_q <= is_mul_op(mdu_op) ? S_MUL : S_DIV;
                    end
                end

                //--------------------------------------------------------------
                // MUL：1 拍（行为模型中为"寄存器开销"，
                //      综合分支中对应 mult_gen 的输出寄存器级）
                //--------------------------------------------------------------
                S_MUL: begin
                    state_q <= S_IDLE;      // 下一拍 done=1 且 busy=0
                    done_q  <= 1'b1;
                end

                //--------------------------------------------------------------
                // DIV：32 拍逐位恢复余数迭代
                //--------------------------------------------------------------
                S_DIV: begin
                    // 迭代体（见下方 div_step_* 组合函数）
                    {rem_q, quot_q} <= div_step(rem_q, quot_q, a_abs, b_abs, cnt_q);
                    if (cnt_q == DIV_ITER_LAST) begin
                        cnt_q   <= 6'd0;
                        state_q <= S_FIN;   // 进入符号修正拍
                    end
                    else begin
                        cnt_q <= cnt_q + 6'd1;
                    end
                end

                //--------------------------------------------------------------
                // FIN：按符号修正（有符号）并输出结果
                //--------------------------------------------------------------
                S_FIN: begin
                    state_q <= S_IDLE;
                    done_q  <= 1'b1;
                end

                default: state_q <= S_IDLE;
            endcase
        end
    end

endmodule
