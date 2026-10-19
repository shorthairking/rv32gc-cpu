//==============================================================================
// tb_decoder_fp_audit.sv —— decoder OP-FP 保留字段定向验证（只读 DUT）
//------------------------------------------------------------------------------
// 用法: iverilog -g2012 -I rtl/pkg -I . -s tb_decoder_fp_audit \
//            -P tb_decoder_fp_audit.CASE=<n> -o <out>.vvp \
//            rtl/decode/decoder.v rtl/decode/dec_imm.v rtl/decode/dec_csr.v \
//            rtl/decode/compressed_expand.v <this>
// 判据同 tb_compressed_audit：控制例须 CONTROL_OK；缺陷例须 DEFECT_REPRODUCED，
//   且 DUT 观测（ill_instr_o）等于当前 RTL 机理预测值（接受保留编码）。
//==============================================================================
`timescale 1ns / 1ps

module tb_decoder_fp_audit #(parameter integer CASE = 1) ();

    reg  [31:0] insn;
    wire [31:0] insn32;
    wire        ill;
    wire        fpwe;
    wire [3:0]  optype;

    decoder u_dut (
        .insn_i            (insn),
        .priv_i            (2'b00),
        .menvcfg_cbie_i    (2'b00),
        .menvcfg_cbcfe_i   (1'b0),
        .senvcfg_cbie_i    (2'b00),
        .senvcfg_cbcfe_i   (1'b0),
        .insn32_o          (insn32),
        .ill_instr_o       (ill),
        .op_type_o         (optype),
        .fp_we_o           (fpwe)
    );

    reg [31:0] exp32;
    reg        exp_ill;
    reg        bad_ill;
    reg        is_ctl;
    reg [8*40-1:0] name;

    initial begin
        insn = 32'h5800_0053; exp_ill = 1'b0; bad_ill = 1'b0;
        is_ctl = 1'b1; name = "UNSET"; exp32 = 32'h5800_0053;
        case (CASE)
            0:  begin name = "F0_CTL_FSQRT_RS2_0";     insn = 32'h5800_0053;
                        exp_ill = 0; is_ctl = 1; end
            1:  begin name = "F1_FSQRT_RS2_NZ";        insn = 32'h5810_0053;
                        exp_ill = 1; is_ctl = 0; bad_ill = 0; end
            2:  begin name = "F2_FCVT_L_S_RV32";       insn = 32'hC020_0053;
                        exp_ill = 1; is_ctl = 0; bad_ill = 0; end
            3:  begin name = "F3_FCVT_S_L_RV32";       insn = 32'hD020_0053;
                        exp_ill = 1; is_ctl = 0; bad_ill = 0; end
            4:  begin name = "F4_FMV_X_W_RS2_NZ";      insn = 32'hE010_0053;
                        exp_ill = 1; is_ctl = 0; bad_ill = 0; end
            5:  begin name = "F5_FMV_W_X_RS2_NZ";      insn = 32'hF010_0053;
                        exp_ill = 1; is_ctl = 0; bad_ill = 0; end
            6:  begin name = "F6_CTL_FCVT_W_S";        insn = 32'hC000_0053;
                        exp_ill = 0; is_ctl = 1; end
            7:  begin name = "F7_CTL_FCVT_S_W";        insn = 32'hD000_0053;
                        exp_ill = 0; is_ctl = 1; end
            8:  begin name = "F8_CTL_FMV_X_W_RS2_0";   insn = 32'hE000_0053;
                        exp_ill = 0; is_ctl = 1; end
            9:  begin name = "F9_CTL_FMV_W_X_RS2_0";   insn = 32'hF000_0053;
                        exp_ill = 0; is_ctl = 1; end
            10: begin name = "FA_CTL_FADD_S";          insn = 32'h0020_8053;
                        exp_ill = 0; is_ctl = 1; end
            default: begin name = "BAD_CASE"; end
        endcase
        #1;
        $display("CASE %0d %0s DUT ill_instr=%b insn32=0x%08x optype=%0d fp_we=%b",
                 CASE, name, ill, insn32, optype, fpwe);
        $display("CASE %0d %0s EXPECT ill_instr=%b", CASE, name, exp_ill);
        if (is_ctl) begin
            if (ill === exp_ill)
                $display("CASE %0d %0s RESULT=CONTROL_OK", CASE, name);
            else
                $display("CASE %0d %0s RESULT=CONTROL_FAIL", CASE, name);
        end else begin
            if (ill === bad_ill)
                $display("CASE %0d %0s RESULT=DEFECT_REPRODUCED", CASE, name);
            else
                $display("CASE %0d %0s RESULT=DEFECT_NOT_REPRODUCED", CASE, name);
        end
        $finish;
    end

endmodule
