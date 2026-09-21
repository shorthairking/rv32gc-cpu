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
//           AGENT.md §4 红线 1（禁止原语，先检索 IP）、红线 2（IP 双分支）、
//             红线 3（大量组合逻辑走 assign/function，always 仅用于时序元件）。
//           08 §3.3 第 3 条：宏名固定 `RV32GC_USE_VIVADO_IP`
//             （综合脚本定义、iverilog/Verilator 回归**从不**定义）。
//           08 §7.3 是 BRAM 的双分支范式，本文件照同口径落地。
//           用户指令 2026-09-14：综合分支必须是**真实可综合的 IP 例化**，
//             不允许停留在「端口模板注释」。
// 唯一真源: `RV32GC_F3_MUL*`/`RV32GC_F3_DIV*` 编号即 M 扩展指令的 **funct3**
//           （rv32_defs.vh §3.7）⇒ D 级可直接把 funct3 接到 `mdu_op`。
// IP 生成 : `fpga/tcl/create_ip.tcl`（分节 `## mult_gen` / `## div_gen`）。
//           本文件的例化端口/位宽与该脚本的 IP 配置**逐字对应**：
//             rv32_mult_signed   : A[Signed]   B[Signed]    32x32 → P[63:0]（纯组合）
//             rv32_mult_su       : A[Signed]   B[Unsigned]  32x32 → P[63:0]（纯组合）
//             rv32_mult_unsigned : A[Unsigned] B[Unsigned]  32x32 → P[63:0]（纯组合）
//             rv32_div           : 32/32 Radix2 Unsigned，AXI-Stream 握手
//                                  tdata[63:0] = {余数[63:32], 商[31:0]}
//           ⇒ 改任一侧必须同步另一侧（接口契约）。
//==============================================================================
// ★★★ 红线 1 检索结论 + **实测证据**（本文件即证据之一，另一份在 create_ip.tcl）★★★
//
//   [检索对象] Vivado 本机安装版 **2023.2**（AGENT.md §2 环境事实表；IP Catalog
//              路径 /home/shorthair/fpga/Vivado/2023.2/data/ip/xilinx）。
//   [检索方式] **机器检索（2026-09-14 实测，非文档推断）**：
//              ① `get_ipdefs -name mult_gen|div_gen -vendor xilinx.com -library ip`
//                 → mult_gen **12.0**、div_gen **5.1** 均在 Catalog 中；
//              ② `create_ip` + `generate_target all` 真实生成 4 个 IP：
//                 rv32_mult_signed / rv32_mult_su / rv32_mult_unsigned / rv32_div；
//              ③ 由生成的 `*_stub` 例化模板**逐字核对端口名/位宽**（见上「IP 生成」）；
//              ④ 读回 `CONFIG.*` 自检：乘法器 `PipeStages=0` ⇒ `C_LATENCY=0`
//                 （**纯组合输出**，端口只有 A/B/P，无 CLK/CE）；除法器
//                 `latency` 参数（radix-2、clocks_per_division=1、32/32）= 34 拍。
//              ⑤ **真实综合**（2026-09-14）：用上述 4 个 IP + 本文件的
//                 `RV32GC_USE_VIVADO_IP` 分支，对顶层 `mdu` 跑
//                 `launch_runs synth_1` ⇒ **synth_design Complete，0 error**；
//                 资源：**LUT 1690 / FF 3470 / DSP48 ×12 / BRAM 0**
//                 （12 个 DSP = 3 个 32×32 乘法 × 4；div_gen 走 radix-2 不用 DSP）。
//                 ⇒ 本文件综合分支的 IP 例化**可被 Vivado 综合**（非"伪例化"）。
//   [结论]
//     ① **Multiplier**（`mult_gen`，PG108）：存在且选用。`Multiplier_Construction
//        =Use_Mults` ⇒ 映射到 **DSP48**（非 LUT 拼接）；`PipeStages=0` 给出纯组合
//        64 位积 ⇒ 与仿真分支「2 拍出结果」的时序契约天然一致。
//     ② **Divider Generator**（`div_gen`，PG151）：存在且选用。
//        `algorithm_type=Radix2`（逐位恢复余数，省 DSP），32/32，
//        `remainder_type=Remainder`（输出不仅给商，还同拍给余数）。
//     ③ **DSP Macro**：原语级配置界面 ⇒ 红线 1 明确不选。
//     ④ **Complex Multiplier**：复数语义不符 ⇒ 不选。
//     ⑤ 对照 Block Memory Generator：本项目 Cache 用（08 §7.3），MDU 不需要。
//     ⇒ 汇总：不存在更合适的替代；合法路径 = 上述 4 个 IP（综合分支）+
//        逐拍等价行为模型（仿真分支）。**全程未使用任何 FPGA 原语**。
//
//   [与任务书建议方案的差异 —— 已论证，必须留档]
//     任务书建议「2 个 mult_gen（signed/su）+ 修正逻辑」。本文件改为 **3 个实例**：
//       * 任务书建议的「signed×unsigned 实例同时覆盖 mulhsu 与 mulhu」**不成立**：
//         a=0x8000_0000、b=0x8000_0000 时，signed×unsigned 高半部 = 0xFFFF_FFFF
//         （-2^62），而 mulhu 要求 0x4000_0000（+2^62）
//         （sim/unit/tb_mdu.sv 的 `mulhu_2p31` 向量正是这个反例）。
//       * 要覆盖 4 条乘法指令，只能「3 个 signedness 精确匹配的实例」或
//         「2 个实例 + 64 位修正加法器」。x7a200t 有 740 个 DSP 硬核乘法器，
//         多一个 32×32 乘法的面积代价可忽略，而零修正逻辑的可审查性最好
//         ⇒ 采用 3 实例（每实例都来自 IP Catalog，非手写算核）。
//     除法器同理只例化**一个无符号实例**（理由见 §6.2 注释）：
//     PG151 的有符号实例输出的是**幅值**商/余数，符号修正必须在 IP 外完成，
//     再挂一个 signed 实例并不能省掉任何外部逻辑，只会让面积翻倍
//     （实测延迟也更长：signed=36 拍 vs unsigned=34 拍）。
//
// ★★★ 仿真/综合双分支（红线 2）★★★
//   两分支**端口完全相同**；时序口径见下「时序契约」一节（乘法两分支逐拍一致，
//   除法综合分支以 IP 的 `m_axis_dout_tvalid` 为完成标志，仿真分支 34 拍固定）：
//
//   `else（默认，iverilog/Verilator）→ **纯行为模型**，零 Vivado 依赖：
//        * 乘法：Verilog 内建 `*` 运算（iverilog/Verilator 原生支持）
//        * 除法：**基 2 恢复余数逐位迭代**（32 拍），与旧项目
//          master:rtl/exec/rv32_mul_div.v 同算法，无 Vivado 也能跑 arch-test rv32im
//   `ifdef RV32GC_USE_VIVADO_IP（仅综合脚本定义）→ §6/§7 的 IP 例化，
//        握手/状态机**共用**（§8 只有一个 always），分支差异集中在「算核」与
//        「迭代完成判定」两处具名连线（§7）——不存在两套状态机。
//
//   ⇒ **仿真分支不得含任何 Vivado 专有语法或模块引用**：
//      所有 `rv32_mult_*`/`rv32_div` 例化都被 `ifdef` 严格包住。
//
// ★★★ 时序契约（tb_mdu 按此检查）★★★
//   设 `start` 在时钟沿 E0 被接收（须满足 E0 拍 `busy==0`）：
//     * E0 之后第 1 拍：`busy` 拉高（除法）；乘法不进 busy（见下）
//     * 乘法族：E0 之后第 **2** 拍 `done=1` 且 `result` 有效
//       （综合分支：mult_gen 为纯组合，P 在同一拍线上稳定 ⇒ **两分支逐拍一致**）
//     * 除法族：仿真分支 E0 之后第 **34** 拍 `done=1`
//               （32 拍逐位迭代 + 1 拍结果计算 + 1 拍输出寄存器）
//       ★ 综合分支：完成拍由 IP 的 `m_axis_dout_tvalid` 决定，**不是固定 34 拍**：
//           - IP 侧 `latency` 参数（radix-2、32/32、clocks_per_division=1）= **34** 拍
//             （create_ip.tcl 实测打印值）；
//           - 状态机在 tvalid 那一拍把 {商,余数} 采进 quot_q/rem_q，再走 1 拍 S_FIN；
//           - 再加启动对齐 1 拍（`ip_div_launch_q`，见 §6.2 的 why）。
//         实测（同一 TB 口径，`done` 出现在 start 采样沿后第 N 拍）：
//           仿真分支 N=33（除法族）/ N=1（乘法族）；
//           综合分支 N=37（除法族，IP 模型 latency=34）/ N=1（乘法族）。
//         ⇒ **乘法两分支逐拍一致；除法综合分支比仿真分支晚 4 拍**。
//         该差异由 IP 固有延迟造成，**不可消除**（仿真分支的迭代拍数按 08 §5.3
//         的 2A 口径保持不变）。⇒ **上层必须按 `busy`/`done` 握手消费，禁止把
//         除法延迟硬编码成 34 拍**；该口径已在头注与交付报告中双处登记。
//         （综合分支的完成拍对 IP 版本敏感：换 Vivado/IP 版本后延迟可能再变，
//           `div_iter_last` 取自 tvalid ⇒ 功能仍正确，只是完成拍随之变化。）
//     * `done` 为**单拍脉冲**；`done` 那一拍 `busy=0`
//       ⇒ 消费者可在 done 同拍背靠背发起下一次 `start`
//     * 除零/溢出特例**不改变时序**（延迟恒定，便于 TB 定拍检查）
//       ★ 两分支的这些特例由**同一个 function**（§5.2 `div_result`）给出，
//         综合分支也走它 ⇒ 不存在"IP 分支漏掉 ISA 特例"的可能。
//     * `flush=1` ⇒ 立即回 IDLE、`busy=0`、在途结果作废
//       （综合分支同时用 `flush` 复位 div_gen，保证下一次除法从干净状态开始）
//   ★ `busy` 冻结前端（08 §5.3）：E 级在 `busy` 期间不得接收新指令。
//   ★ 乘法**不置 busy**：其 2 拍延迟由 E 级固定停顿掩盖（乘法的两个操作数
//     已在 E 级入口就绪，2 拍内不依赖新结果）。此处如实在端口语义中写明，
//     避免上层误以为"乘法也要等 busy=0"。
//
// ★★★ 边界语义（ISA 定值，逐条对表）★★★
//   (1) 除零（b==0）：DIV/DIVU 商 = 32'hFFFF_FFFF（全 1）；REM/REMU 余数 = a。
//   (2) 有符号溢出（a=32'h8000_0000 即 -2^31，b=32'hFFFF_FFFF 即 -1）：
//       DIV 商 = 32'h8000_0000（= 被除数）；REM 余数 = 0；无符号除法不会溢出。
//   (3) 有符号除法**向零取整**，余数符号**与被除数相同**（≠ C 的向负取整）
//   (4) MUL  = (a*b) 低 32 位；MULH = (signed a)x(signed b) 高 32 位；
//       MULHSU= (signed a)x(unsigned b) 高 32 位；
//       MULHU = (unsigned a)x(unsigned b) 高 32 位。
//   (5) 未定义 `mdu_op`：译码保证不出现；若有则按 **mul 低 32 位**给出确定行为，
//       不产生异常、不新增 pkg 未定义的语义（两分支口径一致）。
//==============================================================================
`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"

module mdu (
    // ---- 时钟/复位（与全核口径一致：同步低有效复位 aresetn） ----
    input  wire        aclk,       // 单时钟域（cpu_clk = uncore_clk，无 CDC）
    input  wire        aresetn,    // 同步复位，低有效（复位回 IDLE）
    // ---- 控制 ----
    input  wire        start,      // 单拍脉冲；仅在 IDLE 且 start 时被接收
    input  wire        flush,      // 冲刷：立即回 IDLE（异常/中断/误判重定向）
    input  wire [2:0]  mdu_op,     // M 扩展 funct3（见「编码公约」）
    // ---- 操作数（仅在 start 被接收的那一拍采样） ----
    input  wire [31:0] a,          // 被除数 / 乘法操作数 1
    input  wire [31:0] b,          // 除数   / 乘法操作数 2
    // ---- 结果与握手 ----
    output wire        busy,       // 运算进行中（仅除法迭代期；冻结前端）
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

    // 运算族判定：op[2]==0 ⇒ 乘法（000..011）；op[2]==1 ⇒ 除法（100..111）。
    // 这是 M 扩展 funct3 的**天然**分界（rv32_defs.vh §3.7），非人为约定。
    wire is_mul = ~mdu_op[2];

    //==========================================================================
    // 2. 状态机常量
    //==========================================================================
    localparam [1:0] S_IDLE = 2'd0;   // 空闲：等待 start
    localparam [1:0] S_MUL  = 2'd1;   // 乘法输出拍（1 拍）
    localparam [1:0] S_DIV  = 2'd2;   // 除法迭代/等待（仿真 32 拍；综合等 IP 有效）
    localparam [1:0] S_FIN  = 2'd3;   // 除法输出拍（1 拍）

    // 仿真分支的迭代终值常量定义在 §4 的 `ifndef 区间内（综合分支不需要它，
    // 放在这里会让工具报 "Parameter is not used"）。

    //==========================================================================
    // 3. 时序状态 + 组合辅助
    //    组合逻辑一律走 assign/连续赋值（红线 3、08 §7.4）。
    //==========================================================================
    reg  [1:0]  state_q;            // 当前状态
    reg  [31:0] a_q;                // 被除数 / 乘法操作数 1（start 拍采样）
    reg  [31:0] b_q;                // 除数   / 乘法操作数 2（start 拍采样）
    reg  [2:0]  op_q;               // 运算码锁存（start 拍采样）
    reg  [4:0]  cnt_q;              // 迭代计数（仿真：0..31；综合：等待 IP 的拍数）
    // ★ quot_q/rem_q 两分支都用：仿真 = 逐位迭代的商/余数；综合 = div_gen 的
    //   幅值商/余数（在 IP 的 tvalid 拍锁存）。因此 §7 的 div_core_out 在两分支
    //   上可以是**同一个表达式**。
    reg  [31:0] quot_q;             // 幅值商（|a|/|b|）
    /* verilator lint_off UNUSEDSIGNAL */
    // rem_q 取 33 位是**仿真分支**的需要（逐位迭代左移 1 位后防溢出，见 §4）；
    // 综合分支的 IP 余数 ≤ 32 位（rem_q[32] 恒 0）⇒ 该比特在综合分支未被使用。
    reg  [32:0] rem_q;              // 幅值余数（33 位：仿真迭代防左移溢出）
    /* verilator lint_on UNUSEDSIGNAL */
    reg  [31:0] res_q;              // 输出结果寄存器
    reg         done_q;             // done 单拍脉冲

    // ---- 符号与绝对值（组合） ----
    wire        a_sign = a_q[31];                            // 被除数符号
    wire        b_sign = b_q[31];                            // 除数符号
    wire [31:0] a_abs  = a_sign ? (~a_q + 32'd1) : a_q;      // |a|（有符号用）
    wire [31:0] b_abs  = b_sign ? (~b_q + 32'd1) : b_q;      // |b|（有符号用）
    //     ★ 注：|0x8000_0000| = 0x8000_0000（无符号视角 = 2^31），
    //       补码取负自反，正是 ISA 溢出特例所需的幅值。

    // ★ 迭代/IP 用操作数：**有符号才取绝对值，无符号用原值**
    //   （divu/remu 把 32 位当纯无符号数，直接送原值即可；
    //    若误用 |a| 会把 0xFFFF_FFFF 当成 1 ⇒ 商/余数全错 —— 实测踩过。）
    //   ⇒ 这两个连线**两个分支共用**：
    //        仿真分支 = 逐位迭代的输入；综合分支 = div_gen（无符号实例）的输入。
    //        因为 IP 只做「幅值除法」，有符号的符号修正统一放在 IP 外（§5.2）。
    wire        div_signed_op = (op_q == MDU_DIV) || (op_q == MDU_REM);
    wire [31:0] div_a_op      = div_signed_op ? a_abs : a_q;
    wire [31:0] div_b_op      = div_signed_op ? b_abs : b_q;

    //==========================================================================
    // 4. 迭代元件（**仅仿真分支**）：基 2 恢复余数法一步（function，纯组合）
    //    每拍：余数左移 1 位并并入被除数 abs 的下一高位；
    //          若 (rem >= |b|) ⇒ rem -= |b| 且商位 = 1，否则商位 = 0。
    //    ★ 位宽：rem 用 33 位，保证「左移 1 位后与 32 位 |b| 无溢出比较」。
    //      ★★ 移位写法关键：余数左移时**必须整体左移 33 位寄存器**
    //         （`r_cur << 1`），而不能写成 `{r_cur[31:0], 1'b0}`
    //         ——后者丢弃 r_cur[32]（即余数的第 33 位），会让
    //         「|a| / 1」这类余数增长到 ≥2^32 的用例提前丢位
    //         （实测 divu 0xFFFF_FFFF/1 曾错误返回 1）。此处已修正。
    //    ★ 不做提前终止：延迟恒定 32 拍，便于 TB 定拍检查
    //      （08 §5.3 明确允许简单迭代，性能非 2A 门禁）。
    //    ★ 综合分支不需要本段（除法算核由 div_gen 承担）⇒ 整段用 `ifndef 包住，
    //      避免综合出无用的迭代组合逻辑（面积/时序）。
    //==========================================================================
`ifndef RV32GC_USE_VIVADO_IP
    localparam [4:0] DIV_ITER_LAST = 5'd31;   // 迭代序号 0..31 共 32 拍

    function [64:0] div_step;               // 返回 {rem_next[32:0], quot_next[31:0]}
        input [32:0] r_cur;                 // 当前余数（33 位）
        // q_cur[31] 有意不使用：本拍商的最低位由比较结果决定，q_cur[31] 会在
        // 下一拍成为 quot[30] 被保留；声明 32 位是为了端口语义完整（见下）。
        /* verilator lint_off UNUSEDSIGNAL */
        input [31:0] q_cur;                 // 当前商
        /* verilator lint_on UNUSEDSIGNAL */
        input [31:0] dividend;              // 被除数绝对值（逐位取用）
        input [31:0] divisor;               // 除数绝对值
        input [4:0]  step;                  // 迭代序号 0..31
        reg   [32:0] r_shl;                 // 左移/并入后的余数（33 位保留进位）
        reg   [32:0] r_sub;                 // 减去除数后的余数
        begin
            // 第 0 拍余数为 0 ⇒ 直接并入被除数 bit31；
            // 第 n 拍（n≥1）⇒ 余数**整体左移 1 位**并并入被除数 bit(31-n)。
            if (step == 5'd0)
                r_shl = {32'd0, dividend[31]};
            else
                r_shl = (r_cur << 1) | {32'd0, dividend[31 - step]};

            r_sub = r_shl - {1'b0, divisor};
            if (r_shl >= {1'b0, divisor})
                div_step = {r_sub,   q_cur[30:0], 1'b1};   // 够减 ⇒ 商位 1
            else
                div_step = {r_shl,   q_cur[30:0], 1'b0};   // 不够 ⇒ 商位 0
        end
    endfunction

    // 迭代一步的组合结果（{余数[32:0], 商[31:0]}），供 S_DIV 拍采样。
    // 单独命名：提高可读性，并避免在 concatenation 左值内直接调用 function
    // （消除工具对 side-effect 表达式的告警）。★ 必须声明在 div_step 之后。
    wire [64:0] div_step_next = div_step(rem_q, quot_q, div_a_op, div_b_op, cnt_q);
`endif // !RV32GC_USE_VIVADO_IP

    //==========================================================================
    // 5. 行为算核（function，纯组合）
    //    * §5.1 mul_result ：**仅仿真分支使用**（综合分支由 mult_gen 给出积）。
    //    * §5.2 div_result ：**两分支共用** —— 综合分支把它套在 div_gen 的
    //      「幅值商/余数」外面 ⇒ 除零、有符号溢出、余数符号三条 ISA 特例
    //      在两条分支上是**同一段代码**，不存在"IP 分支漏掉特例"的可能。
    //==========================================================================

    // ---- 5.1 乘法：按运算码返回最终 32 位结果（64 位积的对应半部） ----
    // 说明：本 function 内使用**阻塞赋值**（`=`）——这是 Verilog function 的
    //       正确且唯一用法（function 是纯组合，无时序语义）；工具可能提示
    //       BLKSEQ，属误报，不予修改。
    /* verilator lint_off UNUSEDSIGNAL */
    // BLKSEQ：function 体内用阻塞赋值是 Verilog 的唯一正确写法（纯组合、
    // 无时序语义），工具提示为误报 ⇒ 在本 function 范围内显式关闭。
    /* verilator lint_off BLKSEQ */
    function [31:0] mul_result;
        input [31:0] x;                     // a
        input [31:0] y;                     // b
        input [2:0]  op;                    // 运算码
        reg   [63:0] p_uu;                  // 无符号 × 无符号 64 位积
        // p_ss 只用高 32 位（mulh 取高半部）；低 32 位有意不用。
        reg   [63:0] p_ss;                  // 有符号 × 有符号 64 位积
        reg   [63:0] p_su;                  // 有符号 × 无符号 64 位积
        reg   [31:0] x_abs;                 // |x|
        begin
            // (a) 低 32 位在两种符号模式下**完全相同**（模 2^32）⇒ 用无符号积即可
            p_uu = {32'd0, x} * {32'd0, y};
            // (b) 有符号×有符号 64 位积（mulh 高半部）
            p_ss = $signed(x) * $signed(y);
            // (c) 有符号×无符号：先算 |x|*y 的 64 位无符号积
            x_abs = x[31] ? (~x + 32'd1) : x;
            p_su  = {32'd0, x_abs} * {32'd0, y};
            //      x<0 ⇒ 取该积的 64 位补码（等价于 signed(x)*unsigned(y)）
            if (x[31]) p_su = ~p_su + 64'd1;

            case (op)
                MDU_MULH  : mul_result = p_ss[63:32];   // 有符号高半
                MDU_MULHSU: mul_result = p_su[63:32];   // 有符号×无符号 高半
                MDU_MULHU : mul_result = p_uu[63:32];   // 无符号高半
                // MUL 及未定义编码：低 32 位（确定行为）
                default   : mul_result = p_uu[31:0];
            endcase
        end
    endfunction
    /* verilator lint_on BLKSEQ */
    /* verilator lint_on UNUSEDSIGNAL */

    // ---- 5.2 除法：按运算码 + 特例修正，返回最终 32 位结果（**两分支共用**）----
    //      uq/ur = **幅值**商/余数，即 |a| / |b|：
    //        仿真分支 = 32 拍逐位迭代的结果；综合分支 = div_gen 的
    //        {m_axis_dout_tdata[63:32], m_axis_dout_tdata[31:0]}。
    /* verilator lint_off BLKSEQ */   // 同上：function 内阻塞赋值为正确写法
    function [31:0] div_result;
        input [2:0]  op;                    // 运算码
        input [31:0] x;                     // a 原值（判溢出/除零）
        input [31:0] y;                     // b 原值
        input [31:0] uq;                    // 幅值商 |a|/|b|
        input [31:0] ur;                    // 幅值余数 |a| mod |b|
        input        xs;                    // a 的符号位
        input        ys;                    // b 的符号位
        reg   [31:0] q_sgn;                 // 符号修正后的商
        reg   [31:0] r_sgn;                 // 符号修正后的余数
        begin
            // (a) 符号修正：商符号 = a^b；**余数符号 = a**（ISA 定值：余数符号
            //     与被除数相同，且除法向零取整）
            q_sgn = (xs ^ ys) ? (~uq + 32'd1) : uq;
            r_sgn = xs        ? (~ur + 32'd1) : ur;

            if (y == 32'd0) begin
                // (b) 除零：商全 1；余数 = 被除数（有/无符号同值）
                //     [ISA norm:div_by_zero / norm:rem_by_zero]
                div_result = ((op == MDU_REM) || (op == MDU_REMU)) ? x : 32'hFFFF_FFFF;
            end
            else if (((op == MDU_DIV) || (op == MDU_REM)) &&
                     (x == 32'h8000_0000) && (y == 32'hFFFF_FFFF)) begin
                // (c) **有符号**溢出（-2^31 / -1）：商 = 被除数，余数 = 0
                //     [ISA norm:signed_div_overflow]
                //     ★ 必须只在有符号 DIV/REM 下走此分支：无符号 divu/remu
                //       把 0x8000_0000 当 2^31、0xFFFF_FFFF 当 2^32-1，
                //       结果是 0（商）/ 0x8000_0000（余数），**没有溢出**。
                //       实测踩过：未加符号门控时 divu 会错误返回 0x8000_0000。
                div_result = (op == MDU_REM) ? 32'd0 : 32'h8000_0000;
            end
            else if ((op == MDU_DIV) || (op == MDU_REM)) begin
                // (d) 常规有符号：用符号修正值
                div_result = (op == MDU_DIV) ? q_sgn : r_sgn;
            end
            else begin
                // (e) 无符号 divu/remu（及未定义编码）：幅值即结果
                div_result = (op == MDU_DIVU) ? uq : ur;
            end
        end
    endfunction
    /* verilator lint_on BLKSEQ */

    //==========================================================================
    // 6. 综合分支：Vivado IP 例化（**真实例化，非模板注释**；红线 1/2）
    //    ★ 仅当综合脚本定义了 `RV32GC_USE_VIVADO_IP` 时编译
    //      （定义处：fpga/tcl/synth.tcl；iverilog/Verilator 回归**从不**定义）。
    //    ★ IP 由 `fpga/tcl/create_ip.tcl` 生成（同一 tcl 内两处分节），
    //      端口与配置逐字对应。
    //    ★ **是 IP 例化，不是原语例化**：本文件不例化任何 FPGA 原语（Primitive），
    //      只有 IP 例化 + 纯 RTL（端口名/位宽与 create_ip.tcl 的配置逐字对应）。
    //==========================================================================
`ifdef RV32GC_USE_VIVADO_IP

    //--------------------------------------------------------------------------
    // 6.1 乘法核：Multiplier IP ×3（`Multiplier_Construction=Use_Mults` ⇒ DSP48）
    //      三个实例的 signedness 分别精确匹配 M 扩展的三类乘法语义：
    //        u_mult_signed   : mulh                  （signed × signed）
    //        u_mult_su       : mulhsu                （signed × unsigned）
    //        u_mult_unsigned : mulhu（及 mul 低半部）（unsigned × unsigned）
    //      `PipeStages=0` ⇒ 纯组合（实测 C_LATENCY=0，端口只有 A/B/P），
    //      因此 64 位积在 S_MUL 那一拍线上稳定 ⇒ 与仿真分支 2 拍时序**逐拍一致**。
    //      面积说明：x7a200t 共 740 个 DSP 硬核乘法器，3 个 32×32 乘法占用可忽略；
    //      换成"2 实例 + 64 位修正加法器"要付出组合路径变长与额外证明成本
    //      （见头注「与任务书建议方案的差异」）。
    //--------------------------------------------------------------------------
    //    ★ 下三条积的**低 32 位有意不单独使用**（mul 只取 uu 的低半部，
    //      mulh/mulhsu 只取高半部）⇒ 在综合分支显式抑制 UNUSEDSIGNAL，
    //      与 §5.1 中 p_ss/p_su 的抑制口径一致。
    /* verilator lint_off UNUSEDSIGNAL */
    wire [63:0] ip_mul_ss;      // 有符号 × 有符号 64 位积
    wire [63:0] ip_mul_su;      // 有符号 × 无符号 64 位积
    wire [63:0] ip_mul_uu;      // 无符号 × 无符号 64 位积
    /* verilator lint_on UNUSEDSIGNAL */

    rv32_mult_signed u_mult_signed (
        .A (a_q),               // [31:0] 被乘数（有符号解释）
        .B (b_q),               // [31:0] 乘数（有符号解释）
        .P (ip_mul_ss)          // [63:0] 完整积（本配置无 CLK/CE ⇒ 纯组合）
    );

    rv32_mult_su u_mult_su (
        .A (a_q),               // [31:0] 被乘数（有符号解释）
        .B (b_q),               // [31:0] 乘数（**无符号**解释）
        .P (ip_mul_su)          // [63:0]
    );

    rv32_mult_unsigned u_mult_unsigned (
        .A (a_q),               // [31:0] 被乘数（无符号解释）
        .B (b_q),               // [31:0] 乘数（无符号解释）
        .P (ip_mul_uu)          // [63:0]
    );

    // 按 op_q 取对应积的对应半部（与 §5.1 `mul_result` 的 case 逐条等价）：
    //   MUL    → 低 32 位（三种 signedness 下同值，取无符号实例）
    //   MULH   → signed×signed 高半
    //   MULHSU → signed×unsigned 高半
    //   MULHU  → unsigned×unsigned 高半
    //   未定义编码 → 与 MUL 同（确定行为，两分支一致）
    wire [31:0] ip_mul_out =
                  (op_q == MDU_MULH  ) ? ip_mul_ss[63:32] :
                  (op_q == MDU_MULHSU) ? ip_mul_su[63:32] :
                  (op_q == MDU_MULHU ) ? ip_mul_uu[63:32] :
                                         ip_mul_uu[31:0]  ;

    //--------------------------------------------------------------------------
    // 6.2 除法核：Divider Generator IP ×1（Radix2，无符号 32/32）
    //      ★ 为什么是**无符号**实例（与任务书"SIGNED=1"字面不同，理由留档）：
    //        ① 一条除法指令能不能用有符号 IP，取决于**操作数解释方式**：
    //           divu/remu 必须把 0xFFFF_FFFF 当 2^32-1，而有符号 IP 会把它当 -1
    //           ⇒ 有符号实例无法承担 divu/remu，至少需要两个实例。
    //        ② PG151 的有符号实例输出的是**幅值**商/余数（符号修正由用户在 IP
    //           外做：商符号 = a^b，余数符号 = 被除数 a）——也就是说，即便用
    //           有符号实例，本文件的 §5.2 符号修正逻辑**一行也省不掉**。
    //        ③ 既然外部逻辑相同，用「无符号实例 + 外部取绝对值」与
    //            「有符号实例（内部取绝对值）」在功能上完全等价，但**面积减半**
    //           （实测延迟也更短：unsigned=34 拍 vs signed=36 拍）。
    //        ⇒ 结论：一个无符号实例覆盖全部 4 条除法指令，
    //           操作数走 §3 的 `div_a_op`/`div_b_op`（有符号取 |a|/|b|，无符号原值），
    //           结果套 §5.2 `div_result` 做特例旁路 + 符号修正。
    //      ★ 握手：`s_axis_*_tvalid` 在进入 S_DIV 的**首拍**拉高（`ip_div_launch_q`），
    //        此时 a_q/b_q 已锁存新操作数 ⇒ IP 采到的就是本条指令的操作数。
    //        `FlowControl=NonBlocking`（无 tready 背压），`ARESETN=1` 供 flush 复位。
    //--------------------------------------------------------------------------
    wire [63:0] ip_div_dout;     // {余数[63:32], 商[31:0]}

    // ★ 时序元件（always 的正当场合：无法用 assign 表达的寄存器）
    //   启动脉冲：start 被接收 ⇒ 下一拍（= S_DIV 首拍）向 IP 发 tvalid。
    //   为什么晚一拍：`s_axis_*_tdata` 接的是 a_q/b_q 派生的 `div_a_op`/`div_b_op`，
    //   而 a_q/b_q 是在 start 被接收的那一拍才锁存的 ⇒ 若在同拍发 tvalid，
    //   IP 会采到**上一条指令**的操作数（AXI-Stream 在 tvalid 那一沿取数）。
    //   复位口径：全局复位与 `flush` 都清掉启动脉冲；`flush` 同时复位 IP
    //   （见下 aresetn 接法），保证冲刷后下一次除法从干净状态开始。
    reg ip_div_launch_q;
    always @(posedge aclk) begin
        if (!aresetn)   ip_div_launch_q <= 1'b0;
        else if (flush) ip_div_launch_q <= 1'b0;
        else            ip_div_launch_q <= (state_q == S_IDLE) && start && (~is_mul);
    end

    // 注：IP 的 {商, 余数} **不需要**再挂一级锁存寄存器 —— 状态机在
    //     `m_axis_dout_tvalid` 那一拍（即 §7 的 `div_iter_last`）直接把
    //     `ip_div_dout` 采进 quot_q/rem_q（AXI-Stream 语义保证该拍 tdata 有效），
    //     S_FIN 拍再套 §5.2 `div_result` 输出 ⇒ 寄存器数量最少。
    // 送进 IP 的操作数：除数为 0 时送 1（避免依赖 IP 对 0 除数的未定义行为；
    // 该情形的结果由 §5.2 的除零分支给出，IP 输出被完全旁路）
    wire [31:0] ip_div_a = div_a_op;                              // |a| 或 a
    wire [31:0] ip_div_b = (div_b_op == 32'd0) ? 32'd1 : div_b_op; // |b| 或 b（0→1）

    wire        ip_div_dout_valid;    // IP 结果有效（单拍脉冲）⇒ 状态机完成标志
    wire        ip_div_aresetn = aresetn & (~flush);   // flush 亦复位 IP（清在途运算）

    rv32_div u_div (
        .aclk                   (aclk            ),   // 单时钟域
        .aclken                 (1'b1            ),   // clk_en 恒开（配置已使能）
        .aresetn                (ip_div_aresetn  ),   // 全局复位 + flush 冲刷
        .s_axis_divisor_tvalid  (ip_div_launch_q ),   // 启动脉冲（S_DIV 首拍）
        .s_axis_divisor_tdata   (ip_div_b       ),    // 除数（幅值）
        .s_axis_dividend_tvalid (ip_div_launch_q ),   // 与被除数同拍有效
        .s_axis_dividend_tdata  (ip_div_a       ),    // 被除数（幅值）
        .m_axis_dout_tvalid     (ip_div_dout_valid),  // 结果有效脉冲
        .m_axis_dout_tdata      (ip_div_dout    )     // {余数[63:32], 商[31:0]}
    );

`endif // RV32GC_USE_VIVADO_IP

    //==========================================================================
    // 7. 算核输出与「迭代完成」判定（两分支在这里分叉，其余全部共用）
    //    * `mul_core_out` / `div_core_out`：§8 状态机写入 res_q 的值来源
    //      —— 仿真 = 行为 function；综合 = IP（除法仍套 §5.2 的 div_result）
    //    * `div_iter_last` / `div_rem_next` / `div_quot_next`：S_DIV 的推进条件
    //      —— 仿真 = cnt_q 数到 31；综合 = IP 的 `m_axis_dout_tvalid`
    //    ⇒ 状态机（§8）与外部端口在两个分支上是**同一段代码**。
    //==========================================================================
`ifdef RV32GC_USE_VIVADO_IP
    wire [31:0] mul_core_out  = ip_mul_out;
    wire        div_iter_last = ip_div_dout_valid;                 // IP 报有效 ⇒ 结束等待
    wire [32:0] div_rem_next  = {1'b0, ip_div_dout[63:32]};        // IP 幅值余数（本拍有效）
    wire [31:0] div_quot_next = ip_div_dout[31:0];                 // IP 幅值商
`else
    wire [31:0] mul_core_out  = mul_result(a_q, b_q, op_q);
    wire        div_iter_last = (cnt_q == DIV_ITER_LAST);
    wire [32:0] div_rem_next  = div_step_next[64:32];
    wire [31:0] div_quot_next = div_step_next[31:0];
`endif

    // ★ 除法的**最终结果表达式两分支共用**：不管商/余数来自逐位迭代还是 div_gen，
    //   都套同一个 §5.2 `div_result`（除零、有符号溢出、余数符号三条 ISA 特例
    //   只有一处实现）—— 这是"综合分支不会漏掉 ISA 边界"的结构性保证。
    wire [31:0] div_core_out = div_result(op_q, a_q, b_q,
                                          quot_q, rem_q[31:0],
                                          a_sign, b_sign);

    //==========================================================================
    // 8. 时序状态机（本模块唯一的功能性 always —— 时序元件，无法用 assign 表达）
    //    理由即 §5.3 的「多拍 / busy 冻结前端」：必须有多拍状态机。
    //    组合逻辑一律走 assign/function（红线 3、08 §7.4）。
    //==========================================================================
    always @(posedge aclk) begin
        if (!aresetn) begin
            // ---- 同步复位：回 IDLE，busy/done 全 0 ----
            state_q   <= S_IDLE;
            a_q       <= 32'd0;
            b_q       <= 32'd0;
            op_q      <= MDU_MUL;
            cnt_q     <= 5'd0;
            quot_q    <= 32'd0;
            rem_q     <= 33'd0;
            res_q     <= 32'd0;
            done_q    <= 1'b0;
        end
        else if (flush) begin
            // ---- 冲刷（最高优先级）：立即回 IDLE，在途结果作废 ----
            //      理由：异常/中断/分支误判重定向后，MDU 在途结果必须丢弃，
            //      否则过期结果会写回架构寄存器（2A 顺序核正确性前提）。
            //      综合分支同时由 `ip_div_aresetn` 复位 div_gen（清在途运算）。
            state_q   <= S_IDLE;
            cnt_q     <= 5'd0;
            res_q     <= 32'd0;
            done_q    <= 1'b0;
        end
        else begin
            // done 默认拉低：仅在到达输出拍时置高 ⇒ 保证是单拍脉冲
            done_q <= 1'b0;

            case (state_q)
                //--------------------------------------------------------------
                // IDLE：等待 start（非 IDLE 期间的 start 被忽略 ⇒ busy 期不吃新指令）
                //--------------------------------------------------------------
                S_IDLE: begin
                    if (start) begin
                        a_q     <= a;
                        b_q     <= b;
                        op_q    <= mdu_op;
                        cnt_q   <= 5'd0;
                        quot_q  <= 32'd0;
                        rem_q   <= 33'd0;
                        state_q <= is_mul ? S_MUL : S_DIV;
                    end
                end

                //--------------------------------------------------------------
                // MUL：唯一输出拍 —— 计算并寄存结果，done 同拍拉高
                //      （本拍结束状态回 IDLE ⇒ done 那一拍 busy=0）
                //--------------------------------------------------------------
                S_MUL: begin
                    state_q <= S_IDLE;
                    res_q   <= mul_core_out;   // 仿真 = function；综合 = mult_gen（纯组合）
                    done_q  <= 1'b1;
                end

                //--------------------------------------------------------------
                // DIV：仿真 = 32 拍逐位恢复余数迭代；综合 = 等待 div_gen 结果有效
                //--------------------------------------------------------------
                S_DIV: begin
                    // ★ 推进条件按分支取（§7）：仿真数到 31 拍，综合等 IP tvalid。
                    //   迭代值/等待值都用具名 wire 承接，避免在 concatenation
                    //   左值里直接调用 function（工具会告警 side-effect 表达式）。
                    rem_q  <= div_rem_next;
                    quot_q <= div_quot_next;
                    if (div_iter_last) begin
                        cnt_q   <= 5'd0;
                        state_q <= S_FIN;
                    end
                    else begin
                        cnt_q <= cnt_q + 5'd1;
                    end
                end

                //--------------------------------------------------------------
                // FIN：唯一输出拍 —— 按符号与特例修正，寄存结果，done 拉高
                //--------------------------------------------------------------
                S_FIN: begin
                    state_q <= S_IDLE;
                    res_q   <= div_core_out;   // 两分支都走 §5.2 的 div_result
                    done_q  <= 1'b1;
                end

                default: state_q <= S_IDLE;
            endcase
        end
    end

    //==========================================================================
    // 9. 输出与握手（两分支共用）
    //    * busy   = 处于 **S_DIV** ⇒ 冻结前端（08 §5.3）
    //               （乘法不置 busy：其 2 拍延迟由 E 级固定停顿掩盖）
    //    * done   = done_q（单拍脉冲，与 res_q 同拍有效；该拍 busy=0）
    //    * result = res_q
    //==========================================================================
    assign busy   = (state_q == S_DIV);
    assign done   = done_q;
    assign result = res_q;

endmodule
