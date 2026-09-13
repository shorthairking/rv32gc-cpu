//=============================================================================
// tb_icache.v —— L1 指令 Cache（rtl/frontend/rv32_icache.v）单元/定向测试
//-----------------------------------------------------------------------------
// 覆盖（每条对应一处 RTL 设计决定，出处见 rv32_icache.v 头部注释）：
//   C1 缺失→AXI 整行读→填充→返回整行数据（数据与内存逐字节一致）
//   C2 同址再访问 → **命中**（1 拍返回），且不产生新的 AXI 读
//   C3 D16② XIP 绕 Cache：地址落在 SPI-XIP 窗口（0x1C00_0000 / 别名 0x1FE8_0000）
//        · 永不命中（两次访问都是 miss，每次都发总线读）
//        · **永不分配**（dbg_alloc_wen 在整个 XIP 事务期间恒 0）
//   C4 轮转（RR）替换：同一组第 5 条不同标记行必然挤掉第 1 条；被挤掉的再访问 miss，
//      留存的仍 hit
//   C5 `fence.i` 整表失效（invalidate 脉冲）后，原本命中的行必须 miss
//   C6 `fence.i` 打断**在途填充**：该笔 AXI 读的数据被丢弃（不填充），同一地址**重新发起**
//      AXI 读；填充与交付都发生在第二次读（保证不把 fence.i 之前的旧指令放进 Cache）
//   C7 ENABLE=0 直通：不命中、不分配，但仍正确返回数据（安全阀基线等价性）
//
// 结构：rv32_icache ←→ rv32_axi_master ←→ sim_axi_slave（与 core_top 同款接线），
//   TB 直接驱动 icache 的请求/响应握手，并对 Cache 内部状态做**层次观测**
//   （perf_access/hit/miss、dbg_alloc_*、mem_taken_q）——只观测，不改功能。
//
// 运行：scripts/run_unit_icache.sh（打印 ICACHE_UNIT: PASS (N checks)）
//=============================================================================
`timescale 1ns/1ps

module tb_icache;

  localparam [31:0] XIP_BASE  = 32'h1C00_0000;
  localparam [31:0] XIP_ALIAS = 32'h1FE8_0000;

  integer checks = 0;
  integer errors = 0;

  task ck;
    input            cond;
    input [8*160-1:0] name;
    begin
      checks = checks + 1;
      if (!cond) begin
        errors = errors + 1;
        $display("  [FAIL] %0s", name);
      end
    end
  endtask

  //--------------------------------------------------------------------------
  // 时钟 / 复位
  //--------------------------------------------------------------------------
  reg clk = 1'b0;
  always #5 clk = ~clk;
  reg rst_n = 1'b0;

  //--------------------------------------------------------------------------
  // 被验证对象（ENABLE=1）+ AXI 通路
  //--------------------------------------------------------------------------
  reg          req_valid = 1'b0;
  reg  [31:0]  req_addr  = 32'd0;
  reg          req_xip   = 1'b0;
  wire         req_ready;
  wire         rsp_valid;
  wire [255:0] rsp_data;
  wire         rsp_err;
  reg          rsp_ready = 1'b1;
  reg          invalidate = 1'b0;

  wire         axi_req_valid, axi_req_ready, axi_rsp_valid, axi_rsp_err, axi_rsp_ready;
  wire [31:0]  axi_req_addr;
  wire [255:0] axi_rsp_data;
  wire         alloc_wen;
  wire [31:0]  alloc_addr;
  wire         dbg_hit;

  rv32_icache #(.ENABLE(1)) u_ic (
    .clk(clk), .rst_n(rst_n), .invalidate(invalidate),
    .req_valid(req_valid), .req_addr(req_addr), .req_xip(req_xip), .req_ready(req_ready),
    .rsp_valid(rsp_valid), .rsp_data(rsp_data), .rsp_err(rsp_err), .rsp_ready(rsp_ready),
    .axi_req_valid(axi_req_valid), .axi_req_addr(axi_req_addr), .axi_req_ready(axi_req_ready),
    .axi_rsp_valid(axi_rsp_valid), .axi_rsp_data(axi_rsp_data), .axi_rsp_err(axi_rsp_err),
    .axi_rsp_ready(axi_rsp_ready),
    .dbg_alloc_wen(alloc_wen), .dbg_alloc_addr(alloc_addr),
    .dbg_hit(dbg_hit), .dbg_hit_way(), .dbg_set(),
    .perf_access(), .perf_hit(), .perf_miss()
  );

  wire [3:0]  arid, rid, awid, bid, wid;
  wire [31:0] araddr, awaddr, rdata, wdata;
  wire [3:0]  arlen, awlen, wstrb;
  wire [2:0]  arsize, awsize, arprot, awprot;
  wire [1:0]  arburst, awburst, arlock, awlock;
  wire [3:0]  arcache, awcache;
  wire        arvalid, arready, rvalid, rready, rlast, wlast;
  wire        awvalid, awready, wvalid, wready, bvalid, bready;
  wire [1:0]  rresp, bresp;

  rv32_axi_master u_axi (
    .clk(clk), .rst_n(rst_n),
    .if_req_valid(axi_req_valid), .if_req_addr(axi_req_addr), .if_req_ready(axi_req_ready),
    .if_rsp_valid(axi_rsp_valid), .if_rsp_data(axi_rsp_data),
    .if_rsp_err(axi_rsp_err), .if_rsp_ready(axi_rsp_ready),
    .d_req_valid(1'b0), .d_req_we(1'b0), .d_req_addr(32'd0), .d_req_wdata(32'd0),
    .d_req_wstrb(4'd0), .d_req_ready(),
    .d_rsp_valid(), .d_rsp_rdata(), .d_rsp_err(), .d_rsp_ready(1'b1),
    .arid(arid), .araddr(araddr), .arlen(arlen), .arsize(arsize), .arburst(arburst),
    .arlock(arlock), .arcache(arcache), .arprot(arprot), .arvalid(arvalid), .arready(arready),
    .rid(rid), .rdata(rdata), .rresp(rresp), .rlast(rlast), .rvalid(rvalid), .rready(rready),
    .awid(awid), .awaddr(awaddr), .awlen(awlen), .awsize(awsize), .awburst(awburst),
    .awlock(awlock), .awcache(awcache), .awprot(awprot), .awvalid(awvalid), .awready(awready),
    .wid(wid), .wdata(wdata), .wstrb(wstrb), .wlast(wlast), .wvalid(wvalid), .wready(wready),
    .bid(bid), .bresp(bresp), .bvalid(bvalid), .bready(bready)
  );

  wire uart_we, vuart_we, exit_we, tohost_we, num_we;
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
    .uart_we(uart_we), .uart_wdata(uart_wdata), .vuart_we(vuart_we), .vuart_wdata(vuart_wdata),
    .exit_we(exit_we), .exit_wdata(exit_wdata), .tohost_we(tohost_we), .tohost_wdata(tohost_wdata),
    .num_val(num_val), .num_we(num_we)
  );

  //--------------------------------------------------------------------------
  // 观测计数器（层次引用 Cache 内部状态：只看不改）
  //--------------------------------------------------------------------------
  integer n_axi_req   = 0;    // icache→AXI 请求被主设备接受的笔数
  integer n_alloc     = 0;    // 阵列分配笔数
  integer n_xip_alloc = 0;    // 分配地址落在 XIP 窗口的笔数（必须恒 0）
  always @(posedge clk) if (rst_n) begin
    if (axi_req_valid && axi_req_ready) n_axi_req <= n_axi_req + 1;
    if (alloc_wen) begin
      n_alloc <= n_alloc + 1;
      if (((alloc_addr & 32'hFFF0_0000) == XIP_BASE) ||
          ((alloc_addr & 32'hFFFF_0000) == XIP_ALIAS)) n_xip_alloc <= n_xip_alloc + 1;
    end
  end

  //--------------------------------------------------------------------------
  // 工具
  //--------------------------------------------------------------------------
  function [7:0] pat_byte;
    input [7:0] pat;
    input [4:0] off;
    begin pat_byte = pat ^ {3'd0, off}; end
  endfunction

  task mem_pat;                     // 把 [addr, addr+32) 填成 pat ^ 行内偏移
    input [31:0] addr;
    input [7:0]  pat;
    integer i;
    begin
      for (i = 0; i < 32; i = i + 1)
        u_slave.mem_lo[addr + i] = pat ^ (i[7:0]);
    end
  endtask

  task check_line;
    input [255:0] d;
    input [7:0]   pat;
    input [8*160-1:0] name;
    integer j;
    reg ok;
    begin
      ok = 1'b1;
      for (j = 0; j < 32; j = j + 1)
        if (d[8*j +: 8] !== pat_byte(pat, j[4:0])) ok = 1'b0;
      ck(ok, name);
    end
  endtask

  // 发起一次行请求并等响应；was_hit = 由 perf 计数器前后差判定
  task do_req;
    input  [31:0]  a;
    input          xip;
    output [255:0] d;
    output         was_hit;
    reg [31:0] h0, m0;
    integer guard;
    begin
      h0 = u_ic.perf_hit;  m0 = u_ic.perf_miss;
      @(negedge clk);
      req_addr = a; req_xip = xip; req_valid = 1'b1;
      #1;                              // 握手同拍：本拍 req_valid 有效，req_ready 应立即为 1
      if (!req_ready) begin
        errors = errors + 1; checks = checks + 1;
        $display("  [FAIL] req_ready=0（Cache 不在 S_IDLE）");
      end
      @(posedge clk); #1;              // 该沿被接受
      @(negedge clk); req_valid = 1'b0;
      guard = 0;
      while (!rsp_valid) begin
        @(posedge clk); #1;
        guard = guard + 1;
        if (guard > 200) begin
          errors = errors + 1; checks = checks + 1;
          $display("  [FAIL] 请求 0x%08x 等响应超时（200 拍）", a);
          disable do_req;
        end
      end
      d = rsp_data;
      @(posedge clk); #1;                       // rsp_ready=1 ⇒ 响应被取走
      was_hit = (u_ic.perf_hit != h0) && (u_ic.perf_miss == m0);
    end
  endtask

  //--------------------------------------------------------------------------
  // 激励
  //--------------------------------------------------------------------------
  reg [255:0] d;
  reg         hit;
  integer     rq0, al0;
  integer     guard;

  initial begin
    // 内存图案：行内字节 = pat ^ 行内偏移（与地址无关 ⇒ 便于逐字节比对）
    mem_pat(32'h0000_0000, 8'h11);
    mem_pat(32'h0000_2000, 8'h22);
    mem_pat(32'h0000_4000, 8'h33);
    mem_pat(32'h0000_6000, 8'h44);
    mem_pat(32'h0000_8000, 8'h55);
    mem_pat(32'h0001_0000, 8'h66);   // C6 用
    mem_pat(XIP_BASE,      8'h77);   // XIP 窗口（平台模型里也是可读区域）

    rst_n = 1'b0;
    repeat (8) @(posedge clk);
    @(negedge clk); rst_n = 1'b1;
    repeat (2) @(posedge clk);

    $display("=== tb_icache: L1I 定向/单元测试 ===");

    // ------------------------------------------------------------- C1/C2
    do_req(32'h0000_0000, 1'b0, d, hit);
    ck(!hit, "C1a 冷 Cache 首次访问必须 miss");
    check_line(d, 8'h11, "C1b 缺失后返回的整行数据与内存一致");
    rq0 = n_axi_req;
    do_req(32'h0000_0000, 1'b0, d, hit);
    ck(hit, "C2a 同址再访问必须命中");
    check_line(d, 8'h11, "C2b 命中返回的数据正确");
    ck(n_axi_req == rq0, "C2c 命中不得产生新的 AXI 读");

    // ------------------------------------------------------------- C3 XIP
    rq0 = n_axi_req; al0 = n_alloc;
    do_req(XIP_BASE, 1'b1, d, hit);
    ck(!hit, "C3a XIP 首次访问不得命中");
    do_req(XIP_BASE, 1'b1, d, hit);
    ck(!hit, "C3b XIP 第二次访问仍不得命中（每拍都走总线）");
    ck(n_axi_req == rq0 + 2, "C3c XIP 每次访问都发总线读");
    ck(n_alloc == al0,       "C3d XIP 行不得写入 Cache 阵列");
    do_req(XIP_ALIAS, 1'b1, d, hit);
    do_req(XIP_ALIAS, 1'b1, d, hit);
    ck(!hit, "C3e XIP 别名窗口（0x1FE8_0000）不得命中");
    // 即使 req_xip 没置（模拟判定点漏接），仅凭地址判定也必须拦住
    do_req(XIP_BASE, 1'b0, d, hit);
    do_req(XIP_BASE, 1'b0, d, hit);
    ck(!hit, "C3f 仅凭地址判定也不得命中 XIP 窗口");
    ck(n_xip_alloc == 0, "C3g 全程不得有任何 XIP 窗口的分配");

    // ------------------------------------------------------------- C4 RR
    do_req(32'h0000_2000, 1'b0, d, hit); ck(!hit, "C4a 填 way1：miss");
    do_req(32'h0000_4000, 1'b0, d, hit); ck(!hit, "C4b 填 way2：miss");
    do_req(32'h0000_6000, 1'b0, d, hit); ck(!hit, "C4c 填 way3：miss");
    do_req(32'h0000_8000, 1'b0, d, hit); ck(!hit, "C4d 同组第 5 行：miss（RR 挤掉 way0）");
    do_req(32'h0000_8000, 1'b0, d, hit); ck(hit,  "C4e 新近的 way0 行：hit");
    // RR 指针此时 = 1 ⇒ 下一次填充（C4f）落到 way1，挤掉 0x2000
    do_req(32'h0000_0000, 1'b0, d, hit); ck(!hit, "C4f 被 RR 挤掉的最老行(way0)：miss");
    do_req(32'h0000_4000, 1'b0, d, hit); ck(hit,  "C4g 轮转未轮到 way2：仍 hit");
    do_req(32'h0000_6000, 1'b0, d, hit); ck(hit,  "C4h 轮转未轮到 way3：仍 hit");
    do_req(32'h0000_2000, 1'b0, d, hit); ck(!hit, "C4i way1 已在 C4f 填充时被轮转挤掉：miss");

    // ------------------------------------------------------------- C5 失效
    do_req(32'h0000_8000, 1'b0, d, hit); ck(hit, "C5a 失效前该行命中（前置条件）");
    @(negedge clk); invalidate = 1'b1;
    @(negedge clk); invalidate = 1'b0;
    do_req(32'h0000_8000, 1'b0, d, hit);
    ck(!hit, "C5b fence.i 失效后该行必须 miss");
    check_line(d, 8'h55, "C5c 失效后重新填充的数据正确");
    do_req(32'h0000_2000, 1'b0, d, hit);
    ck(!hit, "C5d 整表失效：其它行也 miss");

    // ------------------------------------------------------------- C6 打断在途填充
    rq0 = n_axi_req; al0 = n_alloc;
    @(negedge clk);
    req_addr = 32'h0001_0000; req_xip = 1'b0; req_valid = 1'b1;
    #1;
    ck(req_ready, "C6a 请求被接受（S_IDLE）");
    @(posedge clk); #1;
    @(negedge clk); req_valid = 1'b0;
    // 等这笔读真的交给主设备（AR 之前在途），再打 invalidate
    guard = 0;
    begin : c6_wait_taken
      while (u_ic.mem_taken_q !== 1'b1) begin
        @(posedge clk); #1; guard = guard + 1;
        if (guard > 100) begin
          errors = errors + 1; checks = checks + 1;
          $display("  [FAIL] C6 等待 mem_taken_q 超时");
          disable c6_wait_taken;
        end
      end
    end
    ck(1'b1, "C6b 该笔 AXI 读已在途");
    @(negedge clk); invalidate = 1'b1;
    @(negedge clk); invalidate = 1'b0;
    // 第一笔响应到达时必须被丢弃并重发 ⇒ 只有第二次读的数据被交付
    guard = 0;
    begin : c6_wait_rsp
      while (!rsp_valid) begin
        @(posedge clk); #1; guard = guard + 1;
        if (guard > 400) begin
          errors = errors + 1; checks = checks + 1;
          $display("  [FAIL] C6 等待重发读的响应超时");
          disable c6_wait_rsp;
        end
      end
    end
    d = rsp_data;
    @(posedge clk); #1;
    ck(n_axi_req == rq0 + 2, "C6c fence.i 打断在途填充后必须重发 AXI 读（共 2 笔）");
    ck(n_alloc   == al0 + 1, "C6d 只有重发的那笔数据被填充（第一笔丢弃）");
    check_line(d, 8'h66, "C6e 交付的数据来自重发读（正确）");
    do_req(32'h0001_0000, 1'b0, d, hit);
    ck(hit, "C6f 重发填充后该行可命中");

    // ------------------------------------------------------------- C7 ENABLE=0
    @(negedge clk);
    req_addr0 = 32'h0000_0000; req_valid0 = 1'b1;
    #1;
    ck(req_ready0, "C7a ENABLE=0 实例接受请求");
    @(posedge clk); #1;
    @(negedge clk); req_valid0 = 1'b0;
    guard = 0;
    begin : c7_wait
      while (!rsp_valid0) begin
        @(posedge clk); #1; guard = guard + 1;
        if (guard > 100) begin
          errors = errors + 1; checks = checks + 1;
          $display("  [FAIL] C7 等响应超时");
          disable c7_wait;
        end
      end
    end
    ck(dbg_hit0 == 1'b0, "C7b ENABLE=0：永不命中");
    ck(alloc_wen0 == 1'b0, "C7c ENABLE=0：永不分配");
    check_line(rsp_data0, 8'h11, "C7d ENABLE=0：数据仍然正确");
    @(posedge clk); #1;
    do_req0(32'h0000_0000);
    ck(dbg_hit0 == 1'b0, "C7e ENABLE=0：第二次仍不命中（直通基线）");

    // ------------------------------------------------------------- 汇总
    $display("=== 结果：checks=%0d errors=%0d ===", checks, errors);
    if (errors == 0) $display("ICACHE_UNIT: PASS (%0d checks)", checks);
    else             $display("ICACHE_UNIT: FAIL (%0d/%0d)", errors, checks);
    $finish;
  end

  //--------------------------------------------------------------------------
  // C7：ENABLE=0 直通实例（不命中/不分配，但数据必须正确）
  //--------------------------------------------------------------------------
  reg          req_valid0 = 1'b0;
  reg  [31:0]  req_addr0  = 32'd0;
  wire         req_ready0, rsp_valid0, rsp_err0;
  wire [255:0] rsp_data0;
  wire         axi_req_valid0, axi_req_ready0, axi_rsp_valid0, axi_rsp_err0, axi_rsp_ready0;
  wire [31:0]  axi_req_addr0;
  wire [255:0] axi_rsp_data0;
  wire         alloc_wen0, dbg_hit0;

  rv32_icache #(.ENABLE(0)) u_ic0 (
    .clk(clk), .rst_n(rst_n), .invalidate(1'b0),
    .req_valid(req_valid0), .req_addr(req_addr0), .req_xip(1'b0), .req_ready(req_ready0),
    .rsp_valid(rsp_valid0), .rsp_data(rsp_data0), .rsp_err(rsp_err0), .rsp_ready(1'b1),
    .axi_req_valid(axi_req_valid0), .axi_req_addr(axi_req_addr0), .axi_req_ready(axi_req_ready0),
    .axi_rsp_valid(axi_rsp_valid0), .axi_rsp_data(axi_rsp_data0), .axi_rsp_err(axi_rsp_err0),
    .axi_rsp_ready(axi_rsp_ready0),
    .dbg_alloc_wen(alloc_wen0), .dbg_alloc_addr(), .dbg_hit(dbg_hit0), .dbg_hit_way(), .dbg_set(),
    .perf_access(), .perf_hit(), .perf_miss()
  );

  // 简易 AXI 侧响应器（整行立即返回内存内容）
  reg         rsp_pend0 = 1'b0;
  reg [255:0] rsp_d0 = 256'd0;
  assign axi_req_ready0 = !rsp_pend0 && !axi_rsp_valid0;
  assign axi_rsp_valid0 = rsp_pend0;
  assign axi_rsp_data0  = rsp_d0;
  assign axi_rsp_err0   = 1'b0;

  always @(posedge clk) begin
    if (!rst_n) begin
      rsp_pend0 <= 1'b0;  rsp_d0 <= 256'd0;
    end else if (axi_req_valid0 && axi_req_ready0) begin
      rsp_pend0 <= 1'b1;
      rsp_d0    <= {u_slave.mem_lo[axi_req_addr0+31], u_slave.mem_lo[axi_req_addr0+30],
                    u_slave.mem_lo[axi_req_addr0+29], u_slave.mem_lo[axi_req_addr0+28],
                    u_slave.mem_lo[axi_req_addr0+27], u_slave.mem_lo[axi_req_addr0+26],
                    u_slave.mem_lo[axi_req_addr0+25], u_slave.mem_lo[axi_req_addr0+24],
                    u_slave.mem_lo[axi_req_addr0+23], u_slave.mem_lo[axi_req_addr0+22],
                    u_slave.mem_lo[axi_req_addr0+21], u_slave.mem_lo[axi_req_addr0+20],
                    u_slave.mem_lo[axi_req_addr0+19], u_slave.mem_lo[axi_req_addr0+18],
                    u_slave.mem_lo[axi_req_addr0+17], u_slave.mem_lo[axi_req_addr0+16],
                    u_slave.mem_lo[axi_req_addr0+15], u_slave.mem_lo[axi_req_addr0+14],
                    u_slave.mem_lo[axi_req_addr0+13], u_slave.mem_lo[axi_req_addr0+12],
                    u_slave.mem_lo[axi_req_addr0+11], u_slave.mem_lo[axi_req_addr0+10],
                    u_slave.mem_lo[axi_req_addr0+9],  u_slave.mem_lo[axi_req_addr0+8],
                    u_slave.mem_lo[axi_req_addr0+7],  u_slave.mem_lo[axi_req_addr0+6],
                    u_slave.mem_lo[axi_req_addr0+5],  u_slave.mem_lo[axi_req_addr0+4],
                    u_slave.mem_lo[axi_req_addr0+3],  u_slave.mem_lo[axi_req_addr0+2],
                    u_slave.mem_lo[axi_req_addr0+1],  u_slave.mem_lo[axi_req_addr0+0]};
    end else if (axi_rsp_valid0 && axi_rsp_ready0) begin
      rsp_pend0 <= 1'b0;
    end
  end

  task do_req0;                       // ENABLE=0 实例：只发请求等响应（不判命中）
    input [31:0] a;
    integer g;
    begin
      @(negedge clk);
      req_addr0 = a; req_valid0 = 1'b1;
      @(posedge clk); #1;
      @(negedge clk); req_valid0 = 1'b0;
      g = 0;
      while (!rsp_valid0) begin
        @(posedge clk); #1;
        g = g + 1;
        if (g > 100) begin
          errors = errors + 1; checks = checks + 1;
          $display("  [FAIL] do_req0 超时");
          disable do_req0;
        end
      end
      @(posedge clk); #1;
    end
  endtask

endmodule
