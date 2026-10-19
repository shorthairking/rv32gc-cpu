//==============================================================================
// tb_priv_backend.sv —— backend_top 以真实 priv_i 译码 CSR / xRET 的权限负例
//------------------------------------------------------------------------------
// 目的: 用**真实指令位**经 backend_top 派发口注入，验证静态发现 P0-01：
//       backend_top.v:699 把 decoder.priv_i 硬接 `RV32GC_PRIV_M`，与模块端口
//       priv_i 无关 ⇒ U/S 下 csrrw mstatus / mret 仍按 M 译码。
// 证据等级: backend 模块级（D1 译码 → rename/ROB → 执行 → 提交/trap 口）；
//       **不实例化 csr_file/priv_ctrl/trap_ctrl**，因此不声称“整核提权已完成/已复现”。
// 用法: iverilog ... -s tb_priv_backend -P tb_priv_backend.CASE=<n>
// 判据: p0 是“cause2 观测通道”的正向控制（必非法指令必须看到 cause 2）；
//       p1/p2/p4 为缺陷例（U/S 的 M CSR 写、U 的 mret 被接受）；
//       p3/p5 为 M 模式控制（同指令合法）。
//==============================================================================
`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"
`include "rtl/back2/back2_params.vh"

module tb_priv_backend #(parameter integer CASE = 0) ();

    reg clk = 1'b0;
    reg rst_n = 1'b0;

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
    wire        trap_valid_o;
    wire [3:0]  trap_cause_o;
    wire        csr_we_o;
    wire        xret_cmt_o;
    wire [3:0]  commit_valid_o;
    wire [127:0] commit_pc_o;
    wire [3:0]  commit_arch_we_o;

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
        .priv_i(priv), .maint_rdy_i(maint_rdy), .cbo_perm_i(cbo_perm),
        .trap_valid_o(trap_valid_o), .trap_cause_o(trap_cause_o),
        .csr_we_o(csr_we_o), .xret_cmt_o(xret_cmt_o),
        .commit_valid_o(commit_valid_o), .commit_pc_o(commit_pc_o),
        .commit_arch_we_o(commit_arch_we_o)
    );

    localparam integer B_ILLEGAL = `BACK2_U_FLAGS_LSB + `BACK2_FL_IS_ILLEGAL;

    reg [31:0] insn;
    reg [1:0]  priv_v;
    reg        is_ctl;          // 1 = 控制例；0 = 缺陷例
    reg        ctl_trap2;       // 控制例期望：是否应看到 cause 2
    reg        ctl_csr_we;      // 控制例期望：是否应看到 CSR 写脉冲
    reg        ctl_xret;        // 控制例期望：是否应看到 xret 提交
    reg [8*36-1:0] name;

    integer cyc;
    reg     captured, commit_seen, trap2_seen, csr_we_seen, xret_seen;
    reg     d1_illegal;
    reg     commit_we;

    always #5 clk = ~clk;

    initial begin
        insn = 32'h0000_0000; priv_v = 2'b11; is_ctl = 1; name = "UNSET";
        ctl_trap2 = 1; ctl_csr_we = 0; ctl_xret = 0;
        case (CASE)
            0: begin name = "P0_CTL_ILLEGAL_INSN"; insn = 32'h0000_0000;
                       priv_v = 2'b11; is_ctl = 1; ctl_trap2 = 1; ctl_csr_we = 0; ctl_xret = 0; end
            1: begin name = "P1_U_CSRRW_MSTATUS"; insn = 32'h3000_10F3;
                       priv_v = 2'b00; is_ctl = 0; end
            2: begin name = "P2_S_CSRRW_MSTATUS"; insn = 32'h3000_10F3;
                       priv_v = 2'b01; is_ctl = 0; end
            3: begin name = "P3_CTL_M_CSRRW_MSTATUS"; insn = 32'h3000_10F3;
                       priv_v = 2'b11; is_ctl = 1; ctl_trap2 = 0; ctl_csr_we = 1; ctl_xret = 0; end
            4: begin name = "P4_U_MRET"; insn = 32'h3020_0073;
                       priv_v = 2'b00; is_ctl = 0; end
            5: begin name = "P5_CTL_M_MRET"; insn = 32'h3020_0073;
                       priv_v = 2'b11; is_ctl = 1; ctl_trap2 = 0; ctl_csr_we = 0; ctl_xret = 1; end
            default: name = "BAD_CASE";
        endcase

        blk_valid = 0; blk_mask = 4'b0001; blk_next_pc = 32'h8000_0000; blk_taken = 0;
        lane_pc = 0; lane_pa = 0; lane_insn = 0; lane_len32 = 4'b0001; lane_cls = 0;
        lane_pred_taken = 0; lane_pred_selg = 0; lane_pred_gdir = 0; lane_pred_ldir = 0;
        lane_pred_target = 0; lane_btb_hit = 0; lane_btb_way = 0; lane_btb_cond = 0;
        lane_btb_call = 0; lane_btb_ret = 0; lane_btb_target = 0;
        lane_fault = 0; lane_fault_cause = 0; lane_fault_tval = 0;
        lane_ckpt = 0; lane_ckpt_valid = 0; fe_fetch_fault = 0;
        train_ready = 1; mem_req_ready = 1; mem_rsp_valid = 0; mem_rsp_err = 0;
        mem_rsp_rdata = 0; mem_rsp_tag = 0;
        st_xlate_en = 0; st_xlate_ctx = 0; st_xlate_ready = 1; st_xlate_done = 0;
        st_xlate_pa = 0; st_xlate_fault = 0;
        trp_flush_v = 0; trp_redirect_v = 0; trp_redirect_pc = 0;
        csr_rdata = 0; csr_frm = 0; csr_fflags = 0;
        priv = priv_v; maint_rdy = 1; cbo_perm = 2'b00;

        captured = 0; commit_seen = 0; trap2_seen = 0; csr_we_seen = 0;
        xret_seen = 0; d1_illegal = 1'b0; commit_we = 1'b0;

        lane_pc[31:0] = 32'h8000_0000;
        lane_insn[31:0] = insn;

        repeat (4) @(posedge clk);
        rst_n <= 1'b1;
        repeat (2) @(posedge clk);

        blk_valid <= 1'b1;
        for (cyc = 0; cyc < 200; cyc = cyc + 1) begin
            @(posedge clk);
            if (!captured && u_dut.d1_v_q[0]) begin
                d1_illegal = u_dut.d1_uop_q[0][B_ILLEGAL];
                captured = 1'b1;
                blk_valid <= 1'b0;
            end
            if (commit_valid_o[0] && (commit_pc_o[31:0] == 32'h8000_0000)) begin
                commit_seen = 1'b1;
                commit_we   = commit_arch_we_o[0];
            end
            if (trap_valid_o && (trap_cause_o == `BACK2_EXC_ILLEGAL)) trap2_seen = 1'b1;
            if (csr_we_o) csr_we_seen = 1'b1;
            if (xret_cmt_o) xret_seen = 1'b1;
        end
        blk_valid <= 1'b0;

        $display("CASE %0d %0s DUT priv=%b captured=%b d1_illegal=%b commit_seen=%b commit_we=%b trap2_seen=%b csr_we_seen=%b xret_seen=%b",
                 CASE, name, priv_v, captured, d1_illegal, commit_seen, commit_we,
                 trap2_seen, csr_we_seen, xret_seen);
        $display("CASE %0d %0s EXPECT priv=%b insn=0x%08x illegal=%b trap2=%b csr_we=%b xret=%b",
                 CASE, name, priv_v, insn,
                 (is_ctl ? ctl_trap2 : 1'b1), ctl_trap2, ctl_csr_we, ctl_xret);

        if (!captured) begin
            $display("CASE %0d %0s RESULT=NO_CAPTURE", CASE, name);
        end else if (is_ctl) begin
            if ((d1_illegal === ctl_trap2) && (trap2_seen === ctl_trap2) &&
                (csr_we_seen === ctl_csr_we) && (xret_seen === ctl_xret))
                $display("CASE %0d %0s RESULT=CONTROL_OK", CASE, name);
            else
                $display("CASE %0d %0s RESULT=CONTROL_FAIL", CASE, name);
        end else begin
            // 缺陷例：必须被按 M 译码（illegal=0）且出现被禁止的副作用、无 cause 2
            if ((d1_illegal === 1'b0) && (commit_seen === 1'b1) && (trap2_seen === 1'b0) &&
                ((csr_we_seen === 1'b1) || (xret_seen === 1'b1)))
                $display("CASE %0d %0s RESULT=DEFECT_REPRODUCED", CASE, name);
            else
                $display("CASE %0d %0s RESULT=DEFECT_NOT_REPRODUCED", CASE, name);
        end
        $finish;
    end

endmodule
