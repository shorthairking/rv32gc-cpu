//=============================================================================
// tb_axi_slave_rw.v —— 只测 sim_axi_slave 的"写后读可见性"（不接核）
//
// 目的：判定"同一地址先写后读，读回旧值"是**内存模型缺陷**还是核/测试台的用法问题。
// 时序：AW/W 各一拍写 0xAAAAAAAA，等 GAP 拍，再 AR/R 读回同一地址；打印每一步的
//       mem_lo[] 字节与 s_rdata，便于逐拍对照。
//
// 用法：
//   iverilog -g2005 -s tb_axi_slave_rw -o sim/log/rw.vvp sim/tb/sim_axi_slave.v sim/tb/tb_axi_slave_rw.v
//   vvp sim/log/rw.vvp +ADDR=80000000 +GAP=3 +D0=AAAAAAAA
//=============================================================================
`timescale 1ns/1ps
module tb_axi_slave_rw;

  reg clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  integer cyc = 0;

  // AXI 从设备端口
  reg  [3:0]  s_awid   = 4'd0;
  reg  [31:0] s_awaddr = 32'd0;
  reg  [3:0]  s_awlen  = 4'd0;
  reg  [2:0]  s_awsize = 3'd2;
  reg  [1:0]  s_awburst= 2'd1;
  reg         s_awvalid= 1'b0;
  wire        s_awready;
  reg  [3:0]  s_wid    = 4'd0;
  reg  [31:0] s_wdata  = 32'd0;
  reg  [3:0]  s_wstrb  = 4'hF;
  reg         s_wlast  = 1'b1;
  reg         s_wvalid = 1'b0;
  wire        s_wready;
  wire [3:0]  s_bid;
  wire [1:0]  s_bresp;
  wire        s_bvalid;
  reg         s_bready = 1'b1;
  reg  [3:0]  s_arid   = 4'd0;
  reg  [31:0] s_araddr = 32'd0;
  reg  [3:0]  s_arlen  = 4'd0;
  reg  [2:0]  s_arsize = 3'd2;
  reg  [1:0]  s_arburst= 2'd1;
  reg         s_arvalid= 1'b0;
  wire        s_arready;
  wire [3:0]  s_rid;
  wire [31:0] s_rdata;
  wire [1:0]  s_rresp;
  wire        s_rlast;
  wire        s_rvalid;
  reg         s_rready = 1'b1;

  wire uart_we, vuart_we, exit_we, tohost_we, num_we;
  wire [7:0] uart_wdata, vuart_wdata;
  wire [31:0] exit_wdata, tohost_wdata, num_val;

  sim_axi_slave #(.MEM_LO_INIT(""), .MEM_HI_INIT("")) u_slave (
    .clk(clk), .rst_n(rst_n),
    .s_awid(s_awid), .s_awaddr(s_awaddr), .s_awlen(s_awlen), .s_awsize(s_awsize), .s_awburst(s_awburst),
    .s_awvalid(s_awvalid), .s_awready(s_awready),
    .s_wid(s_wid), .s_wdata(s_wdata), .s_wstrb(s_wstrb), .s_wlast(s_wlast),
    .s_wvalid(s_wvalid), .s_wready(s_wready),
    .s_bid(s_bid), .s_bresp(s_bresp), .s_bvalid(s_bvalid), .s_bready(s_bready),
    .s_arid(s_arid), .s_araddr(s_araddr), .s_arlen(s_arlen), .s_arsize(s_arsize), .s_arburst(s_arburst),
    .s_arvalid(s_arvalid), .s_arready(s_arready),
    .s_rid(s_rid), .s_rdata(s_rdata), .s_rresp(s_rresp), .s_rlast(s_rlast), .s_rvalid(s_rvalid), .s_rready(s_rready),
    .uart_we(uart_we), .uart_wdata(uart_wdata),
    .vuart_we(vuart_we), .vuart_wdata(vuart_wdata),
    .exit_we(exit_we), .exit_wdata(exit_wdata),
    .tohost_we(tohost_we), .tohost_wdata(tohost_wdata),
    .num_val(num_val), .num_we(num_we)
  );

  integer gap = 3;
  reg concurrent = 1'b0;
  reg [31:0] addr = 32'h80000000;
  reg [31:0] d0   = 32'hAAAAAAAA;

  task show(input [8*16-1:0] tag);
    integer i;
    begin
      // 只对低 1MiB 窗口（mem_hi）打印字节，避免索引越界
      if (addr >= 32'h80000000 && addr < 32'h80100000)
        $display("%s cyc=%0d addr=%h mem_hi[%h]=%02x%02x%02x%02x rvalid=%b rdata=%08x wstate=%0d rstate=%b",
                 tag, cyc, addr, addr - 32'h80000000,
                 u_slave.mem_hi[addr-32'h80000000+3], u_slave.mem_hi[addr-32'h80000000+2],
                 u_slave.mem_hi[addr-32'h80000000+1], u_slave.mem_hi[addr-32'h80000000],
                 s_rvalid, s_rdata, u_slave.wstate, u_slave.rstate);
      else
        $display("%s cyc=%0d addr=%h rvalid=%b rdata=%08x wstate=%0d rstate=%b",
                 tag, cyc, addr, s_rvalid, s_rdata, u_slave.wstate, u_slave.rstate);
    end
  endtask

  initial begin
    if (!$value$plusargs("ADDR=%h", addr)) addr = 32'h80000000;
    if (!$value$plusargs("GAP=%d", gap))   gap = 3;
    if (!$value$plusargs("D0=%h", d0))     d0 = 32'hAAAAAAAA;
    concurrent = $test$plusargs("CONCURRENT");
    $display("[rw] addr=%h gap=%0d d0=%08x", addr, gap, d0);
  end

  always @(posedge clk) cyc <= cyc + 1;

  initial begin : stim
    rst_n = 0;
    repeat (5) @(posedge clk);
    rst_n = 1;
    @(posedge clk);

    // ---- 写 ----
    s_awaddr = addr; s_awvalid = 1'b1;
    s_wdata  = d0;   s_wstrb = 4'hF; s_wvalid = 1'b1;
    @(posedge clk);
    if (concurrent) begin
      // 与写同时发读请求（复现核的"写请求与读请求同拍/紧邻"场景）
      s_araddr = addr; s_arvalid = 1'b1;
    end
    while (!(s_awready && s_awvalid)) @(posedge clk);
    s_awvalid = 1'b0;
    while (!(s_wready && s_wvalid)) @(posedge clk);
    s_wvalid = 1'b0;
    while (!s_bvalid) @(posedge clk);
    @(posedge clk);
    show("WRITE-DONE");

    repeat (gap) @(posedge clk);
    show("AFTER-GAP ");

    // ---- 读 ----
    s_araddr = addr; s_arvalid = 1'b1;
    while (!s_arready) @(posedge clk);
    @(posedge clk);
    s_arvalid = 1'b0;
    while (!s_rvalid) @(posedge clk);
    show("READ-BEAT ");
    @(posedge clk);

    if (s_rdata !== d0) begin
      $display("[rw] FAIL: 读回 %08x，期望 %08x（写后读不可见）", s_rdata, d0);
    end else begin
      $display("[rw] PASS: 写后读可见（%08x）", s_rdata);
    end
    $finish;
  end

  initial begin
    #100000;
    $display("[rw] 超时");
    $finish;
  end
endmodule
