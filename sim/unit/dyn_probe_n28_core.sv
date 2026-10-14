//==============================================================================
// sim/unit/dyn_probe_n28_core.sv —— EXP-N28A：ROB 占用 / 分配停顿 **只读逐拍采样核**
//------------------------------------------------------------------------------
// 用途：挂在既有 TB（tb_back2_lockstep / tb_core_top_2b / tb_back2_ipc /
//       n15s_fpstress_core / dyn_probe_n28_robcore）上，逐拍导出 ROB 占用与
//       "因 ROB 满而未派发"的**原始布尔位**，供 fpga/scratch/n28_analyze.py
//       离线重算直方图 / 近满分档 / 停顿归因 / 64→48 余量判定。
//
// 【为什么采原始位而不是在 SV 里算统计】
//   · 探针只做观测（层次引用 + 写 CSV），全部统计由确定性分析器重算 ⇒ 可独立审查；
//   · 判定失败只能来自数据本身，不能来自探针里的"聪明汇总"。
//
// 【CSV 列】bench,row,cyc,d
//   bench = TB 的基准编号（锁步 = 程序号 pi；core_top_2b = pid；ipc = 0；
//           压力档 = wrapper 给的 N28_BENCH_ID）
//   row   = 该 bench 内采样行号（每 bench 从 0 计）
//   cyc   = **全局时钟拍号**（每个 posedge 无条件 +1，含未采样的复位拍）
//           ★ 存在的理由：TB 在程序边界复位，而探针只在 rst_n==1 时采样 ⇒
//             "同 bench 且 row 连续"**不等于**"时钟拍连续"（复位期间有空洞）。
//             占用演化恒等式 I7 只在 `cyc` 逐拍连续时才成立 ⇒ 分析器按 cyc 判连续性。
//   d     = 64 bit 十六进制位向量，逐位定义见 `sim/unit/dyn_probe_n28_body.inc`
//
// 【逐拍恒等式（分析器 fail-closed 核对，见 n28_analyze.py §3）】
//   I1 rob_cnt ≤ ROB_N(64)                       （rob.v §5.4：cnt 最大 64）
//   I2 d1_n == popcount(d1_v)
//   I3 cmt_fire == (cmt_n != 0)
//   I4 all_other_ok == AND(各门控位)             （与 backend_top:1023-1026 同式）
//   I5 disp_fire == (d1_v!=0) & all_other_ok &  alloc_ready
//   I6 stall     == (d1_v!=0) & all_other_ok & ~alloc_ready
//   I7 占用演化（rob.v:702-707 逐字）：
//        flush 拍 : cnt[t+1] == 0
//        squash 拍: cnt[t+1] == ((squash_idx[t] - head[t]) mod 64) + 1
//        正常拍   : cnt[t+1] == cnt[t] - cmt_n[t] + (disp_fire[t] ? d1_n[t] : 0)
//      （仅在**同 bench 且 row 连续**的相邻两行上核对）
//   I7 把"占用序列 + 派发/提交/冲刷"钉死成一组互相约束的量：任何一处数据被篡改/
//      位宽截断/采样错拍，都会在分析器里报违例（注入反证见 n28_run.sh --inject）。
//
// 纪律：不打印任何含 PASS 字样的文案；文件名不匹配 tb_*.sv ⇒ 不进 regress.sh。
//==============================================================================
`timescale 1ns / 1ps

module n28_rob_probe #(
    parameter FNAME = "fpga/scratch/n28/n28.csv"
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        en,          // 采样窗（1 = 采）
    input  integer     bench,
    input  wire [63:0] d
);
    integer fd;
    integer row;
    integer last_bench;
    integer flush_i;
    integer cyc;                    // 全局时钟拍号（含未采样拍）

    initial begin
        fd         = $fopen(FNAME, "w");
        row        = 0;
        last_bench = -1;
        flush_i    = 0;
        cyc        = 0;
        if (fd == 0)
            $display("N28_PROBE: 无法打开输出文件 %0s", FNAME);
        else
            $fwrite(fd, "bench,row,cyc,d\n");
    end

    always @(posedge clk) cyc <= cyc + 1;

    always @(posedge clk) begin
        if (rst_n && en && (fd != 0)) begin
            if (bench != last_bench) begin
                last_bench = bench;
                row        = 0;
            end
            $fwrite(fd, "%0d,%0d,%0d,%016x\n", bench, row, cyc, d);
            row     = row + 1;
            flush_i = flush_i + 1;
            if (flush_i >= 128) begin
                flush_i = 0;
                $fflush(fd);
            end
        end
    end

    final begin
        if (fd != 0) $fflush(fd);
    end
endmodule
