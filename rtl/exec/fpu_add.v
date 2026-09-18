//==============================================================================
// fpu_add.v —— 浮点加减（F/D）+ 融合乘加（FMA）+ 共享"窄域 + sticky"舍入原语
//==============================================================================
// 项目  : rv32gc-cpu（2A 单发射顺序 5 级基线核）
// 规格  : docs/design/08-baseline-5stage.md §5.3（fpu_add.v / fpu_mul.v 行）
//         IEEE-754-2008 binary32/binary64；RISC-V F/D
//         （riscv-isa-manual/src/unpriv/f-st-ext.adoc:215-222；d-st-ext.adoc:117-129）
//
// 语义要点（逐条对照规范，**与重写前逐位一致**）：
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
//   两个**非零**操作数精确抵消时和幅值为 0，而舍入原语的 sign 接的是 sum_sign
//   （精确抵消时恒为 0）⇒ 无论舍入模式都返回 +0：违反 §6.3 对 RDN 的 −0 要求。
//   修复：在四处舍入调用前新增 exact_cancel 判据，把它并入舍入符号
//      round_sign = win_sign | (exact_cancel & (rm == RDN))
//   精确抵消时幅值为 0 ⇒ 舍入原语走 zero_out 分支，只取符号、不产生 OF/UF/NX，
//   故该修复不改变 fflags。**本次重写保留该结构**（exact_cancel 判据从"全宽
//   sum_mag == 0"改为"窄窗口 win == 0"，两者等价，见下方 P6）。
//
// ★ 缺陷修复记录（2026-09-14，#2）——FMA-NV 误报（NaN 乘数 × Inf + 异号 Inf 加数）
//   IEEE-754-2008 / RISC-V 口径：qNaN 输入**不**报 NV，唯一允许"qNaN 也报 NV"的
//   场景是 0×∞（f-st-ext.adoc:310-312 norm:fma_nv_flag，即 p_inf_zero 项）。
//   修复：inf_opp = p_inf & c_inf & (p_sign != c_sign) & ~any_nan，
//   由 inf_special / give_nan 共用一份，杜绝同一表达式两处不同步。**本次保留**。
//
// ★ 缺陷修复记录（2026-09-17）——UF 的 tininess 判据用"无界指数"口径
//   tininess 是"**无界指数**下舍入后的结果是否仍 < 2^emin"（IEEE 754-2008 §7.5，
//   f-st-ext.adoc:186-188）。判据落在 fpu_round_n 内，**本次逐条保留**（含
//   clamped_ulp / last_ulp_bel / up_to_normal 三项）。
//
//==============================================================================
// ★★ 本次重写（路线 A：窄域 + sticky）—— 结构、位宽与正确性论证 ★★
//------------------------------------------------------------------------------
// 【为什么改】旧实现"以位宽换正确性"：把对阶域做到 4096/8192 bit（D 侧指数差
//   最大 2046 + 有效数 53），舍入原语也在 1024/8192 bit 上做移位/sticky/加法。
//   实测 FPU 单独综合 546 223 LUT（器件 405.8 %），其中 fpu_fma_d 一个模块就
//   419 191 LUT ⇒ 整核放不下（fpga/M4-report.md §6/§8.1）。
//
// 【改成什么】经典"窄窗口 + sticky 压缩"：
//   · 对阶不再两侧全宽左移，而是**以大指数侧（实际 MSB）为锚**：大侧原样放入
//     窗口（永不截断），小侧右移进入窗口，移出窗口的低位**用一个或树压成 1 bit
//     sticky**；
//   · 舍入原语只吃窄窗口 sig + sticky_in，内部移位/取位/加一/求 msb 全在
//     ≤ 110 bit 的小域上做。
//   ★ 这是"压缩"而**不是**"近似"：下面 P1~P6 逐条证明窗口外的信息恰好只用得到
//     "是否存在非零低位"这一位（即 sticky），故所有可观测结果（结果位 + 5 个
//     fflags + 单次舍入语义）与旧全宽实现**逐位相同**。
//
// 【模型定义】对阶加法器把精确和表示为 **三元组 (win_mag, win_sign, sticky)**：
//     V = (−1)^win_sign × ( win_mag × 2^win_exp + δ ),
//     0 ≤ δ < 2^win_exp，且 δ ≠ 0 ⟺ sticky = 1
//   即窗口给出"整数部分"，sticky 只声明"其下还有非零余项"。
//   舍入原语 fpu_round_n 只需这个三元组即可**精确**完成 IEEE 舍入（见 P4/P5）。
//
// 【位宽选择】对阶窗口（fpu_align_add 的 WW 参数）：
//     WW = max(WA, WB) + 4        （WA/WB = 两个操作数有效数位宽）
//   实例：fpu_add_s 24/24→28；fpu_add_d 53/53→57；
//         fpu_fma_s 48/24→52；fpu_fma_d 106/53→110。
//   窗口内布局（相对位号）：大操作数有效数 MSB 固定在 bit(WW−2)，其 LSB 在
//     bit(WW−2−h)（h = 该有效数的实际 msb 下标）；bit(WW−1) **留给进位**
//     （同号相加时和可能比大侧高一个二进制阶，如 1.0+1.0=2.0），
//     有符号加用 WW+1 位补码、符号位在 bit(WW)；窗口 bit0 的权 = win_exp。
//
// 【P1：只有"小侧"可能被截断，大侧永不丢位】
//   大侧左移量 = (top_a − top_max) + (WW−2−h) = WW−2−h ≥ 0（top 相等时为 0），
//   故大侧有效数**逐位**进入窗口（其 MSB 落在 bit(WW−2)）。小侧左移量
//   ≤ 0，可能为负（右移）⇒ 只有小侧会产生 sticky。
//   ⇒ δ 只有一个来源（"单一 sticky 源"），这保证了下面 P3 的符号规则成立。
//
// 【P2：截断发生时，结果 MSB 必落在窗口高位 ⇒ 舍入位在窗口内且是精确位】
//   截断 ⟺ 小侧 LSB 落到窗口外：s ≜ top_max − top_small ≥ WW−1 − h_small。
//   此时 |V| ≥ |big| − |small| > 2^top_max − 2^(top_max−s+1) ≥ 2^top_max(1 − 2^−3)
//   （因 s ≥ WW−1−h_small ≥ 4 ≥ 3，WW = max(·)+4）⇒ 结果 MSB 位号 ≥ WW−3。
//   于是 rsh = ulp_ex − win_exp ≥ (msb − FB) ≥ WW−3−FB ≥ 2（因 WW = max(·)+4
//   ⇒ WW−FB−3 ≥ 2）⇒ 舍入位 bit(rsh−1) ≥ 1、sticky 掩码位都落在窗口内，
//   两者都是**精确**的窗口位（窗口内所有位精确，只有窗口外被压成 sticky）。
//
// 【P3：sticky 与"借位"的合成规则（本次重写最关键的一处）】
//   设被截断的是小侧、其符号 s_t，大侧符号 s_o，窗口内两数相加得整数 T，
//   真实值 V = s_o·|A| + s_t·(|B| + δ')（δ' ∈ (0, 2^win_exp) 为被压掉的余项）。
//   分两种情形：
//     · s_t == s_o（同号相加）：V = s_o·(T + δ) ⇒ 取 floor 后就是 T ⇒ **不减 1**；
//     · s_t != s_o（异号相减）：V = s_o·(T − δ)。若结果符号 == s_o（正结果）：
//       V ∈ ((T−1), T)·2^win_exp ⇒ 整数部分应为 T−1、余项 1−δ ∈ (0,1)
//       ⇒ **幅值减 1**；若结果符号 == s_t（负结果）：|V| = |T| + δ ⇒ 不减 1。
//   统一写成：**当且仅当 sign(被截断侧) ≠ sign(结果) 时，幅值减 1**。
//   （P1 保证至多一侧被截断；P2 保证减 1 后幅值仍 ≥ 2^(WW−3)−1 > 0，不会下溢。）
//   ★ 若不加该判据（例如"见 sticky 就减 1"或"永不减 1"），同号相加/异号相减
//     两条路径里必有一条错 1 个窗口 ulp（典型表现：1.0 + 极小值 多进 1 个尾数 ulp，
//     或 1.0 − 极小值 少进 1 个尾数 ulp）——这正是本次新增的反证实验（判据 ④）
//     所针对的单点。
//
// 【P4：舍入原语只需窗口位 + sticky】
//   旧实现把 sig 的**全部**位交给舍入器。新实现观察到：舍入器只用到
//     (a) q0 = sig >> rsh 的低 FB+2 位（尾数 + 进位）；
//     (b) 舍入位 bit(rsh−1)；
//     (c) "bit(rsh−2) 以下是否存在 1" 这一位（sticky）。
//   由 P2，截断时 rsh ≥ 2 ⇒ (b) 是窗口内的精确位、(c) = (窗口低位或树 | sticky_in)。
//   未被截断时窗口就是精确值、sticky_in = 0，与旧实现同一表达式。
//   ⇒ 新旧舍入器的 q0/round_bit/sticky 完全一致。
//
// 【P5：q 域可以只留低 FB+2 位】
//   q0 = sig >> rsh 且 rsh ≥ ulp_ex − exp ≥ natural_ulp − exp = msb − FB
//   ⇒ q0 < 2^(FB+1)（因 sig < 2^(msb+1)）；!do_right 时 lsh = exp − ulp_ex
//   同样给出 q0 < 2^(FB+1)（ulp_ex 定义）。故 q0 只需 FB+2 位，加一后仍 ≤ 2^(FB+1)，
//   q 用 FB+3 位即无溢出；子正规进位判据 sub_carry = |q[FB+1:FB] 与旧实现
//   "q >= 2^FB"（全宽比较）等价。
//
// 【P6：特殊值判据不变】
//   exact_cancel = (win_mag == 0) & ~sticky：未被截断时窗口和 = 精确和 ⇒ 等价于旧
//   sum_mag==0；被截断时 P2 已证 win_mag ≥ 2^(WW−3)−1 > 0 ⇒ 判据不会被 sticky 误触发；
//   唯一"win==0 且 sticky==1"的退化场景（大侧是 ±0、小侧全被压进 sticky）**不是**
//   精确抵消 ⇒ 必须显式排除，否则 RDN 会错误地强置符号（P3 补充）。
//   其余 NaN/Inf/零/p_finite_zero 判据与旧实现逐字相同。
//
// 【面积/吞吐收益】8192→110 bit（D 侧），1024→53 bit（S 侧）；msb 搜索从
//   "8192 bit 分层"降到"≤112 bit 线性"（单次迭代数从 ~200 降到 ~110，且
//   向量宽度从 256 字降到 2 字），仿真吞吐同时受益（判据 ⑤）。
//
// ★ 红线 1/2（IP 优先 + 双分支）
//   检索结论：Vivado 有 `Floating-Point Operator v7.1` IP（Add/Sub、Multiply、
//   FMA、Divide、Square root，binary32/64），但**只有 RNE/RTZ/RUP/RDN 四种舍入**、
//   没有 RISC-V 的 RMM（ties to max magnitude），且 NaN payload/subnormal 口径
//   需自行兜底 ⇒ 与"综合分支 != 已验证仿真分支"红线冲突（M4-report §8 路线 B
//   已用实测探针否决）。故本文件走**可综合行为模型**（纯整数运算），
//   不使用任何 FPGA 原语（红线 1）；`RV32GC_USE_VIVADO_IP` 只影响 fpu_div_sqrt.v
//   的迭代核，本文件的两分支端口/语义完全一致。
//==============================================================================
`include "rv32_defs.vh"
`include "core_params.vh"

//==============================================================================
// fpu_round_n —— 通用窄域 + sticky 舍入原语（参数化；S/D 共用一份实现）
//------------------------------------------------------------------------------
//   value = sig × 2^exp + δ（0 ≤ δ < 2^exp，δ≠0 ⟺ sticky_in）
//   输出 result（不含 NaN-boxing）+ fflags {NV,DZ,OF,UF,NX}（本原语只产 OF/UF/NX）
//   参数：FB 尾数位宽 / WW 窄域 sig 位宽 / RW 结果位宽 / EB 指数域位宽 /
//         MIN_SUB 最小亚正规 ulp 指数 / E_MAXF 指数域满值 / BIAS 偏置
//   规格与位级验证方法：.work_fpu/HW_ROUND_VERIFIED.md
//==============================================================================
module fpu_round_n #(
    parameter integer FB      = 23,       // 尾数位宽（S:23 / D:52）
    parameter integer WW      = 64,       // 窄域 sig 位宽（≥ 调用者需要保留的有效位）
    parameter integer RW      = 32,       // 结果位宽（S:32 / D:64）
    parameter integer EB      = 8,        // 指数域位宽（S:8 / D:11）
    parameter integer MIN_SUB = -149,     // 最小亚正规 ulp 的指数（S:−149 / D:−1074）
    parameter integer E_MAXF  = 255,      // 指数域满值（S:255 / D:2047）
    parameter integer BIAS    = 127
) (
    input  wire               sign,
    input  wire [WW-1:0]      sig,
    input  wire               sticky_in,
    input  wire signed [15:0] exp,
    input  wire [2:0]         rm,
    output wire [RW-1:0]      result,
    output wire [4:0]         fflags
);
    localparam integer QW = FB + 2;       // q0 位宽（P5：低 FB+2 位足够）
    // 移位域：**严格宽于** WW 与 QW（各留 1 位余量，避免复制数为 0）
    //   ★ 必须宽于 WW：do_right=0 时要做左移（把值规格化到 q0 的 bit FB），
    //     若在 WW 位域里左移会静默溢出 ⇒ 全 0/X（实测踩到：fcvt.d.w(1) 给 X）。
    //   ★ 展宽是零扩展，且左移只取低 QW 位 ⇒ 被移入 q0 的位都来自 sig 的低位，
    //     与原全宽实现一致（P4/P5）。
    localparam integer WSH = ((WW > QW) ? WW : QW) + 1;

    localparam signed [15:0] FB_S      = FB;
    localparam signed [15:0] BIAS_S    = BIAS;
    localparam signed [15:0] MIN_SUB_S = MIN_SUB;
    localparam signed [15:0] EMIN_S    = 1 - BIAS;      // 最小正规数的无偏指数
    localparam signed [15:0] EMAXF_S   = E_MAXF;
    localparam [EB-1:0]      EMAXF_V   = E_MAXF;        // 指数域满值（低 EB 位）
    localparam [EB-1:0]      EMAXM1_V  = E_MAXF - 1;    // 最大有限数的指数域

    // 窗口内最高置位下标（v==0 ⇒ 0）——WW ≤ 128 ⇒ 7 bit
    function [6:0] msb_win;
        input [WW-1:0] v;
        integer i;
        begin
            msb_win = 7'd0;
            for (i = 0; i < WW; i = i + 1) if (v[i]) msb_win = i[6:0];
        end
    endfunction

    // q 域最高置位下标（q 宽 QW+1 ⇒ ≤ 55 bit）
    function [6:0] msb_q;
        input [QW:0] v;
        integer i;
        begin
            msb_q = 7'd0;
            for (i = 0; i <= QW; i = i + 1) if (v[i]) msb_q = i[6:0];
        end
    endfunction

    // ---- 零判据 / 最高位 / 无偏指数 ----
    // ★ sig_zero 必须带 ~sticky_in：sig==0 但 sticky_in=1 表示"值非零、且幅值
    //   小于窗口 LSB"（本设计的所有调用者都在特殊值通路上才可能出现，
    //   此时结果被上层屏蔽；写成 &~sticky_in 是为了不把"非零值"当零输出）。
    wire               sig_zero = ~(|sig) & ~sticky_in;
    wire [6:0]         msb      = msb_win(sig);
    wire signed [15:0] exp_s    = exp;                    // 端口已是有符号 16 bit
    wire signed [15:0] msb_s    = {9'b0, msb};            // 零扩展后按有符号参与运算
    wire signed [15:0] e_unb      = exp_s + msb_s;
    wire signed [15:0] natural_ulp = e_unb - FB_S;
    // ★ 钳位判据在 ulp 上（不是 e_unb 上）—— HW_ROUND_VERIFIED.md 坑 1
    wire signed [15:0] ulp_ex = (natural_ulp >= MIN_SUB_S) ? natural_ulp : MIN_SUB_S;

    // value / 2^ulp = sig × 2^(exp − ulp)
    wire signed [15:0] diff      = exp_s - ulp_ex;
    wire               do_right  = (diff < 16'sd0);
    wire [15:0]        rsh       = do_right ? (-diff) : 16'd0;
    wire [15:0]        lsh       = do_right ? 16'd0 : diff;

    // ---- 窗口取位（P4/P5：只需要 q0 低 QW 位 + 舍入位 + sticky）----
    wire [WSH-1:0] sig_s = {{(WSH-WW){1'b0}}, sig};        // 零扩展到移位域
    wire [WSH-1:0] qsh_f = do_right ? (sig_s >> rsh) : (sig_s << lsh);
    wire [QW-1:0]  q0    = qsh_f[QW-1:0];

    wire [15:0]   rsh_m1 = rsh - 16'd1;                    // do_right ⇒ rsh ≥ 1
    wire          round_bit = do_right ? ((sig >> rsh_m1) & 1'b1) : 1'b0;
    // sticky = 窗口内 bit(rsh−2) 以下有 1 | 窗口外压缩进来的 sticky_in
    //   （rsh−1 ≥ WW 时掩码自然退化为全 1，无越界索引）
    wire [WW-1:0] stk_msk = ({{(WW-1){1'b0}}, 1'b1} << rsh_m1)
                            - {{(WW-1){1'b0}}, 1'b1};
    wire          sticky  = (do_right & (|(sig & stk_msk))) | sticky_in;
    wire          inexact = round_bit | sticky;

    wire          lsb = q0[0];

    // ---- 增量（rm: 000 RNE / 001 RTZ / 010 RDN / 011 RUP / 100 RMM） ----
    wire inc = (rm == 3'b000) ? (round_bit & (sticky | lsb)) :
               (rm == 3'b100) ?  round_bit :
               (rm == 3'b001) ?  1'b0 :
               (rm == 3'b011) ? ~sign :
               (rm == 3'b010) ?  sign :
                                 (round_bit & (sticky | lsb)); // 保留 rm ⇒ RNE

    wire [QW:0] q = {1'b0, q0} + {{QW{1'b0}}, (inexact & inc)};

    // ---- 结果打包 ----
    wire        q_zero = (q == {(QW+1){1'b0}});
    wire [6:0]  q_msb  = msb_q(q);
    wire signed [15:0] e_res = ulp_ex + {9'b0, q_msb};
    wire signed [15:0] e_f   = e_res + BIAS_S;

    wire overflow  = ~q_zero & (e_f >= EMAXF_S);
    wire subnormal = ~q_zero & (e_res < EMIN_S);

    // 亚正规：exp_field = 0；fraction = q（此时 ulp_ex == MIN_SUB，q 即 fraction）；
    // q 进位到 2^FB ⇒ 恰为最小正规数
    wire [RW-1:0] sub_out  = |q[FB+1:FB] ? {sign, {{(EB-1){1'b0}}, 1'b1}, {FB{1'b0}}}
                                         : {sign, {EB{1'b0}}, q[FB-1:0]};
    wire [RW-1:0] norm_out = {sign, e_f[EB-1:0], q[FB-1:0]};

    // 溢出饱和：RTZ 恒最大有限数；RDN 仅正数；RUP 仅负数
    wire of_to_max = (rm == 3'b001) || ((rm == 3'b010) & ~sign) || ((rm == 3'b011) &  sign);
    wire [RW-1:0] zero_out = {sign, {RW-1{1'b0}}};
    wire [RW-1:0] of_out   = of_to_max ? {sign, EMAXM1_V, {FB{1'b1}}}
                                       : {sign, EMAXF_V, {FB{1'b0}}};

    assign result = (sig_zero | q_zero) ? zero_out :
                    overflow            ? of_out   :
                    subnormal           ? sub_out  :
                                          norm_out;

    // ---- fflags（本原语产 OF/UF/NX；NV/DZ 由上层按特殊值给出） ----
    // ★ UF（tininess after rounding，无界指数口径）—— 2026-09-17 修复，逐条保留：
    //   · 未钳位（natural_ulp ≥ MIN_SUB，精确值 ≥ 2^emin）⇒ 结果 ≥ 2^emin ⇒ 不 tiny；
    //   · 钳位且 natural_ulp ≤ MIN_SUB−2 ⇒ 自然网格至少细 2 位 ⇒ 必 tiny；
    //   · 钳位且 natural_ulp == MIN_SUB−1 ⇒ 只有"自然网格舍入恰好进位到 2^emin"
    //     才 non-tiny：需 q0 == 2^FB−1 且 round_bit&sticky 且该舍入模式会进位。
    wire of_fl = overflow;
    wire clamped_ulp  = (natural_ulp < MIN_SUB_S);
    wire last_ulp_bel = (natural_ulp == (MIN_SUB_S - 16'sd1)) &
                        (q0 == {{2{1'b0}}, {FB{1'b1}}});        // q0 == 2^FB − 1
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
// fpu_align_add —— 对阶 + 有符号加 + sticky 压缩（窄窗口，P1~P3 的落地）
//------------------------------------------------------------------------------
//   A = (−1)^sa_sign × sig_a × 2^lsb_a        （sig_a 为无符号有效数，lsb_a 为其 LSB 权）
//   B = (−1)^sb_sign × sig_b × 2^lsb_b
//   输出 (win, win_sign, win_sticky, win_exp) 满足
//     A + B = (−1)^win_sign × (win × 2^win_exp + δ)，0 ≤ δ < 2^win_exp，
//             δ ≠ 0 ⟺ win_sticky
//   参数约束：WW ≥ max(WA,WB)+4（P2 的余量），且 max(WA,WB) ≤ 127（移位量位宽）
//   窗口布局：bit(WW−1) = 进位位（同号相加可到），bit(WW−2) = 大侧有效数 MSB，
//             bit0 = win_exp 对应的权；有符号加用 WW+1 位补码（符号在 bit(WW)）
//   注：操作数有效数为 0（±0 操作数）时其 top 取"LSB 权 + 0"这一退化值，
//       只影响"谁当大侧"的选择；两侧都为 0 时窗口和恒为 0，结果仍正确。
//==============================================================================
module fpu_align_add #(
    parameter integer WA = 53,
    parameter integer WB = 53,
    parameter integer WW = 57
) (
    input  wire [WA-1:0]      sig_a,
    input  wire signed [15:0] lsb_a,
    input  wire               sa_sign,
    input  wire [WB-1:0]      sig_b,
    input  wire signed [15:0] lsb_b,
    input  wire               sb_sign,
    output wire [WW-1:0]      win,
    output wire               win_sign,
    output wire               win_sticky,
    output wire signed [15:0] win_exp
);
    localparam signed [15:0] WWH = WW - 2;        // 窗口 MSB 位号（bit(WW−1) 留给进位）
    localparam signed [15:0] WAS = WA;            // 右移饱和阈值
    localparam signed [15:0] WBS = WB;
    localparam [WW-1:0]      ONE_W = {{(WW-1){1'b0}}, 1'b1};

    function [6:0] msb_a;
        input [WA-1:0] v;
        integer i;
        begin
            msb_a = 7'd0;
            for (i = 0; i < WA; i = i + 1) if (v[i]) msb_a = i[6:0];
        end
    endfunction
    function [6:0] msb_b;
        input [WB-1:0] v;
        integer i;
        begin
            msb_b = 7'd0;
            for (i = 0; i < WB; i = i + 1) if (v[i]) msb_b = i[6:0];
        end
    endfunction

    // ---- 各自有效数 MSB 的权（**实际值**，不是名义位宽）----
    //   用实际 msb 才能保证"大侧 MSB 恰好落在窗口顶端"⇒ P2 的界成立；
    //   若用名义 top（隐藏位假定为 1），亚正规/乘积侧会跌出窗口。
    wire [6:0]         h_a  = msb_a(sig_a);
    wire [6:0]         h_b  = msb_b(sig_b);
    wire signed [15:0] h_as = {9'b0, h_a};
    wire signed [15:0] h_bs = {9'b0, h_b};
    wire signed [15:0] top_a = lsb_a + h_as;
    wire signed [15:0] top_b = lsb_b + h_bs;
    wire signed [15:0] top_m = (top_a >= top_b) ? top_a : top_b;

    assign win_exp = top_m - WWH;

    // ---- 期望左移量（大侧 ≥ 0，小侧 ≤ 0；负值 ⇒ 右移进窗口）----
    wire signed [15:0] sh_a = top_a - top_m + WWH - h_as;
    wire signed [15:0] sh_b = top_b - top_m + WWH - h_bs;

    // A 侧
    wire        a_rs   = (sh_a < 16'sd0);
    wire [15:0] a_rsn  = a_rs ? (-sh_a) : 16'd0;
    wire        a_gone = a_rs & (a_rsn >= WAS);            // 整段移出窗口
    wire [6:0]  a_rsh  = a_gone ? 7'd0 : a_rsn[6:0];       // a_gone ⇒ 窗口恒 0
    wire [6:0]  a_lsh  = (sh_a > 16'sd0) ? sh_a[6:0] : 7'd0;
    // B 侧
    wire        b_rs   = (sh_b < 16'sd0);
    wire [15:0] b_rsn  = b_rs ? (-sh_b) : 16'd0;
    wire        b_gone = b_rs & (b_rsn >= WBS);
    wire [6:0]  b_rsh  = b_gone ? 7'd0 : b_rsn[6:0];
    wire [6:0]  b_lsh  = (sh_b > 16'sd0) ? sh_b[6:0] : 7'd0;

    wire [WW-1:0] a_ext = {{(WW-WA){1'b0}}, sig_a};
    wire [WW-1:0] b_ext = {{(WW-WB){1'b0}}, sig_b};

    wire [WW-1:0] a_win = a_gone ? {WW{1'b0}}
                                 : (a_rs ? (a_ext >> a_rsh) : (a_ext << a_lsh));
    wire [WW-1:0] b_win = b_gone ? {WW{1'b0}}
                                 : (b_rs ? (b_ext >> b_rsh) : (b_ext << b_lsh));

    // 被移出窗口的位 ⇒ 或树压成 1 bit sticky
    //   ★ 必须限定"真的有位被移出"：有效数为 0（±0 操作数）时 a_gone 也会成立，
    //     但一个 0 有效数没有任何位可丢 ⇒ sticky 必须为 0
    //     （否则 x ± 0 会被误判"不精确"，实测踩到：add 家族 556/6000 例 flags/1ulp 错）。
    wire [WW-1:0] a_msk = (ONE_W << a_rsh) - ONE_W;        // bit(a_rsh−1 .. 0)
    wire [WW-1:0] b_msk = (ONE_W << b_rsh) - ONE_W;
    wire [WW-1:0] a_lost = a_gone ? a_ext : (a_ext & a_msk);
    wire [WW-1:0] b_lost = b_gone ? b_ext : (b_ext & b_msk);
    wire          a_stk = a_rs & (|a_lost);
    wire          b_stk = b_rs & (|b_lost);

    // ---- 有符号加（补码，WW+1 位）----
    wire [WW:0] a_tc = sa_sign ? ({1'b1, ~a_win} + {{WW{1'b0}}, 1'b1}) : {1'b0, a_win};
    wire [WW:0] b_tc = sb_sign ? ({1'b1, ~b_win} + {{WW{1'b0}}, 1'b1}) : {1'b0, b_win};
    wire [WW:0] sum_tc = a_tc + b_tc;

    wire [WW-1:0] sum_mag = sum_tc[WW] ? (~sum_tc[WW-1:0] + ONE_W) : sum_tc[WW-1:0];

    // ---- P3：sticky 与借位的合成 ----
    //   仅当"被截断侧符号 ≠ 结果符号"时幅值减 1（同号相加 / 负结果不减 1）。
    //   P1 ⇒ 至多一侧被截断；P2 ⇒ 减 1 后幅值仍 > 0（附加 |sum_mag 兜底，
    //   使"两侧同为 0 且 sticky"这一退化特殊值场景不会回绕）。
    wire trunc_p = a_stk & ~b_stk;                 // 被截断的是 A 侧（P1 ⇒ 唯一）
    wire trunc_sign = trunc_p ? sa_sign : sb_sign;
    wire both_stk   = a_stk & b_stk;               // 不可达（P1）；保守按"不减 1"处理
    wire adjust = (a_stk | b_stk) & ~both_stk & (trunc_sign != sum_tc[WW]) & (|sum_mag);

    // ---- 幅值全被压进 sticky 时的符号恢复（P3 补充，**必须**）----
    //   sum_mag == 0 且 sticky == 1 ⇒ 大侧有效数为 0（±0 操作数，其 top 是退化值
    //   而"赢"了 top 比较），窗口内只剩被截断的小侧 ⇒ 真实值非零、符号 = 被截断侧。
    //   ★ 不补这一条会丢符号（实测踩到：fmadd.s 里 c=±0、积为极小数时
    //     got=+0 / exp=−0；RUP 时还会给 +2^−149 而应为 −0）。
    //   此时 win = 0 且 sticky = 1，舍入原语按"幅值 < 窗口 LSB 的非零值"处理
    //   （ulp_ex 被钳到 MIN_SUB ⇒ 结果 = ±0 或 ±2^MIN_SUB，flags = UF|NX，
    //    与黄金模型/旧实现一致）。
    wire raw_zero = ~(|sum_mag);
    wire stk_any  = a_stk | b_stk;

    assign win_sign   = (raw_zero & stk_any) ? trunc_sign : sum_tc[WW];
    assign win_sticky = stk_any;
    assign win = raw_zero ? {WW{1'b0}} : (adjust ? (sum_mag - ONE_W) : sum_mag);
endmodule

//==============================================================================
// fpu_add_s —— 单精度加法/减法（fadd.s / fsub.s）
//   旧：512 bit 全宽对阶域 + 1024 bit 舍入域；新：28 bit 窗口 + 1 bit sticky
//   语义：rs1 ± rs2，单次舍入；NaN/Inf/零 特殊值按规范
//         （f-st-ext.adoc:134-139 canonical_NaN、:215-222 fadd/fsub 定义）
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

    // 有效数 LSB 的权（亚正规取 −126 − 23 = −149，与 value = sig × 2^lsb 口径一致）
    wire signed [15:0] a_lsb = (a_exp == 0) ? -16'sd149
                                            : ($signed({8'b0, a_exp}) - 16'sd150);
    wire signed [15:0] b_lsb = (b_exp == 0) ? -16'sd149
                                            : ($signed({8'b0, b_exp}) - 16'sd150);

    // ---- 窄窗口对阶 + 有符号加（WW = 24 + 4 = 28）----
    wire [27:0]       win;
    wire              win_sign, win_sticky;
    wire signed [15:0] win_exp;
    fpu_align_add #(.WA(24), .WB(24), .WW(28)) u_align (
        .sig_a (a_sig), .lsb_a (a_lsb), .sa_sign (a_sign),
        .sig_b (b_sig), .lsb_b (b_lsb), .sb_sign (b_sign),
        .win (win), .win_sign (win_sign), .win_sticky (win_sticky), .win_exp (win_exp)
    );

    // ---- 特殊值判据（必须先于舍入原语声明：精确抵消零的符号要用到 both_zero） ----
    wire any_nan   = a_nan | b_nan;
    wire nan_nv    = a_snan | b_snan;
    wire inf_opp   = a_inf & b_inf & (a_sign != b_sign);   // 异号无穷相减 ⇒ NV
    wire both_zero = a_zero & b_zero;

    wire zero_sign = (a_sign == b_sign) ? a_sign : (rm == 3'b010);

    // ---- 精确抵消零的符号（IEEE-754-2008 §6.3；P6 保证 win==0 ⟺ 精确和为零）----
    wire exact_cancel = (win == 28'd0) & ~win_sticky & ~both_zero & (a_sign != b_sign);
    wire round_sign   = win_sign | (exact_cancel & (rm == 3'b010));

    // ---- 交给共享窄域舍入原语 ----
    wire [31:0] round_result;
    wire [4:0]  round_flags;
    fpu_round_n #(.FB(23), .WW(28), .RW(32), .EB(8),
                  .MIN_SUB(-149), .E_MAXF(255), .BIAS(127)) u_round (
        .sign      (round_sign),
        .sig       (win),
        .sticky_in (win_sticky),
        .exp       (win_exp),
        .rm        (rm),
        .result    (round_result),
        .fflags    (round_flags)
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
//   旧：4096 bit 全宽对阶域 + 8192 bit 舍入域；新：57 bit 窗口 + 1 bit sticky
//   与 fpu_add_s 同构，仅参数不同（有效数 53 bit、指数 11 bit）。
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

    // 有效数 LSB 的权（亚正规取 −1022 − 52 = −1074）
    wire signed [15:0] a_lsb = (a_exp == 0) ? -16'sd1074
                                            : ($signed({5'b0, a_exp}) - 16'sd1075);
    wire signed [15:0] b_lsb = (b_exp == 0) ? -16'sd1074
                                            : ($signed({5'b0, b_exp}) - 16'sd1075);

    // ---- 窄窗口对阶 + 有符号加（WW = 53 + 4 = 57）----
    wire [56:0]        win;
    wire               win_sign, win_sticky;
    wire signed [15:0] win_exp;
    fpu_align_add #(.WA(53), .WB(53), .WW(57)) u_align (
        .sig_a (a_sig), .lsb_a (a_lsb), .sa_sign (a_sign),
        .sig_b (b_sig), .lsb_b (b_lsb), .sb_sign (b_sign),
        .win (win), .win_sign (win_sign), .win_sticky (win_sticky), .win_exp (win_exp)
    );

    wire any_nan   = a_nan | b_nan;
    wire nan_nv    = a_snan | b_snan;
    wire inf_opp   = a_inf & b_inf & (a_sign != b_sign);
    wire both_zero = a_zero & b_zero;
    wire zero_sign = (a_sign == b_sign) ? a_sign : (rm == 3'b010);

    // ---- 精确抵消零的符号（IEEE-754-2008 §6.3；P6）----
    wire exact_cancel = (win == 57'd0) & ~win_sticky & ~both_zero & (a_sign != b_sign);
    wire round_sign   = win_sign | (exact_cancel & (rm == 3'b010));

    wire [63:0] round_result;
    wire [4:0]  round_flags;
    fpu_round_n #(.FB(52), .WW(57), .RW(64), .EB(11),
                  .MIN_SUB(-1074), .E_MAXF(2047), .BIAS(1023)) u_round (
        .sign      (round_sign),
        .sig       (win),
        .sticky_in (win_sticky),
        .exp       (win_exp),
        .rm        (rm),
        .result    (round_result),
        .fflags    (round_flags)
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
//   本实现先算出**精确**乘积（24×24=48 bit，无任何舍入），再把加数按公共窗口
//   对齐后做一次有符号加，最后只调用一次舍入原语。
//   ⇒ 结构上不可能出现"先舍入积、再舍入和"的两次舍入。
//   ★ 旧实现把积与加数放在 1024 bit 全宽域对齐；新实现用 52 bit 窗口
//     （WW = 48 + 4）：**积作为大侧时永不丢位**（WW ≥ 48+4 ⇒ 48 bit 精确积
//     完整落在窗口内），只有加数可能被压成 sticky ⇒ P1/P3 依然成立。
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

    // 无偏指数（亚正规取 −126，配合有效数的 ×2^−23 口径）
    wire signed [15:0] a_eunb = (a_exp == 0) ? -16'sd126 : ($signed({8'b0, a_exp}) - 16'sd127);
    wire signed [15:0] b_eunb = (b_exp == 0) ? -16'sd126 : ($signed({8'b0, b_exp}) - 16'sd127);
    wire signed [15:0] c_eunb = (c_exp == 0) ? -16'sd126 : ($signed({8'b0, c_exp}) - 16'sd127);

    // ---- 精确乘积（无舍入）----
    wire        p_sign = a_sign ^ b_sign ^ neg_prod;
    wire [47:0] prod   = a_sig * b_sig;                   // 精确，无舍入
    // value(prod) = prod × 2^(a_eunb + b_eunb − 46)；value(c) = c_sig × 2^(c_eunb − 23)
    wire signed [15:0] p_exp = a_eunb + b_eunb - 16'sd46;
    wire signed [15:0] k_exp = c_eunb - 16'sd23;

    // ---- 窄窗口对阶 + 有符号加（WW = 48 + 4 = 52）----
    wire [51:0]        win;
    wire               win_sign, win_sticky;
    wire signed [15:0] win_exp;
    fpu_align_add #(.WA(48), .WB(24), .WW(52)) u_align (
        .sig_a (prod),  .lsb_a (p_exp), .sa_sign (p_sign),
        .sig_b (c_sig), .lsb_b (k_exp), .sb_sign (c_sign),
        .win (win), .win_sign (win_sign), .win_sticky (win_sticky), .win_exp (win_exp)
    );

    // ---- 特殊值判据（必须先于舍入原语声明：精确抵消判据要用到它们） ----
    wire p_inf_zero = (a_inf & b_zero) | (a_zero & b_inf);   // Inf×0 ⇒ 必报 NV
    wire p_inf      = a_inf | b_inf;
    wire any_nan    = a_nan | b_nan | c_nan;

    // 积是否**恰好**为零（任一侧为零且另一侧有限）：此时结果等于把加数
    // 直接相加，零的符号必须按 IEEE 加法规则决定（不能用回路路径，它会
    // 丢掉 −0 的符号）。
    wire p_zero  = (a_zero & ~b_inf) | (b_zero & ~a_inf);
    wire p_finite_zero = p_zero & ~p_inf_zero;

    // ---- 精确抵消零的符号（IEEE-754-2008 §6.3；P6 保证 win==0 ⟺ 精确和为零）----
    wire exact_cancel = (win == 52'd0) & ~win_sticky & ~p_finite_zero & (p_sign != c_sign);
    wire round_sign   = win_sign | (exact_cancel & (rm == 3'b010));

    // ---- 一次舍入 ----
    wire [31:0] round_result;
    wire [4:0]  round_flags;
    fpu_round_n #(.FB(23), .WW(52), .RW(32), .EB(8),
                  .MIN_SUB(-149), .E_MAXF(255), .BIAS(127)) u_round (
        .sign      (round_sign),
        .sig       (win),
        .sticky_in (win_sticky),
        .exp       (win_exp),
        .rm        (rm),
        .result    (round_result),
        .fflags    (round_flags)
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
// 语义与结构同 fpu_fma_s（见上），仅参数不同：
//   旧：8192 bit 全宽对阶 + 8193 bit 加减 + 8192 bit 舍入域（419 191 LUT）；
//   新：110 bit 窗口（WW = 106 + 4，**106 bit 精确积永不丢位**）+ 1 bit sticky，
//       舍入域 110 bit。单次舍入语义不变（无中间舍入）。
//==============================================================================
module fpu_fma_d (
    input  wire [63:0] a,          // rs1
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
    wire signed [15:0] a_eunb = (a_exp == 0) ? -16'sd1022 : ($signed({5'b0, a_exp}) - 16'sd1023);
    wire signed [15:0] b_eunb = (b_exp == 0) ? -16'sd1022 : ($signed({5'b0, b_exp}) - 16'sd1023);
    wire signed [15:0] c_eunb = (c_exp == 0) ? -16'sd1022 : ($signed({5'b0, c_exp}) - 16'sd1023);

    // ---- 精确乘积（无舍入）----
    wire         p_sign = a_sign ^ b_sign ^ neg_prod;
    wire [105:0] prod   = a_sig * b_sig;                  // 精确，无舍入
    // value(prod) = prod × 2^(a_eunb + b_eunb − 104)；value(c) = c_sig × 2^(c_eunb − 52)
    wire signed [15:0] p_exp = a_eunb + b_eunb - 16'sd104;
    wire signed [15:0] k_exp = c_eunb - 16'sd52;

    // ---- 窄窗口对阶 + 有符号加（WW = 106 + 4 = 110）----
    wire [109:0]       win;
    wire               win_sign, win_sticky;
    wire signed [15:0] win_exp;
    fpu_align_add #(.WA(106), .WB(53), .WW(110)) u_align (
        .sig_a (prod),  .lsb_a (p_exp), .sa_sign (p_sign),
        .sig_b (c_sig), .lsb_b (k_exp), .sb_sign (c_sign),
        .win (win), .win_sign (win_sign), .win_sticky (win_sticky), .win_exp (win_exp)
    );

    // ---- 特殊值判据（必须先于舍入原语声明：精确抵消判据要用到它们） ----
    wire p_inf_zero = (a_inf & b_zero) | (a_zero & b_inf);   // Inf×0 ⇒ 必报 NV
    wire p_inf      = a_inf | b_inf;
    wire any_nan    = a_nan | b_nan | c_nan;

    // 积是否**恰好**为零（任一侧为零且另一侧有限）
    wire p_zero  = (a_zero & ~b_inf) | (b_zero & ~a_inf);
    wire p_finite_zero = p_zero & ~p_inf_zero;

    // ---- 精确抵消零的符号（IEEE-754-2008 §6.3；P6）----
    wire exact_cancel = (win == 110'd0) & ~win_sticky & ~p_finite_zero & (p_sign != c_sign);
    wire round_sign   = win_sign | (exact_cancel & (rm == 3'b010));

    // ---- 一次舍入 ----
    wire [63:0] round_result;
    wire [4:0]  round_flags;
    fpu_round_n #(.FB(52), .WW(110), .RW(64), .EB(11),
                  .MIN_SUB(-1074), .E_MAXF(2047), .BIAS(1023)) u_round (
        .sign      (round_sign),
        .sig       (win),
        .sticky_in (win_sticky),
        .exp       (win_exp),
        .rm        (rm),
        .result    (round_result),
        .fflags    (round_flags)
    );

    // ---- 特殊值（其余判据） ----
    wire any_snan   = a_snan | b_snan | c_snan;

    wire p_sign_w = p_sign;
    wire eff_zero = p_finite_zero & c_zero;
    wire eff_zero_sign = (p_sign_w == c_sign) ? p_sign_w : (rm == 3'b010);

    // 见 fpu_fma_s：inf_opp 必须排除 NaN 操作数（缺陷修复记录②）
    wire inf_opp = p_inf & c_inf & (p_sign != c_sign) & ~any_nan;
    wire inf_special = p_inf_zero | inf_opp;
    wire give_nan = any_nan | p_inf_zero | inf_opp;

    wire give_pinf = p_inf & ~p_inf_zero & ~(c_inf & (c_sign != p_sign)) & ~any_nan;
    wire give_cinf = c_inf & ~p_inf                              & ~any_nan;

    localparam [63:0] CANON_D = 64'h7FF8_0000_0000_0000;

    assign result = give_nan     ? CANON_D :
                    give_pinf    ? {p_sign, 11'h7FF, 52'b0} :
                    give_cinf    ? {c_sign, 11'h7FF, 52'b0} :
                    eff_zero     ? {eff_zero_sign, 63'b0} :
                    p_finite_zero ? {c_sign, c[62:0]} :  // 积为零：结果 = 有效加数（含 neg_add）
                                    round_result;

    wire is_special = give_nan | give_pinf | give_cinf | eff_zero | p_finite_zero;
    wire nv = any_snan | inf_special;
    assign fflags = { nv, 1'b0,
                      is_special ? 1'b0 : round_flags[2],
                      is_special ? 1'b0 : round_flags[1],
                      is_special ? 1'b0 : round_flags[0] };
endmodule
