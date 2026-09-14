//==============================================================================
// sim/unit/tb_fregfile.sv —— 浮点寄存器堆单元测试（DUT = rtl/exec/fregfile.v）
//==============================================================================
// 项目  : rv32gc-cpu（2A 单发射顺序 5 级基线核）
// 规格  : docs/design/08-baseline-5stage.md §5.3（`fregfile.v` 行）
//           —— in: rs1/rs2/rs3/rd/we/wdata；out: rdata1/rdata2/rdata3
//           —— 写优先读口 + 旁路；f0–f31 在 D 视图下为 64 位
//         真源：`RV32GC_FLEN = 64`、`RV32GC_FPRS = 32`（rtl/pkg/core_params.vh §4）
//
// 覆盖点（逐条对应验收判据）：
//   ① 复位：`rst_n` 低 ⇒ 全 32 个寄存器清零；且**复位后以"零抖动"读地址**
//      直接读 f0 必须得到 0（该三条是本文件头注 ★ 缺陷的回归哨兵）。
//   ② **三读口并发**：32 个寄存器各写唯一模式后，用三个**互不相同**的索引
//      （i, i+1, i+7 循环）一次性核对三读口互不串扰、值全对。
//   ③ **写优先旁路**：同一拍 `we=1, rd=k` 且三个读口都读 k ⇒ 三读口都必须
//      返回**同拍写入值**（不是旧值）；下一拍仍读得到（已落寄存器）。
//      另有"部分冲突"用例：rd=5 时 rs1=5、rs2=6、rs3=5 ⇒ 只有命中口给新值，
//      未命中的口必须给旧值（不能整体误旁路）。
//   ④ **64 位 D 视图**：写入完整 64 位模式（含 D qNaN payload、符号位+LSB 的
//      非对称模式）逐位读回，无掩码、无拆分；S 视图下同一 64 位存储的高 32 位
//      （NaN-box 位）原样保留（S/D 视图由使用者取用，本模块不做字段处理）。
//   ⑤ **f0 是普通寄存器**：写 f0 后必须读回写入值（RISC-V 的 f0 与 x0 不同，
//      **不是**硬连零）；再写 0 后读回 0（确认是"寄存器行为"而非"恒 0"）。
//   ⑥ 写使能语义：`we=0` 时 wdata/rd 变化不得改变任何寄存器；
//      连续两拍写同一寄存器 ⇒ 后写覆盖先写（last write wins）；
//      写 k 的同时读 j≠k ⇒ 读口给旧值、写口照常生效。
//   ⑦ 复位可重复：再次拉低 `rst_n` 必须把已写入的值全部清掉。
//
// ★ 本 TB 首跑发现并推动修复的缺陷（2026-09-14，**已在 `rtl/exec/fregfile.v`
//   内修掉**，本文件为该修复的回归哨兵）：
//   `fregfile.v` 的读口原用 `function rd_port(input [4:0] idx)` 读模块级数组
//   `fpr[]`。**iverilog 12.0 对"函数体内读模块级数组"不建立写依赖** ⇒ 读口在
//   "读地址不变、只有阵列变化"时不重算，读到陈旧值：复位后固定读 f0 得到
//   `xxxxxxxxxxxxxxxx`，而层次引用 `dut.fpr[0]` 已是 0；"连续两拍写同一寄存器"
//   的读口也会停在上一拍值（本 TB 首跑 errors=11）。
//   最小复现（独立小文件，与交付文件无关）：
//       reg [63:0] mem [0:3]; reg [1:0] idx = 0;
//       function [63:0] rd; input [1:0] ix; begin rd = mem[ix]; end endfunction
//       wire [63:0] out = rd(idx);
//       // 初值 x → 只写 mem[0]=0xAAAA（不动 idx）→ out 仍 x
//       // 抖动 idx 后才更新 → 再写 mem[0]=0xBBBB，out 仍停在 0xAAAA
//   对照：把数组读直接写在 `assign` 里（`assign out2 = mem[idx2];`）立即更新；
//   同例 Verilator 5.020 的**变量索引**函数调用正常（常量索引同样有停更问题）。
//   ⇒ 修法（已落地）：三条内联 `assign rdataN = (we && (rd == rsN)) ? wdata :
//     fpr[rsN];`（端口/语义不变，iverilog 与 Verilator 依赖均正确）。
//   ⇒ 本 TB 的"零抖动读"用例（复位后 f0、f0 写后重读、连续写第二拍的旁路）
//     即为该缺陷的回归哨兵：若退回函数写法或换回有该问题的模拟器，立刻报错。
//
// 时序口径（本 TB 的驱动纪律）：激励一律用**非阻塞赋值**在 `posedge` 给出
//   （保证"一个时钟周期"的语义）；采样点在"边沿 + 1.5 ns"（clk 低电平中部，
//   与任何时钟沿都不竞争）。写优先旁路是**组合**行为 ⇒ 必须在 `we=1` 的那一拍
//   内采样；写入"落寄存器"在下一个时钟沿，也在同一思路下核对。
//
// 判定协议：唯一 PASS 行 `TB_FREGFILE_UNIT: PASS`（errors==0 时才打印），
//   结束时打印 `TB_FREGFILE_UNIT: checks=<n> errors=<n>`；失败时打印错误明细，
//   以 `TB_FREGFILE_UNIT: FAIL errors=<n>` 收尾并以 `$fatal` 结束
//   （**未捕获即失败**）。
//==============================================================================
`timescale 1ns/1ps

module tb_fregfile;
    // ---- 时钟 / 复位 ------------------------------------------------------
    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #1 clk = ~clk;                       // 周期 2 ns

    // ---- 端口（逐字对应 rtl/exec/fregfile.v）------------------------------
    reg  [4:0]  rs1, rs2, rs3, rd;
    reg         we;
    reg  [63:0] wdata;
    wire [63:0] rdata1, rdata2, rdata3;

    fregfile dut (
        .clk (clk), .rst_n (rst_n),
        .rs1 (rs1), .rs2 (rs2), .rs3 (rs3),
        .rdata1 (rdata1), .rdata2 (rdata2), .rdata3 (rdata3),
        .we (we), .rd (rd), .wdata (wdata)
    );

    integer errors = 0, checks = 0;
    integer i;

    // ---- 每个寄存器索引的唯一测试模式 ------------------------------------
    localparam [63:0] PAT_MASK = 64'h9E37_79B9_7F4A_7C15;
    function [63:0] pat;
        input [4:0] idx;
        begin
            pat = PAT_MASK ^ {59'b0, idx};
        end
    endfunction

    // ---- 判定助手（失败只计数并打印，末尾统一出结论）----------------------
    task chk64;
        input [63:0]     got;
        input [63:0]     exp;
        input [8*40-1:0] tag;
        begin
            checks = checks + 1;
            if (got !== exp) begin
                errors = errors + 1;
                $display("TB_FREGFILE_UNIT: ERR %0s got=%016x exp=%016x",
                         tag, got, exp);
            end
        end
    endtask

    // ---- 写入口（一拍：we=1；采样点在写优先旁路有效的那一拍内）------------
    task wr_check;
        input [4:0]  idx;
        input [63:0] val;
        begin
            @(posedge clk);
            we    <= 1'b1;
            rd    <= idx;
            wdata <= val;
            rs1   <= idx; rs2 <= idx; rs3 <= idx;   // 三读口同时命中同一号
            #1.5;                                    // 写优先：必须读到新值
            chk64(rdata1, val, "wf-bypass rdata1");
            chk64(rdata2, val, "wf-bypass rdata2");
            chk64(rdata3, val, "wf-bypass rdata3");
        end
    endtask

    // ---- 纯读采样（组合读，无写；不抖动读地址、不依赖任何提示信号）--------
    task rd_check;
        input [4:0]      i1;
        input [4:0]      i2;
        input [4:0]      i3;
        input [63:0]     e1;
        input [63:0]     e2;
        input [63:0]     e3;
        input [8*40-1:0] tag;
        begin
            rs1 = i1; rs2 = i2; rs3 = i3;
            #1;
            chk64(rdata1, e1, tag);
            chk64(rdata2, e2, tag);
            chk64(rdata3, e3, tag);
        end
    endtask

    initial begin
        we = 1'b0; rd = 5'd0; wdata = 64'd0;
        rs1 = 5'd0; rs2 = 5'd0; rs3 = 5'd0;

        // =================================================================
        // ① 复位 + 回归哨兵：**零抖动**读 f0 必须为 0
        //    （读地址自 time 0 起未变；若读口退回"函数内读数组"写法，
        //      iverilog 下这里读到 x —— 见头注 ★）
        // =================================================================
        rst_n = 1'b0;
        repeat (3) @(posedge clk);
        rst_n <= 1'b1;
        @(posedge clk); #1.5;
        rs1 = 5'd0; rs2 = 5'd0; rs3 = 5'd0;         // 与 time 0 相同：不产生抖动
        #1;
        chk64(rdata1, 64'd0, "reset f0 no-wiggle rdata1");
        chk64(rdata2, 64'd0, "reset f0 no-wiggle rdata2");
        chk64(rdata3, 64'd0, "reset f0 no-wiggle rdata3");

        for (i = 0; i < 32; i = i + 1) begin
            rd_check(i[4:0], i[4:0], i[4:0], 64'd0, 64'd0, 64'd0, "reset rdata");
        end

        // =================================================================
        // ② + ③ 逐号写入（每拍写一个号，同拍三读口命中 ⇒ 写优先旁路）
        // =================================================================
        for (i = 0; i < 32; i = i + 1) begin
            wr_check(i[4:0], pat(i[4:0]));
        end
        @(posedge clk); we <= 1'b0; #1.5;

        // =================================================================
        // ② 三读口并发核对：32 个寄存器各写唯一模式，三读口取不同索引
        //    （i, i+1, i+7 循环）⇒ 三读口互不串扰、值全对
        // =================================================================
        for (i = 0; i < 32; i = i + 1) begin
            rd_check(i[4:0], (i + 1) % 32, (i + 7) % 32,
                     pat(i[4:0]), pat((i + 1) % 32), pat((i + 7) % 32),
                     "3-port concurrent");
        end

        // =================================================================
        // ⑤ f0 是普通寄存器（非 x0 语义）：写 → 读回；再写 0 → 读回 0
        // =================================================================
        wr_check(5'd0, 64'hFFFF_FFFF_7FC0_0000);      // NaN-boxed S qNaN 位型
        @(posedge clk); we <= 1'b0; #1.5;
        // f0 读回必须是刚才写入的位型本身（若被当作 x0 恒零，这里必失败）
        rd_check(5'd0, 5'd0, 5'd0, 64'hFFFF_FFFF_7FC0_0000, 64'hFFFF_FFFF_7FC0_0000,
                 64'hFFFF_FFFF_7FC0_0000, "f0 == written");
        // 零抖动再读一次 f0（哨兵：写生效后，读地址不变也必须看到新值）
        rs1 = 5'd0; rs2 = 5'd0; rs3 = 5'd0; #1;
        chk64(rdata1, 64'hFFFF_FFFF_7FC0_0000, "f0 no-wiggle reread");
        wr_check(5'd0, 64'd0);
        @(posedge clk); we <= 1'b0; #1.5;
        rd_check(5'd0, 5'd1, 5'd2, 64'd0, pat(5'd1), pat(5'd2), "f0 == 0 after write");

        // =================================================================
        // ④ 64 位 D 视图：完整 64 位模式逐位读回（含 D qNaN payload）
        // =================================================================
        wr_check(5'd17, 64'h7FF8_0000_1234_5678);
        @(posedge clk); we <= 1'b0; #1.5;
        rd_check(5'd17, 5'd17, 5'd17, 64'h7FF8_0000_1234_5678, 64'h7FF8_0000_1234_5678,
                 64'h7FF8_0000_1234_5678, "D view qNaN payload");
        wr_check(5'd18, 64'hFFFF_FFFF_7FC0_0000);      // S 视图：NaN-box 位必须原样保存
        @(posedge clk); we <= 1'b0; #1.5;
        rd_check(5'd18, 5'd18, 5'd18, 64'hFFFF_FFFF_7FC0_0000, 64'hFFFF_FFFF_7FC0_0000,
                 64'hFFFF_FFFF_7FC0_0000, "S view NaN-box preserved");
        wr_check(5'd19, 64'h8000_0000_0000_0001);      // 符号位 + 最低位（非对称模式）
        @(posedge clk); we <= 1'b0; #1.5;
        rd_check(5'd19, 5'd16, 5'd31, 64'h8000_0000_0000_0001, pat(5'd16), pat(5'd31),
                 "D view sign+lsb");

        // =================================================================
        // ③（部分冲突）rd=5 写、rs1=5 / rs2=6 / rs3=5
        //    ⇒ 命中口给同拍新值，未命中口必须给旧值（不得整体误旁路）
        // =================================================================
        @(posedge clk);
        we <= 1'b1; rd <= 5'd5; wdata <= 64'hCAFE_F00D_0000_0005;
        rs1 <= 5'd5; rs2 <= 5'd6; rs3 <= 5'd5;
        #1.5;
        chk64(rdata1, 64'hCAFE_F00D_0000_0005, "partial wf rs1=rd");
        chk64(rdata3, 64'hCAFE_F00D_0000_0005, "partial wf rs3=rd");
        chk64(rdata2, pat(5'd6),               "partial wf rs2!=rd (old)");
        @(posedge clk); we <= 1'b0; #1.5;
        rd_check(5'd6, 5'd5, 5'd6, pat(5'd6), 64'hCAFE_F00D_0000_0005, pat(5'd6),
                 "f6 untouched / f5 committed");

        // =================================================================
        // ⑥ 写使能语义：we=0 时 rd/wdata 变化不得改变寄存器
        // =================================================================
        rd_check(5'd21, 5'd21, 5'd21, pat(5'd21), pat(5'd21), pat(5'd21), "pre we=0 probe");
        @(posedge clk);
        we <= 1'b0; rd <= 5'd21; wdata <= 64'hDEAD_BEEF_DEAD_BEEF;
        rs1 <= 5'd21; rs2 <= 5'd21; rs3 <= 5'd21;
        #1.5;
        chk64(rdata1, pat(5'd21), "we=0 no write (same cycle)");
        @(posedge clk); #1.5;
        rd_check(5'd21, 5'd21, 5'd21, pat(5'd21), pat(5'd21), pat(5'd21),
                 "we=0 no write (next cycle)");

        // =================================================================
        // ⑥ 连续两拍写同一寄存器 ⇒ 后写覆盖先写（last write wins）
        //    —— 第二拍读地址与 we/rd 都不变，只有 wdata/阵列变：函数式读口
        //       曾在这里给上一拍值（缺陷哨兵之一），内联写法必须给新值。
        // =================================================================
        @(posedge clk);
        we <= 1'b1; rd <= 5'd9; wdata <= 64'h1111_2222_3333_4444;
        rs1 <= 5'd9; rs2 <= 5'd9; rs3 <= 5'd9;
        #1.5;
        chk64(rdata1, 64'h1111_2222_3333_4444, "lww 1st (bypass)");
        @(posedge clk);
        we <= 1'b1; rd <= 5'd9; wdata <= 64'h5555_6666_7777_8888;
        rs1 <= 5'd9; rs2 <= 5'd9; rs3 <= 5'd9;
        #1.5;
        chk64(rdata1, 64'h5555_6666_7777_8888, "lww 2nd (bypass)");
        @(posedge clk); we <= 1'b0; #1.5;
        rd_check(5'd9, 5'd9, 5'd9, 64'h5555_6666_7777_8888, 64'h5555_6666_7777_8888,
                 64'h5555_6666_7777_8888, "lww committed");

        // =================================================================
        // ⑥ 写 k 的同时读 j≠k：读口给旧值、写生效
        // =================================================================
        @(posedge clk);
        we <= 1'b1; rd <= 5'd23; wdata <= 64'h0123_4567_89AB_CDEF;
        rs1 <= 5'd24; rs2 <= 5'd25; rs3 <= 5'd26;
        #1.5;
        chk64(rdata1, pat(5'd24), "cross read f24 during write f23");
        chk64(rdata2, pat(5'd25), "cross read f25 during write f23");
        chk64(rdata3, pat(5'd26), "cross read f26 during write f23");
        @(posedge clk); we <= 1'b0; #1.5;
        rd_check(5'd23, 5'd24, 5'd25, 64'h0123_4567_89AB_CDEF, pat(5'd24), pat(5'd25),
                 "f23 committed / neighbours intact");

        // =================================================================
        // ⑦ 复位可重复：再次拉低 rst_n ⇒ 已写入值全部清掉
        // =================================================================
        rst_n <= 1'b0;
        repeat (2) @(posedge clk);
        #1.5;
        for (i = 0; i < 32; i = i + 1) begin
            rd_check(i[4:0], (i + 1) % 32, i[4:0], 64'd0, 64'd0, 64'd0, "re-reset rdata");
        end
        rst_n <= 1'b1;
        @(posedge clk); #1.5;

        // =================================================================
        // 汇总
        // =================================================================
        $display("TB_FREGFILE_UNIT: checks=%0d errors=%0d", checks, errors);
        if (errors == 0) $display("TB_FREGFILE_UNIT: PASS");
        else begin
            $display("TB_FREGFILE_UNIT: FAIL errors=%0d", errors);
            $fatal;
        end
        $finish;
    end
endmodule
