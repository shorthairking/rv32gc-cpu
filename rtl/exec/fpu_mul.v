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
//   舍入交给已验证的窄域原语 `fpu_round_n`（定义在 fpu_add.v；窄域 + sticky
//   重写见 fpu_add.v 头注 P1~P6；规格与验证见 .work_fpu/HW_ROUND_VERIFIED.md）。
//   ★ 乘法通路 sticky_in 恒 0：乘积本身就是精确窗口（48/106 bit ≤ WW），
//     没有"被压掉的低位"⇒ 与旧 1024/8192 bit 全宽实现逐位等价。
//==============================================================================
`include "rv32_defs.vh"
`include "core_params.vh"

//==============================================================================
// fpu_mul_s —— 单精度乘法（fmul.s）
//==============================================================================
module fpu_mul_s (
    input  wire [63:0] a,
    input  wire [63:0] b,
    input  wire [2:0]  rm,
    output wire [31:0] result,
    output wire [4:0]  fflags
);
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

    // ---- 精确乘积（无舍入）----
    // value = a_sig × b_sig × 2^(a_eunb - 23) × 2^(b_eunb - 23)
    //       = prod   × 2^(a_eunb + b_eunb - 46)
    wire        p_sign = a_sign ^ b_sign;
    wire [47:0] prod   = a_sig * b_sig;
    wire signed [15:0] p_exp = a_eunb + b_eunb - 16'sd46;

    // ---- 一次舍入（窄域 + sticky 原语；乘积 48 bit 精确值直接作为窗口，
    //      sticky_in = 0 —— 无对阶、无截断，故舍入与旧全宽实现逐位相同）----
    wire [31:0] round_result;
    wire [4:0]  round_flags;
    fpu_round_n #(.FB(23), .WW(48), .RW(32), .EB(8),
                  .MIN_SUB(-149), .E_MAXF(255), .BIAS(127)) u_round (
        .sign      (p_sign),
        .sig       (prod),
        .sticky_in (1'b0),
        .exp       (p_exp),               // S 的 p_exp ∈ [-298, 200]
        .rm        (rm),
        .result    (round_result),
        .fflags    (round_flags)
    );

    // ---- 特殊值 ----
    wire inf_zero = (a_inf & b_zero) | (a_zero & b_inf);   // ⇒ NV + qNaN
    wire any_nan  = a_nan | b_nan;
    wire any_snan = a_snan | b_snan;
    wire give_nan = any_nan | inf_zero;
    wire give_inf = (a_inf | b_inf) & ~inf_zero & ~any_nan;

    localparam [31:0] CANON_S = 32'h7FC0_0000;

    assign result = give_nan  ? CANON_S :
                    give_inf  ? {p_sign, 8'hFF, 23'b0} :
                    (a_zero | b_zero) ? {p_sign, 31'b0} :
                                round_result;

    // 特殊值通路屏蔽舍入标志（NaN/Inf 的位型不是数值）
    wire is_special = give_nan | give_inf | a_zero | b_zero;
    wire nv = any_snan | inf_zero;
    assign fflags = { nv, 1'b0,
                      is_special ? 1'b0 : round_flags[2],
                      is_special ? 1'b0 : round_flags[1],
                      is_special ? 1'b0 : round_flags[0] };
endmodule

//==============================================================================
// fpu_mul_d —— 双精度乘法（fmul.d）
//==============================================================================
module fpu_mul_d (
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

    wire         p_sign = a_sign ^ b_sign;
    wire [105:0] prod   = a_sig * b_sig;                      // 53×53 精确积
    wire signed [15:0] p_exp = a_eunb + b_eunb - 16'sd104;
    // value = prod × 2^(a_eunb + b_eunb - 104)

    wire [63:0] round_result;
    wire [4:0]  round_flags;
    fpu_round_n #(.FB(52), .WW(106), .RW(64), .EB(11),
                  .MIN_SUB(-1074), .E_MAXF(2047), .BIAS(1023)) u_round (
        .sign      (p_sign),
        .sig       (prod),
        .sticky_in (1'b0),
        .exp       (p_exp),               // D 的 p_exp ∈ [-2148, 1942]
        .rm        (rm),
        .result    (round_result),
        .fflags    (round_flags)
    );

    wire inf_zero = (a_inf & b_zero) | (a_zero & b_inf);
    wire any_nan  = a_nan | b_nan;
    wire any_snan = a_snan | b_snan;
    wire give_nan = any_nan | inf_zero;
    wire give_inf = (a_inf | b_inf) & ~inf_zero & ~any_nan;

    localparam [63:0] CANON_D = 64'h7FF8_0000_0000_0000;

    assign result = give_nan  ? CANON_D :
                    give_inf  ? {p_sign, 11'h7FF, 52'b0} :
                    (a_zero | b_zero) ? {p_sign, 63'b0} :
                                round_result;

    wire is_special = give_nan | give_inf | a_zero | b_zero;
    wire nv = any_snan | inf_zero;
    assign fflags = { nv, 1'b0,
                      is_special ? 1'b0 : round_flags[2],
                      is_special ? 1'b0 : round_flags[1],
                      is_special ? 1'b0 : round_flags[0] };
endmodule
