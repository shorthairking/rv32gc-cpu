//=============================================================================
// tb_spi_boot.v —— 2A-7a SPI-XIP 启动链路专用 TB
//-----------------------------------------------------------------------------
// 与 tb_smoke.v 的关系：**复用同一套平台模型与退出约定**，不另起一套：
//   * 被验证对象     ：rtl/top/core_top.v（本核）
//   * 从设备/平台模型：sim/tb/sim_axi_slave.v（内存 + CONFREG + UART + **SPI XIP**）
//   * 退出约定       ：程序写 0x1FAF_FF00（CONFREG 仿真 IO_SIMU）；**写 0 = PASS**，
//                      非 0 = FAIL。本 TB 与 tb_smoke 一样，在 `exit_we` 有效的那一拍
//                      用**退出值本身**判定（0 → PASS / 非 0 → FAIL），因此"退出码 0"
//                      是被**确定性**检测到的，不依赖"非零才停下"这类额外条件。
//   本 TB 唯一新增的是**启动链路的可观测性断言**（tb_smoke 不提供）：
//     CHECK-1 复位后**首笔取指请求**（AXI AR, arid=0/取指客户端）地址必须落在
//             SPI Flash XIP 窗口 [0x1C000000, 0x1C0FFFFF]；
//     CHECK-2 提交级 PC 必须**出现过**在 SPI XIP 窗口内；
//     CHECK-3 提交级 PC 必须**出现过**在 DDR 窗口内（0x0 起）——即确实跨了窗口；
//     CHECK-4 **取指请求**必须到达过 DDR 窗口（跨窗口的取指通路真的通了）；
//     CHECK-5 退出码 == 0；
//     CHECK-6 **结构断言（第 18 轮新增）**：L1 指令 Cache 在 XIP 窗口期间**永不分配**
//             （`rv32_icache.dbg_alloc_wen` 与写入地址逐拍检查），并统计"确实分配过/确实
//             走过 XIP 直通"防止断言空转；通过时打印 `XIP_NOALLOC: PASS (n checks)`。
//   任一不成立都不算通过：这防止"核根本没从 SPI 启动 / 没跳到 DDR"却被当成通过。
//
// 运行期加号参数：
//   +MEM_LO_INIT=<file.hex>  DDR 段镜像（真实地址 0x0 起，字节宽度 @地址）
//   +SPI_INIT=<file.hex>     SPI XIP 窗口镜像（0 基地址，1 MiB，字节宽度 @地址）
//   +wave=<file.vcd>         波形
//   +timeout=<n>             超时时钟数（默认 200000）
//
// 结构约束（第 18 轮更新）：本核取指行请求的下游是 L1 指令 Cache
//   （`rtl/frontend/rv32_icache.v`，16 KB/128 组/4 路/32 B、VIPT、RR 替换，`rv32_ifetch`
//   与 `rv32_axi_master` 之间）。取指命中 SPI-XIP 必须绕过 I-Cache 这一约束的 RTL 判定点
//   （`IS_SPI_XIP()` → `rv32_ifetch.xip_bypass`/`req_xip_q` → `rv32_icache` 的命中禁令与
//   填充禁令）由 RTL 侧维护；本 TB 只做观测，并以 CHECK-6 给出可判定的结构断言。
//=============================================================================
`timescale 1ns/1ps

module tb_spi_boot;

  localparam CLK_HALF    = 5;              // 10 ns 周期 = 100 MHz
  localparam TMO_DEFAULT = 200000;         // 默认超时拍数（本条启动链只需数百拍）
  localparam RST_CYCLES  = 10;

  // SPI Flash XIP 窗口（平台硬事实）：0x1C00_0000 起 1 MiB
  localparam [31:0] SPI_BASE = 32'h1C00_0000;
  localparam [31:0] SPI_LAST = 32'h1C0F_FFFF;
  // DDR 窗口（mem_lo）：0x0 起。这里用 0x0FFF_FFFF 作"DDR 侧"的判据上界。
  localparam [31:0] DDR_LAST = 32'h0FFF_FFFF;

  // AXI ID：0 = 取指客户端，3 = 数据客户端（见 rtl/bus/rv32_axi_master.v:85-86）
  localparam [3:0]  AXI_ID_IF = 4'd0;

  //--------------------------------------------------------------------------
  // 时钟 / 复位
  //--------------------------------------------------------------------------
  reg clk = 1'b0;
  always #CLK_HALF clk = ~clk;

  reg     rst_n = 1'b0;
  integer cyc   = 0;
  always @(posedge clk) cyc <= cyc + 1;

  initial begin
    rst_n = 1'b0;
    repeat (RST_CYCLES) @(posedge clk);
    @(negedge clk);
    rst_n = 1'b1;
    $display("[SPI-BOOT] reset released at %0t", $time);
  end

  //--------------------------------------------------------------------------
  // 加号参数
  //--------------------------------------------------------------------------
  reg [8*1024-1:0] wave_file;
  reg              wave_en = 1'b0;

  initial begin
    wave_file = "";
    if (!$value$plusargs("wave=%s", wave_file))
      if ($test$plusargs("wave")) wave_file = "sim/log/spi_boot.vcd";
    wave_en = (wave_file != "");
  end

  //--------------------------------------------------------------------------
  // AXI4 主设备侧连线（core_top ↔ sim_axi_slave）
  //--------------------------------------------------------------------------
  wire [3:0]  arid, arlen, arcache, rid, awid, awlen, awcache, wid, wstrb, bid;
  wire [31:0] araddr, rdata, awaddr, wdata, rf_rdata, debug0_wb_pc, debug0_wb_rf_wdata;
  wire [2:0]  arsize, arprot, awsize, awprot;
  wire [1:0]  arburst, arlock, rresp, awburst, awlock, bresp;
  wire [3:0]  debug0_wb_rf_wen;
  wire [4:0]  debug0_wb_rf_wnum;
  wire        arvalid, arready, rlast, rvalid, rready;
  wire        awvalid, awready, wlast, wvalid, wready, bvalid, bready;
  wire        ws_valid;
  wire [7:0]  intrpt = 8'h00;

  core_top u_dut (
    .aclk               (clk),
    .aresetn            (rst_n),
    .intrpt             (intrpt),
    .arid               (arid),
    .araddr             (araddr),
    .arlen              (arlen),
    .arsize             (arsize),
    .arburst            (arburst),
    .arlock             (arlock),
    .arcache            (arcache),
    .arprot             (arprot),
    .arvalid            (arvalid),
    .arready            (arready),
    .rid                (rid),
    .rdata              (rdata),
    .rresp              (rresp),
    .rlast              (rlast),
    .rvalid             (rvalid),
    .rready             (rready),
    .awid               (awid),
    .awaddr             (awaddr),
    .awlen              (awlen),
    .awsize             (awsize),
    .awburst            (awburst),
    .awlock             (awlock),
    .awcache            (awcache),
    .awprot             (awprot),
    .awvalid            (awvalid),
    .awready            (awready),
    .wid                (wid),
    .wdata              (wdata),
    .wstrb              (wstrb),
    .wlast              (wlast),
    .wvalid             (wvalid),
    .wready             (wready),
    .bid                (bid),
    .bresp              (bresp),
    .bvalid             (bvalid),
    .bready             (bready),
    .break_point        (1'b0),
    .infor_flag         (1'b0),
    .reg_num            (5'd0),
    .rf_rdata           (rf_rdata),
    .ws_valid           (ws_valid),
    .debug0_wb_pc       (debug0_wb_pc),
    .debug0_wb_rf_wen   (debug0_wb_rf_wen),
    .debug0_wb_rf_wnum  (debug0_wb_rf_wnum),
    .debug0_wb_rf_wdata (debug0_wb_rf_wdata)
  );

  //--------------------------------------------------------------------------
  // 从设备模型（与 tb_smoke 同一个模型；SPI XIP 窗口由 +SPI_INIT= 载入）
  //--------------------------------------------------------------------------
  wire        uart_we, vuart_we, exit_we, tohost_we, num_we;
  wire [7:0]  uart_wdata, vuart_wdata;
  wire [31:0] exit_wdata, tohost_wdata, num_val;

  sim_axi_slave u_slave (
    .clk        (clk),
    .rst_n      (rst_n),
    .s_awid     (awid),      .s_awaddr   (awaddr),   .s_awlen   (awlen),
    .s_awsize   (awsize),    .s_awburst  (awburst),  .s_awvalid (awvalid),
    .s_awready  (awready),
    .s_wid      (wid),       .s_wdata    (wdata),    .s_wstrb   (wstrb),
    .s_wlast    (wlast),     .s_wvalid   (wvalid),   .s_wready  (wready),
    .s_bid      (bid),       .s_bresp    (bresp),    .s_bvalid  (bvalid),
    .s_bready   (bready),
    .s_arid     (arid),      .s_araddr   (araddr),   .s_arlen   (arlen),
    .s_arsize   (arsize),    .s_arburst  (arburst),  .s_arvalid (arvalid),
    .s_arready  (arready),
    .s_rid      (rid),       .s_rdata    (rdata),    .s_rresp   (rresp),
    .s_rlast    (rlast),     .s_rvalid   (rvalid),   .s_rready  (rready),
    .uart_we    (uart_we),   .uart_wdata (uart_wdata),
    .vuart_we   (vuart_we),  .vuart_wdata(vuart_wdata),
    .exit_we    (exit_we),   .exit_wdata (exit_wdata),
    .tohost_we  (tohost_we), .tohost_wdata(tohost_wdata),
    .num_val    (num_val),   .num_we     (num_we)
  );

  //--------------------------------------------------------------------------
  // 启动链路观测
  //--------------------------------------------------------------------------
  reg        first_fetch_seen  = 1'b0;
  reg [31:0] first_fetch_addr  = 32'd0;
  reg        fetch_spi_seen    = 1'b0;
  reg        fetch_ddr_seen    = 1'b0;
  reg        commit_seen       = 1'b0;
  reg [31:0] first_commit_pc   = 32'd0;
  reg        commit_spi_seen   = 1'b0;
  reg [31:0] first_commit_spi  = 32'd0;
  reg        commit_ddr_seen   = 1'b0;
  reg [31:0] first_commit_ddr  = 32'd0;
  integer    n_fetch           = 0;

  function in_spi;
    input [31:0] a;
    begin in_spi = (a >= SPI_BASE) && (a <= SPI_LAST); end
  endfunction

  function in_ddr;
    input [31:0] a;
    begin in_ddr = (a <= DDR_LAST); end
  endfunction

  wire ar_hs = arvalid & arready;
  wire if_ar_hs = ar_hs & (arid == AXI_ID_IF);

  //--------------------------------------------------------------------------
  // CHECK-6（结构性断言，第 18 轮新增）：XIP 窗口期间 L1I **不得分配**
  //   D16② 要求"命中 SPI-XIP 窗口时绕过 I-Cache"：既不命中、也不填充。功能上由
  //   `run_spi_boot/run_boot_chain` 的启动链路正确性间接反映，这里给一条**直接的结构断言**：
  //     · 每拍观测 `rv32_icache.dbg_alloc_wen`（= 正在写 Cache 阵列/置 valid）；
  //     · ① 只要 alloc_wen=1，被写入的行地址就**不得**落在 SPI-XIP 窗口；
  //       ② `xip_bypass=1`（本拍取指 PA 落在 XIP 窗口）期间 alloc_wen 必须恒 0。
  //   同时统计"确实分配过"与"确实走过 XIP 直通"的次数，防止断言空转（vacuous pass）。
  //   层次路径：tb → core_top(u_dut) → rv32gc_core(u_core) → rv32_icache(u_icache)。
  //--------------------------------------------------------------------------
`ifdef CORE_PRESENT
  wire [31:0] ic_alloc_addr = u_dut.u_core.u_icache.dbg_alloc_addr;
  wire        ic_alloc_wen  = u_dut.u_core.u_icache.dbg_alloc_wen;
  wire        ic_xip_bypass = u_dut.u_core.if_spi_xip;
  // L1D（数据侧，第 20 轮新增）：D16② 的数据侧口径 = SPI-XIP 窗口**既不命中也不分配**
  wire [31:0] dc_alloc_addr = u_dut.u_core.u_dcache.dbg_alloc_addr;
  wire        dc_alloc_wen  = u_dut.u_core.u_dcache.dbg_alloc_wen;
  wire        dc_req_valid  = u_dut.u_core.dc_up_req_valid;
  wire        dc_req_ready  = u_dut.u_core.dc_up_req_ready;
  wire [31:0] dc_req_addr   = u_dut.u_core.dc_up_req_addr;
`else
  wire [31:0] ic_alloc_addr = 32'd0;
  wire        ic_alloc_wen  = 1'b0;
  wire        ic_xip_bypass = 1'b0;
  wire [31:0] dc_alloc_addr = 32'd0;
  wire        dc_alloc_wen  = 1'b0;
  wire        dc_req_valid  = 1'b0;
  wire        dc_req_ready  = 1'b0;
  wire [31:0] dc_req_addr   = 32'd0;
`endif

  // SPI-XIP 别名窗口（`IS_SPI_XIP` 的第二段）：0x1FE8_0000 起 64 KiB
  localparam [31:0] SPI_ALIAS_BASE = 32'h1FE8_0000;
  localparam [31:0] SPI_ALIAS_LAST = 32'h1FE8_FFFF;

  function in_xip;
    input [31:0] a;
    begin in_xip = ((a >= SPI_BASE) && (a <= SPI_LAST)) ||
                   ((a >= SPI_ALIAS_BASE) && (a <= SPI_ALIAS_LAST)); end
  endfunction

  integer n_xip_chk   = 0;    // 有效观测拍数（alloc 拍 或 xip 拍）
  integer n_alloc     = 0;    // 观测到的分配笔数（必须 >0，否则断言空转）
  integer n_xip_cyc   = 0;    // xip_bypass=1 的拍数（必须 >0，否则没走到 XIP 直通）
  integer n_xip_bad   = 0;    // 违例次数
  always @(posedge clk) if (rst_n) begin
    if (ic_alloc_wen) n_alloc <= n_alloc + 1;
    if (ic_xip_bypass) n_xip_cyc <= n_xip_cyc + 1;
    if (ic_alloc_wen || ic_xip_bypass) n_xip_chk <= n_xip_chk + 1;
    // ① 分配的行地址不得在 XIP 窗口
    if (ic_alloc_wen && in_xip(ic_alloc_addr)) begin
      n_xip_bad <= n_xip_bad + 1;
      $display("[SPI-BOOT] XIP_NOALLOC VIOLATION: alloc @0x%08x 落在 SPI-XIP 窗口 (t=%0t)",
               ic_alloc_addr, $time);
    end
    // ② xip_bypass 期间不得分配
    if (ic_xip_bypass && ic_alloc_wen) begin
      n_xip_bad <= n_xip_bad + 1;
      $display("[SPI-BOOT] XIP_NOALLOC VIOLATION: xip_bypass=1 同拍仍 alloc @0x%08x (t=%0t)",
               ic_alloc_addr, $time);
    end
  end

  // L1D 侧同类断言（第 20 轮新增）：数据地址落在 SPI-XIP 窗口时**不得分配行**
  integer n_d_alloc = 0;      // D 侧分配笔数（不要求 >0：无数据访存的镜像可以一次都没有）
  integer n_d_xip   = 0;      // D 侧被接受的 XIP 窗口访问笔数（BOOT_CHAIN 可能为 0）
  integer n_d_bad   = 0;      // D 侧违例次数
  always @(posedge clk) if (rst_n) begin
    if (dc_alloc_wen) begin
      n_d_alloc <= n_d_alloc + 1;
      if (in_xip(dc_alloc_addr)) begin
        n_d_bad <= n_d_bad + 1;
        $display("[SPI-BOOT] XIP_NOALLOC_D VIOLATION: L1D alloc @0x%08x 落在 SPI-XIP 窗口 (t=%0t)",
                 dc_alloc_addr, $time);
      end
    end
    if (dc_req_valid && dc_req_ready && in_xip(dc_req_addr)) begin
      n_d_xip <= n_d_xip + 1;
      if (dc_alloc_wen) begin
        n_d_bad <= n_d_bad + 1;
        $display("[SPI-BOOT] XIP_NOALLOC_D VIOLATION: XIP 数据访问同拍仍 alloc @0x%08x (t=%0t)",
                 dc_alloc_addr, $time);
      end
    end
  end

  // 判定条件（iverilog 要求 function 至少有一个入端口，故这里用 wire 表达式）：
  //   无违例 ∧ 确实发生过分配 ∧ 确实走过 XIP 直通（后两条防"断言空转"）
  wire xip_noalloc_pass = (n_xip_bad == 0) && (n_alloc > 0) && (n_xip_cyc > 0)
                          && (n_d_bad == 0);


  // 提交级：debug0_wb_* 只在"提交一条**写寄存器**指令"时有效（core_top 的 ws_valid），
  // 用它作为"该 PC 确实退休执行过"的判据，避免把未提交/被冲刷的 PC 当成执行过。
  wire cmt_v = ws_valid & debug0_wb_rf_wen[0];

  always @(posedge clk) if (rst_n) begin
    if (if_ar_hs) begin
      n_fetch <= n_fetch + 1;
      if (!first_fetch_seen) begin
        first_fetch_seen <= 1'b1;
        first_fetch_addr <= araddr;
      end
      if (in_spi(araddr)) fetch_spi_seen <= 1'b1;
      if (in_ddr(araddr)) fetch_ddr_seen <= 1'b1;
    end
    if (cmt_v) begin
      if (!commit_seen) begin
        commit_seen      <= 1'b1;
        first_commit_pc  <= debug0_wb_pc;
      end
      if (in_spi(debug0_wb_pc) && !commit_spi_seen) begin
        commit_spi_seen  <= 1'b1;
        first_commit_spi <= debug0_wb_pc;
      end
      if (in_ddr(debug0_wb_pc) && !commit_ddr_seen) begin
        commit_ddr_seen  <= 1'b1;
        first_commit_ddr <= debug0_wb_pc;
      end
    end
  end

  //--------------------------------------------------------------------------
  // 判定
  //--------------------------------------------------------------------------
  task do_verdict;
    input [31:0] code;
    reg ok;
    begin
      ok = 1'b1;
      $display("[SPI-BOOT] ================== 启动链路观测汇总 ==================");
      $display("[SPI-BOOT] 取指请求笔数 = %0d（AXI AR, arid=%0d 取指客户端）", n_fetch, AXI_ID_IF);

      // CHECK-1：复位后首笔取指在 SPI XIP 窗口
      if (!first_fetch_seen) begin
        $display("[SPI-BOOT] CHECK-1 FAIL: 复位后没有观察到任何取指请求");
        ok = 1'b0;
      end else if (in_spi(first_fetch_addr)) begin
        $display("[SPI-BOOT] CHECK-1 OK  : 首笔取指 @0x%08x 落在 SPI-XIP 窗口", first_fetch_addr);
      end else begin
        $display("[SPI-BOOT] CHECK-1 FAIL: 首笔取指 @0x%08x 不在 SPI-XIP 窗口 [0x1C000000,0x1C0FFFFF]",
                 first_fetch_addr);
        ok = 1'b0;
      end

      // CHECK-2：提交级 PC 出现在 SPI XIP 窗口
      if (commit_spi_seen)
        $display("[SPI-BOOT] CHECK-2 OK  : 有指令在 SPI-XIP 窗口提交执行（首个 @0x%08x）", first_commit_spi);
      else begin
        $display("[SPI-BOOT] CHECK-2 FAIL: 没有任何指令在 SPI-XIP 窗口提交执行");
        ok = 1'b0;
      end

      // CHECK-3：提交级 PC 出现在 DDR 窗口
      if (commit_ddr_seen)
        $display("[SPI-BOOT] CHECK-3 OK  : 有指令在 DDR 窗口提交执行（首个 @0x%08x）", first_commit_ddr);
      else begin
        $display("[SPI-BOOT] CHECK-3 FAIL: 没有任何指令在 DDR 窗口提交执行（跨窗口跳转没落地）");
        ok = 1'b0;
      end

      // CHECK-4：取指请求到达过 DDR 窗口
      if (fetch_ddr_seen)
        $display("[SPI-BOOT] CHECK-4 OK  : 取指请求已到达 DDR 窗口（跨窗口取指通路打通）");
      else begin
        $display("[SPI-BOOT] CHECK-4 FAIL: 取指请求从未到达 DDR 窗口");
        ok = 1'b0;
      end

      // CHECK-5：退出码 == 0
      if (code == 32'd0)
        $display("[SPI-BOOT] CHECK-5 OK  : 退出码 = 0（程序自检全部通过）");
      else begin
        $display("[SPI-BOOT] CHECK-5 FAIL: 退出码 = %0d (0x%08x)", code, code);
        ok = 1'b0;
      end

      // CHECK-6：XIP 期间 L1I 不分配（结构断言；见本文件上方 n_xip_bad 统计）
      if (xip_noalloc_pass)
        $display("[SPI-BOOT] CHECK-6 OK  : XIP 期间 L1I 无分配（alloc=%0d 笔，xip_bypass=%0d 拍）",
                 n_alloc, n_xip_cyc);
      else begin
        if (n_xip_bad != 0)
          $display("[SPI-BOOT] CHECK-6 FAIL: L1I 在 XIP 窗口分配了 %0d 次", n_xip_bad);
        else if (n_xip_cyc == 0)
          $display("[SPI-BOOT] CHECK-6 FAIL: 从未观测到 xip_bypass=1（XIP 直通未被覆盖，断言空转）");
        else
          $display("[SPI-BOOT] CHECK-6 FAIL: 从未观测到任何 Cache 分配（断言空转，alloc=0）");
        ok = 1'b0;
      end
      if (xip_noalloc_pass)
        $display("XIP_NOALLOC: PASS (%0d checks)", n_xip_chk);
      else
        $display("XIP_NOALLOC: FAIL (%0d checks, %0d violations)", n_xip_chk, n_xip_bad);
      // L1D 侧：只要没有违例即 PASS（分配数/XIP 数据访问数打印出来防止误读）
      $display("XIP_NOALLOC_D: %s (L1D alloc=%0d 笔, XIP 数据访问=%0d 笔, 违例=%0d)",
               (n_d_bad == 0) ? "PASS" : "FAIL", n_d_alloc, n_d_xip, n_d_bad);

      $display("[SPI-BOOT] 首个提交 PC = 0x%08x，cycles=%0d", first_commit_pc, cyc);
      if (ok) begin
        $display("SPI_BOOT: PASS");
        $finish;
      end else begin
        $display("SPI_BOOT: FAIL");
        $fatal;
      end
    end
  endtask

  always @(posedge clk) begin
    if (rst_n) begin
      if (vuart_we) $write("%c", vuart_wdata);
      if (uart_we)  $write("%c", uart_wdata);
      if (exit_we) begin
        $display("\n[SPI-BOOT] 观测到 IO_SIMU 写：EXIT code=%0d (0x%08x)", exit_wdata, exit_wdata);
        do_verdict(exit_wdata);
      end
    end
  end

  //--------------------------------------------------------------------------
  // 超时看门狗：超时 = 失败（绝不放宽为通过）
  //--------------------------------------------------------------------------
  initial begin : timeout_blk
    integer tmo;
    if (!$value$plusargs("timeout=%d", tmo)) tmo = TMO_DEFAULT;
    repeat (tmo) @(posedge clk);
    $display("\n[SPI-BOOT] TIMEOUT after %0d clocks (%0t)：未观测到 IO_SIMU 退出写", tmo, $time);
    $display("[SPI-BOOT] 首笔取指 seen=%0d @0x%08x；SPI 提交 seen=%0d；DDR 提交 seen=%0d",
             first_fetch_seen, first_fetch_addr, commit_spi_seen, commit_ddr_seen);
    $display("SPI_BOOT: FAIL (timeout)");
    $fatal;
  end

  //--------------------------------------------------------------------------
  // 波形
  //--------------------------------------------------------------------------
  initial begin
    if (wave_en) begin
      $dumpfile(wave_file);
      $dumpvars(1, tb_spi_boot);
      $dumpvars(0, u_dut);
      $dumpvars(1, u_slave);
      $display("[SPI-BOOT] wave -> %0s", wave_file);
    end
  end

endmodule
