//==============================================================================
// sim/unit/dyn_probe_n4_core.sv —— EXP-N4：整数 PRF **写口**动态并发度探针（采样核）
//------------------------------------------------------------------------------
// 目的：回答 answer.md §六/§七 的**决策门**问题——"当前 workload 下整数 PRF 每拍
//       实际写回条数分布与高水位"，以决定 6W→4W 是否可行。
//
// 【设计纪律】（与 dyn_probe_core.sv 同一口径）
//   · **不修改任何产品 RTL**：本核与 dyn_probe_n4_*.sv 只做**只读层次引用**，
//     逐拍把**原始小位宽位掩码**写进 CSV；全部统计（直方图/高水位/并发组合）由
//     确定性脚本 `fpga/scratch/n4_analyze.py` 完成（PASS/FAIL 由脚本判，不靠人工数数）。
//   · 文件名**不匹配** `sim/unit/tb_*.sv`（regress.sh 的通配）⇒ 不进入既有 iverilog
//     回归、不新增/不影响任何 PASS 判据。
//   · 输出仅 CSV 一行表头 + 每拍一行；不打印任何含 PASS 字样的文案。
//
// 【列定义】（全部为**原始小位宽**，popcount 由分析器算 ⇒ RTL 侧零归约逻辑）
//   bench  基准编号（锁步 = 程序号 pi；IPC = 0；core_top_2b = pid）
//   row    探针自己的行号（每基准独立从 0 计；用于交叉核对拍数/剔除预热窗）
//   wv     `wbi_v`            —— 6 个整数写回源的**有效**位（真源 backend_top.v:1727）
//   we     `iprf_we`          —— 整数 PRF 实际写使能 = `wbi_v & wbi_keep`（:2132）
//   wx     `wbi_v & ~(wbi_keep 已定义位)` —— **"有效写回却带未定 keep"** 的位掩码。
//          ★ 为什么需要它：`wbi_keep` 由 ROB 索引锁存比较而来，复位后最初若干拍那些
//            索引锁存仍是 x ⇒ 整条 `wbi_keep` 向量按 `%0d` 打印就是 'x'（**只要有 1 位
//            未定就整值打成 x**）。若只看整值，无法区分"未定位都在 wv=0 的无关位上"
//            还是"某个真写回的 keep 未定"。本列逐位用 case-equality 判别，
//            **恒为 0** 是"写口有效判据逐位确定"的可证条件（分析器 fail-closed 断言）。
//   fwe    `fprf_we`          —— 浮点 PRF 写使能（2 bit，:2150；顺带采集）
//   位序（与 backend_top.v:1727 拼接顺序一致；MSB..LSB = bit5..bit0）：
//     bit0 = ALU0（x_i2_v[0] & a0_wb_i）
//     bit1 = ALU1（x_i2_v[1] & a1_wb_i）
//     bit2 = BRU （x_i2_v[2] & bru_wb_i）
//     bit3 = MDU （mdu_wb_v）
//     bit4 = LSU （lsu_wb_v & lsu_wb_di）
//     bit5 = FPU （fpu_wb_v & fpu_wb_i，即 FP→整数寄存器）
//==============================================================================
`timescale 1ns / 1ps

module dyn_probe_n4_core #(
    parameter FNAME = "n4.csv"
) (
    input  wire        clk,
    input  wire        rst_n,
    input  integer     bench,
    input  wire [5:0]  wv,        // wbi_v
    input  wire [5:0]  we,        // iprf_we
    input  wire [5:0]  wx,        // wbi_v & ~wbi_keep_def（必须恒 0）
    input  wire [1:0]  fwe        // fprf_we
);

    integer fd;
    integer row;
    integer last_bench;
    integer flush_i;

    initial begin
        fd         = $fopen(FNAME, "w");
        row        = 0;
        last_bench = -1;
        flush_i    = 0;
        if (fd == 0)
            $display("DYN_PROBE_N4: 无法打开输出文件 %0s", FNAME);
        else
            $fwrite(fd, "bench,row,wv,we,wx,fwe\n");
    end

    always @(posedge clk) begin
        if (rst_n && (fd != 0)) begin
            if (bench != last_bench) begin
                last_bench = bench;
                row        = 0;
            end
            $fwrite(fd, "%0d,%0d,%0d,%0d,%0d,%0d\n",
                bench, row, wv, we, wx, fwe);
            row     = row + 1;
            flush_i = flush_i + 1;
            if (flush_i >= 128) begin
                flush_i = 0;
                $fflush(fd);
            end
        end
    end

    //   结束前兜底 flush（$finish/$fatal 由 vvp 关闭文件时也会 flush；双保险）
    final begin
        if (fd != 0) $fflush(fd);
    end

endmodule
