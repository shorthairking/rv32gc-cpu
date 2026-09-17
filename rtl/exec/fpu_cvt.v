//==============================================================================
// rtl/exec/fpu_cvt.v —— FPU 转换/搬移（fcvt 全套 + fmv 全套，F/D 双格式，纯组合）
//==============================================================================
// 项目  : rv32gc-cpu（2A 单发射顺序 5 级基线核）
// 规格  : docs/design/08-baseline-5stage.md §5.3（FPU 行）；INTERFACE.md（端口契约）
//         riscv-isa-manual/src/unpriv/f-st-ext.adoc / d-st-ext.adoc（逐条对照见下）
//
// 覆盖指令（归一化 fp_op[6:0]）：
//   fcvt.w.s  fcvt.wu.s  fcvt.s.w  fcvt.s.wu
//   fcvt.w.d  fcvt.wu.d  fcvt.d.w  fcvt.d.wu
//   fcvt.s.d  fcvt.d.s
//   fmv.x.w   fmv.w.x    fmv.x.d   fmv.d.x
//
// 语义要点（每条给规范出处）：
//   ① 浮点→整数：按 rm 舍入；**有效输入域按「舍入后」的值判定**
//      （f-st-ext.adoc:344-361 <<int_conv>> 表：fcvt.w.s 最小 −2^31 / 最大 2^31−1；
//        fcvt.wu.s 最小 0 / 最大 2^32−1）。
//      越界/±∞/NaN ⇒ 置 NV 并饱和：正侧 → 2^31−1（无符号 2^32−1），
//      负侧 → −2^31（无符号 0）；**NaN 一律给正的最大值**（表中「+∞ or NaN」行）。
//   ② NX：只有当结果「不在范围而置 NV」以外的情形、且舍入结果≠原值时才置
//      （f-st-ext.adoc:363-366 norm:fcvt_nx：「…and the Invalid exception flag is not set」）。
//      ⇒ 浮点→整数**可以**置 NX（例如 fcvt.w.s(1.5, RTZ) = 1 且 NX=1）；
//        越界/NaN/±∞ 只置 NV，不置 NX。
//      ⇒ 整数→浮点只有 NX（|x| ≤ 2^31 < 2^53 且 S 侧可能不精确）。
//      与 arch-test 覆盖点一致：F_fcvt_w_s_cg 用 cp_csr_fflags_vn（NV/NX），
//      F_fcvt_s_w_cg 用 cp_csr_fflags_n（仅 NX）（coverpoints/norm/F.yaml:160-240）。
//   ③ fcvt.d.w / fcvt.d.wu **恒精确、与舍入模式无关**（d-st-ext.adoc:147-148）；
//      fcvt.d.s **不舍入**（d-st-ext.adoc:161-162）；fcvt.s.d 按 rm 舍入
//      （会置 OF/UF/NX，见 D_fcvt_s_d_cg 的 cp_csr_fflags_voun）。
//   ④ NaN-boxing（d-st-ext.adoc:24-59）：
//      · 非 transfer 指令的 S 操作数高 32 位不全 1 ⇒ 按 S canonical NaN 处理
//        （fcvt.w.s、fcvt.d.s 均适用）；
//      · S 结果写回 fregfile 的 64 位视图时高 32 位必须全 1
//        （fcvt.s.w/fcvt.s.wu/fcvt.s.d/fmv.w.x）；
//      · fcvt.s.d 的 D 结果是完整 64 位，不补 1；fcvt.d.s 同理。
//   ⑤ NaN 结果一律 canonical NaN（f-st-ext.adoc:136-139）；含 sNaN ⇒ NV
//      （f-st-ext.adoc:173-178 F_canonical_NaN；d-st-ext.adoc:11-14 D_canonical_NaN）。
//   ⑥ fmv.x.w / fmv.w.x / fmv.x.d / fmv.d.x 是 **transfer**：不检查 NaN-boxing、
//      不置任何 fflags、位不变（f-st-ext.adoc:401-414；d-st-ext.adoc:176-186）。
//      fmv.w.x 写入窄值 ⇒ 按 d-st-ext.adoc:45-47 norm:FP_transfer_instrs_narrow_transfer_in
//      必须产生合法 NaN-boxed 值（高 32 位全 1）。
//
// ★ 舍入原语复用：整数→浮点方向直接把 (sign, sig=|x|, exp=0) 喂给 fpu_add.v 里的
//   fpu_round_s / fpu_round_d（其 ulp 恰为格式 ulp）；D→S、S→D 方向把原格式的
//   (sign, sig, exp) 喂进去（S→D 恒精确 ⇒ 0 flags）。
//   ★ 浮点→整数方向**不能**复用该原语：其舍入粒度由数值自身的自然 ulp 决定，
//   而浮点→整数要求固定 ulp = 1（见 fpu_f2i 头注），故用同一张 rm 增量表显式实现。
//
// ★ 红线 1/2（IP 优先 + 无原语）
//   检索结论：Vivado `Floating-Point Operator v7.1`（PG060）含 Conversion 模式
//   （float↔int、float↔float），但其输入/输出语义是 AXI-Stream 定长流水且
//   **不**实现 RISC-V 的 NaN-boxing/canonical-NaN 替换、饱和口径与 NV/NX 组合
//   （而本模块的 fcvt 语义恰恰全在这些细节上）；本模块为纯位级逻辑
//   （无 DSP/BRAM/时钟域硬核），**不含任何 FPGA 原语**、也不例化 IP，
//   故无需 IP/行为模型双分支（`RV32GC_USE_VIVADO_IP` 不适用）。
//
// 实现纪律：**全 assign / 条件表达式 / function**，无 always 块、无 reg（红线 3）。
//
// 操作码表（归一化 fp_op[6:0]，全设计唯一定义在此处与 fpu_cmp.v 头注；
//           fpu.v 必须与此一致）：
//      0 FADD   1 FSUB   2 FMUL   3 FDIV   4 FSQRT
//      5 FSGNJ  6 FSGNJN 7 FSGNJX 8 FMIN   9 FMAX        （fpu_cmp.v）
//     10 FEQ   11 FLT   12 FLE   13 FCLASS              （fpu_cmp.v）
//     14 FMV_X_W / FMV_X_D      （fmt=00 ⇒ fmv.x.w；fmt=01 ⇒ fmv.x.d）
//     15 FMV_W_X / FMV_D_X      （fmt=00 ⇒ fmv.w.x；fmt=01 ⇒ fmv.d.x）
//     16 FCVT_W_S   17 FCVT_WU_S  18 FCVT_S_W   19 FCVT_S_WU
//     20 FCVT_W_D   21 FCVT_WU_D  22 FCVT_D_W   23 FCVT_D_WU
//     24 FCVT_S_D   25 FCVT_D_S
//   fmt[1:0] 编码**目标**类型（d-st-ext.adoc:156-162）：fcvt.s.d ⇒ 00（目标 S）；
//   fcvt.d.s ⇒ 01（目标 D）。fcvt/fmv 的源类型由 op 自身决定。
//
// 端口：
//   rm  : 指令 rm 域（111=DYN）；frm : fcsr.frm。本模块内部解析 DYN；
//         保留舍入模式（rm=101/110、frm 保留值）按 INTERFACE.md 口径当 RNE 处理、
//         不置 fflags。（若 fpu.v 已自行解析 DYN 并把有效 rm 传进来，本模块行为不变。）
//   a   : 操作数（源浮点位型，或 fmv.*.x / fcvt.*.w[.wu] 的整数操作数）
//   result : 写回值 —— 整数目标（fcvt.w*./fmv.x.*）低 32 位有效、高 32 位为 0；
//            浮点目标 S（fcvt.s.w*./fcvt.s.d/fmv.w.x）高 32 位全 1（NaN-boxed）；
//            浮点目标 D（fcvt.d.w*./fcvt.d.s/fmv.d.x）为完整 64 位。
//   fflags : {NV,DZ,OF,UF,NX}，本模块只可能置 NV/OF/UF/NX（DZ 恒 0）。
//==============================================================================
`include "rv32_defs.vh"
`include "core_params.vh"

//==============================================================================
// fpu_f2i —— 浮点 → 32 bit 整数（参数化格式 W/FB），含饱和与 NV/NX
//   value = (-1)^sign × sig × 2^exp2（sig 含隐藏位，口径与 fpu_round_* 一致）
//   舍入粒度固定 ulp = 1（**不是**数值自身的自然 ulp），故独立实现：
//     · exp2 ≥ 0：值已是整数 ⇒ 精确，无 NX；
//     · exp2 < 0：右移 sh=-exp2 位，round bit = 被丢最高位、sticky = 其余位，
//       增量表与 fpu_round_s/fpu_round_d 完全一致
//       （RNE: rb&(st|lsb) / RMM: rb / RTZ: 0 / RUP: ~sign / RDN: sign）。
//   越界/±∞/NaN ⇒ NV + 饱和（NaN 给正最大）；NX 仅在「未置 NV 且不精确」时置。
//==============================================================================
module fpu_f2i #(
    parameter integer W  = 32,      // 源格式位宽（32=S / 64=D）
    parameter integer FB = 23       // 源格式尾数位宽（23 / 52）
) (
    input  wire [W-1:0] a,          // 浮点位型
    input  wire [2:0]   rm,         // 已解析的有效舍入模式（不含 DYN）
    input  wire         is_unsigned,// 1 = fcvt.wu.*；0 = fcvt.w.*
    output wire [31:0]  r,          // 32 bit 整数结果
    output wire [4:0]   fl          // {NV,DZ,OF,UF,NX}，只可能 NV/NX
);
    localparam integer E    = W - FB - 1;                 // 指数域位宽
    localparam integer BIAS = (1 << (E - 1)) - 1;         // 127 / 1023

    localparam signed [15:0] BIAS16 = BIAS;
    localparam signed [15:0] FB16   = FB;
    localparam signed [15:0] EMIN_E = 1 - BIAS;           // 亚正规的无偏指数（−126/−1022）
    localparam [15:0]        SH_LIM = FB + 1;             // 右移量超过它 ⇒ 舍入位以下全 0

    // ---- 分解 ----
    wire          sign = a[W-1];
    wire [E-1:0]  ef   = a[W-2:FB];
    wire [FB-1:0] fr   = a[FB-1:0];
    wire          a_nan = (&ef) & (|fr);
    wire          a_inf = (&ef) & ~(|fr);

    wire [FB:0] sig = (|ef) ? {1'b1, fr} : {1'b0, fr};    // 亚正规隐藏位为 0

    wire signed [15:0] ef_s   = $signed({{(16-E){1'b0}}, ef});
    wire signed [15:0] e_unb  = (|ef) ? (ef_s - BIAS16) : EMIN_E;
    wire signed [15:0] exp2   = e_unb - FB16;             // value = sig × 2^exp2

    // ---- 整数路径（exp2 ≥ 0）----
    wire [63:0] sig64   = {{(64-(FB+1)){1'b0}}, sig};
    // exp2 ≥ 0 时：幅值 ≥ 2^(exp2+FB)；exp2+FB ≥ 32 ⇒ 必然越界（有符号/无符号皆然）
    wire        oor_big = ((exp2 + FB16) >= 16'sd32);
    wire [63:0] n_exact = sig64 << exp2[5:0];             // 仅 !oor_big 时有效（此时移位量 ≤ 8）

    // ---- 小数路径（exp2 < 0）----
    wire               is_frac = (exp2 < 16'sd0);
    wire signed [15:0] nshift  = -exp2;
    wire [15:0]        sh_raw  = nshift[15:0];            // > 0
    wire               sh_big  = (sh_raw > SH_LIM);       // 舍入位以下全被丢弃 ⇒ sticky=1
    wire [5:0]         sh_c    = sh_big ? 6'd1 : sh_raw[5:0];
    wire [63:0]        q_fr    = sh_big ? 64'd0 : (sig64 >> sh_c);
    wire               rb      = sh_big ? 1'b0  : sig64[sh_c - 6'd1];
    wire               st      = sh_big ? (|sig64)
                                        : (|(sig64 & ((64'd1 << (sh_c - 6'd1)) - 64'd1)));
    wire               frac_inexact = rb | st;
    wire               inc_rne = rb & (st | q_fr[0]);
    wire               inc = (rm == 3'b000) ? inc_rne :            // RNE
                             (rm == 3'b100) ? rb       :            // RMM
                             (rm == 3'b001) ? 1'b0     :            // RTZ
                             (rm == 3'b011) ? ~sign    :            // RUP
                             (rm == 3'b010) ?  sign    :            // RDN
                                               inc_rne;             // 保留 rm ⇒ RNE
    wire [63:0] n_frac = q_fr + {63'b0, (frac_inexact & inc)};

    // ---- 幅值 + 有效输入域（按舍入后的值判定）----
    wire [63:0] n_mag = is_frac ? n_frac
                                : (oor_big ? 64'hFFFF_FFFF_FFFF_FFFF : n_exact);
    wire [63:0] lim = is_unsigned ? (sign ? 64'h0000_0000_0000_0000 : 64'h0000_0000_FFFF_FFFF)
                                  : (sign ? 64'h0000_0000_8000_0000 : 64'h0000_0000_7FFF_FFFF);
    wire        in_range = (n_mag <= lim);

    wire nv = a_nan | a_inf | ~in_range;
    wire nx = is_frac & frac_inexact & ~nv;

    wire [31:0] pos_max = is_unsigned ? 32'hFFFF_FFFF : 32'h7FFF_FFFF;
    wire [31:0] neg_sat = is_unsigned ? 32'h0000_0000 : 32'h8000_0000;
    wire [31:0] mag32   = n_mag[31:0];                    // in_range 时低 32 位即幅值
    wire [31:0] sat_r   = a_nan ? pos_max : (sign ? neg_sat : pos_max);

    assign r  = nv ? sat_r : (sign ? (~mag32 + 32'd1) : mag32);
    assign fl = {nv, 1'b0, 1'b0, 1'b0, nx};
endmodule

//==============================================================================
// fpu_cvt —— 顶层：op 分发 + S 操作数 NaN-boxing + S 结果 NaN-boxing
//==============================================================================
module fpu_cvt (
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

    // ---- 舍入模式解析：DYN 取 frm；保留值（101/110/111）按 RNE ----
    wire [2:0] rm_eff = (rm == `RV32GC_RM_DYN)
                            ? (((frm == 3'b101) | (frm == 3'b110) | (frm == 3'b111))
                                   ? `RV32GC_RM_RNE : frm)
                            : (((rm == 3'b101) | (rm == 3'b110)) ? `RV32GC_RM_RNE : rm);

    //--------------------------------------------------------------------------
    // S 视图（NaN-boxing 检查，用于所有非 transfer 的 S 操作数读取）
    //--------------------------------------------------------------------------
    wire [31:0] a_s = (a[63:32] == 32'hFFFF_FFFF) ? a[31:0] : CANON_S;

    wire        s_sign = a_s[31];
    wire [7:0]  s_ef   = a_s[30:23];
    wire [22:0] s_fr   = a_s[22:0];
    wire        s_nan  = (&s_ef) & (|s_fr);
    wire        s_snan = s_nan & ~a_s[22];
    wire        s_inf  = (&s_ef) & ~(|s_fr);

    //--------------------------------------------------------------------------
    // D 视图（fcvt.s.d 的源；D 是 FLEN 宽，无 NaN-boxing 检查）
    //--------------------------------------------------------------------------
    wire        d_sign = a[63];
    wire [10:0] d_ef   = a[62:52];
    wire [51:0] d_fr   = a[51:0];
    wire        d_nan  = (&d_ef) & (|d_fr);
    wire        d_snan = d_nan & ~a[51];
    wire        d_inf  = (&d_ef) & ~(|d_fr);

    //--------------------------------------------------------------------------
    // ① 浮点 → 整数（fcvt.w[.wu].s / fcvt.w[.wu].d）
    //--------------------------------------------------------------------------
    wire f2i_uns = (fp_op == FP_FCVT_WU_S) | (fp_op == FP_FCVT_WU_D);
    // ★ 仿真吞吐优化（2026-09-17，语义不变）：只让本次转换方向用到的舍入原语活动
    //   （末尾按 fp_op 选结果，未选中方向的输出恒被丢弃）。iverilog 事件驱动下，
    //   输入被钳 0 的实例不再每拍重算（D 侧含 8192 bit 域）。
    wire en_i2s = (fp_op == FP_FCVT_S_W)  | (fp_op == FP_FCVT_S_WU);
    wire en_i2d = (fp_op == FP_FCVT_D_W)  | (fp_op == FP_FCVT_D_WU);
    wire en_s2d = (fp_op == FP_FCVT_D_S);
    wire en_d2s = (fp_op == FP_FCVT_S_D);
    wire [31:0] r_f2i_s, r_f2i_d;
    wire [4:0]  fl_f2i_s, fl_f2i_d;
    wire en_f2i_s = (fp_op == FP_FCVT_W_S)  | (fp_op == FP_FCVT_WU_S);
    wire en_f2i_d = (fp_op == FP_FCVT_W_D)  | (fp_op == FP_FCVT_WU_D);

    fpu_f2i #(.W(32), .FB(23)) u_f2i_s (
        .a (en_f2i_s ? a_s : 32'd0), .rm (rm_eff), .is_unsigned (f2i_uns),
        .r (r_f2i_s), .fl (fl_f2i_s)
    );
    fpu_f2i #(.W(64), .FB(52)) u_f2i_d (
        .a (en_f2i_d ? a : 64'd0), .rm (rm_eff), .is_unsigned (f2i_uns),
        .r (r_f2i_d), .fl (fl_f2i_d)
    );

    //--------------------------------------------------------------------------
    // ② 整数 → 浮点（fcvt.s.w[.wu] / fcvt.d.w[.wu]）
    //    复用 fpu_round_s / fpu_round_d：sig = |x|（≤ 2^32）、exp = 0
    //--------------------------------------------------------------------------
    wire        i2f_uns  = (fp_op == FP_FCVT_S_WU) | (fp_op == FP_FCVT_D_WU);
    wire [31:0] x_w      = a[31:0];
    wire [31:0] x_mag_s  = x_w[31] ? (~x_w + 32'd1) : x_w;      // 有符号幅值（0x8000_0000 → 0x8000_0000）
    wire        i2f_sign = i2f_uns ? 1'b0 : x_w[31];
    wire [31:0] i2f_mag  = i2f_uns ? x_w  : x_mag_s;

    wire [1023:0] i2f_sig_s = en_i2s ? {{(1024-32){1'b0}}, i2f_mag} : 1024'd0;
    wire [8191:0] i2f_sig_d = en_i2d ? {{(8192-32){1'b0}}, i2f_mag} : 8192'd0;
    wire [31:0] r_i2s;
    wire [63:0] r_i2d;
    wire [4:0]  fl_i2s, fl_i2d;

    fpu_round_s u_i2s (
        .sign (i2f_sign), .sig (i2f_sig_s), .exp (13'sd0), .rm (rm_eff),
        .result (r_i2s), .fflags (fl_i2s)
    );
    fpu_round_d u_i2d (
        .sign (i2f_sign), .sig (i2f_sig_d), .exp (14'sd0), .rm (rm_eff),
        .result (r_i2d), .fflags (fl_i2d)
    );

    //--------------------------------------------------------------------------
    // ③ fcvt.d.s（S → D，恒精确、不舍入、只可能置 NV）
    //--------------------------------------------------------------------------
    wire [23:0] s_sig = (|s_ef) ? {1'b1, s_fr} : {1'b0, s_fr};
    wire signed [13:0] s_e = (|s_ef) ? ($signed({6'b0, s_ef}) - 14'sd150)
                                     : -14'sd149;              // value = s_sig × 2^s_e
    wire [8191:0] s_sig_x = en_s2d ? {{(8192-24){1'b0}}, s_sig} : 8192'd0;
    wire [63:0] r_ds_raw;
    wire [4:0]  fl_ds_raw;

    fpu_round_d u_s2d (
        .sign (s_sign), .sig (s_sig_x), .exp (s_e), .rm (rm_eff),
        .result (r_ds_raw), .fflags (fl_ds_raw)
    );

    wire [63:0] ds_r = s_nan ? CANON_D :
                       s_inf ? {s_sign, 11'h7FF, 52'd0} : r_ds_raw;
    wire [4:0]  ds_fl = s_nan ? (s_snan ? 5'b10000 : 5'b00000) :
                        s_inf ? 5'b00000 : fl_ds_raw;

    //--------------------------------------------------------------------------
    // ④ fcvt.s.d（D → S，按 rm 舍入，可置 NV/OF/UF/NX）
    //    ★ 极小数快速路径：本设计把 d_e < −600（即 |D 值| ≤ 2^(−600+53) = 2^-547）
    //      的输入视为"远低于 S 亚正规下限"，结果为 ±0 或 ±2^-149（UF|NX）。
    //      走专门通路的原因：fpu_round_s 内部用 9 bit 移位索引（rsh[8:0]），当
    //      rsh = ulp_ex − exp ≥ 512 时索引被截断、q/round_bit 失真；
    //      d_e ≥ −600 ⇒ rsh ≤ 451 < 512，即原语始终在安全域内。
    //      本路径输出与"未被截断的舍入原语"逐位一致（round_bit=0、sticky=1）。
    //      边界两侧都已测：2^-540 走原语通路、2^-560 走本通路，结果同为 ±0 + UF|NX。
    //--------------------------------------------------------------------------
    wire [52:0] d_sig = (|d_ef) ? {1'b1, d_fr} : {1'b0, d_fr};
    wire signed [13:0] d_e = (|d_ef) ? ($signed({3'b0, d_ef}) - 14'sd1075)
                                     : -14'sd1074;             // value = d_sig × 2^d_e
    wire d_tiny = (d_e < -14'sd600);

    wire [1023:0] d_sig_x = en_d2s ? {{(1024-53){1'b0}}, d_sig} : 1024'd0;
    wire [31:0] r_sd_raw;
    wire [4:0]  fl_sd_raw;

    fpu_round_s u_d2s (
        .sign (d_sign), .sig (d_sig_x), .exp (d_e[12:0]), .rm (rm_eff),
        .result (r_sd_raw), .fflags (fl_sd_raw)
    );

    // 极小数：舍入位=0、sticky=1 ⇒ 仅 RUP/RDN 会给出最小亚正规 ±2^-149
    // ★ 例外：D 值**恰好为 ±0** 时转换精确 ⇒ 结果就是同号 0、不置任何 flags
    //   （此时 d_e = −1074 也落在本通路内，必须单独处理，否则会凭空产生 UF|NX）。
    wire d_zero = ~(|d_sig);
    wire tiny_inc = (rm_eff == 3'b011) ? ~d_sign :            // RUP
                    (rm_eff == 3'b010) ?  d_sign :            // RDN
                                          1'b0;               // RNE/RMM/RTZ 及保留值
    wire [31:0] tiny_r = (d_zero | ~tiny_inc) ? {d_sign, 31'd0}
                                              : {d_sign, 8'd0, 23'd1};   // ±2^-149
    wire [4:0]  tiny_fl = d_zero ? 5'b00000 : 5'b00011;       // UF|NX

    wire [31:0] sd_r = d_nan  ? CANON_S :
                       d_inf  ? {d_sign, 8'hFF, 23'd0} :
                       d_tiny ? tiny_r : r_sd_raw;
    wire [4:0]  sd_fl = d_nan ? (d_snan ? 5'b10000 : 5'b00000) :
                        d_inf ? 5'b00000 :
                        d_tiny ? tiny_fl :               // UF|NX（输入恰为 ±0 时 tiny_fl = 0）
                                 fl_sd_raw;

    //--------------------------------------------------------------------------
    // ⑤ 结果分发（S 浮点结果统一在末尾补高 32 位全 1 ⇒ NaN-boxed）
    //--------------------------------------------------------------------------
    wire is_mvx   = (fp_op == FP_FMV_X);
    wire is_mvwx  = (fp_op == FP_FMV_W_X);
    wire fmt_d    = (fmt == 2'b01);

    wire [63:0] r_sd_boxed = {32'hFFFF_FFFF, sd_r};
    wire [63:0] r_i2s_boxed = {32'hFFFF_FFFF, r_i2s};

    assign result =
        (fp_op == FP_FCVT_W_S)  ? {32'b0, r_f2i_s} :
        (fp_op == FP_FCVT_WU_S) ? {32'b0, r_f2i_s} :
        (fp_op == FP_FCVT_W_D)  ? {32'b0, r_f2i_d} :
        (fp_op == FP_FCVT_WU_D) ? {32'b0, r_f2i_d} :
        (fp_op == FP_FCVT_S_W)  ? r_i2s_boxed :
        (fp_op == FP_FCVT_S_WU) ? r_i2s_boxed :
        (fp_op == FP_FCVT_D_W)  ? r_i2d :
        (fp_op == FP_FCVT_D_WU) ? r_i2d :
        (fp_op == FP_FCVT_S_D)  ? r_sd_boxed :
        (fp_op == FP_FCVT_D_S)  ? ds_r :
        is_mvx                  ? (fmt_d ? a : {32'b0, a[31:0]}) :
        is_mvwx                 ? (fmt_d ? a : {32'hFFFF_FFFF, a[31:0]}) :
                                  64'b0;              // 未定义 op ⇒ 确定 0

    assign fflags =
        (fp_op == FP_FCVT_W_S)  ? fl_f2i_s :
        (fp_op == FP_FCVT_WU_S) ? fl_f2i_s :
        (fp_op == FP_FCVT_W_D)  ? fl_f2i_d :
        (fp_op == FP_FCVT_WU_D) ? fl_f2i_d :
        (fp_op == FP_FCVT_S_W)  ? fl_i2s :
        (fp_op == FP_FCVT_S_WU) ? fl_i2s :
        (fp_op == FP_FCVT_D_W)  ? fl_i2d :
        (fp_op == FP_FCVT_D_WU) ? fl_i2d :
        (fp_op == FP_FCVT_S_D)  ? sd_fl :
        (fp_op == FP_FCVT_D_S)  ? ds_fl :
                                  5'b00000;           // fmv.* 不置 fflags
endmodule
