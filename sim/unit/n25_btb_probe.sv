//==============================================================================
// sim/unit/n25_btb_probe.sv —— N25：前端 TB（tb_front4_frontend，BTB 提交训练压力）
//                              上的 BTB 同址同拍读写实测
//------------------------------------------------------------------------------
// 目的：锁步 5 程序里 BTB 碰撞 = 0（见 n25_collision_probe.sv），但这不足以证明
//       "BTB 碰撞不可达"。本探针挂到 **前端单元 TB**（大量 train_cond 更新 + 连续查表，
//       tb_front4_frontend.sv 的 C1–C6 场景），用同一套判据实测真实取指/训练流下的
//       BTB 同址同拍次数与命中判决分叉次数。
//   · 碰撞判据：`a_en && b_en && a_addr == b_addr`（SDP：A 口写 / B 口读；way0/way1 各一份）
//   · 分叉判据：read_first 用**当拍读回值**比 tag，no_change 用**上一拍输出保持值**比 tag；
//     两者命中判决不一致的拍计一次（tag 位段见 bpu_btb.v:84-91）
// 纪律：只读层次引用；文件名不以 tb_ 开头 ⇒ 不进 scripts/regress.sh；不打印 PASS 兜底文案。
//
// 运行：见 fpga/scratch/n25_run.sh（第 6b 步）
//==============================================================================
`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"
`include "rtl/front4/front4_params.vh"

module n25_btb_probe;

    tb_front4_frontend_top u_tb ();

    wire clk   = u_tb.clk;
    wire rst_n = u_tb.rst_n;

    wire        b0_aen = u_tb.u_dut.u_bpu.u_btb.u_way0.a_en;
    wire [9:0]  b0_aad = u_tb.u_dut.u_bpu.u_btb.u_way0.a_addr;
    wire        b0_ben = u_tb.u_dut.u_bpu.u_btb.u_way0.b_en;
    wire [9:0]  b0_bad = u_tb.u_dut.u_bpu.u_btb.u_way0.b_addr;
    wire [65:0] b0_do  = u_tb.u_dut.u_bpu.u_btb.u_way0.b_dout;
    wire        b1_aen = u_tb.u_dut.u_bpu.u_btb.u_way1.a_en;
    wire [9:0]  b1_aad = u_tb.u_dut.u_bpu.u_btb.u_way1.a_addr;
    wire        b1_ben = u_tb.u_dut.u_bpu.u_btb.u_way1.b_en;
    wire [9:0]  b1_bad = u_tb.u_dut.u_bpu.u_btb.u_way1.b_addr;
    wire [65:0] b1_do  = u_tb.u_dut.u_bpu.u_btb.u_way1.b_dout;
    wire [29:0] btq_tag = u_tb.u_dut.u_bpu.u_btb.lu_tag_q;
    wire        btq_val = u_tb.u_dut.u_bpu.u_btb.lu_valid_q;

    wire [1:0] btb_col_c = { (b1_aen & b1_ben & (b1_aad == b1_bad)),
                             (b0_aen & b0_ben & (b0_aad == b0_bad)) };

    reg rst_a;
    reg [1:0] col_a;
    reg [65:0] hd0_a, hd1_a;
    always @(posedge clk) begin
        rst_a <= rst_n;
        col_a <= btb_col_c;
        hd0_a <= b0_do;
        hd1_a <= b1_do;
    end

    integer cyc = 0, col0 = 0, col1 = 0, valdiff = 0, hitdiff = 0, falsehit = 0;
    reg hit_rf, hit_nc;

    always @(posedge clk) if (rst_a) begin
        cyc = cyc + 1;
        if (col_a[0]) begin
            col0 = col0 + 1;
            if (b0_do !== hd0_a) valdiff = valdiff + 1;
            hit_rf = btq_val & b0_do[0]      & (b0_do[30:1]      == btq_tag);
            hit_nc = btq_val & hd0_a[0]      & (hd0_a[30:1]      == btq_tag);
            if (hit_rf !== hit_nc) hitdiff = hitdiff + 1;
            if (hit_nc & ~hit_rf)  falsehit = falsehit + 1;
        end
        if (col_a[1]) begin
            col1 = col1 + 1;
            if (b1_do !== hd1_a) valdiff = valdiff + 1;
            hit_rf = btq_val & b1_do[0]      & (b1_do[30:1]      == btq_tag);
            hit_nc = btq_val & hd1_a[0]      & (hd1_a[30:1]      == btq_tag);
            if (hit_rf !== hit_nc) hitdiff = hitdiff + 1;
            if (hit_nc & ~hit_rf)  falsehit = falsehit + 1;
        end
    end

    final begin
        $display("N25_BTB_PROBE,cyc=%0d,col_way0=%0d,col_way1=%0d,btb_col=%0d,btb_valdiff=%0d,btb_hitdiff=%0d,falsehit=%0d",
                 cyc, col0, col1, col0 + col1, valdiff, hitdiff, falsehit);
        $fflush();
    end

endmodule
