//==============================================================================
// sim/functional/tb_data_bus_irq.sv —— 数据总线 IRQ/PLIC 三模式定向 TB（fail-closed）
//==============================================================================
// 归属 : 2B 数据总线（真实外部 IRQ 取消普通 head cached load；真实 PLIC claim/complete）
// 三个固定 case（同一 TB 由 MODE 选择；三模式必须全跑，未触发不算 PASS）:
//   IRQ_LOAD  (MODE=1)：普通 DRAM cache-miss load A 在真实 AXI AR 后由外部 intrpt[1]
//                        拉高；A 的 R 首 beat 延迟 100 拍。要求：A 未 done 时取 IRQ、
//                        mcause=0x8000000B、mepc=A_PC；claim/complete 各 1；in-service
//                        恰一次；A 的 8 个迟 R 在中断后由 L1D fill(owner=DFIL) 消费、
//                        A 的 ROB 无写回；B（不同 PA、已知值）与 claim 各拿自己的数据。
//   IRQ_REUSE (MODE=3)：同 IRQ_LOAD，但要求 B 实际复用 A 的 LQ tag（tag 相同）且 B 的
//                        数据仍为 B 的 known 值（不吃 A 的旧数据）。
//   IRQ_ONLY  (MODE=2)：纯 IRQ 无 load 控制：wait_loop 提交后拉 pin，证明 handler/
//                        PLIC claim→in-service→complete 链本身成立。
//
// 纪律：只从外部 `intrpt` 引脚驱动（不 force 任何 DUT 内部）；程序结果经 DDR 邮箱 +
//       cbo.flush 写回；TB 侧存储模型/程序由驱动注入（-P），断言标准输出唯一锚点
//       `TB_DATA_BUS_IRQ: PASS mode=<n>`；失败打印 `FAIL: ...` 并 $fatal（rc≠0）。
//==============================================================================
`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"

module tb_data_bus_irq #(
    parameter integer CLK_HALF_NS  = 5,
    parameter integer RESET_CYCLES = 20,
    parameter integer MAX_CYCLES   = 60000,
    parameter integer DRAIN_CYCLES = 300,
    parameter integer MODE         = 1,      // 1=IRQ_LOAD, 2=IRQ_ONLY, 3=IRQ_REUSE
    parameter [8*512-1:0] PROG_HEX = "",
    parameter [31:0] A_PC          = 32'h0,
    parameter [31:0] WAIT_PC       = 32'h0,
    parameter [31:0] DDR_A         = 32'h0000_3000,
    parameter [31:0] DDR_B         = 32'h0000_4000,
    parameter integer HOLD_DLY     = 100
) ();

    localparam [31:0] MAGIC = 32'h5443_3031;   // "TC01"
    localparam [31:0] DONE  = 32'hDEAD_BEEF;
    localparam [31:0] AVAL  = 32'hA5A5_000A;
    localparam [31:0] BVAL  = 32'hB6B6_000B;
    localparam integer MBW  = 32'h0000_2000 >> 2;

    //==========================================================================
    // 0. 时钟 / 复位 / 外部中断引脚
    //==========================================================================
    reg clk;
    reg rst_n;
    reg [7:0] tb_intrpt;
    initial clk = 1'b0;
    always #(CLK_HALF_NS) clk = ~clk;
    initial begin
        rst_n     = 1'b0;
        tb_intrpt = 8'h00;
        #(RESET_CYCLES * 2 * CLK_HALF_NS);
        rst_n = 1'b1;
    end

    //==========================================================================
    // 1. AXI 连线 + DUT + 存储模型
    //==========================================================================
    wire [3:0]  arid, awid, wid;
    wire [31:0] araddr, awaddr, wdata;
    wire [3:0]  arlen, awlen, wstrb;
    wire [2:0]  arsize, awsize, arprot, awprot;
    wire [1:0]  arburst, awburst, arlock, awlock;
    wire [3:0]  arcache, awcache;
    wire        arvalid, arready, awvalid, awready;
    wire        wlast, wvalid, wready, bvalid, bready;
    wire [3:0]  rid, bid;
    wire [31:0] rdata;
    wire [1:0]  rresp, bresp;
    wire        rlast, rvalid, rready;
    wire        ws_valid;

    core_top_2b u_dut (
        .aclk(clk), .intrpt(tb_intrpt), .aresetn(rst_n),
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
        .ws_valid(ws_valid), .break_point(1'b0), .infor_flag(1'b0), .reg_num(5'd0),
        .rf_rdata(),
        .debug0_wb_pc(), .debug0_wb_rf_wen(), .debug0_wb_rf_wnum(), .debug0_wb_rf_wdata()
    );

    // DUT 发 a[31:20]==0x800 ⇒ 存储模型看 a[19:0]（与既有 2B TB 同口径，TB 侧映射）
    function [31:0] b_map_addr; input [31:0] a;
        begin b_map_addr = (a[31:20] == 12'h800) ? {12'h000, a[19:0]} : a; end
    endfunction
    wire [31:0] m_araddr = b_map_addr(araddr);
    wire [31:0] m_awaddr = b_map_addr(awaddr);

    data_bus_irq_mem_model #(
        .XIP_BASE(32'h1C00_0000), .XIP_ALIAS(`RV32GC_XIP_ALIAS), .XIP_SIZE(32'h0000_1000),
        .DDR3_BASE(32'h0000_0000), .DDR3_LIMIT(32'h0004_0000),
        .UART_DATA_ADDR(32'h1FE0_01E0),
        .READ_LAT_DLY(1), .HOLD_RD_ADDR(DDR_A), .HOLD_RD_DLY(HOLD_DLY)
    ) u_mem (
        .clk(clk), .rst_n(rst_n),
        .arid(arid), .araddr(m_araddr), .arlen(arlen), .arsize(arsize),
        .arburst(arburst), .arlock(arlock), .arcache(arcache), .arprot(arprot),
        .arvalid(arvalid), .arready(arready),
        .rid(rid), .rdata(rdata), .rresp(rresp), .rlast(rlast),
        .rvalid(rvalid), .rready(rready),
        .awid(awid), .awaddr(m_awaddr), .awlen(awlen), .awsize(awsize),
        .awburst(awburst), .awlock(awlock), .awcache(awcache), .awprot(awprot),
        .awvalid(awvalid), .awready(awready),
        .wid(wid), .wdata(wdata), .wstrb(wstrb), .wlast(wlast),
        .wvalid(wvalid), .wready(wready),
        .bid(bid), .bresp(bresp), .bvalid(bvalid), .bready(bready),
        .uart_char(), .uart_char_valid(),
        .uart_tx_count(), .uart_overflow(), .uart_bad_strb_count()
    );

    //==========================================================================
    // 2. 程序装载（hex：@ 字节地址 + 32 位字；DDR 模型按字索引）
    //==========================================================================
    task automatic load_ddr_hex;
        input [8*512-1:0] path;
        input [31:0]      ddr_base;
        integer fd, c, v, addr;
        begin
            fd = $fopen(path, "r");
            if (fd == 0) begin
                $display("FAIL: 打不开程序文件 %0s", path);
                $fatal(1, "DATA_BUS_IRQ 装载失败");
            end
            addr = ddr_base;
            c = $fgetc(fd);
            while (c != -1) begin
                if (c == "@") begin
                    c = $fgetc(fd); v = 0;
                    while (((c >= "0") && (c <= "9")) ||
                           ((c >= "a") && (c <= "f")) ||
                           ((c >= "A") && (c <= "F"))) begin
                        if ((c >= "0") && (c <= "9"))      v = (v << 4) | (c - "0");
                        else if ((c >= "a") && (c <= "f")) v = (v << 4) | (c - "a" + 10);
                        else                               v = (v << 4) | (c - "A" + 10);
                        c = $fgetc(fd);
                    end
                    addr = v[31:0];
                end else if (((c >= "0") && (c <= "9")) ||
                             ((c >= "a") && (c <= "f")) ||
                             ((c >= "A") && (c <= "F"))) begin
                    v = 0;
                    while (((c >= "0") && (c <= "9")) ||
                           ((c >= "a") && (c <= "f")) ||
                           ((c >= "A") && (c <= "F"))) begin
                        if ((c >= "0") && (c <= "9"))      v = (v << 4) | (c - "0");
                        else if ((c >= "a") && (c <= "f")) v = (v << 4) | (c - "a" + 10);
                        else                               v = (v << 4) | (c - "A" + 10);
                        c = $fgetc(fd);
                    end
                    if (addr < ddr_base) begin
                        $display("FAIL: 程序地址 0x%08h 低于基址 0x%08h", addr, ddr_base);
                        $fatal(1, "DATA_BUS_IRQ 装载失败");
                    end
                    u_mem.ddr3_mem[(addr - ddr_base) >> 2] = v[31:0];
                    addr = addr + 32'd4;
                end else begin
                    c = $fgetc(fd);
                end
            end
            $fclose(fd);
            $display("[DATA_BUS_IRQ] 程序装载 path=%0s base=0x%08h", path, ddr_base);
        end
    endtask

    integer tamper_b;
    integer xinj_cause, xinj_epc, xinj_tagx, xinj_tagz;
    integer lc;
    initial begin
        for (lc = 0; lc < 8192; lc = lc + 1) u_mem.ddr3_mem[lc] = 32'h0000_0013;
        for (lc = 0; lc < 1024; lc = lc + 1) u_mem.xip_mem[lc]  = 32'h0000_0013;
        load_ddr_hex(PROG_HEX, 32'h8000_0000);
        u_mem.xip_mem[0] = 32'h8000_02b7;   // lui x5, 0x80000
        u_mem.xip_mem[1] = 32'h0002_8067;   // jalr x0, 0(x5)
        // A/B 已知值（真实低索引；越界硬错）
        if ((DDR_A >> 2) + 8 > (u_mem.DDR3_LIMIT >> 2)) $fatal(1, "DDR_A 越界");
        if ((DDR_B >> 2) + 8 > (u_mem.DDR3_LIMIT >> 2)) $fatal(1, "DDR_B 越界");
        tamper_b = 0;
        if ($value$plusargs("TAMPER_B=%d", tamper_b)) tamper_b = (tamper_b != 0);
        // 负工装（仅 TB 捕获字段注 X，不 force DUT）：验证 X 不会被当 PASS
        xinj_cause = 0; xinj_epc = 0;
        if ($value$plusargs("XINJ_CAUSE=%d", xinj_cause)) xinj_cause = (xinj_cause != 0);
        if ($value$plusargs("XINJ_EPC=%d", xinj_epc))     xinj_epc   = (xinj_epc   != 0);
        xinj_tagx = 0; xinj_tagz = 0;
        if ($value$plusargs("XINJ_TAGX=%d", xinj_tagx))   xinj_tagx  = (xinj_tagx  != 0);
        if ($value$plusargs("XINJ_TAGZ=%d", xinj_tagz))   xinj_tagz  = (xinj_tagz  != 0);
        u_mem.ddr3_mem[(DDR_A >> 2) + 0] = AVAL;
        u_mem.ddr3_mem[(DDR_A >> 2) + 1] = 32'hA5A5_0001;
        u_mem.ddr3_mem[(DDR_B >> 2) + 0] = tamper_b ? AVAL : BVAL;
        u_mem.ddr3_mem[(DDR_B >> 2) + 1] = tamper_b ? 32'hA5A5_0001 : 32'hB6B6_0001;
        $display("[DATA_BUS_IRQ] MEMINIT A[%08x]=%08x B[%08x]=%08x tamper=%0d",
                 DDR_A, u_mem.ddr3_mem[DDR_A >> 2], DDR_B,
                 u_mem.ddr3_mem[DDR_B >> 2], tamper_b);
    end

    //==========================================================================
    // 3. 外部 IRQ 激励（只在真实引脚上拉高；不做任何 force）
    //==========================================================================
    integer irq_ph, irq_pulse, irq_arm_seen, irq_taken, irq_n;
    reg [31:0] irq_cause_seen, irq_epc_seen;
    integer a_inflight_at_irq, claim_n, complete_n, claim_id_ok;
    integer a_accept_seen, b_accept_seen, c_accept_seen, a_wb_after_irq;
    integer late_r_after_irq;
    integer gw_set_seen, gw_clr_seen;
    reg [31:0] a_tag_seen, b_tag_seen, c_tag_seen, a_rob_seen;
    reg [31:0] pend_dbg;
    reg        gw_dbg;
    initial begin
        irq_ph = 0; irq_pulse = 0; irq_arm_seen = 0; irq_taken = 0; irq_n = 0;
        irq_cause_seen = 0; irq_epc_seen = 0; a_inflight_at_irq = 0;
        claim_n = 0; complete_n = 0; claim_id_ok = 0;
        a_accept_seen = 0; b_accept_seen = 0; c_accept_seen = 0;
        a_wb_after_irq = 0; late_r_after_irq = 0; gw_set_seen = 0; gw_clr_seen = 0;
        a_tag_seen = 0; b_tag_seen = 0; c_tag_seen = 0; a_rob_seen = 0;
        pend_dbg = 0; gw_dbg = 0;
    end
    always @(posedge clk) begin
        if (!rst_n) tb_intrpt <= 8'h00;
        else if (irq_ph == 0) begin
            if (((MODE == 1) || (MODE == 3)) && u_mem.arvalid && u_mem.arready &&
                (u_mem.araddr == DDR_A)) begin
                irq_ph <= 1; irq_pulse <= 4; tb_intrpt <= 8'h02; irq_arm_seen <= 1;
                $display("[IRQ] ARM_AR t=%0t ar=%08x len=%0d", $time, u_mem.araddr, u_mem.arlen);
            end else if ((MODE == 2) && u_dut.commit_valid[0] &&
                         (u_dut.commit_pc[31:0] == WAIT_PC)) begin
                irq_ph <= 1; irq_pulse <= 4; tb_intrpt <= 8'h02; irq_arm_seen <= 1;
                $display("[IRQ] ARM_WAIT t=%0t pc=%08x", $time, WAIT_PC);
            end
        end else if (irq_ph == 1) begin
            irq_pulse <= irq_pulse - 1;
            if (irq_pulse == 1) begin
                tb_intrpt <= 8'h00; irq_ph <= 2;
                $display("[IRQ] PIN_DEASSERT t=%0t", $time);
            end
        end
    end

    //==========================================================================
    // 4. 观测（真实层次信号只读；不改 DUT 状态）
    //==========================================================================
    always @(posedge clk) if (rst_n) begin
        if (u_dut.tc_trap_valid && u_dut.tc_trap_is_int) begin
            irq_n <= irq_n + 1;
            if (!irq_taken) begin
                irq_taken      <= 1;
                irq_epc_seen   <= xinj_epc   ? 32'hx : u_dut.tc_trap_epc;
                irq_cause_seen <= xinj_cause ? 32'hx : u_dut.tc_trap_cause;
                a_inflight_at_irq <= (u_dut.ad_st_q != 4'd0) & ~u_dut.d_we_q & ~u_dut.l1d_idle;
                $display("[IRQ] TAKEN t=%0t cause=%08x epc=%08x ad_st=%0d d_we=%b d_tag=%0d l1d_idle=%b i_own=%0d a_inflight=%0d",
                         $time, u_dut.tc_trap_cause, u_dut.tc_trap_epc, u_dut.ad_st_q,
                         u_dut.d_we_q, u_dut.d_tag_q, u_dut.l1d_idle, u_dut.i_own_q,
                         (u_dut.ad_st_q != 4'd0) & ~u_dut.d_we_q & ~u_dut.l1d_idle);
            end
        end
        if (u_dut.d_start) begin
            $display("[IRQ] ACCEPT t=%0t addr=%08x we=%b tag=%0d head=%b unc=%b cp=%b",
                     $time, u_dut.lsu_req_a, u_dut.lsu_req_we, u_dut.lsu_req_tag,
                     u_dut.u_back.u_lsu.mem_req_is_head, u_dut.d_unc_w, u_dut.d_clint_plic);
            if (u_dut.lsu_req_a == 32'h8000_3000) begin
                a_accept_seen <= 1; a_tag_seen <= u_dut.lsu_req_tag;
                a_rob_seen    <= u_dut.u_back.u_lsu.mem_req_rob;
            end else if (u_dut.lsu_req_a == 32'h8000_4000) begin
                b_accept_seen <= 1;
                b_tag_seen <= xinj_tagx ? 32'hx : (xinj_tagz ? 32'hz : u_dut.lsu_req_tag);
                if (xinj_tagx) a_tag_seen <= 32'hx;
                if (xinj_tagz) a_tag_seen <= 32'hz;
            end else if (u_dut.lsu_req_a == 32'h1F30_0004) begin
                c_accept_seen <= 1; c_tag_seen <= u_dut.lsu_req_tag;
            end
        end
        if (u_dut.i_fire)
            $display("[IRQ] IFIRE t=%0t addr=%08x own_new=%0d wr=%b", $time,
                     u_dut.i_addr_new, u_dut.i_own_new, u_dut.i_req_wr);
        if (u_mem.rvalid && u_mem.rready) begin
            $display("[IRQ] RB t=%0t addr=%08x cnt=%0d own=%0d data=%08x",
                     $time, u_mem.rd_addr_q, u_mem.rd_cnt_q, u_dut.i_own_q, u_mem.rdata);
            if (irq_taken && (u_dut.i_own_q == 3'd1) &&
                (u_mem.rd_addr_q >= DDR_A) && (u_mem.rd_addr_q < (DDR_A + 32)))
                late_r_after_irq <= late_r_after_irq + 1;
        end
        if (u_dut.u_plic.pending_r[0] != pend_dbg) begin
            $display("[IRQ] PENDING t=%0t %08x -> %08x", $time, pend_dbg,
                     u_dut.u_plic.pending_r[0]);
            pend_dbg <= u_dut.u_plic.pending_r[0];
        end
        if (u_dut.u_plic.gw_busy_r[1] != gw_dbg) begin
            $display("[IRQ] GW_BUSY t=%0t %b -> %b", $time, gw_dbg, u_dut.u_plic.gw_busy_r[1]);
            if (u_dut.u_plic.gw_busy_r[1]) gw_set_seen <= gw_set_seen + 1;
            else                           gw_clr_seen <= gw_clr_seen + 1;
            gw_dbg <= u_dut.u_plic.gw_busy_r[1];
        end
        if (u_dut.u_plic.req_valid)
            $display("[IRQ] PLIC_REQ t=%0t we=%b addr=%08x wdata=%08x rd_claim=%b wr_claim=%b",
                     $time, u_dut.u_plic.req_write, u_dut.u_plic.req_addr,
                     u_dut.u_plic.req_wdata, u_dut.u_plic.rd_claim, u_dut.u_plic.wr_claim);
        if (u_dut.u_plic.rd_claim) begin
            claim_n <= claim_n + 1;
            if (u_dut.u_plic.claim_id[0] == 32'd1) claim_id_ok <= 1;
            $display("[IRQ] CLAIM t=%0t id=%0d", $time, u_dut.u_plic.claim_id[0]);
        end
        if (u_dut.u_plic.wr_claim) begin
            complete_n <= complete_n + 1;
            $display("[IRQ] COMPLETE t=%0t id=%0d", $time, u_dut.u_plic.req_wdata);
        end
        if (u_dut.u_back.u_lsu.wb_valid) begin
            $display("[IRQ] LSWB t=%0t rob=%0d data=%08x", $time,
                     u_dut.u_back.u_lsu.wb_rob, u_dut.u_back.u_lsu.wb_data);
            if (irq_taken && (u_dut.u_back.u_lsu.wb_rob == a_rob_seen))
                a_wb_after_irq <= a_wb_after_irq + 1;
        end
    end

    //==========================================================================
    // 5. 判据
    //==========================================================================
    integer n_checks;
    reg [8*16-1:0] case_id;
    integer i, cyc, mi;
    reg [31:0] res_w [0:31];
    integer n_words, nchk, done_seen;
    reg [31:0] tmpw;
    task automatic chk(input cond, input string msg);
        begin
            n_checks = n_checks + 1;
            // X/Z 一律失败：4 态判据，绝不因 X 让 !cond 为假而跳过 fatal
            if (cond !== 1'b1) begin
                $display("FAIL: %s（第 %0d 项检查）", msg, n_checks);
                $fatal(1, "DATA_BUS_IRQ 判据不满足");
            end
        end
    endtask

    initial begin
        if (MODE == 1)      case_id = "IRQ_LOAD";
        else if (MODE == 2) case_id = "IRQ_ONLY";
        else                case_id = "IRQ_REUSE";
        n_checks = 0; n_words = 0; nchk = 0; done_seen = 0;
        for (i = 0; i < 32; i = i + 1) res_w[i] = 32'h0;
        wait (rst_n === 1'b1);
        for (cyc = 0; (cyc < MAX_CYCLES) && !done_seen; cyc = cyc + 1) begin
            @(posedge clk);
            if (u_mem.ddr3_mem[MBW] == MAGIC) begin
                mi = u_mem.ddr3_mem[MBW + 1];
                if (((mi == 13) || (mi == 14)) &&
                    (u_mem.ddr3_mem[MBW + 2 + mi] == DONE)) begin
                    n_words = mi + 3;
                    for (i = 0; i < 32; i = i + 1) res_w[i] = 32'h0;
                    for (i = 0; i < n_words; i = i + 1) res_w[i] = u_mem.ddr3_mem[MBW + i];
                    done_seen = 1;
                end
            end
        end
        if (!done_seen) begin
            $display("FAIL: 超时未收到邮箱 DONE（mode=%0d pc=%08x rob=%0d）",
                     MODE, u_dut.debug0_wb_pc, u_dut.dbg_rob_cnt_w);
            $fatal(1, "DATA_BUS_IRQ 超时");
        end
        repeat (DRAIN_CYCLES) @(posedge clk);

        // ---- 程序结果流 ----
        nchk = res_w[1];
        chk(n_words == (nchk + 3), "结果字数 == NCHK + 3");
        chk((res_w[0] == MAGIC) && (nchk == 13), "结果流 MAGIC/NCHK 正确");
        for (i = 2; i <= (nchk + 1); i = i + 1)
            if (res_w[i] !== 32'd1)
                $display("FAIL: 程序自检 C%0d = 0x%08h（期望 1）", i - 1, res_w[i]);
        chk(res_w[nchk + 2] == DONE, "结果流结束标记 DONE");
        begin : prog_all
            integer all_ok;
            begin
                all_ok = 1;
                for (i = 2; i <= (nchk + 1); i = i + 1)
                    if (res_w[i] !== 32'd1) all_ok = 0;
                chk(all_ok == 1, "程序自检 C1..C13 全为 1");
            end
        end

        // ---- 中断/PLIC/数据归属 ----
        chk(irq_arm_seen == 1, "外部 IRQ 已在真实事件后拉高");
        chk(irq_taken == 1, "真实取到外部中断");
        chk(irq_cause_seen === 32'h8000_000B, "mcause = 0x8000000B (MEI)");
        chk(claim_n == 1 && complete_n == 1, "PLIC claim/complete 各恰一次");
        chk(claim_id_ok == 1, "PLIC claim 返回 source 1");
        chk(irq_n == 1, "只取一次中断（无重入/饥饿）");
        chk((gw_set_seen === 1) && (gw_clr_seen === 1) &&
            (u_dut.u_plic.gw_busy_r[1] === 1'b0), "PLIC in-service 恰一次 set→clear");
        chk(u_dut.u_plic.pending_r[0][1] === 1'b0, "claim 后 source1 pending 已清");

        if ((MODE == 1) || (MODE == 3)) begin
            chk(irq_epc_seen === A_PC, "中断 mepc = A_load PC");
            chk(a_inflight_at_irq == 1, "取中断拍 A 未完成（adapter 非 IDLE / L1D 忙）");
            chk(a_accept_seen == 1, "A 的真实 accept 已发生");
            chk(late_r_after_irq == 8, "A 的 8 个迟 R 在中断后到达（owner=DFIL）");
            chk(a_wb_after_irq == 0, "A 的 ROB 项无 load 写回（旧响应被吞）");
            chk(b_accept_seen == 1 && c_accept_seen == 1, "B 与 claim 的 accept 均发生");
            if (MODE == 3)
                // 两 tag 同 X / 同 Z 时 `==` 为 X ⇒ 严格 chk（!==1'b1）必红；
                // 已知同 tag 才为 1。不得用 `===` 让同 X/同 Z 假绿。
                chk((a_accept_seen === 1) && (b_accept_seen === 1) &&
                    (a_tag_seen == b_tag_seen),
                    "B 实际复用 A 的 LQ tag（same tag）");
        end else begin
            chk(irq_epc_seen === WAIT_PC, "纯 IRQ 的 mepc = wait_loop PC");
        end

        $display("DATA_BUS_IRQ_CASE id=%0s mode=%0d checks=%0d result=PASS",
                 case_id, MODE, n_checks);
        $display("TB_DATA_BUS_IRQ: PASS mode=%0d", MODE);
        $finish;
    end

endmodule
