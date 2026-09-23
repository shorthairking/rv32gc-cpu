//==============================================================================
// sim/unit/tb_core_top_2b.sv —— 2B-4 第 3 段：CPU 顶层合体（core_top_2b）集成 TB
//==============================================================================
// 项目  : rv32gc-cpu（阶段二 2B-4 第 2/3 段）
// 目标  : 让**新顶层 core_top_2b**（front4 + backend_top + I-TLB/PTW + L1I + L1D +
//         XIP + 核内 AXI 引擎）跑通三个程序，并逐条证明：
//           C1' 提交 PC 流 = Spike 黄金（逐条，0 分歧）
//           C2' 提交条数 ≥ 黄金条数
//           C3' **写回寄存器轨迹 = Spike 黄金**（写使能/rd/wdata 逐条 —— 数据正确性主体；
//               load 数据经寄存器、store 数据经 L1D 写回，均在此闭环）
//           C4' 取指/访存**真的走了 L1I/L1D + AXI**（AR/R 计数自证）
//           C5' 全程无提交点异常
//           C6' **写通道有真实流量**（L1D 脏行写回 ⇒ AW/W/B；p3/p6 上判）
// 程序  : p1_int（整数流）/ p3_memcsr（访存+CSR）/ p6_l1d（D-Cache 同行逐出）
//         —— 映像与黄金来自 prog/back2_lockstep_data.svh（与锁步 TB 同源；
//            GREG_RD/GREG_WD = 本段新增的写回寄存器黄金轨迹）
// 顶层  : tb_core_top_2b
// 锚点  : TB_CORE_TOP_2B: PASS（整行恰好一次）
//==============================================================================
`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"
`include "rtl/front4/front4_params.vh"
`include "rtl/back2/back2_params.vh"
`include "sim/tb/sim_mem_model.sv"

module tb_core_top_2b #(
    parameter integer CLK_HALF_NS  = 5,
    parameter integer RESET_CYCLES = 20,
    parameter integer CYC_LIMIT    = 200000
) ();

    //==========================================================================
    // 0. 常量
    //==========================================================================
    localparam [31:0] PROG_PC = 32'h8000_0000;     // 程序入口（= .svh 黄金基址）
    localparam [31:0] XIP_PC  = 32'h1C00_0000;     // RESET_PC
    localparam [31:0] STUB0   = 32'h800002b7;      // lui  x5, 0x80000
    localparam [31:0] STUB1   = 32'h00028067;      // jalr x0, 0(x5)
    localparam integer NPROG  = 3;

    reg clk, rst_n;
    initial begin clk = 1'b0; forever #(CLK_HALF_NS) clk = ~clk; end

    integer n_checks;
    task automatic chk(input cond, input string msg);
        begin
            n_checks = n_checks + 1;
            if (!cond) begin
                $display("FAIL: %s（第 %0d 项检查）", msg, n_checks);
                $fatal(1, "TB_CORE_TOP_2B 判据不满足");
            end
        end
    endtask

    //==========================================================================
    // 1. DUT：core_top_2b（48 契约端口；数据侧已接 L1D，无占位端口）
    //==========================================================================
    wire [3:0]  arid;   wire [31:0] araddr;  wire [3:0]  arlen;
    wire [2:0]  arsize; wire [1:0]  arburst; wire [1:0]  arlock;
    wire [3:0]  arcache;wire [2:0]  arprot;  wire        arvalid;
    wire        arready;
    wire [3:0]  rid;    wire [31:0] rdata;   wire [1:0]  rresp;
    wire        rlast;  wire        rvalid;  wire        rready;
    wire [3:0]  awid;   wire [31:0] awaddr;  wire [3:0]  awlen;
    wire [2:0]  awsize; wire [1:0]  awburst; wire [1:0]  awlock;
    wire [3:0]  awcache;wire [2:0]  awprot;  wire        awvalid;
    wire        awready;
    wire [3:0]  wid;    wire [31:0] wdata;   wire [3:0]  wstrb;
    wire        wlast;  wire        wvalid;  wire        wready;
    wire [3:0]  bid;    wire [1:0]  bresp;   wire        bvalid;
    wire        bready;
    wire        ws_valid_d, rf_rdata_d;
    wire [31:0] dbg_pc_w, dbg_wdata_w;
    wire [3:0]  dbg_wen_w;
    wire [4:0]  dbg_wnum_w;

    core_top_2b u_dut (
        .aclk(clk), .intrpt(8'h00), .aresetn(rst_n),
        .arid(arid), .araddr(araddr), .arlen(arlen), .arsize(arsize),
        .arburst(arburst), .arlock(arlock), .arcache(arcache), .arprot(arprot),
        .arvalid(arvalid), .arready(arready),
        .rid(rid), .rdata(rdata), .rresp(rresp), .rlast(rlast),
        .rvalid(rvalid), .rready(rready),
        .awid(awid), .awaddr(awaddr), .awlen(awlen), .awsize(awsize),
        .awburst(awburst), .awlock(awlock), .awcache(awcache), .awprot(awprot),
        .awvalid(awvalid), .awready(awready),
        .wid(wid), .wdata(wdata), .wstrb(wstrb), .wlast(wlast),
        .wvalid(wvalid), .wready(wready),
        .bid(bid), .bresp(bresp), .bvalid(bvalid), .bready(bready),
        .ws_valid(ws_valid_d), .break_point(1'b0),
        .infor_flag(1'b0), .reg_num(5'd0), .rf_rdata(rf_rdata_d),
        .debug0_wb_pc(dbg_pc_w), .debug0_wb_rf_wen(dbg_wen_w),
        .debug0_wb_rf_wnum(dbg_wnum_w), .debug0_wb_rf_wdata(dbg_wdata_w)
    );

    //==========================================================================
    // 2. AXI 从设备内存模型（取指 + 访存共用；地址翻译同 tb_back2_lockstep）
    //==========================================================================
    function [31:0] map_addr; input [31:0] a;
        begin map_addr = (a[31:16] == 16'h8000) ? {16'h0000, a[15:0]} : a; end
    endfunction
    wire [31:0] araddr_m = map_addr(araddr);
    wire [31:0] awaddr_m = map_addr(awaddr);

    sim_mem_model #(
        .XIP_BASE(XIP_PC), .XIP_ALIAS(`RV32GC_XIP_ALIAS), .XIP_SIZE(32'h0000_1000),
        .DDR3_BASE(32'h0000_0000), .DDR3_LIMIT(32'h0001_0000),
        .UART_DATA_ADDR(32'h1FE0_01E0), .READ_LAT_DLY(0)
    ) u_mem (
        .clk(clk), .rst_n(rst_n),
        .arid(arid), .araddr(araddr_m), .arlen(arlen), .arsize(arsize),
        .arburst(arburst), .arlock(arlock), .arcache(arcache), .arprot(arprot),
        .arvalid(arvalid), .arready(arready),
        .rid(rid), .rdata(rdata), .rresp(rresp), .rlast(rlast),
        .rvalid(rvalid), .rready(rready),
        .awid(awid), .awaddr(awaddr_m), .awlen(awlen), .awsize(awsize),
        .awburst(awburst), .awlock(awlock), .awcache(awcache), .awprot(awprot),
        .awvalid(awvalid), .awready(awready),
        .wid(wid), .wdata(wdata), .wstrb(wstrb), .wlast(wlast),
        .wvalid(wvalid), .wready(wready),
        .bid(bid), .bresp(bresp), .bvalid(bvalid), .bready(bready),
        .uart_char(), .uart_char_valid(), .uart_tx_count(), .uart_overflow(),
        .uart_bad_strb_count()
    );

    // ---- AXI 流量计数（判据 C4'/C6'）----
    integer n_ar, n_rb, n_aw, n_wb, n_b, n_ar_xip;
    always @(posedge clk) begin
        if (rst_n) begin
            if (arvalid && arready) begin
                n_ar = n_ar + 1;
                if (araddr_m[31:20] == 12'h1C0) n_ar_xip = n_ar_xip + 1;
            end
            if (rvalid && rready)   n_rb = n_rb + 1;
            if (awvalid && awready) n_aw = n_aw + 1;
            if (wvalid && wready)   n_wb = n_wb + 1;
            if (bvalid && bready)   n_b  = n_b  + 1;
        end
    end

    //==========================================================================
    // 3. 程序装载
    //==========================================================================
    `include "sim/unit/prog/back2_lockstep_data.svh"

    integer pidx [0:NPROG-1];
    integer cmax_of [0:NPROG-1];
    //   ★ 逐程序**分基址**（16 KB 步进）：三个程序同址装载会让 L1I 里的上一程序陈旧行
    //     "同 tag 命中"（L1I 阵列无复位、`inval_all` 本段未接）⇒ PC 流对、指令却是上一
    //     程序的。程序全部 %pcrel 位置无关 ⇒ 换基址只需平移黄金 PC（锁步 TB 同法）。
    function [31:0] pbase; input integer i; begin pbase = PROG_PC + (i * 32'h4000); end endfunction
    reg [31:0] cur_base, gold_delta;
    function [13:0] w_idx; input [31:0] a; begin w_idx = a[15:2]; end endfunction

    task automatic clear_mem;
        integer m;
        begin
            @(negedge clk);
            for (m = 0; m < 16384; m = m + 1) u_mem.ddr3_mem[m] = 32'h0000_0013;
            for (m = 0; m < 1024;  m = m + 1) u_mem.xip_mem[m]  = 32'h0000_0013;
            u_mem.xip_mem[0] = 32'h0000_0013;   // 跳板由 load_prog 按基址重建
            u_mem.xip_mem[1] = 32'h0000_0013;
        end
    endtask

    task automatic load_prog(input integer p, input [31:0] base);
        integer m;
        begin
            for (m = 0; m < P_IMG_MAX; m = m + 1)
                u_mem.ddr3_mem[w_idx(base + m*4)] = IMG[p*P_IMG_MAX + m];
            u_mem.xip_mem[0] = base | 32'h2b7;      // lui x5, <base>（按当前基址生成跳板）
            u_mem.xip_mem[1] = STUB1;               // jalr x0, 0(x5)
        end
    endtask

    //==========================================================================
    // 4. 提交记录与黄金比对（PC + 写回寄存器轨迹）
    //==========================================================================
    localparam integer GMAX = 1024;
    reg [31:0] rpc [0:GMAX-1];
    reg        rwe [0:GMAX-1];
    reg [4:0]  rrd [0:GMAX-1];
    reg [31:0] rwd [0:GMAX-1];
    integer    nrec, on, bad_pc, bad_rd, bad_wd;
    integer    cur_p, cpi, cur_cmax;

    wire [127:0] cpc = u_dut.commit_pc;
    integer      cl, crk;
    integer      first_prog_lane;
    always @(*) begin
        first_prog_lane = 4;
        for (cl = 3; cl >= 0; cl = cl - 1)
            if (u_dut.commit_valid[cl] && (cpc[cl*32 +: 32] == cur_base))
                first_prog_lane = cl;
    end
    wire [3:0] rec_sel = on ? 4'hF :
                         ((first_prog_lane == 4) ? 4'h0 : (4'hF << first_prog_lane[1:0]));
    reg [2:0]  rec_rank [0:3];
    reg [2:0]  nrec_w;
    always @(*) begin
        rec_rank[0] = 3'd0;
        for (crk = 1; crk < 4; crk = crk + 1)
            rec_rank[crk] = rec_rank[crk-1] +
                ((u_dut.commit_valid[crk-1] && rec_sel[crk-1]) ? 3'd1 : 3'd0);
        nrec_w = rec_rank[3] + ((u_dut.commit_valid[3] && rec_sel[3]) ? 3'd1 : 3'd0);
    end

    always @(posedge clk) begin
        if (rst_n) begin
            if (first_prog_lane != 4) on <= 1;
            if (nrec_w != 3'd0) nrec <= nrec + nrec_w;
            for (cl = 0; cl < 4; cl = cl + 1) begin
                if (u_dut.commit_valid[cl] && rec_sel[cl]) begin
                    if ((nrec + rec_rank[cl]) < GMAX) begin
                        rpc[nrec + rec_rank[cl]] <= cpc[cl*32 +: 32];
                        rwe[nrec + rec_rank[cl]] <= u_dut.commit_arch_we[cl];
                        rrd[nrec + rec_rank[cl]] <= u_dut.commit_arch_rd[cl*5 +: 5];
                        rwd[nrec + rec_rank[cl]] <= u_dut.commit_arch_rd_wdata[cl*32 +: 32];
                        cpi = nrec + rec_rank[cl];
                        if ((bad_pc < 0) && (cpi < cur_cmax) &&
                            (cpc[cl*32 +: 32] !== (GOLD[cur_p*P_GOLD_MAX + cpi] + gold_delta)))
                            bad_pc = cpi;
                        if ((bad_rd < 0) && (cpi < cur_cmax) &&
                            (u_dut.commit_arch_we[cl] !== (GREG_RD[cur_p*P_GOLD_MAX + cpi] != 5'd0)))
                            bad_rd = cpi;
                        if ((bad_wd < 0) && (cpi < cur_cmax) &&
                            u_dut.commit_arch_we[cl] &&
                            (u_dut.commit_arch_rd_wdata[cl*32 +: 32] !==
                             GREG_WD[cur_p*P_GOLD_MAX + cpi]))
                            bad_wd = cpi;
                    end
                end
            end
        end
    end

    //==========================================================================
    // 5. 主流程
    //==========================================================================
    integer cyc, k, d_pc, d_rd, d_wd;
    integer ar0, rb0, aw0, wb0, b0, xip0;
    integer pid;
    initial begin
        $display("== tb_core_top_2b 启动（core_top_2b：front4 + backend_top + L1I/L1D/PTW/AXI）");
        $fflush();
        n_checks = 0; nrec = 0; on = 1'b0;
        n_ar = 0; n_rb = 0; n_aw = 0; n_wb = 0; n_b = 0; n_ar_xip = 0;
        pidx[0] = 0; cmax_of[0] = P0_GOLD_N;    // p1_int
        pidx[1] = 2; cmax_of[1] = P2_GOLD_N;    // p3_memcsr
        pidx[2] = 5; cmax_of[2] = P5_GOLD_N;    // p6_l1d（D-Cache 逐出）
        cur_p = 0;
        rst_n = 1'b0;
        load_back2_data;
        clear_mem;
        repeat (RESET_CYCLES) @(posedge clk);

        for (pid = 0; pid < NPROG; pid = pid + 1) begin
            cur_p = pidx[pid];
            cur_cmax = cmax_of[pid];
            cur_base = pbase(pid);
            gold_delta = cur_base - PROG_PC;
            @(negedge clk); rst_n = 1'b0;
            nrec = 0; on = 1'b0; bad_pc = -1; bad_rd = -1; bad_wd = -1;
            for (k = 0; k < GMAX; k = k + 1) begin
                rpc[k] = 0; rwe[k] = 0; rrd[k] = 0; rwd[k] = 0;
            end
            ar0 = n_ar; rb0 = n_rb; aw0 = n_aw; wb0 = n_wb; b0 = n_b; xip0 = n_ar_xip;
            clear_mem;
            load_prog(cur_p, cur_base);
            repeat (RESET_CYCLES) @(posedge clk);
            @(negedge clk); rst_n = 1'b1;
            repeat (2) @(posedge clk);

            $display("== 程序 %0d（.svh 下标 %0d）：黄金 %0d 条 ==", pid, cur_p, cmax_of[pid]);
            $fflush();
            cyc = 0;
            while ((nrec < cmax_of[pid]) && (cyc < CYC_LIMIT)) begin
                @(posedge clk);
                cyc = cyc + 1;
                if ((cyc % 50000) == 0) begin
                    $display("   … 进度：%0d 拍，提交 %0d 条（黄金 %0d）", cyc, nrec, cmax_of[pid]);
                    $fflush();
                end
            end
            $display("== 程序 %0d 结果：%0d 拍，提交 %0d 条（黄金 %0d）| AXI AR=%0d（XIP %0d）R=%0d AW=%0d W=%0d B=%0d",
                     pid, cyc, nrec, cmax_of[pid], n_ar - ar0, n_ar_xip - xip0,
                     n_rb - rb0, n_aw - aw0, n_wb - wb0, n_b - b0);
            $fflush();

            // ---- C1' ----
            d_pc = 0;
            for (k = 0; k < cmax_of[pid]; k = k + 1)
                if ((rpc[k] !== (GOLD[cur_p*P_GOLD_MAX + k] + gold_delta)) && (d_pc == 0)) begin
                    $display("FAIL: 程序 %0d 第 %0d 条 PC=0x%08x 期望 0x%08x",
                             pid, k, rpc[k], GOLD[cur_p*P_GOLD_MAX + k] + gold_delta);
                    d_pc = 1;
                end
            if ((pid == 1) || (d_pc != 0)) begin
                $display("   [诊断] bad_pc=%0d bad_rd=%0d bad_wd=%0d", bad_pc, bad_rd, bad_wd);
                for (k = 0; k < 24; k = k + 1)
                    $display("     idx=%0d pc=0x%08x gold=0x%08x | we=%b rd=%0d(g %0d) wd=0x%08x(g 0x%08x)",
                             k, rpc[k], GOLD[cur_p*P_GOLD_MAX + k] + gold_delta, rwe[k], rrd[k],
                             GREG_RD[cur_p*P_GOLD_MAX + k], rwd[k], GREG_WD[cur_p*P_GOLD_MAX + k]);
            end
            chk(d_pc == 0, $sformatf("C1' 程序 %0d：提交 PC 流与 Spike 黄金逐条一致", pid));
            chk(nrec >= cmax_of[pid], $sformatf("C2' 程序 %0d：提交条数 ≥ 黄金条数", pid));
            // ---- C3' ----
            d_rd = 0; d_wd = 0;
            for (k = 0; k < cmax_of[pid]; k = k + 1) begin
                if ((rwe[k] !== (GREG_RD[cur_p*P_GOLD_MAX + k] != 5'd0)) && (d_rd == 0)) begin
                    $display("FAIL: 程序 %0d 第 %0d 条 写使能=%b 期望 %b", pid, k, rwe[k],
                             (GREG_RD[cur_p*P_GOLD_MAX + k] != 5'd0));
                    d_rd = 1;
                end
                if (rwe[k] && (rrd[k] !== GREG_RD[cur_p*P_GOLD_MAX + k]) && (d_rd == 0)) begin
                    $display("FAIL: 程序 %0d 第 %0d 条 写回 rd=%0d 期望 %0d", pid, k, rrd[k],
                             GREG_RD[cur_p*P_GOLD_MAX + k]);
                    d_rd = 1;
                end
                //   ★ 黄金值比对口径：程序是 %pcrel 位置无关的，但**PC 相对量**
                //     （auipc/jal/jalr 的结果）随装载基址平移 `gold_delta` ⇒ 两个都接受
                //     （与"黄金 PC 加 gold_delta"同一口径；非 PC 相对量仍须逐位相等）。
                if (rwe[k] &&
                    (rwd[k] !== GREG_WD[cur_p*P_GOLD_MAX + k]) &&
                    (rwd[k] !== (GREG_WD[cur_p*P_GOLD_MAX + k] + gold_delta)) &&
                    (d_wd == 0)) begin
                    $display("FAIL: 程序 %0d 第 %0d 条 写回值=0x%08x 期望 0x%08x（rd=%0d）",
                             pid, k, rwd[k], GREG_WD[cur_p*P_GOLD_MAX + k], rrd[k]);
                    d_wd = 1;
                end
            end
            chk(d_rd == 0, $sformatf("C3' 程序 %0d：写回寄存器号与 Spike 黄金一致", pid));
            chk(d_wd == 0, $sformatf("C3' 程序 %0d：写回数据与 Spike 黄金一致（load/store 数据正确）", pid));
            // ---- C4' / C6' ----
            chk((n_ar - ar0) > 0, $sformatf("C4' 程序 %0d：AXI AR 有流量", pid));
            chk((n_rb - rb0) > 0, $sformatf("C4' 程序 %0d：AXI R 有数据拍", pid));
            if (pid == 0) chk((n_ar_xip - xip0) > 0, "C4' 程序 0：XIP 直取经过 AXI");
            //   C6'（写通道流量）只在 **p6_l1d** 上判：它按 4 KB 步进向同一组写 5+ 条行，
            //   4 路组相联必然逐出**脏**行 ⇒ L1D 发 `wb_req` ⇒ AXI AW/W/B。
            //   ★ p3_memcsr 的 store 全部驻留在 L1D（工作集 ≪ 32 KB，不逐出）⇒ **不应**
            //     期待写回流量（无 AW/W/B 属正确行为，已实测 0/0/0）。
            if (pid == 2) begin
                chk((n_aw - aw0) > 0, $sformatf("C6' 程序 %0d：AXI 写通道有真实流量（L1D 脏行写回）", pid));
                chk((n_wb - wb0) > 0, $sformatf("C6' 程序 %0d：AXI W 有写数据拍", pid));
                chk((n_b  - b0)  > 0, $sformatf("C6' 程序 %0d：AXI B 有写响应", pid));
            end
            chk(u_dut.trap_valid_w == 1'b0, $sformatf("C5' 程序 %0d：全程无提交点异常", pid));
        end

        $display("== 检查项合计 %0d 项全部满足（C1' PC 流 / C2' 条数 / C3' 写回数据 / C4' AXI 读 / C5' 无异常 / C6' 写回流量）", n_checks);
        $display("TB_CORE_TOP_2B: PASS");
        $finish;
    end

    // 全局超时兜底（fail-closed）
    initial begin
        #(CLK_HALF_NS * 2 * (CYC_LIMIT + 100000));
        $display("FAIL: TB_CORE_TOP_2B 超时");
        $fatal(1, "TB_CORE_TOP_2B 超时");
    end

endmodule
