//==============================================================================
// sim/unit/dyn_probe_n12_core.sv —— EXP-N12A：store→load 转发需求只读采样核
//------------------------------------------------------------------------------
// 目的：为 answer.md §2.1（EXP-N12A 动态需求统计）与 §2.2（EXP-N12B“单条完整覆盖
//   转发、其余等待”）提供**实测数据**。逐拍把**原始位向量**写进 CSV，全部统计
//   （直方图/比例/拼接判定）由确定性脚本 `fpga/scratch/n12_analyze.py` 完成。
//
// 【设计纪律】（与 dyn_probe_n7_core.sv 同一口径）
//   · **不修改任何产品 RTL**：本核与 dyn_probe_n12_*.sv|inc 只做**只读层次引用**。
//   · 文件名**不匹配** `sim/unit/tb_*.sv`（regress.sh 的通配）⇒ 不进既有 iverilog 回归。
//   · 输出仅 CSV 表头 + 每拍一行；**不打印任何含 PASS 字样的文案**。
//   · 所有 32 bit 量都经 `{1'b0, x}` 零扩展后 `%0d` 打印 ⇒ 不会出现负数（否则
//     bit31 置位时 `%d` 会按有符号打印成负数，破坏“只含数字与逗号”的 fail-closed 校验）。
//
// 【列定义】（全部为原始量；除 `bench/row` 外，与本次 E1 无关的列一律**零门控**，
//   避免把空闲拍上总线里的 x 写进 CSV；**有效拍上仍是真值** ⇒ x 不会被门控掩盖）
//   bench  基准编号（锁步/核心 TB = 程序号）
//   row    探针自己的行号（每 bench 独立从 0 计）
//   e1ld   本拍 E1 是一条**有效 load**（= 本次统计的采样点）
//   e1st   本拍 E1 是一条**有效 store**
//   ldblk  `backend_top.lsu_ld_block`：LSU 队头 load 被闸门挡住（含 iss_ok=0 或 csr）
//   issok  `lsq_simple.iss_ok` = `~any_unk_w`：无“更老未定址 store”则放行
//   sqv    `stq_v[31:0]`        —— STQ 占用位
//   sqav   `stq_av[31:0]`       —— 地址已生成位
//   unkv   `unk_v[31:0]`        —— 产品口径：v & ~av & (age < age_iss)（发射闸门用）
//   unke   v & ~av & (age < age_rob)，**以正在 E1 的这条 load 为基准**（物品 4 的口径）
//   live   `fw_live_e[31:0]`    —— 更老 且 地址已确认（转发树的**有效性门**）
//   ldm    `lmask_w8[7:0]`      —— 本次 load 的 8 B 窗字节掩码
//   sz     `exe_size[2:0]`      —— **log2(字节数)**：0=LB 1=LH 2=LW/FLW 3=LD/FLD
//   a2     `exe_addr[1:0]`      —— 字内字节偏移
//   a3     `exe_addr[2]`        —— 8 B 访问的对齐位（a3|a2!=0 ⇒ 非对齐 fld）
//   fp     `exe_is_fp`          —— 区分 LW/LD 与 FLW/FLD（`exe_size` 只给字节数）
//   fwh    `fwd_hit_w[7:0]`     —— 产品逐字节命中（∪ 所有更老 live store 的覆盖）
//   fwa    `fwd_all_w`          —— 产品“全字节命中”判据（可当拍全转发）
//   c0..c7 逐窗口字节 I 的**覆盖向量**：bit gj = “更老且已定址的 store gj 覆盖了
//          本次 load 的第 I 个字节”。与产品叶子的 `mt_w` 逐位同构（去掉 `in_w`）：
//            c_I[gj] = fw_live_e[gj] & (lo_w | hi_w)
//          ⇒ `(|c_I) & ldm[I]` 必须逐位等于 `fwh[I]`（分析器的行内恒等式；
//            该恒等式同时是**反证注入**的靶点）。
//
//   物品 1/2/3 由 c* 与 ldm 派生：“候选”= 与 load 字节范围真重叠的 c_I 合并向量；
//   “单条完整覆盖”= 存在单条 store 盖住 ldm 的全部字节；“拼接”= fwa=1 但无单条完整覆盖。
//==============================================================================
`timescale 1ns / 1ps

module dyn_probe_n12_core #(
    parameter FNAME = "n12.csv"
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [31:0] bench,
    input  wire        e1ld,
    input  wire        e1st,
    input  wire        ldblk,
    input  wire        issok,
    input  wire [31:0] sqv,
    input  wire [31:0] sqav,
    input  wire [31:0] unkv,
    input  wire [31:0] unke,
    input  wire [31:0] live,
    input  wire [7:0]  ldm,
    input  wire [2:0]  sz,
    input  wire [1:0]  a2,
    input  wire        a3,
    input  wire        fp,
    input  wire [7:0]  fwh,
    input  wire        fwa,
    input  wire [31:0] c0,
    input  wire [31:0] c1,
    input  wire [31:0] c2,
    input  wire [31:0] c3,
    input  wire [31:0] c4,
    input  wire [31:0] c5,
    input  wire [31:0] c6,
    input  wire [31:0] c7
);

    integer fd;
    integer row;
    reg [31:0] last_bench;
    integer flush_i;

    initial begin
        fd         = $fopen(FNAME, "w");
        row        = 0;
        last_bench = 32'hFFFF_FFFF;
        flush_i    = 0;
        if (fd == 0)
            $display("DYN_PROBE_N12: 无法打开输出文件 %0s", FNAME);
        else
            $fwrite(fd, "bench,row,e1ld,e1st,ldblk,issok,sqv,sqav,unkv,unke,live,",
                        "ldm,sz,a2,a3,fp,fwh,fwa,c0,c1,c2,c3,c4,c5,c6,c7\n");
    end

    always @(posedge clk) begin
        if (rst_n && (fd != 0)) begin
            if (bench != last_bench) begin
                last_bench = bench;
                row        = 0;
            end
            $fwrite(fd, "%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,",
                        {1'b0, bench}, row, e1ld, e1st, ldblk, issok,
                        {1'b0, sqv}, {1'b0, sqav}, {1'b0, unkv}, {1'b0, unke},
                        {1'b0, live});
            $fwrite(fd, "%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d\n",
                        {1'b0, ldm}, {1'b0, sz}, {1'b0, a2}, a3, fp,
                        {1'b0, fwh}, fwa,
                        {1'b0, c0}, {1'b0, c1}, {1'b0, c2}, {1'b0, c3},
                        {1'b0, c4}, {1'b0, c5}, {1'b0, c6}, {1'b0, c7});
            row     = row + 1;
            flush_i = flush_i + 1;
            if (flush_i >= 128) begin
                flush_i = 0;
                $fflush(fd);
            end
        end
    end

    //   结束前兜底 flush（$finish 关闭文件时也会 flush；双保险）
    final begin
        if (fd != 0) $fflush(fd);
    end

endmodule
