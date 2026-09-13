//=============================================================================
// sim_axi_slave.v —— 自研仿真平台的“单从设备”AXI4 模型（内部地址解码）
//-----------------------------------------------------------------------------
// 约定来源：
//   docs/design/spec/00-conventions.md    （Verilog-2001、clk/rst_n、[MSB:LSB]）
//   docs/design/spec/08-bus-axi.md   §1   （32 bit 数据 / 4 bit ID / 4 bit len / INCR）
//   docs/kb/01-chiplab-platform.md   §4   （CONFREG 两套地址与偏移）
//   docs/kb/07-sim-debug.md               （tohost / CONFREG 退出 / 打印 / 地址映射）
//
// 设计要点：
//   * 一个模块内含全部从设备窗口（内存 + CONFREG + UART + tohost），TB 只连一组 AXI。
//   * 同一时刻只服务一笔写事务、一笔读事务（读写通道各自独立 FSM）——因此“同一 ID 的
//     响应顺序 = 请求顺序”天然成立（本模型不做乱序与背靠背优化，符合任务要求）。
//   * 任何 valid 只有在 ready 同拍为高时才被接受，不丢数据。
//   * 未映射地址返回 SLVERR（2'b10），不挂死。
//
// 地址映射（物理地址）：
//   0x0000_0000 + MEM_LO_BYTES      : mem_lo[]    （默认 16 MiB，可缓存主存）
//   0x8000_0000 + MEM_HI_BYTES      : mem_hi[]    （默认 1 MiB，arch-test 用）
//       0x8000_1000                  : tohost（既写入 mem_hi[]，又置 tohost_we 并锁存）
//   0x1FD0_0000 .. 0x1FD0_FFFF      : CONFREG FPGA（LED +F000 / NUM +F010 / SWITCH +F020
//                                                   / TIMER +E000）
//   0x1FAF_0000 .. 0x1FAF_FFFF      : CONFREG 仿真（LED +F020 / NUM +F050 / SWITCH +F060
//                                                   / TIMER +E000 / IO_SIMU +FF00 /
//                                                   VIRTUAL_UART +FF10 / SIMU_FLAG +FF20 /
//                                                   NUM_MONITOR +FF40）
//   0x1FE0_0000 .. 0x1FE0_3FFF      : UART 16550（寄存器基址 +0x1E0，最小寄存器集）
//   其它                            : SLVERR
//
// 观测端口（给 TB 用，均为 1 拍脉冲，num_val 为电平）：
//   uart_we/uart_wdata, vuart_we/vuart_wdata, exit_we/exit_wdata,
//   tohost_we/tohost_wdata, num_val/num_we
//
// 层次名 mem_lo / mem_hi 保持不变，TB 可用 u_slave.mem_hi[0x1000] 反向读取（dump 签名）。
//=============================================================================
`timescale 1ns/1ps

module sim_axi_slave #(
  parameter MEM_LO_BYTES = 32'h0100_0000,   // 0x0000_0000 起 16 MiB
  parameter MEM_HI_BYTES = 32'h0010_0000,   // 0x8000_0000 起 1 MiB（arch-test 用）
  parameter SPI_BYTES    = 32'h0010_0000,   // 0x1C00_0000 起 1 MiB（SPI Flash XIP 启动窗口）
  parameter SPI_INIT     = "",              // SPI 窗口镜像（hex，字节宽度，@地址）
  parameter MEM_LO_INIT  = "",              // $readmemh 文件（字节宽度，@地址 格式）
  parameter MEM_HI_INIT  = ""
)(
  input  wire clk,
  input  wire rst_n,
  // ---------------- AXI4 从设备（32 位数据 / 4 位 ID / 4 位 len）----------------
  input  wire [3:0]  s_awid,
  input  wire [31:0] s_awaddr,
  input  wire [3:0]  s_awlen,
  input  wire [2:0]  s_awsize,
  input  wire [1:0]  s_awburst,
  input  wire        s_awvalid,
  output wire        s_awready,
  input  wire [3:0]  s_wid,
  input  wire [31:0] s_wdata,
  input  wire [3:0]  s_wstrb,
  input  wire        s_wlast,
  input  wire        s_wvalid,
  output wire        s_wready,
  output wire [3:0]  s_bid,
  output wire [1:0]  s_bresp,
  output wire        s_bvalid,
  input  wire        s_bready,
  input  wire [3:0]  s_arid,
  input  wire [31:0] s_araddr,
  input  wire [3:0]  s_arlen,
  input  wire [2:0]  s_arsize,
  input  wire [1:0]  s_arburst,
  input  wire        s_arvalid,
  output wire        s_arready,
  output wire [3:0]  s_rid,
  output wire [31:0] s_rdata,
  output wire [1:0]  s_rresp,
  output wire        s_rlast,
  output wire        s_rvalid,
  input  wire        s_rready,
  // ---------------- 观测端口（TB 用）----------------
  output reg         uart_we,      // 0x1FE0_01E0 (THR) 写
  output reg  [7:0]  uart_wdata,
  output reg         vuart_we,     // 0x1FAF_FF10 写（仿真虚拟串口，打印字节）
  output reg  [7:0]  vuart_wdata,
  output reg         exit_we,      // 0x1FAF_FF00 写（IO_SIMU，退出码）
  output reg  [31:0] exit_wdata,
  output reg         tohost_we,    // 0x8000_1000 写（arch-test：1=pass 3=fail）
  output reg  [31:0] tohost_wdata,
  output reg  [31:0] num_val,      // CONFREG NUM 当前值（0x1FD0_F010 / 0x1FAF_F050）
  output reg         num_we
);

  //--------------------------------------------------------------------------
  // 0. 常量：窗口与偏移
  //--------------------------------------------------------------------------
  localparam [31:0] MEM_LO_BASE    = 32'h0000_0000;
  localparam [31:0] MEM_LO_LAST    = MEM_LO_BASE + MEM_LO_BYTES - 32'd1;
  localparam [31:0] MEM_HI_BASE    = 32'h8000_0000;
  localparam [31:0] MEM_HI_LAST    = MEM_HI_BASE + MEM_HI_BYTES - 32'd1;
  localparam [31:0] TOHOST_ADDR    = 32'h8000_1000;

  localparam [31:0] CONF_FPGA_BASE = 32'h1FD0_0000;
  localparam [31:0] CONF_FPGA_LAST = 32'h1FD0_FFFF;
  localparam [31:0] CONF_SIM_BASE  = 32'h1FAF_0000;
  localparam [31:0] CONF_SIM_LAST  = 32'h1FAF_FFFF;

  // ---- SPI Flash XIP 窗口（平台硬事实）----
  // chiplab `IP/AMBA/axi_mux_syn.v` 的地址判决：
  //   rd_addr_hit[1] = (araddr[31:16]==16'h1fe8) || (araddr[31:20]==12'h1c0)   // SPI
  // 即 **0x1C00_0000 起 1 MiB 是 SPI Flash 的 XIP 窗口**（另有 0x1FE8_0000 别名）。
  // 平台就是从这里取复位后的第一条指令（PMON/u-boot 在 SPI flash 里）。
  localparam [31:0] SPI_BASE       = 32'h1C00_0000;
  localparam [31:0] SPI_LAST       = 32'h1C0F_FFFF;   // 1 MiB
  localparam [31:0] SPI_ALIAS_BASE = 32'h1FE8_0000;   // 平台给同一个控制器留的别名窗口
  localparam [31:0] SPI_ALIAS_LAST = 32'h1FE8_FFFF;

  localparam [31:0] UART_BASE      = 32'h1FE0_0000;
  localparam [31:0] UART_LAST      = 32'h1FE0_3FFF;
  localparam [31:0] UART_REG_BASE  = 32'h1FE0_01E0;

  // CONFREG 偏移（FPGA 窗口）
  localparam [31:0] CFG_LED        = 32'h0000_F000;
  localparam [31:0] CFG_NUM        = 32'h0000_F010;
  localparam [31:0] CFG_SWITCH     = 32'h0000_F020;
  localparam [31:0] CFG_TIMER      = 32'h0000_E000;
  // CONFREG 偏移（仿真窗口）
  localparam [31:0] CFS_LED        = 32'h0000_F020;
  localparam [31:0] CFS_NUM        = 32'h0000_F050;
  localparam [31:0] CFS_SWITCH     = 32'h0000_F060;
  localparam [31:0] CFS_TIMER      = 32'h0000_E000;
  localparam [31:0] CFS_IO_SIMU    = 32'h0000_FF00;
  localparam [31:0] CFS_VUART      = 32'h0000_FF10;
  localparam [31:0] CFS_SIMU_FLAG  = 32'h0000_FF20;
  localparam [31:0] CFS_NUM_MON    = 32'h0000_FF40;

  // 区域编码
  localparam [2:0] R_MEM_LO = 3'd0;
  localparam [2:0] R_MEM_HI = 3'd1;
  localparam [2:0] R_CFG    = 3'd2;   // CONFREG FPGA
  localparam [2:0] R_CFS    = 3'd3;   // CONFREG 仿真
  localparam [2:0] R_UART   = 3'd4;
  localparam [2:0] R_SPI    = 3'd6;   // SPI Flash XIP（只读；写忽略）
  localparam [2:0] R_NONE   = 3'd5;   // 未映射 → SLVERR

  //--------------------------------------------------------------------------
  // 1. 存储阵列（层次名固定为 mem_lo / mem_hi，TB 反向读取用）
  //--------------------------------------------------------------------------
  reg [7:0] mem_lo [0:MEM_LO_BYTES-1];
  reg [7:0] mem_hi [0:MEM_HI_BYTES-1];
  reg [7:0] mem_spi[0:SPI_BYTES-1];      // SPI Flash XIP 窗口（只读，未初始化字节按 0 读）

  //--------------------------------------------------------------------------
  // 2. CONFREG / UART 内部寄存器
  //--------------------------------------------------------------------------
  reg [31:0] led_fpga, sw_fpga, timer_fpga;
  reg [31:0] led_sim,  sw_sim,  timer_sim;
  reg [31:0] num_monitor;

  reg [7:0]  uart_rbr, uart_ier, uart_fcr, uart_lcr, uart_mcr, uart_scr;
  reg [7:0]  uart_dll, uart_dlm;
  wire       uart_dlab = uart_lcr[7];
  localparam [7:0] UART_IIR = 8'h01;   // 无中断挂起
  localparam [7:0] UART_LSR = 8'h60;   // THRE | TEMT（发送器空且移位寄存器空）
  localparam [7:0] UART_MSR = 8'h00;

  //--------------------------------------------------------------------------
  // 3. 组合函数
  //--------------------------------------------------------------------------
  // 地址属于哪个窗口
  function [2:0] region_of;
    input [31:0] a;
    begin
      if (a <= MEM_LO_LAST)                                          region_of = R_MEM_LO;
      else if (a >= MEM_HI_BASE && a <= MEM_HI_LAST)                 region_of = R_MEM_HI;
      else if (a >= CONF_FPGA_BASE && a <= CONF_FPGA_LAST)           region_of = R_CFG;
      else if (a >= CONF_SIM_BASE  && a <= CONF_SIM_LAST)            region_of = R_CFS;
      else if (a >= UART_BASE      && a <= UART_LAST)                region_of = R_UART;
      else if ((a >= SPI_BASE && a <= SPI_LAST) ||
               (a >= SPI_ALIAS_BASE && a <= SPI_ALIAS_LAST))         region_of = R_SPI;
      else                                                           region_of = R_NONE;
    end
  endfunction

  // 内存字节读（非内存区返回 0，由 device_word 接管）
  // 未初始化字节（$readmemh 未覆盖的位置）按 0 读出：真实 DRAM/BRAM 不会返回 x，
  // 若让 x 传出，取指行里未定义的那些字节会把指令长度/PC 污染成 x（仿真假死锁）。
  function [7:0] mem_byte_read;
    input [31:0] a;
    begin
      if (a <= MEM_LO_LAST)
        mem_byte_read = (mem_lo[a] !== 8'hxx) ? mem_lo[a] : 8'h00;
      else if (a >= MEM_HI_BASE && a <= MEM_HI_LAST)
        mem_byte_read = (mem_hi[a - MEM_HI_BASE] !== 8'hxx) ? mem_hi[a - MEM_HI_BASE] : 8'h00;
      else if (a >= SPI_BASE && a <= SPI_LAST)
        mem_byte_read = (mem_spi[a - SPI_BASE] !== 8'hxx) ? mem_spi[a - SPI_BASE] : 8'h00;
      else if (a >= SPI_ALIAS_BASE && a <= SPI_ALIAS_LAST)
        mem_byte_read = (mem_spi[a - SPI_ALIAS_BASE] !== 8'hxx) ? mem_spi[a - SPI_ALIAS_BASE] : 8'h00;
      else
        mem_byte_read = 8'h00;
    end
  endfunction

  // 设备寄存器“按字节”读值（a 为字节地址；CONFREG 为 32 位寄存器按 lane 取字节，
  // UART 16550 每个寄存器 1 字节，寄存器号 = 相对基址 0x1FE0_01E0 的字节偏移）
  function [7:0] device_byte_read;
    input [31:0] a;
    reg   [31:0] off, woff, rv, bi;
    begin
      device_byte_read = 8'h00;
      woff = {a[31:2], 2'b00};
      bi   = {30'd0, a[1:0]} * 32'd8;
      case (region_of(a))
        R_CFG: begin
          off = woff - CONF_FPGA_BASE;
          case (off)
            CFG_LED:    rv = led_fpga;
            CFG_NUM:    rv = num_val;
            CFG_SWITCH: rv = sw_fpga;
            CFG_TIMER:  rv = timer_fpga;
            default:    rv = 32'h0000_0000;
          endcase
          device_byte_read = (bi < 32) ? rv[bi +: 8] : 8'h00;
        end
        R_CFS: begin
          off = woff - CONF_SIM_BASE;
          case (off)
            CFS_LED:       rv = led_sim;
            CFS_NUM:       rv = num_val;
            CFS_SWITCH:    rv = sw_sim;
            CFS_TIMER:     rv = timer_sim;
            CFS_IO_SIMU:   rv = 32'h0000_0000;
            CFS_VUART:     rv = 32'h0000_0000;
            CFS_SIMU_FLAG: rv = 32'hFFFF_FFFF;  // 只读，仿真中恒全 1
            CFS_NUM_MON:   rv = num_monitor;
            default:       rv = 32'h0000_0000;
          endcase
          device_byte_read = (bi < 32) ? rv[bi +: 8] : 8'h00;
        end
        R_UART: begin
          off = a - UART_BASE;
          if (off >= (UART_REG_BASE - UART_BASE) && off <= (UART_REG_BASE - UART_BASE) + 32'd7) begin
            case (off[2:0])
              3'd0: device_byte_read = uart_dlab ? uart_dll : uart_rbr;
              3'd1: device_byte_read = uart_dlab ? uart_dlm : uart_ier;
              3'd2: device_byte_read = UART_IIR;
              3'd3: device_byte_read = uart_lcr;
              3'd4: device_byte_read = uart_mcr;
              3'd5: device_byte_read = UART_LSR;   // 恒 8'h60（THRE|TEMT）
              3'd6: device_byte_read = UART_MSR;
              3'd7: device_byte_read = uart_scr;
            endcase
          end
        end
        default: device_byte_read = 8'h00;
      endcase
    end
  endfunction

  // 一次读 beat 的数据：按 size/地址把字节放到正确的 lane（AXI 窄传输语义）
  function [31:0] beat_read_data;
    input [31:0] a;
    input [2:0]  sz;
    reg   [31:0] lo, n;
    reg   [31:0] wa;
    integer      k;
    begin
      lo = (sz >= 3'd2) ? 32'd0 : {30'd0, a[1:0]};    // size>=4B 时按字对齐
      n  = (sz == 3'd0) ? 32'd1 : (sz == 3'd1) ? 32'd2 : 32'd4;
      wa = {a[31:2], 2'b00};
      beat_read_data = 32'h0000_0000;
      for (k = 0; k < 4; k = k + 1)
        if ((k >= lo) && (k < (lo + n))) begin
          if (region_of(a) == R_MEM_LO || region_of(a) == R_MEM_HI || region_of(a) == R_SPI)
            beat_read_data[k*8 +: 8] = mem_byte_read(wa + k);
          else
            beat_read_data[k*8 +: 8] = device_byte_read(wa + k);
        end
    end
  endfunction

  // 内存字节写
  task mem_byte_write;
    input [31:0] a;
    input [7:0]  d;
    begin
      if (a <= MEM_LO_LAST)                          mem_lo[a] <= d;
      else if (a >= MEM_HI_BASE && a <= MEM_HI_LAST) mem_hi[a - MEM_HI_BASE] <= d;
    end
  endtask

  //--------------------------------------------------------------------------
  // 4. 写通道 FSM
  //--------------------------------------------------------------------------
  localparam [1:0] W_IDLE = 2'd0, W_DATA = 2'd1, W_RESP = 2'd2;

  reg [1:0]  wstate;
  reg [3:0]  awid_q;
  reg [31:0] awaddr_q;
  reg [3:0]  awlen_q;
  reg [2:0]  awsize_q;
  reg [3:0]  wbeat_q;
  reg        werr_q;

  assign s_awready = (wstate == W_IDLE);
  assign s_wready  = (wstate == W_DATA);
  assign s_bvalid  = (wstate == W_RESP);
  assign s_bid     = awid_q;
  assign s_bresp   = werr_q ? 2'b10 : 2'b00;

  wire        aw_hs = s_awvalid & s_awready;
  wire        w_hs  = s_wvalid  & s_wready;
  wire [31:0] w_beat_addr = awaddr_q + ({28'd0, wbeat_q} << awsize_q);

  // 写 beat 落地（内存 / 设备寄存器 / 观测脉冲）
  /* verilator lint_off BLKSEQ */   // 任务内局部变量用阻塞赋值是惯用写法
  task write_beat;
    input [31:0] a;
    input [31:0] d;
    input [3:0]  strb;
    input [2:0]  sz;
    reg   [31:0] lo, n;
    reg   [31:0] eff, wa;
    integer      k;
    begin
      lo  = (sz >= 3'd2) ? 32'd0 : {30'd0, a[1:0]};
      n   = (sz == 3'd0) ? 32'd1 : (sz == 3'd1) ? 32'd2 : 32'd4;
      wa  = {a[31:2], 2'b00};
      eff = 32'h0000_0000;
      for (k = 0; k < 4; k = k + 1)
        if ((k >= lo) && (k < (lo + n)) && strb[k])
          eff[k*8 +: 8] = d[k*8 +: 8];

      case (region_of(a))
        R_MEM_LO, R_MEM_HI: begin
          for (k = 0; k < 4; k = k + 1)
            if ((k >= lo) && (k < (lo + n)) && strb[k])
              mem_byte_write(wa + k, d[k*8 +: 8]);
          if (region_of(a) == R_MEM_HI && wa == TOHOST_ADDR) begin
            tohost_we    <= 1'b1;        // 既写内存，又向 TB 报告
            tohost_wdata <= eff;
          end
        end
        R_CFG: begin
          case (wa - CONF_FPGA_BASE)
            CFG_LED:    led_fpga   <= eff;
            CFG_NUM:    begin num_val <= eff; num_we <= 1'b1; end
            CFG_SWITCH: sw_fpga    <= eff;
            CFG_TIMER:  timer_fpga <= eff;
            default:    ;
          endcase
        end
        R_CFS: begin
          case (wa - CONF_SIM_BASE)
            CFS_LED:       led_sim      <= eff;
            CFS_NUM:       begin num_val <= eff; num_we <= 1'b1; end
            CFS_SWITCH:    sw_sim       <= eff;
            CFS_TIMER:     timer_sim    <= eff;
            CFS_IO_SIMU:   begin exit_we <= 1'b1; exit_wdata <= eff; end
            CFS_VUART:     begin vuart_we <= 1'b1; vuart_wdata <= eff[7:0]; end
            CFS_NUM_MON:   num_monitor  <= eff;
            default:       ;
          endcase
        end
        R_UART: begin
          if (wa >= UART_REG_BASE && wa <= UART_REG_BASE + 32'd7) begin
            case (wa[2:0])
              3'd0: begin
                if (uart_dlab) uart_dll <= eff[7:0];
                else begin
                  uart_we    <= 1'b1;          // THR 写 → TB 打印
                  uart_wdata <= eff[7:0];
                  uart_rbr   <= eff[7:0];      // 回环，便于读回自测
                end
              end
              3'd1: begin
                if (uart_dlab) uart_dlm <= eff[7:0];
                else           uart_ier <= eff[7:0];
              end
              3'd2: uart_fcr <= eff[7:0];
              3'd3: uart_lcr <= eff[7:0];
              3'd4: uart_mcr <= eff[7:0];
              3'd7: uart_scr <= eff[7:0];
              default: ;                       // 5=LSR / 6=MSR 只读
            endcase
          end
        end
        R_SPI: ;                                // SPI Flash：XIP 读窗口，写不落地（真实器件需命令序列）
        default: ;                              // 未映射：不落地，由 werr_q 报 SLVERR
      endcase
    end
  endtask
  /* verilator lint_on BLKSEQ */

  always @(posedge clk) begin
    if (!rst_n) begin
      wstate <= W_IDLE;
      awid_q <= 4'd0; awaddr_q <= 32'd0; awlen_q <= 4'd0; awsize_q <= 3'd0;
      wbeat_q <= 4'd0; werr_q <= 1'b0;
      uart_we <= 1'b0; uart_wdata <= 8'h00;
      vuart_we <= 1'b0; vuart_wdata <= 8'h00;
      exit_we <= 1'b0; exit_wdata <= 32'd0;
      tohost_we <= 1'b0; tohost_wdata <= 32'd0;
      num_val <= 32'd0; num_we <= 1'b0;
      led_fpga <= 32'd0; sw_fpga <= 32'd0; timer_fpga <= 32'd0;
      led_sim  <= 32'd0; sw_sim  <= 32'd0; timer_sim  <= 32'd0;
      num_monitor <= 32'd0;
      uart_rbr <= 8'h00; uart_ier <= 8'h00; uart_fcr <= 8'h00;
      uart_lcr <= 8'h00; uart_mcr <= 8'h00; uart_scr <= 8'h00;
      uart_dll <= 8'h00; uart_dlm <= 8'h00;
    end else begin
      // 观测脉冲默认无效
      uart_we <= 1'b0; vuart_we <= 1'b0; exit_we <= 1'b0;
      tohost_we <= 1'b0; num_we <= 1'b0;

      case (wstate)
        W_IDLE: begin
          if (aw_hs) begin
            awid_q   <= s_awid;
            awaddr_q <= s_awaddr;
            awlen_q  <= s_awlen;
            awsize_q <= s_awsize;
            wbeat_q  <= 4'd0;
            werr_q   <= (region_of(s_awaddr) == R_NONE);
            wstate   <= W_DATA;
          end
        end
        W_DATA: begin
          if (w_hs) begin
            write_beat(w_beat_addr, s_wdata, s_wstrb, awsize_q);
            if (region_of(w_beat_addr) == R_NONE) werr_q <= 1'b1;
            if (wbeat_q == awlen_q) wstate <= W_RESP;
            else                    wbeat_q <= wbeat_q + 4'd1;
          end
        end
        W_RESP: begin
          if (s_bready) wstate <= W_IDLE;
        end
        default: wstate <= W_IDLE;
      endcase
    end
  end

  //--------------------------------------------------------------------------
  // 5. 读通道 FSM
  //--------------------------------------------------------------------------
  localparam R_IDLE = 1'b0, R_DATA = 1'b1;

  reg        rstate;
  reg [3:0]  arid_q;
  reg [31:0] araddr_q;
  reg [3:0]  arlen_q;
  reg [2:0]  arsize_q;
  reg [3:0]  rbeat_q;
  reg        rerr_q;

  wire        ar_hs = s_arvalid & s_arready;
  wire        r_hs  = s_rvalid  & s_rready;
  wire [31:0] r_beat_addr = araddr_q + ({28'd0, rbeat_q} << arsize_q);

  assign s_arready = (rstate == R_IDLE);
  assign s_rvalid  = (rstate == R_DATA);
  assign s_rid     = arid_q;
  assign s_rlast   = (rbeat_q == arlen_q);
  assign s_rresp   = rerr_q ? 2'b10 : 2'b00;
  // 读数据：**寄存一拍**后保持到 beat 被接收。
  // 为什么不用组合读：本模型的行为级内存数组用非阻塞赋值更新，而 `s_rdata` 若直接组合
  // 读数组，仿真器在"写 beat 与读 beat 紧邻"的时序下会返回**上一版**数据（实测：数组已是
  // 新值、函数单独求值也是新值，但该组合赋值输出的仍是旧值），会让"store 后立刻读回同址"
  // 的定向测试假失败。改为在 AR 握手拍锁存、R 拍保持，既消除该竞态又不改变 AXI 握手时序。
  reg [31:0] rdata_q;
  assign s_rdata = rdata_q;

  always @(posedge clk) begin
    if (!rst_n) begin
      rstate <= R_IDLE;
      arid_q <= 4'd0; araddr_q <= 32'd0; arlen_q <= 4'd0; arsize_q <= 3'd0;
      rbeat_q <= 4'd0; rerr_q <= 1'b0;
    end else begin
      case (rstate)
        R_IDLE: begin
          if (ar_hs) begin
            arid_q   <= s_arid;
            araddr_q <= s_araddr;
            arlen_q  <= s_arlen;
            arsize_q <= s_arsize;
            rbeat_q  <= 4'd0;
            rerr_q   <= (region_of(s_araddr) == R_NONE);
            rdata_q  <= beat_read_data(s_araddr, s_arsize);   // 地址握手拍锁存 beat 0
            rstate   <= R_DATA;
          end
        end
        R_DATA: begin
          if (r_hs) begin
            if (rbeat_q == arlen_q) rstate <= R_IDLE;
            else begin
              rbeat_q <= rbeat_q + 4'd1;
              rdata_q <= beat_read_data(r_beat_addr + (32'd1 << arsize_q), arsize_q);
            end
          end
        end
        default: rstate <= R_IDLE;
      endcase
    end
  end

  //--------------------------------------------------------------------------
  // 6. 轻量协议检查（只告警，不影响功能）：INCR 突发 / wlast 位置 / wid==awid
  //--------------------------------------------------------------------------
  always @(posedge clk) if (rst_n) begin
    if (aw_hs && (s_awburst !== 2'b01))
      $display("[AXI-SLAVE] PROTOCOL: awburst=%b != INCR @%08x", s_awburst, s_awaddr);
    if (ar_hs && (s_arburst !== 2'b01))
      $display("[AXI-SLAVE] PROTOCOL: arburst=%b != INCR @%08x", s_arburst, s_araddr);
    if (w_hs) begin
      if (s_wlast !== (wbeat_q == awlen_q))
        $display("[AXI-SLAVE] PROTOCOL: wlast=%b 但 beat=%0d len=%0d", s_wlast, wbeat_q, awlen_q);
      if (s_wid !== awid_q)
        $display("[AXI-SLAVE] PROTOCOL: wid=%0d != awid=%0d", s_wid, awid_q);
    end
  end

  //--------------------------------------------------------------------------
  // 7. 镜像载入（$readmemh；文件名空则跳过）
  //    参数 MEM_*_INIT 为编译期默认值，运行时可用 +MEM_LO_INIT=/+MEM_HI_INIT= 覆盖
  //--------------------------------------------------------------------------
  reg [8*1024-1:0] lo_init_f, hi_init_f, spi_init_f;

  initial begin
    /* verilator lint_off WIDTHEXPAND */
    lo_init_f  = MEM_LO_INIT;     // "" 参数默认 8 bit，此处零扩展到文件名缓冲
    hi_init_f  = MEM_HI_INIT;
    spi_init_f = SPI_INIT;
    /* verilator lint_on WIDTHEXPAND */
    if ($value$plusargs("MEM_LO_INIT=%s", lo_init_f)) ;
    if ($value$plusargs("MEM_HI_INIT=%s", hi_init_f)) ;
    if ($value$plusargs("SPI_INIT=%s", spi_init_f)) ;
    if (lo_init_f != "") begin
      $display("[AXI-SLAVE] $readmemh MEM_LO_INIT=%0s -> mem_lo[0:%0d]", lo_init_f, MEM_LO_BYTES-1);
      $readmemh(lo_init_f, mem_lo);
    end
    if (hi_init_f != "") begin
      $display("[AXI-SLAVE] $readmemh MEM_HI_INIT=%0s -> mem_hi[0:%0d]", hi_init_f, MEM_HI_BYTES-1);
      $readmemh(hi_init_f, mem_hi);
    end
    if (spi_init_f != "") begin
      $display("[AXI-SLAVE] $readmemh SPI_INIT=%0s -> mem_spi[0:%0d] (XIP @0x1C00_0000)",
               spi_init_f, SPI_BYTES-1);
      $readmemh(spi_init_f, mem_spi);
    end
  end

endmodule
