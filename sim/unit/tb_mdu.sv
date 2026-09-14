//==============================================================================
// sim/unit/tb_mdu.sv —— rtl/exec/mdu.v 单元测试（自检 TB，fail-closed，多拍时序）
//==============================================================================
// 目的    : 验证 E 级乘除法单元的全部 8 条 M 扩展指令，重点覆盖 ISA 边界：
//             * 除零（div/divu 商 = 全 1；rem/remu 余数 = 被除数）
//             * 有符号溢出（-2^31 / -1：商 = 被除数，余数 = 0）
//             * 余数符号与被除数相同（有符号向零取整）
//             * mul / mulh / mulhsu / mulhu 全套（64 位积的两个半部）
//             * 多拍时序契约：busy / done 单拍 / done 拍 busy=0 / 背靠背
//             * flush 冲刷语义
// 判据    : ① 进程退出码 0；② 输出末行恰为 `TB_MDU_UNIT: PASS`（唯一 PASS 字样）；
//           ③ 任何一条断言不符 ⇒ 立即 $fatal（非零退出码），且**绝不打印 PASS**。
// 纪律    : 08 §8.1「未捕获即失败」——显式计数器 + $fatal；
//           `$display` 仅用于诊断，判定一律走 $fatal / err_cnt。
// 顶层    : tb_mdu（验收命令用 -s tb_mdu）
// 说明    : ★ 本 TB 按 **mdu.v 头注「时序契约」** 逐步检查：
//             start 在 E0 被接收 ⇒ 乘法 E0+2 拍 done；除法 E0+34 拍 done；
//             done 为单拍脉冲且同拍 busy=0。
//           ★ 本 TB **不依赖 Vivado**：iverilog 走 mdu.v 的 `else` 行为分支。
//           ★ 反证设计：TB 有意包含"若实现误用无符号/有符号语义就会失败"的向量
//             （如 -1 的 mulhu 高半、负数除法余数符号），保证测试真在测被测物。
//==============================================================================
`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"

module tb_mdu;

    //--------------------------------------------------------------------------
    // 0. 检查计数器（fail-closed）
    //--------------------------------------------------------------------------
    integer chk_cnt = 0;
    integer err_cnt = 0;

    //--------------------------------------------------------------------------
    // 1. 时钟/复位
    //--------------------------------------------------------------------------
    reg aclk    = 1'b0;
    reg aresetn = 1'b0;

    always #5 aclk = ~aclk;      // 10 ns 周期（50 MHz；频率不影响功能）

    //--------------------------------------------------------------------------
    // 2. DUT 例化
    //--------------------------------------------------------------------------
    reg  [31:0] a, b;
    reg  [2:0]  mdu_op;
    reg         start, flush;
    wire        busy, done;
    wire [31:0] result;

    mdu u_dut (
        .aclk    (aclk),
        .aresetn (aresetn),
        .start   (start),
        .flush   (flush),
        .mdu_op  (mdu_op),
        .a       (a),
        .b       (b),
        .busy    (busy),
        .done    (done),
        .result  (result)
    );

    //--------------------------------------------------------------------------
    // 3. 编码镜像（**mdu_op = M 扩展 funct3**，与 pkg §3.7 一致）
    //--------------------------------------------------------------------------
    localparam [2:0] M_MUL    = `RV32GC_F3_MUL;      // 000
    localparam [2:0] M_MULH   = `RV32GC_F3_MULH;     // 001
    localparam [2:0] M_MULHSU = `RV32GC_F3_MULHSU;   // 010
    localparam [2:0] M_MULHU  = `RV32GC_F3_MULHU;    // 011
    localparam [2:0] M_DIV    = `RV32GC_F3_DIV;      // 100
    localparam [2:0] M_DIVU   = `RV32GC_F3_DIVU;     // 101
    localparam [2:0] M_REM    = `RV32GC_F3_REM;      // 110
    localparam [2:0] M_REMU   = `RV32GC_F3_REMU;     // 111

    //--------------------------------------------------------------------------
    // 4. 时序契约常量（与 mdu.v 头注一致）
    //--------------------------------------------------------------------------
    localparam integer MUL_LAT = 2;    // start 被接收后第 2 拍 done
    localparam integer DIV_LAT = 34;   // start 被接收后第 34 拍 done

    //--------------------------------------------------------------------------
    // 5. 单条运算执行任务：发起 + 等 done + 返回结果
    //    同时逐步检查时序契约（busy / done 单拍 / done 拍 busy=0）
    //--------------------------------------------------------------------------
    task automatic run_op;
        input  [2:0]  op;
        input  [31:0] va, vb;
        input  integer lat;            // 期望延迟（拍）
        output [31:0] got;             // 结果
        integer i;
        integer done_cnt;
        begin
            // ---- 发起：等待非 busy 后给单拍 start ----
            //      （busy 期禁止发起；本 TB 起始于 IDLE）
            @(negedge aclk);
            start  = 1'b1;
            flush  = 1'b0;
            mdu_op = op;
            a      = va;
            b      = vb;
            @(negedge aclk);
            start = 1'b0;              // start 只维持 1 拍

            // ---- 等待 done，并统计 done 出现次数（必须恰 1 次） ----
            done_cnt = 0;
            got      = 32'hXXXX_XXXX;
            for (i = 0; i < lat + 6; i = i + 1) begin
                @(negedge aclk);
                if (done === 1'b1) begin
                    done_cnt = done_cnt + 1;
                    got      = result;
                    // ★ 时序契约：done 那一拍 busy 必须为 0（可背靠背）
                    chk_cnt = chk_cnt + 1;
                    if (busy !== 1'b0) begin
                        err_cnt = err_cnt + 1;
                        $display("  [FAIL] done 拍 busy 应为 0，实际 = %b", busy);
                        $fatal(1, "TB_MDU_UNIT: FAIL");
                    end
                end
            end

            // ---- done 必须恰好 1 拍（单拍脉冲） ----
            chk_cnt = chk_cnt + 1;
            if (done_cnt != 1) begin
                err_cnt = err_cnt + 1;
                $display("  [FAIL] op=%0d a=%08h b=%08h : done 出现 %0d 次（应恰 1 次）",
                         op, va, vb, done_cnt);
                $fatal(1, "TB_MDU_UNIT: FAIL");
            end
        end
    endtask

    //--------------------------------------------------------------------------
    // 6. 结果比对任务
    //--------------------------------------------------------------------------
    task automatic chk_val;
        input [127:0] name;
        input [2:0]   op;
        input [31:0]  va, vb;
        input integer lat;
        input [31:0]  exp;
        reg   [31:0]  got;
        begin
            run_op(op, va, vb, lat, got);
            chk_cnt = chk_cnt + 1;
            if (got !== exp) begin
                err_cnt = err_cnt + 1;
                $display("  [FAIL] %0s : op=%0d a=%08h b=%08h -> got %08h, exp %08h",
                         name, op, va, vb, got, exp);
                $fatal(1, "TB_MDU_UNIT: FAIL");
            end
        end
    endtask

    //--------------------------------------------------------------------------
    // 7. 激励
    //--------------------------------------------------------------------------
    initial begin
        $display("=== tb_mdu : rtl/exec/mdu.v 单元测试开始 ===");

        // ---- 复位 ----
        aresetn = 1'b0;
        start   = 1'b0;
        flush   = 1'b0;
        mdu_op  = M_MUL;
        a       = 32'd0;
        b       = 32'd0;
        repeat (4) @(negedge aclk);
        aresetn = 1'b1;
        repeat (2) @(negedge aclk);

        // ---- 复位后握手信号必须干净（busy=0, done=0） ----
        chk_cnt = chk_cnt + 1;
        if ((busy !== 1'b0) || (done !== 1'b0)) begin
            err_cnt = err_cnt + 1;
            $display("  [FAIL] 复位后 busy/done 应为 0，实际 busy=%b done=%b", busy, done);
            $fatal(1, "TB_MDU_UNIT: FAIL");
        end

        //====================================================================
        // 8.1 乘法全套：mul / mulh / mulhsu / mulhu
        //====================================================================
        // ---- MUL：低 32 位（有无符号同值） ----
        chk_val("mul_1x1"      , M_MUL, 32'd1,          32'd1,          MUL_LAT, 32'd1);
        chk_val("mul_0"        , M_MUL, 32'd0,          32'hFFFF_FFFF,  MUL_LAT, 32'd0);
        chk_val("mul_basic"    , M_MUL, 32'd1000,       32'd2000,       MUL_LAT, 32'd2_000_000);
        // 2^31 * 2 = 2^32 ⇒ 低 32 位 = 0（回绕）
        chk_val("mul_wrap"     , M_MUL, 32'h8000_0000,  32'd2,          MUL_LAT, 32'h0000_0000);
        // -1 * -1 = 1
        chk_val("mul_neg_neg"  , M_MUL, 32'hFFFF_FFFF,  32'hFFFF_FFFF,  MUL_LAT, 32'd1);
        // 0xFFFF_FFFF * 2 = 0x1_FFFF_FFFE ⇒ 低 32 位 = 0xFFFF_FFFE
        chk_val("mul_ff_x2"    , M_MUL, 32'hFFFF_FFFF,  32'd2,          MUL_LAT, 32'hFFFF_FFFE);

        // ---- MULHU：无符号高 32 位 ----
        chk_val("mulhu_max_max" , M_MULHU, 32'hFFFF_FFFF, 32'hFFFF_FFFF, MUL_LAT, 32'hFFFF_FFFE);
        // 0x8000_0000 * 0x8000_0000 = 2^62 ⇒ 高 32 位 = 2^30 = 0x4000_0000
        chk_val("mulhu_2p31"    , M_MULHU, 32'h8000_0000, 32'h8000_0000, MUL_LAT, 32'h4000_0000);
        chk_val("mulhu_small"   , M_MULHU, 32'd1,         32'd1,         MUL_LAT, 32'h0000_0000);
        chk_val("mulhu_zero"    , M_MULHU, 32'd0,         32'hFFFF_FFFF, MUL_LAT, 32'h0000_0000);
        // 0xFFFF_FFFF * 2 = 0x1_FFFF_FFFE ⇒ 高 32 位 = 1
        chk_val("mulhu_ff_x2"   , M_MULHU, 32'hFFFF_FFFF, 32'd2,         MUL_LAT, 32'h0000_0001);

        // ---- MULH：有符号×有符号 高 32 位 ----
        // -1 * -1 = +1 ⇒ 高 32 位 = 0（若误用无符号会得 0xFFFF_FFFE —— 反证点）
        chk_val("mulh_neg_neg"  , M_MULH, 32'hFFFF_FFFF, 32'hFFFF_FFFF, MUL_LAT, 32'h0000_0000);
        // -1 * 1 = -1 = 0xFFFF_FFFF_FFFF_FFFF ⇒ 高 32 位 = 0xFFFF_FFFF
        chk_val("mulh_neg_pos"  , M_MULH, 32'hFFFF_FFFF, 32'd1,         MUL_LAT, 32'hFFFF_FFFF);
        // INT_MIN * 1 = INT_MIN（64 位符号扩展）⇒ 高 32 位 = 0xFFFF_FFFF
        chk_val("mulh_intmin_1" , M_MULH, 32'h8000_0000, 32'd1,         MUL_LAT, 32'hFFFF_FFFF);
        // INT_MIN * -1 = +2^31 ⇒ 高 32 位 = 0
        chk_val("mulh_intmin_neg1", M_MULH, 32'h8000_0000, 32'hFFFF_FFFF, MUL_LAT, 32'h0000_0000);
        // 0x4000_0000 * 4 = 2^32 ⇒ 高 32 位 = 1
        chk_val("mulh_2p30_x4"  , M_MULH, 32'h4000_0000, 32'd4,         MUL_LAT, 32'h0000_0001);

        // ---- MULHSU：有符号 × 无符号 高 32 位 ----
        // -1 (signed) * 1u = -1 = 0xFFFF_FFFF_FFFF_FFFF ⇒ 高 32 位 = 0xFFFF_FFFF
        chk_val("mulhsu_neg1_1" , M_MULHSU, 32'hFFFF_FFFF, 32'd1,         MUL_LAT, 32'hFFFF_FFFF);
        // -1 * 0xFFFF_FFFF = -0xFFFF_FFFF = 0xFFFF_FFFF_0000_0001 ⇒ 高 32 位 = 0xFFFF_FFFF
        chk_val("mulhsu_neg1_max", M_MULHSU, 32'hFFFF_FFFF, 32'hFFFF_FFFF, MUL_LAT, 32'hFFFF_FFFF);
        // INT_MIN * 2u = -2^32 ⇒ 高 32 位 = 0xFFFF_FFFF
        chk_val("mulhsu_intmin_2", M_MULHSU, 32'h8000_0000, 32'd2,         MUL_LAT, 32'hFFFF_FFFF);
        // 正数 × 正数：与无符号一致
        chk_val("mulhsu_pos"    , M_MULHSU, 32'h0000_0002, 32'h8000_0000,  MUL_LAT, 32'h0000_0001);
        // -2 * 0x8000_0000 = -2^32 ⇒ 高 32 位 = 0xFFFF_FFFF
        chk_val("mulhsu_neg2_intmin", M_MULHSU, 32'hFFFF_FFFE, 32'h8000_0000, MUL_LAT, 32'hFFFF_FFFF);

        //====================================================================
        // 8.2 除法：常规 + 符号语义
        //====================================================================
        chk_val("div_basic"    , M_DIV,  32'd20,         32'd3,   DIV_LAT, 32'd6);
        chk_val("div_exact"    , M_DIV,  32'd100,        32'd5,   DIV_LAT, 32'd20);
        chk_val("div_lt"       , M_DIV,  32'd3,          32'd20,  DIV_LAT, 32'd0);
        chk_val("div_1"        , M_DIV,  32'h1234_5678,  32'd1,   DIV_LAT, 32'h1234_5678);
        // ---- 关键：有符号除法向零取整 + 余数符号随被除数 ----
        // -7 / 2 = -3（向零），余数 = -1
        chk_val("div_neg_tz"   , M_DIV,  32'hFFFF_FFF9,  32'd2,   DIV_LAT, 32'hFFFF_FFFD);
        chk_val("rem_neg_tz"   , M_REM,  32'hFFFF_FFF9,  32'd2,   DIV_LAT, 32'hFFFF_FFFF);
        // 7 / -2 = -3（向零），余数 = 1（符号随被除数 7）
        chk_val("div_pos_neg"  , M_DIV,  32'd7,          32'hFFFF_FFFE, DIV_LAT, 32'hFFFF_FFFD);
        chk_val("rem_pos_neg"  , M_REM,  32'd7,          32'hFFFF_FFFE, DIV_LAT, 32'd1);
        // -7 / -2 = 3，余数 = -1（符号随被除数）
        chk_val("div_neg_neg"  , M_DIV,  32'hFFFF_FFF9,  32'hFFFF_FFFE, DIV_LAT, 32'd3);
        chk_val("rem_neg_neg"  , M_REM,  32'hFFFF_FFF9,  32'hFFFF_FFFE, DIV_LAT, 32'hFFFF_FFFF);

        // ---- 无符号除法 ----
        chk_val("divu_basic"   , M_DIVU, 32'd20,         32'd3,   DIV_LAT, 32'd6);
        chk_val("divu_max"     , M_DIVU, 32'hFFFF_FFFF,  32'd1,   DIV_LAT, 32'hFFFF_FFFF);
        chk_val("divu_half"    , M_DIVU, 32'hFFFF_FFFF,  32'd2,   DIV_LAT, 32'h7FFF_FFFF);
        // 0x8000_0000 / 2 = 0x4000_0000（无符号；若有符号会得 0xC000_0000 —— 反证点）
        chk_val("divu_sign_edge", M_DIVU, 32'h8000_0000, 32'd2,   DIV_LAT, 32'h4000_0000);
        chk_val("remu_sign_edge", M_REMU, 32'h8000_0000, 32'd3,   DIV_LAT, 32'd2);
        chk_val("remu_max"     , M_REMU, 32'hFFFF_FFFF,  32'hFFFF_FFFF, DIV_LAT, 32'd0);

        //====================================================================
        // 8.3 ★ 除零（任务书验收判据③硬要求）
        //     商 = 全 1；余数 = 被除数（**有符号/无符号同值**）
        //====================================================================
        // 有符号：div x/0 = -1（全 1）；rem x/0 = x
        chk_val("div_by_zero"   , M_DIV,  32'd1234,       32'd0, DIV_LAT, 32'hFFFF_FFFF);
        chk_val("rem_by_zero"   , M_REM,  32'd1234,       32'd0, DIV_LAT, 32'd1234);
        // 负被除数：商仍全 1（= -1），余数 = 被除数原值
        chk_val("div_by_zero_neg", M_DIV, 32'hFFFF_FFFE,  32'd0, DIV_LAT, 32'hFFFF_FFFF);
        chk_val("rem_by_zero_neg", M_REM, 32'hFFFF_FFFE,  32'd0, DIV_LAT, 32'hFFFF_FFFE);
        // 无符号：divu x/0 = 0xFFFF_FFFF；remu x/0 = x
        chk_val("divu_by_zero"  , M_DIVU, 32'hDEAD_BEEF,  32'd0, DIV_LAT, 32'hFFFF_FFFF);
        chk_val("remu_by_zero"  , M_REMU, 32'hDEAD_BEEF,  32'd0, DIV_LAT, 32'hDEAD_BEEF);
        // 边界：0/0 ⇒ 商全 1，余数 0
        chk_val("div_0_0"       , M_DIV,  32'd0,          32'd0, DIV_LAT, 32'hFFFF_FFFF);
        chk_val("rem_0_0"       , M_REM,  32'd0,          32'd0, DIV_LAT, 32'd0);

        //====================================================================
        // 8.4 ★ 有符号溢出 -2^31 / -1（任务书验收判据③硬要求）
        //     商 = 被除数（0x8000_0000）；余数 = 0
        //====================================================================
        chk_val("div_overflow"  , M_DIV,  32'h8000_0000,  32'hFFFF_FFFF, DIV_LAT, 32'h8000_0000);
        chk_val("rem_overflow"  , M_REM,  32'h8000_0000,  32'hFFFF_FFFF, DIV_LAT, 32'h0000_0000);
        // 无符号下 0x8000_0000 / 0xFFFF_FFFF = 0（不是溢出情形，验证未误套溢出分支）
        chk_val("divu_no_overflow", M_DIVU, 32'h8000_0000, 32'hFFFF_FFFF, DIV_LAT, 32'h0000_0000);
        chk_val("remu_no_overflow", M_REMU, 32'h8000_0000, 32'hFFFF_FFFF, DIV_LAT, 32'h8000_0000);
        // 相邻值：0x8000_0000 / 0xFFFF_FFFE = 0（有符号下 -2^31 / -2 = 2^30）
        chk_val("div_intmin_neg2", M_DIV, 32'h8000_0000, 32'hFFFF_FFFE, DIV_LAT, 32'h4000_0000);
        chk_val("rem_intmin_neg2", M_REM, 32'h8000_0000, 32'hFFFF_FFFE, DIV_LAT, 32'h0000_0000);

        //====================================================================
        // 8.5 背靠背：done 同拍可立即发起下一次（吞吐）
        //====================================================================
        begin : back_to_back
            reg [31:0] r1, r2;
            run_op(M_MUL, 32'd6, 32'd7, MUL_LAT, r1);
            chk_cnt = chk_cnt + 1;
            if (r1 !== 32'd42) begin
                err_cnt = err_cnt + 1;
                $display("  [FAIL] back_to_back#1 got %08h exp 0000002a", r1);
                $fatal(1, "TB_MDU_UNIT: FAIL");
            end
            run_op(M_MUL, 32'd8, 32'd9, MUL_LAT, r2);
            chk_cnt = chk_cnt + 1;
            if (r2 !== 32'd72) begin
                err_cnt = err_cnt + 1;
                $display("  [FAIL] back_to_back#2 got %08h exp 00000048", r2);
                $fatal(1, "TB_MDU_UNIT: FAIL");
            end
        end

        //====================================================================
        // 8.6 busy 语义：仅在除法迭代期拉高（乘法不置 busy）
        //====================================================================
        begin : busy_check
            integer saw_busy_mul;
            // ---- 乘法期间 busy 应恒为 0 ----
            @(negedge aclk);
            start = 1'b1; mdu_op = M_MUL; a = 32'd3; b = 32'd5;
            @(negedge aclk);
            start = 1'b0;
            saw_busy_mul = 0;
            repeat (MUL_LAT + 1) begin
                @(negedge aclk);
                if (busy === 1'b1) saw_busy_mul = 1;
            end
            chk_cnt = chk_cnt + 1;
            if (saw_busy_mul != 0) begin
                err_cnt = err_cnt + 1;
                $display("  [FAIL] 乘法期间 busy 应恒 0（实测出现过 1）");
                $fatal(1, "TB_MDU_UNIT: FAIL");
            end

            // ---- 除法迭代期 busy 必须拉高过 ----
            @(negedge aclk);
            start = 1'b1; mdu_op = M_DIV; a = 32'd100; b = 32'd7;
            @(negedge aclk);
            start = 1'b0;
            saw_busy_div = 0;
            for (i_busy = 0; i_busy < DIV_LAT + 4; i_busy = i_busy + 1) begin
                @(negedge aclk);
                if (busy === 1'b1) saw_busy_div = 1;
                if (done === 1'b1) begin
                    got_busy_div = result;
                end
            end
            chk_cnt = chk_cnt + 1;
            if (saw_busy_div != 1) begin
                err_cnt = err_cnt + 1;
                $display("  [FAIL] 除法迭代期 busy 必须拉高（实测从未拉高）");
                $fatal(1, "TB_MDU_UNIT: FAIL");
            end
            chk_cnt = chk_cnt + 1;
            if (got_busy_div !== 32'd14) begin     // 100 / 7 = 14 余 2
                err_cnt = err_cnt + 1;
                $display("  [FAIL] busy_check 除法结果 got %08h exp 0000000e", got_busy_div);
                $fatal(1, "TB_MDU_UNIT: FAIL");
            end
        end

        //====================================================================
        // 8.7 flush 冲刷：在途结果必须丢弃，且回 IDLE（busy=0）
        //====================================================================
        begin : flush_check
            // 发起一次长除法，迭代中途 flush
            @(negedge aclk);
            start = 1'b1; flush = 1'b0; mdu_op = M_DIV;
            a = 32'h0000_0000; b = 32'h0000_0001;   // 结果应为 0（可区分于"未丢弃"）
            @(negedge aclk);
            start = 1'b0;
            repeat (5) @(negedge aclk);             // 进入迭代中段
            flush = 1'b1;
            @(negedge aclk);
            flush = 1'b0;

            // ---- flush 后：busy 必须为 0，且此后 ~40 拍内不得出现 done ----
            chk_cnt = chk_cnt + 1;
            if (busy !== 1'b0) begin
                err_cnt = err_cnt + 1;
                $display("  [FAIL] flush 后 busy 应为 0，实际 = %b", busy);
                $fatal(1, "TB_MDU_UNIT: FAIL");
            end

            saw_done_after_flush = 0;
            for (i_flush = 0; i_flush < 40; i_flush = i_flush + 1) begin
                @(negedge aclk);
                if (done === 1'b1) saw_done_after_flush = 1;
            end
            chk_cnt = chk_cnt + 1;
            if (saw_done_after_flush != 0) begin
                err_cnt = err_cnt + 1;
                $display("  [FAIL] flush 后在途除法不应再产生 done");
                $fatal(1, "TB_MDU_UNIT: FAIL");
            end

            // ---- flush 后必须仍可正常工作（状态机确实回到 IDLE） ----
            begin : post_flush
                reg [31:0] r_post;
                run_op(M_DIV, 32'd84, 32'd2, DIV_LAT, r_post);
                chk_cnt = chk_cnt + 1;
                if (r_post !== 32'd42) begin
                    err_cnt = err_cnt + 1;
                    $display("  [FAIL] flush 后除法 got %08h exp 0000002a", r_post);
                    $fatal(1, "TB_MDU_UNIT: FAIL");
                end
            end
        end

        //----------------------------------------------------------------------
        // 9. 判定（fail-closed）
        //----------------------------------------------------------------------
        if (chk_cnt == 0) begin
            $display("TB_MDU_UNIT: FAIL (no check executed)");
            $fatal(1, "TB_MDU_UNIT: FAIL");
        end
        if (err_cnt != 0) begin
            $display("TB_MDU_UNIT: FAIL (%0d/%0d checks failed)", err_cnt, chk_cnt);
            $fatal(1, "TB_MDU_UNIT: FAIL");
        end

        $display("TB_MDU_UNIT: checked %0d vectors, %0d errors", chk_cnt, err_cnt);
        $display("TB_MDU_UNIT: PASS");
        $finish(0);
    end

    //--------------------------------------------------------------------------
    // 10. busy_check / flush_check 的辅助变量（始终声明在模块级，便于 iverilog）
    //--------------------------------------------------------------------------
    integer i_busy, i_flush;
    reg     saw_busy_div, saw_done_after_flush;
    reg [31:0] got_busy_div;

endmodule
