//=============================================================================
// tb_dcache.v —— L1 数据 Cache（rtl/mem/rv32_dcache.v）单元/定向测试
//-----------------------------------------------------------------------------
// 覆盖（每条对应一处 RTL 设计决定，出处见 rv32_dcache.v 头部注释）：
//   C1  load 缺失 → 8 beat 突发整行填充 → 返回行内正确字；同行另一字再访问 **命中**（无总线读）
//   C2  **store 缺失：写直达、不分配**（整笔期间 dbg_alloc_wen 恒 0），总线写确实落了内存；
//       随后 load 该行 → 仍 miss（读分配）且读回刚写入的值（写直达一致性）
//   C3  **store 命中：行数据被更新** + 同时落总线（写直达）；随后 load 该字命中且读到新值
//   C4  D16② XIP 绕 Cache：0x1C00_0000 与别名 0x1FE8_0000 永不命中、**永不分配**、无行填充
//   C5  非 DDR 窗口（UART/CONFREG 等设备窗口）不缓存：每次访问都走总线，不分配
//   C6  PTW 页表读旁路（up_bypass）：DDR 地址也不命中、不分配（随后普通 load 仍 miss 证明没被缓存）
//   C7  原子绕 Cache：LR/AMO 读旁路不命中；SC/AMO 写完成后**失效被写行**（随后 load 必须 miss
//       并读到内存里该笔写的新值）
//   C8  CBO.INVAL 探针（up_cbo）：成功后失效该行 ⇒ 后续 load 重新从内存取。
//       TB 用"直接 poke 内存"模拟 DMA/外部写：先证明**不失效时读到 Cache 旧值**，再证明失效后读新值
//   C9  RR 替换：同一组第 9 条不同标记行挤掉最老那条；未被轮到的仍命中
//   C10 ENABLE=0 直通实例：组合旁路、不命中、不分配，数据仍然正确（安全阀 = 基线等价）
//   C11 总线错误：① 未映射地址（旁路读）⇒ err 上报 + 不分配；② 第二实例的**行填充**打 err ⇒ 不分配
//
// 结构：rv32_dcache ←→ rv32_axi_master ←→ sim_axi_slave（与 core_top 同款接线，
//   因此 8 beat 突发行填充走的是**真实**的 AXI 主设备/从设备路径）。
//   TB 对 Cache 内部状态只做**层次观测**（perf_*/dbg_alloc_wen/line_mem），不改功能。
//
// 运行：scripts/run_unit_dcache.sh（打印 DCACHE_UNIT: PASS (N checks) 与 DWRITE_THRU: PASS (n)）
//=============================================================================
`timescale 1ns/1ps
`include "rv32gc_defs.vh"

module tb_dcache;

  localparam [31:0] XIP_BASE  = 32'h1C00_0000;
  localparam [31:0] XIP_ALIAS = 32'h1FE8_0000;
  localparam [31:0] VUART     = 32'h1FAF_FF10;   // 设备/非 DDR 窗口
  localparam [31:0] BAD_ADDR  = 32'h3000_0000;   // 未映射 → SLVERR（且非 DDR ⇒ 旁路）

  integer checks = 0;
  integer errors = 0;

  task ck;
    input             cond;
    input [8*176-1:0] name;
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
  reg          req_we    = 1'b0;
  reg  [31:0]  req_addr  = 32'd0;
  reg  [31:0]  req_wdata = 32'd0;
  reg  [3:0]   req_wstrb = 4'd0;
  reg          req_bypass = 1'b0;
  reg          req_atomic = 1'b0;
  reg          req_cbo    = 1'b0;
  wire         req_ready;
  wire         rsp_valid;
  wire [31:0]  rsp_rdata;
  wire         rsp_err;
  reg          rsp_ready = 1'b1;

  wire         dn_req_valid, dn_req_we, dn_req_ready, dn_rsp_valid, dn_rsp_err, dn_rsp_ready;
  wire [31:0]  dn_req_addr, dn_req_wdata, dn_rsp_rdata;
  wire [3:0]   dn_req_wstrb;

  wire         dl_req_valid, dl_req_ready, dl_rsp_valid, dl_rsp_err, dl_rsp_ready;
  wire [31:0]  dl_req_addr;
  wire [255:0] dl_rsp_data;

  wire         dbg_hit, dbg_alloc_wen, dbg_fill_busy, dbg_alloc_store;
  wire [31:0]  u_dc_alloc_addr;
  wire [2:0]   dbg_hit_way;
  wire [6:0]   dbg_set;

  rv32_dcache #(.ENABLE(1)) u_dc (
    .clk(clk), .rst_n(rst_n),
    .up_req_valid(req_valid), .up_req_we(req_we), .up_req_addr(req_addr),
    .up_req_wdata(req_wdata), .up_req_wstrb(req_wstrb), .up_req_ready(req_ready),
    .up_rsp_valid(rsp_valid), .up_rsp_rdata(rsp_rdata), .up_rsp_err(rsp_err),
    .up_rsp_ready(rsp_ready),
    .up_bypass(req_bypass), .up_atomic(req_atomic), .up_cbo(req_cbo),
    .dn_req_valid(dn_req_valid), .dn_req_we(dn_req_we), .dn_req_addr(dn_req_addr),
    .dn_req_wdata(dn_req_wdata), .dn_req_wstrb(dn_req_wstrb), .dn_req_ready(dn_req_ready),
    .dn_rsp_valid(dn_rsp_valid), .dn_rsp_rdata(dn_rsp_rdata), .dn_rsp_err(dn_rsp_err),
    .dn_rsp_ready(dn_rsp_ready),
    .dl_req_valid(dl_req_valid), .dl_req_addr(dl_req_addr), .dl_req_ready(dl_req_ready),
    .dl_rsp_valid(dl_rsp_valid), .dl_rsp_data(dl_rsp_data), .dl_rsp_err(dl_rsp_err),
    .dl_rsp_ready(dl_rsp_ready),
    .dbg_hit(dbg_hit), .dbg_hit_way(dbg_hit_way), .dbg_set(dbg_set),
    .dbg_alloc_wen(dbg_alloc_wen), .dbg_alloc_addr(u_dc_alloc_addr),
    .dbg_fill_busy(dbg_fill_busy), .dbg_alloc_store(dbg_alloc_store),
    .perf_access(), .perf_hit(), .perf_miss(), .perf_bypass()
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
    .if_req_valid(1'b0), .if_req_addr(32'd0), .if_req_ready(),
    .if_rsp_valid(), .if_rsp_data(), .if_rsp_err(), .if_rsp_ready(1'b1),
    .d_req_valid(dn_req_valid), .d_req_we(dn_req_we), .d_req_addr(dn_req_addr),
    .d_req_wdata(dn_req_wdata), .d_req_wstrb(dn_req_wstrb), .d_req_ready(dn_req_ready),
    .d_rsp_valid(dn_rsp_valid), .d_rsp_rdata(dn_rsp_rdata), .d_rsp_err(dn_rsp_err),
    .d_rsp_ready(dn_rsp_ready),
    .dl_req_valid(dl_req_valid), .dl_req_addr(dl_req_addr), .dl_req_ready(dl_req_ready),
    .dl_rsp_valid(dl_rsp_valid), .dl_rsp_data(dl_rsp_data), .dl_rsp_err(dl_rsp_err),
    .dl_rsp_ready(dl_rsp_ready),
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
  integer n_bus_rd    = 0;   // 下行单拍读笔数（含旁路）
  integer n_bus_wr    = 0;   // 下行单拍写笔数
  integer n_line_rd   = 0;   // 行填充突发笔数
  integer n_alloc     = 0;   // 阵列分配笔数
  integer n_xip_alloc = 0;   // 分配地址落在 XIP 窗口的笔数（必须恒 0）

  always @(posedge clk) if (rst_n) begin
    if (dn_req_valid && dn_req_ready) begin
      if (dn_req_we) n_bus_wr <= n_bus_wr + 1;
      else           n_bus_rd <= n_bus_rd + 1;
    end
    if (dl_req_valid && dl_req_ready) n_line_rd <= n_line_rd + 1;
    if (dbg_alloc_wen) begin
      n_alloc <= n_alloc + 1;
      if (((u_dc_alloc_addr & 32'hFFF0_0000) == XIP_BASE) ||
          ((u_dc_alloc_addr & 32'hFFFF_0000) == XIP_ALIAS)) n_xip_alloc <= n_xip_alloc + 1;
    end
  end

  //--------------------------------------------------------------------------
  // 工具
  //--------------------------------------------------------------------------
  task mem_pat;                     // 把 [addr, addr+32) 填成 pat ^ 行内字节偏移
    input [31:0] addr;
    input [7:0]  pat;
    integer i;
    begin
      for (i = 0; i < 32; i = i + 1)
        u_slave.mem_lo[addr + i] = pat ^ (i[7:0]);
    end
  endtask

  function [31:0] exp_word;         // 该行该字的期望值（行内字节 = pat ^ 偏移）
    input [7:0]  pat;
    input [31:0] a;
    reg   [7:0]  o;
    begin
      o = {3'b000, a[4:0]};
      exp_word = { (pat ^ (o | 8'd3)), (pat ^ (o | 8'd2)),
                   (pat ^ (o | 8'd1)), (pat ^ (o | 8'd0)) };
    end
  endfunction

  task mem_word_set;                // 直接改内存一个字（模拟 DMA / 外部写）
    input [31:0] addr;
    input [31:0] val;
    begin
      u_slave.mem_lo[addr + 0] = val[7:0];
      u_slave.mem_lo[addr + 1] = val[15:8];
      u_slave.mem_lo[addr + 2] = val[23:16];
      u_slave.mem_lo[addr + 3] = val[31:24];
    end
  endtask

  // 发起一笔访问：等 ready 握手，保持到响应，取走；顺带采样结构可观测量
  task do_acc;
    input  [31:0]  a;
    input          we;
    input  [31:0]  wd;
    input  [3:0]   wstrb;
    input          bypass, atomic, cbo;
    output [31:0]  rd;
    output         err;
    output         hit;
    output         alloc_seen;
    output [2:0]   hit_way_o;
    integer        guard;
    begin
      @(negedge clk);
      req_addr = a; req_we = we; req_wdata = wd; req_wstrb = wstrb;
      req_bypass = bypass; req_atomic = atomic; req_cbo = cbo;
      req_valid = 1'b1;
      #1;
      if (!req_ready) begin
        errors = errors + 1; checks = checks + 1;
        $display("  [FAIL] up_req_ready=0（Cache 不在 S_IDLE）");
      end
      hit       = dbg_hit;
      hit_way_o = dbg_hit_way;
      @(posedge clk); #1;              // 该沿被接受
      @(negedge clk); req_valid = 1'b0;
      alloc_seen = 1'b0;
      guard = 0;
      while (!rsp_valid) begin
        @(posedge clk); #1;
        if (dbg_alloc_wen) alloc_seen = 1'b1;
        guard = guard + 1;
        if (guard > 400) begin
          errors = errors + 1; checks = checks + 1;
          $display("  [FAIL] 请求 0x%08x 等响应超时（400 拍）", a);
          disable do_acc;
        end
      end
      if (dbg_alloc_wen) alloc_seen = 1'b1;
      rd  = rsp_rdata;
      err = rsp_err;
      @(posedge clk); #1;              // rsp_ready=1 ⇒ 响应被取走
    end
  endtask

  //--------------------------------------------------------------------------
  // 激励
  //--------------------------------------------------------------------------
  reg [31:0] rd;
  reg        err, hit, alloc_seen;
  reg [2:0]  hw;
  integer    i0, i1;
  integer    dwrite_thru_checks = 0;

  task ckw;                          // 写直达/不写分配相关的检查（单独计数）
    input             cond;
    input [8*176-1:0] name;
    begin
      dwrite_thru_checks = dwrite_thru_checks + 1;
      ck(cond, name);
    end
  endtask

  initial begin
    // 行内字节 = pat ^ 偏移（与地址无关 ⇒ 期望值可用 exp_word 算）
    mem_pat(32'h0000_0000, 8'h11);
    mem_pat(32'h0000_0020, 8'h22);
    mem_pat(32'h0000_0040, 8'h33);
    mem_pat(32'h0000_0080, 8'h44);
    mem_pat(32'h0000_1000, 8'h55);
    mem_pat(32'h0000_2000, 8'h66);
    mem_pat(XIP_BASE,      8'hEE);   // XIP 窗口（平台模型里也是可读区域）

    rst_n = 1'b0;
    repeat (8) @(posedge clk);
    @(negedge clk); rst_n = 1'b1;
    repeat (2) @(posedge clk);

    $display("=== tb_dcache: L1D 定向/单元测试 ===");

    // ---------------------------------------------------------------- C1 缺失/命中
    i0 = n_line_rd;
    do_acc(32'h0000_0000, 1'b0, 32'd0, 4'd0, 1'b0, 1'b0, 1'b0, rd, err, hit, alloc_seen, hw);
    ck(!hit, "C1a 冷 Cache 首次 load 必须 miss");
    ck(!err, "C1b 缺失填充不得报错");
    ck(n_line_rd == i0 + 1, "C1c 缺失必须发**一次**整行突发（8 beat）读");
    ck(rd == exp_word(8'h11, 32'h0), "C1d 缺失填充后返回行内正确字（off 0）");
    ck(alloc_seen, "C1e 缺失填充必须分配该行");
    i0 = n_line_rd; i1 = n_bus_rd;
    do_acc(32'h0000_0004, 1'b0, 32'd0, 4'd0, 1'b0, 1'b0, 1'b0, rd, err, hit, alloc_seen, hw);
    ck(hit, "C1f 同行的另一字再访问必须命中");
    ck(n_line_rd == i0 && n_bus_rd == i1, "C1g 命中不得产生任何总线读");
    ck(!alloc_seen, "C1h 命中不得触发分配");
    ck(rd == exp_word(8'h11, 32'h4), "C1i 命中返回行内正确字（off 4）");

    // ---------------------------------------------------------------- C2 store 缺失
    i0 = n_alloc; i1 = n_bus_wr;
    do_acc(32'h0000_0020, 1'b1, 32'hDEAD_BEEF, 4'hF, 1'b0, 1'b0, 1'b0, rd, err, hit, alloc_seen, hw);
    ckw(!hit, "C2a store 缺失不得命中");
    ckw(!err, "C2b store 缺失写直达不得报错");
    ckw(n_bus_wr == i1 + 1, "C2c store 必须落总线（写直达）");
    ckw(!alloc_seen && n_alloc == i0, "C2d **store 缺失不得分配行**（allocate 恒 0）");
    ckw(u_slave.mem_lo[32'h20] == 8'hEF && u_slave.mem_lo[32'h23] == 8'hDE, "C2e 写直达确实写入内存");
    do_acc(32'h0000_0020, 1'b0, 32'd0, 4'd0, 1'b0, 1'b0, 1'b0, rd, err, hit, alloc_seen, hw);
    ckw(!hit, "C2f store 缺失未分配 ⇒ 随后 load 该行必须 miss（读分配）");
    ckw(rd == 32'hDEAD_BEEF, "C2g 写直达一致性：load 读回刚写的值");

    // ---------------------------------------------------------------- C3 store 命中
    i0 = n_bus_wr;
    do_acc(32'h0000_0024, 1'b1, 32'h5A5A_1234, 4'hF, 1'b0, 1'b0, 1'b0, rd, err, hit, alloc_seen, hw);
    ckw(hit, "C3a 命中行的 store 必须命中");
    ckw(n_bus_wr == i0 + 1, "C3b store 命中仍必须落总线（写直达）");
    ckw(!alloc_seen, "C3c store 命中不得分配新行");
    // 直接观测阵列：该行（组=0x24[11:5]，路=命中的路）word1 已被更新
    ckw(u_dc.line_mem[{7'd1, hw}][63:32] === 32'h5A5A_1234,   // 组 1 = 0x24[11:5]
        "C3d store 命中后 Cache 行数据被更新（word1=0x5A5A1234）");
    ckw(u_slave.mem_lo[32'h24] == 8'h34, "C3e store 命中也落了内存（写直达，不产生脏行）");
    do_acc(32'h0000_0024, 1'b0, 32'd0, 4'd0, 1'b0, 1'b0, 1'b0, rd, err, hit, alloc_seen, hw);
    ckw(hit, "C3f 随后 load 该字必须命中");
    ckw(rd == 32'h5A5A_1234, "C3g 随后 load 读到 store 的新值");

    // ---------------------------------------------------------------- C4 XIP 绕 Cache
    i0 = n_line_rd; i1 = n_alloc;
    do_acc(XIP_BASE, 1'b0, 32'd0, 4'd0, 1'b0, 1'b0, 1'b0, rd, err, hit, alloc_seen, hw);
    ck(!hit, "C4a XIP 首次访问不得命中");
    ck(!alloc_seen, "C4b XIP 读不得分配");
    do_acc(XIP_BASE, 1'b0, 32'd0, 4'd0, 1'b0, 1'b0, 1'b0, rd, err, hit, alloc_seen, hw);
    ck(!hit, "C4c XIP 第二次访问仍不得命中（每次都走总线）");
    do_acc(XIP_ALIAS, 1'b0, 32'd0, 4'd0, 1'b0, 1'b0, 1'b0, rd, err, hit, alloc_seen, hw);
    ck(!hit, "C4d XIP 别名窗口（0x1FE8_0000）不得命中");
    ck(n_line_rd == i0 && n_alloc == i1, "C4e XIP 全程无行填充、无分配");
    ck(n_xip_alloc == 0, "C4f 全程不得有任何 XIP 窗口的分配");

    // ---------------------------------------------------------------- C5 设备窗口不缓存
    do_acc(VUART, 1'b0, 32'd0, 4'd0, 1'b0, 1'b0, 1'b0, rd, err, hit, alloc_seen, hw);
    do_acc(VUART, 1'b0, 32'd0, 4'd0, 1'b0, 1'b0, 1'b0, rd, err, hit, alloc_seen, hw);
    ck(!hit, "C5a 非 DDR 设备窗口永不命中");
    ck(!alloc_seen, "C5b 设备窗口不分配");
    do_acc(32'h0000_0000, 1'b0, 32'd0, 4'd0, 1'b0, 1'b0, 1'b0, rd, err, hit, alloc_seen, hw);
    ck(hit, "C5c DDR 窗口仍正常命中（判定没有误伤可缓存区）");

    // ---------------------------------------------------------------- C6 PTW 旁路
    do_acc(32'h0000_0040, 1'b0, 32'd0, 4'd0, 1'b1, 1'b0, 1'b0, rd, err, hit, alloc_seen, hw);
    ck(!hit && !alloc_seen, "C6a PTW 页表读旁路：DDR 地址也不命中/不分配");
    do_acc(32'h0000_0040, 1'b0, 32'd0, 4'd0, 1'b0, 1'b0, 1'b0, rd, err, hit, alloc_seen, hw);
    ck(!hit, "C6b 旁路读不污染 Cache：随后普通 load 仍 miss（该行确实没被缓存）");
    do_acc(32'h0000_0040, 1'b0, 32'd0, 4'd0, 1'b0, 1'b0, 1'b0, rd, err, hit, alloc_seen, hw);
    ck(hit, "C6c 该行此后正常缓存并命中");

    // ---------------------------------------------------------------- C7 原子绕 Cache
    do_acc(32'h0000_1000, 1'b0, 32'd0, 4'd0, 1'b0, 1'b0, 1'b0, rd, err, hit, alloc_seen, hw);
    ck(!hit, "C7a 前置：0x1000 行首次 load miss 并填入");
    do_acc(32'h0000_1000, 1'b0, 32'd0, 4'd0, 1'b1, 1'b0, 1'b0, rd, err, hit, alloc_seen, hw);
    ck(!hit && !alloc_seen, "C7b LR/AMO 读（旁路）不命中、不分配");
    // AMO/SC 写：旁路（走总线）→ 写完成后失效被写行
    do_acc(32'h0000_1000, 1'b1, 32'hAAAA_5555, 4'hF, 1'b0, 1'b1, 1'b0, rd, err, hit, alloc_seen, hw);
    ck(!hit, "C7c 原子写旁路不得命中");
    ck(!err && u_slave.mem_lo[32'h1000] == 8'h55, "C7d 原子写确实落总线/内存");
    do_acc(32'h0000_1000, 1'b0, 32'd0, 4'd0, 1'b0, 1'b0, 1'b0, rd, err, hit, alloc_seen, hw);
    ck(!hit, "C7e AMO/SC 写完成必须失效被写行 ⇒ 随后 load 必须 miss 重取");
    ck(rd == 32'hAAAA_5555, "C7f 重取后读到内存新值（不是 Cache 旧行）");

    // ---------------------------------------------------------------- C8 CBO.INVAL 失效
    do_acc(32'h0000_2000, 1'b0, 32'd0, 4'd0, 1'b0, 1'b0, 1'b0, rd, err, hit, alloc_seen, hw);
    do_acc(32'h0000_2000, 1'b0, 32'd0, 4'd0, 1'b0, 1'b0, 1'b0, rd, err, hit, alloc_seen, hw);
    ck(hit, "C8a 前置：0x2000 行已命中（Cache 中确有该行）");
    mem_word_set(32'h0000_2000, 32'hCAFE_F00D);    // “DMA 改内存”，Cache 不知情
    do_acc(32'h0000_2000, 1'b0, 32'd0, 4'd0, 1'b0, 1'b0, 1'b0, rd, err, hit, alloc_seen, hw);
    ck(hit && rd == exp_word(8'h66, 32'h2000), "C8b 不失效时会读到 Cache 旧值（证明真的在缓存）");
    do_acc(32'h0000_2000, 1'b0, 32'd0, 4'd0, 1'b0, 1'b0, 1'b1, rd, err, hit, alloc_seen, hw);
    ck(!err, "C8c CBO.INVAL 探针读走总线且不报错");
    do_acc(32'h0000_2000, 1'b0, 32'd0, 4'd0, 1'b0, 1'b0, 1'b0, rd, err, hit, alloc_seen, hw);
    ck(!hit, "C8d CBO.INVAL 后该行必须失效 ⇒ 随后 load miss");
    ck(rd == 32'hCAFE_F00D, "C8e 失效后重取读到内存新值");

    // ---------------------------------------------------------------- C9 RR 替换
    // 组 5（addr[11:5]=5）：0x00A0 + k*0x2000 —— 标记不同、组号相同
    do_acc(32'h0000_00A0, 1'b0, 32'd0, 4'd0, 1'b0, 1'b0, 1'b0, rd, err, hit, alloc_seen, hw);
    do_acc(32'h0000_20A0, 1'b0, 32'd0, 4'd0, 1'b0, 1'b0, 1'b0, rd, err, hit, alloc_seen, hw);
    do_acc(32'h0000_40A0, 1'b0, 32'd0, 4'd0, 1'b0, 1'b0, 1'b0, rd, err, hit, alloc_seen, hw);
    do_acc(32'h0000_60A0, 1'b0, 32'd0, 4'd0, 1'b0, 1'b0, 1'b0, rd, err, hit, alloc_seen, hw);
    do_acc(32'h0000_80A0, 1'b0, 32'd0, 4'd0, 1'b0, 1'b0, 1'b0, rd, err, hit, alloc_seen, hw);
    do_acc(32'h0000_A0A0, 1'b0, 32'd0, 4'd0, 1'b0, 1'b0, 1'b0, rd, err, hit, alloc_seen, hw);
    do_acc(32'h0000_C0A0, 1'b0, 32'd0, 4'd0, 1'b0, 1'b0, 1'b0, rd, err, hit, alloc_seen, hw);
    do_acc(32'h0000_E0A0, 1'b0, 32'd0, 4'd0, 1'b0, 1'b0, 1'b0, rd, err, hit, alloc_seen, hw);
    ck(!hit, "C9a 同组第 8 条新行：miss（填最后一空路）");
    do_acc(32'h0001_00A0, 1'b0, 32'd0, 4'd0, 1'b0, 1'b0, 1'b0, rd, err, hit, alloc_seen, hw);
    ck(!hit, "C9b 同组第 9 条：miss（RR 挤掉最老那条）");
    do_acc(32'h0001_00A0, 1'b0, 32'd0, 4'd0, 1'b0, 1'b0, 1'b0, rd, err, hit, alloc_seen, hw);
    ck(hit, "C9c 新填入的行命中");
    do_acc(32'h0000_20A0, 1'b0, 32'd0, 4'd0, 1'b0, 1'b0, 1'b0, rd, err, hit, alloc_seen, hw);
    ck(hit, "C9d 未被轮到的行仍命中");
    do_acc(32'h0000_00A0, 1'b0, 32'd0, 4'd0, 1'b0, 1'b0, 1'b0, rd, err, hit, alloc_seen, hw);
    ck(!hit, "C9e 被 RR 挤掉的最老行已 miss");

    // ---------------------------------------------------------------- C11 总线错误
    i0 = n_alloc;
    do_acc(BAD_ADDR, 1'b0, 32'd0, 4'd0, 1'b0, 1'b0, 1'b0, rd, err, hit, alloc_seen, hw);
    ck(err, "C11a 未映射地址的访问必须上报总线错误");
    ck(n_alloc == i0 && !alloc_seen, "C11b 出错的访问不得分配行");

    // ---------------------------------------------------------------- C10 ENABLE=0 直通
    do_acc0(32'h0000_0000, 1'b0, 32'd0, 4'd0, rd, err);
    do_acc0(32'h0000_0000, 1'b0, 32'd0, 4'd0, rd, err);
    ck(hit0 == 1'b0, "C10a ENABLE=0：永不命中");
    ck(alloc_wen0 == 1'b0, "C10b ENABLE=0：永不分配");
    ck(rd == exp_word(8'h11, 32'h0), "C10c ENABLE=0：数据仍然正确（直通基线等价）");
    ck(!err, "C10d ENABLE=0：不报错");

    // ---------------------------------------------------------------- C12 填充打 err 的实例
    // 第三个实例：ENABLE=1，但行填充通道恒回 err ⇒ 必须不分配并把 err 交付上游
    do_acc1(32'h0000_0000, rd, err);
    ck(err, "C12a 行填充返回总线错误 ⇒ load 必须报 err");
    ck(u_dc1.valid_q == {`L1D_SETS*`L1D_WAYS{1'b0}}, "C12b 填充出错的行不得分配（valid 全 0）");

    // ---------------------------------------------------------------- 汇总
    $display("=== 结果：checks=%0d errors=%0d ===", checks, errors);
    if (errors == 0) begin
      $display("DCACHE_UNIT: PASS (%0d checks)", checks);
      $display("DWRITE_THRU: PASS (%0d checks)", dwrite_thru_checks);
    end else begin
      $display("DCACHE_UNIT: FAIL (%0d/%0d)", errors, checks);
      $display("DWRITE_THRU: FAIL (%0d/%0d)", errors, checks);
    end
    $finish;
  end

  //--------------------------------------------------------------------------
  // C10：ENABLE=0 直通实例（组合旁路，不命中/不分配，但数据必须正确）
  //--------------------------------------------------------------------------
  reg          req_valid0 = 1'b0;
  reg          req_we0    = 1'b0;
  reg  [31:0]  req_addr0  = 32'd0;
  reg  [31:0]  req_wdata0 = 32'd0;
  reg  [3:0]   req_wstrb0 = 4'd0;
  wire         req_ready0, rsp_valid0, rsp_err0;
  wire [31:0]  rsp_rdata0;
  wire         dn_req_valid0, dn_req_we0, dn_req_ready0, dn_rsp_valid0, dn_rsp_err0, dn_rsp_ready0;
  wire [31:0]  dn_req_addr0, dn_req_wdata0, dn_rsp_rdata0;
  wire [3:0]   dn_req_wstrb0;
  wire         dl_req_valid0, dl_req_ready0, dl_rsp_valid0, dl_rsp_err0, dl_rsp_ready0;
  wire [31:0]  dl_req_addr0;
  wire [255:0] dl_rsp_data0;
  wire         hit0, alloc_wen0;

  rv32_dcache #(.ENABLE(0)) u_dc0 (
    .clk(clk), .rst_n(rst_n),
    .up_req_valid(req_valid0), .up_req_we(req_we0), .up_req_addr(req_addr0),
    .up_req_wdata(req_wdata0), .up_req_wstrb(req_wstrb0), .up_req_ready(req_ready0),
    .up_rsp_valid(rsp_valid0), .up_rsp_rdata(rsp_rdata0), .up_rsp_err(rsp_err0),
    .up_rsp_ready(1'b1),
    .up_bypass(1'b0), .up_atomic(1'b0), .up_cbo(1'b0),
    .dn_req_valid(dn_req_valid0), .dn_req_we(dn_req_we0), .dn_req_addr(dn_req_addr0),
    .dn_req_wdata(dn_req_wdata0), .dn_req_wstrb(dn_req_wstrb0), .dn_req_ready(dn_req_ready0),
    .dn_rsp_valid(dn_rsp_valid0), .dn_rsp_rdata(dn_rsp_rdata0), .dn_rsp_err(dn_rsp_err0),
    .dn_rsp_ready(dn_rsp_ready0),
    .dl_req_valid(dl_req_valid0), .dl_req_addr(dl_req_addr0), .dl_req_ready(dl_req_ready0),
    .dl_rsp_valid(dl_rsp_valid0), .dl_rsp_data(dl_rsp_data0), .dl_rsp_err(dl_rsp_err0),
    .dl_rsp_ready(dl_rsp_ready0),
    .dbg_hit(hit0), .dbg_hit_way(), .dbg_set(),
    .dbg_alloc_wen(alloc_wen0), .dbg_alloc_addr(),
    .dbg_fill_busy(), .dbg_alloc_store(),
    .perf_access(), .perf_hit(), .perf_miss(), .perf_bypass()
  );

  // 直通实例的行应答器（立即返回内存内容）
  reg         rsp_pend0 = 1'b0;
  reg [255:0] rsp_d0 = 256'd0;
  assign dl_req_ready0 = !rsp_pend0 && !dl_rsp_valid0;
  assign dl_rsp_valid0 = rsp_pend0;
  assign dl_rsp_data0  = rsp_d0;
  assign dl_rsp_err0   = 1'b0;

  always @(posedge clk) begin
    if (!rst_n) begin
      rsp_pend0 <= 1'b0; rsp_d0 <= 256'd0;
    end else if (dl_req_valid0 && dl_req_ready0) begin
      rsp_pend0 <= 1'b1;
      rsp_d0 <= {u_slave.mem_lo[dl_req_addr0+31], u_slave.mem_lo[dl_req_addr0+30],
                 u_slave.mem_lo[dl_req_addr0+29], u_slave.mem_lo[dl_req_addr0+28],
                 u_slave.mem_lo[dl_req_addr0+27], u_slave.mem_lo[dl_req_addr0+26],
                 u_slave.mem_lo[dl_req_addr0+25], u_slave.mem_lo[dl_req_addr0+24],
                 u_slave.mem_lo[dl_req_addr0+23], u_slave.mem_lo[dl_req_addr0+22],
                 u_slave.mem_lo[dl_req_addr0+21], u_slave.mem_lo[dl_req_addr0+20],
                 u_slave.mem_lo[dl_req_addr0+19], u_slave.mem_lo[dl_req_addr0+18],
                 u_slave.mem_lo[dl_req_addr0+17], u_slave.mem_lo[dl_req_addr0+16],
                 u_slave.mem_lo[dl_req_addr0+15], u_slave.mem_lo[dl_req_addr0+14],
                 u_slave.mem_lo[dl_req_addr0+13], u_slave.mem_lo[dl_req_addr0+12],
                 u_slave.mem_lo[dl_req_addr0+11], u_slave.mem_lo[dl_req_addr0+10],
                 u_slave.mem_lo[dl_req_addr0+9],  u_slave.mem_lo[dl_req_addr0+8],
                 u_slave.mem_lo[dl_req_addr0+7],  u_slave.mem_lo[dl_req_addr0+6],
                 u_slave.mem_lo[dl_req_addr0+5],  u_slave.mem_lo[dl_req_addr0+4],
                 u_slave.mem_lo[dl_req_addr0+3],  u_slave.mem_lo[dl_req_addr0+2],
                 u_slave.mem_lo[dl_req_addr0+1],  u_slave.mem_lo[dl_req_addr0+0]};
    end else if (dl_rsp_valid0 && dl_rsp_ready0) begin
      rsp_pend0 <= 1'b0;
    end
  end

  task do_acc0;
    input  [31:0] a;
    input         we;
    input  [31:0] wd;
    input  [3:0]  wstrb;
    output [31:0] rd_o;
    output        err_o;
    integer g;
    begin
      @(negedge clk);
      req_addr0 = a; req_we0 = we; req_wdata0 = wd; req_wstrb0 = wstrb; req_valid0 = 1'b1;
      @(posedge clk); #1;
      @(negedge clk); req_valid0 = 1'b0;
      g = 0;
      while (!rsp_valid0) begin
        @(posedge clk); #1;
        g = g + 1;
        if (g > 400) begin
          errors = errors + 1; checks = checks + 1;
          $display("  [FAIL] do_acc0 超时");
          disable do_acc0;
        end
      end
      rd_o = rsp_rdata0; err_o = rsp_err0;
      @(posedge clk); #1;
    end
  endtask

  //--------------------------------------------------------------------------
  // C12：第三个实例 —— 行填充通道恒回 err（验证"填充出错 ⇒ 不分配 + err 上报"）
  //--------------------------------------------------------------------------
  reg          req_valid1 = 1'b0;
  reg  [31:0]  req_addr1  = 32'd0;
  wire         req_ready1, rsp_valid1, rsp_err1;
  wire [31:0]  rsp_rdata1;
  wire         dl_req_valid1, dl_req_ready1, dl_rsp_valid1, dl_rsp_err1, dl_rsp_ready1;
  wire [31:0]  dl_req_addr1;
  wire [255:0] dl_rsp_data1;

  rv32_dcache #(.ENABLE(1)) u_dc1 (
    .clk(clk), .rst_n(rst_n),
    .up_req_valid(req_valid1), .up_req_we(1'b0), .up_req_addr(req_addr1),
    .up_req_wdata(32'd0), .up_req_wstrb(4'd0), .up_req_ready(req_ready1),
    .up_rsp_valid(rsp_valid1), .up_rsp_rdata(rsp_rdata1), .up_rsp_err(rsp_err1),
    .up_rsp_ready(1'b1),
    .up_bypass(1'b0), .up_atomic(1'b0), .up_cbo(1'b0),
    .dn_req_valid(), .dn_req_we(), .dn_req_addr(), .dn_req_wdata(), .dn_req_wstrb(),
    .dn_req_ready(1'b1), .dn_rsp_valid(1'b0), .dn_rsp_rdata(32'd0), .dn_rsp_err(1'b0),
    .dn_rsp_ready(),
    .dl_req_valid(dl_req_valid1), .dl_req_addr(dl_req_addr1), .dl_req_ready(dl_req_ready1),
    .dl_rsp_valid(dl_rsp_valid1), .dl_rsp_data(dl_rsp_data1), .dl_rsp_err(dl_rsp_err1),
    .dl_rsp_ready(dl_rsp_ready1),
    .dbg_hit(), .dbg_hit_way(), .dbg_set(), .dbg_alloc_wen(), .dbg_alloc_addr(),
    .dbg_fill_busy(), .dbg_alloc_store(),
    .perf_access(), .perf_hit(), .perf_miss(), .perf_bypass()
  );

  reg rsp_pend1 = 1'b0;
  assign dl_req_ready1  = !rsp_pend1 && !dl_rsp_valid1;
  assign dl_rsp_valid1  = rsp_pend1;
  assign dl_rsp_data1   = 256'd0;
  assign dl_rsp_err1    = 1'b1;                 // 恒 err
  always @(posedge clk) begin
    if (!rst_n) rsp_pend1 <= 1'b0;
    else if (dl_req_valid1 && dl_req_ready1) rsp_pend1 <= 1'b1;
    else if (dl_rsp_valid1 && dl_rsp_ready1) rsp_pend1 <= 1'b0;
  end

  task do_acc1;
    input  [31:0] a;
    output [31:0] rd_o;
    output        err_o;
    integer g;
    begin
      @(negedge clk);
      req_addr1 = a; req_valid1 = 1'b1;
      #1;
      @(posedge clk); #1;
      @(negedge clk); req_valid1 = 1'b0;
      g = 0;
      while (!rsp_valid1) begin
        @(posedge clk); #1;
        g = g + 1;
        if (g > 400) begin
          errors = errors + 1; checks = checks + 1;
          $display("  [FAIL] do_acc1 超时");
          disable do_acc1;
        end
      end
      rd_o = rsp_rdata1; err_o = rsp_err1;
      @(posedge clk); #1;
    end
  endtask

endmodule
