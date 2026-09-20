//==============================================================================
// sim/unit/tb_fpu_cmp_cvt.sv —— rtl/exec/fpu_cmp.v + rtl/exec/fpu_cvt.v 单元测试
//==============================================================================
// 目的    : 一个 TB 覆盖 fpu_cmp.v 与 fpu_cvt.v 两个模块的全部指令（F/D 双格式）。
// 判据    : ① 进程退出码 0；② 输出末行恰为 `TB_FPU_CMP_CVT_UNIT: PASS`（全文唯一 PASS）；
//           ③ 任何一条断言不符 ⇒ 打印 [FAIL] 并在末尾 $fatal(1)（非零退出码），
//              绝不会打印 PASS（08 §8.1「未捕获即失败」纪律：显式计数器 + fail-closed）。
// 覆盖    : 每条指令 ≥ 2 例；另含
//             · NaN 传播：qNaN/sNaN/双 NaN，fmin/fmax 的单 NaN 与双 NaN、
//               比较类遇 NaN 的 NV 口径（feq 仅 sNaN、flt/fle 任一 NaN）；
//             · ±0 比较：+0==−0 为真、flt(+0,−0)=0、fle(+0,−0)=1、
//               fmin(+0,−0)=−0、fmax(+0,−0)=+0；
//             · fclass 全 10 类（S 与 D 各 10 例）；
//             · fcvt.w[.wu].s/d 的饱和 + NV（含 ±∞、NaN、sNaN、−NaN ⇒ 正值饱和）；
//               NX 口径（有符号/无符号取整不精确时置 NX、置 NV 时不置 NX）；
//             · NaN-boxing：非 transfer 的 S 操作数高位不全 1 ⇒ 按 canonical NaN；
//               S 结果（fsgnj.s/fmin.s/fmax.s/fcvt.s.w[.wu]/fcvt.s.d/fmv.w.x）
//               高 32 位必须全 1（chk_box）；fmv.x.d 位不变（chk_hi32ff 断言高 32 位
//               全 1 的 NaN-boxed 源原样透传）。
//             · 反向口径同样固化：D 结果（fcvt.d.s/fcvt.d.w[.wu]/fmv.d.x）是**完整
//               64 位真实值、不补高 32 位 1**，由 result 全 64 位逐位相等断言覆盖
//               （例如 fcvt.d.s(1.0) 必须恰为 0x3FF0_0000_0000_0000）。
// 顶层    : tb_fpu_cmp_cvt（验收命令用 -s tb_fpu_cmp_cvt）
// 时钟    : 本 TB 自带 10 ns 周期时钟（T4 起 DUT 为流水单元）
// 说明    : ★ T4（2026-09-20）后两个 DUT 均为 **8 拍固定潜伏期的流水单元**
//           （rtl/exec/fpu.v §2「T4 契约变更」；cmp = 组合核心 + 8 级 fpu_delay，
//            cvt = decode/prep/round×3/dispatch + pad）⇒ 每条向量 = 设激励 →
//           **等 SC_LAT = 8 个时钟沿** → 在结果拍逐位比对（result 全 64 位 +
//           fflags 全 5 位；不是「打印看看」）。断言强度与覆盖**不降**：
//           向量表、比较位宽、fail-closed 计数逻辑一字未动，只改采样时刻。
//           ★ 本 TB 的期望值不是手抄的：由独立 Python 黄金模型（精确有理数实现，
//             其 RNE 通路已与 Python 原生浮点转换 8 万例交叉验证）算出后固化在此，
//             TB 本身自包含、不依赖任何外部文件。
//==============================================================================
`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"

module tb_fpu_cmp_cvt;

    //--------------------------------------------------------------------------
    // 0. 时钟 + 检查计数器（fail-closed：只有走完全部检查且 0 错误才可能 PASS）
    //--------------------------------------------------------------------------
    // ★ T4：DUT 为 8 拍固定潜伏期的流水单元 ⇒ 自带时钟；
    //   SC_LAT **必须**与 rtl/exec/fpu.v 的 FPU_SC_LAT（8）一致。
    localparam integer SC_LAT = 8;
    reg clk = 1'b0;
    always #5 clk = ~clk;

    integer chk_cnt = 0;    // 已执行检查条数
    integer err_cnt = 0;    // 失败条数

    //--------------------------------------------------------------------------
    // 1. DUT 例化
    //--------------------------------------------------------------------------
    reg  [6:0]  c_op;
    reg  [1:0]  c_fmt;
    reg  [63:0] c_a, c_b;
    wire [63:0] c_r;
    wire [4:0]  c_fl;

    fpu_cmp u_cmp (
        .clk    (clk),
        .fp_op  (c_op),
        .fmt    (c_fmt),
        .a      (c_a),
        .b      (c_b),
        .result (c_r),
        .fflags (c_fl)
    );

    reg  [6:0]  v_op;
    reg  [1:0]  v_fmt;
    reg  [2:0]  v_rm, v_frm;
    reg  [63:0] v_a;
    wire [63:0] v_r;
    wire [4:0]  v_fl;

    fpu_cvt u_cvt (
        .clk    (clk),
        .spec_gate (1'b1),          // ★ T4：单元 TB 直连 DUT ⇒ 门控恒开
        .fp_op  (v_op),
        .fmt    (v_fmt),
        .rm     (v_rm),
        .frm    (v_frm),
        .a      (v_a),
        .result (v_r),
        .fflags (v_fl)
    );

    //--------------------------------------------------------------------------
    // 2. 归一化操作码镜像（与 rtl/exec/fpu_cmp.v / fpu_cvt.v 头注的表一致）
    //--------------------------------------------------------------------------
    localparam [6:0] OP_FSGNJ = 7'd5, OP_FSGNJN = 7'd6, OP_FSGNJX = 7'd7;
    localparam [6:0] OP_FMIN = 7'd8, OP_FMAX = 7'd9;
    localparam [6:0] OP_FEQ = 7'd10, OP_FLT = 7'd11, OP_FLE = 7'd12, OP_FCLASS = 7'd13;
    localparam [6:0] OP_FMV_X = 7'd14, OP_FMV_W_X = 7'd15;
    localparam [6:0] OP_FCVT_W_S = 7'd16, OP_FCVT_WU_S = 7'd17;
    localparam [6:0] OP_FCVT_S_W = 7'd18, OP_FCVT_S_WU = 7'd19;
    localparam [6:0] OP_FCVT_W_D = 7'd20, OP_FCVT_WU_D = 7'd21;
    localparam [6:0] OP_FCVT_D_W = 7'd22, OP_FCVT_D_WU = 7'd23;
    localparam [6:0] OP_FCVT_S_D = 7'd24, OP_FCVT_D_S = 7'd25;

    localparam [1:0] FMT_S = 2'd0, FMT_D = 2'd1;

    localparam [4:0] F_NV = 5'b10000, F_NX = 5'b00001, F_UF = 5'b00010, F_OF = 5'b00100;

    //--------------------------------------------------------------------------
    // 3. 检查任务
    //--------------------------------------------------------------------------
    task automatic chk_cmp;
        input [255:0] name;
        input [6:0]   op;
        input [1:0]   fmt;
        input [63:0]  a, b, er;
        input [4:0]   ef;
        begin
            c_op = op; c_fmt = fmt; c_a = a; c_b = b;
            // ★ T4：等固定潜伏期（激励在下一个时钟沿被采样；结果在第 SC_LAT 拍）
            repeat (SC_LAT) @(posedge clk);
            #1;                                  // 结果拍中部采样
            chk_cnt = chk_cnt + 1;
            if (c_r !== er || c_fl !== ef) begin
                err_cnt = err_cnt + 1;
                $display("  [FAIL] fpu_cmp %0s : op=%0d fmt=%0d a=%016h b=%016h -> got %016h/%05b, exp %016h/%05b",
                         name, op, fmt, a, b, c_r, c_fl, er, ef);
            end
        end
    endtask

    task automatic chk_cvt;
        input [255:0] name;
        input [6:0]   op;
        input [1:0]   fmt;
        input [2:0]   rm;
        input [63:0]  a;
        input [2:0]   frm;
        input [63:0]  er;
        input [4:0]   ef;
        begin
            v_op = op; v_fmt = fmt; v_rm = rm; v_frm = frm; v_a = a;
            // ★ T4：等固定潜伏期（同 chk_cmp）
            repeat (SC_LAT) @(posedge clk);
            #1;
            chk_cnt = chk_cnt + 1;
            if (v_r !== er || v_fl !== ef) begin
                err_cnt = err_cnt + 1;
                $display("  [FAIL] fpu_cvt %0s : op=%0d fmt=%0d rm=%0b frm=%0b a=%016h -> got %016h/%05b, exp %016h/%05b",
                         name, op, fmt, rm, frm, a, v_r, v_fl, er, ef);
            end
        end
    endtask

    // S 结果 NaN-boxing 断言：高 32 位必须全 1（d-st-ext.adoc:29）
    task automatic chk_box;
        input [255:0] name;
        begin
            chk_cnt = chk_cnt + 1;
            if (v_r[63:32] !== 32'hFFFF_FFFF) begin
                err_cnt = err_cnt + 1;
                $display("  [FAIL] NaN-box %0s : result=%016h 高 32 位应为 FFFFFFFF", name, v_r);
            end
        end
    endtask

    // fmv.x.d 位不变断言：结果高 32 位必须等于源的高 32 位（源高位全 1 时即全 1）
    task automatic chk_hi32ff;
        input [255:0] name;
        begin
            chk_cnt = chk_cnt + 1;
            if (v_r[63:32] !== 32'hFFFF_FFFF) begin
                err_cnt = err_cnt + 1;
                $display("  [FAIL] fmv.x.d 高 32 位 %0s : result=%016h 高 32 位应为 FFFFFFFF", name, v_r);
            end
        end
    endtask

    // S 结果 NaN-box 断言的普通版本（用于 fpu_cmp 的 S 写回）
    task automatic chk_boxc;
        input [255:0] name;
        begin
            chk_cnt = chk_cnt + 1;
            if (c_r[63:32] !== 32'hFFFF_FFFF) begin
                err_cnt = err_cnt + 1;
                $display("  [FAIL] NaN-box(cmp) %0s : result=%016h 高 32 位应为 FFFFFFFF", name, c_r);
            end
        end
    endtask

    //--------------------------------------------------------------------------
    // 4. 激励
    //--------------------------------------------------------------------------
    initial begin
        $display("=== tb_fpu_cmp_cvt : rtl/exec/fpu_cmp.v + rtl/exec/fpu_cvt.v 单元测试开始 ===");


        //==========================================================================
        // 4.1 fsgnj.s / fsgnjn.s / fsgnjx.s（含 NaN 不规范化、NaN-boxing 违约）
        //==========================================================================
        // fsgnj.s(1.0, -2.0) = -1.0，无 fflags
        chk_cmp("fsgnj_s_basic", 5, 0, 64'hFFFF_FFFF_3F80_0000, 64'hFFFF_FFFF_C000_0000, 64'hFFFF_FFFF_BF80_0000, 5'b00000);
        chk_boxc("fsgnj_s_basic");
        // fsgnj.s(-2.0, +1.0) = +2.0（符号取自 rs2）
        chk_cmp("fsgnj_s_negsign", 5, 0, 64'hFFFF_FFFF_C000_0000, 64'hFFFF_FFFF_3F80_0000, 64'hFFFF_FFFF_4000_0000, 5'b00000);
        chk_boxc("fsgnj_s_negsign");
        // fsgnjn.s(1.0, -2.0) = +1.0
        chk_cmp("fsgnjn_s_basic", 6, 0, 64'hFFFF_FFFF_3F80_0000, 64'hFFFF_FFFF_C000_0000, 64'hFFFF_FFFF_3F80_0000, 5'b00000);
        chk_boxc("fsgnjn_s_basic");
        // fsgnjn.s(qNaN, +1.0)：不规范化 NaN ⇒ 取 rs1 位型、符号取反
        chk_cmp("fsgnjn_s_nan", 6, 0, 64'hFFFF_FFFF_7FC0_0000, 64'hFFFF_FFFF_3F80_0000, 64'hFFFF_FFFF_FFC0_0000, 5'b00000);
        chk_boxc("fsgnjn_s_nan");
        // fsgnjx.s(-2.0, -1.0)：符号异或 ⇒ +2.0
        chk_cmp("fsgnjx_s_basic", 7, 0, 64'hFFFF_FFFF_C000_0000, 64'hFFFF_FFFF_BF80_0000, 64'hFFFF_FFFF_4000_0000, 5'b00000);
        chk_boxc("fsgnjx_s_basic");
        // fsgnjx.s(qNaN, -1.0)：NaN 载荷保留（不规范化）
        chk_cmp("fsgnjx_s_nan", 7, 0, 64'hFFFF_FFFF_7FC0_0000, 64'hFFFF_FFFF_BF80_0000, 64'hFFFF_FFFF_FFC0_0000, 5'b00000);
        chk_boxc("fsgnjx_s_nan");
        // fsgnj.s(NaN-boxing 违约, -1.0) ⇒ rs1 按 S canonical NaN
        chk_cmp("fsgnj_s_badbox", 5, 0, 64'h1234_5678_DEAD_BEEF, 64'hFFFF_FFFF_BF80_0000, 64'hFFFF_FFFF_FFC0_0000, 5'b00000);
        chk_boxc("fsgnj_s_badbox");
        // fsgnjn.s(NaN-boxing 违约, -1.0) ⇒ canonical NaN 再取反符号
        chk_cmp("fsgnjn_s_badbox", 6, 0, 64'h0000_0000_7FC0_0001, 64'hFFFF_FFFF_BF80_0000, 64'hFFFF_FFFF_7FC0_0000, 5'b00000);
        chk_boxc("fsgnjn_s_badbox");
        // fsgnj.d(1.0, -2.0) = -1.0
        chk_cmp("fsgnj_d_basic", 5, 1, 64'h3FF0_0000_0000_0000, 64'hC000_0000_0000_0000, 64'hBFF0_0000_0000_0000, 5'b00000);
        // fsgnjn.d(-2.0, -1.0) = +2.0
        chk_cmp("fsgnjn_d_basic", 6, 1, 64'hC000_0000_0000_0000, 64'hBFF0_0000_0000_0000, 64'h4000_0000_0000_0000, 5'b00000);
        // fsgnjx.d(-2.0, -1.0)：符号异或 ⇒ +2.0
        chk_cmp("fsgnjx_d_basic", 7, 1, 64'hC000_0000_0000_0000, 64'hBFF0_0000_0000_0000, 64'h4000_0000_0000_0000, 5'b00000);
        // fsgnjn.d(qNaN, +1.0)：不规范化 NaN ⇒ 取 rs1 位型、符号取反
        chk_cmp("fsgnjn_d_nan", 6, 1, 64'h7FF8_0000_0000_0000, 64'h3FF0_0000_0000_0000, 64'hFFF8_0000_0000_0000, 5'b00000);
        // fsgnjn.d(2^-1074, −1.0) = −2^-1074
        chk_cmp("fsgnjn_d_sub", 6, 1, 64'h0000_0000_0000_0001, 64'hBFF0_0000_0000_0000, 64'h0000_0000_0000_0001, 5'b00000);
        // fsgnjx.d(qNaN, −1.0)：载荷保留、符号异或 ⇒ −qNaN
        chk_cmp("fsgnjx_d_nan", 7, 1, 64'h7FF8_0000_0000_0000, 64'hBFF0_0000_0000_0000, 64'hFFF8_0000_0000_0000, 5'b00000);
        // fsgnjx.d(−∞, −1.0) = +∞
        chk_cmp("fsgnjx_d_inf", 7, 1, 64'hFFF0_0000_0000_0000, 64'hBFF0_0000_0000_0000, 64'h7FF0_0000_0000_0000, 5'b00000);
        // fsgnj.d(qNaN, -1.0)：载荷保留、符号取自 rs2
        chk_cmp("fsgnj_d_nan", 5, 1, 64'h7FF8_0000_0000_0000, 64'hBFF0_0000_0000_0000, 64'hFFF8_0000_0000_0000, 5'b00000);

        //==========================================================================
        // 4.2 fmin.s/d、fmax.s/d（IEEE 754-2019 minimumNumber/maximumNumber）
        //   · 一个 NaN ⇒ 返回另一数（不置 NV）；两个 NaN ⇒ canonical NaN（不置 NV）
        //   · 任一 sNaN ⇒ 置 NV（即使结果不是 NaN）
        //   · 仅本指令 −0.0 < +0.0 ⇒ min(+0,−0) = −0、max(+0,−0) = +0
        //==========================================================================
        // fmin.s(1.0, 2.0) = 1.0
        chk_cmp("fmin_s_basic", 8, 0, 64'hFFFF_FFFF_3F80_0000, 64'hFFFF_FFFF_4000_0000, 64'hFFFF_FFFF_3F80_0000, 5'b00000);
        chk_boxc("fmin_s_basic");
        // fmin.s(2.0, 1.0) = 1.0（与顺序无关）
        chk_cmp("fmin_s_swap", 8, 0, 64'hFFFF_FFFF_4000_0000, 64'hFFFF_FFFF_3F80_0000, 64'hFFFF_FFFF_3F80_0000, 5'b00000);
        chk_boxc("fmin_s_swap");
        // fmax.s(1.0, 2.0) = 2.0
        chk_cmp("fmax_s_basic", 9, 0, 64'hFFFF_FFFF_3F80_0000, 64'hFFFF_FFFF_4000_0000, 64'hFFFF_FFFF_4000_0000, 5'b00000);
        chk_boxc("fmax_s_basic");
        // fmin.s(+0,−0) = −0
        chk_cmp("fmin_s_pm0", 8, 0, 64'hFFFF_FFFF_0000_0000, 64'hFFFF_FFFF_8000_0000, 64'hFFFF_FFFF_8000_0000, 5'b00000);
        chk_boxc("fmin_s_pm0");
        // fmax.s(+0,−0) = +0
        chk_cmp("fmax_s_pm0", 9, 0, 64'hFFFF_FFFF_0000_0000, 64'hFFFF_FFFF_8000_0000, 64'hFFFF_FFFF_0000_0000, 5'b00000);
        chk_boxc("fmax_s_pm0");
        // fmin.s(qNaN, 1.0) = 1.0（不置 NV）
        chk_cmp("fmin_s_nan_a", 8, 0, 64'hFFFF_FFFF_7FC0_0000, 64'hFFFF_FFFF_3F80_0000, 64'hFFFF_FFFF_3F80_0000, 5'b00000);
        chk_boxc("fmin_s_nan_a");
        // fmax.s(1.0, qNaN) = 1.0（不置 NV）
        chk_cmp("fmax_s_nan_b", 9, 0, 64'hFFFF_FFFF_3F80_0000, 64'hFFFF_FFFF_7FC0_0000, 64'hFFFF_FFFF_3F80_0000, 5'b00000);
        chk_boxc("fmax_s_nan_b");
        // fmin.s(qNaN, −qNaN) = canonical NaN，**不置 NV**（规范口径）
        chk_cmp("fmin_s_both_nan", 8, 0, 64'hFFFF_FFFF_7FC0_0000, 64'hFFFF_FFFF_FFC0_0000, 64'hFFFF_FFFF_7FC0_0000, 5'b00000);
        chk_boxc("fmin_s_both_nan");
        // fmax.s(−2.0, NaN) 用另一侧 NaN：fmax.s(qNaN, −qNaN) = canonical NaN
        chk_cmp("fmax_s_both_nan", 9, 0, 64'hFFFF_FFFF_7FC0_0000, 64'hFFFF_FFFF_FFC0_0000, 64'hFFFF_FFFF_7FC0_0000, 5'b00000);
        chk_boxc("fmax_s_both_nan");
        // fmin.s(sNaN, 1.0) = 1.0 且 NV（sNaN 即使结果非 NaN 也置 NV）
        chk_cmp("fmin_s_snan_a", 8, 0, 64'hFFFF_FFFF_7F80_0001, 64'hFFFF_FFFF_3F80_0000, 64'hFFFF_FFFF_3F80_0000, 5'b10000);
        chk_boxc("fmin_s_snan_a");
        // fmax.s(1.0, sNaN) = 1.0 且 NV
        chk_cmp("fmax_s_snan_b", 9, 0, 64'hFFFF_FFFF_3F80_0000, 64'hFFFF_FFFF_7F80_0001, 64'hFFFF_FFFF_3F80_0000, 5'b10000);
        chk_boxc("fmax_s_snan_b");
        // fmin.s(sNaN, qNaN) = canonical NaN 且 NV
        chk_cmp("fmin_s_snan_qnan", 8, 0, 64'hFFFF_FFFF_7F80_0001, 64'hFFFF_FFFF_7FC0_0000, 64'hFFFF_FFFF_7FC0_0000, 5'b10000);
        chk_boxc("fmin_s_snan_qnan");
        // fmax.s(+∞, 1.0) = +∞；fmin.s 见下例
        chk_cmp("fmax_s_inf", 9, 0, 64'hFFFF_FFFF_7F80_0000, 64'hFFFF_FFFF_3F80_0000, 64'hFFFF_FFFF_7F80_0000, 5'b00000);
        chk_boxc("fmax_s_inf");
        // fmin.s(−∞, 1.0) = −∞
        chk_cmp("fmin_s_ninf", 8, 0, 64'hFFFF_FFFF_FF80_0000, 64'hFFFF_FFFF_3F80_0000, 64'hFFFF_FFFF_FF80_0000, 5'b00000);
        chk_boxc("fmin_s_ninf");
        // fmin.d(2.0, 1.0) = 1.0
        chk_cmp("fmin_d_basic", 8, 1, 64'h4000_0000_0000_0000, 64'h3FF0_0000_0000_0000, 64'h3FF0_0000_0000_0000, 5'b00000);
        // fmax.d(2.0, 1.0) = 2.0
        chk_cmp("fmax_d_basic", 9, 1, 64'h4000_0000_0000_0000, 64'h3FF0_0000_0000_0000, 64'h4000_0000_0000_0000, 5'b00000);
        // fmin.d(+0,−0) = −0
        chk_cmp("fmin_d_pm0", 8, 1, 64'h0000_0000_0000_0000, 64'h8000_0000_0000_0000, 64'h8000_0000_0000_0000, 5'b00000);
        // fmax.d(+0,−0) = +0
        chk_cmp("fmax_d_pm0", 9, 1, 64'h0000_0000_0000_0000, 64'h8000_0000_0000_0000, 64'h0000_0000_0000_0000, 5'b00000);
        // fmin.d(qNaN, 1.0) = 1.0
        chk_cmp("fmin_d_nan", 8, 1, 64'h7FF8_0000_0000_0000, 64'h3FF0_0000_0000_0000, 64'h3FF0_0000_0000_0000, 5'b00000);
        // fmax.d(sNaN, 1.0) = 1.0 且 NV
        chk_cmp("fmax_d_snan", 9, 1, 64'h7FF0_0000_0000_0001, 64'h3FF0_0000_0000_0000, 64'h3FF0_0000_0000_0000, 5'b10000);
        // fmax.d(qNaN, −qNaN) = canonical D NaN，不置 NV
        chk_cmp("fmax_d_both_nan", 9, 1, 64'h7FF8_0000_0000_0000, 64'hFFF8_0000_0000_0000, 64'h7FF8_0000_0000_0000, 5'b00000);
        // fmin.d(−∞, +∞) = −∞
        chk_cmp("fmin_d_ninf", 8, 1, 64'hFFF0_0000_0000_0000, 64'h7FF0_0000_0000_0000, 64'hFFF0_0000_0000_0000, 5'b00000);

        //==========================================================================
        // 4.3 feq.s/d（quiet：仅 sNaN 置 NV）、flt.s/d、fle.s/d（signaling：任一 NaN 置 NV）
        //   三者任一操作数为 NaN ⇒ 结果 0；+0 == −0 为真；flt(+0,−0) = 0
        //==========================================================================
        // feq.s(2.0, 2.0) = 1
        chk_cmp("feq_s_eq", 10, 0, 64'hFFFF_FFFF_4000_0000, 64'hFFFF_FFFF_4000_0000, 64'h0000_0000_0000_0001, 5'b00000);
        // feq.s(1.0, 2.0) = 0
        chk_cmp("feq_s_ne", 10, 0, 64'hFFFF_FFFF_3F80_0000, 64'hFFFF_FFFF_4000_0000, 64'h0000_0000_0000_0000, 5'b00000);
        // feq.s(+0, −0) = 1（数值相等）
        chk_cmp("feq_s_pm0", 10, 0, 64'hFFFF_FFFF_0000_0000, 64'hFFFF_FFFF_8000_0000, 64'h0000_0000_0000_0001, 5'b00000);
        // feq.s(qNaN, 1.0) = 0 且**不置 NV**（quiet 比较）
        chk_cmp("feq_s_qnan", 10, 0, 64'hFFFF_FFFF_7FC0_0000, 64'hFFFF_FFFF_3F80_0000, 64'h0000_0000_0000_0000, 5'b00000);
        // feq.s(sNaN, 1.0) = 0 且 NV
        chk_cmp("feq_s_snan", 10, 0, 64'hFFFF_FFFF_7F80_0001, 64'hFFFF_FFFF_3F80_0000, 64'h0000_0000_0000_0000, 5'b10000);
        // feq.s(NaN-boxing 违约, 1.0) = 0 且 NV（违约 ⇒ canonical qNaN ⇒ quiet 比较不置 NV）
        chk_cmp("feq_s_badbox", 10, 0, 64'hDEAD_BEEF_0000_0001, 64'hFFFF_FFFF_3F80_0000, 64'h0000_0000_0000_0000, 5'b00000);
        // flt.s(1.0, 2.0) = 1
        chk_cmp("flt_s_lt", 11, 0, 64'hFFFF_FFFF_3F80_0000, 64'hFFFF_FFFF_4000_0000, 64'h0000_0000_0000_0001, 5'b00000);
        // flt.s(2.0, 1.0) = 0
        chk_cmp("flt_s_gt", 11, 0, 64'hFFFF_FFFF_4000_0000, 64'hFFFF_FFFF_3F80_0000, 64'h0000_0000_0000_0000, 5'b00000);
        // flt.s(+0, −0) = 0（±0 数值相等）
        chk_cmp("flt_s_pm0", 11, 0, 64'hFFFF_FFFF_0000_0000, 64'hFFFF_FFFF_8000_0000, 64'h0000_0000_0000_0000, 5'b00000);
        // flt.s(−0, +0) = 0
        chk_cmp("flt_s_pm0_rev", 11, 0, 64'hFFFF_FFFF_8000_0000, 64'hFFFF_FFFF_0000_0000, 64'h0000_0000_0000_0000, 5'b00000);
        // flt.s(qNaN, 1.0) = 0 且 NV（signaling 比较：qNaN 也置 NV）
        chk_cmp("flt_s_qnan", 11, 0, 64'hFFFF_FFFF_7FC0_0000, 64'hFFFF_FFFF_3F80_0000, 64'h0000_0000_0000_0000, 5'b10000);
        // flt.s(1.0, sNaN) = 0 且 NV
        chk_cmp("flt_s_snan_b", 11, 0, 64'hFFFF_FFFF_3F80_0000, 64'hFFFF_FFFF_7F80_0001, 64'h0000_0000_0000_0000, 5'b10000);
        // flt.s(−∞, +∞) = 1
        chk_cmp("flt_s_ninf", 11, 0, 64'hFFFF_FFFF_FF80_0000, 64'hFFFF_FFFF_7F80_0000, 64'h0000_0000_0000_0001, 5'b00000);
        // fle.s(1.0, 2.0) = 1
        chk_cmp("fle_s_le", 12, 0, 64'hFFFF_FFFF_3F80_0000, 64'hFFFF_FFFF_4000_0000, 64'h0000_0000_0000_0001, 5'b00000);
        // fle.s(2.0, 1.0) = 0
        chk_cmp("fle_s_gt", 12, 0, 64'hFFFF_FFFF_4000_0000, 64'hFFFF_FFFF_3F80_0000, 64'h0000_0000_0000_0000, 5'b00000);
        // fle.s(+0, −0) = 1
        chk_cmp("fle_s_pm0", 12, 0, 64'hFFFF_FFFF_0000_0000, 64'hFFFF_FFFF_8000_0000, 64'h0000_0000_0000_0001, 5'b00000);
        // fle.s(+∞, +∞) = 1
        chk_cmp("fle_s_inf_eq", 12, 0, 64'hFFFF_FFFF_7F80_0000, 64'hFFFF_FFFF_7F80_0000, 64'h0000_0000_0000_0001, 5'b00000);
        // fle.s(1.0, qNaN) = 0 且 NV
        chk_cmp("fle_s_nan", 12, 0, 64'hFFFF_FFFF_3F80_0000, 64'hFFFF_FFFF_7FC0_0000, 64'h0000_0000_0000_0000, 5'b10000);
        // feq.d(2.0, 2.0) = 1
        chk_cmp("feq_d_eq", 10, 1, 64'h4000_0000_0000_0000, 64'h4000_0000_0000_0000, 64'h0000_0000_0000_0001, 5'b00000);
        // feq.d(+0, −0) = 1
        chk_cmp("feq_d_pm0", 10, 1, 64'h0000_0000_0000_0000, 64'h8000_0000_0000_0000, 64'h0000_0000_0000_0001, 5'b00000);
        // feq.d(sNaN, 1.0) = 0 且 NV
        chk_cmp("feq_d_snan", 10, 1, 64'h7FF0_0000_0000_0001, 64'h3FF0_0000_0000_0000, 64'h0000_0000_0000_0000, 5'b10000);
        // flt.d(1.0, 2.0) = 1
        chk_cmp("flt_d_lt", 11, 1, 64'h3FF0_0000_0000_0000, 64'h4000_0000_0000_0000, 64'h0000_0000_0000_0001, 5'b00000);
        // flt.d(qNaN, 1.0) = 0 且 NV
        chk_cmp("flt_d_nan", 11, 1, 64'h7FF8_0000_0000_0000, 64'h3FF0_0000_0000_0000, 64'h0000_0000_0000_0000, 5'b10000);
        // fle.d(1.0, 2.0) = 1
        chk_cmp("fle_d_le", 12, 1, 64'h3FF0_0000_0000_0000, 64'h4000_0000_0000_0000, 64'h0000_0000_0000_0001, 5'b00000);
        // fle.d(+0, −0) = 1
        chk_cmp("fle_d_pm0", 12, 1, 64'h0000_0000_0000_0000, 64'h8000_0000_0000_0000, 64'h0000_0000_0000_0001, 5'b00000);
        // fle.d(1.0, sNaN) = 0 且 NV
        chk_cmp("fle_d_snan", 12, 1, 64'h3FF0_0000_0000_0000, 64'h7FF0_0000_0000_0001, 64'h0000_0000_0000_0000, 5'b10000);
        // fle.d(+∞, +∞) = 1
        chk_cmp("fle_d_inf", 12, 1, 64'h7FF0_0000_0000_0000, 64'h7FF0_0000_0000_0000, 64'h0000_0000_0000_0001, 5'b00000);

        //==========================================================================
        // 4.4 fclass.s/d：10 类全枚举（bit0 −∞ / bit1 −normal / bit2 −subnormal /
        //     bit3 −0 / bit4 +0 / bit5 +subnormal / bit6 +normal / bit7 +∞ /
        //     bit8 sNaN / bit9 qNaN；恰一位为 1、不置 fflags）
        //==========================================================================
        // fclass.s(−∞) ⇒ bit0 = 1
        chk_cmp("cls_s_ninf", 13, 0, 64'hFFFF_FFFF_FF80_0000, 64'hFFFF_FFFF_3F80_0000, 64'h0000_0000_0000_0001, 5'b00000);
        // fclass.s(−normal) ⇒ bit1 = 1
        chk_cmp("cls_s_neg_norm", 13, 0, 64'hFFFF_FFFF_C000_0000, 64'hFFFF_FFFF_3F80_0000, 64'h0000_0000_0000_0002, 5'b00000);
        // fclass.s(−subnormal) ⇒ bit2 = 1
        chk_cmp("cls_s_neg_sub", 13, 0, 64'hFFFF_FFFF_8000_0001, 64'hFFFF_FFFF_3F80_0000, 64'h0000_0000_0000_0004, 5'b00000);
        // fclass.s(−0) ⇒ bit3 = 1
        chk_cmp("cls_s_neg_zero", 13, 0, 64'hFFFF_FFFF_8000_0000, 64'hFFFF_FFFF_3F80_0000, 64'h0000_0000_0000_0008, 5'b00000);
        // fclass.s(+0) ⇒ bit4 = 1
        chk_cmp("cls_s_pos_zero", 13, 0, 64'hFFFF_FFFF_0000_0000, 64'hFFFF_FFFF_3F80_0000, 64'h0000_0000_0000_0010, 5'b00000);
        // fclass.s(+subnormal) ⇒ bit5 = 1
        chk_cmp("cls_s_pos_sub", 13, 0, 64'hFFFF_FFFF_0000_0001, 64'hFFFF_FFFF_3F80_0000, 64'h0000_0000_0000_0020, 5'b00000);
        // fclass.s(+normal) ⇒ bit6 = 1
        chk_cmp("cls_s_pos_norm", 13, 0, 64'hFFFF_FFFF_3F80_0000, 64'hFFFF_FFFF_3F80_0000, 64'h0000_0000_0000_0040, 5'b00000);
        // fclass.s(+∞) ⇒ bit7 = 1
        chk_cmp("cls_s_pos_inf", 13, 0, 64'hFFFF_FFFF_7F80_0000, 64'hFFFF_FFFF_3F80_0000, 64'h0000_0000_0000_0080, 5'b00000);
        // fclass.s(sNaN) ⇒ bit8 = 1
        chk_cmp("cls_s_snan", 13, 0, 64'hFFFF_FFFF_7F80_0001, 64'hFFFF_FFFF_3F80_0000, 64'h0000_0000_0000_0100, 5'b00000);
        // fclass.s(qNaN) ⇒ bit9 = 1
        chk_cmp("cls_s_qnan", 13, 0, 64'hFFFF_FFFF_7FC0_0000, 64'hFFFF_FFFF_3F80_0000, 64'h0000_0000_0000_0200, 5'b00000);
        // fclass.d(−∞)
        chk_cmp("cls_d_ninf", 13, 1, 64'hFFF0_0000_0000_0000, 64'h3FF0_0000_0000_0000, 64'h0000_0000_0000_0001, 5'b00000);
        // fclass.d(−normal)
        chk_cmp("cls_d_neg_norm", 13, 1, 64'hBFF0_0000_0000_0000, 64'h3FF0_0000_0000_0000, 64'h0000_0000_0000_0002, 5'b00000);
        // fclass.d(−subnormal)
        chk_cmp("cls_d_neg_sub", 13, 1, 64'h8000_0000_0000_0001, 64'h3FF0_0000_0000_0000, 64'h0000_0000_0000_0004, 5'b00000);
        // fclass.d(−0)
        chk_cmp("cls_d_neg_zero", 13, 1, 64'h8000_0000_0000_0000, 64'h3FF0_0000_0000_0000, 64'h0000_0000_0000_0008, 5'b00000);
        // fclass.d(+0)
        chk_cmp("cls_d_pos_zero", 13, 1, 64'h0000_0000_0000_0000, 64'h3FF0_0000_0000_0000, 64'h0000_0000_0000_0010, 5'b00000);
        // fclass.d(+subnormal)
        chk_cmp("cls_d_pos_sub", 13, 1, 64'h0000_0000_0000_0001, 64'h3FF0_0000_0000_0000, 64'h0000_0000_0000_0020, 5'b00000);
        // fclass.d(+normal)
        chk_cmp("cls_d_pos_norm", 13, 1, 64'h4000_0000_0000_0000, 64'h3FF0_0000_0000_0000, 64'h0000_0000_0000_0040, 5'b00000);
        // fclass.d(+∞)
        chk_cmp("cls_d_pos_inf", 13, 1, 64'h7FF0_0000_0000_0000, 64'h3FF0_0000_0000_0000, 64'h0000_0000_0000_0080, 5'b00000);
        // fclass.d(sNaN)
        chk_cmp("cls_d_snan", 13, 1, 64'h7FF0_0000_0000_0001, 64'h3FF0_0000_0000_0000, 64'h0000_0000_0000_0100, 5'b00000);
        // fclass.d(qNaN)
        chk_cmp("cls_d_qnan", 13, 1, 64'h7FF8_0000_0000_0000, 64'h3FF0_0000_0000_0000, 64'h0000_0000_0000_0200, 5'b00000);
        // NaN-boxing 违约 ⇒ 按 canonical qNaN 分类（bit9）
        // fclass.s(NaN-boxing 违约) = 1<<9
        chk_cmp("cls_s_badbox", 13, 0, 64'h1122_3344_5566_7788, 64'hFFFF_FFFF_3F80_0000, 64'h0000_0000_0000_0200, 5'b00000);

        //==========================================================================
        // 4.5 fcvt.w.s / fcvt.wu.s（按 rm 取整；越界/±∞/NaN ⇒ NV + 饱和；
        //     有符号取整不精确 ⇒ NX；置 NV 时不置 NX）
        //==========================================================================
        // fcvt.w.s(1.5, RNE) = 2 且 NX
        chk_cvt("w_s_1p5_rne", 16, 0, 3'b000, 64'hFFFF_FFFF_3FC0_0000, 3'b000, 64'h0000_0000_0000_0002, 5'b00001);
        // fcvt.w.s(1.5, RTZ) = 1 且 NX
        chk_cvt("w_s_1p5_rtz", 16, 0, 3'b001, 64'hFFFF_FFFF_3FC0_0000, 3'b000, 64'h0000_0000_0000_0001, 5'b00001);
        // fcvt.w.s(1.5, RUP) = 2 且 NX
        chk_cvt("w_s_1p5_rup", 16, 0, 3'b011, 64'hFFFF_FFFF_3FC0_0000, 3'b000, 64'h0000_0000_0000_0002, 5'b00001);
        // fcvt.w.s(−1.5, RDN) = −2 且 NX
        chk_cvt("w_s_neg1p5_rdn", 16, 0, 3'b010, 64'hFFFF_FFFF_BFC0_0000, 3'b000, 64'h0000_0000_FFFF_FFFE, 5'b00001);
        // fcvt.w.s(−1.5, RNE) = −2 且 NX
        chk_cvt("w_s_neg1p5_rne", 16, 0, 3'b000, 64'hFFFF_FFFF_BFC0_0000, 3'b000, 64'h0000_0000_FFFF_FFFE, 5'b00001);
        // fcvt.w.s(0.5, RNE) = 0 且 NX（不置 NV）
        chk_cvt("w_s_half_rne", 16, 0, 3'b000, 64'hFFFF_FFFF_3F00_0000, 3'b000, 64'h0000_0000_0000_0000, 5'b00001);
        // fcvt.w.s(2^31) = 2^31−1 且 NV（最小越界正数）
        chk_cvt("w_s_2p31", 16, 0, 3'b000, 64'hFFFF_FFFF_4F00_0000, 3'b000, 64'h0000_0000_7FFF_FFFF, 5'b10000);
        // fcvt.w.s(−2^31) = −2^31 且**不置 flags**（最小有效输入）
        chk_cvt("w_s_neg2p31", 16, 0, 3'b000, 64'hFFFF_FFFF_CF00_0000, 3'b000, 64'h0000_0000_8000_0000, 5'b00000);
        // fcvt.w.s(+∞) = 2^31−1 且 NV
        chk_cvt("w_s_inf", 16, 0, 3'b000, 64'hFFFF_FFFF_7F80_0000, 3'b000, 64'h0000_0000_7FFF_FFFF, 5'b10000);
        // fcvt.w.s(−∞) = −2^31 且 NV
        chk_cvt("w_s_ninf", 16, 0, 3'b000, 64'hFFFF_FFFF_FF80_0000, 3'b000, 64'h0000_0000_8000_0000, 5'b10000);
        // fcvt.w.s(qNaN) = 2^31−1 且 NV
        chk_cvt("w_s_qnan", 16, 0, 3'b000, 64'hFFFF_FFFF_7FC0_0000, 3'b000, 64'h0000_0000_7FFF_FFFF, 5'b10000);
        // fcvt.w.s(−qNaN) = 2^31−1 且 NV（NaN 恒给正侧饱和值）
        chk_cvt("w_s_negnan", 16, 0, 3'b000, 64'hFFFF_FFFF_FFC0_0000, 3'b000, 64'h0000_0000_7FFF_FFFF, 5'b10000);
        // fcvt.w.s(sNaN) = 2^31−1 且 NV
        chk_cvt("w_s_snan", 16, 0, 3'b000, 64'hFFFF_FFFF_7F80_0001, 3'b000, 64'h0000_0000_7FFF_FFFF, 5'b10000);
        // fcvt.w.s(2^−149) = 0 且 NX
        chk_cvt("w_s_min_sub", 16, 0, 3'b000, 64'hFFFF_FFFF_0000_0001, 3'b000, 64'h0000_0000_0000_0000, 5'b00001);
        // fcvt.w.s(NaN-boxing 违约) ⇒ canonical NaN ⇒ 2^31−1 且 NV
        chk_cvt("w_s_badbox", 16, 0, 3'b000, 64'hAAAA_BBBB_0000_0000, 3'b000, 64'h0000_0000_7FFF_FFFF, 5'b10000);
        // fcvt.wu.s(−0.4, RTZ) = 0 且 NX（舍入后为 0 ⇒ 在域内）
        chk_cvt("wu_s_neg0p4_rtz", 17, 0, 3'b001, 64'hFFFF_FFFF_BECC_CCCD, 3'b000, 64'h0000_0000_0000_0000, 5'b00001);
        // fcvt.wu.s(−0.4, RDN) = 0 且 NV（舍入到 −1 ⇒ 越界）
        chk_cvt("wu_s_neg0p4_rdn", 17, 0, 3'b010, 64'hFFFF_FFFF_BECC_CCCD, 3'b000, 64'h0000_0000_0000_0000, 5'b10000);
        // fcvt.wu.s(−1.0) = 0 且 NV
        chk_cvt("wu_s_neg1", 17, 0, 3'b000, 64'hFFFF_FFFF_BF80_0000, 3'b000, 64'h0000_0000_0000_0000, 5'b10000);
        // fcvt.wu.s(2^32) = 2^32−1 且 NV
        chk_cvt("wu_s_2p32", 17, 0, 3'b000, 64'hFFFF_FFFF_4F80_0000, 3'b000, 64'h0000_0000_FFFF_FFFF, 5'b10000);
        // fcvt.wu.s(4294967040) 在域内（无 NV）
        chk_cvt("wu_s_max_in", 17, 0, 3'b000, 64'hFFFF_FFFF_4F7F_FFFF, 3'b000, 64'h0000_0000_FFFF_FF00, 5'b00000);
        // fcvt.wu.s(1.5, RTZ) = 1 且 NX
        chk_cvt("wu_s_1p5", 17, 0, 3'b001, 64'hFFFF_FFFF_3FC0_0000, 3'b000, 64'h0000_0000_0000_0001, 5'b00001);
        // fcvt.wu.s(−∞) = 0 且 NV
        chk_cvt("wu_s_ninf", 17, 0, 3'b000, 64'hFFFF_FFFF_FF80_0000, 3'b000, 64'h0000_0000_0000_0000, 5'b10000);
        // fcvt.wu.s(qNaN) = 2^32−1 且 NV
        chk_cvt("wu_s_qnan", 17, 0, 3'b000, 64'hFFFF_FFFF_7FC0_0000, 3'b000, 64'h0000_0000_FFFF_FFFF, 5'b10000);

        //==========================================================================
        // 4.6 fcvt.w.d / fcvt.wu.d
        //==========================================================================
        // fcvt.w.d(1.5, RNE) = 2 且 NX
        chk_cvt("w_d_1p5_rne", 20, 1, 3'b000, 64'h3FF8_0000_0000_0000, 3'b000, 64'h0000_0000_0000_0002, 5'b00001);
        // fcvt.w.d(1.5, RTZ) = 1 且 NX
        chk_cvt("w_d_1p5_rtz", 20, 1, 3'b001, 64'h3FF8_0000_0000_0000, 3'b000, 64'h0000_0000_0000_0001, 5'b00001);
        // fcvt.w.d(2^31) = 2^31−1 且 NV
        chk_cvt("w_d_2p31", 20, 1, 3'b000, 64'h41E0_0000_0000_0000, 3'b000, 64'h0000_0000_7FFF_FFFF, 5'b10000);
        // fcvt.w.d(2^31−1) = 2^31−1 且不置 flags
        chk_cvt("w_d_2p31m1", 20, 1, 3'b000, 64'h41DF_FFFF_FFFF_FFFF, 3'b000, 64'h0000_0000_7FFF_FFFF, 5'b10000);
        // fcvt.w.d(−2^31) = −2^31 且不置 flags
        chk_cvt("w_d_neg2p31", 20, 1, 3'b000, 64'hC1E0_0000_0000_0000, 3'b000, 64'h0000_0000_8000_0000, 5'b00000);
        // fcvt.w.d(qNaN) = 2^31−1 且 NV
        chk_cvt("w_d_qnan", 20, 1, 3'b000, 64'h7FF8_0000_0000_0000, 3'b000, 64'h0000_0000_7FFF_FFFF, 5'b10000);
        // fcvt.w.d(sNaN) = 2^31−1 且 NV
        chk_cvt("w_d_snan", 20, 1, 3'b000, 64'h7FF0_0000_0000_0001, 3'b000, 64'h0000_0000_7FFF_FFFF, 5'b10000);
        // fcvt.w.d(−∞) = −2^31 且 NV
        chk_cvt("w_d_ninf", 20, 1, 3'b000, 64'hFFF0_0000_0000_0000, 3'b000, 64'h0000_0000_8000_0000, 5'b10000);
        // fcvt.w.d(2^−1074) = 0 且 NX
        chk_cvt("w_d_minden", 20, 1, 3'b000, 64'h0000_0000_0000_0001, 3'b000, 64'h0000_0000_0000_0000, 5'b00001);
        // fcvt.w.d(−2^31 − 1.0) = −2^31 且 NV
        chk_cvt("w_d_min_32bit", 20, 1, 3'b000, 64'hC1E0_0000_0020_0000, 3'b000, 64'h0000_0000_8000_0000, 5'b10000);
        // fcvt.wu.d(1.5, RTZ) = 1 且 NX
        chk_cvt("wu_d_1p5_rtz", 21, 1, 3'b001, 64'h3FF8_0000_0000_0000, 3'b000, 64'h0000_0000_0000_0001, 5'b00001);
        // fcvt.wu.d(2^32) = 2^32−1 且 NV
        chk_cvt("wu_d_2p32", 21, 1, 3'b000, 64'h41F0_0000_0000_0000, 3'b000, 64'h0000_0000_FFFF_FFFF, 5'b10000);
        // fcvt.wu.d(2^32−1) = 2^32−1 且不置 flags
        chk_cvt("wu_d_max_in", 21, 1, 3'b000, 64'h41EF_FFFF_FFE0_0000, 3'b000, 64'h0000_0000_FFFF_FFFF, 5'b00000);
        // fcvt.wu.d(−1.0) = 0 且 NV
        chk_cvt("wu_d_neg1", 21, 1, 3'b000, 64'hBFF0_0000_0000_0000, 3'b000, 64'h0000_0000_0000_0000, 5'b10000);
        // fcvt.wu.d(qNaN) = 2^32−1 且 NV
        chk_cvt("wu_d_qnan", 21, 1, 3'b000, 64'h7FF8_0000_0000_0000, 3'b000, 64'h0000_0000_FFFF_FFFF, 5'b10000);
        // fcvt.wu.d(−0.25, RTZ) = 0 且 NX
        chk_cvt("wu_d_neg0p25_rtz", 21, 1, 3'b001, 64'hBFD0_0000_0000_0000, 3'b000, 64'h0000_0000_0000_0000, 5'b00001);

        //==========================================================================
        // 4.7 fcvt.s.w / fcvt.s.wu（只有 NX）、fcvt.d.w / fcvt.d.wu（恒精确、0 flags）
        //==========================================================================
        // fcvt.s.w(1) = 1.0（NaN-boxed）
        chk_cvt("s_w_one", 18, 0, 3'b000, 64'h0000_0000_0000_0001, 3'b000, 64'hFFFF_FFFF_3F80_0000, 5'b00000);
        chk_box("s_w_one_box");
        // fcvt.s.w(−1) = −1.0
        chk_cvt("s_w_neg1", 18, 0, 3'b000, 64'h0000_0000_FFFF_FFFF, 3'b000, 64'hFFFF_FFFF_BF80_0000, 5'b00000);
        chk_box("s_w_neg1_box");
        // fcvt.s.w(0) = +0.0，不置任何 flags
        chk_cvt("s_w_zero", 18, 0, 3'b000, 64'h0000_0000_0000_0000, 3'b000, 64'hFFFF_FFFF_0000_0000, 5'b00000);
        chk_box("s_w_zero_box");
        // fcvt.s.w(2^31−1) = 2^31 且 NX（RNE 舍入）
        chk_cvt("s_w_maxint", 18, 0, 3'b000, 64'h0000_0000_7FFF_FFFF, 3'b000, 64'hFFFF_FFFF_4F00_0000, 5'b00001);
        chk_box("s_w_maxint_box");
        // fcvt.s.w(−2^31) = −2^31 精确、不置 flags
        chk_cvt("s_w_minint", 18, 0, 3'b000, 64'h0000_0000_8000_0000, 3'b000, 64'hFFFF_FFFF_CF00_0000, 5'b00000);
        chk_box("s_w_minint_box");
        // fcvt.s.w(2^24+1, RNE) = 2^24 且 NX
        chk_cvt("s_w_2p24p1_rne", 18, 0, 3'b000, 64'h0000_0000_0100_0001, 3'b000, 64'hFFFF_FFFF_4B80_0000, 5'b00001);
        chk_box("s_w_2p24p1_rne_box");
        // fcvt.s.w(2^24+1, RUP) = 2^24+2 且 NX
        chk_cvt("s_w_2p24p1_rup", 18, 0, 3'b011, 64'h0000_0000_0100_0001, 3'b000, 64'hFFFF_FFFF_4B80_0001, 5'b00001);
        chk_box("s_w_2p24p1_rup_box");
        // fcvt.s.wu(2^32−1) = 2^32 且 NX
        chk_cvt("s_wu_max", 19, 0, 3'b000, 64'h0000_0000_FFFF_FFFF, 3'b000, 64'hFFFF_FFFF_4F80_0000, 5'b00001);
        chk_box("s_wu_max_box");
        // fcvt.s.wu(1) = 1.0
        chk_cvt("s_wu_one", 19, 0, 3'b000, 64'h0000_0000_0000_0001, 3'b000, 64'hFFFF_FFFF_3F80_0000, 5'b00000);
        chk_box("s_wu_one_box");
        // fcvt.d.w(1) = 1.0 精确
        chk_cvt("d_w_one", 22, 1, 3'b000, 64'h0000_0000_0000_0001, 3'b000, 64'h3FF0_0000_0000_0000, 5'b00000);
        // fcvt.d.w(−1) = −1.0 精确
        chk_cvt("d_w_neg1", 22, 1, 3'b000, 64'h0000_0000_FFFF_FFFF, 3'b000, 64'hBFF0_0000_0000_0000, 5'b00000);
        // fcvt.d.w(−2^31) = −2^31 精确
        chk_cvt("d_w_minint", 22, 1, 3'b000, 64'h0000_0000_8000_0000, 3'b000, 64'hC1E0_0000_0000_0000, 5'b00000);
        // fcvt.d.w(2^31−1) 精确（D 精度 53 bit ⇒ 无 NX）
        chk_cvt("d_w_maxint", 22, 1, 3'b000, 64'h0000_0000_7FFF_FFFF, 3'b000, 64'h41DF_FFFF_FFC0_0000, 5'b00000);
        // fcvt.d.wu(2^32−1) 精确
        chk_cvt("d_wu_max", 23, 1, 3'b000, 64'h0000_0000_FFFF_FFFF, 3'b000, 64'h41EF_FFFF_FFE0_0000, 5'b00000);
        // fcvt.d.wu 与舍入模式无关（同一值 RTZ/RNE 结果同）
        chk_cvt("d_wu_rtz_cmp", 23, 1, 3'b001, 64'h0000_0000_8000_0001, 3'b000, 64'h41E0_0000_0020_0000, 5'b00000);

        //==========================================================================
        // 4.8 fcvt.d.s（不舍入、只可能 NV）与 fcvt.s.d（按 rm 舍入，可 OF/UF/NX）
        //==========================================================================
        // fcvt.d.s(1.0) = 1.0，0 flags
        chk_cvt("d_s_one", 25, 1, 3'b000, 64'hFFFF_FFFF_3F80_0000, 3'b000, 64'h3FF0_0000_0000_0000, 5'b00000);
        // fcvt.d.s(−2.0) = −2.0
        chk_cvt("d_s_neg2", 25, 1, 3'b000, 64'hFFFF_FFFF_C000_0000, 3'b000, 64'hC000_0000_0000_0000, 5'b00000);
        // fcvt.d.s(qNaN) = D canonical NaN，不置 NV
        chk_cvt("d_s_qnan", 25, 1, 3'b000, 64'hFFFF_FFFF_7FC0_0000, 3'b000, 64'h7FF8_0000_0000_0000, 5'b00000);
        // fcvt.d.s(sNaN) = D canonical NaN 且 NV
        chk_cvt("d_s_snan", 25, 1, 3'b000, 64'hFFFF_FFFF_7F80_0001, 3'b000, 64'h7FF8_0000_0000_0000, 5'b10000);
        // fcvt.d.s(NaN-boxing 违约) ⇒ canonical NaN ⇒ canonical D NaN，0 flags
        chk_cvt("d_s_badbox", 25, 1, 3'b000, 64'h5A5A_5A5A_3F80_0000, 3'b000, 64'h7FF8_0000_0000_0000, 5'b00000);
        // fcvt.d.s(+∞) = +∞
        chk_cvt("d_s_inf", 25, 1, 3'b000, 64'hFFFF_FFFF_7F80_0000, 3'b000, 64'h7FF0_0000_0000_0000, 5'b00000);
        // fcvt.d.s(2^−149) = 2^−149（S 最小亚正规，D 内仍精确）
        chk_cvt("d_s_sub", 25, 1, 3'b000, 64'hFFFF_FFFF_0000_0001, 3'b000, 64'h36A0_0000_0000_0000, 5'b00000);
        // fcvt.d.s(0x007FFFFF)
        chk_cvt("d_s_maxsub_s", 25, 1, 3'b000, 64'hFFFF_FFFF_007F_FFFF, 3'b000, 64'h380F_FFFF_C000_0000, 5'b00000);
        // fcvt.d.s(−0.0) = −0.0
        chk_cvt("d_s_neg0", 25, 1, 3'b000, 64'hFFFF_FFFF_8000_0000, 3'b000, 64'h8000_0000_0000_0000, 5'b00000);
        // fcvt.s.d(1.0) = 1.0（NaN-boxed）
        chk_cvt("s_d_one", 24, 0, 3'b000, 64'h3FF0_0000_0000_0000, 3'b000, 64'hFFFF_FFFF_3F80_0000, 5'b00000);
        chk_box("s_d_one_box");
        // fcvt.s.d(2^31−1) = 2^31 且 NX
        chk_cvt("s_d_2p31m1", 24, 0, 3'b000, 64'h41DF_FFFF_FFFF_FFFF, 3'b000, 64'hFFFF_FFFF_4F00_0000, 5'b00001);
        chk_box("s_d_2p31m1_box");
        // fcvt.s.d(2^31−1, RTZ) = 2^31−2 且 NX
        chk_cvt("s_d_rtz", 24, 0, 3'b001, 64'h41DF_FFFF_FFFF_FFFF, 3'b000, 64'hFFFF_FFFF_4EFF_FFFF, 5'b00001);
        chk_box("s_d_rtz_box");
        // fcvt.s.d(+0) = +0 且**不置任何 flags**（精确转换）
        chk_cvt("s_d_pos_zero", 24, 0, 3'b000, 64'h0000_0000_0000_0000, 3'b000, 64'hFFFF_FFFF_0000_0000, 5'b00000);
        chk_box("s_d_pos_zero_box");
        // fcvt.s.d(−0) = −0 且不置 flags
        chk_cvt("s_d_neg_zero", 24, 0, 3'b000, 64'h8000_0000_0000_0000, 3'b000, 64'hFFFF_FFFF_8000_0000, 5'b00000);
        chk_box("s_d_neg_zero_box");
        // fcvt.s.d(+0, RDN) = +0 且不置 flags（±0 不得因 rm 变成亚正规）
        chk_cvt("s_d_pos_zero_rdn", 24, 0, 3'b010, 64'h0000_0000_0000_0000, 3'b000, 64'hFFFF_FFFF_0000_0000, 5'b00000);
        chk_box("s_d_pos_zero_rdn_box");
        // fcvt.s.d(2^−1074) = +0 且 UF|NX（远低于 S 亚正规下限）
        chk_cvt("s_d_minden", 24, 0, 3'b000, 64'h0000_0000_0000_0001, 3'b000, 64'hFFFF_FFFF_0000_0000, 5'b00011);
        chk_box("s_d_minden_box");
        // fcvt.s.d(2^−1074, RUP) = 2^−149 且 UF|NX
        chk_cvt("s_d_minden_rup", 24, 0, 3'b011, 64'h0000_0000_0000_0001, 3'b000, 64'hFFFF_FFFF_0000_0001, 5'b00011);
        chk_box("s_d_minden_rup_box");
        // fcvt.s.d(−2^−1074, RDN) = −2^−149 且 UF|NX
        chk_cvt("s_d_minden_rdn_neg", 24, 0, 3'b010, 64'h8000_0000_0000_0001, 3'b000, 64'hFFFF_FFFF_8000_0001, 5'b00011);
        chk_box("s_d_minden_rdn_neg_box");
        // fcvt.s.d(2^−540)（走舍入原语通路的极小值）= +0 且 UF|NX
        chk_cvt("s_d_emin_bound_lo", 24, 0, 3'b000, 64'h1E30_0000_0000_0000, 3'b000, 64'hFFFF_FFFF_0000_0000, 5'b00011);
        chk_box("s_d_emin_bound_lo_box");
        // fcvt.s.d(2^−560)（走极小数快速通路的极小值）= +0 且 UF|NX
        chk_cvt("s_d_emin_bound_hi", 24, 0, 3'b000, 64'h1CF0_0000_0000_0000, 3'b000, 64'hFFFF_FFFF_0000_0000, 5'b00011);
        chk_box("s_d_emin_bound_hi_box");
        // fcvt.s.d(2^−149) = 2^−149（D→S 亚正规边界，精确）
        chk_cvt("s_d_sub_s", 24, 0, 3'b000, 64'h36A0_0000_0000_0000, 3'b000, 64'hFFFF_FFFF_0000_0001, 5'b00000);
        chk_box("s_d_sub_s_box");
        // fcvt.s.d(2^−149/4) = 0 且 UF|NX（舍入与下溢）
        chk_cvt("s_d_uf", 24, 0, 3'b000, 64'h3680_0000_0000_0000, 3'b000, 64'hFFFF_FFFF_0000_0000, 5'b00011);
        chk_box("s_d_uf_box");
        // fcvt.s.d(1e300) = +∞ 且 OF|NX
        chk_cvt("s_d_huge", 24, 0, 3'b000, 64'h7E37_E43C_8800_759C, 3'b000, 64'hFFFF_FFFF_7F80_0000, 5'b00101);
        chk_box("s_d_huge_box");
        // fcvt.s.d(1e300, RTZ) = S 最大有限数 且 OF|NX
        chk_cvt("s_d_huge_rtz", 24, 0, 3'b001, 64'h7E37_E43C_8800_759C, 3'b000, 64'hFFFF_FFFF_7F7F_FFFF, 5'b00101);
        chk_box("s_d_huge_rtz_box");
        // fcvt.s.d(qNaN) = S canonical NaN（NaN-boxed），0 flags
        chk_cvt("s_d_qnan", 24, 0, 3'b000, 64'h7FF8_0000_0000_0000, 3'b000, 64'hFFFF_FFFF_7FC0_0000, 5'b00000);
        chk_box("s_d_qnan_box");
        // fcvt.s.d(sNaN) = S canonical NaN 且 NV
        chk_cvt("s_d_snan", 24, 0, 3'b000, 64'h7FF0_0000_0000_0001, 3'b000, 64'hFFFF_FFFF_7FC0_0000, 5'b10000);
        chk_box("s_d_snan_box");
        // fcvt.s.d(+∞) = +∞
        chk_cvt("s_d_inf", 24, 0, 3'b000, 64'h7FF0_0000_0000_0000, 3'b000, 64'hFFFF_FFFF_7F80_0000, 5'b00000);
        chk_box("s_d_inf_box");
        // fcvt.s.d(−∞) = −∞
        chk_cvt("s_d_ninf", 24, 0, 3'b000, 64'hFFF0_0000_0000_0000, 3'b000, 64'hFFFF_FFFF_FF80_0000, 5'b00000);
        chk_box("s_d_ninf_box");
        // fcvt.s.d(2^31−1, rm=DYN) 用 frm=RUP ⇒ 同 RUP 结果
        chk_cvt("s_d_dyn", 24, 0, 3'b111, 64'h41DF_FFFF_FFFF_FFFF, 3'b011, 64'hFFFF_FFFF_4F00_0000, 5'b00001);
        chk_box("s_d_dyn_box");
        // fcvt.s.d(2^31−1, rm=101 保留) ⇒ 按 RNE 处理、不置额外 flags
        chk_cvt("s_d_reserved", 24, 0, 3'b101, 64'h41DF_FFFF_FFFF_FFFF, 3'b000, 64'hFFFF_FFFF_4F00_0000, 5'b00001);
        chk_box("s_d_reserved_box");

        //==========================================================================
        // 4.9 fmv.x.w / fmv.w.x / fmv.x.d / fmv.d.x（transfer：不检查 NaN-boxing、
        //     bit 不变、不置 fflags；fmv.w.x 写入窄值 ⇒ 必须产出合法 NaN-boxed 值）
        //==========================================================================
        // fmv.x.w(1.0 的 boxed 视图) = 低 32 位
        chk_cvt("mvx_w_basic", 14, 0, 3'b000, 64'hFFFF_FFFF_3F80_0000, 3'b000, 64'h0000_0000_3F80_0000, 5'b00000);
        // fmv.x.w(高位不全 1) = 低 32 位原样（transfer 不做 boxing 检查）
        chk_cvt("mvx_w_no_check", 14, 0, 3'b000, 64'hDEAD_BEEF_1234_5678, 3'b000, 64'h0000_0000_1234_5678, 5'b00000);
        // fmv.x.w(qNaN 位型) = 0x7FC00000（载荷不改）
        chk_cvt("mvx_w_nan", 14, 0, 3'b000, 64'hFFFF_FFFF_7FC0_0000, 3'b000, 64'h0000_0000_7FC0_0000, 5'b00000);
        // fmv.w.x(1.0 位型) ⇒ 高 32 位写 1（合法 NaN-boxed）
        chk_cvt("mvwx_basic", 15, 0, 3'b000, 64'h0000_0000_3F80_0000, 3'b000, 64'hFFFF_FFFF_3F80_0000, 5'b00000);
        chk_box("mvwx_basic_box");
        // fmv.w.x(−0.0 位型) ⇒ 0xFFFFFFFF80000000
        chk_cvt("mvwx_negzero", 15, 0, 3'b000, 64'h0000_0000_8000_0000, 3'b000, 64'hFFFF_FFFF_8000_0000, 5'b00000);
        chk_box("mvwx_negzero_box");
        // fmv.w.x(sNaN 位型) ⇒ 0xFFFFFFFF7F800001（位不变 + box）
        chk_cvt("mvwx_snan", 15, 0, 3'b000, 64'h0000_0000_7F80_0001, 3'b000, 64'hFFFF_FFFF_7F80_0001, 5'b00000);
        chk_box("mvwx_snan_box");
        // fmv.x.d(NaN-boxed 源) = 完整 64 位（含高 32 位全 1）
        chk_cvt("mvx_d_nanboxed", 14, 1, 3'b000, 64'hFFFF_FFFF_DEAD_BEEF, 3'b000, 64'hFFFF_FFFF_DEAD_BEEF, 5'b00000);
        chk_hi32ff("mvx_d_nanboxed_hi32ff");
        // fmv.x.d(D qNaN) = 原 64 位（高 32 位是 D 值自身的 7FF80000，不是补 1）
        chk_cvt("mvx_d_qnan", 14, 1, 3'b000, 64'h7FF8_0000_0000_0000, 3'b000, 64'h7FF8_0000_0000_0000, 5'b00000);
        // fmv.x.d(sNaN) = 位不变、不置 NV（transfer）
        chk_cvt("mvx_d_snan", 14, 1, 3'b000, 64'h7FF0_0000_0000_0001, 3'b000, 64'h7FF0_0000_0000_0001, 5'b00000);
        // fmv.d.x(0xCAFEBABE_DEADBEEF) = 原 64 位（不 box、不检查）
        chk_cvt("mvdx_basic", 15, 1, 3'b000, 64'hCAFE_BABE_DEAD_BEEF, 3'b000, 64'hCAFE_BABE_DEAD_BEEF, 5'b00000);
        // fmv.d.x(全 1) = 全 1
        chk_cvt("mvdx_max", 15, 1, 3'b000, 64'hFFFF_FFFF_FFFF_FFFF, 3'b000, 64'hFFFF_FFFF_FFFF_FFFF, 5'b00000);

        //--------------------------------------------------------------------------
        // 5. 判定：显式计数器（fail-closed）
        //--------------------------------------------------------------------------
        if (chk_cnt == 0) begin
            $display("TB_FPU_CMP_CVT_UNIT: FAIL (no check executed)");
            $fatal(1, "TB_FPU_CMP_CVT_UNIT: FAIL");
        end
        if (err_cnt != 0) begin
            $display("TB_FPU_CMP_CVT_UNIT: FAIL (%0d/%0d checks failed)", err_cnt, chk_cnt);
            $fatal(1, "TB_FPU_CMP_CVT_UNIT: FAIL");
        end

        $display("TB_FPU_CMP_CVT_UNIT: checked %0d vectors (86 cmp + 95 cvt), %0d errors",
                 chk_cnt, err_cnt);
        $display("TB_FPU_CMP_CVT_UNIT: PASS");
        $finish(0);
    end

endmodule

