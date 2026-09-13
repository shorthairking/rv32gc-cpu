//=============================================================================
// rv32_axi_master.v —— 简单 AXI4 主设备（基线核 + L1 数据 Cache 行填充）
//
// 平台契约（见 docs/design/spec/08-bus-axi.md §1）：
//   · 数据宽度 32 bit（本模块当前只实现 32 位，与 FPGA SoC 一致）
//   · ID 4 bit、len 4 bit（突发 <= 16 beat）、地址 32 bit、INCR、不跨 4 KB
//
// 三类客户端：
//   1) 取指：一次 8 beat INCR 读（32 B 行，地址自动 32 B 对齐），返回 256 bit 整行（AXI ID 0）
//   2) 数据：单拍读/写（跨字访问由上层拆成两次单拍）
//   3) **数据行填充**（L1D refill，阶段 2A-④ 新增）：一次 8 beat INCR 读返回 256 bit 整行
//      （AXI ID 1，与 `docs/design/03-cache.md` §7 的"L1D refill = INCR 8 beat"一致）。
//      与取指行读共用读 FSM 的"整行装配"路径（rd_client[1]==1 即整行读）。
// 仲裁：数据单拍（load/store）优先，其次数据行填充（它卡着一条访存指令），最后取指；
//      同一时刻只有一笔 AXI 事务在途。
//
// 端口语义：req_valid/req_ready 同拍握手；rsp_valid 保持到 rsp_ready 有效。
//=============================================================================
`include "rv32gc_defs.vh"

module rv32_axi_master (
  input  wire        clk,
  input  wire        rst_n,

  // ---------------- 取指客户端（32 B 行，8 beat） ----------------
  input  wire        if_req_valid,
  input  wire [31:0] if_req_addr,
  output wire        if_req_ready,
  output reg         if_rsp_valid,
  output reg  [255:0] if_rsp_data,
  output reg         if_rsp_err,
  input  wire        if_rsp_ready,

  // ---------------- 数据客户端（单拍读/写） ----------------
  input  wire        d_req_valid,
  input  wire        d_req_we,
  input  wire [31:0] d_req_addr,
  input  wire [31:0] d_req_wdata,
  input  wire [3:0]  d_req_wstrb,
  output wire        d_req_ready,
  output reg         d_rsp_valid,
  output reg  [31:0] d_rsp_rdata,
  output reg         d_rsp_err,
  input  wire        d_rsp_ready,

  // ---------------- 数据行填充客户端（32 B 行，8 beat；L1D refill） ----------------
  input  wire        dl_req_valid,
  input  wire [31:0] dl_req_addr,      // 行地址（内部再按 32 B 对齐）
  output wire        dl_req_ready,
  output reg         dl_rsp_valid,
  output reg  [255:0] dl_rsp_data,
  output reg         dl_rsp_err,
  input  wire        dl_rsp_ready,

  // ---------------- AXI4 主设备 ----------------
  output wire [3:0]  arid,
  output reg  [31:0] araddr,
  output wire [3:0]  arlen,
  output wire [2:0]  arsize,
  output wire [1:0]  arburst,
  output wire [1:0]  arlock,
  output wire [3:0]  arcache,
  output wire [2:0]  arprot,
  output reg         arvalid,
  input  wire        arready,

  input  wire [3:0]  rid,
  input  wire [31:0] rdata,
  input  wire [1:0]  rresp,
  input  wire        rlast,
  input  wire        rvalid,
  output wire        rready,

  output wire [3:0]  awid,
  output reg  [31:0] awaddr,
  output wire [3:0]  awlen,
  output wire [2:0]  awsize,
  output wire [1:0]  awburst,
  output wire [1:0]  awlock,
  output wire [3:0]  awcache,
  output wire [2:0]  awprot,
  output reg         awvalid,
  input  wire        awready,

  output wire [3:0]  wid,
  output reg  [31:0] wdata,
  output reg  [3:0]  wstrb,
  output reg         wlast,
  output reg         wvalid,
  input  wire        wready,

  input  wire [3:0]  bid,
  input  wire [1:0]  bresp,
  input  wire        bvalid,
  output wire        bready
);

  localparam [3:0] AXI_ID_IF = 4'd0;   // 取指行读
  localparam [3:0] AXI_ID_DL = 4'd1;   // L1D 行填充读（03-cache.md §7 的 ID 分配）
  localparam [3:0] AXI_ID_D  = 4'd3;   // 数据单拍（非缓存/设备/写直达）

  // 读 FSM
  localparam [2:0] RD_IDLE = 3'd0,
                   RD_AR   = 3'd1,
                   RD_R    = 3'd2,
                   RD_FILL = 3'd3,   // 行读（取指 / L1D 填充）：等整行拼装完成
                   RD_RSP  = 3'd4,   // 行读：等 rsp_ready；单拍数据：直接进 RD_ACK
                   RD_ACK  = 3'd5;   // 数据：rsp_valid 保持，等 d_rsp_ready
  // 写 FSM
  localparam [2:0] WR_IDLE = 3'd0,
                   WR_AW   = 3'd1,
                   WR_W    = 3'd2,
                   WR_B    = 3'd3,
                   WR_RSP  = 3'd4;

  // 读客户端编码（rd_client）：0=取指行读 1=数据单拍 2=L1D 行填充
  localparam [1:0] RC_IF = 2'd0, RC_D = 2'd1, RC_DL = 2'd2;

  reg [2:0]  rd_state, wr_state;
  reg [3:0]  rd_beat;
  reg [1:0]  rd_client;        // 见 RC_* 编码
  reg [31:0] rd_addr;
  reg [255:0] rd_line;
  reg [31:0] rd_data_word;
  reg        rd_err;           // 本笔行读收到的 rresp != OKAY（SLVERR/DECERR）

  wire       rd_line_read = (rd_client != RC_D);   // 整行（8 beat）读事务

  // 仲裁：数据单拍优先 > L1D 行填充 > 取指（同一时刻只允许一笔在途）
  wire take_data  = d_req_valid && (rd_state == RD_IDLE) && (wr_state == WR_IDLE);
  wire take_dline = dl_req_valid && !d_req_valid && (rd_state == RD_IDLE) && (wr_state == WR_IDLE);
  wire take_if    = if_req_valid && !d_req_valid && !dl_req_valid &&
                    (rd_state == RD_IDLE) && (wr_state == WR_IDLE);
  wire take_write = d_req_valid && d_req_we && (rd_state == RD_IDLE) && (wr_state == WR_IDLE);

  assign if_req_ready = take_if;
  assign d_req_ready  = take_data;
  assign dl_req_ready = take_dline;

  assign arid    = (rd_client == RC_IF) ? AXI_ID_IF :
                   (rd_client == RC_DL) ? AXI_ID_DL : AXI_ID_D;
  assign arlen   = (rd_client == RC_D) ? 4'd0 : 4'd7;
  assign arsize  = 3'b010;
  assign arburst = 2'b01;
  assign arlock  = 2'b00;
  assign arcache = 4'b0000;
  assign arprot  = 3'b000;
  assign rready  = (rd_state == RD_R);

  assign awid    = AXI_ID_D;
  assign awlen   = 4'd0;
  assign awsize  = 3'b010;
  assign awburst = 2'b01;
  assign awlock  = 2'b00;
  assign awcache = 4'b0000;
  assign awprot  = 3'b000;
  assign wid     = AXI_ID_D;
  assign bready  = (wr_state == WR_B);

  // ---------------------------------------------------------------- 读通道
  always @(posedge clk) begin
    if (!rst_n) begin
      rd_state     <= RD_IDLE;
      rd_beat      <= 4'd0;
      rd_client    <= 2'd0;
      rd_addr      <= 32'd0;
      rd_line      <= 256'd0;
      rd_data_word <= 32'd0;
      arvalid      <= 1'b0;
      araddr       <= 32'd0;
      if_rsp_valid <= 1'b0;
      if_rsp_data  <= 256'd0;
      if_rsp_err   <= 1'b0;
      rd_err       <= 1'b0;
      d_rsp_valid  <= 1'b0;
      d_rsp_rdata  <= 32'd0;
      d_rsp_err    <= 1'b0;
      dl_rsp_valid <= 1'b0;
      dl_rsp_data  <= 256'd0;
      dl_rsp_err   <= 1'b0;
    end else begin
      case (rd_state)
        RD_IDLE: begin
          arvalid <= 1'b0;
          if (take_data && !d_req_we) begin        // load：单拍
            rd_client <= RC_D;
            rd_addr   <= d_req_addr;
            rd_beat   <= 4'd0;
            rd_state  <= RD_AR;
          end else if (take_dline) begin           // L1D 行填充：8 beat 整行
            rd_client <= RC_DL;
            rd_addr   <= {dl_req_addr[31:5], 5'b0};
            rd_beat   <= 4'd0;
            rd_line   <= 256'd0;
            rd_err    <= 1'b0;   // 新事务：清总线错误（行读）
            rd_state  <= RD_AR;
          end else if (take_if) begin              // 取指：8 beat 整行
            rd_client <= RC_IF;
            rd_addr   <= {if_req_addr[31:5], 5'b0};
            rd_beat   <= 4'd0;
            rd_line   <= 256'd0;
            rd_err    <= 1'b0;   // 新事务：清总线错误（取指）
            rd_state  <= RD_AR;
          end
        end

        RD_AR: begin
          arvalid <= 1'b1;
          araddr  <= rd_addr;
          if (arvalid && arready) begin
            arvalid <= 1'b0;
            rd_state<= RD_R;
          end
        end

        RD_R: begin
          if (rvalid) begin
            if (rresp != 2'b00) rd_err <= 1'b1;   // 行读：记录总线错误（单拍侧另有 d_rsp_err）
            if (rd_line_read) begin
              case (rd_beat[2:0])
                3'd0: rd_line[31:0]    <= rdata;
                3'd1: rd_line[63:32]   <= rdata;
                3'd2: rd_line[95:64]   <= rdata;
                3'd3: rd_line[127:96]  <= rdata;
                3'd4: rd_line[159:128] <= rdata;
                3'd5: rd_line[191:160] <= rdata;
                3'd6: rd_line[223:192] <= rdata;
                3'd7: rd_line[255:224] <= rdata;
                default: ;
              endcase
            end else begin
              rd_data_word <= rdata;
            end
            rd_beat <= rd_beat + 4'd1;
            if (rlast || (rd_beat[3:0] == 4'd7 && rd_line_read)) begin
              if (rd_line_read) rd_state <= RD_FILL;    // 下一拍整行就绪
              else              rd_state <= RD_RSP;
            end
          end
        end

        RD_FILL: begin
          if (rd_client == RC_IF) begin
            if_rsp_valid <= 1'b1;
            if_rsp_data  <= rd_line;
            if_rsp_err   <= rd_err;   // 取指行：把该笔读的 rresp 结果交给 rv32_ifetch
          end else begin
            dl_rsp_valid <= 1'b1;     // L1D 行填充：交给 rv32_dcache
            dl_rsp_data  <= rd_line;
            dl_rsp_err   <= rd_err;
          end
          rd_state     <= RD_RSP;
        end

        RD_RSP: begin
          if (rd_line_read) begin
            if (rd_client == RC_IF) begin
              if (if_rsp_ready) begin
                if_rsp_valid <= 1'b0;
                rd_state     <= RD_IDLE;
              end
            end else begin
              if (dl_rsp_ready) begin
                dl_rsp_valid <= 1'b0;
                rd_state     <= RD_IDLE;
              end
            end
          end else begin
            // 数据客户端：先拉起 rsp_valid（下一拍生效），再进入 RD_ACK 等待接收
            d_rsp_valid <= 1'b1;
            d_rsp_rdata <= rd_data_word;
            d_rsp_err   <= (rresp != 2'b00);
            rd_state    <= RD_ACK;
          end
        end

        RD_ACK: begin
          if (d_rsp_ready) begin
            d_rsp_valid <= 1'b0;
            rd_state    <= RD_IDLE;
          end
        end

        default: rd_state <= RD_IDLE;
      endcase
    end
  end

  // ---------------------------------------------------------------- 写通道
  always @(posedge clk) begin
    if (!rst_n) begin
      wr_state <= WR_IDLE;
      awvalid  <= 1'b0;
      awaddr   <= 32'd0;
      wvalid   <= 1'b0;
      wdata    <= 32'd0;
      wstrb    <= 4'd0;
      wlast    <= 1'b0;
    end else begin
      case (wr_state)
        WR_IDLE: begin
          if (take_write) begin
            awaddr   <= d_req_addr;
            wdata    <= d_req_wdata;
            wstrb    <= d_req_wstrb;
            awvalid  <= 1'b1;
            wvalid   <= 1'b1;
            wlast    <= 1'b1;
            wr_state <= WR_AW;
          end
        end

        WR_AW: begin
          if (awvalid && awready) awvalid <= 1'b0;
          if (wvalid  && wready)  wvalid  <= 1'b0;
          if ((!awvalid || awready) && (!wvalid || wready)) wr_state <= WR_B;
        end

        WR_B: begin
          if (bvalid) begin
            d_rsp_valid <= 1'b1;
            d_rsp_rdata <= 32'd0;
            d_rsp_err   <= (bresp != 2'b00);
            wr_state    <= WR_RSP;
          end
        end

        WR_RSP: begin
          if (d_rsp_ready) begin
            d_rsp_valid <= 1'b0;
            wr_state    <= WR_IDLE;
          end
        end

        default: wr_state <= WR_IDLE;
      endcase
    end
  end

endmodule
