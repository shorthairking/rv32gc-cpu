//==============================================================================
// fpu_div_sqrt.v —— 浮点除法与平方根（F/D），多拍非流水，拍数可配置
//==============================================================================
// 项目  : rv32gc-cpu（2A 单发射顺序 5 级基线核）
// 规格  : docs/design/08-baseline-5stage.md §5.3
//           —— "`fdiv`/`fsqrt` 的 `busy` 周期数**可配置**（`core_params.vh`
//              的参数）"
//           —— "2A 允许 FPU 为**多拍非流水**（`busy` 冻结前端）"
//         IEEE-754-2008 binary32/binary64；RISC-V F/D
//         （riscv-isa-manual/src/unpriv/f-st-ext.adoc:221-222 fdiv/fsqrt；
//          :186-188 norm:ieee_std_tininess「tininess after rounding」）
//
// 语义：
//   fdiv.s/d  = rs1 ÷ rs2，**单次**正确舍入（按 rm）
//   fsqrt.s/d = √rs1，**单次**正确舍入（按 rm）
//   特殊值（IEEE-754 + RISC-V 口径）：
//     NaN ⇒ canonical NaN（含 sNaN 则同时 NV）
//     0÷0、∞÷∞ ⇒ qNaN + NV ；有限非零÷0 ⇒ ±∞ + DZ（★ ∞÷0 ⇒ ±∞ 且**无** flag）
//     ∞÷有限非零、∞÷0 ⇒ ±∞ ；有限÷∞ ⇒ ±0 ；0÷有限非零 ⇒ ±0
//     √(+x) ⇒ 正值 ；√(−0) = −0 ；√(−x)、√(−∞) = qNaN + NV ；√(+∞) = +∞
//   fflags：NV / DZ / OF / UF / NX
//
// ★ 缺陷修复记录（2026-09-14）—— fdiv(±∞, ±0) 误报 DZ（IEEE-754-2008 §7.3）
//   现象：fdiv.s/d(±∞, ±0) 的结果位型本来就对（±∞），但**多置 DZ**。Spike 1.1.1-dev
//   实测同一批用例 fcsr=0（fdiv.d(∞,±0)→无 flag、fdiv.d(1,+0)→DZ、fdiv.d(0,0)→NV）。
//   根因：fdiv 特殊值判据的**分支次序**——`else if (b_zero)` 排在 `else if (a_inf)`
//   之前，∞÷0 先命中"有限非零 ÷ 0 ⇒ ±∞ + DZ"，而该分支只判除数、对被除数没有任何
//   约束，其隐含前提"被除数为有限非零"没有任何代码兜住。
//   规范口径：IEEE-754-2008 §7.3 divideByZero 仅当**被除数为有限非零**、除数为零、
//   且结果精确为无穷时置位；被除数本身是 ∞ 时不适用 ⇒ ∞÷0 = ±∞ 且无任何 flag
//   （RISC-V 沿用该口径；0÷0 与 ∞÷∞ 仍是 qNaN + NV）。结果符号仍为两操作数符号异或。
//   修法：把 `a_inf` 分支整体提到 `b_zero` **之前**（S/D 共用该分支，结果位型按
//   fmt_d 选），次序变为：
//     NaN → (0/0 | ∞/∞)→qNaN+NV → a_inf→±Inf(无flag) → b_zero(此时 a 必为有限
//     非零)→±Inf+DZ → (b_inf | a_zero)→±0 → 迭代
//   其余分支一字未动；并在 b_zero 分支补上"a 必为有限非零"的次序依赖注释。
//   验证：.work_fpu/verify_fdiv_special.sh（定向 CORE 10 = S4+D6 与 EXTRA 8，同一
//   条目表逐条与 Spike 对齐，含 done 单脉冲探针；修复前 CORE 4/10、EXTRA 3/8 FAIL
//   → 修复后 0 FAIL）；既有回归 .work_fpu/verify_sqrt_all.sh 默认路径与 --quick 全 PASS。
//
// ★ 拍数参数真源
//   `RV32GC_FDIV_CYCLES` / `RV32GC_FSQRT_CYCLES` 定义于 `rtl/pkg/core_params.vh`
//   （本模块**只读**，不改 pkg）。可在例化时覆盖 `FDIV_CYCLES`/`FSQRT_CYCLES`。
//   **数值结果与拍数无关**：迭代总步数由精度决定、固定不变，拍数只改延迟。
//
// ★ 红线 1/2（IP 优先 + 双分支）
//   检索结论：Vivado `Floating-Point Operator v7.1` IP 支持 Divide 与
//   Square root（binary32/64、多周期、可选握手）⇒ 综合分支
//   （`RV32GC_USE_VIVADO_IP`）例化该 IP；仿真分支（默认，iverilog/Verilator）
//   走本文件行为模型（**可综合**、纯整数运算），回归不依赖 Vivado。
//   ★ 不例化任何 FPGA 原语（红线 1）。
//
// ★ 算法（规格见 .work_fpu/DIVSQRT_RTL_SPEC.md；验证结论与复现入口见
//   .work_fpu/SQRT_FIX_REPORT.md §4 与 .work_fpu/verify_sqrt_all.sh）
//   除法：.work_fpu/iter_model.py 对黄金模型 40 万用例 0 差异（可信）。
//   开方：旧口径的 40 万"0 差异"是**假通过**（oracle 与 DUT 共用 parity 变换，
//     互相抵消）；改用独立 isqrt oracle 后暴露 ~50% 失配，根因与修法见下方
//     "开方（逐位 trial-subtract）"与 .work_fpu/sqrt_model_fix.py。
//   统一口径 value = sig × 2^(e_unb − fb)，sig 含隐藏位。
//
//   除法（逐位恢复余数）：
//     nb      = bits(sa)                       // 有效数位宽
//     STEPS   = 2*prec + 3                     // 固定（S:51, D:109）
//     stream  = sa << (STEPS − nb)             // 左对齐，第 0 步消费 sa 的 MSB
//     rem = (rem<<1)|bit ; if rem>=sb: rem-=sb, qb=1 ; q = (q<<1)|qb
//     sticky  = (rem != 0) ; sig = (q<<1)|sticky
//     exp     = (ea − eb) − (STEPS − nb) − 1
//     ★ 比例因子是 (STEPS − nb)，不是 STEPS/prec+3（实测踩到，差几个数量级）
//     ★ 商按 MSB-first 累积（q = (q<<1)|qb）
//
//   开方（逐位 trial-subtract）：
//     nb = bits(sa) ；E = e_unb − fb（原始值，**不做任何偶化/缩放**）
//     p  = (E + nb) & 1                     // 需要奇数窗口时的对齐偏移
//     stream = sa << (STEPS_MAX − nb)       // MSB 对齐 bit(STEPS_MAX−1)
//     消费 2*STEPS 位，p=1 时从 bit(STEPS_MAX) 起（多消费一个前导 0 位）
//       ⇒ 被开方数 W = sa·2^(2·STEPS − p − nb) = root² + rem，root = floor(√W)
//     rem = (rem<<2)|pair ; cand = (root<<2)|1
//     if rem >= cand: rem −= cand ; root = (root<<1)|1     // ★ 左移 1 位
//     else:                         root = (root<<1)
//     sticky = (rem != 0) ; sig = (root<<1)|sticky
//     exp    = (E + nb + p)/2 − STEPS − 1                  // (E+nb+p) 恒为偶
//     ★ root 每步**左移 1 位**，不是 +1（写成 +1 时根只有几位，实测踩到）
//     ★ 不能靠"把 sa 左移使 E、nb 都变偶"来凑整数指数：保值缩放满足
//       (sa<<=1, E−=1) 时 (E+nb) 不变，所以奇偶根本改不了——原实现在
//       (E+nb) 为奇的近半用例上丢掉 √2 因子（sqrt(4.0)=0x3FB504F3）。
//       正确做法是改**窗口对齐**（多消费 1 个前导 0 位），有效数一位不动。
//
// ★ 位宽：S 需 24+STEPS ≤ 75 位；D 需 53+STEPS ≤ 162 位 ⇒ 统一 256 bit 域。
//   以位宽换 RTL 简洁（S/D 共用一套 FSM），2A 面积非门禁。
//==============================================================================
`include "rv32_defs.vh"
`include "core_params.vh"

module fpu_div_sqrt #(
    // 默认值来自 pkg 唯一真源；可在例化时覆盖，数值结果与拍数无关
    parameter integer FDIV_CYCLES  = `RV32GC_FDIV_CYCLES,
    parameter integer FSQRT_CYCLES = `RV32GC_FSQRT_CYCLES
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        flush,        // 冲刷：立即释放 busy，丢弃进行中的迭代
    input  wire        start,        // 1 = 锁存操作数并开始
    input  wire        is_sqrt,      // 1 = fsqrt，0 = fdiv
    input  wire        fmt_d,        // 1 = double，0 = single
    input  wire [63:0] a,
    input  wire [63:0] b,
    input  wire [2:0]  rm,
    output wire        busy,         // 迭代期间为 1（冻结前端）
    output wire        done,         // 结果有效的单拍脉冲
    output wire [63:0] result,       // 结果（S 路径低 32 bit 有效，未 NaN-box）
    output wire [4:0]  fflags
);
    //==========================================================================
    // 规模（D 与 S 共用 256 bit 域；S 使用其低位部分）
    //==========================================================================
    localparam integer DW     = 256;
    localparam integer STEPS_S = 2 * 24 + 3;    // 51
    localparam integer STEPS_D = 2 * 53 + 3;    // 109
    localparam integer STEPS_MAX = STEPS_D;

    // 每拍推进 1 步（位串行；2A 性能非门禁）。
    // FDIV_CYCLES/FSQRT_CYCLES 决定**总拍数**：为满足 08 §5.3 ② 的"拍数
    // 可配置"，本实现按参数计算每拍步数（≥1），保证：
    //   · 总步数固定 ⇒ 数值与拍数无关；
    //   · 拍数 ≈ CYCLES ⇒ busy 周期可配置。
    function integer steps_per_cycle;
        input integer cycles;
        input integer steps;
        begin
            if (cycles >= steps) steps_per_cycle = 1;
            else if (cycles < 1) steps_per_cycle = 1;
            else steps_per_cycle = (steps + cycles - 1) / cycles;
        end
    endfunction

    localparam integer SPC_DIV  = steps_per_cycle(FDIV_CYCLES,  STEPS_MAX);
    localparam integer SPC_SQRT = steps_per_cycle(FSQRT_CYCLES, STEPS_MAX);

    //==========================================================================
    // 有效数位宽（1..53）：用于把 MSB 对齐到窗口顶端
    //   ★ 必须用实际位宽，不能用固定 53——否则 S（24 位）的 MSB 会落在
    //     窗口之外，前导 0 吃掉全部迭代步数，商恒为 0（实测踩到）。
    //==========================================================================
    function [6:0] bits_of;
        input [52:0] v;
        integer i;
        begin
            bits_of = 7'd1;
            for (i = 0; i < 53; i = i + 1) begin
                if (v[i]) bits_of = i[6:0] + 7'd1;
            end
        end
    endfunction

    //==========================================================================
    // 特殊值判定（组合，start 拍采样）
    //==========================================================================
    wire        a_sign = fmt_d ? a[63]    : a[31];
    wire        b_sign = fmt_d ? b[63]    : b[31];
    wire [10:0] a_exp  = fmt_d ? a[62:52] : {3'b000, a[30:23]};
    wire [10:0] b_exp  = fmt_d ? b[62:52] : {3'b000, b[30:23]};
    wire [51:0] a_frac = fmt_d ? a[51:0]  : {29'b0, a[22:0]};
    wire [51:0] b_frac = fmt_d ? b[51:0]  : {29'b0, b[22:0]};
    wire [10:0] emax_w = fmt_d ? 11'h7FF  : 11'h0FF;

    wire a_nan  = (a_exp == emax_w) && (a_frac != 0);
    wire b_nan  = (b_exp == emax_w) && (b_frac != 0);
    wire a_inf  = (a_exp == emax_w) && (a_frac == 0);
    wire b_inf  = (b_exp == emax_w) && (b_frac == 0);
    wire a_zero = (a_exp == 0) && (a_frac == 0);
    wire b_zero = (b_exp == 0) && (b_frac == 0);
    wire a_snan = a_nan && ~a[fmt_d ? 51 : 22];
    wire b_snan = b_nan && ~b[fmt_d ? 51 : 22];

    // 有效数（含隐藏位；亚正规 hidden = 0），**右对齐且宽度 = prec**
    //   ★ 不能用统一的 53 bit 域：S 的隐藏位若落在 bit52，则 bits(sig) 恒为
    //     53（而非 24），导致位流对齐、比例因子 (STEPS − nb) 全错，商恒为 0
    //     （实测踩到）。
    //   D：{1'b1, a_frac} → 53 bit，隐藏位在 bit52
    //   S：{1'b1, a[22:0]} → 24 bit，隐藏位在 bit23，再零扩展到 53 bit
    wire [52:0] a_sig = (a_exp == 0) ? {1'b0, a_frac}
                                     : {1'b1, a_frac};
    wire [52:0] b_sig = (b_exp == 0) ? {1'b0, b_frac}
                                     : {1'b1, b_frac};
    wire [23:0] a_sig_s = (a_exp == 0) ? {1'b0, a[22:0]} : {1'b1, a[22:0]};
    wire [23:0] b_sig_s = (b_exp == 0) ? {1'b0, b[22:0]} : {1'b1, b[22:0]};
    //   归一化：宽度恰为 prec（S:24 / D:53），隐藏位在最高位
    wire [52:0] a_sig_n = fmt_d ? a_sig   : {29'b0, a_sig_s};
    wire [52:0] b_sig_n = fmt_d ? b_sig   : {29'b0, b_sig_s};

    wire signed [15:0] bias_w = fmt_d ? 16'sd1023 : 16'sd127;
    wire signed [15:0] fb_w   = fmt_d ? 16'sd52   : 16'sd23;
    wire signed [15:0] a_eunb = (a_exp == 0) ? (16'sd1 - bias_w)
                                             : ($signed({5'b0, a_exp}) - bias_w);
    wire signed [15:0] b_eunb = (b_exp == 0) ? (16'sd1 - bias_w)
                                             : ($signed({5'b0, b_exp}) - bias_w);

    localparam [63:0] CANON_S = 64'h0000_0000_7FC0_0000;
    localparam [63:0] CANON_D = 64'h7FF8_0000_0000_0000;

    // 定宽有符号常量（避免 32 bit `integer` 与 16 bit 有符号量混算后被截断）
    localparam signed [15:0] STEPS_MAX_S = STEPS_MAX;

    reg [6:0] a_sig_bits;

    //==========================================================================
    // 状态
    //==========================================================================
    reg               busy_r;
    reg [15:0]        cnt;         // 剩余迭代步数
    reg               r_sqrt;
    reg               r_fmt_d;
    reg [2:0]         r_rm;
    reg               r_sign;
    reg signed [15:0] exp_r;       // 供舍入原语的指数（值 = sig × 2^exp_r）
    reg [DW-1:0]      num_r;       // 被除数 / 被开方数（左对齐的位流寄存器）
    reg [DW-1:0]      den_r;       // 除数
    reg [DW-1:0]      rem_r;       // 部分余数 → 迭代结束时装载 (sig|sticky)
    reg [DW-1:0]      quo_r;       // 商 / 根
    reg               done_r;
    reg [63:0]        result_r;    // 特殊值结果 / 锁存的舍入结果
    reg [4:0]         fflags_r;
    reg               sqrt_p_r;    // 锁存的开方位流偏移（1 = 多消费一个前导 0）
    reg               pack_r;      // 1 = 下一拍打包 sig/exp
    reg               pend_r;      // 1 = sig/exp 已稳定，本拍锁存舍入结果

    //==========================================================================
    // 迭代结果 → 已验证的舍入原语（组合）
    //==========================================================================
    // ★ 必须传**完整**的 sig（D 时可达 163 位），不能只取低 64 位：
    //   quo_r 累积 STEPS_MAX 位，sig = (quo<<1)|sticky 直接落在 rem_r 上，
    //   截断会丢掉全部有效位、结果恒为 0（实测踩到）。
    wire [1023:0] sig_round_s = rem_r[DW-1:0];
    wire [8191:0] sig_round_d = rem_r[DW-1:0];

    wire [31:0] rs_res;  wire [4:0] rs_fl;
    wire [63:0] rd_res;  wire [4:0] rd_fl;
    fpu_round_s u_rs (.sign(r_sign), .sig(sig_round_s), .exp(exp_r[12:0]),
                      .rm(r_rm), .result(rs_res), .fflags(rs_fl));
    fpu_round_d u_rd (.sign(r_sign), .sig(sig_round_d), .exp(exp_r[13:0]),
                      .rm(r_rm), .result(rd_res), .fflags(rd_fl));

    // 开方：打包阶段的指数 = ((E+nb+p) >>> 1) − STEPS − 1
    //   ★ 三个加数恒为偶和 ⇒ 算术右移 1 位即精确减半；
    //   ★ 必须先落到**有符号** wire 再移位：有符号量与非有符号拼接混算时
    //     整个表达式被当作无符号，`>>` 会变成逻辑移位（负数时结果错）。
    wire signed [15:0] sq_sum  = exp_r + {{9{1'b0}}, a_sig_bits}
                                       + {{15{1'b0}}, sqrt_p_r};
    wire signed [15:0] sq_half = sq_sum >>> 1;

    //==========================================================================
    // 开方操作数预处理（组合）
    //   value = sa × 2^E，sa = a_sig_n（含隐藏位），E = e_unb − fb。
    //   ★ **不做任何"偶化"**：保值缩放 (sa<<=1, E −= 1) 满足 E+nb 不变式
    //     （nb 同时 +1），故 (E+nb) 的奇偶**无法**通过缩放有效数修正。
    //     原实现强令 E 偶、再令 nb 偶，当 (E+nb) 为奇时 E 被还原为奇，指数
    //     被当成半整数处理、静默丢掉 √2 因子 ⇒ sqrt(4.0)=0x3FB504F3（=√2）。
    //   ★ 正确做法（独立 isqrt oracle 验证：.work_fpu/sqrt_model_fix.py）：
    //     按 (E+nb) 的奇偶让位流窗口**多消费 1 个前导 0 位**（等价于被开方
    //     数窗口减半）：p = (E+nb)&1 ⇒ W = sa·2^(2·STEPS − p − nb)，
    //       root = floor(√W)（递推不变式，见 .work_fpu/sqrt_fix.py）
    //       sig  = (root<<1)|sticky  ⇒  √value = sig·2^exp
    //       exp  = (E+nb+p)/2 − STEPS − 1        （(E+nb+p) 恒为偶 ⇒ 整数）
    //==========================================================================
    wire signed [15:0] sqrt_E  = (a_eunb - fb_w);
    wire [6:0]         sqrt_nb = bits_of(a_sig_n);          // 有效数实际位宽
    wire               sqrt_p  = sqrt_E[0] ^ sqrt_nb[0];    // (E+nb) 为奇 ⇒ 多消费 1 位

    //==========================================================================
    // 组合：单步迭代
    //==========================================================================
    // 位流窗口：有效数的 MSB 对齐到 num_r 的 bit (STEPS_MAX−1)，迭代时从该位
    // 起逐位（除法）或逐两位（开方）消费。
    // ★ 必须从"窗口顶端"bit(STEPS_MAX−1) 消费，**不是** DW 顶端 bit255；
    //   否则前导 0 会吃掉全部步数、商恒为 0（实测踩到）。
    wire stream_msb  = num_r[STEPS_MAX-1];
    // 开方消费两位：p=1 时从 bit(STEPS_MAX) 起（多消费一个前导 0 位）
    wire [1:0] stream_top2 = sqrt_p_r ? num_r[STEPS_MAX -: 2]
                                      : num_r[STEPS_MAX-1 -: 2];

    // 除法：rem' = (rem<<1) | 位流最高位
    wire [DW-1:0] rem_sh  = {rem_r[DW-2:0], stream_msb};
    wire [DW-1:0] rem_sub = rem_sh - den_r;
    wire          div_ge  = ~rem_sub[DW-1];         // 无借位 ⇒ rem' >= den

    // 开方：每次消费两位；cand = (root<<2)|1
    wire [DW-1:0] rem4   = {rem_r[DW-3:0], stream_top2};
    wire [DW-1:0] cand4  = (quo_r << 2) | {{(DW-1){1'b0}}, 1'b1};
    wire [DW-1:0] sq_sub = rem4 - cand4;
    wire          sq_ge  = ~sq_sub[DW-1];

    //==========================================================================
    // 主状态机
    //   `always @(posedge)` 用于时序状态机（需要计数器与向量寄存器在时钟沿
    //   更新，无法用连续赋值表达；这是 AGENT.md §4.3 允许的"确有必要"场合）。
    //==========================================================================
    integer k;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy_r   <= 1'b0;
            cnt      <= 16'd0;
            r_sqrt   <= 1'b0;
            r_fmt_d  <= 1'b0;
            r_rm     <= 3'b000;
            r_sign   <= 1'b0;
            exp_r    <= 16'sd0;
            num_r    <= {DW{1'b0}};
            den_r    <= {DW{1'b0}};
            rem_r    <= {DW{1'b0}};
            quo_r    <= {DW{1'b0}};
            done_r   <= 1'b0;
            result_r <= 64'd0;
            fflags_r <= 5'd0;
            a_sig_bits <= 7'd1;
            sqrt_p_r <= 1'b0;
            pack_r   <= 1'b0;
            pend_r   <= 1'b0;
        end else if (flush) begin
            busy_r <= 1'b0;
            cnt    <= 16'd0;
            done_r <= 1'b0;
            pack_r <= 1'b0;
            pend_r <= 1'b0;
        end else begin
            done_r <= 1'b0;

            // ---- 阶段 B：打包 sig/exp（quo_r/rem_r 已稳定为终值） ----
            if (pack_r) begin
                pack_r <= 1'b0;
                pend_r <= 1'b1;
                // sig = (quo<<1) | sticky
                rem_r <= (quo_r << 1) | ((rem_r != 0) ? 1'b1 : 1'b0);
                if (r_sqrt) begin
                    // exp = (E + nb + p)/2 − STEPS − 1
                    //   推导：p = (E+nb)&1 ⇒ W = sa·2^(2·STEPS − p − nb)，
                    //   root = floor(√W) ⇒ √value = root·2^((E+nb+p)/2 − STEPS)；
                    //   sig = (root<<1)|sticky 多出的因子 2 即末尾的 −1。
                    //   ★ E、nb 均为**原始**值（不做偶化、不改有效数）。
                    exp_r <= sq_half - STEPS_MAX_S - 16'sd1;
                end else begin
                    exp_r <= exp_r - STEPS_MAX[15:0] + a_sig_bits - 16'sd1;
                end
            end

            // ---- 阶段 C：sig/exp 已稳定，锁存组合舍入结果 ----
            if (pend_r) begin
                pend_r   <= 1'b0;
                busy_r   <= 1'b0;
                done_r   <= 1'b1;
                result_r <= r_fmt_d ? rd_res : {32'b0, rs_res};
                fflags_r <= r_fmt_d ? rd_fl  : rs_fl;
            end

            if (start && !busy_r) begin
                //------------------------------------------------------------
                // 启动：特殊值优先；否则装载位流并进入迭代
                //------------------------------------------------------------
                r_sqrt  <= is_sqrt;
                r_fmt_d <= fmt_d;
                r_rm    <= rm;
                a_sig_bits <= bits_of(a_sig_n);   // 实际有效数位宽（S:1..24, D:1..53）
                sqrt_p_r <= sqrt_p;               // 开方：位流多消费 1 个前导 0 位？

                if (is_sqrt) begin
                    //----------------------- fsqrt --------------------------
                    r_sign <= a_sign;
                    if (a_nan) begin
                        // NaN ⇒ canonical NaN（sNaN 置 NV）
                        result_r <= fmt_d ? CANON_D : CANON_S;
                        fflags_r <= a_snan ? 5'b10000 : 5'b00000;
                        done_r   <= 1'b1;  busy_r <= 1'b0;
                    end else if (a_zero) begin
                        // √(±0) = ±0（含 −0，无标志）
                        result_r <= a;
                        fflags_r <= 5'b00000;
                        done_r   <= 1'b1;  busy_r <= 1'b0;
                    end else if (a_inf && !a_sign) begin
                        // √(+∞) = +∞
                        result_r <= a;
                        fflags_r <= 5'b00000;
                        done_r   <= 1'b1;  busy_r <= 1'b0;
                    end else if (a_sign) begin
                        // √(−x) ⇒ qNaN + NV；★ 含 −∞（IEEE-754：负数域含 −∞，
                        //   不是"原样返回 −∞"；旧实现把 −∞ 与 +∞ 混在一个分支里，
                        //   会把 −∞ 原样返回且不置 NV）
                        result_r <= fmt_d ? CANON_D : CANON_S;
                        fflags_r <= 5'b10000;
                        done_r   <= 1'b1;  busy_r <= 1'b0;
                    end else begin
                        // 迭代初始（开方）：见上方"开方操作数预处理"
                        //   num_r = sa << (STEPS_MAX − nb)：MSB 对齐到 bit(STEPS_MAX−1)；
                        //   p=1 时消费从 bit(STEPS_MAX) 起 ⇒ 多消费一个前导 0 位，
                        //   被开方数窗口 = sa·2^(2·STEPS − p − nb)。
                        num_r <= {DW{1'b0}} | ({10'b0, a_sig_n}
                                                << (STEPS_MAX - sqrt_nb));
                        exp_r <= sqrt_E;
                        rem_r  <= {DW{1'b0}};
                        quo_r  <= {DW{1'b0}};
                        den_r  <= {DW{1'b0}};
                        cnt    <= STEPS_MAX[15:0];
                        busy_r <= 1'b1;
                    end
                end else begin
                    //----------------------- fdiv ---------------------------
                    r_sign <= a_sign ^ b_sign;
                    if (a_nan | b_nan) begin
                        result_r <= fmt_d ? CANON_D : CANON_S;
                        fflags_r <= (a_snan | b_snan) ? 5'b10000 : 5'b00000;
                        done_r   <= 1'b1;  busy_r <= 1'b0;
                    end else if ((a_zero & b_zero) | (a_inf & b_inf)) begin
                        // 0/0、∞/∞ ⇒ qNaN + NV
                        result_r <= fmt_d ? CANON_D : CANON_S;
                        fflags_r <= 5'b10000;
                        done_r   <= 1'b1;  busy_r <= 1'b0;
                    end else if (a_inf) begin
                        // ∞ ÷ 有限非零、∞ ÷ 0 ⇒ ±∞，**无任何 flag**
                        //   ★ ∞÷0 必须走这里：IEEE-754-2008 §7.3 divideByZero 只在
                        //   被除数为**有限非零**时置位；本分支必须排在 b_zero 之前
                        //   （缺陷修复记录见文件头）。
                        result_r <= fmt_d ? {a_sign ^ b_sign, 11'h7FF, 52'b0}
                                          : {32'b0, a_sign ^ b_sign, 8'hFF, 23'b0};
                        fflags_r <= 5'b00000;
                        done_r   <= 1'b1;  busy_r <= 1'b0;
                    end else if (b_zero) begin
                        // 有限非零 ÷ 0 ⇒ ±∞ + DZ
                        //   ★ 次序依赖：走到这里 a 必为**有限非零**（NaN / ∞ / 0 都已被
                        //   上面的分支拦截）；若把本分支提到 a_inf 之前，∞÷0 会误置 DZ。
                        result_r <= fmt_d ? {a_sign ^ b_sign, 11'h7FF, 52'b0}
                                          : {32'b0, a_sign ^ b_sign, 8'hFF, 23'b0};
                        fflags_r <= 5'b01000;
                        done_r   <= 1'b1;  busy_r <= 1'b0;
                    end else if (b_inf || a_zero) begin
                        result_r <= fmt_d ? {a_sign ^ b_sign, 63'b0}
                                          : {32'b0, a_sign ^ b_sign, 31'b0};
                        fflags_r <= 5'b00000;
                        done_r   <= 1'b1;  busy_r <= 1'b0;
                    end else begin
                        // 迭代初始：把被除数左对齐到 STEPS_MAX 窗口
                        //   stream = sa << (STEPS_MAX − bits(sa))
                        //   这里用固定上界 53（D 的有效数位宽）做"窗口顶端"，
                        //   S 时 sa 更小 ⇒ 实际消费窗口更靠高位，但步数与
                        //   比例因子均由"实际消费位数"决定，见下。
                        //   num_r = sa << (STEPS_MAX − bits(sa))：MSB 对齐到
                        //   窗口顶端 bit(STEPS_MAX−1)
                        num_r <= {DW{1'b0}} | ({10'b0, a_sig_n} << (STEPS_MAX - bits_of(a_sig_n)));
                        den_r <= {DW{1'b0}} | {10'b0, b_sig_n};
                        rem_r <= {DW{1'b0}};
                        quo_r <= {DW{1'b0}};
                        // exp 的最终值在迭代结束时统一赋值（依赖实际步数）
                        exp_r <= (a_eunb - fb_w) - (b_eunb - fb_w);
                        cnt   <= STEPS_MAX[15:0];
                        busy_r <= 1'b1;
                    end
                end
            end else if (busy_r && !pack_r && !pend_r) begin
                //------------------------------------------------------------
                // 迭代推进（每拍 SPC 步）
                // ★ 关键：最后一拍**必须**照常执行迭代步，否则最后一个商位
                //   永远进不到 quo_r 里（实测：1.0/2.0 得到 0.25 而非 0.5）。
                //   结算推迟到下一拍（pend_r），那时 quo_r/rem_r 已是终值，
                //   组合舍入原语才能读到正确的 sig/exp。
                // ★ 分支条件必须排除 pack_r/pend_r：否则"最后一拍"把 pack_r 置 1
                //   后，下一拍 pack 分支与 busy 分支**同时**有效，busy 分支里的
                //   `if (cnt<=1) pack_r<=1`（此时 cnt 已是 0）会覆盖 pack 分支的
                //   清零 ⇒ pack/pend 二次执行、exp 被重复打包，并多发出**第二个
                //   done 脉冲**（实测：sqrt(4.0) 第二拍给 0x1F000000、div 1.0/2.0
                //   第二拍给 0+UF|NX）。这是既有缺陷，已按此条件修复。
                //------------------------------------------------------------
                for (k = 0; k < SPC_DIV; k = k + 1) begin
                    // ★ 只在真正处于迭代阶段时推进一步（belt & braces）
                    if (!pack_r && !pend_r && (cnt != 16'd0)) begin
                    if (r_sqrt) begin
                        // 开方：每步消费 2 位；root 左移 1 位
                        if (sq_ge) begin
                            rem_r <= sq_sub;
                            quo_r <= (quo_r << 1) | {{(DW-1){1'b0}}, 1'b1};
                        end else begin
                            rem_r <= rem4;
                            quo_r <= (quo_r << 1);
                        end
                        num_r <= num_r << 2;
                    end else begin
                        // 除法：每步消费 1 位；商 MSB-first 累积
                        if (div_ge) begin
                            rem_r <= rem_sub;
                            quo_r <= {quo_r[DW-2:0], 1'b1};
                        end else begin
                            rem_r <= rem_sh;
                            quo_r <= {quo_r[DW-2:0], 1'b0};
                        end
                        num_r <= num_r << 1;
                    end
                    end
                end

                if (cnt <= 16'd1) begin
                    // 最后一步已在上面的 for 中执行；下一拍进入打包
                    cnt    <= 16'd0;
                    pack_r <= 1'b1;
                end else begin
                    cnt <= cnt - 16'd1;
                end
            end
        end
    end

    //==========================================================================
    // 输出
    //==========================================================================
    // ---- 输出 ----
    // 结果在 done 拍锁存：迭代结束的那一拍 rem_r/exp_r 刚被非阻塞赋值，
    // 组合舍入原语在同一拍读到的仍是旧值（实测会得到差一倍的结果），
    // 因此在"结束标志置起"的下一拍再采样并锁存。
    assign busy   = busy_r;
    assign done   = done_r;
    assign result = result_r;
    assign fflags = fflags_r;
endmodule
