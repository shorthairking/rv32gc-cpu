//==============================================================================
// fpu_mul.v —— 浮点乘法（F: binary32 / D: binary64）
//==============================================================================
// 项目  : rv32gc-cpu（2A 单发射顺序 5 级基线核）
// 规格  : docs/design/08-baseline-5stage.md §5.3（fpu_mul.v 行）
//         IEEE-754-2008 binary32/binary64；RISC-V F/D
//         （riscv-isa-manual/src/unpriv/f-st-ext.adoc:219-222 norm:fadd-s_fmul-s_op；
//          d-st-ext.adoc:122-125 norm:D_computational_instrs）
//
// 语义：
//   ① fmul.s/d = rs1 × rs2，**单次**正确舍入（按 rm）。
//   ② Inf × 0 ⇒ NV + canonical NaN（f-st-ext.adoc:134-139 canonical_NaN）。
//   ③ 0 × 有限 ⇒ 带符号零（符号 = 两操作数符号异或）。
//   ④ Inf × 有限(非零) ⇒ 带符号 Inf。
//   ⑤ NaN ⇒ canonical NaN；含 sNaN ⇒ 置 NV。
//   ⑥ fflags：NV/OF/UF/NX（DZ 不产生）。
//
// ★ 红线 1/2（IP 优先 + 双分支）
//   检索结论：Vivado 有 `Floating-Point Operator v7.1` IP，支持 Multiply、
//   FMA、Add/Sub、Divide、Square root，可配 binary32/binary64 ⇒ 综合分支
//   （`RV32GC_USE_VIVADO_IP`）例化该 IP；仿真分支（默认）走本文件行为模型
//   （**可综合**、纯整数运算），保证 iverilog/Verilator 回归不依赖 Vivado。
//   ★ 不使用任何 FPGA 原语（红线 1）：乘积用 Verilog `*` 描述，由综合器
//     自动推断 DSP48/乘法器，**不**手写原语或 DSP 宏。
//
// 位宽：S 用 24×24=48 bit 精确积；D 用 53×53=106 bit 精确积。
//   ★ 因为乘积**完全精确**，乘法天然满足"单次舍入"（只有一个待舍入的值）。
//   舍入交给已验证的窄域原语 `fpu_round_pipe`（定义在 fpu_add.v；窄域 + sticky
//   重写见 fpu_add.v 头注 P1~P6；规格与验证见 .work_fpu/HW_ROUND_VERIFIED.md）。
//   ★ 乘法通路 sticky_in 恒 0：乘积本身就是精确窗口（48/106 bit ≤ WW），
//     没有"被压掉的低位"⇒ 与旧 1024/8192 bit 全宽实现逐位等价。
//
// ★ T4（2026-09-20）：分级流水（与 fpu_add.v 同一套切点）
//   级1 fields ｜ 级2 = 舍入级A（组合吃精确积）｜ 级3 pre ｜ 级4 mid ｜
//   末级 post（组合）+ 特殊值 mux ⇒ **天然 4 级**；再补 `fpu_delay(N = LAT−4 = 4)`
//   对齐全核统一潜伏期 LAT = 8 拍（与 rtl/exec/fpu.v 的 FPU_SC_LAT 一致）。
//   ★ 级数必须逐级数**寄存器**：fields(R1)→舍入A→B→C = 4 级寄存器，乘积是
//     组合（直接进舍入级 A）。写错会静默错 1 拍（本任务实测踩到：写成 LAT−5
//     时 fmul 结果早 1 拍，被"操作数在停拍期间保持不变"掩盖）。
//   特殊值结果/flags 在第 0 级算好后用 `fpu_delay(N=LAT)` 延迟到末级
//   （论证见 fpu_add.v 头注「T4 逐位不变论证」）。
//==============================================================================
`include "rv32_defs.vh"
`include "core_params.vh"

//==============================================================================
// fpu_mul_s —— 单精度乘法（fmul.s）—— 8 拍潜伏期（5 级天然 + 3 级补齐）
//==============================================================================
module fpu_mul_s (
    input  wire        clk,
    input  wire [63:0] a,
    input  wire [63:0] b,
    input  wire [2:0]  rm,
    output wire [31:0] result,
    output wire [4:0]  fflags
);
    //---- 第 0 级（组合）：字段 + 特殊值 ----
    wire        a_sign = a[31];
    wire        b_sign = b[31];
    wire [7:0]  a_exp  = a[30:23];
    wire [7:0]  b_exp  = b[30:23];
    wire [22:0] a_frac = a[22:0];
    wire [22:0] b_frac = b[22:0];

    wire a_nan  = (a_exp == 8'hFF) && (a_frac != 0);
    wire b_nan  = (b_exp == 8'hFF) && (b_frac != 0);
    wire a_inf  = (a_exp == 8'hFF) && (a_frac == 0);
    wire b_inf  = (b_exp == 8'hFF) && (b_frac == 0);
    wire a_zero = (a_exp == 0) && (a_frac == 0);
    wire b_zero = (b_exp == 0) && (b_frac == 0);
    wire a_snan = a_nan && ~a[22];
    wire b_snan = b_nan && ~b[22];

    // 有效数（亚正规隐藏位 0）
    wire [23:0] a_sig = (a_exp == 0) ? {1'b0, a_frac} : {1'b1, a_frac};
    wire [23:0] b_sig = (b_exp == 0) ? {1'b0, b_frac} : {1'b1, b_frac};

    // 无偏指数（亚正规取 -126，配合有效数的 ×2^-23 口径）
    wire signed [15:0] a_eunb = (a_exp == 0) ? -16'sd126 : ($signed({8'b0, a_exp}) - 16'sd127);
    wire signed [15:0] b_eunb = (b_exp == 0) ? -16'sd126 : ($signed({8'b0, b_exp}) - 16'sd127);

    wire p_sign = a_sign ^ b_sign;

    //---- 特殊值（原末级 mux 的特殊值段，逐字）----
    wire inf_zero = (a_inf & b_zero) | (a_zero & b_inf);   // ⇒ NV + qNaN
    wire any_nan  = a_nan | b_nan;
    wire any_snan = a_snan | b_snan;
    wire give_nan = any_nan | inf_zero;
    wire give_inf = (a_inf | b_inf) & ~inf_zero & ~any_nan;
    localparam [31:0] CANON_S = 32'h7FC0_0000;
    wire is_special = give_nan | give_inf | a_zero | b_zero;
    wire nv = any_snan | inf_zero;
    wire [31:0] sp_r = give_nan  ? CANON_S :
                       give_inf  ? {p_sign, 8'hFF, 23'b0} :
                                   {p_sign, 31'b0};      // 剩下的 is_special 情形 = 零
    wire [4:0]  sp_f = {nv, 4'b0000};

    //---- 级 1：字段 ----
    reg [23:0] r1_as, r1_bs;
    reg signed [15:0] r1_ae, r1_be;
    reg        r1_ps;
    reg [2:0]  r1_rm;
    always @(posedge clk) begin
        r1_as <= a_sig; r1_bs <= b_sig;
        r1_ae <= a_eunb; r1_be <= b_eunb;
        r1_ps <= p_sign; r1_rm <= rm;
    end

    //---- 级 2（组合：精确乘积）→ 舍入级 A 寄存器 ----
    // value = a_sig × b_sig × 2^(a_eunb - 23) × 2^(b_eunb - 23)
    //       = prod   × 2^(a_eunb + b_eunb - 46)
    wire [47:0]        w_prod = r1_as * r1_bs;
    wire signed [15:0] w_pexp = r1_ae + r1_be - 16'sd46;

    //---- 级 3~5 + 末级：一次舍入（窄域 + sticky 原语；乘积 48 bit 精确值直接
    //     作为窗口，sticky_in = 0 —— 无对阶、无截断，故舍入与旧全宽实现逐位相同）----
    wire [31:0] round_result;
    wire [4:0]  round_flags;
    fpu_round_pipe #(.FB(23), .WW(48), .RW(32), .EB(8),
                     .MIN_SUB(-149), .E_MAXF(255), .BIAS(127)) u_round (
        .clk       (clk),
        .sign      (r1_ps),
        .sig       (w_prod),
        .sticky_in (1'b0),
        .exp       (w_pexp),              // S 的 p_exp ∈ [-298, 200]
        .rm        (r1_rm),
        .result    (round_result),
        .fflags    (round_flags)
    );

    //---- 特殊值旁带（延迟 LAT 拍）+ 末级 mux（天然 5 级 ⇒ 补 3 级）----
    localparam integer LAT = 8;           // ★ 必须与 fpu.v 的 FPU_SC_LAT 一致
    wire [36:0] sp_d;
    assign sp_d = {sp_r, sp_f};
    wire [36:0] sp_q;
    fpu_delay #(.W(37), .N(LAT)) u_spdly (.clk (clk), .d (sp_d), .q (sp_q));
    wire [31:0] sp_r_q = sp_q[36:5];
    wire [4:0]  sp_f_q = sp_q[4:0];
    wire        sp_e_q;
    fpu_delay #(.W(1), .N(LAT)) u_sped (.clk (clk), .d (is_special), .q (sp_e_q));

    wire [36:0] rr_d;
    assign rr_d = {round_result, round_flags};
    wire [36:0] rr_q;
    fpu_delay #(.W(37), .N(LAT - 4)) u_pad (.clk (clk), .d (rr_d), .q (rr_q));
    wire [31:0] rr_r = rr_q[36:5];
    wire [4:0]  rr_f = rr_q[4:0];

    assign result = sp_e_q ? sp_r_q : rr_r;
    assign fflags = sp_e_q ? sp_f_q : rr_f;
endmodule

//==============================================================================
// fpu_mul_d —— 双精度乘法（fmul.d）—— 8 拍潜伏期（5 级天然 + 3 级补齐）
//==============================================================================
module fpu_mul_d (
    input  wire        clk,
    input  wire [63:0] a,
    input  wire [63:0] b,
    input  wire [2:0]  rm,
    output wire [63:0] result,
    output wire [4:0]  fflags
);
    wire        a_sign = a[63];
    wire        b_sign = b[63];
    wire [10:0] a_exp  = a[62:52];
    wire [10:0] b_exp  = b[62:52];
    wire [51:0] a_frac = a[51:0];
    wire [51:0] b_frac = b[51:0];

    wire a_nan  = (a_exp == 11'h7FF) && (a_frac != 0);
    wire b_nan  = (b_exp == 11'h7FF) && (b_frac != 0);
    wire a_inf  = (a_exp == 11'h7FF) && (a_frac == 0);
    wire b_inf  = (b_exp == 11'h7FF) && (b_frac == 0);
    wire a_zero = (a_exp == 0) && (a_frac == 0);
    wire b_zero = (b_exp == 0) && (b_frac == 0);
    wire a_snan = a_nan && ~a[51];
    wire b_snan = b_nan && ~b[51];

    wire [52:0] a_sig = (a_exp == 0) ? {1'b0, a_frac} : {1'b1, a_frac};
    wire [52:0] b_sig = (b_exp == 0) ? {1'b0, b_frac} : {1'b1, b_frac};

    wire signed [15:0] a_eunb = (a_exp == 0) ? -16'sd1022 : ($signed({5'b0, a_exp}) - 16'sd1023);
    wire signed [15:0] b_eunb = (b_exp == 0) ? -16'sd1022 : ($signed({5'b0, b_exp}) - 16'sd1023);

    wire p_sign = a_sign ^ b_sign;

    wire inf_zero = (a_inf & b_zero) | (a_zero & b_inf);
    wire any_nan  = a_nan | b_nan;
    wire any_snan = a_snan | b_snan;
    wire give_nan = any_nan | inf_zero;
    wire give_inf = (a_inf | b_inf) & ~inf_zero & ~any_nan;
    localparam [63:0] CANON_D = 64'h7FF8_0000_0000_0000;
    wire is_special = give_nan | give_inf | a_zero | b_zero;
    wire nv = any_snan | inf_zero;
    wire [63:0] sp_r = give_nan  ? CANON_D :
                       give_inf  ? {p_sign, 11'h7FF, 52'b0} :
                                   {p_sign, 63'b0};      // 剩下的 is_special 情形 = 零
    wire [4:0]  sp_f = {nv, 4'b0000};

    //---- 级 1：字段 ----
    reg [52:0] r1_as, r1_bs;
    reg signed [15:0] r1_ae, r1_be;
    reg        r1_ps;
    reg [2:0]  r1_rm;
    always @(posedge clk) begin
        r1_as <= a_sig; r1_bs <= b_sig;
        r1_ae <= a_eunb; r1_be <= b_eunb;
        r1_ps <= p_sign; r1_rm <= rm;
    end

    //---- 级 2：精确乘积（→ 舍入级 A 寄存器）----
    wire [105:0]       w_prod = r1_as * r1_bs;                // 53×53 精确积
    wire signed [15:0] w_pexp = r1_ae + r1_be - 16'sd104;
    // value = prod × 2^(a_eunb + b_eunb - 104)

    wire [63:0] round_result;
    wire [4:0]  round_flags;
    fpu_round_pipe #(.FB(52), .WW(106), .RW(64), .EB(11),
                     .MIN_SUB(-1074), .E_MAXF(2047), .BIAS(1023)) u_round (
        .clk       (clk),
        .sign      (r1_ps),
        .sig       (w_prod),
        .sticky_in (1'b0),
        .exp       (w_pexp),              // D 的 p_exp ∈ [-2148, 1942]
        .rm        (r1_rm),
        .result    (round_result),
        .fflags    (round_flags)
    );

    localparam integer LAT = 8;           // ★ 必须与 fpu.v 的 FPU_SC_LAT 一致
    wire [68:0] sp_d;
    assign sp_d = {sp_r, sp_f};
    wire [68:0] sp_q;
    fpu_delay #(.W(69), .N(LAT)) u_spdly (.clk (clk), .d (sp_d), .q (sp_q));
    wire [63:0] sp_r_q = sp_q[68:5];
    wire [4:0]  sp_f_q = sp_q[4:0];
    wire        sp_e_q;
    fpu_delay #(.W(1), .N(LAT)) u_sped (.clk (clk), .d (is_special), .q (sp_e_q));

    wire [68:0] rr_d;
    assign rr_d = {round_result, round_flags};
    wire [68:0] rr_q;
    fpu_delay #(.W(69), .N(LAT - 4)) u_pad (.clk (clk), .d (rr_d), .q (rr_q));
    wire [63:0] rr_r = rr_q[68:5];
    wire [4:0]  rr_f = rr_q[4:0];

    assign result = sp_e_q ? sp_r_q : rr_r;
    assign fflags = sp_e_q ? sp_f_q : rr_f;
endmodule
