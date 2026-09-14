//==============================================================================
// sim/unit/tb_l1i.sv —— L1I 单元测试（命中/缺失/回填/XIP 旁路不分配）
//==============================================================================
// 项目  : rv32gc-cpu（阶段二 2A）
// 归属  : docs/design/08-baseline-5stage.md §8.1；05-cache-memory.md §5.2/§8
// 顶层  : tb_l1i_top（验收命令 -s tb_l1i_top）
//
// 判定纪律（08 §8.1 fail-closed，最高纪律）：
//   ① 起始 RESULT=fail；只有走完全部检查才置 pass。
//   ② 兜底/默认输出**不含 PASS 字样**（只打 FAIL/UNKNOWN）。
//   ③ 退出码由显式计数器决定：捕获数 > 0 且 失败数 == 0。
//   ④ 正则成对（本 TB 不用外部 grep，直接内部计数）。
//   ⑤ 唯一 PASS 字样是最后一行 `TB_L1I_UNIT: PASS`。
//
// 覆盖（对应任务验收判据③ tb_l1i 部分）：
//   C1 命中：填入一行后同地址命中，1 拍返回、数据正确
//   C2 缺失：未填入的地址 ⇒ cs_miss=1、cs_ready=0、发起 fill_req
//   C3 回填：逐 beat 回填 8 拍后，再访问 ⇒ 命中且数据正确（行内 8 字全对）
//   C4 XIP 旁路：PA 命中 XIP 窗口 ⇒ cs_uncached=1、**不发起 fill_req**
//               （即"不分配"：不写 Tag/Data 阵列，不驱动总线）
//   C5 XIP 别名窗口（0x1FE8_xxxx）同样旁路
//   C6 失效：inval_all 后再访问 ⇒ 未命中
//   C7 伪 LRU：连续访问同一组两个不同 tag，第 3 行缺失应替换较老的一路
//==============================================================================
`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"

module tb_l1i_top;

    //--------------------------------------------------------------------------
    // 检查计数（fail-closed 核心）
    //--------------------------------------------------------------------------
    integer checks_run;
    integer checks_failed;
    integer checks_passed;

    task automatic chk(input logic cond, input string name);
        begin
            checks_run = checks_run + 1;
            if (cond) begin
                checks_passed = checks_passed + 1;
            end else begin
                checks_failed = checks_failed + 1;
                $display("  [FAIL] %0s", name);
            end
        end
    endtask

    //--------------------------------------------------------------------------
    // 时钟/复位
    //--------------------------------------------------------------------------
    logic clk;
    logic rst_n;
    initial clk = 1'b0;
    always #5 clk = ~clk;

    //--------------------------------------------------------------------------
    // DUT 信号
    //--------------------------------------------------------------------------
    logic         cs_req;
    logic [31:0]  cs_paddr;
    logic [31:0]  cs_vaddr;
    logic         cs_ready;
    logic [31:0]  cs_rdata;
    logic         cs_uncached;
    logic         cs_miss;

    logic         fill_req;
    logic [31:0]  fill_paddr;
    logic [1:0]   fill_owner;
    logic [4:0]   fill_beats;
    logic         fill_accepted;
    logic         fill_valid;
    logic [31:0]  fill_data;
    logic [4:0]   fill_word_idx;
    logic         fill_done;
    logic         inval_all;
    logic         idle;

    l1i dut (
        .clk           (clk),
        .rst_n         (rst_n),
        .cs_req        (cs_req),
        .cs_paddr      (cs_paddr),
        .cs_vaddr      (cs_vaddr),
        .cs_ready      (cs_ready),
        .cs_rdata      (cs_rdata),
        .cs_uncached   (cs_uncached),
        .cs_miss       (cs_miss),
        .fill_req      (fill_req),
        .fill_paddr    (fill_paddr),
        .fill_owner    (fill_owner),
        .fill_beats    (fill_beats),
        .fill_accepted (fill_accepted),
        .fill_valid    (fill_valid),
        .fill_data     (fill_data),
        .fill_word_idx (fill_word_idx),
        .fill_done     (fill_done),
        .inval_all     (inval_all),
        .idle          (idle)
    );

    //--------------------------------------------------------------------------
    // 辅助任务
    //--------------------------------------------------------------------------
    // 复位
    task automatic do_reset;
        begin
            rst_n        = 1'b0;
            cs_req       = 1'b0;
            cs_paddr     = 32'h0;
            cs_vaddr     = 32'h0;
            fill_accepted= 1'b0;
            fill_valid   = 1'b0;
            fill_data    = 32'h0;
            fill_word_idx= 5'h0;
            fill_done    = 1'b0;
            inval_all    = 1'b0;
            repeat (3) @(posedge clk);
            rst_n = 1'b1;
            @(posedge clk);
        end
    endtask

    // 发起一次取指访问（vaddr/paddr），返回时 cs_* 已稳定
    task automatic issue(input logic [31:0] va, input logic [31:0] pa);
        begin
            @(negedge clk);
            cs_req   = 1'b1;
            cs_vaddr = va;
            cs_paddr = pa;
        end
    endtask

    // 撤销请求
    task automatic drop_req;
        begin
            @(negedge clk);
            cs_req = 1'b0;
        end
    endtask

    // 走完一次 8-beat 行填充（数据按 base+4*i 生成）
    task automatic do_fill(input logic [31:0] line_base);
        integer k;
        begin
            // 等待填充请求
            wait (fill_req === 1'b1);
            chk(fill_paddr == line_base, "fill_paddr 应为行基址");
            chk(fill_owner == 2'd0, "fill_owner 应为 0（I-Cache 填充）");
            chk(fill_beats == 5'd7, "fill_beats 应为 7（8 beat）");
            // 接受
            @(negedge clk);
            fill_accepted = 1'b1;
            @(posedge clk);
            @(negedge clk);
            fill_accepted = 1'b0;
            // 逐 beat 回填
            for (k = 0; k < 8; k = k + 1) begin
                fill_valid    = 1'b1;
                fill_data     = 32'hA000_0000 | {24'h0, line_base[7:0]} | k;
                fill_word_idx = k[4:0];
                fill_done     = (k == 7);
                @(posedge clk);
                @(negedge clk);
            end
            fill_valid = 1'b0;
            fill_done  = 1'b0;
            @(posedge clk);
        end
    endtask

    //--------------------------------------------------------------------------
    // 主测试
    //--------------------------------------------------------------------------
    logic [31:0] base_va, base_pa;
    integer      k;

    initial begin
        checks_run    = 0;
        checks_failed = 0;
        checks_passed = 0;

        $display("---- tb_l1i: L1I 单元测试（16 KB / 2 路 / 32 B 行）----");

        do_reset();

        //======================================================================
        // C1 + C2：缺失 → 发起填充 → 回填 → 命中
        //======================================================================
        // 物理地址 0x0000_1000 为行基址；访问行内字 3
        base_va = 32'h0000_1000;
        base_pa = 32'h0000_1000;

        // ---- C2 缺失 ----
        issue(base_va + 32'h0C, base_pa + 32'h0C);
        @(posedge clk);              // S0 末
        #1;
        chk(cs_miss   === 1'b1, "C2 缺失：cs_miss 应为 1");
        chk(cs_ready  === 1'b0, "C2 缺失：cs_ready 应为 0");
        chk(cs_uncached === 1'b0, "C2 DDR 地址不应为 uncached");
        chk(fill_req  === 1'b1, "C2 缺失应发起 fill_req");

        // ---- C3 回填 ----
        do_fill(base_pa);

        // ---- C1 命中（1 拍返回 + 数据正确） ----
        // 释放请求，重新访问同一地址
        drop_req();
        repeat (2) @(posedge clk);
        issue(base_va + 32'h0C, base_pa + 32'h0C);
        @(posedge clk);
        #1;
        chk(cs_miss  === 1'b0, "C1 回填后应命中");
        chk(cs_ready === 1'b1, "C1 命中应 cs_ready=1");

        // ---- 行内 8 字全部可命中且数据正确 ----
        for (k = 0; k < 8; k = k + 1) begin
            drop_req();
            repeat (2) @(posedge clk);
            issue(base_va + k[31:0] * 4, base_pa + k[31:0] * 4);
            @(posedge clk);
            #1;
            chk(cs_ready === 1'b1, $sformatf("行内字 %0d 应命中", k));
            chk(cs_rdata === (32'hA000_0000 | {24'h0, base_pa[7:0]} | k),
                $sformatf("行内字 %0d 数据应正确", k));
        end
        drop_req();
        repeat (2) @(posedge clk);

        //======================================================================
        // C4：XIP 旁路（不分配）
        //======================================================================
        // XIP 主窗口 0x1C00_0000
        issue(32'h1C00_0000, 32'h1C00_0000);
        @(posedge clk);
        #1;
        chk(cs_uncached === 1'b1, "C4 XIP 主窗口应 uncached=1");
        chk(fill_req    === 1'b0, "C4 XIP 旁路**不得**发起 fill_req（不分配）");
        chk(cs_ready    === 1'b0, "C4 XIP 旁路不经 Cache ⇒ cs_ready=0");
        drop_req();
        repeat (2) @(posedge clk);
        chk(idle === 1'b1, "C4 XIP 旁路后应保持 idle（无在途事务）");

        //======================================================================
        // C5：XIP 别名窗口 0x1FE8_xxxx
        //======================================================================
        issue(32'h1FE8_0010, 32'h1FE8_0010);
        @(posedge clk);
        #1;
        chk(cs_uncached === 1'b1, "C5 XIP 别名窗口应 uncached=1");
        chk(fill_req    === 1'b0, "C5 XIP 别名**不得**发起 fill_req");
        drop_req();
        repeat (2) @(posedge clk);

        // ---- XIP 未污染 Cache：原 DDR 行仍应命中 ----
        issue(base_va + 32'h0C, base_pa + 32'h0C);
        @(posedge clk);
        #1;
        chk(cs_ready === 1'b1, "C5 XIP 旁路不得淘汰/污染已填充行");
        drop_req();
        repeat (2) @(posedge clk);

        //======================================================================
        // C6：inval_all 后再访问 ⇒ 未命中
        //======================================================================
        @(negedge clk);
        inval_all = 1'b1;
        @(posedge clk);
        @(negedge clk);
        inval_all = 1'b0;
        repeat (2) @(posedge clk);

        issue(base_va + 32'h0C, base_pa + 32'h0C);
        @(posedge clk);
        #1;
        chk(cs_miss === 1'b1, "C6 inval_all 后应重新缺失");
        // 收尾：完成这次填充，避免悬挂在途
        do_fill(base_pa);
        drop_req();
        repeat (2) @(posedge clk);

        //======================================================================
        // C7：伪 LRU 替换（同组两路，第 3 个 tag 应替换较老的一路）
        //    同组 = 索引相同、tag 不同 ⇒ 地址高位不同、VA[12:5] 相同
        //======================================================================
        begin
            logic [31:0] va_a, va_b, va_c, pa_a, pa_b, pa_c;
            // 组索引位 VA[12:5] = 0x08 ⇒ 地址低 13 位 = 0x0100
            va_a = 32'h0010_0100;   // tag 不同（bit 20）
            va_b = 32'h0020_0100;
            va_c = 32'h0030_0100;
            pa_a = va_a; pa_b = va_b; pa_c = va_c;

            // 填 A
            issue(va_a, pa_a);
            @(posedge clk); #1;
            do_fill(pa_a);
            drop_req(); repeat (2) @(posedge clk);
            // 命中 A（way0 成为"最近使用"，way1 为 LRU）
            issue(va_a, pa_a); @(posedge clk); #1;
            chk(cs_ready === 1'b1, "C7 行 A 应命中");
            drop_req(); repeat (2) @(posedge clk);
            // 填 B（应在 way1）
            issue(va_b, pa_b); @(posedge clk); #1;
            do_fill(pa_b);
            drop_req(); repeat (2) @(posedge clk);
            // 命 A（保护 way0）⇒ LRU 应是 way1
            issue(va_a, pa_a); @(posedge clk); #1;
            chk(cs_ready === 1'b1, "C7 行 A 应仍命中");
            drop_req(); repeat (2) @(posedge clk);
            // 访问 C（缺失）⇒ 应替换 way1（B），A 仍命中
            issue(va_c, pa_c); @(posedge clk); #1;
            chk(cs_miss === 1'b1, "C7 行 C 应缺失");
            do_fill(pa_c);
            drop_req(); repeat (2) @(posedge clk);
            // A 应存活（未被替换）
            issue(va_a, pa_a); @(posedge clk); #1;
            chk(cs_ready === 1'b1, "C7 伪 LRU：A 应未被替换（最近使用路受保护）");
            drop_req(); repeat (2) @(posedge clk);
        end

        //======================================================================
        // 判定（fail-closed）：唯一 PASS 字样
        //======================================================================
        drop_req();
        repeat (2) @(posedge clk);

        $display("---- tb_l1i 检查统计: run=%0d passed=%0d failed=%0d ----",
                 checks_run, checks_passed, checks_failed);

        if (checks_run == 0) begin
            $display("TB_L1I_UNIT: FAIL (no checks executed)");
            $fatal(1, "fail-closed: 未执行任何检查");
        end
        if (checks_failed != 0) begin
            $display("TB_L1I_UNIT: FAIL (%0d/%0d checks failed)",
                     checks_failed, checks_run);
            $fatal(1, "fail-closed: 存在失败检查");
        end
        if (checks_passed != checks_run) begin
            $display("TB_L1I_UNIT: FAIL (passed != run)");
            $fatal(1, "fail-closed: 计数不一致");
        end

        $display("TB_L1I_UNIT: PASS");
        $finish;
    end

    //--------------------------------------------------------------------------
    // 全局超时兜底：超时 ⇒ 明确 FAIL（且不含 PASS 字样）
    //--------------------------------------------------------------------------
    initial begin
        #200000;
        $display("TB_L1I_UNIT: FAIL (timeout)");
        $fatal(1, "fail-closed: 仿真超时");
    end

endmodule
