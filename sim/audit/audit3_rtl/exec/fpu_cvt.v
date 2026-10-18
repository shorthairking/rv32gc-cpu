//==============================================================================
// fpu_cvt.v —— 浮点 ⇄ 整数 / S ⇄ D 转换 + 搬移（fmv.x.w / fmv.w.x / fmv.x.d / fmv.d.x）
//==============================================================================
// 项目  : rv32gc-cpu（2A 单发射顺序 5 级基线核）
// 规格  : docs/design/08-baseline-5stage.md §5.3（fpu_cvt.v 行）
//         IEEE-754-2008 binary32/binary64；RISC-V F/D
//         （riscv-isa-manual/src/unpriv/f-st-ext.adoc:311-341 norm:fcvt；
//          d-st-ext.adoc:24-59 NaN-boxing、:154-168 fcvt.d.s / fcvt.s.d）
//
// 操作码（与 fpu.v / fpu_cmp.v 头注的表逐条一致）：
//   14 FMV_X_W  fmt=00 fmv.x.w / fmt=01 fmv.x.d
//   15 FMV_W_X  fmt=00 fmv.w.x / fmt=01 fmv.d.x
//   16 FCVT_W_S   17 FCVT_WU_S   18 FCVT_S_W   19 FCVT_S_WU
//   20 FCVT_W_D   21 FCVT_WU_D   22 FCVT_D_W   23 FCVT_D_WU
//   24 FCVT_S_D（fmt=00，**目标 S**）   25 FCVT_D_S（fmt=01，**目标 D**）
//
// 语义要点：
//   ① 除 fmv.x.d / fcvt.d.s 外，S 操作数都要做 NaN-boxing 检查（高 32 位不全 1
//      ⇒ 按 S canonical NaN 参与）——本文件用 `a_s` 视图统一处理。
//   ② S 浮点结果写回 fregfile 时高 32 位补 1（NaN-boxing）；整数结果高 32 位补 0。
//   ③ f2i 越界/±∞/NaN ⇒ NV + 饱和（NaN 给正最大）；NX 仅在「未置 NV 且不精确」时置。
//   ④ fcvt.d.s 恒精确、不舍入；fcvt.s.d 按 rm 舍入（可置 NV/OF/UF/NX）。
//   ⑤ fmv.x.w 取 S 视图低 32 位（高 32 位 0）；fmv.w.x 结果 NaN-boxed。
//
// ★ T4（2026-09-20）：分级流水（统一潜伏期 LAT = 8 拍）
//   级1 decode ：操作码/rm 解析 + S/D 视图与类别判别（+ 搬移值与特殊值覆盖预算）
//   级2 prep   ：各转换方向的舍入输入（i2f / s2d / d2s）+ f2i 组合块
//   级3~5      ：三个方向的舍入原语 `fpu_round_pipe`（级A/pre/mid + 组合 post）
//   级6 dispatch：f2i 结果（延迟 2）、搬移值/特殊值覆盖（延迟 4）与舍入结果
//                 按操作码合成完整 result/fflags（**组合**）
//   级7~8 pad  ：把级6 的结果再寄存 2 级 ⇒ 全核 FPU 统一 LAT = 8
//   ★ 位级不变：所有表达式（含 D→S 的 d_tiny 快速通路、S→D 的 NaN/Inf 覆盖、
//     f2i 的饱和/取整）逐字保留；流水化只把同一份组合逻辑按上述边界打拍，
//     并把"末级才需要、但级1 就能算好"的旁带信号用 fpu_delay 精确延迟到级6。
//   ★ 三个舍入实例仍按"只让本次方向活动"的口径把未选中方向的输入钳 0
//     （仿真吞吐优化；语义不变，见下 §②③④ 注释）。
//==============================================================================
`include "rv32_defs.vh"
`include "core_params.vh"

//==============================================================================
// fpu_f2i —— 浮点 → 32 bit 整数（参数化 W/FB；S/D 各例化一次）
//------------------------------------------------------------------------------
//   口径（与重写前逐字一致）：
//     · 有符号/无符号饱和：越界 ⇒ ±(2^31−1)/2^31 或 0/(2^32−1)，并置 NV；
//     · NaN ⇒ 正最大（有符号 0x7FFF_FFFF / 无符号 0xFFFF_FFFF）+ NV；
//     · NX = is_frac & frac_inexact & ~nv（NV 优先）。
//   ★ T4：本模块保持**纯组合、端口不变**（单元 TB 亦直接例化）；流水化由上层
//     把它整体作为"级2"的一拍（其组合锥 = 64 bit 移位 + 比较 + mux，足够浅）。
//==============================================================================
module fpu_f2i_a #(
    parameter integer W  = 32,      // 源格式位宽（32=S / 64=D）
    parameter integer FB = 23       // 源格式尾数位宽（23 / 52）
) (
    input  wire [W-1:0]       a,
    output wire               sign,
    output wire               a_nan,
    output wire               a_inf,
    output wire               oor_big,   // exp2+FB ≥ 32 ⇒ 必然越界
    output wire               is_frac,   // exp2 < 0 ⇒ 小数路径
    output wire               sh_big,    // 右移量 > FB+1 ⇒ 舍入位以下全 0
    output wire [5:0]         sh_c,      // 实际右移量（sh_big 时取 1）
    output wire [5:0]         exp2_lo,   // 整数路径左移量（exp2[5:0]）
    output wire [FB:0]        sig        // 含隐藏位（亚正规隐藏位 0）
);
    localparam integer E    = W - FB - 1;
    localparam integer BIAS = (1 << (E - 1)) - 1;

    localparam signed [15:0] BIAS16 = BIAS;
    localparam signed [15:0] FB16   = FB;
    localparam signed [15:0] EMIN_E = 1 - BIAS;
    localparam [15:0]        SH_LIM = FB + 1;

    wire          sign_w = a[W-1];
    wire [E-1:0]  ef     = a[W-2:FB];
    wire [FB-1:0] fr     = a[FB-1:0];
    wire          a_nan_w = (&ef) & (|fr);
    wire          a_inf_w = (&ef) & ~(|fr);
    wire [FB:0]   sig_w   = (|ef) ? {1'b1, fr} : {1'b0, fr};

    wire signed [15:0] ef_s  = $signed({{(16-E){1'b0}}, ef});
    wire signed [15:0] e_unb = (|ef) ? (ef_s - BIAS16) : EMIN_E;
    wire signed [15:0] exp2  = e_unb - FB16;
    wire               oor_w = ((exp2 + FB16) >= 16'sd32);
    wire               fra_w = (exp2 < 16'sd0);
    wire signed [15:0] nsh   = -exp2;
    wire [15:0]        shraw = nsh[15:0];
    wire               sbig_w = (shraw > SH_LIM);
    wire [5:0]        shc_w  = sbig_w ? 6'd1 : shraw[5:0];

    assign sign    = sign_w;
    assign a_nan   = a_nan_w;
    assign a_inf   = a_inf_w;
    assign oor_big = oor_w;
    assign is_frac = fra_w;
    assign sh_big  = sbig_w;
    assign sh_c    = shc_w;
    assign exp2_lo = exp2[5:0];
    assign sig     = sig_w;
endmodule

//==============================================================================
// fpu_f2i_b —— 第 2 段（纯组合）：两条路径的移位 + 一次舍入判决
//==============================================================================
module fpu_f2i_b #(
    parameter integer FB = 23
) (
    input  wire          sign,
    input  wire          is_frac,
    input  wire          sh_big,
    input  wire [5:0]    sh_c,
    input  wire [5:0]    exp2_lo,
    input  wire [FB:0]   sig,
    input  wire [2:0]    rm,
    output wire [63:0]   n_frac,        // 小数路径：舍入后的幅值
    output wire [63:0]   n_exact,       // 整数路径：精确幅值（oor_big 时无效）
    output wire          frac_inexact
);
    wire [63:0] sig64 = {{(64-(FB+1)){1'b0}}, sig};
    wire [63:0] n_exact_w = sig64 << exp2_lo;          // 仅 !oor_big 时有效
    wire [63:0] q_fr = sh_big ? 64'd0 : (sig64 >> sh_c);
    wire        rb   = sh_big ? 1'b0  : sig64[sh_c - 6'd1];
    wire        st   = sh_big ? (|sig64)
                              : (|(sig64 & ((64'd1 << (sh_c - 6'd1)) - 64'd1)));
    wire        frac_inexact_w = rb | st;
    wire        inc_rne = rb & (st | q_fr[0]);
    wire        inc = (rm == 3'b000) ? inc_rne :            // RNE
                      (rm == 3'b100) ? rb       :            // RMM
                      (rm == 3'b001) ? 1'b0     :            // RTZ
                      (rm == 3'b011) ? ~sign    :            // RUP
                      (rm == 3'b010) ?  sign    :            // RDN
                                        inc_rne;             // 保留 rm ⇒ RNE
    assign n_frac       = q_fr + {63'b0, (frac_inexact_w & inc)};
    assign n_exact      = n_exact_w;
    assign frac_inexact = frac_inexact_w;
endmodule

//==============================================================================
// fpu_f2i_c —— 第 3 段（纯组合）：幅值选择 / 有效域判定 / 饱和 / NX
//==============================================================================
module fpu_f2i_c (
    input  wire [63:0] n_frac,
    input  wire [63:0] n_exact,
    input  wire        is_frac,
    input  wire        oor_big,
    input  wire        sign,
    input  wire        a_nan,
    input  wire        a_inf,
    input  wire        is_unsigned,
    input  wire        frac_inexact,
    output wire [31:0] r,
    output wire [4:0]  fl
);
    wire [63:0] n_mag = is_frac ? n_frac
                                : (oor_big ? 64'hFFFF_FFFF_FFFF_FFFF : n_exact);
    wire [63:0] lim = is_unsigned ? (sign ? 64'h0000_0000_0000_0000 : 64'h0000_0000_FFFF_FFFF)
                                  : (sign ? 64'h0000_0000_8000_0000 : 64'h0000_0000_7FFF_FFFF);
    wire        in_range = (n_mag <= lim);

    wire nv = a_nan | a_inf | ~in_range;
    wire nx = is_frac & frac_inexact & ~nv;

    wire [31:0] pos_max = is_unsigned ? 32'hFFFF_FFFF : 32'h7FFF_FFFF;
    wire [31:0] neg_sat = is_unsigned ? 32'h0000_0000 : 32'h8000_0000;
    wire [31:0] mag32   = n_mag[31:0];
    wire [31:0] sat_r   = a_nan ? pos_max : (sign ? neg_sat : pos_max);

    assign r  = nv ? sat_r : (sign ? (~mag32 + 32'd1) : mag32);
    assign fl = {nv, 1'b0, 1'b0, 1'b0, nx};
endmodule

//==============================================================================
// fpu_f2i —— 浮点 → 32 bit 整数（**三段直连的组合参考形式**；零例化）
//------------------------------------------------------------------------------
//   口径（与重写前逐字一致）：
//     · 有符号/无符号饱和：越界 ⇒ ±(2^31−1)/2^31 或 0/(2^32−1)，并置 NV；
//     · NaN ⇒ 正最大（有符号 0x7FFF_FFFF / 无符号 0xFFFF_FFFF）+ NV；
//     · NX = is_frac & frac_inexact & ~nv（NV 优先）。
//   ★ T4：本模块 = fpu_f2i_a → b → c 三段**直连**（与重写前逐字等价）。
//     实际流水由 fpu_cvt 在三段之间插寄存器（见 fpu_cvt 的级 2/3/4）。
//==============================================================================
module fpu_f2i #(
    parameter integer W  = 32,
    parameter integer FB = 23
) (
    input  wire [W-1:0] a,
    input  wire [2:0]   rm,
    input  wire         is_unsigned,
    output wire [31:0]  r,
    output wire [4:0]   fl
);
    wire        sign, a_nan, a_inf, oor_big, is_frac, sh_big;
    wire [5:0]  sh_c, exp2_lo;
    wire [FB:0] sig;
    wire [63:0] n_frac, n_exact;
    wire        frac_inexact;

    fpu_f2i_a #(.W(W), .FB(FB)) u_a (
        .a (a), .sign (sign), .a_nan (a_nan), .a_inf (a_inf),
        .oor_big (oor_big), .is_frac (is_frac), .sh_big (sh_big),
        .sh_c (sh_c), .exp2_lo (exp2_lo), .sig (sig)
    );
    fpu_f2i_b #(.FB(FB)) u_b (
        .sign (sign), .is_frac (is_frac), .sh_big (sh_big), .sh_c (sh_c),
        .exp2_lo (exp2_lo), .sig (sig), .rm (rm),
        .n_frac (n_frac), .n_exact (n_exact), .frac_inexact (frac_inexact)
    );
    fpu_f2i_c u_c (
        .n_frac (n_frac), .n_exact (n_exact), .is_frac (is_frac),
        .oor_big (oor_big), .sign (sign), .a_nan (a_nan), .a_inf (a_inf),
        .is_unsigned (is_unsigned), .frac_inexact (frac_inexact),
        .r (r), .fl (fl)
    );
endmodule

//==============================================================================
// fpu_cvt —— 顶层：op 分发 + S 操作数 NaN-boxing + S 结果 NaN-boxing（T4：8 级流水）
//==============================================================================
module fpu_cvt (
    input  wire        clk,        // ★ T4：统一潜伏期用的流水时钟
    input  wire        spec_gate,  // ★ T4：= 本拍有一条指令被 fpu.v 接收（输入钳零门控）
    input  wire [6:0]  fp_op,      // 归一化操作码（本模块子集：14..25）
    input  wire [1:0]  fmt,        // 目标格式：00=S / 01=D（fmv 时选 W/D 变体）
    input  wire [2:0]  rm,         // 指令 rm 域（111=DYN）
    input  wire [2:0]  frm,        // fcsr.frm
    input  wire [63:0] a,          // 源操作数（浮点位型或整数）
    output wire [63:0] result,     // 写回值（见头注）
    output wire [4:0]  fflags      // {NV,DZ,OF,UF,NX}
);
    // ---- 操作码 ----
    localparam [6:0] FP_FMV_X   = 7'd14;
    localparam [6:0] FP_FMV_W_X = 7'd15;
    localparam [6:0] FP_FCVT_W_S  = 7'd16;
    localparam [6:0] FP_FCVT_WU_S = 7'd17;
    localparam [6:0] FP_FCVT_S_W  = 7'd18;
    localparam [6:0] FP_FCVT_S_WU = 7'd19;
    localparam [6:0] FP_FCVT_W_D  = 7'd20;
    localparam [6:0] FP_FCVT_WU_D = 7'd21;
    localparam [6:0] FP_FCVT_D_W  = 7'd22;
    localparam [6:0] FP_FCVT_D_WU = 7'd23;
    localparam [6:0] FP_FCVT_S_D  = 7'd24;
    localparam [6:0] FP_FCVT_D_S  = 7'd25;

    // S/D canonical NaN
    localparam [31:0] CANON_S = 32'h7FC0_0000;
    localparam [63:0] CANON_D = 64'h7FF8_0000_0000_0000;
    localparam [31:0] BOX_HI  = 32'hFFFF_FFFF;

    localparam integer LAT = 8;    // ★ 必须与 fpu.v 的 FPU_SC_LAT 一致

    //==========================================================================
    // 级 1（组合）：操作码/rm 解析 + S/D 视图 + 类别判别 + 搬移/特殊值预算
    //==========================================================================
    // ---- 舍入模式解析：DYN 取 frm；保留值（101/110/111）按 RNE ----
    wire [2:0] rm_eff = (rm == `RV32GC_RM_DYN)
                            ? (((frm == 3'b101) | (frm == 3'b110) | (frm == 3'b111))
                                   ? `RV32GC_RM_RNE : frm)
                            : (((rm == 3'b101) | (rm == 3'b110)) ? `RV32GC_RM_RNE : rm);

    // ---- S 视图（NaN-boxing 检查，用于所有非 transfer 的 S 操作数读取）----
    wire [31:0] a_s = (a[63:32] == BOX_HI) ? a[31:0] : CANON_S;

    wire        s_sign = a_s[31];
    wire [7:0]  s_ef   = a_s[30:23];
    wire [22:0] s_fr   = a_s[22:0];
    wire        s_nan  = (&s_ef) & (|s_fr);
    wire        s_snan = s_nan & ~a_s[22];
    wire        s_inf  = (&s_ef) & ~(|s_fr);

    // ---- D 视图（fcvt.s.d 的源；D 是 FLEN 宽，无 NaN-boxing 检查）----
    wire        d_sign = a[63];
    wire [10:0] d_ef   = a[62:52];
    wire [51:0] d_fr   = a[51:0];
    wire        d_nan  = (&d_ef) & (|d_fr);
    wire        d_snan = d_nan & ~a[51];
    wire        d_inf  = (&d_ef) & ~(|d_fr);

    // ---- ①②③④ 的方向使能（未选中方向输入钳 0：仿真吞吐优化，语义不变）----
    wire f2i_uns = (fp_op == FP_FCVT_WU_S) | (fp_op == FP_FCVT_WU_D);
    wire en_f2i_s = (fp_op == FP_FCVT_W_S)  | (fp_op == FP_FCVT_WU_S);
    wire en_f2i_d = (fp_op == FP_FCVT_W_D)  | (fp_op == FP_FCVT_WU_D);
    wire en_i2s = (fp_op == FP_FCVT_S_W)  | (fp_op == FP_FCVT_S_WU);
    wire en_i2d = (fp_op == FP_FCVT_D_W)  | (fp_op == FP_FCVT_D_WU);
    wire en_s2d = (fp_op == FP_FCVT_D_S);
    wire en_d2s = (fp_op == FP_FCVT_S_D);
    wire i2f_uns  = (fp_op == FP_FCVT_S_WU) | (fp_op == FP_FCVT_D_WU);
    wire fmt_d    = (fmt == 2'b01);
    wire is_mvx   = (fp_op == FP_FMV_X);
    wire is_mvwx  = (fp_op == FP_FMV_W_X);

    // 整数源（fmv.w.x 等）：x_mag 为有符号幅值（0x8000_0000 → 0x8000_0000）
    wire [31:0] x_w      = a[31:0];
    wire [31:0] x_mag_s  = x_w[31] ? (~x_w + 32'd1) : x_w;
    wire        i2f_sign = i2f_uns ? 1'b0 : x_w[31];
    wire [31:0] i2f_mag  = i2f_uns ? x_w  : x_mag_s;

    // ---- ③ fcvt.d.s（S → D，恒精确、不舍入、只可能置 NV）----
    wire [23:0] s_sig = (|s_ef) ? {1'b1, s_fr} : {1'b0, s_fr};
    wire signed [15:0] s_e = (|s_ef) ? ($signed({8'b0, s_ef}) - 16'sd150)
                                     : -16'sd149;               // value = s_sig × 2^s_e
    // ---- ④ fcvt.s.d（D → S，按 rm 舍入，可置 NV/OF/UF/NX）----
    wire [52:0] d_sig = (|d_ef) ? {1'b1, d_fr} : {1'b0, d_fr};
    wire signed [15:0] d_e = (|d_ef) ? ($signed({5'b0, d_ef}) - 16'sd1075)
                                     : -16'sd1074;              // value = d_sig × 2^d_e
    //   极小数快速路径（见下方 §④ 注释；语义与通用通路逐位等价）
    wire d_tiny = (d_e < -16'sd600);
    wire d_zero = ~(|d_sig);

    // ---- 结果类别编码（级 1 定，随流水携带到级 6 的 dispatch mux）----
    localparam [3:0] RC_NONE = 4'd0, RC_F2IS = 4'd1, RC_F2ID = 4'd2,
                     RC_I2S  = 4'd3, RC_I2D  = 4'd4, RC_SD   = 4'd5,
                     RC_DS   = 4'd6, RC_MVX  = 4'd7, RC_MVWX = 4'd8;
    wire [3:0] rclass = (fp_op == FP_FCVT_W_S)  ? RC_F2IS :
                        (fp_op == FP_FCVT_WU_S) ? RC_F2IS :
                        (fp_op == FP_FCVT_W_D)  ? RC_F2ID :
                        (fp_op == FP_FCVT_WU_D) ? RC_F2ID :
                        (fp_op == FP_FCVT_S_W)  ? RC_I2S  :
                        (fp_op == FP_FCVT_S_WU) ? RC_I2S  :
                        (fp_op == FP_FCVT_D_W)  ? RC_I2D  :
                        (fp_op == FP_FCVT_D_WU) ? RC_I2D  :
                        (fp_op == FP_FCVT_S_D)  ? RC_SD   :
                        (fp_op == FP_FCVT_D_S)  ? RC_DS   :
                        is_mvx                  ? RC_MVX  :
                        is_mvwx                 ? RC_MVWX : RC_NONE;

    // ---- 搬移值（级 1 定值；fmv 与 fflags=0）----
    wire [63:0] mv_r = is_mvx  ? (fmt_d ? a : {32'b0, a[31:0]}) :
                       is_mvwx ? (fmt_d ? a : {BOX_HI, a[31:0]}) : 64'b0;

    // ---- 特殊值覆盖（级 1 定值）：③ 的 NaN/Inf、④ 的 NaN/Inf/tiny ----
    //   ③ ds：s_nan ⇒ CANON_D（sNaN 置 NV）；s_inf ⇒ 带符号 Inf
    //   ④ sd：d_nan ⇒ CANON_S（sNaN 置 NV）；d_inf ⇒ 带符号 Inf；d_tiny ⇒ ±0/±2^-149
    //     极小数：舍入位=0、sticky=1 ⇒ 仅 RUP/RDN 会给出最小亚正规 ±2^-149
    //     ★ 例外：D 值**恰好为 ±0** 时转换精确 ⇒ 结果就是同号 0、不置任何 flags
    wire        tiny_inc = (rm_eff == 3'b011) ? ~d_sign :            // RUP
                           (rm_eff == 3'b010) ?  d_sign :            // RDN
                                                 1'b0;               // RNE/RMM/RTZ 及保留值
    wire [31:0] tiny_r = (d_zero | ~tiny_inc) ? {d_sign, 31'd0}
                                              : {d_sign, 8'd0, 23'd1};
    wire [4:0]  tiny_fl = d_zero ? 5'b00000 : 5'b00011;              // UF|NX

    wire sel_ds_ov = (fp_op == FP_FCVT_D_S);
    wire sel_sd_ov = (fp_op == FP_FCVT_S_D);
    wire ov_e = (sel_ds_ov & (s_nan | s_inf)) |
                (sel_sd_ov & (d_nan | d_inf | d_tiny));
    wire [63:0] ov_r = sel_ds_ov ? (s_nan ? CANON_D : {s_sign, 11'h7FF, 52'd0}) :
                       sel_sd_ov ? (d_nan ? CANON_S :
                                    d_inf ? {d_sign, 8'hFF, 23'd0} : tiny_r) :
                                   64'b0;
    wire [4:0]  ov_f = sel_ds_ov ? (s_nan ? (s_snan ? 5'b10000 : 5'b00000) : 5'b00000) :
                       sel_sd_ov ? (d_nan ? (d_snan ? 5'b10000 : 5'b00000) :
                                    d_inf ? 5'b00000 : tiny_fl) :
                                   5'b00000;

    //==========================================================================
    // 级 1 寄存器（R1）：decode 之后的全部常量与操作数
    //==========================================================================
    reg [63:0] r1_a;
    reg [31:0] r1_a_s;                  // ★ S 视图（NaN-boxing 检查后）——f2i_s 用
    reg [2:0]  r1_rm;
    reg        r1_f2i_uns, r1_en_f2i_s, r1_en_f2i_d, r1_en_i2s, r1_en_i2d, r1_i2f_sign;
    reg [31:0] r1_i2f_mag;
    reg [23:0] r1_s_sig;
    reg signed [15:0] r1_s_e;
    reg        r1_s_sign;
    reg [52:0] r1_d_sig;
    reg signed [15:0] r1_d_e;
    reg        r1_d_sign, r1_d_tiny, r1_d_zero, r1_tiny_inc;
    reg [3:0]  r1_rclass;
    reg        r1_en_s2d_d, r1_en_d2s_d;
    always @(posedge clk) begin
        r1_a <= a;
        r1_a_s <= a_s;
        r1_rm <= rm_eff;
        r1_f2i_uns <= f2i_uns;
        r1_en_f2i_s <= en_f2i_s; r1_en_f2i_d <= en_f2i_d;
        r1_en_i2s <= en_i2s;   r1_en_i2d <= en_i2d;
        r1_i2f_sign <= i2f_sign; r1_i2f_mag <= i2f_mag;
        r1_s_sig <= s_sig; r1_s_e <= s_e; r1_s_sign <= s_sign;
        r1_d_sig <= d_sig; r1_d_e <= d_e; r1_d_sign <= d_sign;
        r1_d_tiny <= d_tiny; r1_d_zero <= d_zero; r1_tiny_inc <= tiny_inc;
        r1_rclass <= rclass;
        // 只看选择位：把选择位本身也寄存（用于级 2 的输入钳零）
        r1_en_s2d_d <= (fp_op == FP_FCVT_D_S) & ~(s_nan | s_inf);
        r1_en_d2s_d <= (fp_op == FP_FCVT_S_D) & ~(d_nan | d_inf | d_tiny);
    end

    //==========================================================================
    // 级 2（组合）：各方向舍入输入（直接进 fpu_round_pipe 的级 A）+ f2i 组合块
    //==========================================================================
    // ①② 整数 → 浮点：sig = |x|（≤ 2^32，直接就是精确窗口）、sticky_in = 0、
    //    exp = 0（值 = sig × 2^0 = |x|，无对阶、无截断）
    wire [31:0] i2f_sig   = r1_en_i2s ? r1_i2f_mag : 32'd0;
    wire [31:0] i2f_sig_d = r1_en_i2d ? r1_i2f_mag : 32'd0;
    // ③ S → D：24 bit 精确窗口
    wire [23:0] s_sig_x = r1_en_s2d_d ? r1_s_sig : 24'd0;
    // ④ D → S：53 bit 精确窗口
    wire [52:0] d_sig_x = r1_en_d2s_d ? r1_d_sig : 53'd0;

    // ①② 浮点 → 整数（T4 第 2 轮：拆成 a/b/c **三段流水**，两格式各一份；未选中钳 0）
    //   T3/首轮实测：单段 48 级、18.85 ns（−2.714 ns）是全核最差锥 ⇒ 三段后每段 ≈16 级。
    //   段边界：a = 字段/指数/移位量；b = 两条路径的移位 + 舍入判决；c = 有效域/饱和/NX。
    wire        w_sa_sign, w_sa_nan, w_sa_inf, w_sa_oor, w_sa_frac, w_sa_sbig;
    wire [5:0]  w_sa_shc, w_sa_e2lo;
    wire [23:0] w_sa_sig;
    fpu_f2i_a #(.W(32), .FB(23)) u_f2i_a_s (
        .a (r1_en_f2i_s ? r1_a_s : 32'd0),
        .sign (w_sa_sign), .a_nan (w_sa_nan), .a_inf (w_sa_inf),
        .oor_big (w_sa_oor), .is_frac (w_sa_frac), .sh_big (w_sa_sbig),
        .sh_c (w_sa_shc), .exp2_lo (w_sa_e2lo), .sig (w_sa_sig)
    );
    wire        w_da_sign, w_da_nan, w_da_inf, w_da_oor, w_da_frac, w_da_sbig;
    wire [5:0]  w_da_shc, w_da_e2lo;
    wire [52:0] w_da_sig;
    fpu_f2i_a #(.W(64), .FB(52)) u_f2i_a_d (
        .a (r1_en_f2i_d ? r1_a : 64'd0),
        .sign (w_da_sign), .a_nan (w_da_nan), .a_inf (w_da_inf),
        .oor_big (w_da_oor), .is_frac (w_da_frac), .sh_big (w_da_sbig),
        .sh_c (w_da_shc), .exp2_lo (w_da_e2lo), .sig (w_da_sig)
    );

    // ---- 级 3 寄存器（R2 = f2i_a 输出）----
    reg        r2_sa_sign, r2_sa_nan, r2_sa_inf, r2_sa_oor, r2_sa_frac, r2_sa_sbig;
    reg [5:0]  r2_sa_shc, r2_sa_e2lo;
    reg [23:0] r2_sa_sig;
    reg        r2_da_sign, r2_da_nan, r2_da_inf, r2_da_oor, r2_da_frac, r2_da_sbig;
    reg [5:0]  r2_da_shc, r2_da_e2lo;
    reg [52:0] r2_da_sig;
    always @(posedge clk) begin
        r2_sa_sign <= w_sa_sign; r2_sa_nan <= w_sa_nan; r2_sa_inf <= w_sa_inf;
        r2_sa_oor <= w_sa_oor;   r2_sa_frac <= w_sa_frac; r2_sa_sbig <= w_sa_sbig;
        r2_sa_shc <= w_sa_shc;   r2_sa_e2lo <= w_sa_e2lo; r2_sa_sig <= w_sa_sig;
        r2_da_sign <= w_da_sign; r2_da_nan <= w_da_nan; r2_da_inf <= w_da_inf;
        r2_da_oor <= w_da_oor;   r2_da_frac <= w_da_frac; r2_da_sbig <= w_da_sbig;
        r2_da_shc <= w_da_shc;   r2_da_e2lo <= w_da_e2lo; r2_da_sig <= w_da_sig;
    end

    // ---- f2i_b（组合）→ 级 4 寄存器（R3）----
    wire [63:0] w_sb_nfrac, w_sb_nexact, w_db_nfrac, w_db_nexact;
    wire        w_sb_finx, w_db_finx;
    fpu_f2i_b #(.FB(23)) u_f2i_b_s (
        .sign (r2_sa_sign), .is_frac (r2_sa_frac), .sh_big (r2_sa_sbig),
        .sh_c (r2_sa_shc), .exp2_lo (r2_sa_e2lo), .sig (r2_sa_sig), .rm (r2_f2i_rm),
        .n_frac (w_sb_nfrac), .n_exact (w_sb_nexact), .frac_inexact (w_sb_finx)
    );
    fpu_f2i_b #(.FB(52)) u_f2i_b_d (
        .sign (r2_da_sign), .is_frac (r2_da_frac), .sh_big (r2_da_sbig),
        .sh_c (r2_da_shc), .exp2_lo (r2_da_e2lo), .sig (r2_da_sig), .rm (r2_f2i_rm),
        .n_frac (w_db_nfrac), .n_exact (w_db_nexact), .frac_inexact (w_db_finx)
    );
    //   ★ rm / is_unsigned 是"第 0 级即定值"，但**必须随流水携带**：
    //     f2i_b 在级 3 用 rm、f2i_c 在级 5 用 is_unsigned；背靠背派发时 r1_* 会在
    //     下一拍被后一条指令覆盖 ⇒ 直接读 r1_* 会取错。故 R2 存 rm、R3 存 is_unsigned。
    reg [2:0]  r2_f2i_rm;
    reg        r2_f2i_uns, r3_f2i_uns;
    reg [63:0] r3_sb_nfrac, r3_sb_nexact, r3_db_nfrac, r3_db_nexact;
    reg        r3_sb_finx, r3_db_finx;
    reg        r3_sb_sign, r3_sb_nan, r3_sb_inf, r3_sb_oor, r3_sb_frac;
    reg        r3_db_sign, r3_db_nan, r3_db_inf, r3_db_oor, r3_db_frac;
    always @(posedge clk) begin
        r2_f2i_rm <= r1_rm; r2_f2i_uns <= r1_f2i_uns; r3_f2i_uns <= r2_f2i_uns;
        r3_sb_nfrac <= w_sb_nfrac; r3_sb_nexact <= w_sb_nexact; r3_sb_finx <= w_sb_finx;
        r3_db_nfrac <= w_db_nfrac; r3_db_nexact <= w_db_nexact; r3_db_finx <= w_db_finx;
        r3_sb_sign <= r2_sa_sign; r3_sb_nan <= r2_sa_nan; r3_sb_inf <= r2_sa_inf;
        r3_sb_oor <= r2_sa_oor;   r3_sb_frac <= r2_sa_frac;
        r3_db_sign <= r2_da_sign; r3_db_nan <= r2_da_nan; r3_db_inf <= r2_da_inf;
        r3_db_oor <= r2_da_oor;   r3_db_frac <= r2_da_frac;
    end

    // ---- f2i_c（组合）→ 级 5 寄存器（R4）：级 5 与"级 1 的 dispatch mux"同一拍 ----
    wire [31:0] w_f2i_s, w_f2i_d;
    wire [4:0]  w_fl_f2i_s, w_fl_f2i_d;
    fpu_f2i_c u_f2i_c_s (
        .n_frac (r3_sb_nfrac), .n_exact (r3_sb_nexact), .is_frac (r3_sb_frac),
        .oor_big (r3_sb_oor), .sign (r3_sb_sign), .a_nan (r3_sb_nan),
        .a_inf (r3_sb_inf), .is_unsigned (r3_f2i_uns), .frac_inexact (r3_sb_finx),
        .r (w_f2i_s), .fl (w_fl_f2i_s)
    );
    fpu_f2i_c u_f2i_c_d (
        .n_frac (r3_db_nfrac), .n_exact (r3_db_nexact), .is_frac (r3_db_frac),
        .oor_big (r3_db_oor), .sign (r3_db_sign), .a_nan (r3_db_nan),
        .a_inf (r3_db_inf), .is_unsigned (r3_f2i_uns), .frac_inexact (r3_db_finx),
        .r (w_f2i_d), .fl (w_fl_f2i_d)
    );

    //==========================================================================
    // 级 2~5 的三个舍入实例（每个 = 级A/pre/mid + 组合 post）
    //==========================================================================
    wire [31:0] w_r_i2s, w_r_sd_raw;
    wire [63:0] w_r_i2d, w_r_ds_raw;
    wire [4:0]  w_fl_i2s, w_fl_i2d, w_fl_sd_raw, w_fl_ds_raw;

    fpu_round_pipe #(.FB(23), .WW(32), .RW(32), .EB(8),
                     .MIN_SUB(-149), .E_MAXF(255), .BIAS(127)) u_i2s (
        .clk (clk), .sign (r1_i2f_sign), .sig (i2f_sig), .sticky_in (1'b0),
        .exp (16'sd0), .rm (r1_rm), .result (w_r_i2s), .fflags (w_fl_i2s)
    );
    fpu_round_pipe #(.FB(52), .WW(32), .RW(64), .EB(11),
                     .MIN_SUB(-1074), .E_MAXF(2047), .BIAS(1023)) u_i2d (
        .clk (clk), .sign (r1_i2f_sign), .sig (i2f_sig_d), .sticky_in (1'b0),
        .exp (16'sd0), .rm (r1_rm), .result (w_r_i2d), .fflags (w_fl_i2d)
    );
    fpu_round_pipe #(.FB(52), .WW(24), .RW(64), .EB(11),
                     .MIN_SUB(-1074), .E_MAXF(2047), .BIAS(1023)) u_s2d (
        .clk (clk), .sign (r1_s_sign), .sig (s_sig_x), .sticky_in (1'b0),
        .exp (r1_s_e), .rm (r1_rm), .result (w_r_ds_raw), .fflags (w_fl_ds_raw)
    );
    fpu_round_pipe #(.FB(23), .WW(53), .RW(32), .EB(8),
                     .MIN_SUB(-149), .E_MAXF(255), .BIAS(127)) u_d2s (
        .clk (clk), .sign (r1_d_sign), .sig (d_sig_x), .sticky_in (1'b0),
        .exp (r1_d_e), .rm (r1_rm), .result (w_r_sd_raw), .fflags (w_fl_sd_raw)
    );

    //==========================================================================
    // 级 5 寄存器（R4）：f2i_c 结果 —— 与级 5 dispatch mux 同一拍（无需再延迟）
    //==========================================================================
    reg [31:0] r4_f2i_s, r4_f2i_d;
    reg [4:0]  r4_fl_f2i_s, r4_fl_f2i_d;
    always @(posedge clk) begin
        r4_f2i_s <= w_f2i_s; r4_f2i_d <= w_f2i_d;
        r4_fl_f2i_s <= w_fl_f2i_s; r4_fl_f2i_d <= w_fl_f2i_d;
    end

    //==========================================================================
    // 旁带延迟：搬移值 + 特殊值覆盖 + 类别（级 1 定值 ⇒ 延迟 LAT-4 到级 6）
    //==========================================================================
    wire [63:0] mv_q, ov_r_q;
    wire [4:0]  ov_f_q;
    wire [3:0]  rclass_q;
    wire        ov_e_q;

    //   ★ 级 1 的 mv/ov 在**第 0 拍**（派发拍）就是终值 ⇒ 延迟 4 拍到级 6
    //   ★ 延迟线的**输入必须与"本拍真有指令被接收"相与**（T4 仿真吞吐修复，与
    //     fpu.v §5 的子单元输入钳零同一口径）：否则非 FP 指令期间 fp_op 字段的
    //     任意位型会让这几条 70 bit 延迟线**每拍跟着取指结果翻转** ⇒ iverilog
    //     回归吞吐明显下降（实测 tb_m3_ddr3）。与门控相与后空闲期恒 0 ⇒ 静止。
    //     语义不变：延迟线的输出只在 done 拍被消费，而 done 拍的必要条件是派发拍
    //     的 gate=1。
    wire       cvt_gate = spec_gate;
    wire [63:0] mv_d  = cvt_gate ? mv_r  : 64'd0;
    wire [63:0] ovr_d = cvt_gate ? ov_r  : 64'd0;
    wire [4:0]  ovf_d = cvt_gate ? ov_f  : 5'd0;
    wire        ove_d = cvt_gate ? ov_e  : 1'b0;
    wire [3:0]  rcl_d = cvt_gate ? rclass: 4'd0;
    fpu_delay #(.W(64), .N(4)) u_mvd  (.clk (clk), .d (mv_d),  .q (mv_q));
    fpu_delay #(.W(64), .N(4)) u_ovrd (.clk (clk), .d (ovr_d), .q (ov_r_q));
    fpu_delay #(.W(5),  .N(4)) u_ovfd (.clk (clk), .d (ovf_d), .q (ov_f_q));
    fpu_delay #(.W(1),  .N(4)) u_oved (.clk (clk), .d (ove_d), .q (ov_e_q));
    fpu_delay #(.W(4),  .N(4)) u_rcd  (.clk (clk), .d (rcl_d), .q (rclass_q));

    //==========================================================================
    // 级 6（组合）：dispatch mux（舍入结果 + f2i + 搬移 + 特殊值覆盖）
    //==========================================================================
    // 各方向的"最终值"（含 ③④ 的 NaN/Inf 覆盖，逐字对应原 ds_r/sd_r）
    wire [63:0] ds_r = (rclass_q == RC_DS) ? (ov_e_q ? ov_r_q : w_r_ds_raw) : 64'b0;
    wire [4:0]  ds_fl = (rclass_q == RC_DS) ? (ov_e_q ? ov_f_q : w_fl_ds_raw) : 5'b0;
    wire [31:0] sd_raw_r = ov_e_q ? ov_r_q[31:0] : w_r_sd_raw;
    wire [4:0]  sd_raw_fl = ov_e_q ? ov_f_q : w_fl_sd_raw;

    wire [63:0] r_sd_boxed  = {BOX_HI, sd_raw_r};
    wire [63:0] r_i2s_boxed = {BOX_HI, w_r_i2s};

    assign r_disp =
        (rclass_q == RC_F2IS) ? {32'b0, r4_f2i_s} :
        (rclass_q == RC_F2ID) ? {32'b0, r4_f2i_d} :
        (rclass_q == RC_I2S)  ? r_i2s_boxed :
        (rclass_q == RC_I2D)  ? w_r_i2d :
        (rclass_q == RC_SD)   ? r_sd_boxed :
        (rclass_q == RC_DS)   ? ds_r :
        (rclass_q == RC_MVX)  ? mv_q :
        (rclass_q == RC_MVWX) ? mv_q :
                                64'b0;              // 未定义 op ⇒ 确定 0

    wire [4:0] fl_sel =
        (rclass_q == RC_F2IS) ? r4_fl_f2i_s :
        (rclass_q == RC_F2ID) ? r4_fl_f2i_d :
        (rclass_q == RC_I2S)  ? w_fl_i2s :
        (rclass_q == RC_I2D)  ? w_fl_i2d :
        (rclass_q == RC_SD)   ? sd_raw_fl :
        (rclass_q == RC_DS)   ? ds_fl :
                                5'b00000;           // fmv.* 不置 fflags

    //==========================================================================
    // 级 7~8（pad）：把级 6 的结果再寄存 4 级 ⇒ LAT = 8（与全核 FPU 统一）
    //   级 6（dispatch mux 的输出）在第 4 拍有效 ⇒ 延迟 4 拍后第 8 拍输出。
    //==========================================================================
    wire [63:0] r_disp;
    wire [68:0] res_d;
    assign res_d = {r_disp, fl_sel};
    wire [68:0] res_q;
    fpu_delay #(.W(69), .N(4)) u_pad (.clk (clk), .d (res_d), .q (res_q));

    assign result = res_q[68:5];
    assign fflags = res_q[4:0];
endmodule
