//==============================================================================
// sim/unit/tb_alu.sv —— rtl/exec/alu.v 单元测试（自检 TB，fail-closed）
//==============================================================================
// 目的    : 验证 E 级整数 ALU 的全部运算与边界。
// 判据    : ① 进程退出码 0；② 输出末行恰为 `TB_ALU_UNIT: PASS`（唯一 PASS 字样）；
//           ③ 任何一条断言不符 ⇒ 立即 $fatal（非零退出码），且**绝不打印 PASS**。
// 纪律    : 08 §8.1「未捕获即失败」——本 TB 用**显式计数器**统计检查数与失败数，
//           只有 `chk_cnt > 0 && err_cnt == 0` 时才允许打印 PASS；
//           `$display` 仅用于诊断，判定一律走 $fatal / err_cnt。
// 覆盖    : 任务书验收判据③要求 ——
//             add/sub/sll/srl/sra/slt/sltu/xor/or/and/lui/auipc 共 12 条全覆盖，
//             且含边界值（INT_MIN/INT_MAX、移位量 ≥32、slt 的符号边界）。
// 顶层    : tb_alu（验收命令用 -s tb_alu）
// 说明    : 组合验证——DUT 无时钟；每条向量直接比对 result。
//           ★ 本 TB 有意**不**依赖被测模块内部实现（黑盒端口比对）。
//==============================================================================
`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"

module tb_alu;

    //--------------------------------------------------------------------------
    // 0. 检查计数器（fail-closed 纪律：只有走完全部检查才可能 PASS）
    //--------------------------------------------------------------------------
    integer chk_cnt = 0;    // 已执行的检查条数
    integer err_cnt = 0;    // 失败条数

    //--------------------------------------------------------------------------
    // 1. DUT 例化
    //--------------------------------------------------------------------------
    reg  [31:0] a, b, pc;
    reg  [3:0]  alu_op;
    wire [31:0] result;

    alu u_dut (
        .a      (a),
        .b      (b),
        .alu_op (alu_op),
        .pc     (pc),
        .result (result)
    );

    //--------------------------------------------------------------------------
    // 2. alu_op 编码镜像（与 DUT 头注「编码公约」一致）
    //--------------------------------------------------------------------------
    localparam [3:0] ALU_ADD   = 4'd0;
    localparam [3:0] ALU_SUB   = 4'd1;
    localparam [3:0] ALU_SLL   = 4'd2;
    localparam [3:0] ALU_SLT   = 4'd3;
    localparam [3:0] ALU_SLTU  = 4'd4;
    localparam [3:0] ALU_XOR   = 4'd5;
    localparam [3:0] ALU_SRL   = 4'd6;
    localparam [3:0] ALU_SRA   = 4'd7;
    localparam [3:0] ALU_OR    = 4'd8;
    localparam [3:0] ALU_AND   = 4'd9;
    localparam [3:0] ALU_LUI   = 4'd10;
    localparam [3:0] ALU_AUIPC = 4'd11;

    //--------------------------------------------------------------------------
    // 3. 检查任务：一条向量 = 一次「设激励 + 比结果」
    //--------------------------------------------------------------------------
    task automatic chk;
        input [127:0] name;             // 诊断名（ASCII）
        input [3:0]   op;               // 运算
        input [31:0]  va, vb, vpc;      // 输入
        input [31:0]  exp;              // 期望
        begin
            alu_op = op;  a = va;  b = vb;  pc = vpc;
            #1;                          // 组合传播
            chk_cnt = chk_cnt + 1;
            if (result !== exp) begin
                err_cnt = err_cnt + 1;
                $display("  [FAIL] %0s : op=%0d a=%08h b=%08h pc=%08h -> got %08h, exp %08h",
                         name, op, va, vb, vpc, result, exp);
                $fatal(1, "TB_ALU_UNIT: FAIL");
            end
        end
    endtask

    //--------------------------------------------------------------------------
    // 4. 激励
    //--------------------------------------------------------------------------
    initial begin
        $display("=== tb_alu : rtl/exec/alu.v 单元测试开始 ===");

        //---- 4.1 ADD：模 2^32 回绕（含进位溢出） ----
        chk("add_basic" , ALU_ADD, 32'd1,          32'd2,          32'd0, 32'd3);
        chk("add_zero"  , ALU_ADD, 32'd0,          32'd0,          32'd0, 32'd0);
        chk("add_wrap"  , ALU_ADD, 32'hFFFF_FFFF,  32'd1,          32'd0, 32'h0000_0000);
        chk("add_max"   , ALU_ADD, 32'h7FFF_FFFF,  32'h7FFF_FFFF,  32'd0, 32'hFFFF_FFFE);
        chk("add_sign"  , ALU_ADD, 32'h8000_0000,  32'h8000_0000,  32'd0, 32'h0000_0000);

        //---- 4.2 SUB：回绕与符号边界 ----
        chk("sub_basic" , ALU_SUB, 32'd5,          32'd3,          32'd0, 32'd2);
        chk("sub_neg"   , ALU_SUB, 32'd3,          32'd5,          32'd0, 32'hFFFF_FFFE);
        chk("sub_wrap"  , ALU_SUB, 32'h0000_0000,  32'd1,          32'd0, 32'hFFFF_FFFF);
        chk("sub_min"   , ALU_SUB, 32'h8000_0000,  32'd1,          32'd0, 32'h7FFF_FFFF);
        chk("sub_eq"    , ALU_SUB, 32'hDEAD_BEEF,  32'hDEAD_BEEF,  32'd0, 32'h0000_0000);

        //---- 4.3 SLL：移位量取低 5 位（32≡0、63≡31） ----
        chk("sll_1"     , ALU_SLL, 32'd1,          32'd4,          32'd0, 32'd16);
        chk("sll_31"    , ALU_SLL, 32'd1,          32'd31,         32'd0, 32'h8000_0000);
        chk("sll_off"   , ALU_SLL, 32'd1,          32'd32,         32'd0, 32'd1);          // 32 → 0
        chk("sll_63"    , ALU_SLL, 32'd1,          32'd63,         32'd0, 32'h8000_0000);  // 63 → 31
        chk("sll_hi_ign", ALU_SLL, 32'h0000_0001,  32'hFFFF_FFE0,  32'd0, 32'h0000_0001);  // b[31:5] 忽略 ⇒ 移 0

        //---- 4.4 SRL：逻辑右移补 0 ----
        chk("srl_1"     , ALU_SRL, 32'h8000_0000,  32'd31,         32'd0, 32'd1);
        chk("srl_sign"  , ALU_SRL, 32'hFFFF_FFFF,  32'd4,          32'd0, 32'h0FFF_FFFF);
        chk("srl_off"   , ALU_SRL, 32'hFFFF_FFFF,  32'd32,         32'd0, 32'hFFFF_FFFF);  // 32 → 0
        chk("srl_63"    , ALU_SRL, 32'h8000_0000,  32'd63,         32'd0, 32'd1);          // 63 → 31

        //---- 4.5 SRA：算术右移补符号位 ----
        chk("sra_pos"   , ALU_SRA, 32'h0000_0010,  32'd2,          32'd0, 32'h0000_0004);
        chk("sra_neg"   , ALU_SRA, 32'h8000_0000,  32'd4,          32'd0, 32'hF800_0000);
        chk("sra_all1"  , ALU_SRA, 32'hFFFF_FFFF,  32'd31,         32'd0, 32'hFFFF_FFFF);
        chk("sra_off"   , ALU_SRA, 32'h8000_0000,  32'd32,         32'd0, 32'h8000_0000);  // 32 → 0
        chk("sra_min1"  , ALU_SRA, 32'h8000_0000,  32'd1,          32'd0, 32'hC000_0000);

        //---- 4.6 SLT：有符号比较，结果必须 0/1 ----
        chk("slt_lt"    , ALU_SLT, 32'hFFFF_FFFF,  32'd1,          32'd0, 32'd1);          // -1 < 1
        chk("slt_gt"    , ALU_SLT, 32'd1,          32'hFFFF_FFFF,  32'd0, 32'd0);
        chk("slt_minmax", ALU_SLT, 32'h8000_0000,  32'h7FFF_FFFF,  32'd0, 32'd1);          // INT_MIN < INT_MAX
        chk("slt_eq"    , ALU_SLT, 32'h1234_5678,  32'h1234_5678,  32'd0, 32'd0);
        // 关键反证：若实现误用无符号比较，下面这条会得到 0（错），必须得 1
        chk("slt_unsig_neg", ALU_SLT, 32'hFFFF_FFFE, 32'h0000_0001, 32'd0, 32'd1);

        //---- 4.7 SLTU：无符号比较 ----
        chk("sltu_lt"   , ALU_SLTU, 32'd1,         32'hFFFF_FFFF,  32'd0, 32'd1);
        chk("sltu_gt"   , ALU_SLTU, 32'hFFFF_FFFF, 32'd1,          32'd0, 32'd0);
        chk("sltu_eq"   , ALU_SLTU, 32'hABCD_EF01, 32'hABCD_EF01,  32'd0, 32'd0);
        // 关键反证：若实现误用有符号比较，下面这条会得到 1（错），必须得 0
        chk("sltu_signed_look", ALU_SLTU, 32'hFFFF_FFFF, 32'd1,    32'd0, 32'd0);

        //---- 4.8 XOR ----
        chk("xor_1"     , ALU_XOR, 32'hFF00_FF00,  32'h0F0F_0F0F,  32'd0, 32'hF00F_F00F);
        chk("xor_same"  , ALU_XOR, 32'h1234_5678,  32'h1234_5678,  32'd0, 32'h0000_0000);
        chk("xor_zero"  , ALU_XOR, 32'h1234_5678,  32'h0000_0000,  32'd0, 32'h1234_5678);

        //---- 4.9 OR ----
        chk("or_1"      , ALU_OR,  32'hFF00_0000,  32'h00FF_0000,  32'd0, 32'hFFFF_0000);
        chk("or_zero"   , ALU_OR,  32'h1234_5678,  32'h0000_0000,  32'd0, 32'h1234_5678);
        chk("or_all"    , ALU_OR,  32'hFFFF_FFFF,  32'h0000_0000,  32'd0, 32'hFFFF_FFFF);

        //---- 4.10 AND ----
        chk("and_1"     , ALU_AND, 32'hFFFF_00FF,  32'h0F0F_0F0F,  32'd0, 32'h0F0F_000F);
        chk("and_zero"  , ALU_AND, 32'hFFFF_FFFF,  32'h0000_0000,  32'd0, 32'h0000_0000);
        chk("and_self"  , ALU_AND, 32'hDEAD_BEEF,  32'hFFFF_FFFF,  32'd0, 32'hDEAD_BEEF);

        //---- 4.11 LUI：result = b（U 型立即数已左移 12） ----
        //     lui x1, 0x12345 ⇒ imm = 0x1234_5000
        chk("lui_1"     , ALU_LUI, 32'hDEAD_BEEF,  32'h1234_5000,  32'd0, 32'h1234_5000);
        chk("lui_hi"    , ALU_LUI, 32'h0000_0000,  32'hFFFF_F000,  32'd0, 32'hFFFF_F000);
        // LUI 结果与 a（rs1）无关：换 a 结果不变（反证 LUI 未误用 a）
        chk("lui_ignore_a", ALU_LUI, 32'hFFFF_FFFF, 32'h8000_0000, 32'd0, 32'h8000_0000);

        //---- 4.12 AUIPC：result = pc + b ----
        //     auipc x1, 0x1000 @ pc=0x1C00_0000 ⇒ 0x1C00_0000 + 0x0100_0000 = 0x1D00_0000
        chk("auipc_1"   , ALU_AUIPC, 32'hDEAD_BEEF, 32'h0100_0000, 32'h1C00_0000, 32'h1D00_0000);
        //     PC=0x0000_1000 + imm=0xFFFF_F000 ⇒ 回绕到 0x0000_0000
        chk("auipc_wrap", ALU_AUIPC, 32'h0000_0000, 32'hFFFF_F000, 32'h0000_1000, 32'h0000_0000);
        // AUIPC 结果与 a（rs1）无关（反证未误用 a）：a 换成全 1，结果不变
        chk("auipc_ignore_a", ALU_AUIPC, 32'hFFFF_FFFF, 32'h0000_0004, 32'h1000_0000, 32'h1000_0004);

        //---- 4.13 未定义编码：确定输出 0（无 latch、无异常） ----
        chk("undef_12"  , 4'd12,   32'hFFFF_FFFF,  32'hFFFF_FFFF,  32'd0, 32'h0000_0000);
        chk("undef_15"  , 4'd15,   32'h1234_5678,  32'h8765_4321,  32'd0, 32'h0000_0000);

        //--------------------------------------------------------------------------
        // 5. 判定：显式计数器（fail-closed）
        //--------------------------------------------------------------------------
        if (chk_cnt == 0) begin
            $display("TB_ALU_UNIT: FAIL (no check executed)");
            $fatal(1, "TB_ALU_UNIT: FAIL");
        end
        if (err_cnt != 0) begin
            $display("TB_ALU_UNIT: FAIL (%0d/%0d checks failed)", err_cnt, chk_cnt);
            $fatal(1, "TB_ALU_UNIT: FAIL");
        end

        $display("TB_ALU_UNIT: checked %0d vectors, %0d errors", chk_cnt, err_cnt);
        $display("TB_ALU_UNIT: PASS");
        $finish(0);
    end

endmodule
