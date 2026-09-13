//=============================================================================
// tb_prof.v —— 长时程剖析 TB：量化停滞来源、提交速率与“是否卡在循环里”
//
// 用途：定位 arch-test 长时间不结束的根因（真循环 vs 只是基线核太慢）。
// 用法：
//   iverilog -g2005 -I rtl/pkg -s tb_prof -o /tmp/prof.vvp \
//       $(find rtl -name '*.v') sim/tb/sim_axi_slave.v sim/tb/tb_prof.v
//   vvp /tmp/prof.vvp +MEM_LO_INIT=... +MEM_HI_INIT=... [+timeout=<拍>] [+win=<拍>]
//
// 输出：
//   · 每 win 拍一行 PROF：周期/提交/IPC/PC/各停滞来源占比/窗口 PC 哈希
//   · tohost/exit 时打印 PASS/FAIL
//   · 结束时打印停滞直方图与最后 40 条提交 PC
//
// 关键信号（层次引用 rv32gc_core 内部）：
//   fetch_stall / mem_stall / mdu_hold / load_use / csr_order_stall / front_hold
//=============================================================================
`timescale 1ns/1ps
module tb_prof;
  reg clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  // ---- AXI 连线 ----
  wire [3:0]  arid;   wire [31:0] araddr; wire [3:0] arlen;
  wire [2:0]  arsize; wire [1:0]  arburst, arlock; wire [3:0] arcache; wire [2:0] arprot;
  wire        arvalid, arready, rready;
  wire [1:0]  awburst, awlock;
  wire [3:0]  rid, bid, awid, wid;
  wire [31:0] rdata, awaddr, wdata;
  wire [1:0]  rresp, bresp;
  wire        rlast, rvalid, awvalid, awready, wvalid, wready, bvalid, bready, wlast;
  wire [3:0]  awlen, wstrb;
  wire [2:0]  awsize, awprot;
  wire [3:0]  awcache;
  wire        ws_valid;
  wire [31:0] dbg_pc, dbg_wdata;
  wire [3:0]  dbg_wen4;
  wire [4:0]  dbg_wnum;

  core_top dut (
    .aclk(clk), .aresetn(rst_n), .intrpt(8'd0),
    .arid(arid), .araddr(araddr), .arlen(arlen), .arsize(arsize), .arburst(arburst),
    .arlock(arlock), .arcache(arcache), .arprot(arprot), .arvalid(arvalid), .arready(arready),
    .rid(rid), .rdata(rdata), .rresp(rresp), .rlast(rlast), .rvalid(rvalid), .rready(rready),
    .awid(awid), .awaddr(awaddr), .awlen(awlen), .awsize(awsize), .awburst(awburst),
    .awlock(awlock), .awcache(awcache), .awprot(awprot), .awvalid(awvalid), .awready(awready),
    .wid(wid), .wdata(wdata), .wstrb(wstrb), .wlast(wlast), .wvalid(wvalid), .wready(wready),
    .bid(bid), .bresp(bresp), .bvalid(bvalid), .bready(bready),
    .break_point(1'b0), .infor_flag(1'b0), .reg_num(5'd0), .rf_rdata(),
    .ws_valid(ws_valid), .debug0_wb_pc(dbg_pc), .debug0_wb_rf_wen(dbg_wen4),
    .debug0_wb_rf_wnum(dbg_wnum), .debug0_wb_rf_wdata(dbg_wdata)
  );

  wire        uart_we, vuart_we, exit_we, tohost_we, num_we;
  wire [7:0]  uart_wdata, vuart_wdata;
  wire [31:0] exit_wdata, tohost_wdata, num_val;

  sim_axi_slave u_slave (
    .clk(clk), .rst_n(rst_n),
    .s_awid(awid), .s_awaddr(awaddr), .s_awlen(awlen), .s_awsize(awsize), .s_awburst(awburst),
    .s_awvalid(awvalid), .s_awready(awready),
    .s_wid(wid), .s_wdata(wdata), .s_wstrb(wstrb), .s_wlast(wlast), .s_wvalid(wvalid), .s_wready(wready),
    .s_bid(bid), .s_bresp(bresp), .s_bvalid(bvalid), .s_bready(bready),
    .s_arid(arid), .s_araddr(araddr), .s_arlen(arlen), .s_arsize(arsize), .s_arburst(arburst),
    .s_arvalid(arvalid), .s_arready(arready),
    .s_rid(rid), .s_rdata(rdata), .s_rresp(rresp), .s_rlast(rlast), .s_rvalid(rvalid), .s_rready(rready),
    .uart_we(uart_we), .uart_wdata(uart_wdata),
    .vuart_we(vuart_we), .vuart_wdata(vuart_wdata),
    .exit_we(exit_we), .exit_wdata(exit_wdata),
    .tohost_we(tohost_we), .tohost_wdata(tohost_wdata),
    .num_val(num_val), .num_we(num_we)
  );

  integer cyc = 0;
  integer horizon = 200000, win = 100000;
  reg [1023:0] f;
  integer i, tmo;

  // ---- 累计统计 ----
  integer n_commit = 0, n_trap = 0, n_fetch_stall = 0, n_mem_stall = 0;
  integer n_mdu_hold = 0, n_load_use = 0, n_csr_order = 0, n_front_hold = 0;
  integer n_if_req = 0, n_ar_hs = 0, n_r_beat = 0, n_aw_hs = 0, n_w_beat = 0, n_b_hs = 0;
  integer n_d_req = 0, n_d_rsp = 0;
  integer w_commit = 0, w_hash = 0, w_first_pc = 0, w_last_pc = 0;
  integer prev_cyc = 0, prev_commit = 0;

  // 最后 40 条提交 PC（环形）
  reg [31:0] last_pc [0:39];
  integer lp = 0;

  // 每一拍采样
  always @(posedge clk) begin
    cyc <= cyc + 1;
    if (cyc == 10) rst_n <= 1;
    if (!rst_n) begin
      // 保持在复位
    end else begin
      if (dut.u_core.wb_retire) begin
        n_commit = n_commit + 1;
        w_commit = w_commit + 1;
        w_hash   = w_hash ^ (dut.u_core.wb_pc_q * 32'd2654435761 + 32'd12345);
        if (w_first_pc == 0) w_first_pc = dut.u_core.wb_pc_q;
        w_last_pc = dut.u_core.wb_pc_q;
        last_pc[lp] = dut.u_core.wb_pc_q;
        lp = (lp + 1) % 40;
      end
      if (dut.u_core.trap_take) n_trap = n_trap + 1;
      if (dut.u_core.fetch_stall)      n_fetch_stall = n_fetch_stall + 1;
      if (dut.u_core.mem_stall)        n_mem_stall   = n_mem_stall   + 1;
      if (dut.u_core.mdu_hold)         n_mdu_hold    = n_mdu_hold    + 1;
      if (dut.u_core.load_use)         n_load_use    = n_load_use    + 1;
      if (dut.u_core.csr_order_stall)  n_csr_order   = n_csr_order   + 1;
      if (dut.u_core.front_hold)       n_front_hold  = n_front_hold  + 1;
      if (dut.u_core.if_req_valid && dut.u_core.if_req_ready) n_if_req = n_if_req + 1;
      if (arvalid && arready) n_ar_hs = n_ar_hs + 1;
      if (rvalid && rready)   n_r_beat = n_r_beat + 1;
      if (awvalid && awready) n_aw_hs = n_aw_hs + 1;
      if (wvalid && wready)   n_w_beat = n_w_beat + 1;
      if (bvalid && bready)   n_b_hs = n_b_hs + 1;
      if (dut.u_core.d_req_valid) n_d_req = n_d_req + 1;
      if (dut.u_core.d_rsp_valid) n_d_rsp = n_d_rsp + 1;
    end
  end

  initial begin
    if (!$value$plusargs("MEM_LO_INIT=%s", f)) f = "";
    if (f != "") $readmemh(f, u_slave.mem_lo);
    if ($value$plusargs("MEM_HI_INIT=%s", f)) $readmemh(f, u_slave.mem_hi);
    if (!$value$plusargs("timeout=%d", horizon)) horizon = 200000;
    if (!$value$plusargs("win=%d", win)) win = 100000;
    $display("PROF: horizon=%0d win=%0d", horizon, win);
    for (i = 0; i < 40; i = i + 1) last_pc[i] = 32'hFFFF_FFFF;

    // 周期/window 报告
    forever begin
      @(posedge clk);
      if (rst_n && (cyc > 10) && ((cyc % win) == 0)) begin
        $display("PROF cyc=%0d commit=%0d (win=%0d) IPC=%0d.%02d pc=%h winPC=[%h..%h] hash=%h | fstall=%0d mstall=%0d csr=%0d luse=%0d mdu=%0d | if=%0d ar=%0d rb=%0d aw=%0d wb=%0d b=%0d dr=%0d ds=%0d",
          cyc, n_commit, w_commit,
          (w_commit*100)/(cyc-prev_cyc), ((w_commit*10000)/(cyc-prev_cyc))%100,
          dut.u_core.pc_q, w_first_pc, w_last_pc, w_hash,
          n_fetch_stall-prev_cyc, n_mem_stall, n_csr_order, n_load_use, n_mdu_hold,
          n_if_req, n_ar_hs, n_r_beat, n_aw_hs, n_w_beat, n_b_hs, n_d_req, n_d_rsp);
        w_commit = 0; w_hash = 0; w_first_pc = 0;
        prev_cyc = cyc;
        prev_commit = n_commit;
        if (cyc >= horizon) begin
          prof_finish(0);
        end
      end
    end
  end

  task prof_finish;
    input integer code;
    begin
      $display("PROF: ===== 结束 cyc=%0d code=%0d =====", cyc, code);
      $display("PROF: commit=%0d IPCall=%.3f traps=%0d", n_commit,
               (n_commit*1.0)/cyc, n_trap);
      $display("PROF: stalls: fetch=%0d mem=%0d csr_order=%0d load_use=%0d mdu=%0d front_hold=%0d",
               n_fetch_stall, n_mem_stall, n_csr_order, n_load_use, n_mdu_hold, n_front_hold);
      $display("PROF: 总线: if_req=%0d ar=%0d rbeat=%0d aw=%0d wbeat=%0d b=%0d dreq=%0d drsp=%0d",
               n_if_req, n_ar_hs, n_r_beat, n_aw_hs, n_w_beat, n_b_hs, n_d_req, n_d_rsp);
      // ---- 死锁现场 ----
      $display("PROF: [现场] pc=%h cross=%b line_valid=%b need_cross=%b if_ready=%b at_end=%b hw0=%h hw1=%h",
               dut.u_core.pc_q, dut.u_core.cross_q, dut.u_core.line_valid,
               dut.u_core.need_cross, dut.u_core.if_ready, dut.u_core.at_line_end,
               dut.u_core.hw0, dut.u_core.hw1);
      $display("PROF: [现场] redirect=%b trap=%b xret=%b exbr=%b idjal=%b | ifetch: vld=%b tag=%h busy=%b reqv=%b reqa=%h rspv=%b",
               dut.u_core.redirect_valid, dut.u_core.trap_take, dut.u_core.xret_take,
               dut.u_core.ex_br_redirect, dut.u_core.id_jal_taken,
               dut.u_core.u_ifetch.line_vld_q, dut.u_core.u_ifetch.line_tag_q,
               dut.u_core.u_ifetch.busy_q, dut.u_core.u_ifetch.if_req_valid,
               dut.u_core.u_ifetch.if_req_addr, dut.u_core.if_rsp_valid);
      $display("PROF: [现场] IDv=%b IDpc=%h EXv=%b EXpc=%h exbrtaken=%b | MEMv=%b MEMpc=%h memst=%0d | WBv=%b WBpc=%h",
               dut.u_core.id_valid_q, dut.u_core.id_pc_q,
               dut.u_core.ex_valid_q, dut.u_core.ex_pc_q, dut.u_core.br_taken,
               dut.u_core.mem_valid_q, dut.u_core.mem_pc_q, dut.u_core.memst_q,
               dut.u_core.wb_valid_q, dut.u_core.wb_pc_q);
      $display("PROF: 最后 40 条提交 PC（旧→新）:");
      for (i = 0; i < 40; i = i + 1)
        $display("  lastPC[%0d]=%h", i, last_pc[(lp + i) % 40]);
      if (code == 0) $display("TB: TEST PASS");
      else           $display("TB: TEST FAIL code=%0d", code);
      $finish;
    end
  endtask

  // tohost / exit 观测
  always @(posedge clk) begin
    if (rst_n) begin
      if (tohost_we) begin
        $display("PROF: TOHOST=%0d @cyc=%0d", tohost_wdata, cyc);
        if (tohost_wdata == 32'd1) prof_finish(0);
        else if (tohost_wdata == 32'd3) prof_finish(1);
      end
      if (exit_we) begin
        $display("PROF: EXIT=%0d @cyc=%0d", exit_wdata, cyc);
        prof_finish(exit_wdata == 0 ? 0 : 1);
      end
    end
  end

  // 硬超时
  initial begin
    if (!$value$plusargs("timeout=%d", tmo)) tmo = horizon;
    #(2000000000);
    $display("PROF: 绝对超时");
    prof_finish(2);
  end
endmodule
