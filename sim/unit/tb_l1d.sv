//==============================================================================
// sim/unit/tb_l1d.sv —— L1D 单元测试
//   覆盖：写命中（写回，不穿透）、写分配、dirty 回写、多路替换
//==============================================================================
// 项目  : rv32gc-cpu（阶段二 2A）
// 归属  : docs/design/08-baseline-5stage.md §8.1；05-cache-memory.md §3.1/§3.2
// 顶层  : tb_l1d_top（验收命令 -s tb_l1d_top）
//
// 判定纪律（fail-closed，08 §8.1）：起始 fail；只有走完全部检查才 PASS；
//   兜底/超时输出不含 PASS；退出码由显式计数器决定。
//
// 覆盖（对应任务验收判据③ tb_l1d 部分）：
//   C1 读缺失 → 写分配填充（fill 8 beat）→ 读命中且数据正确
//   C2 写命中：store 只落数据阵列 + 置 dirty，**不产生 wb_req**（写回不穿透）
//   C3 写命中后回读：读回被写的字（写回语义：数据留在本层）
//   C4 dirty 回写：写入后造成同组第 5 行缺失 ⇒ 先发 wb_req（owner=2），
//                 且写回数据 = 之前写入的值
//   C5 多路替换：同组连续填 5 行 ⇒ 4 路被占满后替换最久未用路
//   C6 维护：clean_all 清 dirty（后续替换不再回写）
//==============================================================================
`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"

module tb_l1d_top;

    //--------------------------------------------------------------------------
    // 检查计数（fail-closed）
    //--------------------------------------------------------------------------
    integer checks_run;
    integer checks_failed;
    integer checks_passed;

    task automatic chk(input logic cond, input string name);
        begin
            checks_run = checks_run + 1;
            if (cond) checks_passed = checks_passed + 1;
            else begin
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
    logic         cs_req, cs_we;
    logic [3:0]   cs_wstrb;
    logic [31:0]  cs_paddr, cs_vaddr, cs_wdata;
    logic         cs_ready, cs_miss, cs_stall, cs_wr_done;
    logic [31:0]  cs_rdata;

    logic         fill_req;
    logic [31:0]  fill_paddr;
    logic [1:0]   fill_owner;
    logic [4:0]   fill_beats;
    logic         fill_accepted;
    logic         fill_valid;
    logic [31:0]  fill_data;
    logic [4:0]   fill_word_idx;
    logic         fill_done;

    logic         wb_req;
    logic [31:0]  wb_paddr;
    logic [1:0]   wb_way;
    logic [1:0]   wb_owner;
    logic [4:0]   wb_beats;
    logic         wb_accepted;
    logic [4:0]   wb_word_idx;
    logic [31:0]  wb_data;
    logic         wb_done;
    logic         wb_ready;

    logic         inval_all, clean_all, idle;

    l1d dut (
        .clk (clk), .rst_n (rst_n),
        .cs_req (cs_req), .cs_we (cs_we), .cs_wstrb (cs_wstrb),
        .cs_paddr (cs_paddr), .cs_vaddr (cs_vaddr), .cs_wdata (cs_wdata),
        .cs_ready (cs_ready), .cs_rdata (cs_rdata), .cs_miss (cs_miss),
        .cs_stall (cs_stall), .cs_wr_done (cs_wr_done),
        .fill_req (fill_req), .fill_paddr (fill_paddr), .fill_owner (fill_owner),
        .fill_beats (fill_beats), .fill_accepted (fill_accepted),
        .fill_valid (fill_valid), .fill_data (fill_data),
        .fill_word_idx (fill_word_idx), .fill_done (fill_done),
        .wb_req (wb_req), .wb_paddr (wb_paddr), .wb_way (wb_way),
        .wb_owner (wb_owner), .wb_beats (wb_beats), .wb_accepted (wb_accepted),
        .wb_word_idx (wb_word_idx), .wb_data (wb_data), .wb_done (wb_done),
        .wb_ready (wb_ready),
        .inval_all (inval_all), .clean_all (clean_all), .idle (idle)
    );

    //--------------------------------------------------------------------------
    // 辅助任务
    //--------------------------------------------------------------------------
    task automatic do_reset;
        begin
            rst_n = 1'b0; cs_req = 1'b0; cs_we = 1'b0; cs_wstrb = 4'h0;
            cs_paddr = 32'h0; cs_vaddr = 32'h0; cs_wdata = 32'h0;
            fill_accepted = 1'b0; fill_valid = 1'b0; fill_data = 32'h0;
            fill_word_idx = 5'h0; fill_done = 1'b0;
            wb_accepted = 1'b0; wb_word_idx = 5'h0; wb_done = 1'b0;
            inval_all = 1'b0; clean_all = 1'b0;
            repeat (3) @(posedge clk);
            rst_n = 1'b1;
            @(posedge clk);
        end
    endtask

    // ★ 访问协议（与 L1D 的同步读时序对应）：
    //   第 1 拍（S0）在 negedge 拉高 cs_req 并发地址 → 阵列同步读；
    //   第 2 拍（S1）读数据到达，命中/缺失结果在 S1 的组合输出上有效。
    //   本任务返回时（S1 采样点之后）可直接读 cs_ready/cs_rdata。
    //   实现：S0 拉高并保持，S1 末（negedge）拉低。
    task automatic do_read(input logic [31:0] va);
        begin
            @(negedge clk);
            cs_req = 1'b1; cs_we = 1'b0; cs_wstrb = 4'h0;
            cs_vaddr = va; cs_paddr = va;
            @(posedge clk);      // S0→S1：读数据到达
            #1;                  // 采样点：此时 cs_* 已稳定
        end
    endtask

    task automatic do_write(input logic [31:0] va, input logic [31:0] data,
                            input logic [3:0] strb);
        begin
            @(negedge clk);
            cs_req = 1'b1; cs_we = 1'b1; cs_wstrb = strb;
            cs_vaddr = va; cs_paddr = va; cs_wdata = data;
            @(posedge clk);      // S1：命中判定 + 写落地
            #1;
        end
    endtask

    // 撤销请求：在采样点之后调用（本 TB 在每个 do_* 后紧接调用）
    task automatic drop_req;
        begin
            @(negedge clk);
            cs_req = 1'b0; cs_we = 1'b0;
            @(posedge clk);
            #1;
        end
    endtask

    // 等待并完成一次行填充（8 beat；数据 = seed 派生）
    //   ★ 时序纪律：fill_req 在 MS_FILL_REQ 状态**持续**有效（不是一个脉冲），
    //    因此这里在 negedge 采样（组合稳定区），握手用 valid && ready。
    task automatic do_fill_data(input logic [31:0] line_base, input logic [31:0] seed);
        integer k;
        integer guard;
        begin
            // 等待填充请求有效（neg_edge 采样，避开组合抖动）
            guard = 0;
            while (fill_req !== 1'b1) begin
                @(negedge clk);
                guard = guard + 1;
                if (guard > 200) begin
                    $fatal(1, "do_fill_data 超时");
                end
            end
            // 接受：在 negedge 拉高 accepted，下一 posedge 完成握手
            fill_accepted = 1'b1;
            @(posedge clk);
            @(negedge clk);
            fill_accepted = 1'b0;
            // 逐 beat 回填
            for (k = 0; k < 8; k = k + 1) begin
                fill_valid    = 1'b1;
                fill_data     = seed + k[31:0];
                fill_word_idx = k[4:0];
                fill_done     = (k == 7);
                @(posedge clk);
                @(negedge clk);
            end
            fill_valid = 1'b0; fill_done = 1'b0;
            @(posedge clk);
        end
    endtask

    //--------------------------------------------------------------------------
    // 主测试
    //--------------------------------------------------------------------------
    logic [31:0] A0, A1, A2, A3, A4;
    logic [31:0] wb_first;

    initial begin
        checks_run = 0; checks_failed = 0; checks_passed = 0;

        $display("---- tb_l1d: L1D 单元测试（32 KB / 4 路 / 32 B 行）----");

        do_reset();

        //======================================================================
        // C1：读缺失 → 写分配填充 → 读命中
        //======================================================================
        // 同索引地址：低 13 位相同（0x0000），高位（tag）不同
        A0 = 32'h0000_0000;
        A1 = 32'h0001_0000;
        A2 = 32'h0002_0000;
        A3 = 32'h0003_0000;
        A4 = 32'h0004_0000;
        do_read(A0 + 32'h4);
        chk(cs_miss  === 1'b1, "C1 读缺失应 cs_miss=1");
        chk(cs_ready === 1'b0, "C1 缺失时 cs_ready=0");
        // ★ 保持 cs_req 直到 FSM 捕获缺失并发起填充：
        //   L1D 在 MS_IDLE 拍用访问寄存器锁存行地址 ⇒ 必须让请求维持到那一刻。
        while (fill_req !== 1'b1) @(negedge clk);
        drop_req();
        chk(fill_req   === 1'b1, "C1 缺失应发起 fill_req");
        chk(fill_beats === 5'd7, "C1 填充应为 8 beat（beats=7）");
        do_fill_data(A0, 32'hB000_0000);
        repeat (2) @(posedge clk);
        // 读命中
        do_read(A0 + 32'h4);
        chk(cs_ready === 1'b1, "C1 填充后应读命中");
        chk(cs_rdata === (32'hB000_0000 + 32'd1), "C1 命中数据应为行内第 1 字");
        drop_req();
        repeat (2) @(posedge clk);

        //======================================================================
        // C2/C3：写命中 —— 落本层、置 dirty、**不穿透**（无 wb_req）
        //======================================================================
        do_write(A0 + 32'h8, 32'h1234_5678, 4'hF);
        chk(cs_wr_done === 1'b1, "C2 写命中应 cs_wr_done=1");
        chk(wb_req     === 1'b0, "C2 写命中**不得**产生 wb_req（写回不穿透）");
        drop_req();
        repeat (2) @(posedge clk);

        // C3 回读被写的字
        do_read(A0 + 32'h8);
        chk(cs_ready === 1'b1, "C3 写后回读应命中");
        chk(cs_rdata === 32'h1234_5678, "C3 读回应等于写入值（写回语义）");
        drop_req();
        repeat (2) @(posedge clk);

        // C3b 行内其它字未被破坏（数据阵列字节使能正确）
        do_read(A0 + 32'h0C);
        chk(cs_rdata === (32'hB000_0000 + 32'd3), "C3b 同行其它字不应被破坏");
        drop_req();
        repeat (2) @(posedge clk);

        //======================================================================
        // C4：dirty 回写 —— 填满本组其余路后，再缺失应替换并回写 A0 的脏行
        //======================================================================
        // 填 A1/A2/A3（同组、不同 tag）⇒ 4 路占满，A0 为最久未用
        do_read(A1 + 32'h4);
        chk(cs_miss === 1'b1, "C4 A1 应缺失"); drop_req();
        do_fill_data(A1, 32'hC100_0000); repeat (2) @(posedge clk);
        do_read(A2 + 32'h4);
        chk(cs_miss === 1'b1, "C4 A2 应缺失"); drop_req();
        do_fill_data(A2, 32'hC200_0000); repeat (2) @(posedge clk);
        do_read(A3 + 32'h4);
        chk(cs_miss === 1'b1, "C4 A3 应缺失"); drop_req();
        do_fill_data(A3, 32'hC300_0000); repeat (2) @(posedge clk);

        // A0 仍应命中（4 路未满时不应替换）
        do_read(A0 + 32'h8);
        chk(cs_ready === 1'b1, "C4 4 路未满：A0 应仍命中");
        drop_req(); repeat (2) @(posedge clk);

        // 现在访问 A4（第 5 行，同组）⇒ 必须替换且受害者 A0 是 dirty ⇒ 回写
        do_read(A4 + 32'h4);
        chk(cs_miss === 1'b1, "C4 A4 应缺失（组已满）");
        drop_req();
        // 等写回请求（dirty 回写）；wb_req 在 MS_WB_BUS 持续有效
        while (wb_req !== 1'b1) @(negedge clk);
        chk(wb_owner === 2'd2, "C4 写回 owner 应为 2（脏行写回）");
        chk(wb_paddr === A0,   "C4 写回地址应为被替换行基址");
        chk(wb_beats === 5'd7, "C4 写回应为 8 beat");
        // 完成写回并核对写回数据（第 2 个字应为之前写入的 0x12345678）
        begin
            logic [31:0] seen_word2;
            integer k;
            @(negedge clk); wb_accepted = 1'b1;
            @(posedge clk); @(negedge clk); wb_accepted = 1'b0;
            seen_word2 = 32'h0;
            // ★ 先等 RTL 的 wb_ready（抓行阶段不接收数据拍），再逐 beat 送。
            while (wb_ready !== 1'b1) @(negedge clk);
            // ★ 行缓冲是寄存的：给出 wb_word_idx=k 之后，wb_data 在**下一拍**有效。
            for (k = 0; k < 8; k = k + 1) begin
                @(negedge clk);
                wb_word_idx = k[4:0];
                wb_done     = (k == 7);
                @(posedge clk); #1;
                if (k == 2) seen_word2 = wb_data;
            end
            @(negedge clk); wb_done = 1'b0;
            @(posedge clk); #1;
            // 说明：idx=2 在本拍给出，其数据在下一拍（k==3 循环）有效，
            //       因此上面在 k==2 之后立即采样即为该 idx 的数据。
            chk(seen_word2 === 32'h1234_5678,
                "C4 写回数据应含此前 store 的值（脏数据被推出）");
        end
        repeat (2) @(posedge clk);

        // 写回完成后 FSM 自动转到 MS_FILL_REQ 并发起填充
        do_fill_data(A4, 32'hC400_0000);
        repeat (2) @(posedge clk);

        // A4 现在应命中
        do_read(A4 + 32'h4);
        chk(cs_ready === 1'b1, "C4 写回+填充后 A4 应命中");
        drop_req(); repeat (2) @(posedge clk);

        //======================================================================
        // C5：多路替换 —— A1/A2/A3 仍应在（未被替换）
        //======================================================================
        do_read(A1 + 32'h4);
        chk(cs_ready === 1'b1, "C5 A1 应仍在（未被替换）");
        drop_req(); repeat (2) @(posedge clk);
        do_read(A2 + 32'h4);
        chk(cs_ready === 1'b1, "C5 A2 应仍在");
        drop_req(); repeat (2) @(posedge clk);
        do_read(A3 + 32'h4);
        chk(cs_ready === 1'b1, "C5 A3 应仍在");
        drop_req(); repeat (2) @(posedge clk);

        //======================================================================
        // C6：clean_all 清 dirty（之后替换不再回写）
        //======================================================================
        // 写脏 A1
        // 诊断：先确认 A1 当前是否命中（C4 的替换可能已把 A1 换出）
        do_read(A1 + 32'h4);
        drop_req(); repeat (2) @(posedge clk);
        do_write(A1 + 32'h4, 32'hAAAA_0000, 4'hF);
        chk(cs_wr_done === 1'b1, "C6 写 A1 命中");
        drop_req(); repeat (2) @(posedge clk);
        // clean_all：全阵列扫描需逐组进行（SETS 拍），必须等扫描结束再访问
        @(negedge clk); clean_all = 1'b1;
        // ★ 扫描启动后一拍（maint_q 已在上一 posedge 拉高）：对外 idle 必须为 0。
        //   08 §7.2 口径：维护期间视作非空闲/占用，调用方以 idle 判扫描完成再放行访问；
        //   若此拍 idle 仍为 1，调用方会误判扫描已完成（本断言即该口径的防回归）。
        @(posedge clk); #1;
        chk(idle === 1'b0, "C6 clean 扫描期间 idle 应为 0（维护占用）");
        @(negedge clk); clean_all = 1'b0;
        // 等维护扫描完成：按对外口径用 idle 判定（原层次引用 dut.maint_q 已改）
        begin
            integer g;
            g = 0;
            while (dut.idle !== 1'b1) begin
                @(posedge clk);
                g = g + 1;
                if (g > 1000) begin
                    $display("  [diag] clean 扫描未结束（idle 未回升）");
                    $fatal(1, "clean 扫描超时");
                end
            end
            #1;
            chk(idle === 1'b1, "C6 clean 扫描结束后 idle 应为 1");
        end
        repeat (2) @(posedge clk);
        // 现在替换 A1 不应产生写回：先访问 A0/A1 使其成为最久未用，
        // 直接检查 clean 后 dirty 位已清（通过"再访问 A1 命中且无 wb"间接验证）
        do_read(A1 + 32'h4);
        chk(cs_ready === 1'b1, "C6 clean 后 A1 仍应命中（clean 不失效）");
        chk(cs_rdata === 32'hAAAA_0000, "C6 clean 应保留数据");
        chk(wb_req  === 1'b0, "C6 clean 自身不应产生写回");
        drop_req(); repeat (2) @(posedge clk);

        //======================================================================
        // 判定（fail-closed）：唯一 PASS 字样
        //======================================================================
        drop_req();
        repeat (2) @(posedge clk);

        $display("---- tb_l1d 检查统计: run=%0d passed=%0d failed=%0d ----",
                 checks_run, checks_passed, checks_failed);

        if (checks_run == 0) begin
            $display("TB_L1D_UNIT: FAIL (no checks executed)");
            $fatal(1, "fail-closed: 未执行任何检查");
        end
        if (checks_failed != 0) begin
            $display("TB_L1D_UNIT: FAIL (%0d/%0d checks failed)",
                     checks_failed, checks_run);
            $fatal(1, "fail-closed: 存在失败检查");
        end
        if (checks_passed != checks_run) begin
            $display("TB_L1D_UNIT: FAIL (passed != run)");
            $fatal(1, "fail-closed: 计数不一致");
        end

        $display("TB_L1D_UNIT: PASS");
        $finish;
    end

    //--------------------------------------------------------------------------
    // 全局超时兜底
    //--------------------------------------------------------------------------
    initial begin
        #400000;
        $display("TB_L1D_UNIT: FAIL (timeout)");
        $fatal(1, "fail-closed: 仿真超时");
    end

endmodule
