//==============================================================================
// sw/m5_board/tb/ip/tb_mdu_ip.v —— **IP 分支的 MDU 级自检**（真实 div_gen/mult_gen IP）
//==============================================================================
// 目的（2026-09-21 · M 扩展嫌疑核查）：
//   用 xsim + **真实 IP 网表**（`fpga/ip/rv32_{div,mult_*}/*_sim_netlist.v`）驱动
//   `rtl/exec/mdu.v` 的 `RV32GC_USE_VIVADO_IP` 分支，逐向量核对 M 扩展的 8 条指令：
//     · 这是 RTL 的 **IP 分支首次进入仿真闭环**（M4 遗留 R3：iverilog 不能编译加密网表，
//       历次回归都跑行为分支）—— 板上"十进制打印乱码"的第一嫌疑就在这里。
//     · 判定是 **fail-closed**：任一向量读回值 ≠ 期望 ⇒ 打印 FAIL 行；只有全过才
//       `TB_MDU_IP: PASS`（脚本按此判 rc）。
//
// 用法：bash sw/m5_board/tb/ip/run_mdu_ip_xsim.sh            # 期望全过
//       bash sw/m5_board/tb/ip/run_mdu_ip_xsim.sh --expect-fail   # 修复前复现（期望有 FAIL）
//==============================================================================
`timescale 1ns / 1ps

module tb_mdu_ip;

    reg         aclk    = 1'b0;
    reg         aresetn = 1'b0;
    reg         flush   = 1'b0;
    reg         start   = 1'b0;
    reg  [2:0]  mdu_op  = 3'd0;
    reg  [31:0] a_in    = 32'd0;
    reg  [31:0] b_in    = 32'd0;

    wire        busy;
    wire        done;
    wire [31:0] result;

    integer     n_vec = 0, n_pass = 0, n_fail = 0;
    integer     i;

    always #5 aclk = ~aclk;

    mdu u_mdu (
        .aclk (aclk), .aresetn (aresetn), .start (start), .flush (flush),
        .mdu_op (mdu_op), .a (a_in), .b (b_in),
        .busy (busy), .done (done), .result (result)
    );

    // 一个向量：发 start（单拍）→ 等 done → 比对（读 result 必须在 done 那一拍）
    task check;
        input [2:0]  op;
        input [31:0] a;
        input [31:0] b;
        input [31:0] exp;
        input [8*32-1:0] name;
        reg [31:0] got;
        begin
            @(negedge aclk);
            mdu_op = op; a_in = a; b_in = b; start = 1'b1;
            @(posedge aclk);
            @(negedge aclk);
            start = 1'b0;
            i = 0;
            while (!done && (i < 200)) begin @(posedge aclk); i = i + 1; end
            got = result;
            n_vec = n_vec + 1;
            if (done && (got === exp)) begin
                n_pass = n_pass + 1;
                $display("TB_MDU_IP: PASS %0s a=0x%08x b=0x%08x => 0x%08x（等待 %0d 拍）",
                         name, a, b, got, i);
            end else begin
                n_fail = n_fail + 1;
                $display("TB_MDU_IP: FAIL %0s a=0x%08x b=0x%08x => 读回 0x%08x（期望 0x%08x，等待 %0d 拍，done=%b）",
                         name, a, b, got, exp, i, done);
            end
            @(negedge aclk);
        end
    endtask

    initial begin
        repeat (10) @(posedge aclk);
        @(negedge aclk); aresetn = 1'b1;
        $display("TB_MDU_IP: 复位释放；开始向量（IP 分支：真实 div_gen + mult_gen）");

        // ---------------- 乘法（mult_gen 也是 IP 分支；顺带验证）----------------
        check(3'b000, 32'd6,          32'd7,          32'd42,         "MUL    6*7");
        check(3'b000, 32'hFFFFFFFF,   32'hFFFFFFFF,   32'h00000001,   "MUL    (-1)*(-1) low");
        check(3'b001, 32'h80000000,   32'h80000000,   32'h40000000,   "MULH   (-2^31)*(-2^31) high");
        check(3'b011, 32'hFFFFFFFF,   32'hFFFFFFFF,   32'hFFFFFFFE,   "MULHU  max*max high");
        check(3'b010, 32'h80000000,   32'hFFFFFFFF,   32'h80000000,   "MULHSU -2^31 * max high");

        // ---------------- 除法：**板上 puts_dec 用的向量**（十进制打印）----------------
        check(3'b101, 32'd59,         32'd10,         32'd5,          "DIVU   59/10");
        check(3'b111, 32'd59,         32'd10,         32'd9,          "REMU   59%10");
        check(3'b101, 32'd118049,     32'd2000,       32'd59,         "DIVU   118049/2000");
        check(3'b111, 32'd118049,     32'd2000,       32'd49,         "REMU   118049%2000");
        check(3'b101, 32'd0,          32'd10,         32'd0,          "DIVU   0/10");
        check(3'b101, 32'd1,          32'd10,         32'd0,          "DIVU   1/10");
        check(3'b111, 32'd1,          32'd10,         32'd1,          "REMU   1%10");
        check(3'b101, 32'd16,         32'd10,         32'd1,          "DIVU   16/10（步① pattern=16）");
        check(3'b111, 32'd16,         32'd10,         32'd6,          "REMU   16%10");
        check(3'b101, 32'd128,        32'd10,         32'd12,         "DIVU   128/10");
        check(3'b111, 32'd128,        32'd10,         32'd8,          "REMU   128%10");
        check(3'b101, 32'hFFFFFFFF,   32'd10,         32'd429496729,  "DIVU   max/10");
        check(3'b111, 32'hFFFFFFFF,   32'd10,         32'd5,          "REMU   max%10");
        check(3'b101, 32'd33000000,   32'd1000000,    32'd33,         "DIVU   33e6/1e6（步⑤ div1e6）");

        // ---------------- 除法：ISA 边界 ----------------
        check(3'b100, 32'hFFFFFFF9,   32'd2,          32'hFFFFFFFD,   "DIV    -7/2 向零 = -3");
        check(3'b110, 32'hFFFFFFF9,   32'd2,          32'hFFFFFFFF,   "REM    -7%2 = -1");
        check(3'b100, 32'h80000000,   32'hFFFFFFFF,   32'h80000000,   "DIV    -2^31/-1 溢出特例");
        check(3'b110, 32'h80000000,   32'hFFFFFFFF,   32'd0,          "REM    -2^31%-1 = 0");
        check(3'b101, 32'h12345678,   32'd0,          32'hFFFFFFFF,   "DIVU   除零 ⇒ 全 1");
        check(3'b111, 32'h12345678,   32'd0,          32'h12345678,   "REMU   除零 ⇒ 被除数");

        $display("TB_MDU_IP: 汇总 向量=%0d PASS=%0d FAIL=%0d", n_vec, n_pass, n_fail);
        if (n_fail == 0)
            $display("TB_MDU_IP: PASS");
        else
            $display("TB_MDU_IP: FAIL 向量比对未全过");
        $finish;
    end

    initial begin
        #500000;
        $display("TB_MDU_IP: FAIL 全局超时（500 us）");
        $finish;
    end

endmodule
