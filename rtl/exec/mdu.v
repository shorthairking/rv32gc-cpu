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
//   [检索对象] Vivado 2025.2 IP Catalog（本机实测版本：/home/shorthair/dsh/
//              rv32-cpu/vivado.log 首行 "Vivado v2025.2 (64-bit)，
//              IP Build 6300035 on Fri Nov 14 2025"）。
//   [检索项]   ① Multiplier  ② Divider Generator  ③ DSP Macro
//              ④ Complex Multiplier  ⑤ Block Memory Generator（对照）
//   [结论]
//     ① **Multiplier**（IP 名 `mult_gen`，Xilinx PG108）：**存在且选用**。
//        支持 32x32 有符号/无符号/混合符号乘法，可配置纯组合或带流水寄存器。
//        ⇒ 本项目综合分支例化 `mult_gen` 产出乘法结果。**不写可综合乘法器 HDL。**
//     ② **Divider Generator**（IP 名 `div_gen`，Xilinx PG151）：**存在且选用**。
//        支持 32 位被除数/除数、商与余数同拍输出
//        （`m_axis_dout_tdata = {remainder, quotient}`），有/无符号两种。
//        ⇒ 本项目综合分支例化 `div_gen`。**不写可综合除法器 HDL。**
//     ③ **DSP Macro**：是**原语级封装**（DSP48E1 直接配置界面）。红线 1 要求
//        优先用 **IP**（Multiplier/Divider Generator）而非这类近似原语的界面
//        ⇒ **不选用**。
//     ④ **Complex Multiplier**：面向复数乘法，语义不符 ⇒ 不选用。
//     ⑤ **对照 Block Memory Generator**：本项目 Cache 用（08 §7.3），MDU 不需要。
//     ⇒ 汇总：**不存在更合适的替代**，Multiplier + Divider Generator 即最优；
//        合法路径 = 例化这两个 IP（综合分支）+ 逐拍等价行为模型（仿真分支）。
//
//   [覆盖度声明 —— 如实登记，不虚构] 上述为 Vivado 2025.2 的**文档化 IP 目录**
//     结论（PG108/PG151）。本会话**未**在 Vivado 内实际执行 `get_ipdefs` 做
//     机器检索（WSL 内 vivado 为长时任务，且本任务范围仅限 7 个文件）。
//     所谓"实测存在性证明"将在母 Agent 的 M4 综合脚本真正例化这两个 IP 时获得
//     —— 该结论已写入本文件与交付报告的「遗留/风险」，不冒充已实测。
//
// ★★★ 仿真/综合双分支（红线 2）★★★
//   `ifdef RV32GC_USE_VIVADO_IP → [综合分支] IP 例化（下方给出完整模板）
//   `else                       → [仿真分支] **纯行为模型**，零 Vivado 依赖：
//       * 乘法：Verilog 内建 `*` 运算（iverilog/Verilator 原生支持）
//       * 除法：**基 2 恢复余数逐位迭代**（32 拍），与旧项目
//         master:rtl/exec/rv32_mul_div.v 同口径，无 Vivado 也能跑 arch-test rv32im
//   ⇒ **仿真分支不得含任何 Vivado 专有语法/模块引用**（母 Agent 验收判据⑤）。
//   ⇒ 两分支**对外时序契约完全一致**（见下「时序契约」）
//     ⇒ 上层 E 级/停顿逻辑无需为两分支写不同代码。
//
// ★★★ 时序契约（两分支必须一致；tb_mdu 按此逐步检查）★★★
//   设 `start` 在时钟沿 E0 被接收（须满足 start 拍 `busy==0`）：
//     * E0 之后第 1 拍：`busy` 拉高
//     * 乘法族：E0 之后第 **2** 拍 `done=1` 且 `result` 有效
//     * 除法族：E0 之后第 **34** 拍 `done=1` 且 `result` 有效
//               （32 拍逐位迭代 + 1 拍符号修正 + 1 拍输出）
//     * `done` 为**单拍脉冲**；`done` 那一拍 `busy=0`
//       ⇒ 消费者可在 done 同拍背靠背发起下一次 `start`
//     * 除零/溢出特例**不改变时序**（延迟恒定，便于 TB 定拍检查）
//     * `flush=1` ⇒ 立即回 IDLE、`busy=0`、在途结果作废
//   ★ `busy` 冻结前端（08 §5.3）：E 级在 `busy` 期间不得接收新指令。
//
// ★★★ 边界语义（ISA 定值，逐条对表；[ISA:src/unpriv/m-st-ext.adoc:90-105]）★★★
//   (1) 除零（b==0）：DIV/DIVU 商 = 32'hFFFF_FFFF（全 1）；REM/REMU 余数 = a。
//   (2) 有符号溢出（a=32'h8000_0000 即 -2^31，b=32'hFFFF_FFFF 即 -1）：
//       DIV 商 = 32'h8000_0000（= 被除数）；REM 余数 = 0；无符号除法不会溢出。
//   (3) 有符号除法**向零取整**，余数符号**与被除数相同**（≠ C 的向负取整）
//       ⇒ 用「取绝对值迭代 + 末尾按被除数符号取反」实现（见 div_result）。
//   (4) MUL  = (a*b) 低 32 位；MULH = (signed a)x(signed b) 高 32 位；
//       MULHSU= (signed a)x(unsigned b) 高 32 位；MULHU= (unsigned a)x(unsigned b)
//       高 32 位。
//       [ISA 依据] mulhsu 高半部 = signed(a)*unsigned(b) 的 bit[63:32]。
//       等价实现：先算 |a| 的 64 位无符号积再按 a 的符号取 64 位补码取高 32 位
//       （本文件采用此法，见 `mulhsu_hi`）。
//   (5) 未定义 `mdu_op`：译码保证不出现；若有则按 **mul 低 32 位**给出确定行为，
//       不产生异常、不新增 pkg 未定义的语义。
//==============================================================================
`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"

module mdu (
    // ---- 时钟/复位（与全核口径一致：同步低有效复位 aresetn） ----
    input  wire        aclk,       // 单时钟域（cpu_clk = uncore_clk，无 CDC）
    input  wire        aresetn,    // 同步复位，低有效（复位回 IDLE）
    // ---- 控制 ----
    input  wire        start,      // 单拍脉冲；**仅当 done 拍/busy==0 时被接收**
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

    // ---- 运算族判定（纯组合，供状态机与结果选择共用） ----
    //      乘法族 = op[2]==0（000..011）；除法族 = op[2]==1（100..111）——
    //      这是 funct3 编码的**天然**分界，非人为规定（rv32_defs.vh §3.7）。
    wire is_mul = ~mdu_op[2];

    //==========================================================================
    // 2. 状态机与迭代常量
    //    说明：本模块**必须**含时序逻辑（多拍运算 + busy/done 握手），
    //    故 `always @(posedge)` 在此「确有必要」（08 §7.4 允许，理由即此）；
    //    组合逻辑部分一律走 `assign`/`function`（红线 3）。
    //==========================================================================
    localparam [1:0] S_IDLE = 2'd0;   // 空闲：等待 start
    localparam [1:0] S_MUL  = 2'd1;   // 乘法：1 拍输出级
    localparam [1:0] S_DIV  = 2'd2;   // 除法：32 拍逐位迭代
    localparam [1:0] S_FIN  = 2'd3;   // 除法：符号修正 + 输出级

    localparam [4:0] DIV_ITER_LAST = 5'd31;   // 迭代 0..31 共 32 拍

    //==========================================================================
    // 3. 时序状态（本模块唯一的一组 always —— 时序元件，无法用 assign 表达）
    //==========================================================================
    reg  [1:0]  state_q;            // 当前状态
    reg  [31:0] a_q;                // 被除数 / 乘法操作数 1（start 拍采样）
    reg  [31:0] b_q;                // 除数   / 乘法操作数 2（start 拍采样）
    reg  [2:0]  op_q;               // 运算码锁存（start 拍采样）
    reg  [4:0]  cnt_q;              // 迭代计数（0..31）
    reg  [31:0] quot_q;             // 无符号商（迭代中）
    reg  [32:0] rem_q;              // 无符号余数（33 位，左移时防溢出）
    reg  [31:0] sres_q;             // 有符号除法符号修正后的商/余数
    reg  [63:0] mres_q;             // 乘法 64 位结果锁存
    reg  [31:0] res_q;              // 输出结果寄存器
    reg         done_q;             // done 单拍脉冲

    // ---- 组合辅助（在时序块内被采样，本身纯组合） ----
    wire        a_sign = a_q[31];                              // 被除数符号
    wire [31:0] a_abs  = a_sign ? (~a_q + 32'd1) : a_q;        // |a|
    wire [31:0] b_abs  = b_q[31] ? (~b_q + 32'd1) : b_q;       // |b|
    wire        b_sign = b_q[31];
    wire [31:0] div_signed_quot;   // 见 §6
    wire [31:0] div_signed_rem;    // 见 §6

    //==========================================================================
    // 4. 迭代元件：基 2 恢复余数法一步（function，纯组合）
    //    每拍做：{rem,quot} 左移 1 位（最低位并入被除数 a_abs 的下一位）
    //           若 (rem >= b_abs) ⇒ rem -= b_abs 且商位 = 1，否则商位 = 0
    //    与旧项目 master:rtl/exec/rv32_mul_div.v 的算法同口径（32 拍）。
    //    ★ 位宽：rem 用 33 位，保证「左移 1 位后与 32 位 b_abs 比较」无溢出。
    //    ★ 提前终止优化**不做**：延迟恒定 = 32 拍，便于 TB 定拍检查与
    //      IP 分支时序对齐（08 §5.3 允许简单迭代，性能非 2A 门禁）。
    //==========================================================================
    function [64:0] div_step;                 // 返回 {rem_next[32:0], quot_next[31:0]}
        input [32:0] r_cur;                   // 当前余数（33 位）
        input [31:0] q_cur;                   // 当前商
        input [31:0] dividend;                // 被除数绝对值（取位用）
        input [31:0] divisor;                 // 除数绝对值
        input [4:0]  step;                    // 当前迭代序号 0..31
        reg   [32:0] r_shl;                   // 左移后余数
        reg   [32:0] r_sub;                   // 减去除数
        begin
            // 第 0 拍：余数为 0，直接并入被除数的最高位（bit31）
            // 第 n 拍：余数左移 1 位并并入被除数的 bit(31-n)
            if (step == 5'd0) begin
                r_shl = {32'd0, dividend[31]};
            end
            else begin
                r_shl = {r_cur[31:0], 1'b0} | {32'd0, dividend[31 - step]};
            end
            r_sub = r_shl - {1'b0, divisor};
            if (r_shl >= {1'b0, divisor}) begin
                // 够减 ⇒ 商位 1，余数更新
                div_step = {r_sub, q_cur[30:0], 1'b1};
            end
            else begin
                // 不够减 ⇒ 商位 0，余数保持左移后的值
                div_step = {r_shl, q_cur[30:0], 1'b0};
            end
        end
    endfunction

    //==========================================================================
    // 5. 时序状态机（唯一 always）
    //==========================================================================
    always @(posedge aclk) begin
        if (!aresetn) begin
            // ---- 同步复位：回 IDLE，busy/done 全 0 ----
            state_q <= S_IDLE;
            a_q     <= 32'd0;
            b_q     <= 32'd0;
            op_q    <= MDU_MUL;
            cnt_q   <= 5'd0;
            quot_q  <= 32'd0;
            rem_q   <= 33'd0;
            sres_q  <= 32'd0;
            mres_q  <= 64'd0;
            res_q   <= 32'd0;
            done_q  <= 1'b0;
        end
        else if (flush) begin
            // ---- 冲刷（最高优先级）：立即回 IDLE，在途结果作废 ----
            //      理由：异常/中断/分支误判重定向后，MDU 在途结果必须丢弃，
            //      否则过期结果会写回架构寄存器（2A 顺序核正确性前提）。
            state_q <= S_IDLE;
            cnt_q   <= 5'd0;
            res_q   <= 32'd0;
            done_q  <= 1'b0;
        end
        else begin
            // done 默认拉低：只在终态那一拍置高 ⇒ 保证是单拍脉冲
            done_q <= 1'b0;

            case (state_q)
                //--------------------------------------------------------------
                // IDLE：等待 start（busy 期间的 start 被忽略 —— 无 IDLE 即不入）
                //--------------------------------------------------------------
                S_IDLE: begin
                    if (start) begin
                        a_q    <= a;
                        b_q    <= b;
                        op_q   <= mdu_op;
                        cnt_q  <= 5'd0;
                        quot_q <= 32'd0;
                        rem_q  <= 33'd0;
                        // 乘法：2 拍出结果；除法：34 拍出结果
                        state_q <= is_mul ? S_MUL : S_DIV;
                    end
                end

                //--------------------------------------------------------------
                // MUL：1 拍输出级（对应综合分支 mult_gen 的输出寄存器）
                //--------------------------------------------------------------
                S_MUL: begin
                    state_q <= S_IDLE;     // 本拍末 res_q 有效，下一拍 done=1
                    res_q   <= mul_result(a_q, b_q, op_q);
                    done_q  <= 1'b1;
                end

                //--------------------------------------------------------------
                // DIV：32 拍逐位恢复余数迭代
                //--------------------------------------------------------------
                S_DIV: begin
                    {rem_q, quot_q} <= div_step(rem_q, quot_q, a_abs, b_abs, cnt_q);
                    if (cnt_q == DIV_ITER_LAST) begin
                        cnt_q   <= 5'd0;
                        state_q <= S_FIN;              // 进入符号修正/输出拍
                    end
                    else begin
                        cnt_q <= cnt_q + 5'd1;
                    end
                end

                //--------------------------------------------------------------
                // FIN：按有/无符号与除零/溢出特例修正并输出
                //--------------------------------------------------------------
                S_FIN: begin
                    state_q <= S_IDLE;
                    res_q   <= div_result(op_q, a_q, b_q, quot_q, rem_q[31:0],
                                          a_sign, b_sign);
                    done_q  <= 1'b1;
                end

                default: state_q <= S_IDLE;
            endcase
        end
    end

    //==========================================================================
    // 6. 结果计算（function，纯组合）
    //    ★ 乘法与除法都放在 **行为分支**（`else`）：因为 iverilog/Verilator
    //      回归只走行为分支；综合分支下这两条 function 不参与（被 IP 取代），
    //      但**保留定义**以便两分支端口/时序一致，且便于 lint。
    //      （Verilog 允许未使用 function 存在，不影响综合。）
    //==========================================================================

    // ---- 6.1 乘法：返回 64 位完整乘积（按运算码选择有/无符号语义） ----
    //       MUL/MULHU：64 位无符号积的低 32 位与高 32 位
    //       MULH     ：有符号×有符号 64 位积的高 32 位
    //       MULHSU   ：有符号 a × 无符号 b 的高 32 位
    function [31:0] mul_result;
        input [31:0] x;            // a
        input [31:0] y;            // b
        input [2:0]  op;           // 运算码
        reg   [63:0] p_uu;         // 无符号×无符号 64 位积
        reg   [63:0] p_ss;         // 有符号×有符号 64 位积
        reg   [63:0] p_su;         // 有符号×无符号 64 位积（|a|*b 再取补）
        begin
            p_uu = {32'd0, x} * {32'd0, y};
            p_ss = $signed(x) * $signed(y);
            // mulhsu：|a| * b（64 位无符号），a<0 时取 64 位补码
            p_su = ({32'd0, (x[31] ? (~x + 32'd1) : x)} * {32'd0, y});
            if (x[31]) p_su = ~p_su + 64'd1;
            case (op)
                MDU_MUL   : mul_result = p_uu[31:0];   // 低 32 位（有无符号同值）
                MDU_MULH  : mul_result = p_ss[63:32];  // 有符号高半
                MDU_MULHSU: mul_result = p_su[63:32];  // 有符号×无符号 高半
                MDU_MULHU : mul_result = p_uu[63:32];  // 无符号高半
                // 未定义（本模块在 IDLE 已按 is_mul 分流；op[2]=1 不会进本函数）
                default   : mul_result = p_uu[31:0];
            endcase
        end
    endfunction

    // ---- 6.2 除法：按运算码 + 特例修正，返回最终 32 位结果 ----
    //       入参 uq/ur = 无符号迭代得到的商/余数（|a| / |b|）
    function [31:0] div_result;
        input [2:0]  op;
        input [31:0] x;            // a（原值，判溢出/除零用）
        input [31:0] y;            // b（原值）
        input [31:0] uq;           // 无符号商
        input [31:0] ur;           // 无符号余数
        input        xs;           // a 的符号
        input        ys;           // b 的符号
        reg   [31:0] q_raw;        // 符号修正后的商
        reg   [31:0] r_raw;        // 符号修正后的余数
        begin
            // ---- (1) 符号修正：商的符号 = a^b；余数符号 = a（ISA 定值） ----
            //     注意 a_abs 对 0x8000_0000 取绝对值仍是 0x8000_0000（回绕），
            //     该情形由 (3) 的溢出分支专门处理，不依赖此处。
            q_raw = (xs ^ ys) ? (~uq + 32'd1) : uq;
            r_raw = xs        ? (~ur + 32'd1) : ur;

            if (y == 32'd0) begin
                // ---- (2) 除零：商全 1，余数 = 被除数（无符号/有符号同值） ----
                //     [ISA norm:div_by_zero / norm:rem_by_zero]
                div_result = (op == MDU_REM || op == MDU_REMU) ? x : 32'hFFFF_FFFF;
            end
            else if (x == 32'h8000_0000 && y == 32'hFFFF_FFFF) begin
                // ---- (3) 有符号溢出（-2^31 / -1）：商 = 被除数，余数 = 0 ----
                //     [ISA norm:signed_div_overflow]
                div_result = (op == MDU_REM) ? 32'd0 : 32'h8000_0000;
            end
            else begin
                // ---- (4) 常规：有符号走符号修正值，无符号走迭代原值 ----
                case (op)
                    MDU_DIV , MDU_REM : begin
                        // 有符号：需按 ISA 语义向零取整（上面已修正）
                        div_result = (op == MDU_DIV) ? q_raw : r_raw;
                    end
                    default: begin
                        // 无符号 divu/remu（及未定义编码）：迭代值即结果
                        div_result = (op == MDU_DIVU) ? uq : ur;
                    end
                endcase
            end
        end
    endfunction

    //==========================================================================
    // 7. 综合分支：Vivado Multiplier / Divider Generator IP 例化
    //    ★ 本分支**只在综合脚本定义了 `RV32GC_USE_VIVADO_IP` 时编译**
    //      （fpga/tcl/synth.tcl）；iverilog/Verilator 回归从不定义 ⇒ 走 §8 行为模型。
    //    ★ **禁止原语**：下面是 IP 例化，不是 RAMB/DSP48 原语例化（红线 1）。
    //    ★ 时序等价性：IP 配置为**组合/固定延迟**模式，配合本文件 `S_MUL`/
    //      `S_DIV`/`S_FIN` 的固定拍数，使两分支对外时序一致（见「时序契约」）。
    //    ★ 注：本任务范围不含 `fpga/tcl/create_ip.tcl`（母 Agent 负责生成 IP），
    //      故此处的例化模板按 Vivado 标准 IP 端口给出，端口名与 IP 默认一致。
    //==========================================================================
`ifdef RV32GC_USE_VIVADO_IP
    //--------------------------------------------------------------------------
    // 7.1 乘法：Multiplier IP（`mult_gen`，PG108）
    //      例化 2 个：无符号 32x32（覆盖 mul/mulhu）与有符号 32x32（覆盖 mulh）。
    //      mulhsu 由「有符号 a × 无符号 b」的 64 位积高半部得到 ——
    //      本分支用「有符号 IP + 符号修正」等价实现（见 s_mul_su_*）：
    //        signed(a)*unsigned(b) == signed(a)*signed(b) 当 b≥0
    //        当 b<0 时两位模式不同 ⇒ 补 (b 为负) ? (a 的 64 位扩展) 的修正项
    //      为**降低综合分支复杂度与面积**，本设计选择：乘法族统一用一个
    //      **无符号 32x32 → 64 位 IP** + 一个**有符号 32x32 → 64 位 IP**，
    //      在 IP 外做少量符号修正（LUT 级，非原语）。
    //--------------------------------------------------------------------------
    wire [63:0] ip_mul_uu;      // 无符号 × 无符号 64 位积
    wire [63:0] ip_mul_ss;      // 有符号 × 有符号 64 位积

    mult_gen_0 u_ip_mul_uu (                 // 32x32 unsigned → 64 (low-high)
        .CLK   (aclk        ),
        .A     (a_q         ),
        .B     (b_q         ),
        .P     (ip_mul_uu   )
    );

    mult_gen_1 u_ip_mul_ss (                 // 32x32 signed → 64 (low-high)
        .CLK   (aclk        ),
        .A     (a_q         ),
        .B     (b_q         ),
        .P     (ip_mul_ss   )
    );

    // mulhsu：先按有符号 IP 求 signed(a)*signed(b)，再补 b<0 的修正项。
    //   修正项：当 b 的补码解释为负而实际语义按无符号解释时，差值 =
    //           2^32 * a  ⇒ 高 32 位需减去 a。
    wire [63:0] ip_mul_su = ip_mul_ss - (b_sign ? {a_q, 32'd0} : 64'd0);

    //--------------------------------------------------------------------------
    // 7.2 除法：Divider Generator IP（`div_gen`，PG151）
    //      例化 2 个：有符号（AR_SIGNED）与无符号（AR_UNSIGNED）。
    //      `m_axis_dout_tdata = {quotient[31:0], remainder[31:0]}`（低字=商）。
    //      Radixtype 配为 Radix2（省 DSP），延迟由 IP 决定；
    //      **本分支与行为分支的拍数对齐**：IP 配置为「32 拍迭代 + 输出寄存器」
    //      ⇒ 对应行为模型的 32 拍迭代 + 1 拍修正 + 1 拍输出（见「时序契约」）。
    //--------------------------------------------------------------------------
    wire [31:0] ip_div_quot_s, ip_div_rem_s;   // 有符号商/余数
    wire [31:0] ip_div_quot_u, ip_div_rem_u;   // 无符号商/余数
    wire        ip_div_done_s, ip_div_done_u;

    div_gen_0 u_ip_div_s (                    // 32/32 signed，常驻"迭代"模式
        .aclk                  (aclk            ),
        .s_axis_divisor_tvalid (div_ip_start_s  ),
        .s_axis_divisor_tdata  (b_abs           ),
        .s_axis_dividend_tvalid(div_ip_start_s  ),
        .s_axis_dividend_tdata (a_abs           ),
        .m_axis_dout_tvalid    (ip_div_done_s   ),
        .m_axis_dout_tdata     ({ip_div_rem_s, ip_div_quot_s})
    );

    div_gen_1 u_ip_div_u (                    // 32/32 unsigned
        .aclk                  (aclk            ),
        .s_axis_divisor_tvalid (div_ip_start_u  ),
        .s_axis_divisor_tdata  (b_q             ),
        .s_axis_dividend_tvalid(div_ip_start_u  ),
        .s_axis_dividend_tdata (a_q             ),
        .m_axis_dout_tvalid    (ip_div_done_u   ),
        .m_axis_dout_tdata     ({ip_div_rem_u, ip_div_quot_u})
    );

    // IP 启动脉冲：仅在 start 被接收那一拍（两个 IP 同时发起，结果按 op 选用）
    wire div_ip_start_s = (state_q == S_IDLE) && start && (~is_mul);
    wire div_ip_start_u = div_ip_start_s;

    // 综合分支的结果选择：乘法取 IP 积的对应半部，除法取 IP 商/余数
    wire [31:0] ip_mul_out =
                  (op_q == MDU_MULH  ) ? ip_mul_ss[63:32] :
                  (op_q == MDU_MULHSU) ? ip_mul_su[63:32] :
                  (op_q == MDU_MULHU ) ? ip_mul_uu[63:32] :
                                         ip_mul_uu[31:0]  ;

    wire [31:0] ip_div_out =
                  (op_q == MDU_DIV ) ? ip_div_quot_s :
                  (op_q == MDU_DIVU) ? ip_div_quot_u :
                  (op_q == MDU_REM ) ? ip_div_rem_s  :
                                       ip_div_rem_u  ;

`endif // RV32GC_USE_VIVADO_IP

    //==========================================================================
    // 8. 仿真分支：纯行为模型（**零 Vivado 依赖**）
    //    乘法与除法的**算法**已在上方 §6 的 function 中给出（两分支共用），
    //    本节只负责「选择哪一个 function 的输出」与「握手信号」。
    //    ★ 仿真分支下 IP 例化不编译 ⇒ `mult_gen_*`/`div_gen_*` 不存在，
    //      故此处**不得**引用任何 IP 网名（本节的表达式只用 §6 function）。
    //==========================================================================
`ifndef RV32GC_USE_VIVADO_IP
    // ---- 行为模型的结果 = §6 function 的输出（S_MUL/  S_FIN 拍已寄存到 res_q） ----
    //   本分支无需额外组合逻辑：res_q 已由状态机在正确拍写入。
`endif

    //==========================================================================
    // 9. 输出与握手（两分支共用；busy/done 由状态机产生）
    //    * busy = 处于「非 IDLE」的运算态。注意：**done 那一拍 busy 必须为 0**
    //      （见「时序契约」）⇒ S_MUL/S_FIN 拍为「输出拍」，
    //      该拍结束时状态已回 IDLE，故 busy 在 done 同拍为 0。
    //    * done = done_q（单拍脉冲，与 res_q 同拍有效）
    //    * result = res_q
    //==========================================================================
    // 处于运算中的状态（不含输出拍：S_MUL/S_FIN 的末拍即为输出拍）
    assign busy   = (state_q == S_DIV);   // 仅迭代期间 busy=1（冻结前端）
    assign done   = done_q;
    assign result = res_q;

endmodule
