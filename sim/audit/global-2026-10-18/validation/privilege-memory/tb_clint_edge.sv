//==============================================================================
// tb_clint_edge.sv —— CLINT MTIP 在 mtime==mtimecmp 的边界（P1-09）
//------------------------------------------------------------------------------
// 目的: 静态发现 clint.v:123 用 `mtime > mtimecmp`，规范要求 mtime >= mtimecmp
//       时 MTIP pending。用真实 MMIO 写口把 mtime 与 mtimecmp **持续保持相等**
//       多个周期（写 mtime 优先于自增），排除“一拍传播延迟”的解释。
// 证据等级: clint 模块级（真实 req_valid/req_write/req_addr/req_wdata 写口 +
//       resp 读回校验），不含 mmio_route/top 集成。
// 用法: iverilog ... -s tb_clint_edge -P tb_clint_edge.CASE=<n>
// 判据: B1(T-1)/B3(T+1) 为控制；B2(T==) 为缺陷例。
//==============================================================================
`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"

module tb_clint_edge #(parameter integer CASE = 1) ();

    `define CLINT_MTIMECMP_LO `RV32GC_CLINT_MTIMECMP_OFF
    `define CLINT_MTIMECMP_HI `RV32GC_CLINT_MTIMECMPH_OFF
    `define CLINT_MTIME_LO    `RV32GC_CLINT_MTIME_OFF
    `define CLINT_MTIME_HI    `RV32GC_CLINT_MTIMEH_OFF

    reg         clk = 1'b0;
    reg         rst_n = 1'b0;
    reg         req_valid, req_write;
    reg  [31:0] req_addr, req_wdata;
    reg  [3:0]  req_wstrb;
    wire [31:0] resp_rdata;
    wire        resp_hit;
    wire        msip_o, mtip_o;

    clint u_dut (
        .aclk(clk), .aresetn(rst_n),
        .req_valid(req_valid), .req_write(req_write),
        .req_addr(req_addr), .req_wdata(req_wdata), .req_wstrb(req_wstrb),
        .resp_rdata(resp_rdata), .resp_hit(resp_hit),
        .msip_o(msip_o), .mtip_o(mtip_o)
    );

    localparam [63:0] T = 64'h0000_0000_0000_1000;

    reg  [63:0] target_mtime;
    reg         is_ctl;
    reg         exp_mtip;
    reg  [8*36-1:0] name;
    integer     i, ok_cnt, hit_cnt, rd_ok;
    reg  [63:0] rb_mtime, rb_cmp;

    always #5 clk = ~clk;

    task wr(input [31:0] a, input [31:0] d);
        begin
            req_valid = 1'b1; req_write = 1'b1; req_addr = a; req_wdata = d; req_wstrb = 4'hF;
            @(posedge clk); #1;
            req_valid = 1'b0; req_write = 1'b0;
        end
    endtask

    task rd(input [31:0] a, output [31:0] d, output hit);
        begin
            req_valid = 1'b1; req_write = 1'b0; req_addr = a; req_wdata = 0; req_wstrb = 4'h0;
            #1; d = resp_rdata; hit = resp_hit;
            @(posedge clk); #1;
            req_valid = 1'b0; req_write = 1'b0;
        end
    endtask

    reg [31:0] rdv; reg rdh;

    initial begin
        target_mtime = T; is_ctl = 1; exp_mtip = 0; name = "UNSET";
        case (CASE)
            1: begin name = "B1_CTL_MTIME_T_MINUS_1"; target_mtime = T - 1; is_ctl = 1; exp_mtip = 0; end
            2: begin name = "B2_MTIME_EQ_MTIMECMP";   target_mtime = T;     is_ctl = 0; exp_mtip = 1; end
            3: begin name = "B3_CTL_MTIME_T_PLUS_1";  target_mtime = T + 1; is_ctl = 1; exp_mtip = 1; end
            default: name = "BAD_CASE";
        endcase

        req_valid = 0; req_write = 0; req_addr = 0; req_wdata = 0; req_wstrb = 0;
        repeat (4) @(posedge clk);
        rst_n <= 1'b1;
        repeat (2) @(posedge clk);

        // mtimecmp = T（低/高字分开写）
        wr(`CLINT_MTIMECMP_LO, T[31:0]);
        wr(`CLINT_MTIMECMP_HI, T[63:32]);

        // 读回 mtimecmp，确认写入生效
        rd(`CLINT_MTIMECMP_LO, rdv, rdh); rb_cmp[31:0]  = rdv;
        rd(`CLINT_MTIMECMP_HI, rdv, rdh); rb_cmp[63:32] = rdv;

        // 连续 16 拍保持 mtime == target_mtime（每拍软件写 mtime，优先于 +1）
        ok_cnt = 0; hit_cnt = 0;
        for (i = 0; i < 16; i = i + 1) begin
            req_valid = 1'b1; req_write = 1'b1; req_addr = `CLINT_MTIME_LO;
            req_wdata = target_mtime[31:0]; req_wstrb = 4'hF;
            @(posedge clk); #1;
            if (mtip_o) ok_cnt = ok_cnt + 1;
            // 每拍读回 mtime（组合读，不打乱写入节奏）
            req_write = 1'b0; req_addr = `CLINT_MTIME_LO;
            #1; if (resp_hit && (resp_rdata == target_mtime[31:0])) hit_cnt = hit_cnt + 1;
        end
        req_valid = 1'b0; req_write = 1'b0; req_wstrb = 4'h0;
        rd(`CLINT_MTIME_LO, rdv, rdh); rb_mtime[31:0]  = rdv;
        rd(`CLINT_MTIME_HI, rdv, rdh); rb_mtime[63:32] = rdv;
        rd_ok = (rb_cmp == T) && (hit_cnt == 16);

        $display("CASE %0d %0s DUT mtime_target=0x%016x mtimecmp=0x%016x mtip_asserted=%0d/16 readback_ok=%0d rb_mtime=0x%016x rb_cmp=0x%016x",
                 CASE, name, target_mtime, T, ok_cnt, rd_ok, rb_mtime, rb_cmp);
        $display("CASE %0d %0s EXPECT (mtime >= mtimecmp) => mtip=1 every cycle; case_mode=%0s exp_mtip=%b",
                 CASE, name, (is_ctl ? "control" : "defect"), exp_mtip);

        if (CASE == 2) begin
            // 缺陷例：16 拍持续相等，DUT 仍 0 次置位
            if (rd_ok && (ok_cnt == 0))
                $display("CASE %0d %0s RESULT=DEFECT_REPRODUCED", CASE, name);
            else
                $display("CASE %0d %0s RESULT=DEFECT_NOT_REPRODUCED (ok_cnt=%0d readback_ok=%0d)", CASE, name, ok_cnt, rd_ok);
        end else begin
            if (rd_ok && (ok_cnt == (exp_mtip ? 16 : 0)))
                $display("CASE %0d %0s RESULT=CONTROL_OK", CASE, name);
            else
                $display("CASE %0d %0s RESULT=CONTROL_FAIL (ok_cnt=%0d readback_ok=%0d)", CASE, name, ok_cnt, rd_ok);
        end
        $finish;
    end

endmodule
