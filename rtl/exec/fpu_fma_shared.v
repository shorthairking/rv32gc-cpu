//==============================================================================
// rtl/exec/fpu_fma_shared.v —— N27B：**S/D 共享 53-bit 主算术核 + 双模单舍入器**
//==============================================================================
// 项目  : rv32gc-cpu（阶段二 2B）
// 来源  : EXP-N27A 可行性报告（fpga/scratch/n27a_report.md）的探针实测落地。
//   本文件是探针源码 `fpga/scratch/n27a_round_dual.v` + `fpga/scratch/n27a_fma_shared.v`
//   的**逐字位级搬运**（只做模块改名 n27a_* → fpu_*；逻辑表达式、位宽、位序一字未改）。
//   sha256（搬运前探针原文）：
//     n27a_round_dual.v = 937603b9ffe472f9e35fb2bb3766489a52f1335e0db1cb5233a048ecb0622b53
//     n27a_fma_shared.v = 15f114059cce9b3d85caa0ba5a00bfd1c1246949b4fc67bb9a775e056adc5f8e
//   ⇒ N27A 的 80,000 向量（共享核 ↔ 原生 S/D FMA）与 12,000 向量（双模舍入器 ↔
//     原生 S/D 舍入器）位级对拍结论对本文件**原样适用**；N27B 用同一 TB 指向本文件复跑。
//
// 顶层  : `fpu_fma_shared` —— 自 N27B 起由 rtl/exec/fpu.v §5 **唯一例化**（取代原先
//   `u_fma_s` + `u_fma_d` 两个实例）；`fpu_fma_s`/`fpu_fma_d` 的模块体保留在
//   rtl/exec/fpu_add.v 内但**不再被例化**（金标 + 逐位差分对照，与 N8 对
//   fpu_add_s/d 的惯例一致，见该文件 N27B 头注）。
//   ★ N8 语义前提不变：fpu.v 的 §5 仍把 FADD/FSUB/FMUL 并入本 FMA 通路
//     （FADD(a,b)=FMA(a,1.0,b)、FMUL(a,b)=FMA(a,b,±0)），本文件只负责在
//     `is_s` 指定的精度上做"精确积 + 精确对阶 + **一次**舍入"。
//
// 结构（N27A §2-Q1/Q2/Q3 的实测口径；括号内为 OOC LUT 实测值，同配方 OOC 口径）：
//   级 0  组合：字段视图 / 分类常量 / 特殊值结果按 `is_s` 选择（+206 的来源）
//   级 1  字段（有效数 53 bit / 绝对无偏指数 / 符号 / rm / ec_en / is_s）
//   级 2  精确积 53×53 → 106 bit（9 DSP）+ pexp = ae+be−104 / kexp = ce−52
//   级 3  fpu_align_pre  (WA=106, WB=53, WW=110) = 345
//   级 4  fpu_align_mid  (同上)                   = 1,629（与原生 D **逐值相同**）
//   级 5  fpu_align_sum  (WW=110)                 = 111
//   级 6  fpu_align_fix  (WW=110)                 = 415
//   级 6~8 fpu_round_dual：**一次舍入**（S 模式 ulp 网格 = e_unb−23 / 下钳 −149，
//          D 模式 = e_unb−52 / 下钳 −1074）        = 1,100（= 原生 D 1,051 + 49）
//   旁带   special 结果 + fflags 的 8 拍延迟线（69 bit + 1 bit，S/D 合一；S 的
//          37-bit 延迟线被删）⇒ ΔSRL −33
//   ⇒ 仍是 8 级流水（与本文件取代的两条原生通路同为 LAT=8）⇒ fpu.v 的
//     FPU_SC_LAT=8 与 busy/done 时序**逐拍不变**，IPC 影响 = 0。
//
// 位级等价（"单次舍入"是硬约束，绝无二次舍入）：
//   S 操作数精确注入 D 域：sig53 = {sig24, 29'b0}、指数沿用同一"绝对无偏指数"，
//   则 sig53 × 2^(eunb−52) ≡ sig24 × 2^(eunb−23)。窗口 (win, win_exp, sticky) 是
//   "值 + 下界 sticky"的精确表示，与窗口放在 52 bit 还是 110 bit 无关 ⇒
//   S 模式拿到的低位信息只多不少，一次舍入到 S 与原生 S 通路逐位相同。
//   ★ N27A 对拍过程中抓到并修掉的 3 个真实缺陷（**本文件已含修复**，注释内留痕）：
//     ① S 指数满值常量 11'h07F → 11'h0FF；② S 尾数补零必须在**低位**侧
//        （{frac,29'b0}）而非高位侧；③ UF 判定的 q0 掩码 24 个 1 → 23 个 1。
//     这三条正说明"逐位对拍"是本路线**必须**的实验门，而不是可选项。
//
// 红线 2（IP 双分支）：本文件**不含任何 FPGA 原语、也不例化 IP**——只有位选/移位/
//   加法/mux 与寄存器；53×53 乘法沿用与原生 fpu_fma_d 逐字相同的
//   `r1_as * r1_bs` 写法（非 IP 分支由综合器推断 DSP，与既有 RTL 同口径）。
//   综合与仿真走**同一份** RTL（本文件无 `ifdef` 分支）。
// 红线 3（实现纪律）：组合逻辑一律 assign/function；always 块全部是**时序寄存器**，
//   无任何 always @(*)。
//==============================================================================

//------------------------------------------------------------------------------
// fpu_round_dual_pre —— 双模 pre（对 fpu_round_pre 的运行期参数化）
//------------------------------------------------------------------------------
module fpu_round_dual_pre #(
    parameter integer WW = 110
) (
    input  wire               is_s,
    input  wire [WW-1:0]      sig,
    input  wire               sticky_in,
    input  wire signed [15:0] exp,
    output wire               zero_o,
    output wire signed [15:0] ulp_ex,
    output wire signed [15:0] natural_ulp,
    output wire [15:0]        rsh,
    output wire [15:0]        lsh,
    output wire               do_right
);
    // S: FB=23 / MIN_SUB=−149 ; D: FB=52 / MIN_SUB=−1074
    wire signed [15:0] FB_S      = is_s ? 16'sd23  : 16'sd52;
    wire signed [15:0] MIN_SUB_S = is_s ? -16'sd149 : -16'sd1074;

    function [6:0] msb_win;
        input [WW-1:0] v;
        integer i;
        begin
            msb_win = 7'd0;
            for (i = 0; i < WW; i = i + 1) if (v[i]) msb_win = i[6:0];
        end
    endfunction

    wire               sig_zero = ~(|sig) & ~sticky_in;
    wire [6:0]         msb      = msb_win(sig);
    wire signed [15:0] e_unb    = exp + {9'b0, msb};
    wire signed [15:0] nat_w    = e_unb - FB_S;
    wire signed [15:0] ulp_w    = (nat_w >= MIN_SUB_S) ? nat_w : MIN_SUB_S;
    wire signed [15:0] diff     = exp - ulp_w;
    wire               dr_w     = (diff < 16'sd0);
    wire [15:0]        rsh_w    = dr_w ? (-diff) : 16'd0;
    wire [15:0]        lsh_w    = dr_w ? 16'd0 : diff;

    assign zero_o      = sig_zero;
    assign ulp_ex      = ulp_w;
    assign natural_ulp = nat_w;
    assign rsh         = rsh_w;
    assign lsh         = lsh_w;
    assign do_right    = dr_w;
endmodule

//------------------------------------------------------------------------------
// fpu_round_dual_mid —— 双模 mid（QW 取 D 的 max=54；代码同 fpu_round_mid，FB=52）
//------------------------------------------------------------------------------
module fpu_round_dual_mid #(
    parameter integer WW = 110,
    parameter integer QW = 54
) (
    input  wire          [WW-1:0] sig,
    input  wire                   sticky_in,
    input  wire                   do_right,
    input  wire          [15:0]   rsh,
    input  wire          [15:0]   lsh,
    output wire          [QW-1:0] q0,
    output wire                   round_bit,
    output wire                   sticky,
    output wire                   inexact
);
    localparam integer WSH = ((WW > QW) ? WW : QW) + 1;

    wire [WSH-1:0] sig_s = {{(WSH-WW){1'b0}}, sig};
    wire [WSH-1:0] qsh_f = do_right ? (sig_s >> rsh) : (sig_s << lsh);
    wire [QW-1:0]  q0_i  = qsh_f[QW-1:0];

    wire [15:0]   rsh_m1     = rsh - 16'd1;
    wire          round_bit_i = do_right ? ((sig >> rsh_m1) & 1'b1) : 1'b0;
    wire [WW-1:0] stk_msk  = ({{(WW-1){1'b0}}, 1'b1} << rsh_m1)
                             - {{(WW-1){1'b0}}, 1'b1};
    wire          sticky_i = (do_right & (|(sig & stk_msk))) | sticky_in;

    assign q0        = q0_i;
    assign round_bit = round_bit_i;
    assign sticky    = sticky_i;
    assign inexact   = round_bit_i | sticky_i;
endmodule

//------------------------------------------------------------------------------
// fpu_round_dual_post —— 双模 post（打包/异常标志按 is_s 选 S 或 D 常量与位宽）
//------------------------------------------------------------------------------
module fpu_round_dual_post #(
    parameter integer QW = 54
) (
    input  wire               is_s,
    input  wire               sign,
    input  wire [QW-1:0]      q0,
    input  wire               round_bit,
    input  wire               sticky,
    input  wire               inexact,
    input  wire signed [15:0] ulp_ex,
    input  wire signed [15:0] natural_ulp,
    input  wire [2:0]         rm,
    input  wire               zero_in,
    output wire [63:0]        result,
    output wire [4:0]         fflags
);
    wire signed [15:0] MIN_SUB_S = is_s ? -16'sd149 : -16'sd1074;
    wire signed [15:0] EMAXF_S   = is_s ?  16'sd255 : 16'sd2047;
    wire signed [15:0] BIAS_S    = is_s ?  16'sd127 : 16'sd1023;
    wire signed [15:0] EMIN_S    = 16'sd1 - BIAS_S;

    function [6:0] msb_q;
        input [QW:0] v;
        integer i;
        begin
            msb_q = 7'd0;
            for (i = 0; i <= QW; i = i + 1) if (v[i]) msb_q = i[6:0];
        end
    endfunction

    wire          lsb = q0[0];

    wire inc = (rm == 3'b000) ? (round_bit & (sticky | lsb)) :
               (rm == 3'b100) ?  round_bit :
               (rm == 3'b001) ?  1'b0 :
               (rm == 3'b011) ? ~sign :
               (rm == 3'b010) ?  sign :
                                 (round_bit & (sticky | lsb));

    wire [QW:0] q = {1'b0, q0} + {{QW{1'b0}}, (inexact & inc)};

    wire        q_zero = (q == {(QW+1){1'b0}});
    wire [6:0]  q_msb  = msb_q(q);
    wire signed [15:0] e_res = ulp_ex + {9'b0, q_msb};
    wire signed [15:0] e_f   = e_res + BIAS_S;

    wire overflow  = ~q_zero & (e_f >= EMAXF_S);
    wire subnormal = ~q_zero & (e_res < EMIN_S);

    // ---- S 打包（高 32 位填 1 = fpu.v 出口的 NaN-box 形状；低 32 位为真值）----
    localparam [31:0] BOX_HI = 32'hFFFF_FFFF;
    wire [63:0] sub_out_s = |q[24:23] ? {BOX_HI, sign, 8'h01, 23'b0}
                                      : {BOX_HI, sign, 8'h00, q[22:0]};
    wire [63:0] norm_out_s = {BOX_HI, sign, e_f[7:0], q[22:0]};
    wire [63:0] of_out_s  = {BOX_HI, sign, 8'hFF, 23'b0};

    // ---- D 打包 ----
    wire [63:0] sub_out_d = |q[53:52] ? {sign, 11'h001, 52'b0}
                                      : {sign, 11'b0, q[51:0]};
    wire [63:0] norm_out_d = {sign, e_f[10:0], q[51:0]};
    wire [63:0] of_out_d  = {sign, 11'h7FF, 52'b0};

    wire of_to_max = (rm == 3'b001) || ((rm == 3'b010) & ~sign) || ((rm == 3'b011) &  sign);
    wire [63:0] of_out = of_to_max ? (is_s ? {BOX_HI, sign, 8'hFE, 23'h7F_FFFF} : {sign, 11'h7FE, 52'hF_FFFF_FFFF_FFFF})
                                   : (is_s ? of_out_s : of_out_d);

    wire [63:0] zero_out = is_s ? {BOX_HI, sign, 31'b0} : {sign, 63'b0};

    wire [63:0] sub_out  = is_s ? sub_out_s  : sub_out_d;
    wire [63:0] norm_out = is_s ? norm_out_s : norm_out_d;

    assign result = (zero_in | q_zero) ? zero_out :
                    overflow           ? of_out   :
                    subnormal          ? sub_out  :
                                         norm_out;

    // ---- fflags（本原语产 OF/UF/NX）----
    wire of_fl = overflow;
    wire clamped_ulp  = (natural_ulp < MIN_SUB_S);
    // ★ 与 fpu_round_post 逐字一致：S 侧 q0 == 2^FB−1 = 2^23−1（23 个 1，不是 24 个），
    //   D 侧 q0 == 2^52−1。写错 ⇒ "自然网格恰好在 2^emin 以下一位、舍入进位到最小
    //   正规数"这一条 UF 判定会误报（实测：20000 例随机对拍里唯一 1 例失配）。
    wire [QW-1:0] last_s = {{(QW-23){1'b0}}, 23'h7F_FFFF};
    wire [QW-1:0] last_d = {{(QW-52){1'b0}}, 52'hF_FFFF_FFFF_FFFF};
    wire last_ulp_bel = (natural_ulp == (MIN_SUB_S - 16'sd1)) &
                        (is_s ? (q0 == last_s) : (q0 == last_d));
    wire inc_like     = (rm != 3'b001) &
                        ~((rm == 3'b011) &  sign) &
                        ~((rm == 3'b010) & ~sign);
    wire up_to_normal = last_ulp_bel & inc_like & round_bit & sticky;
    wire tiny         = clamped_ulp ? ~up_to_normal : (subnormal | q_zero);
    wire uf_fl = (~overflow) & inexact & tiny;
    wire nx_fl = inexact & ~overflow;
    assign fflags = {1'b0, 1'b0, of_fl, uf_fl, (nx_fl | of_fl)};
endmodule

//==============================================================================
// fpu_round_dual —— 3 级流水双模舍入器（与 fpu_round_pipe 同构，参数运行期）
//==============================================================================
module fpu_round_dual #(
    parameter integer WW = 110,
    parameter integer QW = 54
) (
    input  wire               clk,
    input  wire               is_s,
    input  wire               sign,
    input  wire [WW-1:0]      sig,
    input  wire               sticky_in,
    input  wire signed [15:0] exp,
    input  wire [2:0]         rm,
    output wire [63:0]        result,
    output wire [4:0]         fflags
);
    // ---- 级 A ----
    reg               a_is_s, a_sign, a_stk_in;
    reg  [WW-1:0]     a_sig;
    reg  signed [15:0] a_exp;
    reg  [2:0]        a_rm;
    always @(posedge clk) begin
        a_is_s   <= is_s;
        a_sign   <= sign;
        a_sig    <= sig;
        a_stk_in <= sticky_in;
        a_exp    <= exp;
        a_rm     <= rm;
    end

    // ---- 级 B ----
    wire               b_zero_w;
    wire signed [15:0] b_ulp_w, b_nat_w;
    wire [15:0]        b_rsh_w, b_lsh_w;
    wire               b_dr_w;
    fpu_round_dual_pre #(.WW(WW)) u_pre (
        .is_s (a_is_s), .sig (a_sig), .sticky_in (a_stk_in), .exp (a_exp),
        .zero_o (b_zero_w), .ulp_ex (b_ulp_w), .natural_ulp (b_nat_w),
        .rsh (b_rsh_w), .lsh (b_lsh_w), .do_right (b_dr_w)
    );
    reg               b_is_s, b_sign, b_stk_in, b_zero, b_dr;
    reg  [WW-1:0]     b_sig;
    reg  signed [15:0] b_ulp, b_nat;
    reg  [15:0]        b_rsh, b_lsh;
    reg  [2:0]         b_rm;
    always @(posedge clk) begin
        b_is_s   <= a_is_s;
        b_sign   <= a_sign;
        b_sig    <= a_sig;
        b_stk_in <= a_stk_in;
        b_rm     <= a_rm;
        b_zero   <= b_zero_w;
        b_ulp    <= b_ulp_w;
        b_nat    <= b_nat_w;
        b_rsh    <= b_rsh_w;
        b_lsh    <= b_lsh_w;
        b_dr     <= b_dr_w;
    end

    // ---- 级 C ----
    wire [QW-1:0] c_q0_w;
    wire          c_rb_w, c_stk_w, c_inx_w;
    fpu_round_dual_mid #(.WW(WW), .QW(QW)) u_mid (
        .sig (b_sig), .sticky_in (b_stk_in), .do_right (b_dr),
        .rsh (b_rsh), .lsh (b_lsh),
        .q0 (c_q0_w), .round_bit (c_rb_w), .sticky (c_stk_w), .inexact (c_inx_w)
    );
    reg               c_is_s, c_sign, c_zero, c_rb, c_stk, c_inx;
    reg  [QW-1:0]     c_q0;
    reg  signed [15:0] c_ulp, c_nat;
    reg  [2:0]         c_rm;
    always @(posedge clk) begin
        c_is_s <= b_is_s;
        c_sign <= b_sign;
        c_zero <= b_zero;
        c_rm   <= b_rm;
        c_ulp  <= b_ulp;
        c_nat  <= b_nat;
        c_q0   <= c_q0_w;
        c_rb   <= c_rb_w;
        c_stk  <= c_stk_w;
        c_inx  <= c_inx_w;
    end

    // ---- 末级组合 ----
    fpu_round_dual_post #(.QW(QW)) u_post (
        .is_s (c_is_s), .sign (c_sign), .q0 (c_q0), .round_bit (c_rb),
        .sticky (c_stk), .inexact (c_inx), .ulp_ex (c_ulp), .natural_ulp (c_nat),
        .rm (c_rm), .zero_in (c_zero), .result (result), .fflags (fflags)
    );
endmodule

//==============================================================================
// fpu_fma_shared —— N27B：S/D 共享 53-bit 主算术核（`is_s` 双模）
//------------------------------------------------------------------------------
// 设计（与 N13A §6 建议 2 的"选项 C"、N27A §2-Q2 一致）：
//   ① 结构 = fpu_fma_d 的 53-bit 通路（106-bit 精确积 / WW=110 对阶窗口 /
//      fpu_align_{pre,mid,sum,fix}）**原样** —— 它是 S 通路的严格超集。
//   ② S 操作数**精确注入** D 域（不是近似）：见文件头"位级等价"段。
//   ③ 舍入 = fpu_round_dual（一次舍入）：S 模式 ulp 网格 (e_unb−23, 下钳 −149)，
//      D 模式 (e_unb−52, 下钳 −1074)。
//   ④ 舍入前窗口 (win, win_exp, sticky) 与"窗口放在哪"无关 ⇒ 位级等价。
//
// 与原生 S 通路（fpu_fma_s）的差异清单 = 本模块里所有 `is_s ?` 的地方：
//   · 级 0 字段解码/分类常量（EXPM / qbit / EMINU / BIAS）
//   · 级 0 特殊值 sp_r（S：高 32 位填 1 的 NaN-box 形状 / D：完整 64 位）
//   · 舍入器（fpu_round_dual）
//   · 末尾 sp_d 延迟线统一为 69 bit（原 S 37 bit + D 69 bit）
//   · 输出 result 对 S **已在模块内完成 NaN-box**（fpu.v 出口不再补高位）
// 端口契约：见 rtl/exec/fpu.v §5；`is_s` 必须与 a/b/c/neg_prod/neg_add/rm 同拍有效
//   （fpu.v 用 `en_fma & ~is_d` 门控），`result` 为 64 位（S 模式高 32 位全 1）。
//==============================================================================
module fpu_fma_shared (
    input  wire        clk,
    input  wire        is_s,        // 1 = 单精度模式（a/b/c 低 32 bit 有效）
    input  wire [63:0] a,
    input  wire [63:0] b,
    input  wire [63:0] c,
    input  wire        neg_prod,
    input  wire        neg_add,
    input  wire [2:0]  rm,
    output wire [63:0] result,
    output wire [4:0]  fflags
);
    localparam [31:0] BOX_HI = 32'hFFFF_FFFF;

    //---- 第 0 级（组合）：模式选择的字段视图 ----
    wire        a_sign = is_s ? a[31] : a[63];
    wire        b_sign = is_s ? b[31] : b[63];
    wire        c_sign = (is_s ? c[31] : c[63]) ^ neg_add;
    wire [10:0] a_exp  = is_s ? {3'b000, a[30:23]} : a[62:52];
    wire [10:0] b_exp  = is_s ? {3'b000, b[30:23]} : b[62:52];
    wire [10:0] c_exp  = is_s ? {3'b000, c[30:23]} : c[62:52];
    // ★ S→D 域注入的关键一行：S 的 23-bit 显式尾数必须落在 **51:29**，
    //   即 {1'b1, frac, 29'b0}（隐含位在 52、显式尾数在其下、最低 29 位补零）。
    //   同值性：sig53 × 2^(eunb−52) = (2^23+frac)·2^29 × 2^(eunb−52)
    //          = (2^23+frac) × 2^(eunb−23) = S 原值。位序写反 ⇒ 尾数整体偏低
    //          29 位（实测：S 结果分数被清零，见 n27a_equiv_tb 的失配教训）。
    wire [51:0] a_frac = is_s ? {a[22:0], 29'b0} : a[51:0];
    wire [51:0] b_frac = is_s ? {b[22:0], 29'b0} : b[51:0];
    wire [51:0] c_frac = is_s ? {c[22:0], 29'b0} : c[51:0];

    wire [10:0] EXPM = is_s ? 11'h0FF : 11'h7FF;      // 指数域满值（S 8'hFF 零扩展）
    wire        a_q  = is_s ? a[22] : a[51];          // quiet bit
    wire        b_q  = is_s ? b[22] : b[51];
    wire        c_q  = is_s ? c[22] : c[51];

    wire a_nan  = (a_exp == EXPM) && (a_frac != 0);
    wire b_nan  = (b_exp == EXPM) && (b_frac != 0);
    wire c_nan  = (c_exp == EXPM) && (c_frac != 0);
    wire a_inf  = (a_exp == EXPM) && (a_frac == 0);
    wire b_inf  = (b_exp == EXPM) && (b_frac == 0);
    wire c_inf  = (c_exp == EXPM) && (c_frac == 0);
    wire a_zero = (a_exp == 0) && (a_frac == 0);
    wire b_zero = (b_exp == 0) && (b_frac == 0);
    wire c_zero = (c_exp == 0) && (c_frac == 0);
    wire a_snan = a_nan && ~a_q;
    wire b_snan = b_nan && ~b_q;
    wire c_snan = c_nan && ~c_q;

    wire [52:0] a_sig = (a_exp == 0) ? {1'b0, a_frac} : {1'b1, a_frac};
    wire [52:0] b_sig = (b_exp == 0) ? {1'b0, b_frac} : {1'b1, b_frac};
    wire [52:0] c_sig = (c_exp == 0) ? {1'b0, c_frac} : {1'b1, c_frac};

    wire signed [15:0] EMINU  = is_s ? -16'sd126  : -16'sd1022;
    wire signed [15:0] BIAS_S = is_s ?  16'sd127  :  16'sd1023;
    wire signed [15:0] a_eunb = (a_exp == 0) ? EMINU : ($signed({5'b0, a_exp}) - BIAS_S);
    wire signed [15:0] b_eunb = (b_exp == 0) ? EMINU : ($signed({5'b0, b_exp}) - BIAS_S);
    wire signed [15:0] c_eunb = (c_exp == 0) ? EMINU : ($signed({5'b0, c_exp}) - BIAS_S);

    wire p_sign = a_sign ^ b_sign ^ neg_prod;

    //---- 特殊值（第 0 级组合）----
    wire p_inf_zero = (a_inf & b_zero) | (a_zero & b_inf);
    wire p_inf      = a_inf | b_inf;
    wire any_nan    = a_nan | b_nan | c_nan;
    wire p_zero  = (a_zero & ~b_inf) | (b_zero & ~a_inf);
    wire p_finite_zero = p_zero & ~p_inf_zero;
    wire any_snan   = a_snan | b_snan | c_snan;
    wire p_sign_w = p_sign;
    wire eff_zero = p_finite_zero & c_zero;
    wire eff_zero_sign = (p_sign_w == c_sign) ? p_sign_w : (rm == 3'b010);
    wire inf_opp = p_inf & c_inf & (p_sign != c_sign) & ~any_nan;
    wire inf_special = p_inf_zero | inf_opp;
    wire give_nan = any_nan | p_inf_zero | inf_opp;
    wire give_pinf = p_inf & ~p_inf_zero & ~(c_inf & (c_sign != p_sign)) & ~any_nan;
    wire give_cinf = c_inf & ~p_inf                              & ~any_nan;
    localparam [31:0] CANON_S = 32'h7FC0_0000;
    localparam [63:0] CANON_D = 64'h7FF8_0000_0000_0000;
    wire is_special = give_nan | give_pinf | give_cinf | eff_zero | p_finite_zero;
    wire nv = any_snan | inf_special;
    wire ec_en = ~p_finite_zero & (p_sign != c_sign);

    wire [63:0] sp_r = give_nan  ? (is_s ? {BOX_HI, CANON_S} : CANON_D) :
                       give_pinf ? (is_s ? {BOX_HI, p_sign, 8'hFF, 23'b0}
                                         : {p_sign, 11'h7FF, 52'b0}) :
                       give_cinf ? (is_s ? {BOX_HI, c_sign, 8'hFF, 23'b0}
                                         : {c_sign, 11'h7FF, 52'b0}) :
                       eff_zero  ? (is_s ? {BOX_HI, eff_zero_sign, 31'b0}
                                         : {eff_zero_sign, 63'b0}) :
                                   (is_s ? {BOX_HI, c_sign, c[30:0]}
                                         : {c_sign, c[62:0]});
    wire [4:0]  sp_f = {nv, 4'b0000};

    //---- 级 1：字段 ----
    reg [52:0] r1_as, r1_bs, r1_cs;
    reg signed [15:0] r1_ae, r1_be, r1_ce;
    reg        r1_ps, r1_csg;
    reg [2:0]  r1_rm;
    reg        r1_ec;
    reg        r1_is;                       // ★ 模式位必须与数据同深：级 1
    always @(posedge clk) begin
        r1_as <= a_sig; r1_bs <= b_sig; r1_cs <= c_sig;
        r1_ae <= a_eunb; r1_be <= b_eunb; r1_ce <= c_eunb;
        r1_ps <= p_sign; r1_csg <= c_sign; r1_rm <= rm; r1_ec <= ec_en;
        r1_is <= is_s;
    end

    //---- 级 2：精确乘积（53×53 ⇒ 106 bit）----
    wire [105:0]       w_prod = r1_as * r1_bs;
    wire signed [15:0] w_pexp = r1_ae + r1_be - 16'sd104;
    wire signed [15:0] w_kexp = r1_ce - 16'sd52;
    reg [105:0] r2_prod;
    reg signed [15:0] r2_pexp, r2_kexp;
    reg [52:0] r2_cs;
    reg        r2_ps, r2_csg;
    reg [2:0]  r2_rm;
    reg        r2_ec;
    reg        r2_is;
    always @(posedge clk) begin
        r2_prod <= w_prod; r2_pexp <= w_pexp; r2_kexp <= w_kexp;
        r2_cs <= r1_cs; r2_ps <= r1_ps; r2_csg <= r1_csg; r2_rm <= r1_rm; r2_ec <= r1_ec;
        r2_is <= r1_is;
    end

    //---- 级 3：对阶 pre ----
    wire [6:0]         w_arsh, w_alsh, w_brsh, w_blsh;
    wire               w_agone, w_ars, w_bgone, w_brs;
    wire signed [15:0] w_wexp;
    fpu_align_pre #(.WA(106), .WB(53), .WW(110)) u_pre (
        .sig_a (r2_prod), .lsb_a (r2_pexp), .sig_b (r2_cs), .lsb_b (r2_kexp),
        .a_rsh (w_arsh), .a_lsh (w_alsh), .a_gone (w_agone), .a_rs (w_ars),
        .b_rsh (w_brsh), .b_lsh (w_blsh), .b_gone (w_bgone), .b_rs (w_brs),
        .win_exp (w_wexp)
    );
    reg [105:0] r3_prod;
    reg [52:0]  r3_cs;
    reg [6:0]   r3_arsh, r3_alsh, r3_brsh, r3_blsh;
    reg         r3_agone, r3_ars, r3_bgone, r3_brs;
    reg signed [15:0] r3_wexp;
    reg         r3_ps, r3_csg;
    reg [2:0]   r3_rm;
    reg         r3_ec;
    reg         r3_is;
    always @(posedge clk) begin
        r3_prod <= r2_prod; r3_cs <= r2_cs;
        r3_arsh <= w_arsh; r3_alsh <= w_alsh;
        r3_brsh <= w_brsh; r3_blsh <= w_blsh;
        r3_agone <= w_agone; r3_ars <= w_ars;
        r3_bgone <= w_bgone; r3_brs <= w_brs;
        r3_wexp <= w_wexp;
        r3_ps <= r2_ps; r3_csg <= r2_csg; r3_rm <= r2_rm; r3_ec <= r2_ec;
        r3_is <= r2_is;
    end

    //---- 级 4：对阶 mid ----
    wire [109:0] w_a_win, w_b_win;
    wire         w_a_stk, w_b_stk;
    fpu_align_mid #(.WA(106), .WB(53), .WW(110)) u_mid (
        .sig_a (r3_prod), .sig_b (r3_cs),
        .a_rsh (r3_arsh), .a_lsh (r3_alsh), .a_gone (r3_agone), .a_rs (r3_ars),
        .b_rsh (r3_brsh), .b_lsh (r3_blsh), .b_gone (r3_bgone), .b_rs (r3_brs),
        .a_win (w_a_win), .b_win (w_b_win), .a_stk (w_a_stk), .b_stk (w_b_stk)
    );
    reg [109:0] r4_awin, r4_bwin;
    reg         r4_astk, r4_bstk;
    reg signed [15:0] r4_wexp;
    reg         r4_ps, r4_csg;
    reg [2:0]   r4_rm;
    reg         r4_ec;
    reg         r4_is;
    always @(posedge clk) begin
        r4_awin <= w_a_win; r4_bwin <= w_b_win;
        r4_astk <= w_a_stk; r4_bstk <= w_b_stk;
        r4_wexp <= r3_wexp;
        r4_ps <= r3_ps; r4_csg <= r3_csg; r4_rm <= r3_rm; r4_ec <= r3_ec;
        r4_is <= r3_is;
    end

    //---- 级 5：对阶 sum ----
    wire [110:0] w_sum_tc;
    fpu_align_sum #(.WW(110)) u_sum (
        .a_win (r4_awin), .b_win (r4_bwin),
        .sa_sign (r4_ps), .sb_sign (r4_csg), .sum_tc (w_sum_tc)
    );
    reg [110:0] r5_sum_tc;
    reg         r5_astk, r5_bstk;
    reg signed [15:0] r5_wexp;
    reg         r5_ps, r5_csg;
    reg [2:0]   r5_rm;
    reg         r5_ec;
    reg         r5_is;
    always @(posedge clk) begin
        r5_sum_tc <= w_sum_tc;
        r5_astk <= r4_astk; r5_bstk <= r4_bstk;
        r5_wexp <= r4_wexp;
        r5_ps <= r4_ps; r5_csg <= r4_csg; r5_rm <= r4_rm; r5_ec <= r4_ec;
        r5_is <= r4_is;
    end

    //---- 级 6（组合 fix → 舍入级 A 寄存器）----
    wire [109:0] w_win;
    wire         w_win_sign, w_win_sticky;
    fpu_align_fix #(.WW(110)) u_fix (
        .sum_tc (r5_sum_tc), .a_stk (r5_astk), .b_stk (r5_bstk),
        .sa_sign (r5_ps), .sb_sign (r5_csg),
        .win (w_win), .win_sign (w_win_sign), .win_sticky (w_win_sticky)
    );
    wire exact_cancel = (w_win == 110'd0) & ~w_win_sticky & r5_ec;
    wire round_sign   = w_win_sign | (exact_cancel & (r5_rm == 3'b010));

    // 舍入模式与模式位都随流水携带到舍入器输入（与原生 r5_rm 同位置）
    wire [2:0] r5_rm_w = r5_rm;

    //---- 级 6~8 + 末级：一次舍入（双模）----
    wire [63:0] round_result;
    wire [4:0]  round_flags;
    fpu_round_dual #(.WW(110), .QW(54)) u_round (
        .clk       (clk),
        .is_s      (r5_is),
        .sign      (round_sign),
        .sig       (w_win),
        .sticky_in (w_win_sticky),
        .exp       (r5_wexp),
        .rm        (r5_rm_w),
        .result    (round_result),
        .fflags    (round_flags)
    );

    localparam integer LAT = 8;
    wire [68:0] sp_d;
    assign sp_d = {sp_r, sp_f};
    wire [68:0] sp_q;
    fpu_delay #(.W(69), .N(LAT)) u_spdly (.clk (clk), .d (sp_d), .q (sp_q));
    wire [63:0] sp_r_q = sp_q[68:5];
    wire [4:0]  sp_f_q = sp_q[4:0];
    wire        sp_e_q;
    fpu_delay #(.W(1), .N(LAT)) u_sped (.clk (clk), .d (is_special), .q (sp_e_q));

    assign result = sp_e_q ? sp_r_q : round_result;
    assign fflags = sp_e_q ? sp_f_q : round_flags;
endmodule
