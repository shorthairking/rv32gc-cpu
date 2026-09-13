//=============================================================================
// tb_trace_mem.v —— 提交轨迹 + 访存请求/响应追踪 TB（arch-test / 定向测试通用调试台）
//
// 与 tb_smoke.v 的区别：不做 PASS/FAIL 判定，只输出轨迹；重点是**访存侧完整可见性**：
//   * COMMIT：每条退休指令（pc / instr / rd / wdata / wen）
//   * DREQ/DRSP：核内 D 侧每次请求握手与响应（地址、we、写数据、字节使能、读回值、err）
//   * AXIWR/AXIRD：AXI 通道上实际落地的写/读（地址、数据、strb）
//   * TRAP：陷阱发生（cause/tval/priv/instr）
//   * CSRW/CSRID：CSR 写与译码
// 用途：定位"某条指令实际访问了哪个地址、读到什么值"（本轮用它查清了 Zalrsc 的
//       错位访问与本核 store→load 可见性问题）。
//
// 编译/运行（见 run_trace.sh）：
//   iverilog -g2005 -I rtl/pkg -s tb_trace_mem -o sim/log/trace.vvp \
//       -DCORE_PRESENT $(find rtl -name '*.v') sim/tb/tb_trace_mem.v sim/tb/sim_axi_slave.v
//   vvp sim/log/trace.vvp +MEM_LO_INIT=sim/tests/out/lrsc.hex +maxcyc=20000
//
// 参数：+MEM_LO_INIT=<hex> +MEM_HI_INIT=<hex> +maxcyc=<n> +sig_dump=<file>
//       +trace_pc=<hex>（可选：只打印该 PC 附近的 DREQ/DRSP，减少日志量）
//=============================================================================
`timescale 1ns/1ps
module tb_trace_mem;
  reg clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  wire [3:0]  arid;   wire [31:0] araddr; wire [3:0] arlen; wire [2:0] arsize;
  wire [1:0]  arburst, arlock; wire [3:0] arcache; wire [2:0] arprot;
  wire        arvalid, arready, rready;
  wire [3:0]  rid, bid, awid, wid;
  wire [31:0] rdata, awaddr, wdata;
  wire [1:0]  rresp, bresp;
  wire        rlast, rvalid, awvalid, awready, wvalid, wready, bvalid, bready;
  wire [3:0]  awlen, wstrb;
  wire [2:0]  awsize, awprot;
  wire [3:0]  awcache;
  wire        wlast;

  wire uart_we, vuart_we, exit_we, tohost_we, num_we;
  wire [7:0]  uart_wdata, vuart_wdata;
  wire [31:0] exit_wdata, tohost_wdata, num_val;

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

  sim_axi_slave #(.MEM_LO_INIT(""), .MEM_HI_INIT("")) u_slave (
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
  integer maxcyc = 20000;
  reg        resv_valid_p = 1'b0;
  reg [31:0] resv_addr_p  = 32'd0;
  reg [1023:0] mem_path;
  reg [31:0]   trace_pc = 32'hFFFF_FFFF;

  initial begin
    if (!$value$plusargs("maxcyc=%d", maxcyc)) maxcyc = 20000;
    if ($value$plusargs("trace_pc=%h", trace_pc)) ;
    if ($value$plusargs("MEM_LO_INIT=%s", mem_path)) begin
      $readmemh(mem_path, u_slave.mem_lo);
      $display("[trace] mem_lo <- %s", mem_path);
    end
    if ($value$plusargs("MEM_HI_INIT=%s", mem_path)) begin
      $readmemh(mem_path, u_slave.mem_hi);
      $display("[trace] mem_hi <- %s", mem_path);
    end
  end

  // UART 打印
  always @(posedge clk) if (rst_n && uart_we) $write("%c", uart_wdata);

  always @(posedge clk) begin
    cyc <= cyc + 1;
    if (cyc == 10) rst_n <= 1;

    if (dut.u_core.wb_retire && dut.u_core.wb_csr_op_q != 2'd0)
      $display("CSRW cyc=%0d pc=%h op=%0d addr=%h data=%h wen=%b", cyc, dut.u_core.wb_pc_q,
               dut.u_core.wb_csr_op_q, dut.u_core.wb_csr_addr_q, dut.u_core.wb_csr_wdata, dut.u_core.wb_csr_wen);
    if (dut.u_core.trap_take)
      $display("TRAP cyc=%0d pc=%h cause=%h tval=%h priv=%0d instr=%h", cyc, dut.u_core.wb_pc_q,
               dut.u_core.wb_excp_cause_q, dut.u_core.wb_excp_tval_q, dut.u_core.priv_q, dut.u_core.wb_instr_q);

    // 提交轨迹（含访存类型/地址，便于把"读回 0"定位到具体指令）
    if (dut.u_core.wb_retire)
      $display("COMMIT cyc=%0d pc=%h instr=%h rd=%0d wd=%h wen=%b",
               cyc, dut.u_core.wb_pc_q, dut.u_core.wb_instr_q, dut.u_core.wb_rd_q, dut.u_core.wb_wdata,
               dut.u_core.wb_wen, dut.u_core.wb_mem_data_q);

`ifdef RV32GC_RESV_TRACE
    // 每次 M_IDLE 入口（发起访存的第一拍）打印锁存意图
    if (rst_n && (cyc>=196 && cyc<=220))
      $display("STALL cyc=%0d memst=%0d adv=%b fetch_stall=%b mem_stall=%b mdu_hold=%b front_hold=%b load_use=%b csr_ord=%b mems_valid=%b mem_valid=%b ex_valid=%b id_valid=%b | mempc=%h memop=%0d",
               cyc, dut.u_core.memst_q, dut.u_core.advance_all, dut.u_core.fetch_stall, dut.u_core.mem_stall,
               dut.u_core.mdu_hold, dut.u_core.front_hold, dut.u_core.load_use, dut.u_core.csr_order_stall,
               dut.u_core.mem_needs_fsm, dut.u_core.mem_valid_q, dut.u_core.ex_valid_q, dut.u_core.id_valid_q,
               dut.u_core.mem_pc_q, dut.u_core.mem_mem_op_q);
    if (rst_n && dut.u_core.memst_q == 3'd0 && dut.u_core.mem_needs_fsm && dut.u_core.mem_valid_q)
      $display("MIDLE cyc=%0d mempc=%h memop=%0d we_will=%b addr=%h lr=%b sc=%b amo=%b resv=%b/%h",
               cyc, dut.u_core.mem_pc_q, dut.u_core.mem_mem_op_q,
               (dut.u_core.mem_mem_op_q == 3'd2), dut.u_core.mem_addr_q,
               dut.u_core.mem_is_lr, dut.u_core.mem_is_sc, dut.u_core.mem_is_amo,
               dut.u_core.resv_valid_q, dut.u_core.resv_addr_q);
`endif
`ifdef RV32GC_RESV_TRACE
    if (rst_n && dut.u_core.resv_valid_q && !resv_valid_p)
      $display("RESV_SET  cyc=%0d addr=%h | memst=%0d mempc=%h memop=%0d m_is_lr=%b m_is_sc=%b m_is_amo=%b",
               cyc, dut.u_core.resv_addr_q, dut.u_core.memst_q, dut.u_core.mem_pc_q,
               dut.u_core.mem_mem_op_q, dut.u_core.m_is_lr_q, dut.u_core.m_is_sc_q, dut.u_core.m_is_amo_q);
    if (rst_n && !dut.u_core.resv_valid_q && resv_valid_p)
      $display("RESV_CLR  cyc=%0d (was addr=%h) | memst=%0d mempc=%h memop=%0d m_we=%b",
               cyc, resv_addr_p, dut.u_core.memst_q, dut.u_core.mem_pc_q,
               dut.u_core.mem_mem_op_q, dut.u_core.m_we_q);
    resv_valid_p <= dut.u_core.resv_valid_q;
    resv_addr_p  <= dut.u_core.resv_addr_q;
`endif
`ifdef RV32GC_BUS_TRACE
    if (rst_n && cyc >= 195 && cyc <= 245)
      $display("BUS cyc=%0d rd_state=%0d wr_state=%0d take_data=%b take_write=%b take_if=%b d_req_valid=%b d_req_we=%b d_req_addr=%h d_req_ready=%b | awvalid=%b awready=%b wvalid=%b wready=%b bvalid=%b",
               cyc, dut.u_axi.rd_state, dut.u_axi.wr_state, dut.u_axi.take_data, dut.u_axi.take_write,
               dut.u_axi.take_if, dut.u_core.d_req_valid, dut.u_core.d_req_we, dut.u_core.d_req_addr,
               dut.u_core.d_req_ready, awvalid, awready, wvalid, wready, bvalid);
`endif
    // D 侧请求/响应：带 MEM 级 PC（发起该请求的指令）
    if (dut.u_core.d_req_valid && dut.u_core.d_req_ready)
      $display("DREQ cyc=%0d pc=%h we=%b addr=%h wdata=%h strb=%x", cyc,
               dut.u_core.mem_pc_q, dut.u_core.d_req_we, dut.u_core.d_req_addr,
               dut.u_core.d_req_wdata, dut.u_core.d_req_wstrb);
    if (dut.u_core.d_rsp_valid)
      $display("DRSP cyc=%0d pc=%h rdata=%h err=%b", cyc,
               dut.u_core.mem_pc_q, dut.u_core.d_rsp_rdata, dut.u_core.d_rsp_err);

    // 监视指定地址的每个写 beat（含字节使能）与读 beat
    if (rst_n && u_slave.wstate == 2'd1 && wvalid && wready &&
        u_slave.w_beat_addr >= 32'h00080000 && u_slave.w_beat_addr <= 32'h00080020)
      $display("MEMW cyc=%0d addr=%h data=%h strb=%x wa=%h wst=%0d", cyc,
               u_slave.w_beat_addr, wdata, wstrb, u_slave.awaddr_q, u_slave.wstate);
    if (rst_n && u_slave.rstate == 1'b1 && rvalid && rready &&
        u_slave.r_beat_addr >= 32'h00080000 && u_slave.r_beat_addr <= 32'h00080020)
      $display("MEMR cyc=%0d addr=%h data=%h ar=%h", cyc, u_slave.r_beat_addr, rdata, u_slave.araddr_q);

    // AXI 通道实际落地（写 beat / 读 beat）
    if (rst_n && u_slave.wstate == 2'd1 && wvalid && wready)
      $display("AXIWR cyc=%0d addr=%h data=%h strb=%x", cyc, u_slave.w_beat_addr, wdata, wstrb);
    if (rst_n && u_slave.rstate == 1'b1 && rvalid && rready)
      $display("AXIRD cyc=%0d addr=%h data=%h", cyc, u_slave.r_beat_addr, rdata);

    if (exit_we) begin
      $display("\n[trace] EXIT code=%0d @cyc=%0d", exit_wdata, cyc);
      $finish;
    end
    if (tohost_we) begin
      $display("\n[trace] TOHOST=%0d @cyc=%0d", tohost_wdata, cyc);
      $finish;
    end
    if (cyc > maxcyc) begin
      $display("\n[trace] 达到 maxcyc=%0d pc=%h", maxcyc, dut.u_core.pc_q);
      $finish;
    end
  end

  initial begin
    #400_000_000;
    $display("[trace] 硬超时");
    $finish;
  end
endmodule
