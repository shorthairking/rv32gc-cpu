//==============================================================================
// fpu_add.v —— 浮点加减（F/D）+ 共享舍入原语（fpu_round_s / fpu_round_d）
//==============================================================================
// 项目  : rv32gc-cpu（2A 单发射顺序 5 级基线核）
// 规格  : docs/design/08-baseline-5stage.md §5.3（fpu_add.v / fpu_mul.v 行）
//         IEEE-754-2008 binary32/binary64；RISC-V F/D
//         （riscv-isa-manual/src/unpriv/f-st-ext.adoc:215-222；d-st-ext.adoc:117-129）
//
// 语义要点（逐条对照规范）：
//   ① fadd.s/d = rs1 + rs2；fsub.s/d = rs1 − rs2（rs2 取反号后走同一通路）。
//   ② NaN：任一输入 NaN ⇒ canonical NaN；含 sNaN ⇒ 同时置 NV
//      （f-st-ext.adoc:134-139 canonical_NaN / F_canonical_NaN）。
//   ③ Inf + Inf 异号 ⇒ NV + canonical NaN；同号 ⇒ 该符号 Inf。
//   ④ 精确抵消（x + (−x)）⇒ rm≠RDN 给 +0，rm=RDN 给 −0。
//   ⑤ 零 + 零：同号 ⇒ 该符号零；异号 ⇒ RNE/RMM/RUP 给 +0，RDN 给 −0。
//   ⑥ tininess after rounding：UF 在"舍入后仍亚正规或归零、且不精确"时置位
//      （f-st-ext.adoc:186-188 norm:ieee_std_tininess）。
//   ⑦ fflags 精确：NV/DZ(无)/OF/UF/NX。
//
// ★ 缺陷修复记录（2026-09-14）——精确抵消零的符号（IEEE-754-2008 §6.3）
//   原实现只把零符号用在 both_zero 特殊值通路（zero_sign）。两个**非零**操作数
//   精确抵消时 sum_mag==0 掉进舍入原语，而 fpu_round_s/d 的 sign 接的是
//   sum_sign（精确抵消时恒为 0）⇒ 无论舍入模式都返回 +0：违反 §6.3 对 RDN 的
//   −0 要求（fadd.s(1.0,−1.0,RDN) 曾给 0x00000000，应为 0x80000000）。
//   修复：在四处舍入调用前新增 exact_cancel 判据（fpu_add_s/d：两个非零操作数
//   等值异号；fpu_fma_s/d：加数对阶后与积精确异号等值），把它并入舍入符号
//      round_sign = sum_sign | (exact_cancel & (rm == RDN))
//   精确抵消时 sum_mag==0 ⇒ 舍入原语走 zero_out 分支，只取符号、不产生
//   OF/UF/NX，故该修复不改变 fflags。(+0)+(−0) 双零通路与 RNE/RTZ/RUP/RMM
//   行为均保持不变。
//   验证：.work_fpu/verify_cancel.sh（定向"精确抵消+RDN"家族 ≥2 万例）与定点
//   TB .work_fpu/tb_cancel_directed.sv；原均匀随机家族不含该用例（实测
//   add_s 0/6000、add_d 0/600、fma_s 0/4000、fma_d 0/500），故此前未暴露。
//
// ★ 缺陷修复记录（2026-09-14，#2）——FMA-NV 误报（NaN 乘数 × Inf + 异号 Inf 加数）
//   现象：fpu_fma_s/fpu_fma_d 在"任一乘数为 NaN、另一乘数为 Inf、且加数（含
//   neg_add / neg_prod 取反后）为异号 Inf"时给 NV=1；结果位本就正确（canonical
//   NaN），仅 fflags 错。IEEE-754-2008 / RISC-V 口径：qNaN 输入**不**报 NV，
//   唯一允许"qNaN 也报 NV"的场景是 0×∞（f-st-ext.adoc:310-312
//   norm:fma_nv_flag，即 p_inf_zero 项，本修复**不动**它）。
//   根因：`inf_special = p_inf_zero | (p_inf & c_inf & (p_sign != c_sign))` 与
//   give_nan 里的同一项没有排除 NaN 操作数。p_inf = a_inf|b_inf 只判"指数全 1"，
//   NaN 的 frac≠0 不在该判据内 ⇒ NaN×Inf 也命中；NaN 的符号位又随机扰动
//   p_sign，使加数为**同号** Inf 时也可能被判成异号相消。
//   修复：该项统一提取为
//      inf_opp = p_inf & c_inf & (p_sign != c_sign) & ~any_nan
//   （any_nan = a_nan | b_nan | c_nan），由 inf_special / give_nan 共用一份，
//   杜绝同一表达式两处不同步再次引入偏差。结果位不变（give_nan 本来就被
//   any_nan 覆盖 ⇒ canonical NaN）；add 侧无此问题（a_inf/b_inf 已要求
//   frac==0，本身排除 NaN）故未动。
//   验证：定点 TB（/tmp/tb_fma_nv_directed.sv，26 例，含 neg_prod/neg_add/RDN
//   变体与控制例）修复前 10 例 FAIL（全部"结果对、NV 误置"）→ 修复后 0 例 FAIL；
//   .work_fpu/verify_cancel.sh 12345（fmad）/777（fma）由 FAIL 转 PASS；控制例
//   真 Inf−Inf 仍 NV=1、0×∞+qNaN 仍 NV=1、同号 Inf 加数仍 NV=0。
//
// ★ 红线 1/2（IP 优先 + 双分支）
//   检索结论：Vivado 有 `Floating-Point Operator v7.1` IP，支持 Add/Sub、
//   Multiply、FMA、Divide、Square root，可配 binary32/64 与多周期流水 ⇒
//   综合分支（`RV32GC_USE_VIVADO_IP`）例化该 IP；仿真分支（默认）走本文件
//   行为模型（**可综合**、纯整数运算），保证 iverilog/Verilator 回归不依赖
//   Vivado（红线 2）。★ 不使用任何 FPGA 原语（红线 1）。
//
// 位宽规划（**完全精确对阶**，不依赖 sticky 正确性）
//   两个操作数按较小指数对齐时，最多需要 (大指数 − 小指数 + 有效数位宽) 位。
//   S：指数域 8 bit ⇒ 指数差 ≤ 254；有效数 24 bit ⇒ 用 512 bit 移位域。
//   D：指数域 11 bit ⇒ 指数差 ≤ 2046；有效数 53 bit ⇒ 用 4096 bit 移位域。
//   ★ 以位宽换正确性：2A 允许（性能非门禁），并彻底消除"sticky 算错 ⇒ 1 ulp
//     静默错"这一最常见的 FPU 缺陷源。舍入原语按"实际 ulp 粒度"做，
//     规格与验证见 .work_fpu/HW_ROUND_VERIFIED.md（60 万用例位与 fflags 全等）。
//==============================================================================
`include "rv32_defs.vh"
`include "core_params.vh"

//==============================================================================
// 前导零 / 最高有效位：组合函数（纯 function，无副作用）
//------------------------------------------------------------------------------
// ★ 2026-09-17 仿真吞吐优化（**语义逐位不变**，仅为让 arch-test 的 F 组能在
//   run.sh 的超时内跑完）：
//   原实现是"逐位扫全宽"的线性搜索（msb8192 每次调用 8192 次循环）。这些原语在
//   全设计里有 12 个实例（fpu_add 4 + fpu_cvt 4 + fpu_div_sqrt 2 + fpu_mul 2），
//   且 fpu_round_s/d 每次都调 2 遍 ⇒ 每拍被解释执行的循环迭代数 ≈
//     6×2×1024 + 6×2×8192 = 110 592 次
//   实测（.work 基准 tb_fpu_bench）这是 iverilog 下 FPU 的主要仿真开销。
//   ⇒ 改为**分层搜索**：先在 512 bit 块（16 个）里找最高的非零块，再在 64 bit
//     子块（8 个）里找，最后只对命中的 64 bit 做逐位扫描。
//     最坏 16+8+64 = 88 次迭代（原 8192），结果与原线性搜索**完全一致**
//     （返回最高置 1 位下标；v==0 时返回 0，与原实现同）。
//   等价性证据：优化后重跑 .work_fpu 的黄金模型全量比对（add/addd/fma/fmad/
//     muls/muld/div/sqrt/cvt/cmp）与 arch-test rv32i/F 全组，位与 fflags 全等。
//==============================================================================
// 64 bit 叶子：最高置位下标（v==0 ⇒ 0）——最多 64 次迭代
function [5:0] msb64;
    input [63:0] v;
    integer j;
    begin
        msb64 = 6'd0;
        for (j = 0; j < 64; j = j + 1) begin
            if (v[j]) msb64 = j[5:0];
        end
    end
endfunction

function [12:0] msb1024;                   // 1024 bit 域的最高有效位位置
    input [1023:0] v;
    integer k;
    reg     found;
    begin
        msb1024 = 13'd0;
        found   = 1'b0;
        for (k = 15; k >= 0; k = k - 1) begin          // 16 × 64 bit 块，高→低
            if (!found && (|v[k*64 +: 64])) begin
                msb1024 = (k*64) + msb64(v[k*64 +: 64]);
                found   = 1'b1;
            end
        end
    end
endfunction

function [12:0] msb512;                    // 512 bit 域（D 侧复用）
    input [511:0] v;
    integer k;
    reg     found;
    begin
        msb512 = 13'd0;
        found  = 1'b0;
        for (k = 7; k >= 0; k = k - 1) begin           // 8 × 64 bit 块，高→低
            if (!found && (|v[k*64 +: 64])) begin
                msb512 = (k*64) + msb64(v[k*64 +: 64]);
                found  = 1'b1;
            end
        end
    end
endfunction

function [13:0] msb8192;                   // 8192 bit 域的最高有效位位置
    input [8191:0] v;
    integer k, j;
    reg     found;
    reg [511:0] chunk;
    begin
        msb8192 = 14'd0;
        found   = 1'b0;
        for (k = 15; k >= 0; k = k - 1) begin          // 16 × 512 bit 大块，高→低
            chunk = v[k*512 +: 512];
            if (!found && (|chunk)) begin
                for (j = 7; j >= 0; j = j - 1) begin   // 8 × 64 bit 子块，高→低
                    if (!found && (|chunk[j*64 +: 64])) begin
                        msb8192 = (k*512) + (j*64) + msb64(chunk[j*64 +: 64]);
                        found   = 1'b1;
                    end
                end
            end
        end
    end
endfunction

//==============================================================================
// fpu_round_s —— 单精度舍入原语
//   value = sig × 2^exp（sig 无符号、可为 0；exp 有符号）
//   输出：result = 32 bit 结果（**不含 NaN-boxing**，由调用者补高位 1）；
//         fflags = {NV,DZ,OF,UF,NX}（本原语只可能产生 OF/UF/NX）
//   规格来源：.work_fpu/HW_ROUND_VERIFIED.md（已验证与黄金模型位+flags 全等）
//==============================================================================
module fpu_round_s (
    input  wire           sign,
    input  wire [1023:0]  sig,
    input  wire signed [12:0] exp,
    input  wire [2:0]    rm,
    output wire [31:0]   result,
    output wire [4:0]    fflags
);
    // ★ 必须显式定宽且有符号：写成 `integer`（32 bit）会与 14 bit 的 e_res
    //   做 32 位运算后截断，静默丢掉高位（实测踩到：1.0 被算成 2^-126）。
    localparam signed [5:0]  FB   = 6'sd23;
    localparam signed [13:0] BIAS = 14'sd127;
    localparam signed [12:0] MIN_SUB  = -13'sd149;   // 1 - 127 - 23
    localparam signed [12:0] E_MIN    = -13'sd126;   // 1 - 127
    localparam signed [12:0] EMAX_S   = 13'sd255;

    wire sig_zero = (sig == 1024'd0);

    // ---- msb / 指数 ----
    wire [12:0] msb = msb1024(sig);
    // ★ 当 sig==0 时 msb512 返回 0，e_unb 无意义；后续用 sig_zero 屏蔽，
    //    但为避免 x 传播到打包逻辑，这里让 msb 在零时为 0 即可（结果被屏蔽）。
    wire signed [13:0] e_unb      = exp + $signed({1'b0, msb});
    wire signed [13:0] natural_ulp = e_unb - FB;

    // ★ 钳位判据在 ulp 上（不是 e_unb 上）—— HW_ROUND_VERIFIED.md 坑 1
    wire signed [13:0] ulp_ex = (natural_ulp >= MIN_SUB) ? natural_ulp : MIN_SUB;

    // value / 2^ulp = sig × 2^(exp - ulp)
    wire signed [13:0] diff = exp - ulp_ex;                   // exp - ulp
    wire               do_right = (diff < 0);                  // 需右移丢弃
    // 右移位数（do_right 时有效）：ulp - exp = -diff，范围 [1, 149+52]
    // 左移位数（!do_right 时有效）：exp - ulp = diff，范围 [0, 23]
    wire [13:0] neg_diff = -diff;
    wire [13:0] rsh = do_right ? neg_diff : 14'd0;
    wire [13:0] lsh = do_right ? 14'd0    : diff;

    // ---- 移位域：S 有效数 ≤ 24 bit + 左移余量 ≤ 23 ⇒ 512 bit 充裕 ----
    wire [1023:0] sigx = sig;
    wire [1023:0] q_shifted = do_right ? (sigx >> rsh[8:0])
                                       : (sigx << lsh[8:0]);

    // round bit / sticky（仅 do_right 有意义）
    wire [13:0] rsh_m1 = rsh - 14'd1;
    wire round_bit = do_right ? ((sigx >> rsh_m1[8:0]) & 1024'd1) : 1'b0;
    wire sticky    = do_right ? (|(sigx & ((1024'd1 << rsh_m1[8:0]) - 1024'd1))) : 1'b0;
    wire inexact   = round_bit | sticky;

    wire [1023:0] q0  = q_shifted;
    wire         lsb = q0[0];

    // ---- 增量（rm: 000 RNE / 001 RTZ / 010 RDN / 011 RUP / 100 RMM） ----
    wire inc = (rm == 3'b000) ? (round_bit & (sticky | lsb)) :
               (rm == 3'b100) ?  round_bit :
               (rm == 3'b001) ?  1'b0 :
               (rm == 3'b011) ? ~sign :
               (rm == 3'b010) ?  sign :
                                 (round_bit & (sticky | lsb)); // 保留 rm ⇒ RNE

    wire [1023:0] q = q0 + {1023'b0, (inexact & inc)};

    // ---- 结果打包 ----
    wire q_zero = (q == 1024'd0);
    wire [12:0] q_msb = msb1024(q);
    wire signed [13:0] e_res = ulp_ex + $signed({1'b0, q_msb});
    wire signed [13:0] e_f   = e_res + BIAS;

    wire overflow  = ~q_zero & (e_f >= EMAX_S);
    wire subnormal = ~q_zero & (e_res < E_MIN);

    // 亚正规：exp_field = 0；fraction = q（此时 ulp_ex == MIN_SUB，q 即 fraction）
    // 但 q 可能已达 2^23（进位到最小正规数）⇒ 单独处理
    wire sub_carry = (q >= 1024'd8_388_608);           // 2^23
    wire [31:0] sub_out = sub_carry ? {sign, 8'd1, 23'd0}
                                    : {sign, 8'd0, q[22:0]};
    // 正常：fraction = q 的低 FB 位（q 已按 ulp 对齐到 msb ≥ FB）
    wire [31:0] norm_out = {sign, e_f[7:0], q[22:0]};

    // 溢出饱和：RTZ 恒最大有限数；RDN 仅正数；RUP 仅负数
    wire of_to_max = (rm == 3'b001) || ((rm == 3'b010) & ~sign) || ((rm == 3'b011) &  sign);
    wire [31:0] zero_out = {sign, 31'b0};
    wire [31:0] of_out   = of_to_max ? {sign, 8'hFE, 23'h7F_FFFF} : {sign, 8'hFF, 23'b0};

    assign result = (sig_zero | q_zero) ? zero_out :
                    overflow            ? of_out   :
                    subnormal           ? sub_out  :
                                          norm_out;

    // ---- fflags（本原语产 OF/UF/NX；NV/DZ 由上层按特殊值给出） ----
    wire of_fl = overflow;
    // ---- ★ UF（tininess after rounding）修复记录（2026-09-17）-------------------
    //   现象（arch-test rv32i/F）：F-fmadd.s-06 2 处、F-fmadd.s-07 3 处 fflags
    //   dut=0x01(NX) / spike=0x03(UF|NX)。样例（F-fmadd.s-06）：
    //     c = 0x807FFFFF（= −最大亚正规 = −(2^−126 − 2^−149)）、积 = 约 −1.6·2^−205，
    //     rm = RDN ⇒ 精确值落在"最大亚正规"与"最小正规数"之间的**空隙**里，
    //     舍入后恰好等于最小正规数 2^−126（结果位两者一致）。
    //   根因：原判据用**有界指数**下的舍入结果判 tiny
    //     `uf = inexact & (subnormal | q_zero)`
    //   —— 该结果此刻是"最小正规数"，于是判 non-tiny；但 IEEE 754-2008 §7.5 的
    //   tininess 是"**无界指数**下舍入后的结果是否仍 < 2^emin"：本例无界网格细一位
    //   （2^−150），舍入后是 2^−126 − 2^−150 < 2^−126 ⇒ **tiny**（Spike 实测 0x03 ✓）。
    //   规范出处：riscv-isa-manual f-st-ext.adoc:186-188「tininess is detected after
    //   rounding」；softfloat `roundPackToF32` 的 isTiny 等价式
    //     `(exp < -1) || (sig + roundIncrement < 0x80000000)`
    //   （本实现按该等价式逐条落地，Spike 定向用例 4/4 对齐，见交付说明）。
    //   等价判据（natural_ulp = ulp_ex 未钳位时的自然 ulp）：
    //     · 未钳位（natural_ulp ≥ MIN_SUB，即精确值 ≥ 2^emin）
    //         ⇒ 结果 ≥ 2^emin ⇒ 不可能 tiny；此域内沿用原判据（亚正规/归零）。
    //     · 钳位且 natural_ulp ≤ MIN_SUB−2（精确值低至少两个二进制阶）
    //         ⇒ 自然网格至少细 2 位，舍入绝不可能抬到 2^emin ⇒ tiny。
    //     · 钳位且 natural_ulp == MIN_SUB−1（精确值落在最小正规数**正下方**一个
    //       自然 ulp 内）⇒ 只有"自然网格舍入恰好进位到 2^emin"才 non-tiny：
    //         需要 q0 == 2^FB−1（粗网格上恰在最小正规数下方一个 ulp 内）且
    //         round_bit & sticky（余量 ≥ 3/4 粗 ulp）且**该舍入模式会把幅值进位**
    //         （RNE/RMM/保留值；RUP 仅正数；RDN 仅负数；RTZ 与反号方向永不进位）。
    wire clamped_ulp  = (natural_ulp < MIN_SUB);
    wire last_ulp_bel = (natural_ulp == (MIN_SUB - 14'sd1)) &
                        (q0 == 1024'd8_388_607);            // q0 == 2^23 − 1
    wire inc_like     = (rm != 3'b001) &                    // RTZ 不进位
                        ~((rm == 3'b011) &  sign) &         // RUP：负数不进位
                        ~((rm == 3'b010) & ~sign);          // RDN：正数不进位
    wire up_to_normal = last_ulp_bel & inc_like & round_bit & sticky;
    wire tiny         = clamped_ulp ? ~up_to_normal : (subnormal | q_zero);
    wire uf_fl = (~overflow) & inexact & tiny;
    wire nx_fl = inexact & ~overflow;      // overflow 时 NX 恒置，见下
    assign fflags = {1'b0, 1'b0, of_fl, uf_fl, (nx_fl | of_fl)};
endmodule

//==============================================================================
// fpu_round_d —— 双精度舍入原语（与 fpu_round_s 同规格，位宽不同）
//==============================================================================
module fpu_round_d (
    input  wire           sign,
    input  wire [8191:0]  sig,
    input  wire signed [13:0] exp,
    input  wire [2:0]     rm,
    output wire [63:0]    result,
    output wire [4:0]     fflags
);
    localparam signed [6:0]  FB   = 7'sd52;
    localparam signed [14:0] BIAS = 15'sd1023;
    localparam signed [13:0] MIN_SUB = -14'sd1074;   // 1 - 1023 - 52
    localparam signed [13:0] E_MIN   = -14'sd1022;   // 1 - 1023
    localparam signed [13:0] EMAX_D  = 14'sd2047;

    wire sig_zero = (sig == 8192'd0);

    wire [13:0] msb = msb8192(sig);
    wire signed [14:0] e_unb       = exp + $signed({1'b0, msb});
    wire signed [14:0] natural_ulp = e_unb - FB;
    wire signed [14:0] ulp_ex = (natural_ulp >= MIN_SUB) ? natural_ulp : MIN_SUB;

    wire signed [14:0] diff = exp - ulp_ex;
    wire               do_right = (diff < 0);
    wire [14:0] neg_diff = -diff;
    wire [14:0] rsh = do_right ? neg_diff : 15'd0;
    wire [14:0] lsh = do_right ? 15'd0    : diff;

    wire [8191:0] sigx = sig;
    wire [8191:0] q_shifted = do_right ? (sigx >> rsh[11:0])
                                       : (sigx << lsh[11:0]);

    wire [14:0] rsh_m1 = rsh - 15'd1;
    wire round_bit = do_right ? ((sigx >> rsh_m1[11:0]) & 8192'd1) : 1'b0;
    wire sticky    = do_right ? (|(sigx & ((8192'd1 << rsh_m1[11:0]) - 8192'd1))) : 1'b0;
    wire inexact   = round_bit | sticky;

    wire [8191:0] q0  = q_shifted;
    wire          lsb = q0[0];

    wire inc = (rm == 3'b000) ? (round_bit & (sticky | lsb)) :
               (rm == 3'b100) ?  round_bit :
               (rm == 3'b001) ?  1'b0 :
               (rm == 3'b011) ? ~sign :
               (rm == 3'b010) ?  sign :
                                 (round_bit & (sticky | lsb));

    wire [8191:0] q = q0 + {8191'b0, (inexact & inc)};

    wire q_zero = (q == 8192'd0);
    wire [13:0] q_msb = msb8192(q);
    wire signed [14:0] e_res = ulp_ex + $signed({1'b0, q_msb});
    wire signed [14:0] e_f   = e_res + BIAS;

    wire overflow  = ~q_zero & (e_f >= EMAX_D);
    wire subnormal = ~q_zero & (e_res < E_MIN);

    // 2^52 = 4503599627370496
    wire sub_carry = (q >= 8192'd4503599627370496);
    wire [63:0] sub_out = sub_carry ? {sign, 11'd1, 52'd0}
                                    : {sign, 11'd0, q[51:0]};
    wire [63:0] norm_out = {sign, e_f[10:0], q[51:0]};

    wire of_to_max = (rm == 3'b001) || ((rm == 3'b010) & ~sign) || ((rm == 3'b011) &  sign);
    wire [63:0] zero_out = {sign, 63'b0};
    wire [63:0] of_out   = of_to_max ? {sign, 11'h7FE, 52'hF_FFFF_FFFF_FFFF}
                                     : {sign, 11'h7FF, 52'b0};

    assign result = (sig_zero | q_zero) ? zero_out :
                    overflow            ? of_out   :
                    subnormal           ? sub_out  :
                                          norm_out;

    wire of_fl = overflow;
    //   ★ UF：tininess after rounding（无界指数口径）——判据与修复记录见
    //     fpu_round_s 同名段落（本处为 D 侧同构实现，FB=52 ⇒ q0 判据 2^52−1）。
    wire clamped_ulp  = (natural_ulp < MIN_SUB);
    wire last_ulp_bel = (natural_ulp == (MIN_SUB - 15'sd1)) &
                        (q0 == 8192'd4_503_599_627_370_495);   // q0 == 2^52 − 1
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
// fpu_add_s —— 单精度加法/减法（fadd.s / fsub.s）
//   语义：rs1 ± rs2，单次舍入；NaN/Inf/零 特殊值按规范
//         （f-st-ext.adoc:134-139 canonical_NaN、:215-222 fadd/fsub 定义）
//   实现：**完全精确对阶**——两个有效数都放进 512 bit 移位域，按较小指数
//         对齐后再做有符号加。位宽足以容纳最大指数差（254），对齐不丢位，
//         因此不存在"sticky 取值错 ⇒ 1 ulp 静默错"的风险。
//   输入 op_sub=1 表示减法（对 rs2 取反号后走同一通路）。
//==============================================================================
module fpu_add_s (
    input  wire [63:0] a,          // S 操作数（低 32 bit 有效）
    input  wire [63:0] b,
    input  wire        op_sub,
    input  wire [2:0]  rm,
    output wire [31:0] result,     // 不含 NaN-boxing（上层补高 32 位 1）
    output wire [4:0]  fflags
);
    // ---- 拆字段 ----
    wire        a_sign     = a[31];
    wire        b_sign     = b[31] ^ op_sub;      // 减法 = 取反号
    wire [7:0]  a_exp      = a[30:23];
    wire [7:0]  b_exp      = b[30:23];
    wire [22:0] a_frac     = a[22:0];
    wire [22:0] b_frac     = b[22:0];

    wire a_nan  = (a_exp == 8'hFF) && (a_frac != 0);
    wire b_nan  = (b_exp == 8'hFF) && (b_frac != 0);
    wire a_inf  = (a_exp == 8'hFF) && (a_frac == 0);
    wire b_inf  = (b_exp == 8'hFF) && (b_frac == 0);
    wire a_zero = (a_exp == 0) && (a_frac == 0);
    wire b_zero = (b_exp == 0) && (b_frac == 0);
    wire a_snan = a_nan && ~a[22];
    wire b_snan = b_nan && ~b[22];

    // 有效数（亚正规隐藏位为 0）
    wire [23:0] a_sig = (a_exp == 0) ? {1'b0, a_frac} : {1'b1, a_frac};
    wire [23:0] b_sig = (b_exp == 0) ? {1'b0, b_frac} : {1'b1, b_frac};

    // 无偏指数：亚正规取 -126（配合 value = sig × 2^-23 × 2^-126）
    wire signed [12:0] a_eunb = (a_exp == 0) ? -13'sd126
                                             : ($signed({5'b0, a_exp}) - 13'sd127);
    wire signed [12:0] b_eunb = (b_exp == 0) ? -13'sd126
                                             : ($signed({5'b0, b_exp}) - 13'sd127);

    // ---- 精确对阶 ----
    // value = sig × 2^(e_unb - 23)；取 base = min(ea,eb) - 23
    wire signed [12:0] base = (a_eunb < b_eunb) ? (a_eunb - 13'sd23)
                                                : (b_eunb - 13'sd23);
    wire [12:0] shift_a = a_eunb - 13'sd23 - base;     // >= 0
    wire [12:0] shift_b = b_eunb - 13'sd23 - base;     // >= 0
    // 512 bit 域：24 bit 有效数左移最多 254 bit，余量充足
    wire [511:0] a_al = {488'b0, a_sig} << shift_a[8:0];
    wire [511:0] b_al = {488'b0, b_sig} << shift_b[8:0];

    // ---- 有符号加：用补码形式统一处理 ----
    // 取负 = 按位取反 + 1；两操作数各 512 bit，和用 513 bit 承载进位
    wire [512:0] a_tc = a_sign ? ({1'b1, ~a_al} + 513'd1) : {1'b0, a_al};
    wire [512:0] b_tc = b_sign ? ({1'b1, ~b_al} + 513'd1) : {1'b0, b_al};
    wire [512:0] sum_tc = a_tc + b_tc;

    wire         sum_sign = sum_tc[512];
    wire [511:0] sum_mag  = sum_sign ? (~sum_tc[511:0] + 512'd1) : sum_tc[511:0];
    wire [1023:0] sum_mag_x = sum_mag;   // 零扩展到舍入原语域

    // ---- 特殊值判据（必须先于舍入原语声明：精确抵消零的符号要用到 both_zero） ----
    wire any_nan   = a_nan | b_nan;
    wire nan_nv    = a_snan | b_snan;
    wire inf_opp   = a_inf & b_inf & (a_sign != b_sign);   // Inf − Inf 同号? 见下
    wire both_zero = a_zero & b_zero;

    // 注意：b_sign 已含 op_sub 的取反，故"符号不同"即代表异号无穷相减 ⇒ NV
    wire zero_sign = (a_sign == b_sign) ? a_sign : (rm == 3'b010);

    // ---- 精确抵消零的符号（IEEE-754-2008 §6.3；缺陷修复见文件头） ----
    // 两个**非零**操作数等值异号（x + (−x) / x − x）⇒ 精确和为零：除 RDN 外给
    // +0，RDN 给 −0。同号非零之和不可能为零；异号双零已由 both_zero 单独处理，
    // 故 sum_mag==0 且非 both_zero 即该情形（此时 sum_sign 恒为 0）。
    wire exact_cancel = (sum_mag == 512'd0) & ~both_zero & (a_sign != b_sign);
    wire round_sign   = sum_sign | (exact_cancel & (rm == 3'b010));

    // ---- 交给共享舍入原语 ----
    wire [31:0] round_result;
    wire [4:0]  round_flags;
    fpu_round_s u_round (
        .sign   (round_sign),
        .sig    (sum_mag_x),
        .exp    (base),
        .rm     (rm),
        .result (round_result),
        .fflags (round_flags)
    );

    localparam [31:0] CANON_S = 32'h7FC0_0000;

    assign result = (any_nan | inf_opp) ? CANON_S :
                    a_inf               ? {a_sign, 8'hFF, 23'b0} :
                    b_inf               ? {b_sign, 8'hFF, 23'b0} :
                    both_zero           ? {zero_sign, 31'b0} :
                                          round_result;

    // ---- fflags ----
    // ★ 关键：一旦走了特殊值通路（NaN / Inf / 双零），舍入原语的输出**无效**
    //   （它会把 NaN/Inf 的位型当作普通数参与对阶与舍入）。必须屏蔽，否则会
    //   凭空产生 OF/NX（本实现实测踩到：-inf + qNaN 报出 OF|NX）。
    wire is_special = any_nan | a_inf | b_inf | both_zero;
    wire nv = nan_nv | inf_opp;
    assign fflags = { nv,
                      1'b0,
                      is_special ? 1'b0 : round_flags[2],
                      is_special ? 1'b0 : round_flags[1],
                      is_special ? 1'b0 : round_flags[0] };
endmodule

//==============================================================================
// fpu_add_d —— 双精度加法/减法（fadd.d / fsub.d）
//   与 fpu_add_s 同构，仅位宽与常量不同（有效数 53 bit、指数 11 bit）。
//   对阶域用 4096 bit：指数差最大 2046，53+2046 < 4096，对齐不丢位。
//==============================================================================
module fpu_add_d (
    input  wire [63:0] a,
    input  wire [63:0] b,
    input  wire        op_sub,
    input  wire [2:0]  rm,
    output wire [63:0] result,
    output wire [4:0]  fflags
);
    wire        a_sign = a[63];
    wire        b_sign = b[63] ^ op_sub;
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

    // 无偏指数（亚正规取 -1022）
    wire signed [13:0] a_eunb = (a_exp == 0) ? -14'sd1022
                                             : ($signed({3'b0, a_exp}) - 14'sd1023);
    wire signed [13:0] b_eunb = (b_exp == 0) ? -14'sd1022
                                             : ($signed({3'b0, b_exp}) - 14'sd1023);

    // ---- 精确对阶 ----
    wire signed [13:0] base = (a_eunb < b_eunb) ? (a_eunb - 14'sd52)
                                                : (b_eunb - 14'sd52);
    wire [13:0] shift_a = a_eunb - 14'sd52 - base;
    wire [13:0] shift_b = b_eunb - 14'sd52 - base;

    // 4096 bit 域：53 bit 有效数左移最多 2046 bit
    wire [4095:0] a_al = {4043'b0, a_sig} << shift_a[11:0];
    wire [4095:0] b_al = {4043'b0, b_sig} << shift_b[11:0];

    wire [4096:0] a_tc = a_sign ? ({1'b1, ~a_al} + 4097'd1) : {1'b0, a_al};
    wire [4096:0] b_tc = b_sign ? ({1'b1, ~b_al} + 4097'd1) : {1'b0, b_al};
    wire [4096:0] sum_tc = a_tc + b_tc;

    wire          sum_sign = sum_tc[4096];
    wire [4095:0] sum_mag  = sum_sign ? (~sum_tc[4095:0] + 4096'd1) : sum_tc[4095:0];
    wire [8191:0] sum_mag_x = sum_mag;   // 零扩展到舍入原语域

    // ---- 特殊值判据（必须先于舍入原语声明：精确抵消零的符号要用到 both_zero） ----
    wire any_nan   = a_nan | b_nan;
    wire nan_nv    = a_snan | b_snan;
    wire inf_opp   = a_inf & b_inf & (a_sign != b_sign);
    wire both_zero = a_zero & b_zero;
    wire zero_sign = (a_sign == b_sign) ? a_sign : (rm == 3'b010);

    // ---- 精确抵消零的符号（IEEE-754-2008 §6.3；缺陷修复见文件头） ----
    // 同 fpu_add_s：两个非零操作数等值异号 ⇒ 精确零，RDN 给 −0、其余模式 +0。
    wire exact_cancel = (sum_mag == 4096'd0) & ~both_zero & (a_sign != b_sign);
    wire round_sign   = sum_sign | (exact_cancel & (rm == 3'b010));

    wire [63:0] round_result;
    wire [4:0]  round_flags;
    fpu_round_d u_round (
        .sign   (round_sign),
        .sig    (sum_mag_x),
        .exp    (base),
        .rm     (rm),
        .result (round_result),
        .fflags (round_flags)
    );

    localparam [63:0] CANON_D = 64'h7FF8_0000_0000_0000;

    assign result = (any_nan | inf_opp) ? CANON_D :
                    a_inf               ? {a_sign, 11'h7FF, 52'b0} :
                    b_inf               ? {b_sign, 11'h7FF, 52'b0} :
                    both_zero           ? {zero_sign, 63'b0} :
                                          round_result;

    // 特殊值通路下屏蔽舍入标志（同 fpu_add_s 的理由）
    wire is_special = any_nan | a_inf | b_inf | both_zero;
    wire nv = nan_nv | inf_opp;
    assign fflags = { nv, 1'b0,
                      is_special ? 1'b0 : round_flags[2],
                      is_special ? 1'b0 : round_flags[1],
                      is_special ? 1'b0 : round_flags[0] };
endmodule

//==============================================================================
// fpu_fma_s —— 单精度融合乘加（fmadd.s / fmsub.s / fnmsub.s / fnmadd.s）
//==============================================================================
// 语义（riscv-isa-manual/src/unpriv/f-st-ext.adoc:267-280）：
//   fmadd.s  = rs1×rs2 + rs3
//   fmsub.s  = rs1×rs2 − rs3
//   fnmsub.s = −(rs1×rs2) + rs3        （注意：RISC-V 的 fnmsub 取反的是**积**）
//   fnmadd.s = −(rs1×rs2) − rs3
//   对应本例化参数：neg_prod（取反积）、neg_add（取反加数）
//     fmadd : neg_prod=0 neg_add=0
//     fmsub : neg_prod=0 neg_add=1
//     fnmsub: neg_prod=1 neg_add=0
//     fnmadd: neg_prod=1 neg_add=1
//
// ★ 必须**单次舍入**（08 §5.3 要求 ③）：
//   本实现先算出**精确**乘积（24×24=48 bit，无任何舍入），再把加数按
//   公共基准精确对齐后做一次有符号加，最后只调用一次舍入原语。
//   ⇒ 结构上不可能出现"先舍入积、再舍入和"的两次舍入。
//
// 规范细节（f-st-ext.adoc:310-312 norm:fma_nv_flag）：
//   当被乘数为 Inf 与 0 时**必须**置 NV，**即使加数是 quiet NaN**。
//   （IEEE-754-2008 允许但不要求对 Inf×0+qNaN 报 NV；RISC-V 要求报。）
//==============================================================================
module fpu_fma_s (
    input  wire [63:0] a,          // rs1（低 32 bit 有效）
    input  wire [63:0] b,          // rs2
    input  wire [63:0] c,          // rs3
    input  wire        neg_prod,   // 取反积
    input  wire        neg_add,    // 取反加数
    input  wire [2:0]  rm,
    output wire [31:0] result,
    output wire [4:0]  fflags
);
    // ---- 字段 ----
    wire        a_sign = a[31];
    wire        b_sign = b[31];
    wire        c_sign = c[31] ^ neg_add;
    wire [7:0]  a_exp  = a[30:23];
    wire [7:0]  b_exp  = b[30:23];
    wire [7:0]  c_exp  = c[30:23];
    wire [22:0] a_frac = a[22:0];
    wire [22:0] b_frac = b[22:0];
    wire [22:0] c_frac = c[22:0];

    wire a_nan  = (a_exp == 8'hFF) && (a_frac != 0);
    wire b_nan  = (b_exp == 8'hFF) && (b_frac != 0);
    wire c_nan  = (c_exp == 8'hFF) && (c_frac != 0);
    wire a_inf  = (a_exp == 8'hFF) && (a_frac == 0);
    wire b_inf  = (b_exp == 8'hFF) && (b_frac == 0);
    wire c_inf  = (c_exp == 8'hFF) && (c_frac == 0);
    wire a_zero = (a_exp == 0) && (a_frac == 0);
    wire b_zero = (b_exp == 0) && (b_frac == 0);
    wire c_zero = (c_exp == 0) && (c_frac == 0);
    wire a_snan = a_nan && ~a[22];
    wire b_snan = b_nan && ~b[22];
    wire c_snan = c_nan && ~c[22];

    // 有效数
    wire [23:0] a_sig = (a_exp == 0) ? {1'b0, a_frac} : {1'b1, a_frac};
    wire [23:0] b_sig = (b_exp == 0) ? {1'b0, b_frac} : {1'b1, b_frac};
    wire [23:0] c_sig = (c_exp == 0) ? {1'b0, c_frac} : {1'b1, c_frac};

    // 无偏指数
    wire signed [12:0] a_eunb = (a_exp == 0) ? -13'sd126 : ($signed({5'b0, a_exp}) - 13'sd127);
    wire signed [12:0] b_eunb = (b_exp == 0) ? -13'sd126 : ($signed({5'b0, b_exp}) - 13'sd127);
    wire signed [12:0] c_eunb = (c_exp == 0) ? -13'sd126 : ($signed({5'b0, c_exp}) - 13'sd127);

    // ---- 精确乘积 ----
    wire        p_sign = a_sign ^ b_sign ^ neg_prod;
    wire [47:0] prod   = a_sig * b_sig;                   // 精确，无舍入
    // value(prod) = a_sig × b_sig × 2^(a_eunb-23) × 2^(b_eunb-23)
    //             = prod × 2^(a_eunb + b_eunb - 46)
    wire signed [13:0] p_exp = a_eunb + b_eunb - 13'sd46;
    // value(c) = c_sig × 2^(c_eunb - 23)
    wire signed [13:0] k_exp = c_eunb - 13'sd23;

    // ---- 公共基准：min(p_exp, k_exp)，两侧精确左移对齐 ----
    wire signed [13:0] base = (p_exp < k_exp) ? p_exp : k_exp;
    wire [13:0] sh_p = p_exp - base;      // >= 0
    wire [13:0] sh_k = k_exp - base;      // >= 0
    // 1024 bit 域：48 bit 积 + 最大指数跨度 508 ⇒ 充裕
    wire [1023:0] p_al = {976'b0, prod}   << sh_p[9:0];
    wire [1023:0] k_al = {1000'b0, c_sig} << sh_k[9:0];

    // 有符号加（补码）
    wire [1024:0] p_tc = p_sign ? ({1'b1, ~p_al} + 1025'd1) : {1'b0, p_al};
    wire [1024:0] k_tc = c_sign ? ({1'b1, ~k_al} + 1025'd1) : {1'b0, k_al};
    wire [1024:0] sum_tc = p_tc + k_tc;
    wire          sum_sign = sum_tc[1024];
    wire [1023:0] sum_mag  = sum_sign ? (~sum_tc[1023:0] + 1024'd1) : sum_tc[1023:0];

    // ---- 特殊值判据（必须先于舍入原语声明：精确抵消判据要用到它们） ----
    wire p_inf_zero = (a_inf & b_zero) | (a_zero & b_inf);   // Inf×0 ⇒ 必报 NV
    wire p_inf      = a_inf | b_inf;
    wire any_nan    = a_nan | b_nan | c_nan;

    // 积是否**恰好**为零（任一侧为零且另一侧有限）：此时结果等于把加数
    // 直接相加，零的符号必须按 IEEE 加法规则决定（不能用回合路径，它会
    // 丢掉 −0 的符号）。
    wire p_zero  = (a_zero & ~b_inf) | (b_zero & ~a_inf);
    wire p_finite_zero = p_zero & ~p_inf_zero;

    // ---- 精确抵消零的符号（IEEE-754-2008 §6.3；缺陷修复见文件头） ----
    // 加数对阶后与积**精确异号等值**（两者均非零）⇒ 精确和为零：除 RDN 外给
    // +0，RDN 给 −0。舍入通路里积与加数均非零（积为零的情形已由
    // p_finite_zero 另行处理），故 sum_mag==0 即该情形。
    wire exact_cancel = (sum_mag == 1024'd0) & ~p_finite_zero & (p_sign != c_sign);
    wire round_sign   = sum_sign | (exact_cancel & (rm == 3'b010));

    // ---- 一次舍入 ----
    wire [31:0] round_result;
    wire [4:0]  round_flags;
    fpu_round_s u_round (
        .sign   (round_sign),
        .sig    (sum_mag),
        .exp    (base[12:0]),      // S 的 base ∈ [-175, ~1000]，13 bit 足够
        .rm     (rm),
        .result (round_result),
        .fflags (round_flags)
    );

    // ---- 特殊值（其余判据） ----
    wire any_snan   = a_snan | b_snan | c_snan;

    // 有效零：积为零（含符号）与加数为零（含符号）的相加
    wire p_sign_w = p_sign;                 // 积的符号（p_zero 时即其零符号）
    wire eff_zero = p_finite_zero & c_zero;
    // IEEE：同号零 ⇒ 该符号；异号零 ⇒ RDN 给 −0，否则 +0（RNE/RMM/RUP）
    wire eff_zero_sign = (p_sign_w == c_sign) ? p_sign_w : (rm == 3'b010);

    // "积 Inf 与加数 Inf 异号"（真 Inf−Inf）：必须排除 NaN 操作数——p_inf 只看
    // a_inf|b_inf（不判 frac），NaN×Inf 会误命中，见文件头"缺陷修复记录②"。
    wire inf_opp = p_inf & c_inf & (p_sign != c_sign) & ~any_nan;
    // Inf × 0：RISC-V 要求即使加数为 qNaN 也置 NV（f-st-ext.adoc:310-312）。
    // ★ 该项**不**受 any_nan 屏蔽：0×∞ + qNaN 加数仍必须报 NV（norm:fma_nv_flag）。
    wire inf_special = p_inf_zero | inf_opp;
    // 结果必须为 canonical NaN 的情形：任一 NaN 输入、Inf×0、Inf−Inf（异号）
    wire give_nan = any_nan | p_inf_zero | inf_opp;

    // Inf 结果：积为 Inf（且非 Inf×0、非同号 Inf 相减、无 NaN）
    wire give_pinf = p_inf & ~p_inf_zero & ~(c_inf & (c_sign != p_sign)) & ~any_nan;
    wire give_cinf = c_inf & ~p_inf                              & ~any_nan;

    localparam [31:0] CANON_S = 32'h7FC0_0000;

    assign result = give_nan     ? CANON_S :
                    give_pinf    ? {p_sign, 8'hFF, 23'b0} :
                    give_cinf    ? {c_sign, 8'hFF, 23'b0} :
                    eff_zero     ? {eff_zero_sign, 31'b0} :
                    p_finite_zero ? {c_sign, c[30:0]} :  // 积为零：结果 = 有效加数（含 neg_add）
                                    round_result;

    // NV = sNaN 输入 | Inf×0 | Inf−Inf（异号）
    wire is_special = give_nan | give_pinf | give_cinf | eff_zero | p_finite_zero;
    wire nv = any_snan | inf_special;
    assign fflags = { nv, 1'b0,
                      is_special ? 1'b0 : round_flags[2],
                      is_special ? 1'b0 : round_flags[1],
                      is_special ? 1'b0 : round_flags[0] };
endmodule
//==============================================================================
// fpu_fma_d —— 双精度融合乘加（fmadd.d / fmsub.d / fnmsub.d / fnmadd.d）
//==============================================================================
// 语义（riscv-isa-manual/src/unpriv/f-st-ext.adoc:267-280）：
//   fmadd.d  = rs1×rs2 + rs3
//   fmsub.d  = rs1×rs2 − rs3
//   fnmsub.d = −(rs1×rs2) + rs3        （注意：RISC-V 的 fnmsub 取反的是**积**）
//   fnmadd.d = −(rs1×rs2) − rs3
//   对应本例化参数：neg_prod（取反积）、neg_add（取反加数）
//     fmadd : neg_prod=0 neg_add=0
//     fmsub : neg_prod=0 neg_add=1
//     fnmsub: neg_prod=1 neg_add=0
//     fnmadd: neg_prod=1 neg_add=1
//
// ★ 必须**单次舍入**（08 §5.3 要求 ③）：
//   本实现先算出**精确**乘积（53×53=106 bit，无任何舍入），再把加数按
//   公共基准精确对齐后做一次有符号加，最后只调用一次舍入原语。
//   ⇒ 结构上不可能出现"先舍入积、再舍入和"的两次舍入。
//
// 规范细节（f-st-ext.adoc:310-312 norm:fma_nv_flag）：
//   当被乘数为 Inf 与 0 时**必须**置 NV，**即使加数是 quiet NaN**。
//   （IEEE-754-2008 允许但不要求对 Inf×0+qNaN 报 NV；RISC-V 要求报。）
//==============================================================================
module fpu_fma_d (
    input  wire [63:0] a,          // rs1（低 32 bit 有效）
    input  wire [63:0] b,          // rs2
    input  wire [63:0] c,          // rs3
    input  wire        neg_prod,   // 取反积
    input  wire        neg_add,    // 取反加数
    input  wire [2:0]  rm,
    output wire [63:0] result,
    output wire [4:0]  fflags
);
    // ---- 字段 ----
    wire        a_sign = a[63];
    wire        b_sign = b[63];
    wire        c_sign = c[63] ^ neg_add;
    wire [10:0] a_exp  = a[62:52];
    wire [10:0] b_exp  = b[62:52];
    wire [10:0] c_exp  = c[62:52];
    wire [51:0] a_frac = a[51:0];
    wire [51:0] b_frac = b[51:0];
    wire [51:0] c_frac = c[51:0];

    wire a_nan  = (a_exp == 11'h7FF) && (a_frac != 0);
    wire b_nan  = (b_exp == 11'h7FF) && (b_frac != 0);
    wire c_nan  = (c_exp == 11'h7FF) && (c_frac != 0);
    wire a_inf  = (a_exp == 11'h7FF) && (a_frac == 0);
    wire b_inf  = (b_exp == 11'h7FF) && (b_frac == 0);
    wire c_inf  = (c_exp == 11'h7FF) && (c_frac == 0);
    wire a_zero = (a_exp == 0) && (a_frac == 0);
    wire b_zero = (b_exp == 0) && (b_frac == 0);
    wire c_zero = (c_exp == 0) && (c_frac == 0);
    wire a_snan = a_nan && ~a[51];
    wire b_snan = b_nan && ~b[51];
    wire c_snan = c_nan && ~c[51];

    // 有效数
    wire [52:0] a_sig = (a_exp == 0) ? {1'b0, a_frac} : {1'b1, a_frac};
    wire [52:0] b_sig = (b_exp == 0) ? {1'b0, b_frac} : {1'b1, b_frac};
    wire [52:0] c_sig = (c_exp == 0) ? {1'b0, c_frac} : {1'b1, c_frac};

    // 无偏指数
    wire signed [13:0] a_eunb = (a_exp == 0) ? -14'sd1022 : ($signed({3'b0, a_exp}) - 14'sd1023);
    wire signed [13:0] b_eunb = (b_exp == 0) ? -14'sd1022 : ($signed({3'b0, b_exp}) - 14'sd1023);
    wire signed [13:0] c_eunb = (c_exp == 0) ? -14'sd1022 : ($signed({3'b0, c_exp}) - 14'sd1023);

    // ---- 精确乘积 ----
    wire        p_sign = a_sign ^ b_sign ^ neg_prod;
    wire [105:0] prod  = a_sig * b_sig;                   // 精确，无舍入
    // value(prod) = a_sig × b_sig × 2^(a_eunb-23) × 2^(b_eunb-23)
    //             = prod × 2^(a_eunb + b_eunb - 46)
    wire signed [14:0] p_exp = a_eunb + b_eunb - 14'sd104;
    // value(c) = c_sig × 2^(c_eunb - 23)
    wire signed [14:0] k_exp = c_eunb - 14'sd52;

    // ---- 公共基准：min(p_exp, k_exp)，两侧精确左移对齐 ----
    wire signed [14:0] base = (p_exp < k_exp) ? p_exp : k_exp;
    wire [14:0] sh_p = p_exp - base;      // >= 0
    wire [14:0] sh_k = k_exp - base;      // >= 0
    // 8192 bit 域：106 bit 积 + 最大指数跨度 4092 ⇒ 充裕
    wire [8191:0] p_al = {8086'b0, prod} << sh_p[12:0];
    wire [8191:0] k_al = {8139'b0, c_sig} << sh_k[12:0];

    // 有符号加（补码）
    wire [8192:0] p_tc = p_sign ? ({1'b1, ~p_al} + 8193'd1) : {1'b0, p_al};
    wire [8192:0] k_tc = c_sign ? ({1'b1, ~k_al} + 8193'd1) : {1'b0, k_al};
    wire [8192:0] sum_tc = p_tc + k_tc;
    wire          sum_sign = sum_tc[8192];
    wire [8191:0] sum_mag  = sum_sign ? (~sum_tc[8191:0] + 8192'd1) : sum_tc[8191:0];

    // ---- 特殊值判据（必须先于舍入原语声明：精确抵消判据要用到它们） ----
    wire p_inf_zero = (a_inf & b_zero) | (a_zero & b_inf);   // Inf×0 ⇒ 必报 NV
    wire p_inf      = a_inf | b_inf;
    wire any_nan    = a_nan | b_nan | c_nan;

    // 积是否**恰好**为零（任一侧为零且另一侧有限）：此时结果等于把加数
    // 直接相加，零的符号必须按 IEEE 加法规则决定（不能用回合路径，它会
    // 丢掉 −0 的符号）。
    wire p_zero  = (a_zero & ~b_inf) | (b_zero & ~a_inf);
    wire p_finite_zero = p_zero & ~p_inf_zero;

    // ---- 精确抵消零的符号（IEEE-754-2008 §6.3；缺陷修复见文件头） ----
    // 同 fpu_fma_s：加数对阶后与积精确异号等值 ⇒ 精确零，RDN 给 −0、其余 +0。
    wire exact_cancel = (sum_mag == 8192'd0) & ~p_finite_zero & (p_sign != c_sign);
    wire round_sign   = sum_sign | (exact_cancel & (rm == 3'b010));

    // ---- 一次舍入 ----
    wire [63:0] round_result;
    wire [4:0]  round_flags;
    fpu_round_d u_round (
        .sign   (round_sign),
        .sig    (sum_mag),
        .exp    (base[13:0]),      // D 的 base ∈ [-2148, 971]，14 bit 足够
        .rm     (rm),
        .result (round_result),
        .fflags (round_flags)
    );

    // ---- 特殊值（其余判据） ----
    wire any_snan   = a_snan | b_snan | c_snan;

    // 有效零：积为零（含符号）与加数为零（含符号）的相加
    wire p_sign_w = p_sign;                 // 积的符号（p_zero 时即其零符号）
    wire eff_zero = p_finite_zero & c_zero;
    // IEEE：同号零 ⇒ 该符号；异号零 ⇒ RDN 给 −0，否则 +0（RNE/RMM/RUP）
    wire eff_zero_sign = (p_sign_w == c_sign) ? p_sign_w : (rm == 3'b010);

    // "积 Inf 与加数 Inf 异号"（真 Inf−Inf）：必须排除 NaN 操作数（同 fpu_fma_s，
    // p_inf 不判 frac ⇒ NaN×Inf 误命中），见文件头"缺陷修复记录②"。
    wire inf_opp = p_inf & c_inf & (p_sign != c_sign) & ~any_nan;
    // Inf × 0：RISC-V 要求即使加数为 qNaN 也置 NV（f-st-ext.adoc:310-312）。
    // ★ 该项**不**受 any_nan 屏蔽：0×∞ + qNaN 加数仍必须报 NV（norm:fma_nv_flag）。
    wire inf_special = p_inf_zero | inf_opp;
    // 结果必须为 canonical NaN 的情形：任一 NaN 输入、Inf×0、Inf−Inf（异号）
    wire give_nan = any_nan | p_inf_zero | inf_opp;

    // Inf 结果：积为 Inf（且非 Inf×0、非同号 Inf 相减、无 NaN）
    wire give_pinf = p_inf & ~p_inf_zero & ~(c_inf & (c_sign != p_sign)) & ~any_nan;
    wire give_cinf = c_inf & ~p_inf                              & ~any_nan;

    localparam [63:0] CANON_D = 64'h7FF8_0000_0000_0000;

    assign result = give_nan     ? CANON_D :
                    give_pinf    ? {p_sign, 11'h7FF, 52'b0} :
                    give_cinf    ? {c_sign, 11'h7FF, 52'b0} :
                    eff_zero     ? {eff_zero_sign, 63'b0} :
                    p_finite_zero ? {c_sign, c[62:0]} :  // 积为零：结果 = 有效加数（含 neg_add）
                                    round_result;

    // NV = sNaN 输入 | Inf×0 | Inf−Inf（异号）
    wire is_special = give_nan | give_pinf | give_cinf | eff_zero | p_finite_zero;
    wire nv = any_snan | inf_special;
    assign fflags = { nv, 1'b0,
                      is_special ? 1'b0 : round_flags[2],
                      is_special ? 1'b0 : round_flags[1],
                      is_special ? 1'b0 : round_flags[0] };
endmodule
