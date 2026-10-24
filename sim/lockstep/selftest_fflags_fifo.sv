//==============================================================================
// sim/lockstep/selftest_fflags_fifo.sv
//   —— tb_lockstep 的隐式 fflags 事件 FIFO + 独立 fake-fixture 单元自测
//==============================================================================
// 为什么单独成文件：审计 L4 指出旧 TB 的 pop+push 总写 fl2，occupancy 1/2 时
// 队首会出现空洞。这里把队列做成可独立验证的纯测试 helper：
//   · 按 pop 后 n-1 的 tail 放置新事件（不是固定 slot2）；
//   · 覆盖 occupancy 1/2/3、同拍 pop+push、重复 PC、only push/pop、overflow/underflow。
// 它不是产品 RTL，不参与综合；tb_lockstep 例化 lockstep_fflags_fifo，
// `iverilog -s selftest_fflags_fifo` 可单独跑本文件的 fake 序列。
//==============================================================================
`timescale 1ns / 1ps

module lockstep_fflags_fifo #(
    parameter integer DEPTH = 4
) (
    input  wire        clk,
    input  wire        rst_n,
    // push（事件在 E 级实际更新后一拍送入；val 为实际 poststate）
    input  wire        push,
    input  wire [31:0] push_pc,
    input  wire [4:0]  push_val,
    input  wire        push_taint,   // 与 W 级 CSR flags 写重叠，无法独立归属
    // pop（外部只在 head PC == 提交 PC 时拉高）
    input  wire        pop,
    output wire [31:0] head_pc,
    output wire [4:0]  head_val,
    output wire        head_taint,
    output wire        head_valid,
    output wire [2:0]  count,
    output reg         overflow,
    output reg         underflow
);
    reg [31:0] pc_q    [0:DEPTH-1];
    reg [4:0]  val_q   [0:DEPTH-1];
    reg        taint_q [0:DEPTH-1];
    reg [2:0]  n;

    integer i;
    integer pop_i, push_i;

    always @(posedge clk) begin
        if (!rst_n) begin
            n         <= 3'd0;
            overflow  <= 1'b0;
            underflow <= 1'b0;
            for (i = 0; i < DEPTH; i = i + 1) begin
                pc_q[i]    <= 32'h0;
                val_q[i]   <= 5'h0;
                taint_q[i] <= 1'b0;
            end
        end else begin
            pop_i  = (pop && (n != 3'd0)) ? 1 : 0;
            push_i = (push && (pop_i ? 1 : ((n < DEPTH) ? 1 : 0))) ? 1 : 0;

            // pop 后整体左移，tail 位置由 n-1 决定（audit L4 的根因）
            if (pop_i) begin
                for (i = 0; i < DEPTH-1; i = i + 1) begin
                    pc_q[i]    <= pc_q[i+1];
                    val_q[i]   <= val_q[i+1];
                    taint_q[i] <= taint_q[i+1];
                end
            end

            if (push && push_i) begin
                if (pop_i)
                    pc_q[n-1] <= push_pc;
                else
                    pc_q[n]   <= push_pc;
                if (pop_i) begin
                    val_q[n-1]   <= push_val;
                    taint_q[n-1] <= push_taint;
                end else begin
                    val_q[n]     <= push_val;
                    taint_q[n]   <= push_taint;
                end
            end

            if (push && !push_i) overflow  <= 1'b1;
            if (pop && (n == 3'd0)) underflow <= 1'b1;
            n <= n - pop_i[2:0] + push_i[2:0];
        end
    end

    assign head_pc    = pc_q[0];
    assign head_val   = val_q[0];
    assign head_taint = taint_q[0];
    assign head_valid = (n != 3'd0);
    assign count      = n;

endmodule

//==============================================================================
// 独立 fake-fixture 单元自测（不依赖 DUT/Spike）
//==============================================================================
module selftest_fflags_fifo;
    reg clk, rst_n, push, pop, push_taint;
    reg [31:0] push_pc;
    reg [4:0]  push_val;
    wire [31:0] head_pc;
    wire [4:0]  head_val;
    wire        head_taint, head_valid;
    wire [2:0]  count;
    wire        overflow, underflow;

    integer checks, fails;
    integer i;

    lockstep_fflags_fifo #(.DEPTH(4)) u_fifo (
        .clk(clk), .rst_n(rst_n),
        .push(push), .push_pc(push_pc), .push_val(push_val), .push_taint(push_taint),
        .pop(pop), .head_pc(head_pc), .head_val(head_val), .head_taint(head_taint),
        .head_valid(head_valid), .count(count), .overflow(overflow), .underflow(underflow)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    task chk_queue;
        input [8*48-1:0] label;
        input [31:0] e_pc;
        input [4:0]  e_val;
        input [2:0]  e_cnt;
        input        e_valid;
        begin
            if ((count !== e_cnt) || (head_valid !== e_valid) ||
                (e_valid && ((head_pc !== e_pc) || (head_val !== e_val)))) begin
                fails = fails + 1;
                $display("FFLAGS_FIFO_SELFTEST: FAIL %0s got(pc=0x%08h val=%0d cnt=%0d v=%b) exp(pc=0x%08h val=%0d cnt=%0d v=%b)",
                         label, head_pc, head_val, count, head_valid,
                         e_pc, e_val, e_cnt, e_valid);
            end
        end
    endtask

    task chk;
        input [8*48-1:0] label;
        input [31:0] e_pc;
        input [4:0]  e_val;
        input [2:0]  e_cnt;
        input        e_valid;
        begin
            checks = checks + 1;
            chk_queue(label, e_pc, e_val, e_cnt, e_valid);
            if ((overflow !== 1'b0) || (underflow !== 1'b0)) begin
                fails = fails + 1;
                $display("FFLAGS_FIFO_SELFTEST: FAIL %0s error flags got(ovf=%b unf=%b) exp(ovf=0 unf=0); queue(pc=0x%08h val=%0d cnt=%0d v=%b)",
                         label, overflow, underflow, head_pc, head_val, count, head_valid);
            end
        end
    endtask

    task chk_fault;
        input [8*48-1:0] label;
        input [31:0] e_pc;
        input [4:0]  e_val;
        input [2:0]  e_cnt;
        input        e_valid;
        input        e_overflow;
        input        e_underflow;
        begin
            checks = checks + 1;
            chk_queue(label, e_pc, e_val, e_cnt, e_valid);
            if ((overflow !== e_overflow) || (underflow !== e_underflow)) begin
                fails = fails + 1;
                $display("FFLAGS_FIFO_SELFTEST: FAIL %0s error flags got(ovf=%b unf=%b) exp(ovf=%b unf=%b); queue(pc=0x%08h val=%0d cnt=%0d v=%b)",
                         label, overflow, underflow, e_overflow, e_underflow,
                         head_pc, head_val, count, head_valid);
            end
        end
    endtask

    task do_push;
        input [31:0] pc;
        input [4:0]  v;
        input        t;
        begin
            @(negedge clk); push = 1'b1; push_pc = pc; push_val = v; push_taint = t;
            @(posedge clk); #1; push = 1'b0;
        end
    endtask

    task do_pop;
        begin
            @(negedge clk); pop = 1'b1;
            @(posedge clk); #1; pop = 1'b0;
        end
    endtask

    task reset_fifo;
        begin
            @(negedge clk); rst_n = 1'b0; push = 1'b0; pop = 1'b0;
            repeat (2) @(posedge clk);
            #1; rst_n = 1'b1;
            chk("reset-empty", 0, 0, 0, 1'b0);
        end
    endtask

    initial begin
        checks = 0; fails = 0;
        rst_n = 1'b0; push = 0; pop = 0; push_pc = 0; push_val = 0; push_taint = 0;
        repeat (2) @(posedge clk);
        #1; rst_n = 1'b1;
        chk("reset-empty", 0, 0, 0, 1'b0);

        // occupancy 1 + taint 位随条目移动
        do_push(32'h0000_0100, 5'd1, 1'b1);
        chk("push1", 32'h0000_0100, 5'd1, 3'd1, 1'b1);
        checks = checks + 1;
        if (!head_taint) begin fails = fails + 1;
            $display("FFLAGS_FIFO_SELFTEST: FAIL taint not preserved"); end
        do_push(32'h0000_0104, 5'd2, 1'b0);
        do_pop();
        checks = checks + 1;
        if (head_taint) begin fails = fails + 1;
            $display("FFLAGS_FIFO_SELFTEST: FAIL taint not shifted out"); end
        do_pop();
        chk("taint-drain", 0, 0, 0, 1'b0);
        // occupancy 1 必须由真实 push 建立并先断言；再测同拍 pop+push tail=0。
        do_push(32'h0000_0108, 5'd3, 1'b1);
        chk("pop_push_n1_seed", 32'h0000_0108, 5'd3, 3'd1, 1'b1);
        checks = checks + 1;
        if (!head_taint) begin fails = fails + 1;
            $display("FFLAGS_FIFO_SELFTEST: FAIL n1 seed taint missing"); end
        @(negedge clk); pop = 1'b1; push = 1'b1; push_pc = 32'h0000_010c; push_val = 5'd4;
        @(posedge clk); #1; pop = 1'b0; push = 1'b0;
        chk("pop_push_n1", 32'h0000_010c, 5'd4, 3'd1, 1'b1);
        do_pop();
        chk("pop_push_n1_empty", 0, 0, 0, 1'b0);

        // occupancy 3
        do_push(32'h0000_0200, 5'd4, 1'b0);
        do_push(32'h0000_0204, 5'd5, 1'b0);
        do_push(32'h0000_0208, 5'd6, 1'b0);
        chk("push3", 32'h0000_0200, 5'd4, 3'd3, 1'b1);
        // 重复 PC 两个事件：pop 一次后队首仍是同 PC，但 value 必须是第二个
        do_push(32'h0000_0200, 5'd7, 1'b0);
        chk("dup_pc_head", 32'h0000_0200, 5'd4, 3'd4, 1'b1);
        do_pop();
        chk("dup_pc_second", 32'h0000_0204, 5'd5, 3'd3, 1'b1);
        do_pop();
        chk("occ2_after_dup", 32'h0000_0208, 5'd6, 3'd2, 1'b1);
        // occupancy 2 + 同拍 pop+push
        @(negedge clk); pop = 1'b1; push = 1'b1; push_pc = 32'h0000_0200; push_val = 5'd7;
        @(posedge clk); #1; pop = 1'b0; push = 1'b0;
        chk("pop_push_n2", 32'h0000_0200, 5'd7, 3'd2, 1'b1);
        do_pop();
        chk("pop_push_n2_next", 32'h0000_0200, 5'd7, 3'd1, 1'b1);
        do_pop();
        chk("drain", 0, 0, 0, 1'b0);

        // occupancy 3 + 同拍 pop+push
        do_push(32'h0000_0300, 5'd8, 1'b0);
        do_push(32'h0000_0304, 5'd9, 1'b0);
        do_push(32'h0000_0308, 5'd10, 1'b0);
        @(negedge clk); pop = 1'b1; push = 1'b1; push_pc = 32'h0000_030c; push_val = 5'd11;
        @(posedge clk); #1; pop = 1'b0; push = 1'b0;
        chk("pop_push_n3", 32'h0000_0304, 5'd9, 3'd3, 1'b1);
        do_pop(); do_pop(); do_pop();
        chk("pop_push_n3_drain", 0, 0, 0, 1'b0);

        // Overflow 是独立错误阶段：先 reset 并确认两个错误标志清零。
        reset_fifo();
        checks = checks + 1;
        if ((overflow !== 1'b0) || (underflow !== 1'b0) || (count !== 3'd0)) begin fails = fails + 1;
            $display("FFLAGS_FIFO_SELFTEST: FAIL overflow phase was not reset"); end
        // only push overflow
        do_push(32'h0000_0400, 5'd12, 1'b0);
        do_push(32'h0000_0404, 5'd13, 1'b0);
        do_push(32'h0000_0408, 5'd14, 1'b0);
        do_push(32'h0000_040c, 5'd15, 1'b0);
        do_push(32'h0000_0410, 5'd16, 1'b0);   // overflow
        checks = checks + 1;
        if ((overflow !== 1'b1) || (underflow !== 1'b0)) begin fails = fails + 1;
            $display("FFLAGS_FIFO_SELFTEST: FAIL overflow flags expected 1/0 got %b/%b",
                     overflow, underflow); end
        chk_fault("full4", 32'h0000_0400, 5'd12, 3'd4, 1'b1, 1'b1, 1'b0);
        for (i = 0; i < 4; i = i + 1) do_pop();
        chk_fault("full4_drain", 0, 0, 0, 1'b0, 1'b1, 1'b0);

        // Underflow 用独立 reset 阶段，不能继承 overflow 的 sticky 标志。
        reset_fifo();
        checks = checks + 1;
        if ((overflow !== 1'b0) || (underflow !== 1'b0) || (count !== 3'd0)) begin fails = fails + 1;
            $display("FFLAGS_FIFO_SELFTEST: FAIL underflow phase was not reset"); end
        // only pop on empty -> underflow
        do_pop();
        if ((overflow !== 1'b0) || (underflow !== 1'b1)) begin fails = fails + 1;
            $display("FFLAGS_FIFO_SELFTEST: FAIL underflow flags expected 0/1 got %b/%b",
                     overflow, underflow); end
        chk_fault("underflow_empty", 0, 0, 0, 1'b0, 1'b0, 1'b1);

        if (fails == 0)
            $display("FFLAGS_FIFO_SELFTEST: %0d/%0d PASS", checks, checks);
        else
            $display("FFLAGS_FIFO_SELFTEST: %0d/%0d FAIL", checks - fails, checks);
        if (fails != 0) $fatal(1, "FFLAGS_FIFO_SELFTEST FAIL");
        $finish;
    end
endmodule
