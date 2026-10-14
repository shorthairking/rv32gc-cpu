//==============================================================================
// sim/unit/dyn_probe_n21b_core.sv —— EXP-N21B：PRF 读口 pairwise 冲突矩阵
//                                     **只读逐拍采样核**（不改任何产品 RTL）
//------------------------------------------------------------------------------
// 用途：挂在既有 TB（tb_back2_lockstep / tb_core_top_2b / tb_back2_ipc /
//       n15s_fpstress_core）上，逐拍导出"每个 PRF 读口消费者是否本拍要这个口"的
//       **原始布尔位向量**，供 fpga/scratch/n21b_analyze.py 离线重算 pairwise 矩阵
//       （同拍同时请求次数/占比、让位周期、最长连续等待）。
//
// 【为什么采原始位而不是在 SV 里算矩阵】
//   · 探针只做**观测**（层次引用 + 写 CSV），全部统计由确定性分析器重算 ⇒ 可独立审查；
//   · 判定失败（矩阵与实际不符）只能来自数据本身，不能来自探针里的"聪明汇总"。
//
// 【CSV 列】bench,row,d
//   bench = TB 的基准编号（锁步 = 程序号；core_top_2b = pid；ipc = 0；压力档 = 见 wrapper）
//   row   = 该 bench 内采样行号（每 bench 从 0 计，与 dyn_probe_core 口径一致）
//   d     = 48 bit 十六进制位向量，逐位定义见 `sim/unit/dyn_probe_n21b_body.inc`
//
// 纪律：不打印任何含 PASS 字样的文案；文件名不匹配 tb_*.sv ⇒ 不进 regress.sh。
//==============================================================================
`timescale 1ns / 1ps

module n21b_prf_probe #(
    parameter FNAME = "fpga/scratch/n21b/n21b.csv"
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        en,          // 采样窗（与 TB 主流程一致；1 = 采）
    input  wire        rs,          // 1 = en 下降沿后不再采（与 en 同步即可，保留给 wrapper）
    input  integer     bench,
    input  wire [47:0] d
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
            $display("N21B_PROBE: 无法打开输出文件 %0s", FNAME);
        else
            $fwrite(fd, "bench,row,d\n");
    end

    always @(posedge clk) begin
        if (rst_n && en && rs && (fd != 0)) begin
            if (bench != last_bench) begin
                last_bench = bench;
                row        = 0;
            end
            $fwrite(fd, "%0d,%0d,%012x\n", bench, row, d);
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
