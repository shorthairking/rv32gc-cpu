//==============================================================================
// tb_compressed_audit.sv —— compressed_expand 定向验证（只读 DUT，不改 RTL）
//------------------------------------------------------------------------------
// 用法: iverilog -g2012 -I rtl/pkg -I . -s tb_compressed_audit \
//            -P tb_compressed_audit.CASE=<n> -o <out>.vvp \
//            rtl/decode/compressed_expand.v <this>
//       vvp <out>.vvp
// 判据: 每个 CASE 恰好打印一行 "CASE n NAME RESULT=..."；
//       控制例要求 CONTROL_OK（DUT 与规范一致）；缺陷例要求 DEFECT_REPRODUCED
//       且 DUT 观测值等于“按当前 RTL 机理预测的错误值”（证明机理，不止是“不相等”）。
//       RESULT 行缺失 / 计数 != 1 ⇒ 脚本判失败。
//==============================================================================
`timescale 1ns / 1ps

module tb_compressed_audit #(parameter integer CASE = 1) ();

    reg  [15:0] cin;
    wire [31:0] i32;
    wire        ill, hint, ctl;

    compressed_expand u_dut (
        .c_insn     (cin),
        .insn32_o   (i32),
        .ill16_o    (ill),
        .is_hint_o  (hint),
        .ctl_xfer_o (ctl)
    );

    reg [31:0] exp32;
    reg        exp_ill;
    reg [31:0] bad32;      // 按当前 RTL 机理预测的 DUT 错误观测
    reg        bad_ill;
    reg        is_ctl;
    reg [8*40-1:0] name;

    initial begin
        cin = 16'h0001; exp32 = 32'h00000013; exp_ill = 1'b0;
        bad32 = 32'h00000000; bad_ill = 1'b0; is_ctl = 1'b1; name = "UNSET";
        case (CASE)
            0:  begin name = "C0_CTL_C_NOP";            cin = 16'h0001;
                        exp32 = 32'h0000_0013; exp_ill = 0; is_ctl = 1; end
            1:  begin name = "C1_C_SUB_X8_X9";          cin = 16'h8C05;
                        exp32 = 32'h4094_0433; exp_ill = 0; is_ctl = 0;
                        bad32 = 32'h4094_84b3; bad_ill = 0; end   // DUT: rd_p 取 c[4:2]
            2:  begin name = "C2_CTL_SUB_RD_EQ_RS2";    cin = 16'h8C01;
                        exp32 = 32'h4084_0433; exp_ill = 0; is_ctl = 1; end
            3:  begin name = "C3_C_SRLI_X8_5";          cin = 16'h8015;
                        exp32 = 32'h0054_5413; exp_ill = 0; is_ctl = 0;
                        bad32 = 32'h0056_D693; bad_ill = 0; end
            4:  begin name = "C4_C_ANDI_X8_5";          cin = 16'h8815;
                        exp32 = 32'h0054_7413; exp_ill = 0; is_ctl = 0;
                        bad32 = 32'h0056_F693; bad_ill = 0; end
            5:  begin name = "C5_C_EBREAK";             cin = 16'h9002;
                        exp32 = 32'h0010_0073; exp_ill = 0; is_ctl = 0;
                        bad32 = 32'h0010_0073; bad_ill = 1; end   // DUT: 误判非法
            6:  begin name = "C6_C_JR_X0_RESERVED";     cin = 16'h8002;
                        exp32 = 32'h0000_0067; exp_ill = 1; is_ctl = 0;
                        bad32 = 32'h0000_0067; bad_ill = 0; end   // DUT: 误判合法
            7:  begin name = "C7_CTL_C_JR_X5";          cin = 16'h8282;
                        exp32 = 32'h0002_8067; exp_ill = 0; is_ctl = 1; end
            8:  begin name = "C8_CTL_C_JALR_X5";        cin = 16'h9282;
                        exp32 = 32'h0002_80E7; exp_ill = 0; is_ctl = 1; end
            default: begin name = "BAD_CASE"; end
        endcase
        #1;
        $display("CASE %0d %0s DUT insn32=0x%08x ill16=%b hint=%b ctl=%b",
                 CASE, name, i32, ill, hint, ctl);
        $display("CASE %0d %0s EXPECT insn32=0x%08x ill16=%b",
                 CASE, name, exp32, exp_ill);
        if (is_ctl) begin
            if ((i32 === exp32) && (ill === exp_ill))
                $display("CASE %0d %0s RESULT=CONTROL_OK", CASE, name);
            else
                $display("CASE %0d %0s RESULT=CONTROL_FAIL", CASE, name);
        end else begin
            if ((i32 === bad32) && (ill === bad_ill))
                $display("CASE %0d %0s RESULT=DEFECT_REPRODUCED", CASE, name);
            else
                $display("CASE %0d %0s RESULT=DEFECT_NOT_REPRODUCED", CASE, name);
        end
        $finish;
    end

endmodule
