//==============================================================================
// sim/unit/dyn_probe_n15s_core.sv —— EXP-N15-STRESS 只读层次探针（让位 / 连续等待）
//==============================================================================
// 用途：挂在 `sim/unit/n15s_fpstress_core.sv` 的 `u_back`（backend_top）上，逐拍记录
//   **N15 读口合并让位**只读可观测量，产出 CSV 供 fpga/scratch/n15_stress_analyze.py
//   做 fail-closed 判定。
//
// 口径（与 N15 报告 §4.1/§4.3 逐字一致；判据见 `rtl/back2/backend_top.v:1453-1454`）：
//   · 请求       `iwm_req[l]`      = 未门控选择口 ∧ 基础就绪（lane l ∈ {0..5}，
//                                    4=BRU? 见下 lane 表）
//   · 原始获准   `iwm_gnt_raw[l]`  = 未施加合并让位的 bank 仲裁结果
//   · 最终获准   `iwm_gnt[l]`      = raw ∧ ~让位
//   · **让位判据**（唯二两条，N15 新增）：
//        gnt[3] = raw[3] & ~raw[1]      ⇒ MDU(L3) 让 ALU1(L1)      → 让位事件 y3
//        gnt[5] = raw[5] & ~raw[4]      ⇒ FPU(L5) 让 LSU(L4)       → 让位事件 y5
//   · lane 表：0=ALU0, 1=ALU1, 2=BRU, 3=MDU, 4=LSU, 5=FPU
//   · **实际发射** `iq_iss_v[l]`（= iq 的 iss_valid）；断言 `iss == req & gnt`
//     （获准即发射、未获准必不发射）——分析器逐拍核对。
//
// 逐拍 CSV 列（空格分隔）：cyc req gnt raw iss y3 y5 q4 q5
//   req/gnt/raw/iss = 6 bit（2 位十六进制）；y3/y5 = 让位事件；q4/q5 = 两队列占用。
// 纪律：只读层次探针，不改任何产品 RTL；本文件不打印任何含 PASS 字样的文案。
//==============================================================================
`timescale 1ns / 1ps

module n15s_yield_probe (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        en,              // 采样窗（复位释放 → 程序提交完成）
    input  wire [5:0]  iwm_req,
    input  wire [5:0]  iwm_gnt,
    input  wire [5:0]  iwm_gnt_raw,
    input  wire [5:0]  iq_iss_v,
    input  wire [5:0]  iq_base_rdy,
    input  wire [4:0]  iq4_cnt,
    input  wire [4:0]  iq5_cnt
);
    integer fcsv;
    integer ncyc;

    integer req_cnt [0:5];
    integer gnt_cnt [0:5];
    integer raw_cnt [0:5];
    integer iss_cnt [0:5];
    integer wait_any_run [0:5];
    integer wait_any_max [0:5];
    integer wait_yld_run [0:5];
    integer wait_yld_max [0:5];

    integer y3_cnt, y5_cnt;
    integer y3_run, y3_max;
    integer y5_run, y5_max;
    integer both_req_cnt;      // 同拍 lane4 与 lane5 都请求
    integer both_raw_cnt;      // 同拍 raw4=raw5=1（不同 bank、本可同拍发射）
    integer req5_raw_cnt;      // raw5=1（若不合并则 FPU 本可发射）
    integer gnt4_cnt;          // LSU 实际获准拍数
    integer req5_cnt;
    integer iss45_cnt;

    integer l;
    reg [5:0] yld_mask;
    reg [5:0] expect_gnt;

    wire y3 = iwm_gnt_raw[3] & iwm_gnt_raw[1];
    wire y5 = iwm_gnt_raw[5] & iwm_gnt_raw[4];

    // 让位后应有的获准结果（分析器同式；TB 内也自查，fail-closed）
    always @(*) begin
        yld_mask   = 6'd0;
        if (iwm_gnt_raw[1]) yld_mask[3] = 1'b1;
        if (iwm_gnt_raw[4]) yld_mask[5] = 1'b1;
        expect_gnt = iwm_gnt_raw & ~yld_mask;
    end

    initial begin
        fcsv = 0;
        ncyc = 0;
        for (l = 0; l < 6; l = l + 1) begin
            req_cnt[l] = 0; gnt_cnt[l] = 0; raw_cnt[l] = 0; iss_cnt[l] = 0;
            wait_any_run[l] = 0; wait_any_max[l] = 0;
            wait_yld_run[l] = 0; wait_yld_max[l] = 0;
        end
        y3_cnt = 0; y5_cnt = 0; y3_run = 0; y3_max = 0; y5_run = 0; y5_max = 0;
        both_req_cnt = 0; both_raw_cnt = 0; req5_raw_cnt = 0;
        gnt4_cnt = 0; req5_cnt = 0; iss45_cnt = 0;
        if ($test$plusargs("N15S_CSV")) begin
            fcsv = $fopen("fpga/scratch/n15_stress/yield.csv", "w");
            if (fcsv == 0)
                $display("FAIL: 探针无法打开 fpga/scratch/n15_stress/yield.csv");
            else
                $fwrite(fcsv, "# cyc req gnt raw iss y3 y5 q4 q5\n");
        end
    end

    always @(posedge clk) begin
        if (rst_n & en) begin
            ncyc = ncyc + 1;
            for (l = 0; l < 6; l = l + 1) begin
                if (iwm_req[l])     req_cnt[l] = req_cnt[l] + 1;
                if (iwm_gnt[l])     gnt_cnt[l] = gnt_cnt[l] + 1;
                if (iwm_gnt_raw[l]) raw_cnt[l] = raw_cnt[l] + 1;
                if (iq_iss_v[l])    iss_cnt[l] = iss_cnt[l] + 1;
                // 连续等待：请求但未获准（任何原因）
                if (iwm_req[l] && !iwm_gnt[l]) begin
                    wait_any_run[l] = wait_any_run[l] + 1;
                    if (wait_any_run[l] > wait_any_max[l])
                        wait_any_max[l] = wait_any_run[l];
                end else
                    wait_any_run[l] = 0;
                // 连续等待：N15 让位专属（raw=1 本可获准，却被合并让位规则挡下）
                if (iwm_gnt_raw[l] && !iwm_gnt[l]) begin
                    wait_yld_run[l] = wait_yld_run[l] + 1;
                    if (wait_yld_run[l] > wait_yld_max[l])
                        wait_yld_max[l] = wait_yld_run[l];
                end else
                    wait_yld_run[l] = 0;
            end
            if (y3) begin
                y3_cnt = y3_cnt + 1;
                y3_run = y3_run + 1;
                if (y3_run > y3_max) y3_max = y3_run;
            end else
                y3_run = 0;
            if (y5) begin
                y5_cnt = y5_cnt + 1;
                y5_run = y5_run + 1;
                if (y5_run > y5_max) y5_max = y5_run;
            end else
                y5_run = 0;
            if (iwm_req[4] && iwm_req[5])      both_req_cnt = both_req_cnt + 1;
            if (iwm_gnt_raw[4] && iwm_gnt_raw[5]) both_raw_cnt = both_raw_cnt + 1;
            if (iwm_gnt_raw[5])                req5_raw_cnt = req5_raw_cnt + 1;
            if (iwm_gnt[4])                    gnt4_cnt = gnt4_cnt + 1;
            if (iwm_req[5])                    req5_cnt = req5_cnt + 1;
            if (iq_iss_v[4] && iq_iss_v[5])    iss45_cnt = iss45_cnt + 1;

            if (fcsv != 0)
                $fwrite(fcsv, "%0d %02x %02x %02x %02x %0d %0d %0d %0d\n",
                        ncyc, iwm_req, iwm_gnt, iwm_gnt_raw, iq_iss_v,
                        y3, y5, iq4_cnt, iq5_cnt);
        end
    end

    // 注：CSV 由 TB 在主流程末尾显式 `$fclose(u_probe.fcsv)` 收口（不依赖 `final`）。
endmodule
