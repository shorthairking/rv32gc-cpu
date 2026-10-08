//==============================================================================
// sim/unit/dyn_probe_n6_core.sv —— EXP-N6：**FPU 动态**探针（采样核，只读）
//------------------------------------------------------------------------------
// 目的（answer.md §2.1）：回答"FPU 是否真的需要双并发"以及"哪些 FP op 是面积大头"。
//
// 【设计纪律】（与 dyn_probe_n4_core.sv 同一口径）
//   · **不修改任何产品 RTL**：本核与 dyn_probe_n6_*.sv 只做**只读层次引用**，
//     逐拍把**原始小位宽向量**写进 CSV；全部统计（直方图/占用/opcode 分类）由
//     确定性脚本 `fpga/scratch/n6_analyze.py` 完成（PASS/FAIL 由脚本判）。
//   · 文件名**不匹配** `sim/unit/tb_*.sv`（regress.sh 的通配）⇒ 不进入既有 iverilog
//     回归、不新增/不影响任何 PASS 判据。
//   · 输出仅 CSV 一行表头 + 每拍一行；本文件**不打印任何含 PASS 字样的文案**。
//
// 【列定义】（全部原始小位宽；popcount/分类由分析器算 ⇒ RTL 侧零归约逻辑）
//   bench  基准编号（锁步 = 程序号 pi；IPC = 0；core_top_2b = pid）
//   row    探针自己的行号（每基准独立从 0 计；用于剔除预热窗）
//   req    `i5_sel_v`            —— IQ5（FPU 队列，深度 6）头项有效 = **FPU 发射请求**
//   rdy    `iq_base_rdy[5]`      —— FPU 基础发射许可（FPU 空闲 ∧ 无 CSR→FP 互锁）
//   rdym   `iwm_gnt[5]`          —— 宽操作数读口仲裁获准（拿不到 ⇒ 本拍不出队）
//   gnt    `iq_iss_v[5]`         —— 发射兑现（出队）
//   acc    `x_i2_v[5]`           —— E1 有效 = `fpu.req_valid`（送进 FPU 的候选）
//   dan    `fpu.disp_any`        —— **FPU 真正接收**本条（= req_valid ∧ ds_can_disp）
//   dds    `fpu.disp_ds`         —— 本条是 div/sqrt 并被接收（start 脉冲）
//   op     `fpu.fp_op[6:0]`      —— 归一化 FP 操作码（真源 fpu.v 头注 §1；26–29=FMA 族）
//   fmt    `fpu.fmt[1:0]`        —— 00=S / 01=D
//   scv    `fpu.sc_v[7:0]`       —— 非 div/sqrt 流水线 8 级占用位（FPU_SC_LAT=8）
//   busy   `fpu.busy`            —— 冻结前端（div/sqrt 忙 ∨ 在途非 div/sqrt）
//   dsp    `fpu.ds_pend`         —— div/sqrt 在途登记
//   dsb    `fpu.ds_busy`         —— div/sqrt 迭代器忙
//   finv   `fpu_if_v`            —— backend 侧"FPU 至多 1 条在飞"登记
//   opx    `acc ∧ ¬(op 逐位已定义)` —— **白证列**：被接收的 FP 必须是已定义操作码（恒 0）
//   acx    `acc ∧ ¬(fmt 逐位已定义)` —— 同上，fmt 必须已定义（恒 0）
//
// 【并发口径】本核是**单发射**（IQ5 每拍至多 1 条出队）⇒ "FPU 发射请求并发 ≥2"在
//   结构上恒为 0；真正决定"要不要多并发/多流水"的是 `scv` 的**在途占用直方图**：
//   P(|scv| ≥ 2) 就是"同一时刻 FPU 内有多条非 div/sqrt 在途"的拍占比。
//==============================================================================
`timescale 1ns / 1ps

module dyn_probe_n6_core #(
    parameter FNAME = "n6.csv"
) (
    input  wire        clk,
    input  wire        rst_n,
    input  integer     bench,
    input  wire        req,
    input  wire        rdy,
    input  wire        rdym,
    input  wire        gnt,
    input  wire        acc,
    input  wire        dan,
    input  wire        dds,
    input  wire [6:0]  op,
    input  wire [1:0]  fmt,
    input  wire [7:0]  scv,
    input  wire        busy,
    input  wire        dsp,
    input  wire        dsb,
    input  wire        finv,
    input  wire        opx,
    input  wire        acx,
    input  wire        rdyx,
    input  wire        rdymx
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
            $display("DYN_PROBE_N6: 无法打开输出文件 %0s", FNAME);
        else
            $fwrite(fd, "bench,row,req,rdy,rdym,gnt,acc,dan,dds,op,fmt,scv,busy,dsp,dsb,finv,opx,acx,rdyx,rdymx\n");
    end

    always @(posedge clk) begin
        if (rst_n && (fd != 0)) begin
            if (bench != last_bench) begin
                last_bench = bench;
                row        = 0;
            end
            $fwrite(fd, "%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%b,%b,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d\n",
                bench, row, req, rdy, rdym, gnt, acc, dan, dds, op, fmt, scv,
                busy, dsp, dsb, finv, opx, acx, rdyx, rdymx);
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
