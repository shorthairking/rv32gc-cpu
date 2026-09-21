//==============================================================================
// sw/m5_board/tb/ip/tb_ip_div.v —— **真实 div_gen IP**（rv32_div sim netlist）的时序探针
//==============================================================================
// 目的（2026-09-21 诊断轮 · M 扩展嫌疑核查）：
//   板上现象（十进制打印全乱、字符串/FREQ hex 正常、两次烧录逐字节相同）指向
//   **M 扩展除法通路在板上返回确定性垃圾**。而 RTL 的 IP 分支（`RV32GC_USE_VIVADO_IP`）
//   从未在仿真里跑过 ⇒ 本 TB 用 xsim 直接驱动**真实 IP**（`rv32_div_sim_netlist.v`，
//   Vivado 生成的加密功能模型，xsim 可解密），量出：
//     ① 输入 `s_axis_*_tvalid` 单拍脉冲被接受后，多久出现 `m_axis_dout_tvalid`；
//     ② `m_axis_dout_tdata` 是否**只在 tvalid 那一拍**有效（AXI-Stream 语义）；
//     ③ 连续/单拍两种驱动方式下结果是否正确（59/10 = 5余9、118049/2000 = 59余49）。
//   ⇒ 结论直接对照 `rtl/exec/mdu.v` 的握手拍（`ip_div_launch_q` 发 tvalid、
//      FSM 在 `div_iter_last = m_axis_dout_tvalid` 那一拍把 tdata 采进 quot_q/rem_q）。
//
// 用法：bash sw/m5_board/tb/ip/run_ip_div_xsim.sh
// 判定：脚本末尾 grep 本 TB 打印的 `TB_IP_DIV: ...` 行；任一向量结果不符 ⇒ 非零退出。
//==============================================================================
`timescale 1ns / 1ps

module tb_ip_div;

    reg         aclk    = 1'b0;
    reg         aresetn = 1'b0;
    reg         aclken  = 1'b1;

    reg  [31:0] dividend = 32'd0;
    reg  [31:0] divisor  = 32'd0;
    reg  [1:0]  dv_valid = 2'b00;          // bit0 = dividend tvalid, bit1 = divisor tvalid

    wire [63:0] dout;
    wire        dout_valid;

    integer     cyc = 0;
    integer     i;
    reg [31:0]  exp_q, exp_r;

    always #5 aclk = ~aclk;                 // 200 MHz（时序探针，与核内同域口径无关）
    always @(posedge aclk) cyc = cyc + 1;

    // ---- 被测 IP：真实 div_gen（无符号 32/32，radix-2，C_LATENCY=34）----
    rv32_div u_div (
        .aclk                   (aclk),
        .aclken                 (aclken),
        .aresetn                (aresetn),
        .s_axis_divisor_tvalid  (dv_valid[1]),
        .s_axis_divisor_tdata   (divisor),
        .s_axis_dividend_tvalid (dv_valid[0]),
        .s_axis_dividend_tdata  (dividend),
        .m_axis_dout_tvalid     (dout_valid),
        .m_axis_dout_tdata      (dout)
    );

    // ---- 逐拍打印（tvalid 附近 ±2 拍 + 每次 tvalid 出现）----
    always @(posedge aclk) begin
        if (aresetn) begin
            if (dout_valid)
                $display("TB_IP_DIV: +%0d m_axis_dout_tvalid=1 tdata=0x%08x%08x  => quot=%0d rem=%0d",
                         cyc, dout[63:32], dout[31:0], dout[31:0], dout[63:32]);
            else if (dv_valid != 2'b00)
                $display("TB_IP_DIV: +%0d in: dividend=%0d divisor=%0d (tvalid=%b)", cyc, dividend, divisor, dv_valid);
        end
    end

    // 一次除法：发单拍 tvalid 脉冲，等 dout_valid，比对
    task do_div;
        input [31:0] a;
        input [31:0] b;
        input integer wait_max;
        begin
            exp_q = a / b;
            exp_r = a % b;
            @(negedge aclk);
            dividend = a; divisor = b; dv_valid = 2'b11;
            $display("TB_IP_DIV: ==== 发单拍 tvalid：a=%0d b=%0d（期望 quot=%0d rem=%0d）==== 拍 %0d",
                     a, b, exp_q, exp_r, cyc);
            @(negedge aclk);
            dv_valid = 2'b00;                  // 单拍脉冲（= mdu.v 的 ip_div_launch_q 行为）
            i = 0;
            while (!dout_valid && (i < wait_max)) begin
                @(posedge aclk);
                i = i + 1;
            end
            if (i >= wait_max) begin
                $display("TB_IP_DIV: FAIL 向量 a=%0d b=%0d：%0d 拍内未见 dout_valid", a, b, wait_max);
            end else begin
                if (dout[31:0] === exp_q && dout[63:32] === exp_r)
                    $display("TB_IP_DIV: PASS 向量 a=%0d b=%0d ⇒ quot=%0d rem=%0d（等待 %0d 拍）",
                             a, b, dout[31:0], dout[63:32], i);
                else
                    $display("TB_IP_DIV: FAIL 向量 a=%0d b=%0d ⇒ 读回 quot=%0d rem=%0d（期望 %0d/%0d，等待 %0d 拍）",
                             a, b, dout[31:0], dout[63:32], exp_q, exp_r, i);
            end
            @(negedge aclk);
        end
    endtask

    initial begin
        repeat (10) @(posedge aclk);
        @(negedge aclk); aresetn = 1'b1;
        $display("TB_IP_DIV: 复位释放（拍 %0d）", cyc);

        // ---- 与板上 puts_dec 完全同形的 6 个向量（单拍 tvalid 脉冲）----
        do_div(32'd59,     32'd10,   200);
        do_div(32'd118049, 32'd2000, 200);
        do_div(32'd0,      32'd10,   200);
        do_div(32'd1,      32'd10,   200);
        do_div(32'd16,     32'd10,   200);
        do_div(32'd128,    32'd10,   200);

        // ---- 背靠背两笔（模拟 puts_dec 里 remu 紧跟 divu 的数据依赖序列）----
        do_div(32'd4294967295, 32'd10, 200);

        repeat (5) @(posedge aclk);
        $display("TB_IP_DIV: DONE");
        $finish;
    end

    // 超时保护
    initial begin
        #200000;
        $display("TB_IP_DIV: FAIL 全局超时（200 us）");
        $finish;
    end

endmodule
