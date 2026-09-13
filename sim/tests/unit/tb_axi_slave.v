//=============================================================================
// tb_axi_slave.v —— sim_axi_slave 的独立单元自测（手写小型 AXI4 主设备模型）
//-----------------------------------------------------------------------------
// 覆盖：
//   ① 单拍写 0xDEADBEEF → 0x100，再读回比对
//   ② 8 beat INCR 突发写/读 0x200 起 32 字节，逐字 + 逐字节比对
//   ③ wstrb=4'b0011 只改低 2 字节
//   ④ 写 VIRTUAL_UART（0x1FAF_FF10）触发 vuart_we
//   ⑤ 写 tohost（0x8000_1000）触发 tohost_we 且 mem_hi[0x1000] 更新
//   ⑥ 未映射地址（0x4000_0000）读写均得 resp=2'b10（SLVERR），不挂死
//   ⑦ 附加：UART LSR=0x60、SIMU_FLAG=0xFFFF_FFFF、CONFREG NUM 读写、IO_SIMU 退出码、
//      UART THR 写、窄传输 lane 位置
//
// 运行：scripts/run_unit_axi.sh        （iverilog）
// 通过标准：打印 AXI_SLAVE_UNIT: PASS (N checks)
//=============================================================================
`timescale 1ns/1ps

module tb_axi_slave;

  //--------------------------------------------------------------------------
  // 时钟 / 复位 / 记分
  //--------------------------------------------------------------------------
  reg clk = 1'b0;
  always #5 clk = ~clk;              // 10 ns 周期

  reg rst_n = 1'b0;

  integer n_checks = 0;
  integer n_fails  = 0;

  task check_eq;
    input [8*40-1:0] name;
    input [31:0]     got;
    input [31:0]     exp;
    begin
      n_checks = n_checks + 1;
      if (got !== exp) begin
        n_fails = n_fails + 1;
        $display("  [FAIL] %0s: got=0x%08x exp=0x%08x", name, got, exp);
      end
    end
  endtask

  task check_byte;
    input [8*40-1:0] name;
    input [7:0]      got;
    input [7:0]      exp;
    begin
      n_checks = n_checks + 1;
      if (got !== exp) begin
        n_fails = n_fails + 1;
        $display("  [FAIL] %0s: got=0x%02x exp=0x%02x", name, got, exp);
      end
    end
  endtask

  //--------------------------------------------------------------------------
  // DUT：单从设备 AXI 模型（单元测试用缩小内存，加速仿真）
  //--------------------------------------------------------------------------
  reg  [3:0]  m_awid   = 4'd0;
  reg  [31:0] m_awaddr = 32'd0;
  reg  [3:0]  m_awlen  = 4'd0;
  reg  [2:0]  m_awsize = 3'd2;
  reg  [1:0]  m_awburst= 2'b01;
  reg         m_awvalid= 1'b0;
  reg  [3:0]  m_wid    = 4'd0;
  reg  [31:0] m_wdata  = 32'd0;
  reg  [3:0]  m_wstrb  = 4'hF;
  reg         m_wlast  = 1'b0;
  reg         m_wvalid = 1'b0;
  reg         m_bready = 1'b0;
  reg  [3:0]  m_arid   = 4'd0;
  reg  [31:0] m_araddr = 32'd0;
  reg  [3:0]  m_arlen  = 4'd0;
  reg  [2:0]  m_arsize = 3'd2;
  reg  [1:0]  m_arburst= 2'b01;
  reg         m_arvalid= 1'b0;
  reg         m_rready = 1'b0;

  wire [3:0]  s_bid, s_rid;
  wire        s_awready, s_wready, s_bvalid, s_arready, s_rvalid, s_rlast;
  wire [1:0]  s_bresp, s_rresp;
  wire [31:0] s_rdata;

  wire        uart_we, vuart_we, exit_we, tohost_we, num_we;
  wire [7:0]  uart_wdata, vuart_wdata;
  wire [31:0] exit_wdata, tohost_wdata, num_val;

  sim_axi_slave #(
    .MEM_LO_BYTES (32'h0004_0000),   // 256 KiB（单元测试足够）
    .MEM_HI_BYTES (32'h0000_4000),   // 16 KiB（含 tohost 0x1000）
    .MEM_LO_INIT  (""),
    .MEM_HI_INIT  ("")
  ) u_dut (
    .clk (clk), .rst_n (rst_n),
    .s_awid (m_awid),  .s_awaddr (m_awaddr), .s_awlen (m_awlen),
    .s_awsize (m_awsize), .s_awburst (m_awburst), .s_awvalid (m_awvalid),
    .s_awready (s_awready),
    .s_wid (m_wid), .s_wdata (m_wdata), .s_wstrb (m_wstrb),
    .s_wlast (m_wlast), .s_wvalid (m_wvalid), .s_wready (s_wready),
    .s_bid (s_bid), .s_bresp (s_bresp), .s_bvalid (s_bvalid), .s_bready (m_bready),
    .s_arid (m_arid), .s_araddr (m_araddr), .s_arlen (m_arlen),
    .s_arsize (m_arsize), .s_arburst (m_arburst), .s_arvalid (m_arvalid),
    .s_arready (s_arready),
    .s_rid (s_rid), .s_rdata (s_rdata), .s_rresp (s_rresp),
    .s_rlast (s_rlast), .s_rvalid (s_rvalid), .s_rready (m_rready),
    .uart_we (uart_we), .uart_wdata (uart_wdata),
    .vuart_we (vuart_we), .vuart_wdata (vuart_wdata),
    .exit_we (exit_we), .exit_wdata (exit_wdata),
    .tohost_we (tohost_we), .tohost_wdata (tohost_wdata),
    .num_val (num_val), .num_we (num_we)
  );

  //--------------------------------------------------------------------------
  // 握手监视（在 posedge 采样 valid&ready，避免 TB/DUT 的 NBA 竞争）
  //   *_hs 为寄存指示：为 1 表示“上一个 posedge 完成了一次握手”
  //--------------------------------------------------------------------------
  reg aw_hs, w_hs, b_hs, ar_hs;
  always @(posedge clk) begin
    aw_hs <= rst_n & m_awvalid & s_awready;
    w_hs  <= rst_n & m_wvalid  & s_wready;
    b_hs  <= rst_n & s_bvalid  & m_bready;
    ar_hs <= rst_n & m_arvalid & s_arready;
  end

  // 观测脉冲捕获
  reg        vuart_seen = 1'b0, uart_seen = 1'b0;
  reg        exit_seen  = 1'b0, tohost_seen = 1'b0, num_seen = 1'b0;
  reg [7:0]  vuart_byte = 8'h00, uart_byte = 8'h00;
  reg [31:0] exit_code  = 32'h0,  tohost_val = 32'h0;
  always @(posedge clk) if (rst_n) begin
    if (vuart_we)  begin vuart_seen  <= 1'b1; vuart_byte <= vuart_wdata; end
    if (uart_we)   begin uart_seen   <= 1'b1; uart_byte  <= uart_wdata;  end
    if (exit_we)   begin exit_seen   <= 1'b1; exit_code  <= exit_wdata;  end
    if (tohost_we) begin tohost_seen <= 1'b1; tohost_val <= tohost_wdata;end
    if (num_we)    num_seen <= 1'b1;
  end

  //--------------------------------------------------------------------------
  // 主设备模型：写/读任务（半周期驱动，posedge 采样；非流水，单笔在途）
  //--------------------------------------------------------------------------
  reg [31:0] wr_data [0:15];
  reg [3:0]  wr_strb [0:15];
  reg [31:0] rd_data [0:15];
  reg [1:0]  rd_resp [0:15];
  reg        rd_last [0:15];
  reg [31:0] b_resp, b_id;

  task axi_write;
    input [3:0]  id;
    input [31:0] addr;
    input [3:0]  len;
    input [2:0]  size;
    integer i;
    begin
      @(negedge clk);
      m_awid = id; m_awaddr = addr; m_awlen = len; m_awsize = size;
      m_awburst = 2'b01; m_awvalid = 1'b1;
      @(posedge clk); #1;
      while (!aw_hs) begin @(posedge clk); #1; end
      m_awvalid = 1'b0;
      for (i = 0; i <= {28'd0, len}; i = i + 1) begin
        @(negedge clk);
        m_wid = id; m_wdata = wr_data[i]; m_wstrb = wr_strb[i];
        m_wlast = (i == {28'd0, len}); m_wvalid = 1'b1;
        @(posedge clk); #1;
        while (!w_hs) begin @(posedge clk); #1; end
        m_wvalid = 1'b0;
      end
      @(negedge clk);
      m_bready = 1'b1;
      @(posedge clk); #1;
      while (!b_hs) begin @(posedge clk); #1; end
      b_resp = {30'd0, s_bresp};
      b_id   = {28'd0, s_bid};
      m_bready = 1'b0;
      @(negedge clk);
    end
  endtask

  task axi_read;
    input [3:0]  id;
    input [31:0] addr;
    input [3:0]  len;
    input [2:0]  size;
    integer i;
    begin
      @(negedge clk);
      m_arid = id; m_araddr = addr; m_arlen = len; m_arsize = size;
      m_arburst = 2'b01; m_arvalid = 1'b1;
      @(posedge clk); #1;
      while (!ar_hs) begin @(posedge clk); #1; end
      m_arvalid = 1'b0;
      m_rready = 1'b1;
      for (i = 0; i <= {28'd0, len}; i = i + 1) begin
        while (!s_rvalid) begin @(posedge clk); #1; end
        rd_data[i] = s_rdata;
        rd_resp[i] = s_rresp;
        rd_last[i] = s_rlast;
        @(posedge clk); #1;                // 本 beat 握手完成
      end
      m_rready = 1'b0;
      @(negedge clk);
    end
  endtask

  // 便捷封装：单拍写 / 单拍读
  task wr32;                              // 全字节使能的单拍字写
    input [3:0]  id;
    input [31:0] addr;
    input [31:0] data;
    begin
      wr_data[0] = data; wr_strb[0] = 4'hF;
      axi_write(id, addr, 4'd0, 3'd2);
    end
  endtask

  task wr8;                               // 单字节写（lane 由地址决定）
    input [3:0]  id;
    input [31:0] addr;
    input [7:0]  data;
    begin
      wr_data[0] = {24'h0, data};
      wr_strb[0] = (4'h1 << addr[1:0]);
      axi_write(id, addr, 4'd0, 3'd0);
    end
  endtask

  reg [31:0] rd32_v;
  task rd32;                              // 单拍字读，结果放 rd32_v
    input [3:0]  id;
    input [31:0] addr;
    begin
      axi_read(id, addr, 4'd0, 3'd2);
      rd32_v = rd_data[0];
    end
  endtask

  //--------------------------------------------------------------------------
  // 测试序列
  //--------------------------------------------------------------------------
  integer i, k;
  reg [7:0]  expect_byte;

  initial begin
    for (i = 0; i < 16; i = i + 1) begin
      wr_data[i] = 32'h0; wr_strb[i] = 4'hF;
      rd_data[i] = 32'h0; rd_resp[i] = 2'b00; rd_last[i] = 1'b0;
    end

    // 复位：前 5 拍为 0
    rst_n = 1'b0;
    repeat (5) @(posedge clk);
    @(negedge clk);
    rst_n = 1'b1;
    repeat (2) @(negedge clk);

    $display("=== AXI slave unit test ===");
    $display("-- T1: single write/read 0xDEADBEEF @0x100");
    wr32(4'd1, 32'h0000_0100, 32'hDEAD_BEEF);
    check_eq("T1.bresp",  b_resp, 32'h0);
    check_eq("T1.bid",    b_id,   32'h1);
    rd32(4'd1, 32'h0000_0100);
    check_eq("T1.rdata",  rd32_v, 32'hDEAD_BEEF);
    check_eq("T1.rresp",  {30'd0, rd_resp[0]}, 32'h0);
    check_eq("T1.rlast",  {31'd0, rd_last[0]}, 32'h1);
    check_eq("T1.rid",    {28'd0, s_rid}, 32'h1);

    $display("-- T2: 8-beat INCR burst write/read @0x200 (32 B)");
    for (i = 0; i < 8; i = i + 1) begin
      wr_data[i] = 32'hA5A5_0000 + i * 32'h0001_0101;
      wr_strb[i] = 4'hF;
    end
    axi_write(4'd2, 32'h0000_0200, 4'd7, 3'd2);
    check_eq("T2.bresp", b_resp, 32'h0);
    axi_read(4'd2, 32'h0000_0200, 4'd7, 3'd2);
    for (i = 0; i < 8; i = i + 1) begin
      check_eq("T2.word", rd_data[i], wr_data[i]);
      check_eq("T2.last", {31'd0, rd_last[i]}, (i == 7) ? 32'h1 : 32'h0);
      for (k = 0; k < 4; k = k + 1) begin
        expect_byte = wr_data[i][k*8 +: 8];
        check_byte("T2.byte", u_dut.mem_lo[32'h200 + 4*i + k], expect_byte);
      end
    end

    $display("-- T3: wstrb=4'b0011 only touches low 2 bytes");
    wr32(4'd3, 32'h0000_0300, 32'hFFFF_FFFF);
    wr_data[0] = 32'hAABB_CCDD; wr_strb[0] = 4'b0011;
    axi_write(4'd3, 32'h0000_0300, 4'd0, 3'd2);
    check_eq("T3.bresp", b_resp, 32'h0);
    rd32(4'd3, 32'h0000_0300);
    check_eq("T3.mixed", rd32_v, 32'hFFFF_CCDD);

    $display("-- T4: VIRTUAL_UART write triggers vuart_we");
    vuart_seen = 1'b0;
    wr8(4'd3, 32'h1FAF_FF10, 8'h48);          // 'H'
    check_eq("T4.vuart_we",   {31'd0, vuart_seen}, 32'h1);
    check_eq("T4.vuart_data", {24'd0, vuart_byte}, 32'h48);
    check_eq("T4.bresp",      b_resp, 32'h0);

    $display("-- T5: tohost write triggers tohost_we and updates mem_hi[0x1000]");
    tohost_seen = 1'b0; tohost_val = 32'h0;
    wr32(4'd3, 32'h8000_1000, 32'h0000_0001);
    check_eq("T5.tohost_we",   {31'd0, tohost_seen}, 32'h1);
    check_eq("T5.tohost_data", tohost_val, 32'h1);
    check_eq("T5.bresp",       b_resp, 32'h0);
`ifndef VERILATOR
    // 小端：地址 0x1000 的字节是 32 位字的 bit[7:0]
    check_eq("T5.mem_hi[0x1000]",
             {u_dut.mem_hi[32'h1003], u_dut.mem_hi[32'h1002],
              u_dut.mem_hi[32'h1001], u_dut.mem_hi[32'h1000]}, 32'h1);
`endif
    rd32(4'd3, 32'h8000_1000);
    check_eq("T5.readback", rd32_v, 32'h1);

    $display("-- T6: unmapped address returns SLVERR (2'b10)");
    axi_read(4'd4, 32'h4000_0000, 4'd0, 3'd2);
    check_eq("T6.rresp", {30'd0, rd_resp[0]}, 32'h2);
    wr32(4'd4, 32'h4000_0000, 32'h1234_5678);
    check_eq("T6.bresp", b_resp, 32'h2);

    $display("-- T7: extra (UART LSR, SIMU_FLAG, NUM, IO_SIMU, THR, narrow lane)");
    rd32(4'd5, 32'h1FE0_01E4);                 // LSR 位于字内 [15:8]
    check_eq("T7.lsr_word", rd32_v, 32'h0000_6000);
    axi_read(4'd5, 32'h1FE0_01E5, 4'd0, 3'd0); // 窄读：字节在 lane1
    check_eq("T7.lsr_lane1", {24'd0, rd_data[0][15:8]}, 32'h60);
    check_eq("T7.lsr_lane0", {24'd0, rd_data[0][7:0]},  32'h0);
    rd32(4'd5, 32'h1FAF_FF20);                 // SIMU_FLAG
    check_eq("T7.simu_flag", rd32_v, 32'hFFFF_FFFF);
    num_seen = 1'b0;
    wr32(4'd6, 32'h1FAF_F050, 32'h0000_1234);  // CONFREG 仿真 NUM（+0xF050）
    check_eq("T7.num_we",   {31'd0, num_seen}, 32'h1);
    check_eq("T7.num_val",  num_val, 32'h1234);
    rd32(4'd6, 32'h1FD0_F010);                 // CONFREG FPGA NUM 读回同一值
    check_eq("T7.num_rd",   rd32_v, 32'h1234);
    uart_seen = 1'b0;
    wr8(4'd6, 32'h1FE0_01E0, 8'h55);           // UART THR
    check_eq("T7.uart_we",   {31'd0, uart_seen}, 32'h1);
    check_eq("T7.uart_data", {24'd0, uart_byte}, 32'h55);
    exit_seen = 1'b0;
    wr32(4'd6, 32'h1FAF_FF00, 32'h0000_0000);  // IO_SIMU 退出码
    check_eq("T7.exit_we",   {31'd0, exit_seen}, 32'h1);
    check_eq("T7.exit_code", exit_code, 32'h0);
    // 半字写：0x0000_6000 处写 0xBEEF，只改低 2 字节
    wr32(4'd7, 32'h0000_0400, 32'h1111_1111);
    wr_data[0] = 32'h0000_BEEF; wr_strb[0] = 4'b0011;
    axi_write(4'd7, 32'h0000_0400, 4'd0, 3'd1);   // size=2B
    rd32(4'd7, 32'h0000_0400);
    check_eq("T7.half_word", rd32_v, 32'h1111_BEEF);

    //--------------------------------------------------------------------------
    $display("-----------------------------------------------------------------");
    if (n_fails == 0)
      $display("AXI_SLAVE_UNIT: PASS (%0d checks)", n_checks);
    else begin
      $display("AXI_SLAVE_UNIT: FAIL (%0d checks, %0d fails)", n_checks, n_fails);
      $fatal;
    end
    $finish;
  end

endmodule
