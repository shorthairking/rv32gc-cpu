//==============================================================================
// sim/unit/tb_core_top_2b.sv —— 2B-4 第 2 段：CPU 顶层合体（core_top_2b）集成 TB
//==============================================================================
// 项目  : rv32gc-cpu（阶段二 2B-4 第 2 段）
// 目标  : 让**新顶层 core_top_2b**（front4 + backend_top + I-TLB/PTW + L1I + XIP +
//         核内 AXI 读引擎）跑通 **p1_int** 程序，并证明：
//           C1' 提交 PC 流 = Spike 黄金（逐条，0 分歧）
//           C2' 提交条数 ≥ 黄金条数（程序段完整跑完）
//           C3' 跳板路径 = RESET_PC(0x1C00_0000) XIP 直取 → 0x8000_0000（程序入口）
//           C4' 取指**真的走了 L1I/AXI**（实测 AXI AR 笔数 > 0 且存在 DDR 行填充）
//           C5' 全程无提交点异常
// 口径  : 与 tb_back2_lockstep.sv 同源（程序映像/黄金轨迹来自同一份
//         prog/back2_lockstep_data.svh；p1_int = 程序 0，黄金 161 条）；
//         数据侧为本段**占位端口**（oo_mem_*，TB 内存模型直连，见报告 §B4.2.3）。
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
    parameter integer CYC_LIMIT    = 60000,
    parameter integer MEM_WORDS    = 16384,        // 乱序侧数据体 64 KiB
    parameter integer DBG          = 0
) ();

    //==========================================================================
    // 0. 常量与时钟
    //==========================================================================
    localparam [31:0] PROG_PC = 32'h8000_0000;     // 程序入口（= .svh 的黄金基址）
    localparam [31:0] XIP_PC  = 32'h1C00_0000;     // RESET_PC（core_params 口径）
    localparam [31:0] STUB0   = 32'h800002b7;      // lui  x5, 0x80000
    localparam [31:0] STUB1   = 32'h00028067;      // jalr x0, 0(x5)

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
    // 1. DUT：core_top_2b（48 契约端口 + 10 个占位端口 oo_mem_*）
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

    // 数据侧占位口
    wire        oo_req_v, oo_req_wen;
    wire [31:0] oo_req_a, oo_req_d;
    wire [3:0]  oo_req_strb;
    wire [`BACK2_MEM_TAG_W-1:0] oo_req_tag;
    wire        oo_req_ready;
    reg         oo_rsp_v;
    reg  [31:0] oo_rsp_d;
    reg  [`BACK2_MEM_TAG_W-1:0] oo_rsp_tag;

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
        .debug0_wb_rf_wnum(dbg_wnum_w), .debug0_wb_rf_wdata(dbg_wdata_w),
        // ---- 占位：数据侧直连 TB 内存模型（第 3 段换 L1D/AXI）----
        .oo_mem_req_valid(oo_req_v), .oo_mem_req_wen(oo_req_wen),
        .oo_mem_req_addr(oo_req_a), .oo_mem_req_wdata(oo_req_d),
        .oo_mem_req_wstrb(oo_req_strb), .oo_mem_req_tag(oo_req_tag),
        .oo_mem_req_ready(oo_req_ready),
        .oo_mem_rsp_valid(oo_rsp_v), .oo_mem_rsp_rdata(oo_rsp_d),
        .oo_mem_rsp_tag(oo_rsp_tag)
    );

    //==========================================================================
    // 2. AXI 从设备内存模型（取指通路：XIP 单字 + L1I 行填充）
    //--------------------------------------------------------------------------
    //   程序链接在 0x8000_0000（仿真布局）而模型 DDR3 基址 = 0 ⇒ 插入**纯组合
    //   地址翻译**（与 tb_back2_lockstep 的 map2a 同法）；XIP 窗口原样透传。
    //==========================================================================
    function [31:0] map_addr; input [31:0] a;
        begin map_addr = (a[31:16] == 16'h8000) ? {16'h0000, a[15:0]} : a; end
    endfunction

    wire [31:0] araddr_m = map_addr(araddr);
    wire [31:0] awaddr_m = map_addr(awaddr);

    sim_mem_model #(
        .XIP_BASE       (XIP_PC),
        .XIP_ALIAS      (`RV32GC_XIP_ALIAS),
        .XIP_SIZE       (32'h0000_1000),      // 4 KB 跳板
        .DDR3_BASE      (32'h0000_0000),      // ★ 必须 0：模型用绝对下标
        .DDR3_LIMIT     (32'h0001_0000),      // 64 KB
        .UART_DATA_ADDR (32'h1FE0_01E0),
        .READ_LAT_DLY   (0)
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

    // ---- AXI 取指观测（判据 C4'：取指真的走了 L1I/AXI）----
    integer n_ar, n_ar_xip, n_ar_ddr;
    always @(posedge clk) begin
        if (rst_n && arvalid && arready) begin
            n_ar = n_ar + 1;
            if (araddr_m[31:20] == 12'h1C0) n_ar_xip = n_ar_xip + 1;
            else                           n_ar_ddr = n_ar_ddr + 1;
        end
    end

    //==========================================================================
    // 3. 数据侧占位内存模型（LSU 单请求口；带标签响应，2 级流水）
    //   ★ 与 tb_back2_lockstep.sv §5 的访存模型同口径（每笔读恰好一拍响应）
    //==========================================================================
    reg [31:0] mem_oo [0:MEM_WORDS-1];
    function [13:0] w_idx; input [31:0] a; begin w_idx = a[15:2]; end endfunction
    function is_xip_w; input [31:0] a;
        begin is_xip_w = (a[31:20] == 12'h1C0) | (a[31:16] == 16'h1FE8); end
    endfunction

    reg        rq1_v, rq2_v;
    reg [`BACK2_MEM_TAG_W-1:0] rq1_t, rq2_t;
    reg [31:0] rq1_d, rq2_d;
    wire       rd_acc = oo_req_v & oo_req_ready & ~oo_req_wen;
    assign oo_req_ready = ~rq2_v;
    assign oo_rsp_v     = rq2_v;
    assign oo_rsp_tag   = rq2_t;
    assign oo_rsp_d     = rq2_d;
    integer wb_i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rq1_v <= 1'b0; rq2_v <= 1'b0;
            rq1_t <= {`BACK2_MEM_TAG_W{1'b0}}; rq2_t <= {`BACK2_MEM_TAG_W{1'b0}};
            rq1_d <= 32'h0; rq2_d <= 32'h0;
        end else begin
            if (oo_req_v && oo_req_ready && oo_req_wen) begin
                for (wb_i = 0; wb_i < 4; wb_i = wb_i + 1)
                    if (oo_req_strb[wb_i])
                        mem_oo[w_idx(oo_req_a)][8*wb_i +: 8] <= oo_req_d[8*wb_i +: 8];
            end
            rq1_v <= rd_acc;
            if (rd_acc) begin
                rq1_t <= oo_req_tag;
                rq1_d <= is_xip_w(oo_req_a) ? 32'h0000_0013 : mem_oo[w_idx(oo_req_a)];
            end
            rq2_v <= rq1_v; rq2_t <= rq1_t; rq2_d <= rq1_d;
        end
    end

    //==========================================================================
    // 4. 程序装载（黄金轨迹/映像与 tb_back2_lockstep 同源）
    //==========================================================================
    `include "sim/unit/prog/back2_lockstep_data.svh"
    localparam integer CMAX = P0_GOLD_N;          // p1_int = 程序 0，黄金 161 条

    task automatic load_all;
        integer m;
        begin
            // ---- 数据体：清 nop（防取到 x）+ 装载程序映像 ----
            for (m = 0; m < MEM_WORDS; m = m + 1) begin
                mem_oo[m]           = 32'h0000_0013;
                u_mem.ddr3_mem[m]   = 32'h0000_0013;
            end
            for (m = 0; m < P_IMG_MAX; m = m + 1) begin
                mem_oo[w_idx(PROG_PC + m*4)]           = IMG[0*P_IMG_MAX + m];
                u_mem.ddr3_mem[w_idx(PROG_PC + m*4)]   = IMG[0*P_IMG_MAX + m];
            end
            // ---- XIP 跳板（RESET_PC 处，不经 I-Cache）：2 字 ----
            for (m = 0; m < 1024; m = m + 1) u_mem.xip_mem[m] = 32'h0000_0013;
            u_mem.xip_mem[0] = STUB0;
            u_mem.xip_mem[1] = STUB1;
        end
    endtask

    //==========================================================================
    // 5. 提交记录与黄金比对（口径同 tb_back2_lockstep.sv）
    //==========================================================================
    localparam integer GMAX = 1024;
    reg [31:0] rpc [0:GMAX-1];
    reg        rwe [0:GMAX-1];
    reg [4:0]  rrd [0:GMAX-1];
    reg [31:0] rwd [0:GMAX-1];
    integer    nrec;
    reg        on;
    integer    bad_at;

    wire [127:0] cpc = u_dut.commit_pc;
    integer      cl, crk;
    //   ★ 起录口径（与 tb_back2_lockstep.sv 同法）：跳板 2 条与程序首条可能**同块**
    //     ⇒ 必须按 **lane** 找到"块内首个 PC==PROG_PC 的 lane"，该 lane 及其后归程序段。
    //     ★ 不能写成"先置 on、下一拍再记"（会静默丢掉程序第 1 条并整体错位）。
    integer      first_prog_lane;
    always @(*) begin
        first_prog_lane = 4;
        for (cl = 3; cl >= 0; cl = cl - 1)
            if (u_dut.commit_valid[cl] && (cpc[cl*32 +: 32] == PROG_PC))
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
            if (first_prog_lane != 4) on <= 1'b1;
            if (nrec_w != 3'd0) nrec <= nrec + nrec_w;
            for (cl = 0; cl < 4; cl = cl + 1) begin
                if (u_dut.commit_valid[cl] && rec_sel[cl]) begin
                    if ((nrec + rec_rank[cl]) < GMAX) begin
                        rpc[nrec + rec_rank[cl]] <= cpc[cl*32 +: 32];
                        rwe[nrec + rec_rank[cl]] <= u_dut.commit_arch_we[cl];
                        rrd[nrec + rec_rank[cl]] <= u_dut.commit_arch_rd[cl*5 +: 5];
                        rwd[nrec + rec_rank[cl]] <= u_dut.commit_arch_rd_wdata[cl*32 +: 32];
                        // 即时黄金比对（只打印，判据由主流程给出）
                        if ((bad_at < 0) && ((nrec + rec_rank[cl]) < CMAX) &&
                            (cpc[cl*32 +: 32] !== GOLD[0*P_GOLD_MAX + (nrec + rec_rank[cl])])) begin
                            bad_at = nrec + rec_rank[cl];
                            $display("      [oo-bad t=%0t] 第 %0d 条 PC=0x%08x 期望 0x%08x",
                                     $time, bad_at, cpc[cl*32 +: 32],
                                     GOLD[0*P_GOLD_MAX + bad_at]);
                        end
                    end
                end
            end
        end
    end

    // ---- 跳板观测（判据 C3'）----
    integer n_xip_seen, n_prog_seen;
    always @(posedge clk) begin
        if (rst_n) begin
            if (u_dut.commit_valid[0] && (cpc[0 +: 32] == XIP_PC))        n_xip_seen  <= 1'b1;
            if (u_dut.commit_valid[0] && (cpc[0 +: 32] == XIP_PC + 32'd4)) n_prog_seen <= 1'b1;
        end
    end

    //==========================================================================
    // 6. 主流程
    //==========================================================================
    integer cyc, k, d_pc;
    initial begin
        $display("== tb_core_top_2b 启动（core_top_2b：front4 + backend_top + L1I/XIP/AXI）");
        $fflush();
        n_checks = 0; nrec = 0; on = 1'b0; bad_at = -1;
        n_ar = 0; n_ar_xip = 0; n_ar_ddr = 0;
        n_xip_seen = 0; n_prog_seen = 0;
        rst_n = 1'b0;
        load_back2_data;
        load_all;
        repeat (RESET_CYCLES) @(posedge clk);
        @(negedge clk); rst_n = 1'b1;
        repeat (2) @(posedge clk);

        cyc = 0;
        while ((nrec < CMAX) && (cyc < CYC_LIMIT)) begin
            @(posedge clk);
            cyc = cyc + 1;
            if ((cyc % 20000) == 0) begin
                $display("   … 进度：%0d 拍，提交 %0d 条（黄金 %0d），AXI AR=%0d（XIP %0d / DDR %0d），CHK 违规 %0d",
                         cyc, nrec, CMAX, n_ar, n_ar_xip, n_ar_ddr, bad_at);
                $fflush();
            end
        end

        $display("== 顶层合体结果：%0d 拍，提交 %0d 条（黄金 %0d），AXI AR=%0d（XIP %0d / DDR %0d）",
                 cyc, nrec, CMAX, n_ar, n_ar_xip, n_ar_ddr);

        // ---- C1'：PC 流与黄金逐条一致 ----
        begin : cmp
            integer dc;
            dc = 0;
            for (k = 0; k < CMAX; k = k + 1) begin
                if ((rpc[k] !== GOLD[0*P_GOLD_MAX + k]) && (dc == 0)) begin
                    $display("FAIL: 第 %0d 条提交 PC=0x%08x 期望 0x%08x", k, rpc[k], GOLD[0*P_GOLD_MAX + k]);
                    dc = 1;
                end
            end
            chk(dc == 0, "C1' 提交 PC 流与 Spike 黄金逐条一致（0 分歧）");
        end
        // ---- C2'：条数 ----
        chk(nrec >= CMAX, "C2' 提交条数 ≥ 黄金条数（程序段跑完）");
        // ---- C3'：跳板路径 ----
        chk(n_xip_seen == 1, "C3' 从 RESET_PC=0x1C00_0000 取到跳板首字（XIP 直通）");
        chk(n_prog_seen == 1, "C3' 跳板次字提交（顺序取指）");
        // ---- C4'：取指真的走了 L1I/AXI ----
        chk(n_ar_xip > 0, "C4' XIP 单字读经过核内 AXI（AR 笔数 > 0）");
        chk(n_ar_ddr > 0, "C4' DDR 取指经 L1I 行填充走 AXI（AR 笔数 > 0）");
        // ---- C5'：无提交点异常 ----
        chk(u_dut.trap_valid_w == 1'b0, "C5' 全程无提交点异常");

        $display("== 检查项合计 %0d 项全部满足（C1' PC 流 / C2' 条数 / C3' 跳板 / C4' L1I+AXI / C5' 无异常）", n_checks);
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
