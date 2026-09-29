//==============================================================================
// sim/unit/tb_back2_rob_wide_mem.sv —— `rob_wide_mem` 存取一致性单测（B1 自检）
//   · 覆盖：4 bank 并行写/读、连续索引跨 bank、同步读 1 拍延迟、read_first 口径、
//            bank 内偏移边界（0/31）、随机 200 轮读回逐位一致。
//==============================================================================
`timescale 1ns / 1ps

module tb_back2_rob_wide_mem;
    localparam integer NW = 4, BW = 32, DW = 416, OW = 5;

    reg               clk = 0, rst_n = 0;
    reg  [OW-1:0]     woff_a [0:NW-1];
    reg  [OW-1:0]     roff_a [0:NW-1];
    reg  [DW-1:0]     wdata_a[0:NW-1];
    reg  [NW-1:0]     we = 0, re = 0;
    wire [NW*OW-1:0]  woff, roff;
    wire [NW*DW-1:0]  wdata, rdata;

    genvar gi;
    generate
    for (gi = 0; gi < NW; gi = gi + 1) begin : g_drv
        assign woff [gi*OW +: OW] = woff_a [gi];
        assign roff [gi*OW +: OW] = roff_a [gi];
        assign wdata[gi*DW +: DW] = wdata_a[gi];
    end
    endgenerate

    rob_wide_mem #(.NW(NW), .BW(BW), .DW(DW), .OW(OW), .CHK(1)) u_dut (
        .clk(clk), .rst_n(rst_n), .we(we), .woff(woff), .wdata(wdata),
        .re(re), .roff(roff), .rdata(rdata));

    always #5 clk = ~clk;

    reg [DW-1:0] ref_mem [0:NW*BW-1];      // 参考模型：bank*BW + off
    reg          written [0:NW*BW-1];      // 只比对"已写过"的位置（未写位在真实 BRAM 里本就是未知）
    integer i, n, errs;
    reg [DW-1:0] got;

    task automatic wr_rd(input [NW-1:0] wmask, input [NW-1:0] rmask);
        begin
            we = wmask; re = rmask;
            @(posedge clk); #1;
            for (i = 0; i < NW; i = i + 1)
                if (wmask[i]) begin
                    ref_mem[i*BW + woff_a[i]] = wdata_a[i];             // 写生效
                    written [i*BW + woff_a[i]] = 1'b1;
                end
            we = 0;
            @(posedge clk); #1;                                          // 同步读数据落地
            re = 0;
        end
    endtask

    task automatic chk_all(input [NW-1:0] rmask, input [127:0] tag, input [31:0] tn);
        begin
            for (i = 0; i < NW; i = i + 1)
                if (rmask[i] && written[i*BW + roff_a[i]]) begin
                    got = rdata[i*DW +: DW];
                    if (got !== ref_mem[i*BW + roff_a[i]]) begin
                        errs = errs + 1;
                        $display("FAIL %0s T%0d bank %0d off %0d: got=%h exp=%h",
                                 tag, tn, i, roff_a[i], got, ref_mem[i*BW + roff_a[i]]);
                    end
                end
        end
    endtask

    initial begin
        errs = 0;
        for (i = 0; i < NW*BW; i = i + 1) begin ref_mem[i] = {DW{1'b0}}; written[i] = 1'b0; end
        for (i = 0; i < NW; i = i + 1) begin
            woff_a[i] = 0; roff_a[i] = 0; wdata_a[i] = {DW{1'b0}};
        end
        repeat (3) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        // ---- T1：4 bank 并行写（偏移 0）→ 读回 ----
        for (i = 0; i < NW; i = i + 1) begin
            woff_a[i] = 5'd0; roff_a[i] = 5'd0;
            wdata_a[i] = {DW{1'b0}} + (i + 1);
        end
        wr_rd(4'hF, 4'hF);
        chk_all(4'hF, "T1-4bank", 0);
        $display("== T1 4 bank 并行写+读：errs=%0d", errs);

        // ---- T2：连续索引跨 bank（偏移 1）----
        for (i = 0; i < NW; i = i + 1) begin
            woff_a[i] = 5'd1; roff_a[i] = 5'd1;
            wdata_a[i] = {DW{1'b1}} - (i + 4);
        end
        wr_rd(4'hF, 4'hF);
        chk_all(4'hF, "T2-cross", 0);
        $display("== T2 连续索引跨 bank：errs=%0d", errs);

        // ---- T3：bank 内偏移边界 31 ----
        for (i = 0; i < NW; i = i + 1) begin
            woff_a[i] = 5'd31; roff_a[i] = 5'd31;
            wdata_a[i] = {DW{1'b0}} + 32'hDEAD_0000 + i;
        end
        wr_rd(4'hF, 4'hF);
        chk_all(4'hF, "T3-off31", 0);
        $display("== T3 边界偏移 31：errs=%0d", errs);

        // ---- T4：随机 200 轮（随机 mask / 地址）----
        for (n = 0; n < 200; n = n + 1) begin
            for (i = 0; i < NW; i = i + 1) begin
                woff_a[i][4:0] = $random;
                roff_a[i]      = woff_a[i];
                wdata_a[i]     = {$random, $random, $random, $random, $random,
                                  $random, $random, $random, $random, $random,
                                  $random, $random, $random};
            end
            wr_rd($random, 4'hF);
            chk_all(4'hF, "T4-rand", n);
        end
        $display("== T4 随机 200 轮后累计 errs=%0d", errs);

        //   锚点口径（scripts/regress.sh）：恰好一行 `TB_BACK2_ROB_WIDE_MEM: PASS`
        if (errs == 0) $display("TB_BACK2_ROB_WIDE_MEM: PASS");
        else           $display("TB_BACK2_ROB_WIDE_MEM FAIL errs=%0d", errs);
        $finish;
    end
endmodule
