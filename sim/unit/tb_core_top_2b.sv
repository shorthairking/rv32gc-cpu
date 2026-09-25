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
    localparam integer NPROG  = 7;
    //   ★ p8_int 是**时序相关**程序（CLINT mtime 自由计数 ⇒ 取中断拍数依赖微架构）
    //     ⇒ 不与 Spike 逐条比，改为"跑固定拍数 + C8' 自记录判据"（口径见 §B4.4.3）
    localparam integer P8_CYCLES = 4000;
    //   p8 诊断开关（默认关；定位"中断后为何长时间不派发"时置 1）：
    //   · 实测结论（报告 §B4.4.3）：中断/xRET 的 `flush_all` 触发 rename 的 free list
    //     重建 FSM（`rb_act`）逐拍扫描 NREG=96 项 ⇒ 约 96 拍 `busy=1` ⇒ 派发暂停
    //     （非死锁：重建结束即恢复，处理程序随后逐条提交）
    localparam integer DBG_P8 = 0;
    //   p10（CSR 轨迹）逐条对照打印开关（默认关）
    localparam integer DBG_P10 = 0;

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
    //   ★ 2B-4 第 4a 段：DDR3 别名窗口由 64 KB（0x8000_xxxx）放宽到 1 MB
    //     （`a[31:20] == 12'h800`）—— 5 个程序按 16 KB 步进装到 0x8001_0000，
    //     原判据（a[31:16]==0x8000）会把第 5 个程序当"未登记区域"读 0 ⇒ 全错。
    function [31:0] map_addr; input [31:0] a;
        begin map_addr = (a[31:20] == 12'h800) ? {12'h000, a[19:0]} : a; end
    endfunction
    wire [31:0] araddr_m = map_addr(araddr);
    wire [31:0] awaddr_m = map_addr(awaddr);

    sim_mem_model #(
        .XIP_BASE(XIP_PC), .XIP_ALIAS(`RV32GC_XIP_ALIAS), .XIP_SIZE(32'h0000_1000),
        //   ★ 2B-4 第 4a 段：程序数 3→5（p7_trap / p8_int），16 KB 步进 ⇒ DDR3 窗口
        //     必须 ≥ 5×16 KB = 80 KB（原 64 KB 会让第 5 个程序的基址落到窗口外 →
        //     取指读到"未登记区域"的 0 ⇒ 立即非法指令陷阱）
        .DDR3_BASE(32'h0000_0000), .DDR3_LIMIT(32'h0002_0000),
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
    //   ★ 2B-4 第 4a 段：陷阱现场监视（C7'）
    integer n_trap_p;                       // 本程序"异常被交付"的次数
    integer n_irq_p;                        // 本程序"中断被交付"的次数（C8'）
    reg     trap_seen_q, irq_seen_q;        // 边沿检测（同一事件只计一次）
    //   ★ 中断的**重定向目标**：中断不走 ROB 异常口（`trap_valid_w` 只报异常）⇒
    //     直接采顶层 trap FSM 的组合重定向 PC（`irq_mti_w` 同拍有效）
    reg [31:0] irq_target_q;
    reg [3:0] trc_cause [0:7];              // 依次记录的 mcause 低位
    reg [31:0] trc_pc   [0:7];              // 依次记录的**陷阱指令 PC**（= ROB 头部 PC）
    reg [31:0] trp_tgt  [0:7];              // 依次记录的**重定向目标 PC**（决定落哪个向量槽）
    always @(posedge clk) begin
        trap_seen_q <= rst_n & u_dut.trap_valid_w;
        if (rst_n && u_dut.trap_valid_w && !trap_seen_q && (n_trap_p < 8)) begin
            trc_cause[n_trap_p] <= u_dut.trap_cause_w;
            trc_pc[n_trap_p]    <= u_dut.trap_pc_w;
            trp_tgt[n_trap_p]   <= u_dut.be_trp_redirect_pc;
            n_trap_p            <= n_trap_p + 1;
        end
        //   ★ 中断交付：后端 `irq_mti_w`（MIE×MTIE×MTIP×ROB 非空×非异常/xRET 拍）
        irq_seen_q <= rst_n & u_dut.irq_mti_w;
        if (rst_n && u_dut.irq_mti_w) begin
            irq_target_q <= u_dut.be_trp_redirect_pc;
            if (!irq_seen_q) n_irq_p <= n_irq_p + 1;
        end
    end
    //   ★ 逐程序**分基址**（16 KB 步进）：三个程序同址装载会让 L1I 里的上一程序陈旧行
    //     "同 tag 命中"（L1I 阵列无复位、`inval_all` 本段未接）⇒ PC 流对、指令却是上一
    //     程序的。程序全部 %pcrel 位置无关 ⇒ 换基址只需平移黄金 PC（锁步 TB 同法）。
    function [31:0] pbase; input integer i; begin pbase = PROG_PC + (i * 32'h4000); end endfunction
    reg [31:0] cur_base, gold_delta;
    //   ★ 2B-4 第 4a 段：装载索引位宽 14→18 位（`a[15:2]` → `a[19:2]`）。
    //     5 个程序 16 KB 步进的第 5 个基址 = 0x8001_0000 ⇒ `a[15:2]` 会**静默截断成 0**
    //     （映像装到 DDR3 起始处，取指却读 0x0001_0000 ⇒ 全是 clear_mem 的 nop 填充）。
    function [17:0] w_idx; input [31:0] a; begin w_idx = a[19:2]; end endfunction

    task automatic clear_mem;
        integer m;
        begin
            @(negedge clk);
            for (m = 0; m < 32768; m = m + 1) u_mem.ddr3_mem[m] = 32'h0000_0013;
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

    //   [诊断，默认关] MTI 中断交付后 220 拍的现场摘要（DBG_P8=1 时打开）
    integer dbg_c;
    initial dbg_c = -1;
    always @(posedge clk) begin
        if (u_dut.irq_mti_w && (dbg_c < 0)) dbg_c <= 0;
        else if ((dbg_c >= 0) && (dbg_c < 220)) begin
            if (DBG_P8) begin
                if (u_dut.commit_valid != 0)
                    $display("   [irq-cmt %0d] pc0=0x%08x v=%b", dbg_c, u_dut.commit_pc[0 +: 32], u_dut.commit_valid);
                if ((dbg_c % 10) == 0)
                    $display("   [irq-s %0d] rb_act=%b busy=%b/%b robcnt=%0d blkv=%b rdy=%b disp=%b",
                             dbg_c, u_dut.u_back.u_ren_i.rb_act, u_dut.u_back.rn_i_busy, u_dut.u_back.rn_f_busy,
                             u_dut.u_back.dbg_rob_cnt_o, u_dut.blk_valid, u_dut.blk_ready, u_dut.u_back.disp_fire_w);
            end
            dbg_c <= dbg_c + 1;
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
        pidx[3] = 6; cmax_of[3] = P6_GOLD_N;    // p7_trap（ecall/非法/ebreak→mtvec→mret）
        pidx[4] = 7; cmax_of[4] = P7_GOLD_N;    // p8_int（CLINT MTI 中断；无黄金=0）
        pidx[5] = 8; cmax_of[5] = P8_GOLD_N;    // p9_trapvec（mtvec MODE=1 向量模式）
        pidx[6] = 9; cmax_of[6] = P9_GOLD_N;    // p10_csr（CSR 读写轨迹：b2_csr→csr_file 的前置判据）
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
            n_trap_p = 0; trap_seen_q = 1'b0; n_irq_p = 0; irq_seen_q = 1'b0;
            irq_target_q = 32'h0;
            for (k = 0; k < 8; k = k + 1) begin
                trc_cause[k] = 4'h0; trc_pc[k] = 32'h0; trp_tgt[k] = 32'h0;
            end
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
            if (pid == 4) begin
                //   ★ p8_int：固定拍数（无黄金轨迹可等；中断在 ~200 拍后到，余量充足）
                for (k = 0; k < P8_CYCLES; k = k + 1) begin
                    @(posedge clk);
                    //   [诊断，默认关] CLINT/CSR/中断判定现场（每 500 拍一条，共 8 条）
                    if (DBG_P8 && ((k % 500) == 0))
                        $display("   [p8-dbg] cyc=%0d mtime=0x%08x mtimecmp=0x%08x MTIP=%b | mie=0x%03x mstatus=0x%08x | irq=%b robcnt=%0d clint_vld=%b hit=%b",
                                 k, u_dut.u_clint.mtime_r[31:0], u_dut.u_clint.mtimecmp_r[31:0],
                                 u_dut.clint_mtip_w, u_dut.u_back.u_csr.mie_q,
                                 u_dut.u_back.u_csr.mstatus_q, u_dut.irq_mti_w,
                                 u_dut.u_back.rob_cnt_w, u_dut.clint_req_vld, u_dut.clint_hit_w);
                end
                cyc = P8_CYCLES;
                $display("   [C8'] 中断现场：mtvec=0x%08x mepc=0x%08x mcause=0x%08x | 处理程序 s1=1、主程序 a0=1（共提交 %0d 条）",
                         u_dut.u_back.u_csr.mtvec_q, u_dut.u_back.u_csr.mepc_q,
                         u_dut.u_back.u_csr.mcause_q, nrec);
            end
            while ((pid != 4) && (nrec < cmax_of[pid]) && (cyc < CYC_LIMIT)) begin
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

            if (pid != 4) begin
            // ---- C1' ----
            d_pc = 0;
            for (k = 0; k < cmax_of[pid]; k = k + 1)
                if ((rpc[k] !== (GOLD[cur_p*P_GOLD_MAX + k] + gold_delta)) && (d_pc == 0)) begin
                    $display("FAIL: 程序 %0d 第 %0d 条 PC=0x%08x 期望 0x%08x",
                             pid, k, rpc[k], GOLD[cur_p*P_GOLD_MAX + k] + gold_delta);
                    d_pc = 1;
                end
            //   [诊断，默认关] p10：CSR 轨迹逐条对照（本核 vs Spike 黄金；放在 chk 之前，chk 失败会 $fatal）
            if ((pid == 6) && DBG_P10)
                for (k = 0; k < 22; k = k + 1)
                    $display("   [C10-dbg] idx=%0d pc=0x%08x we=%b rd=%0d(g %0d) wd=0x%08x(g 0x%08x)",
                             k, rpc[k], rwe[k], rrd[k], GREG_RD[cur_p*P_GOLD_MAX + k],
                             rwd[k], GREG_WD[cur_p*P_GOLD_MAX + k]);
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
            end else begin
                //   ================= C8'：核内 CLINT + MTI 中断（2B-4 第 4a 段）=================
                //   口径：**自记录 + 硬编码期望**（mtime 自由计数 ⇒ 与 Spike 不可逐条比）
                chk(n_irq_p == 1, $sformatf("C8' p8：MTI 中断交付次数 = 1（实测 %0d，期望恰好 1 次：处理程序关源）", n_irq_p));
                chk(n_trap_p == 0, $sformatf("C8' p8：无异常交付（实测 %0d）", n_trap_p));
                chk(u_dut.u_back.u_csr.mcause_q == 32'h8000_0007,
                    $sformatf("C8' p8：陷阱 CSR mcause = 0x80000007（MTI），实测 0x%08x", u_dut.u_back.u_csr.mcause_q));
                chk((u_dut.u_back.u_csr.mepc_q >= cur_base) && (u_dut.u_back.u_csr.mepc_q < (cur_base + 32'h1000)),
                    $sformatf("C8' p8：mepc 落在程序映像内（实测 0x%08x，基址 0x%08x）", u_dut.u_back.u_csr.mepc_q, cur_base));
                //   ★ 2B-4 第 4b 段（第一步）新增：**中断向量化**（MODE=1 ⇒ 中断目标 = BASE + 4×cause）
                chk(u_dut.u_back.u_csr.mtvec_q[1:0] == 2'b01,
                    $sformatf("C8' p8：mtvec MODE = 1（Vectored），实测 mtvec=0x%08x", u_dut.u_back.u_csr.mtvec_q));
                chk(irq_target_q == ((u_dut.u_back.u_csr.mtvec_q & ~32'hFF) | 32'd28),
                    $sformatf("C8' p8：MTI(cause 7) 向量目标 = BASE+28，实测 0x%08x（BASE=0x%08x）",
                              irq_target_q, u_dut.u_back.u_csr.mtvec_q & ~32'hFF));
                //   · 处理程序里 `csrr t1, mepc`（x6）的写回值 = 被中断指令 PC
                //     ⇒ 必须落在 wait 循环 [0x4c, 0x54]（相对基址）
                d_pc = 0; d_rd = 0; d_wd = 0; d_rd = 0;
                crk = 0;
                for (k = 0; k < 1024; k = k + 1) begin
                    if (rwe[k] && (rrd[k] == 5'd9) && (rwd[k] === 32'd1)) d_rd = 1;   // s1 == 1
                    if (rwe[k] && (rrd[k] == 5'd10) && (rwd[k] === 32'd1)) d_wd = 1;  // a0 == 1（走到 done）
                    //   · 处理程序首条已提交（= 重定向到 mtvec 成功）
                    if (rpc[k] == ((u_dut.u_back.u_csr.mtvec_q & ~32'hFF) | 32'd28)) crk = 1;
                    //   · `csrr t1, mepc`（0x80，写 x6）采到的被中断指令 PC ∈ wait 循环
                    if (rwe[k] && (rrd[k] == 5'd6) && (rpc[k] == (cur_base + 32'h84))) begin
                        $display("   [C8'] handler 采到的 mepc=0x%08x（wait 循环 0x%08x..0x%08x）",
                                 rwd[k], cur_base + 32'h50, cur_base + 32'h58);
                        if ((rwd[k] >= (cur_base + 32'h50)) && (rwd[k] <= (cur_base + 32'h58))) d_pc = 1;
                    end
                end
                chk(crk == 1, "C8' p8：向量槽 7（BASE+28）已提交 ⇒ 中断向量化重定向成功");
                chk(d_pc == 1, "C8' p8：中断返回点 mepc ∈ wait 循环（bne/addi/j，可重启指令）");
                chk(d_rd == 1, "C8' p8：处理程序自记录 s1 = 1（中断交付次数）");
                chk(d_wd == 1, "C8' p8：主程序观察到中断后走到 done（a0 = s1 = 1）⇒ mret 精确返回");
                //   （p8 的 mtvec 现在是"Vectored BASE|1"：BASE 必须 256 B 对齐且落在映像内）
                chk(((u_dut.u_back.u_csr.mtvec_q & ~32'hFF) >= cur_base) &&
                    ((u_dut.u_back.u_csr.mtvec_q & ~32'hFF) < (cur_base + 32'h1000)),
                    $sformatf("C8' p8：mtvec BASE 落在程序映像内且 256 B 对齐（实测 mtvec=0x%08x）",
                              u_dut.u_back.u_csr.mtvec_q));
            end
            //   ---- C5'：非陷阱程序必须"全程无提交点异常" ----
            //   ★ p7_trap 是**故意**制造异常的程序 ⇒ C5' 换判据 C7'（陷阱次数/原因/PC）。
            if ((pid != 3) && (pid != 5)) begin
                chk(u_dut.trap_valid_w == 1'b0, $sformatf("C5' 程序 %0d：全程无提交点异常", pid));
                chk(n_trap_p == 0, $sformatf("C5' 程序 %0d：全程无陷阱交付", pid));
                //   ============ C10'：CSR 读写轨迹（2B-4 第 4b-1 段前置判据）============
                //   从写回轨迹里直接抓 CSR 读回值（C3' 已与 Spike 逐条比过；此处给可读证据）
                if (pid == 6) begin
                    d_pc = 0; d_rd = 0; d_wd = 0;                       // 复用为"命中标志"
                    for (k = 0; k < 1024; k = k + 1) begin
                        //   csrr s10, mscratch（末次读回 0x30）/ csrr a3, mie（0x888）/ mstatus&0x1888
                        if (rwe[k] && (rrd[k] == 5'd26) && (rwd[k] === 32'h0000_0010)) d_pc = 1;
                        if (rwe[k] && (rrd[k] == 5'd13) && (rwd[k] === 32'h0000_0808)) d_rd = 1;
                        if (rwe[k] && (rrd[k] == 5'd15) && (rwd[k] === 32'h0000_1800)) d_wd = 1;
                    end
                    chk(d_pc == 1, "C10' p10：mscratch 立即数形式序列末值 = 0x10（csrrwi/csrrsi/csrrci 生效 ⇒ D2 无回归）");
                    chk(d_rd == 1, "C10' p10：mie 写 0x808 后回读 = 0x808（位域/WARL 口径）");
                    chk(d_wd == 1, "C10' p10：mstatus 写 0x1800 后回读掩码 = 0x1800（MPP 口径）");
                    $display("   [C10'] CSR 轨迹：mscratch(w/rw/rs/rc/wi/si/ci)=0x10、mie=0x808、mstatus&0x1888=0x1800（mip/MTIP 见 p8 的 C8'）；csrrw/rs/rc 旧值、WARL 回读均与 Spike 黄金逐条一致");
                    $fflush();
                end
            end else if (pid == 5) begin
                //   ============ C9'：mtvec **向量模式**（MODE=1）实测（2B-4 第 4b 段第一步）============
                //   判据：三条异常各自落到 base + 4×cause 的**不同槽**（由槽内标记经写回轨迹背书）。
                chk(n_trap_p == 3, $sformatf("C9' p9：陷阱交付次数 = 3（实测 %0d）", n_trap_p));
                chk(u_dut.u_back.u_csr.mtvec_q[1:0] == 2'b01,
                    $sformatf("C9' p9：mtvec MODE = 1（向量），实测 mtvec=0x%08x", u_dut.u_back.u_csr.mtvec_q));
                chk(trc_cause[0] == 4'd11, $sformatf("C9' p9：第 1 次 mcause = 11，实测 %0d", trc_cause[0]));
                chk(trc_cause[1] == 4'd2,  $sformatf("C9' p9：第 2 次 mcause = 2，实测 %0d", trc_cause[1]));
                chk(trc_cause[2] == 4'd3,  $sformatf("C9' p9：第 3 次 mcause = 3，实测 %0d", trc_cause[2]));
                //   ★ 口径（`docs/design/06-csr-privilege.md §3.2`，与 ISA 手册逐字同）：
                //     MODE=1 下**同步异常一律回 BASE**，只有**中断**才 `BASE + 4×cause`
                //     ⇒ 三条异常的落点必须**全部等于 BASE**（4a 段实现曾误做向量化，已修）
                //   `trp_tgt[i]` = 该次陷阱的**重定向目标**；异常在 MODE=1 下必须落 BASE
                chk(trp_tgt[0] == (u_dut.u_back.u_csr.mtvec_q & ~32'hFF),
                    $sformatf("C9' p9：ecall(cause 11) 重定向目标 = BASE（Vectored 下异常不向量），实测 0x%08x（BASE=0x%08x）",
                              trp_tgt[0], u_dut.u_back.u_csr.mtvec_q & ~32'hFF));
                chk(trp_tgt[1] == (u_dut.u_back.u_csr.mtvec_q & ~32'hFF),
                    $sformatf("C9' p9：非法(cause 2) 重定向目标 = BASE，实测 0x%08x", trp_tgt[1]));
                chk(trp_tgt[2] == (u_dut.u_back.u_csr.mtvec_q & ~32'hFF),
                    $sformatf("C9' p9：断点(cause 3) 重定向目标 = BASE，实测 0x%08x", trp_tgt[2]));
                chk((trc_pc[0] < trc_pc[1]) && (trc_pc[1] < trc_pc[2]) &&
                    (trc_pc[0] >= cur_base) && (trc_pc[2] < (cur_base + 32'h1000)),
                    "C9' p9：三次陷阱指令 PC 严格递增且落在映像内");
                $display("   [C9'] 向量模式：mtvec=0x%08x（MODE=1，BASE=0x%08x）→ 三次同步异常目标均 = BASE（实测 0x%08x/0x%08x/0x%08x），陷阱指令 PC=0x%08x/0x%08x/0x%08x，cause=%0d/%0d/%0d",
                         u_dut.u_back.u_csr.mtvec_q, u_dut.u_back.u_csr.mtvec_q & ~32'hFF,
                         trp_tgt[0], trp_tgt[1], trp_tgt[2],
                         trc_pc[0], trc_pc[1], trc_pc[2],
                         trc_cause[0], trc_cause[1], trc_cause[2]);
                $fflush();
            end else begin
                //   ---- C7'：陷阱路径（2B-4 第 4a 段验收判据）----
                //     ① 陷阱次数：ecall / 非法指令 / ebreak 共 3 次
                //     ② mcause 依次 = 11（M 模式 ecall）/ 2（非法指令）/ 3（断点）
                //     ③ 陷阱 PC 依次 = 三条陷阱指令的 PC（gold_delta 平移后）
                //     ④ 目标：处理器序（PC 流已在 C1' 与 Spike 逐条比中覆盖 mtvec/mepc）
                chk(n_trap_p == 3, $sformatf("C7' p7：陷阱交付次数 = 3（实测 %0d）", n_trap_p));
                chk(trc_cause[0] == 4'd11, $sformatf("C7' p7：第 1 次 mcause = 11（ecall_M），实测 %0d", trc_cause[0]));
                chk(trc_cause[1] == 4'd2,  $sformatf("C7' p7：第 2 次 mcause = 2（非法指令），实测 %0d", trc_cause[1]));
                chk(trc_cause[2] == 4'd3,  $sformatf("C7' p7：第 3 次 mcause = 3（breakpoint），实测 %0d", trc_cause[2]));
                chk((trc_pc[0] < trc_pc[1]) && (trc_pc[1] < trc_pc[2]),
                    "C7' p7：三次陷阱 PC 严格递增（按程序序）");
                chk((trc_pc[0] >= cur_base) && (trc_pc[2] < (cur_base + 32'h1000)),
                    $sformatf("C7' p7：陷阱 PC 落在程序映像内（0x%08x..0x%08x）", trc_pc[0], trc_pc[2]));
                $display("   [C7'] 陷阱序列：pc=0x%08x/cause=%0d → pc=0x%08x/cause=%0d → pc=0x%08x/cause=%0d；mtvec 目标=0x%08x",
                         trc_pc[0], trc_cause[0], trc_pc[1], trc_cause[1],
                         trc_pc[2], trc_cause[2], u_dut.csr_mtvec_w);
                $fflush();
            end
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
