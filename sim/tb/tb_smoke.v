//=============================================================================
// tb_smoke.v —— 自研仿真平台端到端 TB（本核 core_top + AXI 从设备模型）
//-----------------------------------------------------------------------------
// 运行期加号参数（scripts/run_sim.sh 会自动传）：
//   +MEM_LO_INIT=<file.hex>   载入 0x0000_0000 起主存（字节宽度 @地址 格式）
//   +MEM_HI_INIT=<file.hex>   载入 0x8000_0000 起 arch-test 内存
//   +wave=<file.vcd>          打开波形 dump（也可只写 +wave 用默认名）
//   +sig_dump=<file>          $finish 前把 mem_hi[0x1000..0x2000] 以 %08x 逐行写出
//   +timeout=<n>              超时时钟数（默认 5,000,000 ≈ 50 ms @100 MHz）
//   +trace                    打印提交级指令轨迹（debug0_wb_*）
//
// 观测/退出约定（docs/kb/07-sim-debug.md）：
//   vuart_we / uart_we  → $write("%c", byte) 逐字节打印
//   num_we              → 打印 NUM=%h
//   exit_we (0x1FAF_FF00)→ 打印 EXIT code=%0d；0=PASS，非 0=FAIL
//   tohost_we (0x8000_1000) → 打印 TOHOST=%0d；1=PASS，3=FAIL
//   TIMEOUT             → 打印 TIMEOUT 并 $fatal（非零退出）
//
// 与核的耦合：rtl/top/core_top.v 尚未落地时，编译不加 -DCORE_PRESENT，
//   本 TB 跳过核例化，只做“镜像载入 + 从设备空闲”自检（见文件末尾 NO-CORE 分支）。
//   core_top 端口清单按 docs/design/spec/03-pipeline-regs.md §7.1。
//=============================================================================
`timescale 1ns/1ps

module tb_smoke;

  localparam CLK_HALF   = 5;              // 10 ns 周期 = 100 MHz
  localparam TMO_DEFAULT = 5000000;       // 默认超时：5,000,000 拍
  localparam RST_CYCLES  = 10;             // 前 10 拍 rst_n = 0

  //--------------------------------------------------------------------------
  // 时钟 / 复位
  //--------------------------------------------------------------------------
  reg clk = 1'b0;
  always #CLK_HALF clk = ~clk;

  reg rst_n = 1'b0;
  integer cyc = 0;
  always @(posedge clk) cyc <= cyc + 1;

  initial begin
    rst_n = 1'b0;
    repeat (RST_CYCLES) @(posedge clk);
    @(negedge clk);
    rst_n = 1'b1;
    $display("TB: reset released at %0t", $time);
  end

  //--------------------------------------------------------------------------
  // 加号参数 / 波形 / 签名 dump
  //--------------------------------------------------------------------------
  reg [8*1024-1:0] wave_file;
  reg [8*1024-1:0] sig_dump_file;
  reg [8*1024-1:0] lo_init_file;
  reg [8*1024-1:0] hi_init_file;
  reg              trace_en = 1'b0;
  reg              wave_en  = 1'b0;
  reg              sig_en   = 1'b0;
  // 签名 dump 范围（mem_hi 字节偏移/字数）；默认沿用 0x1000..0x2000 的 1024 字
  integer          sig_base  = 32'h1000;
  integer          sig_words = 1024;

  initial begin
    wave_file = "";
    if (!$value$plusargs("wave=%s", wave_file))
      if ($test$plusargs("wave")) wave_file = "sim/log/tb_smoke.vcd";
    wave_en = (wave_file != "");

    sig_dump_file = "";
    sig_en = $value$plusargs("sig_dump=%s", sig_dump_file);
    if (!$value$plusargs("sig_base=%h", sig_base))  sig_base  = 32'h1000;
    if (!$value$plusargs("sig_words=%d", sig_words)) sig_words = 1024;

    lo_init_file = "";
    hi_init_file = "";
    if ($value$plusargs("MEM_LO_INIT=%s", lo_init_file)) ;
    if ($value$plusargs("MEM_HI_INIT=%s", hi_init_file)) ;
    trace_en = $test$plusargs("trace");
  end


  //--------------------------------------------------------------------------
  // AXI4 主设备侧连线（core_top ↔ sim_axi_slave）
  //--------------------------------------------------------------------------
  wire [3:0]  arid;
  wire [31:0] araddr;
  wire [3:0]  arlen;
  wire [2:0]  arsize;
  wire [1:0]  arburst;
  wire [1:0]  arlock;
  wire [3:0]  arcache;
  wire [2:0]  arprot;
  wire        arvalid;
  wire        arready;
  wire [3:0]  rid;
  wire [31:0] rdata;
  wire [1:0]  rresp;
  wire        rlast;
  wire        rvalid;
  wire        rready;
  wire [3:0]  awid;
  wire [31:0] awaddr;
  wire [3:0]  awlen;
  wire [2:0]  awsize;
  wire [1:0]  awburst;
  wire [1:0]  awlock;
  wire [3:0]  awcache;
  wire [2:0]  awprot;
  wire        awvalid;
  wire        awready;
  wire [3:0]  wid;
  wire [31:0] wdata;
  wire [3:0]  wstrb;
  wire        wlast;
  wire        wvalid;
  wire        wready;
  wire [3:0]  bid;
  wire [1:0]  bresp;
  wire        bvalid;
  wire        bready;
  wire [7:0]  intrpt = 8'h00;
  wire [31:0] rf_rdata;
  wire        ws_valid;
  wire [31:0] debug0_wb_pc;
  wire [3:0]  debug0_wb_rf_wen;
  wire [4:0]  debug0_wb_rf_wnum;
  wire [31:0] debug0_wb_rf_wdata;

`ifndef CORE_PRESENT
  //--------------------------------------------------------------------------
  // 无核模式：把 AXI 主端口置为无效，只观察从设备是否安分
  //--------------------------------------------------------------------------
  assign arid    = 4'd0;
  assign araddr  = 32'd0;
  assign arlen   = 4'd0;
  assign arsize  = 3'd2;
  assign arburst = 2'b01;
  assign arlock  = 2'b00;
  assign arcache = 4'b0000;
  assign arprot  = 3'b000;
  assign arvalid = 1'b0;
  assign awid    = 4'd0;
  assign awaddr  = 32'd0;
  assign awlen   = 4'd0;
  assign awsize  = 3'd2;
  assign awburst = 2'b01;
  assign awlock  = 2'b00;
  assign awcache = 4'b0000;
  assign awprot  = 3'b000;
  assign awvalid = 1'b0;
  assign wid     = 4'd0;
  assign wdata   = 32'd0;
  assign wstrb   = 4'd0;
  assign wlast   = 1'b0;
  assign wvalid  = 1'b0;
  assign rready  = 1'b1;
  assign bready  = 1'b1;
`endif

  //--------------------------------------------------------------------------
  // 被验证的核（并行工程师交付；端口按 docs/design/spec/03-pipeline-regs.md §7.1）
  //--------------------------------------------------------------------------
`ifdef CORE_PRESENT
  core_top u_core (
    .aclk               (clk),
    .aresetn            (rst_n),
    .intrpt             (intrpt),
    // AXI4 主设备
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
    // 平台调试/difftest
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
`endif

  //--------------------------------------------------------------------------
  // 从设备模型（内存 + CONFREG + UART + tohost，内部地址解码）
  //--------------------------------------------------------------------------
  wire        uart_we, vuart_we, exit_we, tohost_we, num_we;
  wire [7:0]  uart_wdata, vuart_wdata;
  wire [31:0] exit_wdata, tohost_wdata, num_val;

  sim_axi_slave u_slave (
    .clk        (clk),
    .rst_n      (rst_n),
    .s_awid     (awid),
    .s_awaddr   (awaddr),
    .s_awlen    (awlen),
    .s_awsize   (awsize),
    .s_awburst  (awburst),
    .s_awvalid  (awvalid),
    .s_awready  (awready),
    .s_wid      (wid),
    .s_wdata    (wdata),
    .s_wstrb    (wstrb),
    .s_wlast    (wlast),
    .s_wvalid   (wvalid),
    .s_wready   (wready),
    .s_bid      (bid),
    .s_bresp    (bresp),
    .s_bvalid   (bvalid),
    .s_bready   (bready),
    .s_arid     (arid),
    .s_araddr   (araddr),
    .s_arlen    (arlen),
    .s_arsize   (arsize),
    .s_arburst  (arburst),
    .s_arvalid  (arvalid),
    .s_arready  (arready),
    .s_rid      (rid),
    .s_rdata    (rdata),
    .s_rresp    (rresp),
    .s_rlast    (rlast),
    .s_rvalid   (rvalid),
    .s_rready   (rready),
    .uart_we    (uart_we),
    .uart_wdata (uart_wdata),
    .vuart_we   (vuart_we),
    .vuart_wdata(vuart_wdata),
    .exit_we    (exit_we),
    .exit_wdata (exit_wdata),
    .tohost_we  (tohost_we),
    .tohost_wdata(tohost_wdata),
    .num_val    (num_val),
    .num_we     (num_we)
  );

  //--------------------------------------------------------------------------
  // 签名 dump：mem_hi[0x1000..0x2000]（1024 个字，小端，每行一个 %08x）
  //--------------------------------------------------------------------------
  task do_sig_dump;
    input [8*1024-1:0] fname;
    integer fd;
    integer i;
    begin
      if (fname == "") begin
        $display("TB: (no +sig_dump, skip signature dump)");
      end else begin
`ifdef VERILATOR
        $display("TB: WARNING sig_dump unsupported under Verilator, skipped (%0s)", fname);
`else
        fd = $fopen(fname, "w");
        if (fd == 0) begin
          $display("TB: ERROR cannot open sig_dump file %0s", fname);
        end else begin
          for (i = 0; i < sig_words; i = i + 1)
            $fdisplay(fd, "%08x",
                      {u_slave.mem_hi[sig_base + 3 + 4*i], u_slave.mem_hi[sig_base + 2 + 4*i],
                       u_slave.mem_hi[sig_base + 1 + 4*i], u_slave.mem_hi[sig_base + 0 + 4*i]});
          $fclose(fd);
          $display("TB: sig_dump -> %0s (mem_hi[0x%0h + %0d words])", fname, sig_base, sig_words);
        end
`endif
      end
    end
  endtask

  //--------------------------------------------------------------------------
  // 结束流程
  //--------------------------------------------------------------------------
  task tb_finish;
    input integer code;                 // 0 = PASS
    begin
      do_sig_dump(sig_dump_file);
      $display("TB: cycles=%0d", cyc);
      if (code == 0) begin
        $display("TB: TEST PASS");
        $finish;
      end else begin
        $display("TB: TEST FAIL code=%0d", code);
        $fatal;                         // 非零退出（脚本据此判失败）
      end
    end
  endtask

  //--------------------------------------------------------------------------
  // 观测：打印 + 退出条件
  //--------------------------------------------------------------------------
  always @(posedge clk) begin
    if (rst_n) begin
      if (vuart_we) $write("%c", vuart_wdata);
      if (uart_we)  $write("%c", uart_wdata);
      if (num_we)   $display("\nTB: NUM=%h", num_val);

      if (tohost_we) begin
        $display("\nTB: TOHOST=%0d", tohost_wdata);
        if (tohost_wdata == 32'd1) begin
          $display("TB: arch-test PASS (tohost=1)");
          tb_finish(0);
        end else if (tohost_wdata == 32'd3) begin
          $display("TB: arch-test FAIL (tohost=3)");
          tb_finish(1);
        end
      end

      if (exit_we) begin
        $display("\nTB: EXIT code=%0d", exit_wdata);
        if (exit_wdata == 32'd0) tb_finish(0);
        else                     tb_finish(1);
      end

      if (trace_en && debug0_wb_rf_wen[0])
        $display("TB: COMMIT pc=%08x x%0d=%08x", debug0_wb_pc,
                 debug0_wb_rf_wnum, debug0_wb_rf_wdata);
    end
  end

`ifndef CORE_PRESENT
  //--------------------------------------------------------------------------
  // 无核模式自检：镜像是否载入 + 从设备是否空闲（不产生虚假 rvalid/bvalid）
  //--------------------------------------------------------------------------
  reg idle_rvalid_seen = 1'b0;
  reg idle_bvalid_seen = 1'b0;
  always @(posedge clk) if (rst_n) begin
    if (rvalid) idle_rvalid_seen <= 1'b1;
    if (bvalid) idle_bvalid_seen <= 1'b1;
  end
`endif

  //--------------------------------------------------------------------------
  // 超时看门狗
  //--------------------------------------------------------------------------
  initial begin : timeout_blk
    integer tmo;
    if (!$value$plusargs("timeout=%d", tmo)) tmo = TMO_DEFAULT;
    repeat (tmo) @(posedge clk);
    $display("TB: TIMEOUT after %0d clocks (%0t)", tmo, $time);
    $fatal;
  end

  //--------------------------------------------------------------------------
  // 波形与无核自检主流程
  //--------------------------------------------------------------------------
  initial begin
    // 波形（放在 0 时刻，尽量覆盖复位）
    if (wave_en) begin
      $dumpfile(wave_file);
      $dumpvars(1, tb_smoke);
      $dumpvars(1, u_slave);
`ifdef CORE_PRESENT
      $dumpvars(0, u_core);
`endif
      $display("TB: wave -> %0s", wave_file);
    end

`ifdef CORE_PRESENT
    $display("TB: core_top instantiated (CORE_PRESENT), waiting for EXIT/TOHOST ...");
`else
    begin : no_core_check
      integer i;
      reg     img_ok;
      #1;                                    // 等 u_slave 的 $readmemh 完成
      img_ok = 1'b1;
      if (lo_init_file != "") begin
        img_ok = 1'b0;
        for (i = 0; i < 16; i = i + 1)
          if (u_slave.mem_lo[i] !== 8'hxx) img_ok = 1'b1;
      end
      $display("TB: WARNING: rtl/top/core_top.v 未就绪（未定义 CORE_PRESENT），跳过核例化");
      $display("TB: no-core check: image_loaded=%0d, MEM_LO_INIT=%0s", img_ok, lo_init_file);
      wait (rst_n === 1'b1);
      repeat (200) @(posedge clk);
      if (!img_ok) begin
        $display("TB: NO-CORE CHECK FAIL: 镜像未载入（mem_lo[0..15] 全为 x）");
        $fatal;
      end else if (idle_rvalid_seen || idle_bvalid_seen) begin
        $display("TB: NO-CORE CHECK FAIL: 无请求时从设备给出 rvalid/bvalid");
        $fatal;
      end else begin
        $display("TB: NO-CORE SMOKE PASS (compile/elaboration + image load + slave idle)");
        tb_finish(0);
      end
    end
`endif
  end

endmodule
