//==============================================================================
// rtl/exec/fpu_cmp.v —— FPU 比较/符号注入/最小最大/分类（F/D 双格式，纯组合）
//==============================================================================
// 项目  : rv32gc-cpu（2A 单发射顺序 5 级基线核）
// 规格  : docs/design/08-baseline-5stage.md §5.3（FPU 行）；INTERFACE.md（端口契约）
//         riscv-isa-manual/src/unpriv/f-st-ext.adoc / d-st-ext.adoc（逐条对照见下）
//
// 覆盖指令（归一化 fp_op[6:0]，见下方「操作码表」）：
//   fsgnj.s/d、fsgnjn.s/d、fsgnjx.s/d、fmin.s/d、fmax.s/d、
//   feq.s/d、flt.s/d、fle.s/d、fclass.s/d
//
// 语义要点（每条给规范出处）：
//   ① fsgnj/fsgnjn/fsgnjx：取 rs1 除符号位外全部位，符号位按 rs2 注入
//      （j：rs2 符号；jn：rs2 符号取反；jx：两者异或）；**不置任何 fflags、
//      不规范化 NaN** —— f-st-ext.adoc:372-382 norm:fsgnj-s_fsgnjn-s_fsgnjx-s_op。
//   ② fmin/fmax = IEEE 754-2019 minimumNumber/maximumNumber：
//      · 两个都 NaN ⇒ canonical NaN；只有一个 NaN ⇒ 返回另一个操作数
//        （f-st-ext.adoc:246-247 norm:fmin-s_fmax-s_both_nan_input / _one_nan_input）；
//      · **任一 sNaN 输入 ⇒ 置 NV**（即使结果不是 NaN）
//        （f-st-ext.adoc:248 norm:fmin-s_fmax-s_signaling_nan_nv）；
//      · 仅对本指令 −0.0 < +0.0（f-st-ext.adoc:245）。
//      ★ 注意：规范**没有**「双 NaN 置 NV」这条；双 NaN（无 sNaN）只给 canonical NaN。
//        （arch-test 同口径：coverpoints/norm/F.yaml:296-303 的 fmin/fmax 只有
//         cp_csr_fflags_v；docs/ctp/src/f.adoc:17 定义 v=NV。）
//   ③ feq 是**quiet** 比较：仅 sNaN 置 NV；flt/fle 是 **signaling** 比较：
//      任一 NaN（含 qNaN）置 NV；三者只要有一个操作数是 NaN，结果就是 0
//      （f-st-ext.adoc:440-446 norm:flt-s_fle-s_signaling / feq-s_quiet / _NaN_input）。
//      ⇒ +0 == −0 为真；flt(+0,−0) = 0（二者数值相等）。
//   ④ fclass：写 10 bit 掩码（bit0 −∞ … bit7 +∞、bit8 sNaN、bit9 qNaN），
//      其余位清零、恰有一位为 1、**不置 fflags**（f-st-ext.adoc:461-491）。
//   ⑤ NaN-boxing（d-st-ext.adoc:52-59 norm:FP_nontransfer_instrs_improper_nan-boxed_input）：
//      本模块所有 S 操作数在**非 transfer** 语义下检查高 32 位是否全 1，
//      不全 1 ⇒ 该操作数按 S canonical NaN (0x7FC00000) 参与运算；
//      S 结果写回 fregfile 的 64 位视图时高 32 位必须全 1（d-st-ext.adoc:29）。
//
// ★ 红线 1/2（IP 优先 + 无原语）
//   检索结论：Vivado 的 `Floating-Point Operator v7.1`（PG060）虽提供 Compare /
//   Conversion 模式，但它**不**提供 RISC-V 需要的 fclass 10 类掩码、
//   canonical-NaN/NaN-boxing 替换、fmin/fmax 的 IEEE-754-2019 NaN 传播，
//   也不输出 RISC-V 口径的 NV/NX（比较类只输出 A=B/A<B 等布尔）。
//   本模块为纯位级选择逻辑（无 DSP/BRAM/时钟域硬核），**不含任何 FPGA 原语**、
//   也不例化任何 IP，故无需 IP/行为模型双分支（`RV32GC_USE_VIVADO_IP` 不适用）。
//
// 实现纪律：**全 assign / 条件表达式**，无 always 块、无 reg（红线 3）。
//
// 操作码表（归一化 fp_op[6:0]，与 INTERFACE.md 列出的顺序一致；
//           fpu.v 与本文件必须一致，全表见 fpu_cvt.v 头注）：
//     5 FSGNJ   6 FSGNJN  7 FSGNJX  8 FMIN   9 FMAX
//    10 FEQ    11 FLT    12 FLE    13 FCLASS
//   fmt[1:0]：00 = S（32 bit，操作数/结果均按 NaN-boxed 处理）
//             01 = D（64 bit，完整 64 位参与运算）
//   本模块不涉及舍入，故无 rm/frm 端口。
//
// 端口：
//   a, b   : 操作数（直接来自 fregfile 的 64 位视图）
//   result : 写回值 ——
//              · FEQ/FLT/FLE/FCLASS 写**整数**寄存器 ⇒ 低 32 位有效、高 32 位为 0；
//              · FSGNJ*/FMIN/FMAX 写 fregfile ⇒ S 结果高 32 位全 1（NaN-boxed）、
//                D 结果为完整 64 位。
//   fflags : {NV,DZ,OF,UF,NX}，本模块只可能置 NV（DZ/OF/UF/NX 恒 0）。
//==============================================================================
`include "rv32_defs.vh"
`include "core_params.vh"

//==============================================================================
// fpu_cmp_core —— 单格式核心（参数化 W/FB，S 与 D 各例化一次）
//   W  = 32/64（格式位宽），FB = 23/52（尾数位宽）
//   op[3:0]：见 localparam（本文件内部编码，不对外）
//==============================================================================
module fpu_cmp_core #(
    parameter integer W  = 32,
    parameter integer FB = 23
) (
    input  wire [W-1:0] a,
    input  wire [W-1:0] b,
    input  wire [3:0]   op,
    output wire [W-1:0] r,
    output wire [4:0]   fl
);
    localparam integer E = W - FB - 1;                 // 指数域位宽（8 / 11）

    // 内部操作编码（仅本文件使用）
    localparam [3:0] C_FEQ    = 4'd0;
    localparam [3:0] C_FLT    = 4'd1;
    localparam [3:0] C_FLE    = 4'd2;
    localparam [3:0] C_FSGNJ  = 4'd3;
    localparam [3:0] C_FSGNJN = 4'd4;
    localparam [3:0] C_FSGNJX = 4'd5;
    localparam [3:0] C_FMIN   = 4'd6;
    localparam [3:0] C_FMAX   = 4'd7;
    localparam [3:0] C_FCLASS = 4'd8;

    // canonical NaN：符号 0、指数全 1、尾数仅 qNaN 位（S:7FC00000 / D:7FF8000000000000）
    localparam [W-1:0] CANON_NAN = {1'b0, {E{1'b1}}, 1'b1, {(FB-1){1'b0}}};

    //--------------------------------------------------------------------------
    // 类别判定（a 侧）
    //--------------------------------------------------------------------------
    wire            a_sign = a[W-1];
    wire [E-1:0]    a_exp  = a[W-2:FB];                // S:[30:23] / D:[62:52]
    wire [FB-1:0]   a_frac = a[FB-1:0];
    wire            a_exp_all1 = &a_exp;
    wire            a_exp_zero = ~(|a_exp);
    wire            a_frac_zero = ~(|a_frac);
    wire            a_nan  = a_exp_all1 & ~a_frac_zero;
    wire            a_snan = a_nan & ~a[FB-1];         // 尾数最高位为 0 ⇒ signaling
    wire            a_qnan = a_nan &  a[FB-1];
    wire            a_inf  = a_exp_all1 &  a_frac_zero;
    wire            a_zero = a_exp_zero &  a_frac_zero;
    wire            a_sub  = a_exp_zero & ~a_frac_zero;
    wire            a_norm = ~a_exp_all1 & ~a_exp_zero;

    wire            b_sign = b[W-1];
    wire [E-1:0]    b_exp  = b[W-2:FB];
    wire [FB-1:0]   b_frac = b[FB-1:0];
    wire            b_exp_all1 = &b_exp;
    wire            b_exp_zero = ~(|b_exp);
    wire            b_frac_zero = ~(|b_frac);
    wire            b_nan  = b_exp_all1 & ~b_frac_zero;
    wire            b_snan = b_nan & ~b[FB-1];
    wire            b_qnan = b_nan &  b[FB-1];
    wire            b_inf  = b_exp_all1 &  b_frac_zero;
    wire            b_zero = b_exp_zero &  b_frac_zero;
    wire            b_sub  = b_exp_zero & ~b_frac_zero;
    wire            b_norm = ~b_exp_all1 & ~b_exp_zero;

    wire            nan_any   = a_nan | b_nan;
    wire            snan_any  = a_snan | b_snan;
    wire            both_zero = a_zero & b_zero;

    //--------------------------------------------------------------------------
    // 数值序比较（同号时位型无符号比较，异号时符号决定；零与 NaN 单独处理）
    //   同号且非零：正数位型越大数值越大；负数位型越大数值越小
    //--------------------------------------------------------------------------
    wire raw_lt = (a_sign != b_sign) ? a_sign : (a_sign ? (a > b) : (a < b));
    wire eq     = ~nan_any & ((a == b) | both_zero);   // +0 == −0 为真
    wire lt     = ~nan_any & ~both_zero & raw_lt;      // flt(+0,−0) = 0
    wire le     = lt | eq;

    //--------------------------------------------------------------------------
    // fmin / fmax（IEEE 754-2019 minimumNumber / maximumNumber）
    //--------------------------------------------------------------------------
    wire [W-1:0] min_v = a_nan ? (b_nan ? CANON_NAN : b) :            // 双 NaN ⇒ canonical
                         b_nan ? a :                                  // 单 NaN ⇒ 另一数
                         both_zero ? {a_sign | b_sign, {(W-1){1'b0}}} :  // min(+0,−0) = −0（任一为 −0 ⇒ −0）
                                     (raw_lt ? a : b);
    wire [W-1:0] max_v = a_nan ? (b_nan ? CANON_NAN : b) :
                         b_nan ? a :
                         both_zero ? {a_sign & b_sign, {(W-1){1'b0}}} :  // max(+0,−0) = +0（只有两者都是 −0 才是 −0）
                                     (raw_lt ? b : a);
    wire nv_minmax = snan_any;      // 仅 sNaN 置 NV（不是「双 NaN 置 NV」）

    //--------------------------------------------------------------------------
    // fclass：10 bit 掩码（恰好一位为 1）
    //--------------------------------------------------------------------------
    wire [9:0] cls;
    assign cls[0] = a_inf  &  a_sign;      // −∞
    assign cls[1] = a_norm &  a_sign;      // −normal
    assign cls[2] = a_sub  &  a_sign;      // −subnormal
    assign cls[3] = a_zero &  a_sign;      // −0
    assign cls[4] = a_zero & ~a_sign;      // +0
    assign cls[5] = a_sub  & ~a_sign;      // +subnormal
    assign cls[6] = a_norm & ~a_sign;      // +normal
    assign cls[7] = a_inf  & ~a_sign;      // +∞
    assign cls[8] = a_snan;                // signaling NaN
    assign cls[9] = a_qnan;                // quiet NaN

    //--------------------------------------------------------------------------
    // 结果 / flags 选择（纯条件表达式）
    //--------------------------------------------------------------------------
    assign r = (op == C_FEQ)    ? {{(W-1){1'b0}},  eq} :
               (op == C_FLT)    ? {{(W-1){1'b0}},  lt} :
               (op == C_FLE)    ? {{(W-1){1'b0}},  le} :
               (op == C_FSGNJ)  ? {b_sign,          a[W-2:0]} :
               (op == C_FSGNJN) ? {~b_sign,         a[W-2:0]} :
               (op == C_FSGNJX) ? {a_sign ^ b_sign, a[W-2:0]} :
               (op == C_FMIN)   ? min_v :
               (op == C_FMAX)   ? max_v :
               (op == C_FCLASS) ? {{(W-10){1'b0}}, cls} :
                                   {W{1'b0}};          // 未定义 op ⇒ 确定 0

    assign fl = (op == C_FEQ)  ? (snan_any ? 5'b10000 : 5'b00000) :
                (op == C_FLT)  ? (nan_any  ? 5'b10000 : 5'b00000) :
                (op == C_FLE)  ? (nan_any  ? 5'b10000 : 5'b00000) :
                (op == C_FMIN) ? (nv_minmax ? 5'b10000 : 5'b00000) :
                (op == C_FMAX) ? (nv_minmax ? 5'b10000 : 5'b00000) :
                                  5'b00000;   // fsgnj* / fclass 不置 fflags
endmodule

//==============================================================================
// fpu_cmp —— 顶层：fmt 选择 S/D 两个核心，并完成 NaN-boxing 与结果定向
//------------------------------------------------------------------------------
// ★ T4（2026-09-20）：本单元组合很浅（比较/分类），流水化只为**统一全核 FPU
//   潜伏期**：把组合结果经 `fpu_delay(N = 8)` 延迟 LAT 拍后输出 ⇒ 与
//   add/mul/fma/cvt 同为 LAT = 8 拍完成。位级语义一位不变（延迟只改时刻）。
//   `fpu_cmp_core`（单格式核心）保持纯组合、端口不变（单元 TB 仍直接例化它）。
//==============================================================================
module fpu_cmp (
    input  wire        clk,        // ★ T4：统一潜伏期用的流水时钟
    input  wire [6:0]  fp_op,      // 归一化操作码（本模块子集：5..13）
    input  wire [1:0]  fmt,        // 00=S(32b) / 01=D(64b)
    input  wire [63:0] a,          // 操作数（fregfile 64 位视图）
    input  wire [63:0] b,
    output wire [63:0] result,     // 比较/分类 ⇒ 整数结果（高 32 位 0）；fsgnj/min/max ⇒ FP 结果
    output wire [4:0]  fflags      // {NV,DZ,OF,UF,NX}
);
    localparam [6:0] FP_FSGNJ  = 7'd5;
    localparam [6:0] FP_FSGNJN = 7'd6;
    localparam [6:0] FP_FSGNJX = 7'd7;
    localparam [6:0] FP_FMIN   = 7'd8;
    localparam [6:0] FP_FMAX   = 7'd9;
    localparam [6:0] FP_FEQ    = 7'd10;
    localparam [6:0] FP_FLT    = 7'd11;
    localparam [6:0] FP_FLE    = 7'd12;
    localparam [6:0] FP_FCLASS = 7'd13;

    localparam [3:0] C_FEQ    = 4'd0;
    localparam [3:0] C_FLT    = 4'd1;
    localparam [3:0] C_FLE    = 4'd2;
    localparam [3:0] C_FSGNJ  = 4'd3;
    localparam [3:0] C_FSGNJN = 4'd4;
    localparam [3:0] C_FSGNJX = 4'd5;
    localparam [3:0] C_FMIN   = 4'd6;
    localparam [3:0] C_FMAX   = 4'd7;
    localparam [3:0] C_FCLASS = 4'd8;

    wire is_d = (fmt == 2'b01);

    // ---- S 操作数 NaN-boxing 检查：高 32 位不全 1 ⇒ 按 S canonical NaN 处理 ----
    wire [31:0] a_s = (a[63:32] == 32'hFFFF_FFFF) ? a[31:0] : 32'h7FC0_0000;
    wire [31:0] b_s = (b[63:32] == 32'hFFFF_FFFF) ? b[31:0] : 32'h7FC0_0000;

    // ---- op 归一化 ----
    wire [3:0] cop = (fp_op == FP_FEQ)    ? C_FEQ    :
                     (fp_op == FP_FLT)    ? C_FLT    :
                     (fp_op == FP_FLE)    ? C_FLE    :
                     (fp_op == FP_FSGNJ)  ? C_FSGNJ  :
                     (fp_op == FP_FSGNJN) ? C_FSGNJN :
                     (fp_op == FP_FSGNJX) ? C_FSGNJX :
                     (fp_op == FP_FMIN)   ? C_FMIN   :
                     (fp_op == FP_FMAX)   ? C_FMAX   :
                     (fp_op == FP_FCLASS) ? C_FCLASS : 4'd15;

    // ---- 两个格式核心（2A 面积非门禁：以「双核心 + fmt 选择」换取逐位直白）----
    wire [31:0] r_s;
    wire [63:0] r_d;
    wire [4:0]  fl_s, fl_d;

    fpu_cmp_core #(.W(32), .FB(23)) u_cmp_s (
        .a  (a_s), .b (b_s), .op (cop), .r (r_s), .fl (fl_s)
    );
    fpu_cmp_core #(.W(64), .FB(52)) u_cmp_d (
        .a  (a),   .b (b),   .op (cop), .r (r_d), .fl (fl_d)
    );

    // ---- 结果定向：FEQ/FLT/FLE/FCLASS 写整数寄存器（高 32 位补 0）；
    //      FSGNJ*/FMIN/FMAX 写 fregfile（S 结果 NaN-boxed，D 结果完整 64 位）----
    wire int_target = (fp_op == FP_FEQ) | (fp_op == FP_FLT) |
                      (fp_op == FP_FLE) | (fp_op == FP_FCLASS);

    wire [63:0] r_fp  = is_d ? r_d : {32'hFFFF_FFFF, r_s};     // S ⇒ 高 32 位全 1
    wire [63:0] r_int = is_d ? {32'b0, r_d[31:0]} : {32'b0, r_s};

    wire [63:0] r_c = int_target ? r_int : r_fp;
    wire [4:0]  f_c = is_d ? fl_d : fl_s;

    // ---- T4：统一潜伏期（LAT = 8；★ 必须与 fpu.v 的 FPU_SC_LAT 一致）----
    wire [68:0] cmp_d;
    assign cmp_d = {r_c, f_c};
    wire [68:0] cmp_q;
    fpu_delay #(.W(69), .N(8)) u_lat (.clk (clk), .d (cmp_d), .q (cmp_q));

    assign result = cmp_q[68:5];
    assign fflags = cmp_q[4:0];
endmodule
