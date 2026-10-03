//==============================================================================
// sim/unit/dyn_probe_core.sv —— 后端动态行为数据采集探针（通用采样核）
//------------------------------------------------------------------------------
// 目的：为「6→3 集群 IQ / PRF operand collector / ROB 稀疏更新」三项架构决策
//       采集三组动态数据（见 fpga/scratch/dyn_behavior.md）。
//
// 【设计纪律】
//   · 本模块与 dyn_probe_*.sv **不修改任何产品 RTL**：只从 TB 层次引用读信号，
//     逐拍把**已归约好的小整数**写进 CSV；全部统计由确定性脚本
//     `fpga/scratch/dyn_analyze.py` 完成（PASS/FAIL 由脚本判，不靠人工数数）。
//   · 文件名**不匹配** `sim/unit/tb_*.sv`（regress.sh 的通配）⇒ 不进入既有
//     iverilog 回归、不新增/不影响任何 PASS 判据。
//   · 输出仅 CSV 一行表头 + 每拍一行；不打印任何含 PASS 字样的文案。
//
// 【列定义】（表头自描述；字段口径见 dyn_behavior.md §0）
//   bench     基准编号（锁步 = 程序号 pi；IPC = 0；core_top_2b = pid）
//   row       探针自己的行号（每基准独立从 0 计；用于交叉核对拍数）
//   iqf0..5   6 个 IQ 的 **free_cnt（剩余空位）**（真源 backend_top.v:449/1115..1200）
//             ⇒ occupancy = depth[q] − iqfq；full ⇔ iqfq==0
//   d0..5     6 个 IQ 本拍**派发写入条数**（iq_wv_g 的每队列 4 bit 段，已与
//             disp_fire_w 相与，见 backend_top.v:974）
//   iss       iq_iss_v（6 bit，每队列 iss_fire = sel_valid & iss_ready）
//   blk       6 bit：sel_valid=1 且本拍因结构（iss_ready=0）未发射
//   rob       rob_cnt_w（ROB 有效项数 0..64）
//   utr/uff/uexc/ucsr   upd_{tr,ff,exc,csr}_valid（ucsr 恒 0：backend_top.v:1793 死口）
//   iread     整数执行期读请求数（0..11；= 6 个 I2/E1 uop 的 s1i/s2i use 之和）
//   csrread   其中属 CSR 指令的（0/1）
//   creadi    整数提交期读（0..4；端口 11..14，判据 = 提交 lane 的 rd_i_wen）
//   creadcsr  CSR 提交期读（端口 15，判据 = csr_cmt_we）
//   fread     浮点执行期读（0..4；FPU s1f/s2f/s3f + LSU 的 s2f 存数据）
//   creadf    浮点提交期读（0..4；端口 4..7，判据 = 提交 lane 的 rd_f_wen）
//   ncmt/nbr/nfp/nexc   本拍提交条数 / 其中分支 / FP / 带 D1 预译码异常码
//   trap      trap_valid_o（提交点陷阱脉冲）
//==============================================================================
`timescale 1ns / 1ps

module dyn_probe_core #(
    parameter FNAME = "dyn.csv"
) (
    input  wire        clk,
    input  wire        rst_n,
    input  integer     bench,
    input  wire [29:0] iq_free_p,   // {iq0,iq1,iq2,iq3,iq4,iq5} 各 5 bit
    input  wire [23:0] disp_p,      // 6 x 4 bit
    input  wire [5:0]  iss_p,
    input  wire [5:0]  blk_p,
    input  wire [7:0]  rob_cnt,
    input  wire        utr,
    input  wire        uff,
    input  wire        uexc,
    input  wire        ucsr,
    input  wire [4:0]  iread,
    input  wire        csrread,
    input  wire [2:0]  creadi,
    input  wire        creadcsr,
    input  wire [2:0]  fread,
    input  wire [2:0]  creadf,
    input  wire [2:0]  ncmt,
    input  wire [2:0]  nbr,
    input  wire [2:0]  nfp,
    input  wire [2:0]  nexc,
    input  wire        trap
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
            $display("DYN_PROBE: 无法打开输出文件 %0s", FNAME);
        else
            $fwrite(fd, "bench,row,iqf0,iqf1,iqf2,iqf3,iqf4,iqf5,d0,d1,d2,d3,d4,d5,iss,blk,rob,utr,uff,uexc,ucsr,iread,csrread,creadi,creadcsr,fread,creadf,ncmt,nbr,nfp,nexc,trap\n");
    end

    always @(posedge clk) begin
        if (rst_n && (fd != 0)) begin
            if (bench != last_bench) begin
                last_bench = bench;
                row        = 0;
            end
            $fwrite(fd, "%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d\n",
                bench, row,
                iq_free_p[4:0],   iq_free_p[9:5],   iq_free_p[14:10],
                iq_free_p[19:15], iq_free_p[24:20], iq_free_p[29:25],
                disp_p[3:0],  disp_p[7:4],  disp_p[11:8],
                disp_p[15:12], disp_p[19:16], disp_p[23:20],
                iss_p, blk_p, rob_cnt,
                utr, uff, uexc, ucsr,
                iread, csrread, creadi, creadcsr, fread, creadf,
                ncmt, nbr, nfp, nexc, trap);
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
