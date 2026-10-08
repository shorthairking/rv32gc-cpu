//==============================================================================
// sim/unit/dyn_probe_n7_core.sv —— EXP-N7/N10：SQ bank + IQ arrival 只读采样核
//------------------------------------------------------------------------------
// 目的：为 answer.md §6（SQ address banking）与 §10（np_q 4W → 2W bank）提供**实测数据**：
//   ① SQ（`lsq_simple` 的 32 项 STQ）按 store **字地址低位 [1:0]**（= `stq_a[3:2]`）分 4 bank
//      后：逐拍每 bank 占用、全局 max bank 占用、bank 分布均匀性、以及 load 的 bank 内
//      转发候选数（= banking 后真正要比较的项数）。
//   ② 每个 IQ 每拍的**新派发条数**（arrivals）= `iq_wv_g[qi*4 +: 4]` 的 popcount。
//
// 【设计纪律】（与 dyn_probe_n4_core.sv 同一口径）
//   · **不修改任何产品 RTL**：本核与 dyn_probe_n7_*.sv|.inc 只做**只读层次引用**，
//     逐拍把**原始小位宽量**（掩码/索引/计数）写进 CSV；**全部统计**（直方图/高水位/
//     bank 冲突/候选削减比）由确定性脚本 `fpga/scratch/n7_analyze.py` 完成
//     （PASS/FAIL 由脚本判，不靠人工数数）。
//   · 文件名**不匹配** `sim/unit/tb_*.sv`（regress.sh 的通配）⇒ 不进入既有 iverilog 回归。
//   · 输出仅 CSV 一行表头 + 每拍一行；**不打印任何含 PASS 字样的文案**。
//
// 【列定义】（全部为原始量；十进制打印，与 n4 探针口径一致）
//   bench  基准编号（锁步 = 程序号 pi；IPC = 0；core_top_2b = pid）
//   row    探针自己的行号（每基准独立从 0 计）
//   sqv    `u_lsu.stq_v[31:0]`        —— STQ 占用位（bit i = 槽 i 已分配）
//   sqav   `u_lsu.stq_av[31:0]`       —— 地址已生成位（bit i = 槽 i 的地址已落地）
//   sqb0   `stq_a[15:0][3:2]`         —— 低 16 槽的**字地址低 2 位**（bank），每槽 2 bit
//   sqb1   `stq_a[31:16][3:2]`        —— 高 16 槽同上
//   stqc   `u_lsu.stq_cnt_o`          —— 产品自带占用计数（= popcount(stq_v) 的 fail-closed 交叉源）
//   e1st   `u_lsu.exe_valid & u_lsu.exe_is_store`  —— 本拍 E1 有一条 store 写地址
//   e1idx  `u_lsu.exe_stq_idx`        —— 该 store 的 STQ 槽
//   e1bk   `u_lsu.exe_addr[3:2]`      —— 该 store 的字地址 bank（本拍即将写入）
//   e1ld   `u_lsu.exe_valid & ~u_lsu.exe_is_store` —— 本拍 E1 有一条 load
//   e1lbk  `u_lsu.exe_addr[3:2]`      —— 该 load 的字地址 bank（banking 后只比这个 bank）
//   ast    `u_lsu.alloc_valid[3:0]`   —— D3 本拍为 store 分配的 STQ 槽（≤4/拍）
//   aidx   `u_lsu.alloc_idx[3:0]`     —— 各 lane 分到的 STQ 槽索引（4×5 bit）
//   iqwv   `iq_wv_g[23:0]`            —— 6 个 IQ × 4 写口的新派发位（每队列 4 bit）
//   iqcnt  `iq_cnt[0:5]`              —— 各 IQ 的**剩余空位**（free_cnt；6×5 bit）
//   disp   `disp_fire_w`              —— 本拍真正派发
//   d1v    `d1_v_q[3:0]`              —— D1 滑板有效 lane
//
// 【为什么"同拍多条 store 落同一 bank"在产品里几乎不可能发生】（写进报告，由数据佐证）
//   LSU 是**单发射**：`iq_base_rdy[4]`/`u_lsu.exe_valid` 每拍最多一条访存 ⇒ 地址生成
//   （bank 落位）每拍 ≤1 条。故 **E1 侧的同拍 bank 写冲突恒为 0**，banking 的收益在
//   **读侧**（forwarding 候选面），本核据此同时采集 `e1lbk` + `sqb*` 以直接算候选削减。
//==============================================================================
`timescale 1ns / 1ps

module dyn_probe_n7_core #(
    parameter FNAME = "n7.csv"
) (
    input  wire        clk,
    input  wire        rst_n,
    input  integer     bench,
    input  wire [31:0] sqv,
    input  wire [31:0] sqav,
    input  wire [31:0] sqb0,
    input  wire [31:0] sqb1,
    input  wire [5:0]  stqc,
    input  wire        e1st,
    input  wire [4:0]  e1idx,
    input  wire [1:0]  e1bk,
    input  wire        e1ld,
    input  wire [1:0]  e1lbk,
    input  wire [3:0]  ast,
    input  wire [19:0] aidx,
    input  wire [23:0] iqwv,
    input  wire [29:0] iqcnt,
    input  wire        disp,
    input  wire [3:0]  d1v
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
            $display("DYN_PROBE_N7: 无法打开输出文件 %0s", FNAME);
        else
            $fwrite(fd, "bench,row,sqv,sqav,sqb0,sqb1,stqc,e1st,e1idx,e1bk,e1ld,e1lbk,",
                        "ast,aidx,iqwv,iqcnt,disp,d1v\n");
    end

    always @(posedge clk) begin
        if (rst_n && (fd != 0)) begin
            if (bench != last_bench) begin
                last_bench = bench;
                row        = 0;
            end
            $fwrite(fd, "%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d\n",
                bench, row, sqv, sqav, sqb0, sqb1, stqc,
                e1st, e1idx, e1bk, e1ld, e1lbk,
                ast, aidx, iqwv, iqcnt, disp, d1v);
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
