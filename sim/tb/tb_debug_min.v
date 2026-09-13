//=============================================================================
// tb_debug_min.v —— 极简调试 TB：直接观察核内流水线状态（用于定位停摆）
// 用法：iverilog -g2005 -I rtl/pkg -s tb_debug_min -o /tmp/dbg.vvp rtl/**/*.v sim/tb/sim_axi_slave.v sim/tb/tb_debug_min.v
//       vvp /tmp/dbg.vvp +MEM_LO_INIT=sim/tests/out/hello.hex
//=============================================================================
`timescale 1ns/1ps
module tb_debug_min;
  reg clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  wire [3:0]  arid;   wire [31:0] araddr; wire [3:0] arlen, arsize_unused;
  wire [2:0]  arsize; wire [1:0]  arburst, arlock; wire [3:0] arcache; wire [2:0] arprot;
  wire        arvalid, arready, rready;
  wire [3:0]  rid, wid_unused, bid_unused, awid, wstrb_unused_dummy;
  wire [31:0] rdata, awaddr, wdata, wdata_unused;
  wire [1:0]  rresp, bresp, awburst_unused, awlock_unused;
  wire        rlast, rvalid, awvalid, awready, wvalid, wready, bvalid, bready;
  wire [3:0]  awlen, wstrb;
  wire [2:0]  awsize, awprot;
  wire [3:0]  awcache;
  wire [3:0]  bid, wid;

  wire uart_we, vuart_we, exit_we, tohost_we, num_we;
  wire [7:0]  uart_wdata, vuart_wdata;
  wire [31:0] exit_wdata, tohost_wdata, num_val;

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
  wire ws_valid; wire [31:0] dbg_pc; wire [3:0] dbg_wen4; wire [4:0] dbg_wnum; wire [31:0] dbg_wdata;
  wire wlast;

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
  reg [1023:0] mem_path;
  initial begin
    if (!$value$plusargs("MEM_LO_INIT=%s", mem_path)) mem_path = "sim/tests/out/hello.hex";
    $readmemh(mem_path, u_slave.mem_lo);
    $display("[dbg] mem_lo <- %s", mem_path);
    if ($value$plusargs("MEM_HI_INIT=%s", mem_path)) begin
      $readmemh(mem_path, u_slave.mem_hi);
      $display("[dbg] mem_hi <- %s", mem_path);
    end
  end

  always @(posedge clk) begin
    cyc <= cyc + 1;
    if (cyc == 10) rst_n <= 1;
    if (dut.u_core.wb_retire && dut.u_core.wb_csr_op_q != 2'd0)
      $display("CSRW cyc=%0d pc=%h op=%0d addr=%h data=%h wen=%b", cyc, dut.u_core.wb_pc_q,
               dut.u_core.wb_csr_op_q, dut.u_core.wb_csr_addr_q, dut.u_core.wb_csr_wdata, dut.u_core.wb_csr_wen);
    if (dut.u_core.id_valid_q && dut.u_core.c_csr_op != 2'd0)
      $display("CSRID cyc=%0d pc=%h op=%0d addr=%h rs1=%0d", cyc, dut.u_core.id_pc_q,
               dut.u_core.c_csr_op, dut.u_core.dec_csr_addr, dut.u_core.dec_rs1);
    if (dut.u_core.wb_retire) begin
      $display("C%0d pc=%h instr=%h rd=%0d wd=%h wen=%b", cyc, dut.u_core.wb_pc_q,
               dut.u_core.wb_instr_q, dut.u_core.wb_rd_q, dut.u_core.wb_wdata, dut.u_core.wb_wen);
    end
    if (cyc > 4000000) begin $display("[dbg] 结束"); $finish; end
    if (cyc > 100000000) begin
      $display("cyc=%0d pc=%h ifrdy=%b line=%b | f:busy=%b reqv=%b reqa=%h tag=%h | axird=%0d | stall=%b memstall=%b memst=%0d memop=%0d memaddr=%h | commit=%b wbv=%b memv=%b redir=%b",
        cyc, dut.u_core.pc_q, dut.u_core.if_ready, dut.u_core.line_valid,
        dut.u_core.u_ifetch.busy_q, dut.u_core.u_ifetch.if_req_valid,
        dut.u_core.u_ifetch.if_req_addr, dut.u_core.u_ifetch.line_tag_q,
        dut.u_axi.rd_state,
        dut.u_core.stall, dut.u_core.mem_stall, dut.u_core.memst_q,
        dut.u_core.mem_mem_op_q, dut.u_core.mem_addr_q,
        dut.u_core.wb_retire, dut.u_core.wb_valid_q, dut.u_core.mem_valid_q, dut.u_core.redirect_valid);
    end
    if (cyc > 2000) begin $display("[dbg] 2000 拍结束"); $finish; end
  end

  initial begin
    #20_000_000; $display("[dbg] 超时"); $finish;
  end
endmodule
