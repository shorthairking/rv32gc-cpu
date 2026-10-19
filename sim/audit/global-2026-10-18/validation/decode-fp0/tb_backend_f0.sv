//==============================================================================
// tb_backend_f0.sv —— 后端 dst_fp 对 FP 目的寄存器 f0 的抑制（只读 DUT）
//------------------------------------------------------------------------------
// 目的: 把 **真实指令** 经 front4→backend 的派发口（lane_insn_i）注入
//       backend_top，读 **D1 打包 uop** 的 dst_fp/dst_int/is_fp 位，验证
//       backend_top.v:780 `dst_fp = fp_we & (drd != 0) & ~kill` 对 f0 的抑制。
//       —— 这是“组合条件证实 + 真实指令流入后端 D1”的层级；
//          **不是**端到端架构写回（未跑到 PRF/ROB 提交写口），报告须区分。
// 用法: iverilog -g2012 -I rtl/pkg -I . -s tb_backend_f0 \
//            -P tb_backend_f0.CASE=<n> -o <out>.vvp <rtl> <this>
// 判据: 缺陷例（rd=f0）要求 DUT dst_fp=0 且 is_fp=1 且 illegal=0（预测机理值）；
//       控制例（rd=f1）要求 dst_fp=1。RESULT 行缺失/不唯一 ⇒ 脚本失败。
//==============================================================================
`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"
`include "rtl/back2/back2_params.vh"

module tb_backend_f0 #(parameter integer CASE = 1) ();

    reg clk = 1'b0;
    reg rst_n = 1'b0;

    // ---- 前端派发块 ----
    reg         blk_valid;
    reg  [3:0]  blk_mask;
    reg  [31:0] blk_next_pc;
    reg         blk_taken;
    reg  [127:0] lane_pc, lane_pa, lane_insn;
    reg  [3:0]  lane_len32;
    reg  [11:0] lane_cls;
    reg  [3:0]  lane_pred_taken, lane_pred_selg, lane_pred_gdir, lane_pred_ldir;
    reg  [127:0] lane_pred_target;
    reg  [3:0]  lane_btb_hit, lane_btb_way, lane_btb_cond, lane_btb_call, lane_btb_ret;
    reg  [127:0] lane_btb_target;
    reg  [3:0]  lane_fault;
    reg  [19:0] lane_fault_cause;
    reg  [127:0] lane_fault_tval;
    reg  [15:0] lane_ckpt;
    reg  [3:0]  lane_ckpt_valid;
    reg         fe_fetch_fault;
    // ---- 其它输入 ----
    reg         train_ready;
    reg         mem_req_ready, mem_rsp_valid, mem_rsp_err;
    reg  [31:0] mem_rsp_rdata;
    reg  [`BACK2_MEM_TAG_W-1:0] mem_rsp_tag;
    reg         st_xlate_en, st_xlate_ready, st_xlate_done, st_xlate_fault;
    reg  [3:0]  st_xlate_ctx;
    reg  [31:0] st_xlate_pa;
    reg         trp_flush_v, trp_redirect_v;
    reg  [31:0] trp_redirect_pc;
    reg  [31:0] csr_rdata;
    reg  [2:0]  csr_frm;
    reg  [4:0]  csr_fflags;
    reg  [1:0]  priv;
    reg         maint_rdy;
    reg  [1:0]  cbo_perm;

    wire        blk_ready_o;

    backend_top u_dut (
        .clk(clk), .rst_n(rst_n),
        .blk_valid_i(blk_valid), .blk_ready_o(blk_ready_o), .blk_mask_i(blk_mask),
        .blk_next_pc_i(blk_next_pc), .blk_taken_i(blk_taken),
        .lane_pc_i(lane_pc), .lane_pa_i(lane_pa), .lane_insn_i(lane_insn),
        .lane_len32_i(lane_len32), .lane_cls_i(lane_cls),
        .lane_pred_taken_i(lane_pred_taken), .lane_pred_selg_i(lane_pred_selg),
        .lane_pred_gdir_i(lane_pred_gdir), .lane_pred_ldir_i(lane_pred_ldir),
        .lane_pred_target_i(lane_pred_target),
        .lane_btb_hit_i(lane_btb_hit), .lane_btb_way_i(lane_btb_way),
        .lane_btb_cond_i(lane_btb_cond), .lane_btb_call_i(lane_btb_call),
        .lane_btb_ret_i(lane_btb_ret), .lane_btb_target_i(lane_btb_target),
        .lane_fault_i(lane_fault), .lane_fault_cause_i(lane_fault_cause),
        .lane_fault_tval_i(lane_fault_tval), .lane_ckpt_i(lane_ckpt),
        .lane_ckpt_valid_i(lane_ckpt_valid), .fe_fetch_fault_i(fe_fetch_fault),
        .train_ready_i(train_ready),
        .mem_req_ready_i(mem_req_ready), .mem_rsp_valid_i(mem_rsp_valid),
        .mem_rsp_rdata_i(mem_rsp_rdata), .mem_rsp_tag_i(mem_rsp_tag),
        .mem_rsp_err_i(mem_rsp_err),
        .st_xlate_en_i(st_xlate_en), .st_xlate_ctx_i(st_xlate_ctx),
        .st_xlate_ready_i(st_xlate_ready), .st_xlate_done_i(st_xlate_done),
        .st_xlate_pa_i(st_xlate_pa), .st_xlate_fault_i(st_xlate_fault),
        .trp_flush_v_i(trp_flush_v), .trp_redirect_v_i(trp_redirect_v),
        .trp_redirect_pc_i(trp_redirect_pc),
        .csr_rdata_i(csr_rdata), .csr_frm_i(csr_frm), .csr_fflags_i(csr_fflags),
        .priv_i(priv), .maint_rdy_i(maint_rdy), .cbo_perm_i(cbo_perm)
    );

    localparam integer FL_LSB = `BACK2_U_FLAGS_LSB;
    localparam integer B_DST_INT = FL_LSB + `BACK2_FL_RD_I_WEN;
    localparam integer B_DST_FP  = FL_LSB + `BACK2_FL_RD_F_WEN;
    localparam integer B_IS_FP   = FL_LSB + `BACK2_FL_IS_FP;
    localparam integer B_ILLEGAL = FL_LSB + `BACK2_FL_IS_ILLEGAL;
    localparam integer B_FPLS    = FL_LSB + `BACK2_FL_IS_FPLS;

    reg [31:0] insn;
    reg        expect_fp;      // 规范期望：该指令写 FP 寄存器 ⇒ dst_fp 应为 1
    reg        is_ctl;
    reg [8*40-1:0] name;
    integer    cyc;
    reg        captured;
    reg [15:0] dut_flags;
    reg [4:0]  dut_rd;
    reg [3:0]  dut_opt;
    reg        cmt_seen, prf_we_seen;
    reg        cmt_we;
    reg [4:0]  cmt_rd;

    always #5 clk = ~clk;

    initial begin
        insn = 32'h0020_8053; expect_fp = 1'b1; is_ctl = 1'b0; name = "UNSET";
        case (CASE)
            1: begin name = "B1_FADD_S_F0"; insn = 32'h0020_8053; expect_fp = 1; is_ctl = 0; end
            2: begin name = "B2_CTL_FADD_S_F1"; insn = 32'h0020_80D3; expect_fp = 1; is_ctl = 1; end
            3: begin name = "B3_FLW_F0"; insn = 32'h0000_2007; expect_fp = 1; is_ctl = 0; end
            4: begin name = "B4_CTL_FLW_F1"; insn = 32'h0000_2087; expect_fp = 1; is_ctl = 1; end
            default: name = "BAD_CASE";
        endcase

        blk_valid = 0; blk_mask = 4'b0001; blk_next_pc = 32'h8000_0000; blk_taken = 0;
        lane_pc = 128'd0; lane_pa = 128'd0; lane_insn = 128'd0; lane_len32 = 4'b0001;
        lane_cls = 12'd0; lane_pred_taken = 0; lane_pred_selg = 0; lane_pred_gdir = 0;
        lane_pred_ldir = 0; lane_pred_target = 0; lane_btb_hit = 0; lane_btb_way = 0;
        lane_btb_cond = 0; lane_btb_call = 0; lane_btb_ret = 0; lane_btb_target = 0;
        lane_fault = 0; lane_fault_cause = 0; lane_fault_tval = 0; lane_ckpt = 0;
        lane_ckpt_valid = 0; fe_fetch_fault = 0;
        train_ready = 1; mem_req_ready = 1; mem_rsp_valid = 0; mem_rsp_err = 0;
        mem_rsp_rdata = 0; mem_rsp_tag = 0;
        st_xlate_en = 0; st_xlate_ctx = 0; st_xlate_ready = 1; st_xlate_done = 0;
        st_xlate_pa = 0; st_xlate_fault = 0;
        trp_flush_v = 0; trp_redirect_v = 0; trp_redirect_pc = 0;
        csr_rdata = 0; csr_frm = 0; csr_fflags = 0; priv = 2'b11;
        maint_rdy = 1; cbo_perm = 2'b00;
        captured = 0; dut_flags = 4'd0; dut_rd = 0; dut_opt = 0;
        cmt_seen = 0; prf_we_seen = 0; cmt_we = 0; cmt_rd = 0;

        lane_pc[31:0] = 32'h8000_0000;
        lane_insn[31:0] = insn;

        repeat (4) @(posedge clk);
        rst_n <= 1'b1;
        repeat (2) @(posedge clk);

        // 真实派发：blk_valid=1，mask=仅 lane0；抓到 D1 uop 后立刻撤销派发
        blk_valid <= 1'b1;
        for (cyc = 0; cyc < 200; cyc = cyc + 1) begin
            @(posedge clk);
            // 此处读到的是本拍之前的寄存器值：d1_v_q=1 表示 D1 已锁存待派发 uop
            if (!captured && u_dut.d1_v_q[0]) begin
                dut_flags = u_dut.d1_uop_q[0][`BACK2_U_FLAGS_MSB:`BACK2_U_FLAGS_LSB];
                dut_rd    = u_dut.d1_uop_q[0][`BACK2_U_ARND_MSB:`BACK2_U_ARND_LSB];
                dut_opt   = u_dut.d1_uop_q[0][`BACK2_U_OPTYPE_MSB:`BACK2_U_OPTYPE_LSB];
                captured  = 1'b1;
                blk_valid <= 1'b0;      // 只注入一条，避免重复派发
            end
            // 简易访存从设备：接受读请求后回一笔数据（让 flw 能完成/提交）
            if (u_dut.mem_req_valid_o && mem_req_ready) begin
                mem_rsp_valid <= 1'b1;
                mem_rsp_rdata <= 32'h0000_0000;
                mem_rsp_tag   <= u_dut.mem_req_tag_o;
            end else begin
                mem_rsp_valid <= 1'b0;
            end
            // 端到端：FP 物理寄存器堆写口 + 提交写使能
            if (u_dut.u_prf_f.we !== 2'b00) prf_we_seen = 1'b1;
            if (u_dut.commit_valid_o[0] && (u_dut.commit_pc_o[31:0] == 32'h8000_0000)) begin
                cmt_seen = 1'b1;
                cmt_we   = u_dut.commit_arch_we_o[0];
                cmt_rd   = u_dut.commit_arch_rd_o[4:0];
            end
        end
        blk_valid <= 1'b0;

        $display("CASE %0d %0s DUT captured=%b optype=%0d uop_rd=%0d dst_fp=%b dst_int=%b is_fp=%b is_fpls=%b illegal=%b",
                 CASE, name, captured, dut_opt, dut_rd, dut_flags[`BACK2_FL_RD_F_WEN],
                 dut_flags[`BACK2_FL_RD_I_WEN], dut_flags[`BACK2_FL_IS_FP],
                 dut_flags[`BACK2_FL_IS_FPLS], dut_flags[`BACK2_FL_IS_ILLEGAL]);
        $display("CASE %0d %0s EXPECT dst_fp=1 (rd=f%0d 是合法 FP 目的寄存器, 规范无 f0 抑制) insn=0x%08x",
                 CASE, name, dut_rd, insn);
        $display("CASE %0d %0s E2E commit_seen=%b commit_arch_we=%b commit_rd=%0d fp_prf_we_seen=%b",
                 CASE, name, cmt_seen, cmt_we, cmt_rd, prf_we_seen);

        if (!captured) begin
            $display("CASE %0d %0s RESULT=NO_CAPTURE", CASE, name);
        end else if (is_ctl) begin
            if (dut_flags[`BACK2_FL_RD_F_WEN] === 1'b1)
                $display("CASE %0d %0s RESULT=CONTROL_OK", CASE, name);
            else
                $display("CASE %0d %0s RESULT=CONTROL_FAIL", CASE, name);
        end else begin
            // 缺陷例：DUT 必须表现为 dst_fp=0（抑制），且该 uop 确为合法 FP 写指令
            if (dut_flags[`BACK2_FL_RD_F_WEN] === 1'b0)
                $display("CASE %0d %0s RESULT=DEFECT_REPRODUCED", CASE, name);
            else
                $display("CASE %0d %0s RESULT=DEFECT_NOT_REPRODUCED", CASE, name);
        end
        $finish;
    end

endmodule
