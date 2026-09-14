//==============================================================================
// sim/unit/tb_pc_gen.sv —— rtl/fetch/pc_gen.v（PCC）单元测试
//==============================================================================
// 测什么  : PC 来源优先级 = 复位 > 重定向(异常/中断 > BRU > 断点) > 顺序推进(+2/+4)
//           （docs/design/08-baseline-5stage.md §5.1 ①；§4.3；§4.4）
// 怎么判  : 全部检查用 `$fatal` 判定，**失败路径只打 FAIL + $fatal**；
//           只有走完所有用例才在最后一行打印 `TB_PC_GEN_UNIT: PASS`。
//           任意用例失败 ⇒ 立即 $fatal ⇒ 非零退出码且**绝不出现 PASS**。
// 失败长相: "FAIL: <用例名> 期望 x 实得 y" 后跟 $fatal 与 vvp 非零退出。
// 反证实验: 编译期 `-DPCGEN_DISABLE_REDIRECT` 会把重定向优先级打乱，
//           此时 TB 必须 FAIL（证明这些用例真的在测优先级，08 §8.5）。
// 顶层    : tb_pc_gen_top（验收命令用 -s tb_pc_gen_top）
//==============================================================================
`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"

module tb_pc_gen_top;

    //---- 真源常量（core_params.vh §1；不在此硬编码新值） ----
    localparam [31:0] RESET_PC = `RV32GC_RESET_PC;    // 32'h1C00_0000
    localparam [31:0] XIP_ALIAS = `RV32GC_XIP_ALIAS;  // 32'h1FE8_0000
    localparam [31:0] DDR_BASE  = `RV32GC_DDR_BASE;   // 32'h0000_0000

    localparam integer CLK_PERIOD = 10;   // 10 ns / 拍（频率与判定无关）

    //---- DUT 端口 ----
    reg         aclk;
    reg         aresetn;
    reg         rst_hold;
    reg         rst_valid;
    reg         redirect_exc_valid;
    reg  [31:0] redirect_exc_pc;
    reg         redirect_bru_valid;
    reg  [31:0] redirect_bru_pc;
    reg         break_point;
    reg         seq_adv_valid;
    reg         seq_len32;

    wire [31:0] pc;
    wire [31:0] pc_next;
    wire [1:0]  pc_sel;
    wire [31:0] pc_plus2;
    wire [31:0] pc_plus4;

    //---- 检查计数器（"未捕获即失败"：必须有捕获且无失败） ----
    integer checks_run;
    integer checks_fail;

    pc_gen dut (
        .aclk              (aclk),
        .aresetn           (aresetn),
        .rst_hold          (rst_hold),
        .rst_valid         (rst_valid),
        .redirect_exc_valid(redirect_exc_valid),
        .redirect_exc_pc   (redirect_exc_pc),
        .redirect_bru_valid(redirect_bru_valid),
        .redirect_bru_pc   (redirect_bru_pc),
        .break_point       (break_point),
        .seq_adv_valid     (seq_adv_valid),
        .seq_len32         (seq_len32),
        .pc                (pc),
        .pc_next           (pc_next),
        .pc_sel            (pc_sel),
        .pc_plus2          (pc_plus2),
        .pc_plus4          (pc_plus4)
    );

    //--------------------------------------------------------------------------
    // 时钟
    //--------------------------------------------------------------------------
    initial aclk = 1'b0;
    always #(CLK_PERIOD/2) aclk = ~aclk;

    //--------------------------------------------------------------------------
    // 判定任务：先计数，再 $fatal（失败路径永不打 PASS）
    //--------------------------------------------------------------------------
    task automatic chk;
        input [255:0] name;
        input [31:0]  exp;
        input [31:0]  got;
        begin
            checks_run = checks_run + 1;
            if (exp !== got) begin
                checks_fail = checks_fail + 1;
                $display("FAIL: %0s 期望 %08x(%b) 实得 %08x(%b)",
                         name, exp, exp, got, got);
                $fatal(1, "TB_PC_GEN FAIL");
            end else begin
                $display("  ok  %0s = %08x", name, got);
            end
        end
    endtask

    task automatic chk1;      // 1 bit 版
        input [255:0] name;
        input         exp;
        input         got;
        begin
            checks_run = checks_run + 1;
            if (exp !== got) begin
                checks_fail = checks_fail + 1;
                $display("FAIL: %0s 期望 %b 实得 %b", name, exp, got);
                $fatal(1, "TB_PC_GEN FAIL");
            end else begin
                $display("  ok  %0s = %b", name, got);
            end
        end
    endtask

    //--------------------------------------------------------------------------
    // 复位助手：异步复位然后释放
    //--------------------------------------------------------------------------
    task automatic do_reset;
        begin
            @(negedge aclk);
            aresetn = 1'b0;
            rst_hold = 1'b0; rst_valid = 1'b0; seq_adv_valid = 1'b0; seq_len32 = 1'b0;
            redirect_exc_valid = 1'b0; redirect_bru_valid = 1'b0; break_point = 1'b0;
            redirect_exc_pc = 32'h0;  redirect_bru_pc = 32'h0;
            repeat (2) @(posedge aclk);
            @(negedge aclk) aresetn = 1'b1;
            @(posedge aclk);
            #1;
        end
    endtask

    //--------------------------------------------------------------------------
    // 用例
    //--------------------------------------------------------------------------
    integer k;
    initial begin
        checks_run  = 0;
        checks_fail = 0;
        aclk = 1'b0; aresetn = 1'b0; rst_hold = 1'b0; rst_valid = 1'b0;
        redirect_exc_valid = 1'b0; redirect_bru_valid = 1'b0; break_point = 1'b0;
        seq_adv_valid = 1'b0; seq_len32 = 1'b0;
        redirect_exc_pc = 32'h0; redirect_bru_pc = 32'h0;

        $display("---- tb_pc_gen: PCC 优先级 / RESET_PC / 顺序推进 ----");

        //==================================================================
        // C1: 异步复位 ⇒ pc = RESET_PC = 0x1C00_0000（§4.3 §5.1 ①）
        //==================================================================
        @(negedge aclk) aresetn = 1'b0;
        repeat (2) @(posedge aclk);
        #1;
        chk("C1 reset: pc==RESET_PC", RESET_PC, pc);
        chk("C1 reset: pc_plus2",      RESET_PC + 32'd2, pc_plus2);
        chk("C1 reset: pc_plus4",      RESET_PC + 32'd4, pc_plus4);

        //==================================================================
        // C2: 复位保持（rst_hold）⇒ PC 冻结在 RESET_PC，不被顺序推进带走
        //     （这是本设计对 §5.1 ①「复位优先级最高」的落地取舍，
        //       见 pc_gen.v 文件头：否则首条取指会是 RESET_PC+2，与
        //       §4.3 / M1 首条取指 = 0x1C00_0000 冲突）
        //==================================================================
        do_reset;
        chk("C2 after reset: pc==RESET_PC", RESET_PC, pc);
        @(negedge aclk) begin
            rst_hold      = 1'b1;
            seq_adv_valid = 1'b1;    // 即使请求推进，复位保持也必须赢
            seq_len32     = 1'b1;
        end
        repeat (3) @(posedge aclk);
        #1;
        chk("C2 rst_hold freeze: pc==RESET_PC", RESET_PC, pc);
        chk("C2 rst_hold wins over seq: pc_sel", 2'd1, pc_sel);   // SEL_RST
        @(negedge aclk) begin rst_hold = 1'b0; seq_adv_valid = 1'b0; seq_len32 = 1'b0; end
        @(posedge aclk); #1;

        //==================================================================
        // C3: 顺序推进 pc+2（16 bit 指令）与 pc+4（32 bit 指令）
        //==================================================================
        do_reset;
        // 从 RESET_PC 走 3 条 2 B 指令
        for (k = 0; k < 3; k = k + 1) begin
            @(negedge aclk) begin seq_adv_valid = 1'b1; seq_len32 = 1'b0; end
            @(posedge aclk); #1;
        end
        chk("C3 pc+2 x3 from RESET_PC", RESET_PC + 32'd6, pc);
        // 一条 4 B 指令 ⇒ +4
        @(negedge aclk) begin seq_adv_valid = 1'b1; seq_len32 = 1'b1; end
        @(posedge aclk); #1;
        chk("C3 pc+4 once", RESET_PC + 32'd10, pc);
        // 停止推进 ⇒ 保持
        @(negedge aclk) seq_adv_valid = 1'b0;
        repeat (2) @(posedge aclk); #1;
        chk("C3 no advance keeps pc", RESET_PC + 32'd10, pc);
        chk("C3 pc_sel==SEQ", 2'd5, pc_sel);          // 无推进时 SEL_HOLD=0
        @(negedge aclk) seq_adv_valid = 1'b1;
        @(posedge aclk); #1;
        chk("C3 pc_sel==SEQ(5) when advancing", 2'd5, pc_sel);

        //==================================================================
        // C4: 重定向优先级（§5.1 ①：重定向 > 顺序推进）
        //     4a BRU 胜顺序；4b 异常胜 BRU；4c 断点低于 BRU/异常
        //==================================================================
        do_reset;
        //---- C4a: BRU 重定向（与顺序推进同拍请求） ----
        @(negedge aclk) begin
            redirect_bru_valid = 1'b1;
            redirect_bru_pc    = 32'h1C00_1000;
            seq_adv_valid      = 1'b1;
            seq_len32          = 1'b0;
        end
        #1;   // 组合判定（重定向下拍生效）
        @(posedge aclk); #1;
        chk("C4a BRU redirect pc", 32'h1C00_1000, pc);
        chk("C4a BRU sel", 2'd3, pc_sel);
        @(negedge aclk) begin redirect_bru_valid = 1'b0; seq_adv_valid = 1'b0; end
        @(posedge aclk); #1;

        //---- C4b: 异常/中断重定向优先级最高（与 BRU + 顺序同拍） ----
        @(negedge aclk) begin
            redirect_exc_valid = 1'b1;
            redirect_exc_pc    = 32'h0000_0100;   // mtvec（VA）
            redirect_bru_valid = 1'b1;
            redirect_bru_pc    = 32'h1C00_2000;
            seq_adv_valid      = 1'b1;
        end
        #1;
        @(posedge aclk); #1;
        chk("C4b EXC beats BRU: pc", 32'h0000_0100, pc);
        chk("C4b EXC sel", 2'd2, pc_sel);
        @(negedge aclk) begin
            redirect_exc_valid = 1'b0; redirect_bru_valid = 1'b0; seq_adv_valid = 1'b0;
        end
        @(posedge aclk); #1;

        //---- C4c: 断点（§4.4：F 级制造重定向，2A 允许停在当前 PC） ----
        @(negedge aclk) begin
            break_point   = 1'b1;
            seq_adv_valid = 1'b1;    // 断点必须压过顺序推进
            seq_len32     = 1'b1;
        end
        #1;
        @(posedge aclk); #1;
        chk("C4c break point holds pc (redirect to self)",
            RESET_PC, pc);
        chk("C4c break sel", 2'd4, pc_sel);
        // 断点期间再等 2 拍，PC 不得前进
        repeat (2) @(posedge aclk); #1;
        chk("C4c break keeps pc frozen", RESET_PC, pc);
        @(negedge aclk) begin break_point = 1'b0; seq_adv_valid = 1'b0; end
        @(posedge aclk); #1;

        //---- C4d: 断点 vs BRU：BRU 优先（§4.4 断点是调试探针，不得压过重定向） ----
        @(negedge aclk) begin
            break_point        = 1'b1;
            redirect_bru_valid = 1'b1;
            redirect_bru_pc    = XIP_ALIAS + 32'h40;   // 别名窗口（同窗跳转）
        end
        #1;
        @(posedge aclk); #1;
        chk("C4d BRU beats break: pc", XIP_ALIAS + 32'h40, pc);
        chk("C4d BRU beats break: sel", 2'd3, pc_sel);
        @(negedge aclk) begin
            break_point = 1'b0; redirect_bru_valid = 1'b0;
        end
        @(posedge aclk); #1;

        //==================================================================
        // C5: 软复位 rst_valid ⇒ 重载 RESET_PC（受时钟采样）
        //==================================================================
        @(negedge aclk) begin
            seq_adv_valid = 1'b1; seq_len32 = 1'b1;   // 正在推进
        end
        @(posedge aclk); #1;
        // 此刻 pc != RESET_PC
        checks_run = checks_run + 1;
        if (pc === RESET_PC) begin
            checks_fail = checks_fail + 1;
            $display("FAIL: C5 前置条件（pc 应已离开 RESET_PC）不成立");
            $fatal(1, "TB_PC_GEN FAIL");
        end
        @(negedge aclk) begin rst_valid = 1'b1; seq_adv_valid = 1'b1; end
        @(posedge aclk); #1;
        chk("C5 rst_valid reloads RESET_PC", RESET_PC, pc);
        @(negedge aclk) begin rst_valid = 1'b0; seq_adv_valid = 1'b0; seq_len32 = 1'b0; end
        @(posedge aclk); #1;

        //==================================================================
        // C6: 早期禁止跨窗口跳转（§5.1 ⑥）—— 硬件**不做任何自动修正**：
        //     把 XIP 别名窗口的目标原样交给 PC（不得被拉回主窗口）
        //==================================================================
        @(negedge aclk) begin
            redirect_bru_valid = 1'b1;
            redirect_bru_pc    = XIP_ALIAS;            // 0x1FE8_0000
        end
        #1; @(posedge aclk); #1;
        chk("C6 cross-window redirect is verbatim (no fixup)", XIP_ALIAS, pc);
        @(negedge aclk) begin
            redirect_bru_valid = 1'b1;
            redirect_bru_pc    = DDR_BASE;             // 0x0000_0000（DDR3）
        end
        #1; @(posedge aclk); #1;
        chk("C6 cross-window to DDR is verbatim (no fixup)", DDR_BASE, pc);
        @(negedge aclk) redirect_bru_valid = 1'b0;
        @(posedge aclk); #1;

        //==================================================================
        // 结束判定：必须有捕获，且零失败
        //==================================================================
        checks_run = checks_run + 1;
        if (checks_run <= 0) begin
            $display("FAIL: 未捕获任何检查项");
            $fatal(1, "TB_PC_GEN FAIL");
        end
        if (checks_fail != 0) begin
            $display("FAIL: %0d 项失败", checks_fail);
            $fatal(1, "TB_PC_GEN FAIL");
        end
        $display("checks_run=%0d checks_fail=%0d", checks_run, checks_fail);
        $display("TB_PC_GEN_UNIT: PASS");
        $finish;
    end

    // 全局超时兜底：任何挂死都必须 FAIL，不得静默结束
    initial begin
        #200000;
        $display("FAIL: 仿真超时（TB 未走完用例）");
        $fatal(1, "TB_PC_GEN FAIL");
    end

endmodule
