//==============================================================================
// tb_lsq_release.sv —— LSQ LQ 释放窗口在 ROB 回绕边界的模宽错误（03 P0）
//------------------------------------------------------------------------------
// 目的: 静态发现 lsq_simple.v:1462–1467 的释放判据
//         (ld_rob - rob_head) & 7'h7F < cmt_n
//       用 7 bit 模 128 的年龄，而 ROB 深度 64 应取模 64；`head=63, cmt_n=2,
//       ld_rob=0` 时年龄为 65（不是 1），已提交的 LQ 项不释放。
// 证据等级: 真实 D3 分配口（lalloc_valid/lalloc_rob）→ 真实 LQ 阵列 → 真实提交窗口
//       （rob_head/cmt_n 为模块输入，由 TB 受控给值）⇒ 证明该状态转移，**不声称
//       整核可达**（未跑 ROB/派发/执行/提交全链，也未生成该场景的程序）。
// 用法: iverilog ... -s tb_lsq_release -P tb_lsq_release.CASE=<n>
// 判据: L1(head=63, rob=[63,0]) 为缺陷例；L2(head=0, rob=[0,1]) 为控制例。
//==============================================================================
`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"
`include "rtl/back2/back2_params.vh"

module tb_lsq_release #(parameter integer CASE = 1) ();

    reg clk = 1'b0;
    reg rst_n = 1'b0;

    reg         flush_all, squash;
    reg  [5:0]  squash_idx, rob_head;
    reg  [3:0]  alloc_valid;
    reg  [3*6-1:0] alloc_rob;
    reg  [3:0]  lalloc_valid;
    reg  [3*6-1:0] lalloc_rob;
    reg         exe_valid, exe_is_store, exe_is_fp;
    reg  [5:0]  exe_rob;
    reg  [1:0]  exe_epoch;
    reg  [31:0] exe_addr, exe_wdata, exe_wdata_hi;
    reg  [2:0]  exe_size;
    reg         exe_unsign, exe_dst_i, exe_dst_f;
    reg  [5:0]  exe_pdest_i, exe_pdest_f;
    reg  [4:0]  exe_stq_idx;
    reg  [2:0]  exe_lq_idx;
    reg  [5:0]  iss_rob;
    reg  [3:0]  dr_valid;
    reg  [3*5-1:0] dr_idx;
    reg  [2:0]  cmt_n;
    reg         mem_req_ready, mem_rsp_valid, mem_rsp_err;
    reg  [31:0] mem_rsp_rdata;
    reg  [3:0]  mem_rsp_tag;
    reg         st_xlate_en, st_xlate_ready, st_xlate_done, st_xlate_fault;
    reg  [3:0]  st_xlate_ctx;
    reg  [31:0] st_xlate_pa;

    lsq_simple u_lsu (
        .clk(clk), .rst_n(rst_n),
        .flush_all(flush_all), .squash(squash), .squash_idx(squash_idx),
        .rob_head(rob_head),
        .alloc_valid(alloc_valid), .alloc_rob(alloc_rob),
        .alloc_ok(), .alloc_idx(),
        .lalloc_valid(lalloc_valid), .lalloc_rob(lalloc_rob),
        .lalloc_ok(), .lalloc_idx(),
        .exe_valid(exe_valid), .exe_is_store(exe_is_store), .exe_is_fp(exe_is_fp),
        .exe_rob(exe_rob), .exe_epoch(exe_epoch),
        .exe_addr(exe_addr), .exe_wdata(exe_wdata), .exe_wdata_hi(exe_wdata_hi),
        .exe_size(exe_size), .exe_unsign(exe_unsign),
        .exe_dst_i(exe_dst_i), .exe_dst_f(exe_dst_f),
        .exe_pdest_i(exe_pdest_i), .exe_pdest_f(exe_pdest_f),
        .exe_stq_idx(exe_stq_idx), .exe_lq_idx(exe_lq_idx),
        .iss_rob(iss_rob),
        .iss_ok(),
        .dr_empty_o(),
        .dr_valid(dr_valid), .dr_idx(dr_idx), .dr_room_ok(),
        .cmt_n(cmt_n),
        .mem_req_valid(), .mem_req_wen(), .mem_req_addr(), .mem_req_wdata(),
        .mem_req_wstrb(), .mem_req_tag(), .mem_req_ready(mem_req_ready),
        .mem_rsp_valid(mem_rsp_valid), .mem_rsp_rdata(mem_rsp_rdata),
        .mem_rsp_tag(mem_rsp_tag), .mem_rsp_err(mem_rsp_err),
        .exc_valid_o(), .exc_rob_o(), .exc_cause_o(), .exc_tval_o(),
        .wb_valid(), .wb_rob(), .wb_epoch(), .wb_dst_i(), .wb_dst_f(),
        .wb_pdest_i(), .wb_pdest_f(), .wb_data(), .wb_data_hi(), .wb_f64(),
        .st_done_valid(), .st_done_rob(), .st_done_epoch(),
        .st_xlate_en(st_xlate_en), .st_xlate_ctx(st_xlate_ctx),
        .st_xlate_valid(), .st_xlate_va(), .st_xlate_idx(), .st_xlate_ctx_o(),
        .st_xlate_ready(st_xlate_ready), .st_xlate_done(st_xlate_done),
        .st_xlate_pa(st_xlate_pa), .st_xlate_fault(st_xlate_fault)
    );

    reg [5:0] rob_l0, rob_l1;
    reg       pre_v0, pre_v1, post_v0, post_v1;
    reg [5:0] pre_rob0, pre_rob1;
    reg       is_ctl;
    reg [8*36-1:0] name;
    reg [5:0] head_v;

    always #5 clk = ~clk;

    initial begin
        head_v = 6'd63; is_ctl = 0; name = "UNSET";
        rob_l0 = 6'd63; rob_l1 = 6'd0;
        case (CASE)
            1: begin name = "L1_ROB_WRAP_HEAD63_CMT2"; head_v = 6'd63;
                       rob_l0 = 6'd63; rob_l1 = 6'd0; is_ctl = 0; end
            2: begin name = "L2_CTL_HEAD0_CMT2";        head_v = 6'd0;
                       rob_l0 = 6'd0;  rob_l1 = 6'd1; is_ctl = 1; end
            default: name = "BAD_CASE";
        endcase

        flush_all = 0; squash = 0; squash_idx = 0;
        rob_head = 0; cmt_n = 0;
        alloc_valid = 0; alloc_rob = 0;
        lalloc_valid = 0; lalloc_rob = 0;
        exe_valid = 0; exe_is_store = 0; exe_is_fp = 0; exe_rob = 0; exe_epoch = 0;
        exe_addr = 0; exe_wdata = 0; exe_wdata_hi = 0; exe_size = 0;
        exe_unsign = 0; exe_dst_i = 0; exe_dst_f = 0;
        exe_pdest_i = 0; exe_pdest_f = 0; exe_stq_idx = 0; exe_lq_idx = 0;
        iss_rob = 0; dr_valid = 0; dr_idx = 0;
        mem_req_ready = 1; mem_rsp_valid = 0; mem_rsp_err = 0;
        mem_rsp_rdata = 0; mem_rsp_tag = 0;
        st_xlate_en = 0; st_xlate_ctx = 0; st_xlate_ready = 1; st_xlate_done = 0;
        st_xlate_pa = 0; st_xlate_fault = 0;

        pre_v0 = 0; pre_v1 = 0; pre_rob0 = 0; pre_rob1 = 0;
        post_v0 = 1; post_v1 = 1;

        repeat (4) @(posedge clk);
        rst_n <= 1'b1;
        repeat (2) @(posedge clk);

        // 真实 D3 分配：两条 load，lane0 rob=rob_l0，lane1 rob=rob_l1
        lalloc_valid = 4'b0011;
        lalloc_rob[0*6 +: 6] = rob_l0;
        lalloc_rob[1*6 +: 6] = rob_l1;
        lalloc_rob[2*6 +: 6] = 6'd0;
        lalloc_rob[3*6 +: 6] = 6'd0;
        @(posedge clk); #1;
        lalloc_valid = 1'b0;
        pre_v0   = u_lsu.ld_v[0];
        pre_v1   = u_lsu.ld_v[1];
        pre_rob0 = u_lsu.ld_rob[0];
        pre_rob1 = u_lsu.ld_rob[1];

        // 提交窗口：head/ cmt_n 由 ROB 输入给出（受控）
        rob_head = head_v; cmt_n = 3'd2;
        @(posedge clk); #1;
        post_v0 = u_lsu.ld_v[0];
        post_v1 = u_lsu.ld_v[1];

        $display("CASE %0d %0s DUT head=%0d cmt_n=2 pre_alloc v0=%b rob0=%0d v1=%b rob1=%0d AFTER v0=%b v1=%b",
                 CASE, name, head_v, pre_v0, pre_rob0, pre_v1, pre_rob1, post_v0, post_v1);
        $display("CASE %0d %0s EXPECT both LQ slots released (v0=0,v1=0); spec ages=(rob-head)%%64 < 2",
                 CASE, name);

        if (!(pre_v0 && pre_v1 && (pre_rob0 == rob_l0) && (pre_rob1 == rob_l1))) begin
            $display("CASE %0d %0s RESULT=NO_CAPTURE (allocation/rob mismatch)", CASE, name);
        end else if (is_ctl) begin
            if ((post_v0 === 1'b0) && (post_v1 === 1'b0))
                $display("CASE %0d %0s RESULT=CONTROL_OK", CASE, name);
            else
                $display("CASE %0d %0s RESULT=CONTROL_FAIL", CASE, name);
        end else begin
            // 缺陷例：slot0(rob=63, age 0) 释放、slot1(rob=0, DUT age 65) 泄漏
            if ((post_v0 === 1'b0) && (post_v1 === 1'b1))
                $display("CASE %0d %0s RESULT=DEFECT_REPRODUCED", CASE, name);
            else
                $display("CASE %0d %0s RESULT=DEFECT_NOT_REPRODUCED", CASE, name);
        end
        $finish;
    end

endmodule
