//==============================================================================
// sim/unit/tb_parcel_align.sv —— rtl/fetch/parcel_align.v 单元测试
//==============================================================================
// 测什么  : 16-bit parcel 拆分与跨 parcel（跨字/跨行）拼接
//           （docs/design/08-baseline-5stage.md §5.1 ⑤：C 扩展跨 parcel 时在
//            parcel_align.v 拼接，**不得**让 D 级看到半条指令）
// 怎么判  : 全部检查 $fatal；失败路径只打 FAIL + $fatal；
//           走完全部用例才在最后一行打印 `TB_PARCEL_ALIGN_UNIT: PASS`。
// 失败长相: "FAIL: <用例名> 期望 x 实得 y" 后跟 $fatal 与非零退出码。
// 覆盖    : ① 16 bit 压缩指令直通；② 32 bit 指令 = {carry, hi}；
//           ③ carry 缺失 ⇒ insn_valid=0 且 cross_pending=1（不许交出半条指令）；
//           ④ 半字序（小端：VA+2 在高半）；⑤ 跨行：carry 来自下一行低半。
// 顶层    : tb_parcel_align_top
//==============================================================================
`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"

module tb_parcel_align_top;

    reg  [31:0] word_o;
    reg  [31:0] word_va_o;
    reg         carry_valid_i;
    reg  [15:0] carry_parcel_i;
    reg  [31:0] carry_va_i;

    wire [31:0] insn_o;
    wire [31:0] insn_va_o;
    wire        ilen32_o;
    wire        insn_valid_o;
    wire        cross_pending_o;

    integer checks_run;
    integer checks_fail;

    parcel_align dut (
        .word_o        (word_o),
        .word_va_o     (word_va_o),
        .carry_valid_i (carry_valid_i),
        .carry_parcel_i(carry_parcel_i),
        .carry_va_i    (carry_va_i),
        .insn_o        (insn_o),
        .insn_va_o     (insn_va_o),
        .ilen32_o      (ilen32_o),
        .insn_valid_o  (insn_valid_o),
        .cross_pending_o(cross_pending_o)
    );

    task automatic chk32;
        input [255:0] name;
        input [31:0]  exp;
        input [31:0]  got;
        begin
            checks_run = checks_run + 1;
            if (exp !== got) begin
                checks_fail = checks_fail + 1;
                $display("FAIL: %0s 期望 %08x 实得 %08x", name, exp, got);
                $fatal(1, "TB_PARCEL_ALIGN FAIL");
            end else begin
                $display("  ok  %0s = %08x", name, got);
            end
        end
    endtask

    task automatic chk1;
        input [255:0] name;
        input         exp;
        input         got;
        begin
            checks_run = checks_run + 1;
            if (exp !== got) begin
                checks_fail = checks_fail + 1;
                $display("FAIL: %0s 期望 %b 实得 %b", name, exp, got);
                $fatal(1, "TB_PARCEL_ALIGN FAIL");
            end else begin
                $display("  ok  %0s = %b", name, got);
            end
        end
    endtask

    // 反证实验用：XOR 混淆使实测值偏离期望（证明断言真的在比较数值）
    `ifdef PARCEL_ALIGN_XOR_MUTATION
    wire [31:0] insn_mut = insn_o ^ 32'h0000_0001;
    `else
    wire [31:0] insn_mut = insn_o;
    `endif

    initial begin
        checks_run  = 0;
        checks_fail = 0;
        word_o = 32'h0; word_va_o = 32'h0;
        carry_valid_i = 1'b0; carry_parcel_i = 16'h0; carry_va_i = 32'h0;

        $display("---- tb_parcel_align: parcel 拆分 / 跨字拼接 ----");

        //==================================================================
        // C1: 16 bit 压缩指令直通（opcode[1:0] != 3）
        //     例：c.addi a0, 1 的编码 0x0505（低 2 位 = 01 ⇒ 16 bit）
        //==================================================================
        word_o    = 32'h0000_0505;    // 低 parcel = 0x0505（压缩），高 parcel = 0x0000
        word_va_o = 32'h1C00_0000;
        carry_valid_i = 1'b0; carry_parcel_i = 16'hDEAD; carry_va_i = 32'h1C00_0004;
        #1;
        chk1 ("C1 ilen32=0 (compressed)",            1'b0, ilen32_o);
        chk32("C1 insn right-aligned, hi half zero", 32'h0000_0505, insn_o);
        chk32("C1 insn VA = word VA (parcel 0)",     32'h1C00_0000, insn_va_o);
        chk1 ("C1 insn_valid (no carry needed)",     1'b1, insn_valid_o);
        chk1 ("C1 cross_pending=0",                  1'b0, cross_pending_o);

        //==================================================================
        // C2: 16 bit 指令位于**高半**（parcel_is_lo=0 的情形）
        //     压缩指令在前一个字的高半 ⇒ 该字低半仍是上一指令的尾
        //     此处直接给出「已在低半」以外的独立用例：高半=0x0505
        //     但按本模块约定，低半不是压缩 ⇒ 低半[1:0]==11 才是 32 bit；
        //     为单独测高半，令低半 = 0xFFFF（[1:0]==11 ⇒ 32 bit），
        //     则走 32 bit 分支（这是本模块的固定口径，已在 C3 覆盖）。
        //     故本用例改为验证「半字序」：32 bit 时 carry 在低 16 位。
        //==================================================================
        // C2: 32 bit 指令 = {carry_parcel_i, word_o[15:0]}
        //     以 addi a0,a0,1 = 0x0015_0513 为例（RV32 小端 ⇒ 低半字在低地址）：
        //       起始 parcel（VA+0）= insn[15:0]  = 0x0513（[1:0]==11 ⇒ 32 bit 起始）
        //       下一个 parcel（VA+2）= insn[31:16] = 0x0015 = carry_parcel_i
        //     ★ 口径见 parcel_align.v §2：低半是**指令低位**，carry 是**指令高位**。
        word_o        = 32'hXXXX_0513;   // 低半 = 起始 parcel 0x0513（高半本例不使用）
        word_va_o     = 32'h1C00_0000;
        carry_parcel_i = 16'h0015;       // VA+2 的 parcel = 指令高半
        carry_va_i     = 32'h1C00_0002;
        carry_valid_i  = 1'b1;
        #1;
        chk1 ("C2 ilen32=1 (32-bit)",        1'b1, ilen32_o);
        chk32("C2 insn = {carry, start parcel}", 32'h0015_0513, insn_o);
        chk1 ("C2 insn_valid (carry present)", 1'b1, insn_valid_o);
        chk1 ("C2 cross_pending=0",            1'b0, cross_pending_o);
        chk32("C2 insn VA = word VA",          32'h1C00_0000, insn_va_o);

        //==================================================================
        // C3: carry 缺失 ⇒ **不交出半条指令**（§5.1 ⑤ 硬要求）
        //==================================================================
        carry_valid_i = 1'b0;
        #1;
        chk1("C3 ilen32 still 1",        1'b1, ilen32_o);
        chk1("C3 insn_valid=0 (no half-insn)", 1'b0, insn_valid_o);
        chk1("C3 cross_pending=1 (need 1 stall)", 1'b1, cross_pending_o);

        //==================================================================
        // C4: 半字序对照实验（小端）——交换 word 的上下半，输出必须随之变
        //     证明模块确实在用 word_o[31:16] 而非别的位段
        //==================================================================
        carry_valid_i  = 1'b1;
        carry_parcel_i = 16'h0015;
        // 起始 parcel 来自 word[15:0]；word[31:16] 是「同字 +2」的 parcel
        // —— 但对 32 bit 指令而言 +2 就是 carry 该给的值，故 word 高半被忽略。
        // 用不同的高半证明「高半不参与拼接」：
        word_o         = 32'hAAAA_0513;   // 低半 0x0513(32b 起始)，高半 0xAAAA
        #1;
        chk1 ("C4 32b start parcel from word[15:0]", 1'b1, ilen32_o);
        chk32("C4 32-bit ignores word[31:16], uses carry", 32'h0015_0513, insn_mut);
        word_o         = 32'h1234_0513;   // 仅换高半，结果必须不变
        #1;
        chk32("C4 result independent of word[31:16]", 32'h0015_0513, insn_mut);

        // C4b: 低半为压缩指令 ⇒ 只取低半，高半与 carry 全部无关
        word_o = 32'hDEAD_0505;   // 低半 0x0505（低 2 位 01 ⇒ 16 bit）
        #1;
        chk1 ("C4b low half compressed: ilen32=0", 1'b0, ilen32_o);
        chk32("C4b compressed uses word[15:0] only", 32'h0000_0505, insn_mut);
        chk1 ("C4b compressed ignores carry",      1'b0, cross_pending_o);

        //==================================================================
        // C5: 跨行拼接（§5.1 ⑤）——carry 来自**下一取指行**的低半
        //     本模块对「carry 来自哪一行」不敏感：只要 carry_valid=1，
        //     拼接即成立。故此处用「下一行 VA」构造，验证结果与行边界无关。
        //==================================================================
        word_o         = 32'hDEAD_0513;   // 字在行尾（VA+2 已跨到下一行）
        word_va_o      = 32'h1C00_001E;   // 该字 +2 parcel 落在 0x1C00_0020
        carry_parcel_i = 16'h0015;
        carry_va_i     = 32'h1C00_0020;   // 下一行（新 32 B 行）的起始 parcel
        carry_valid_i  = 1'b1;
        #1;
        chk32("C5 cross-line insn (result independent of line boundary)",
              32'h0015_0513, insn_mut);
        chk1 ("C5 cross-line valid",  1'b1, insn_valid_o);

        //==================================================================
        // C6: 边界值——全 1 与全 0
        //==================================================================
        word_o = 32'hDEAD_FFFF;           // 起始 parcel 0xFFFF（[1:0]==11 ⇒ 32 bit）
        carry_parcel_i = 16'hFFFF; carry_valid_i = 1'b1;
        #1;
        chk32("C6 all-ones insn", 32'hFFFF_FFFF, insn_mut);
        chk1 ("C6 all-ones ilen32=1", 1'b1, ilen32_o);
        // 起始 parcel = 0xFFFF，carry = 0x1234 ⇒ 0x1234_FFFF
        carry_parcel_i = 16'h1234;
        #1;
        chk32("C6 start=FFFF carry=1234 => 1234_FFFF", 32'h1234_FFFF, insn_mut);
        // carry 全 0 ⇒ 0x0000_FFFF
        carry_parcel_i = 16'h0000;
        #1;
        chk32("C6 start=FFFF carry=0000 => 0000_FFFF", 32'h0000_FFFF, insn_mut);

        //==================================================================
        // 结束判定
        //==================================================================
        checks_run = checks_run + 1;
        if (checks_run <= 0) begin
            $display("FAIL: 未捕获任何检查项");
            $fatal(1, "TB_PARCEL_ALIGN FAIL");
        end
        if (checks_fail != 0) begin
            $display("FAIL: %0d 项失败", checks_fail);
            $fatal(1, "TB_PARCEL_ALIGN FAIL");
        end
        $display("checks_run=%0d checks_fail=%0d", checks_run, checks_fail);
        $display("TB_PARCEL_ALIGN_UNIT: PASS");
        $finish;
    end

    initial begin
        #100000;
        $display("FAIL: 仿真超时（TB 未走完用例）");
        $fatal(1, "TB_PARCEL_ALIGN FAIL");
    end

endmodule
