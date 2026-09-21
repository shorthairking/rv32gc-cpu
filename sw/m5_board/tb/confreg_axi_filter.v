//==============================================================================
// sw/m5_board/tb/confreg_axi_filter.v —— AXI4 地址过滤层 + 上板 CONFREG 行为模型
//==============================================================================
// 归属 : sw/m5_board/tb/（M5 上板前核级仿真验证件；本目录外只读）
// 位置 : core_top（AXI4 主） ──► **本层** ──► sim_mem_model（AXI4 从）
//
// 职责（两件，且只有两件）：
//   ① **地址过滤**：地址落在 [CONF_BASE, CONF_LIMIT) 的读/写由本层截获并自行响应；
//      其余地址**逐字段原样透传**给 sim_mem_model（不改地址/长度/属性/时序）。
//   ② **CONFREG（上板 confreg_syn）行为模型**，偏移口径见 m5_board.S 头注 §二：
//        +0xF000 LED[15:0]          读写（写即显示；wstrb 按字节生效）
//        +0xF010 数码管 num_data[31:0] 读写（每 4 bit 一位）
//        +0xF020 switch[7:0]        只读（参数 SWITCH_VAL；写忽略并计数）
//        +0xF030 FREQ               只读常量 32'd33000000（写忽略并计数）
//        +0xE000 TIMER              自由运行 32 bit，每拍 +1；**写任意值即清零**
//                                   （写 0 之后**下一拍**起从 0 递增）
//      窗口内未登记偏移：读 0、写忽略，各自计数（便于诊断，不静默）。
//
// AXI4 口径：
//   · 五通道握手全部用 `valid && ready`；本层对上游最多各一笔在途（读一笔/写一笔），
//     与 2A 核的 axi_master_ctrl（`RV32GC_AXI_OUTSTANDING == 1`，读写交替）一致。
//   · 读：AR 握手后**下一拍**起逐 beat 输出 R（与 sim_mem_model 的 READ_LAT_DLY=0 同口径），
//     支持 INCR 多 beat（末拍 rlast）。
//   · 写：AW → W（逐 beat，wlast 收尾）→ B（OKAY）。
//   · 防御：若出现"本层与下游同时有在途事务"这类**只可能来自误路由/主机违反单笔在途**
//     的情形，计入 xact_collision_count（TB 判 FAIL），不静默吞掉。
//
// 观测（TB 判据的唯一观测点都在 AXI 通道上）：
//   · first_ar_seen/first_ar_addr：**上游** AR 通道上第一笔读地址（C1 判据）
//   · led_wr_seen / sw_rd_seen / timer_rd_seen / freq_rd_seen（C4 判据）
//   · LED/数码管回读值、TIMER 首/末读值、FREQ 读回值（诊断：证明行为模型真的在动）
//   · AXI 轨迹数组（ar_trace_*/aw_trace_*，供 TB 打印"AXI 轨迹"）
//
// 红线：不进 rtl/**、不进 sim/**；本文件是 TESTBENCH 件，不可综合。
//==============================================================================
`timescale 1ns / 1ps

module confreg_axi_filter #(
    // ---- 窗口（上板 confreg_syn 基址 0x1FD0_0000；窗口 64 KiB）----
    parameter [31:0]  CONF_BASE   = 32'h1FD0_0000,
    parameter [31:0]  CONF_LIMIT  = 32'h1FD1_0000,   // 开区间上界
    // ---- 行为参数 ----
    parameter [7:0]   SWITCH_VAL  = 8'hA5,           // 拨码开关固定值
    parameter [31:0]  FREQ_VAL    = 32'd33000000,    // 上板 33 MHz 同域时钟常量
    // ---- 轨迹深度（超出后只计数不存储）----
    parameter integer TRACE_DEPTH = 1024,
    // ---- R 数据保持（"粘性"）----
    //   1（默认，= 上板 confreg_syn / sim_mem_model 的真实行为）：读数据在 **AR 握手拍
    //     寄存**（confreg_syn.v:295 `if (ar_enter) s_rdata <= rdata_d;`），并在**下一笔
    //     AR 到来之前**一直保持在 R 总线上（AXI4 允许从设备保持更久）。
    //   0（A/B 对照用）：只在 rvalid 有效期间驱动数据，握手后立刻把总线交还下游 ——
    //     这是"严格按 AXI 握手点采样"的从设备模型。
    //   ★ 为什么默认必须是 1：本核 M 级 AXI 读的完成判定用的是**打了一拍的**
    //     `axi_done_q`（core_top.v:2975/4040），因此实际是在 R 握手**之后第 2 拍**
    //     才从 `rdata` 上取值（`m_axi_ld_data`，core_top.v:2221）。对"握手后立刻换数据"
    //     的从设备，这会读到**别的事务的数据**（本 TB 实测：读到的是 XIP 取指指令字）。
    //     置 0 可复现该现象，用来给核 RTL 的这一时序脆弱点留证据（见 tb/README-tb.md）。
    parameter integer R_STICKY    = 1,
    // ---- ★ 下游（DDR3/XIP 侧 = sim_mem_model）R 数据保持口径 ----
    //   0（默认，= 历史行为）：下游 RDATA 原样透传（`sim_mem_model` 在握手后仍把数据
    //     留在总线上 ⇒ 掩盖主设备"晚拍采样"缺陷）。
    //   1（"非保持型 R 通道模型"，= 真实 MIG / 流水化互连口径）：下游 RDATA **只在
    //     `m_rvalid & m_rready` 同拍有效**，其余拍一律呈现 0。
    //   ★ 为什么需要它：M5 上板的 DDR3 侧就是这种从设备（Xilinx MIG 的 app_rd_data 只在
    //     `app_rd_data_valid` 拍有效）⇒ 核内 AXI 控制器若在 R 握手之后才取数，读回的是
    //     总线上"别的东西"（实测上板表现为 `.data/.bss` 常量/变量损坏、十进制打印全乱）。
    //     本开关只改**从设备行为模型**，不改任何判断语义（C0–C5 一字不动）。
    //   注：CONFREG 本层自答的读数据口径由 R_STICKY 单独控制（上板 confreg_syn 是
    //     寄存器保持型 ⇒ 默认 R_STICKY=1 才对）。
    parameter integer DDR_R_NONHOLD = 0
) (
    input  wire        clk,
    input  wire        rst_n,

    //--------------------------------------------------------------------------
    // 上游（core_top 侧）：端口名/位宽与 sim_mem_model 的从端口逐字一致
    //--------------------------------------------------------------------------
    // AR
    input  wire [3:0]  arid,
    input  wire [31:0] araddr,
    input  wire [3:0]  arlen,
    input  wire [2:0]  arsize,
    input  wire [1:0]  arburst,
    input  wire [1:0]  arlock,
    input  wire [3:0]  arcache,
    input  wire [2:0]  arprot,
    input  wire        arvalid,
    output wire        arready,
    // R
    output wire [3:0]  rid,
    output wire [31:0] rdata,
    output wire [1:0]  rresp,
    output wire        rlast,
    output wire        rvalid,
    input  wire        rready,
    // AW
    input  wire [3:0]  awid,
    input  wire [31:0] awaddr,
    input  wire [3:0]  awlen,
    input  wire [2:0]  awsize,
    input  wire [1:0]  awburst,
    input  wire [1:0]  awlock,
    input  wire [3:0]  awcache,
    input  wire [2:0]  awprot,
    input  wire        awvalid,
    output wire        awready,
    // W
    input  wire [3:0]  wid,
    input  wire [31:0] wdata,
    input  wire [3:0]  wstrb,
    input  wire        wlast,
    input  wire        wvalid,
    output wire        wready,
    // B
    output wire [3:0]  bid,
    output wire [1:0]  bresp,
    output wire        bvalid,
    input  wire        bready,

    //--------------------------------------------------------------------------
    // 下游（sim_mem_model 侧）：本层是主机
    //--------------------------------------------------------------------------
    output wire [3:0]  m_arid,
    output wire [31:0] m_araddr,
    output wire [3:0]  m_arlen,
    output wire [2:0]  m_arsize,
    output wire [1:0]  m_arburst,
    output wire [1:0]  m_arlock,
    output wire [3:0]  m_arcache,
    output wire [2:0]  m_arprot,
    output wire        m_arvalid,
    input  wire        m_arready,

    input  wire [3:0]  m_rid,
    input  wire [31:0] m_rdata,
    input  wire [1:0]  m_rresp,
    input  wire        m_rlast,
    input  wire        m_rvalid,
    output wire        m_rready,

    output wire [3:0]  m_awid,
    output wire [31:0] m_awaddr,
    output wire [3:0]  m_awlen,
    output wire [2:0]  m_awsize,
    output wire [1:0]  m_awburst,
    output wire [1:0]  m_awlock,
    output wire [3:0]  m_awcache,
    output wire [2:0]  m_awprot,
    output wire        m_awvalid,
    input  wire        m_awready,

    output wire [3:0]  m_wid,
    output wire [31:0] m_wdata,
    output wire [3:0]  m_wstrb,
    output wire        m_wlast,
    output wire        m_wvalid,
    input  wire        m_wready,

    input  wire [3:0]  m_bid,
    input  wire [1:0]  m_bresp,
    input  wire        m_bvalid,
    output wire        m_bready,

    //--------------------------------------------------------------------------
    // 观测（TB 用；判据观测点全部在 AXI 通道上）
    //--------------------------------------------------------------------------
    output reg  [31:0] cyc_cnt,               // 复位释放后的拍数
    output reg         first_ar_seen,         // 上游 AR 通道首笔
    output reg  [31:0] first_ar_addr,
    output reg  [31:0] ar_fire_count,
    output reg  [31:0] aw_fire_count,
    output reg         ar_fire_pulse,         // 单拍脉冲（TB 直方图用）
    output reg  [31:0] ar_fire_addr,
    output reg         aw_fire_pulse,
    output reg  [31:0] aw_fire_addr,
    output reg  [31:0] aw_fire_data,
    output reg  [3:0]  aw_fire_strb,
    output reg  [31:0] conf_ar_count,         // 命中 CONFREG 窗口的读
    output reg  [31:0] conf_aw_count,         // 命中 CONFREG 窗口的写
    output reg  [31:0] conf_rd_unknown_off,   // 窗口内未登记偏移读
    output reg  [31:0] conf_wr_unknown_off,   // 窗口内未登记偏移写
    output reg  [31:0] conf_ro_wr_count,      // 对只读寄存器（SWITCH/FREQ）的写
    output reg  [31:0] xact_collision_count,  // 误路由/并发在途（应为 0）
    // ---- C4 判据标志 ----
    output reg         led_wr_seen,           // 收到对 +0xF000 的写
    output reg         sw_rd_seen,            // 收到对 +0xF020 的读
    output reg         timer_rd_seen,         // 收到对 +0xE000 的读
    output reg         freq_rd_seen,          // 收到对 +0xF030 的读
    // ---- 诊断值 ----
    output reg  [31:0] led_wr_data, led_wr_cycle, led_wr_count,
    output reg  [31:0] seg_wr_data, seg_wr_count,
    output reg  [31:0] timer_wr_data, timer_wr_count,
    output reg  [31:0] timer_rd_data_first, timer_rd_data_last, timer_rd_count,
    output reg  [31:0] led_rd_data, led_rd_count,
    output reg  [31:0] seg_rd_data, seg_rd_count,
    output reg  [31:0] sw_rd_data,  sw_rd_count,
    output reg  [31:0] freq_rd_data, freq_rd_count,
    // ---- CONFREG 寄存器当前值（层次探针：证明行为模型在动）----
    output reg  [15:0] led_q,
    output reg  [31:0] seg_q,
    output reg  [31:0] timer_q
);

    //==========================================================================
    // 0. 常量与译码
    //==========================================================================
    localparam [1:0]  RESP_OKAY = 2'b00;
    localparam [15:0] OFF_LED   = 16'hF000;
    localparam [15:0] OFF_SEG   = 16'hF010;
    localparam [15:0] OFF_SW    = 16'hF020;
    localparam [15:0] OFF_FREQ  = 16'hF030;
    localparam [15:0] OFF_TIMER = 16'hE000;

    function in_conf;
        input [31:0] a;
        begin
            in_conf = (a >= CONF_BASE) && (a < CONF_LIMIT);
        end
    endfunction

    // 窗口内读（组合）：返回该偏移的寄存器值
    function [31:0] conf_read;
        input [31:0] a;
        begin
            case (a[15:0])
                OFF_LED:   conf_read = {16'h0000, led_q};
                OFF_SEG:   conf_read = seg_q;
                OFF_SW:    conf_read = {24'h000000, SWITCH_VAL};
                OFF_FREQ:  conf_read = FREQ_VAL;
                OFF_TIMER: conf_read = timer_q;
                default:   conf_read = 32'h0000_0000;
            endcase
        end
    endfunction

    //==========================================================================
    // 1. 自由运行计数器 + 时序观测
    //==========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) cyc_cnt <= 32'd0;
        else        cyc_cnt <= cyc_cnt + 32'd1;
    end

    //==========================================================================
    // 2. 上游地址译码（组合）+ 握手脉冲
    //==========================================================================
    wire ar_hit = in_conf(araddr);
    wire aw_hit = in_conf(awaddr);
    wire ar_fire = arvalid & arready;      // 上游读地址通道握手
    wire aw_fire = awvalid & awready;      // 上游写地址通道握手

    //==========================================================================
    // 3. 读通道：AR → R（本层自答） / 透传
    //==========================================================================
    reg        c_rd_busy;      // AR 已握手，R 未送完
    reg        c_rd_valid;
    reg [31:0] c_rd_addr;
    reg [3:0]  c_rd_len;       // AxLEN（beat 数 - 1）
    reg [4:0]  c_rd_cnt;
    reg [3:0]  c_rd_id;
    // ★ 读数据在 AR 握手拍寄存（confreg_syn 口径），并在下一笔 AR 之前保持
    reg [31:0] c_rd_data_q;
    reg        c_rd_hold;      // "R 总线归本层"保持位（R_STICKY=1 时保持到下一笔 AR）

    wire       c_ar_fire   = arvalid & ar_hit & ~c_rd_busy;
    wire       c_r_fire    = c_rd_valid & rready;
    wire       rd_sel_conf = R_STICKY ? (c_rd_busy | c_rd_hold) : c_rd_busy;

    assign arready   = ar_hit ? ~c_rd_busy : m_arready;
    assign rvalid    = rd_sel_conf ? c_rd_valid : m_rvalid;
    // ★ DDR_R_NONHOLD=1：下游（DDR3/XIP）RDATA 只在 `m_rvalid & m_rready` 同拍有效；
    //   其余拍呈现 0（严格 AXI4 / MIG 口径）。默认 0 = 原样透传（历史行为）。
    assign rdata     = rd_sel_conf ? c_rd_data_q
                                   : ((DDR_R_NONHOLD != 0)
                                      ? ((m_rvalid & m_rready) ? m_rdata : 32'h0000_0000)
                                      : m_rdata);
    assign rresp     = rd_sel_conf ? RESP_OKAY : m_rresp;
    assign rlast     = rd_sel_conf ? (c_rd_cnt[3:0] == c_rd_len) : m_rlast;
    assign rid       = rd_sel_conf ? c_rd_id : m_rid;

    assign m_arvalid = arvalid & ~ar_hit;
    assign m_arid    = arid;
    assign m_araddr  = araddr;
    assign m_arlen   = arlen;
    assign m_arsize  = arsize;
    assign m_arburst = arburst;
    assign m_arlock  = arlock;
    assign m_arcache = arcache;
    assign m_arprot  = arprot;
    assign m_rready  = rready & ~rd_sel_conf;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            c_rd_busy  <= 1'b0;
            c_rd_valid <= 1'b0;
            c_rd_addr  <= 32'h0;
            c_rd_len   <= 4'h0;
            c_rd_cnt   <= 5'h0;
            c_rd_id    <= 4'h0;
            c_rd_data_q<= 32'h0;
            c_rd_hold  <= 1'b0;
        end else begin
            // ★ 每一笔 AR 都重新决定 R 总线归属：命中本层 ⇒ 保持到下一笔 AR 之前；
            //   否则立刻交还下游（下游的 rvalid 只可能在该 AR 之后出现）。
            if (ar_fire) begin
                c_rd_hold <= ar_hit;
                if (ar_hit) c_rd_data_q <= conf_read(araddr);   // confreg_syn 口径：AR 拍寄存
            end
            if (c_ar_fire) begin
                c_rd_busy  <= 1'b1;
                c_rd_valid <= 1'b1;          // 与 sim_mem_model 同口径：AR 后下一拍起送 R
                c_rd_addr  <= araddr;
                c_rd_len   <= arlen;
                c_rd_cnt   <= 5'd0;
                c_rd_id    <= arid;
            end else if (c_r_fire) begin
                if (c_rd_cnt[3:0] == c_rd_len) begin
                    c_rd_busy  <= 1'b0;
                    c_rd_valid <= 1'b0;
                end else begin
                    c_rd_cnt  <= c_rd_cnt + 5'd1;
                    c_rd_addr <= c_rd_addr + 32'd4;
                    c_rd_data_q <= conf_read(c_rd_addr + 32'd4);  // 多 beat：下一 beat 数据
                end
            end
        end
    end

    //==========================================================================
    // 4. 写通道：AW → W → B（本层自答） / 透传
    //==========================================================================
    reg        c_wr_busy;
    reg [31:0] c_wr_addr;
    reg [3:0]  c_wr_len;
    reg [4:0]  c_wr_cnt;
    reg [3:0]  c_wr_id;
    reg        c_b_valid;

    wire       c_aw_fire      = awvalid & aw_hit & ~c_wr_busy;
    // 防御：若主机在 AW 握手**同拍**就给 W（本核 FSM 不会，见 axi_master_ctrl ST_AW→ST_W），
    //   本拍也必须把 W 判给 CONF 而不是漏给下游。
    wire       aw_route_conf  = awvalid & aw_hit & ~c_wr_busy;
    wire       wr_sel_conf    = c_wr_busy | aw_route_conf;
    wire       c_w_fire       = c_wr_busy & ~c_b_valid & wvalid;
    wire       c_b_fire       = c_b_valid & bready;

    assign awready   = aw_hit ? ~c_wr_busy : m_awready;
    assign wready    = c_wr_busy ? ~c_b_valid : (aw_route_conf ? 1'b0 : m_wready);
    assign bvalid    = c_b_valid | m_bvalid;
    assign bresp     = c_b_valid ? RESP_OKAY : m_bresp;
    assign bid       = c_b_valid ? c_wr_id : m_bid;

    assign m_awvalid = awvalid & ~aw_hit;
    assign m_awid    = awid;
    assign m_awaddr  = awaddr;
    assign m_awlen   = awlen;
    assign m_awsize  = awsize;
    assign m_awburst = awburst;
    assign m_awlock  = awlock;
    assign m_awcache = awcache;
    assign m_awprot  = awprot;

    assign m_wvalid  = wvalid & ~wr_sel_conf;
    assign m_wid     = wid;
    assign m_wdata   = wdata;
    assign m_wstrb   = wstrb;
    assign m_wlast   = wlast;

    assign m_bready  = bready & ~c_b_valid;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            c_wr_busy <= 1'b0;
            c_wr_addr <= 32'h0;
            c_wr_len  <= 4'h0;
            c_wr_cnt  <= 5'h0;
            c_wr_id   <= 4'h0;
            c_b_valid <= 1'b0;
        end else begin
            if (c_aw_fire) begin
                c_wr_busy <= 1'b1;
                c_wr_addr <= awaddr;
                c_wr_len  <= awlen;
                c_wr_cnt  <= 5'd0;
                c_wr_id   <= awid;
            end
            if (c_w_fire) begin
                if (c_wr_cnt[3:0] == c_wr_len) begin
                    c_b_valid <= 1'b1;
                end else begin
                    c_wr_cnt  <= c_wr_cnt + 5'd1;
                    c_wr_addr <= c_wr_addr + 32'd4;
                end
            end
            if (c_b_fire) begin
                c_b_valid <= 1'b0;
                c_wr_busy <= 1'b0;
            end
        end
    end

    //==========================================================================
    // 5. CONFREG 寄存器本体（时序）
    //==========================================================================
    wire wr_is_led   = c_w_fire && (c_wr_addr[15:0] == OFF_LED);
    wire wr_is_seg   = c_w_fire && (c_wr_addr[15:0] == OFF_SEG);
    wire wr_is_sw    = c_w_fire && (c_wr_addr[15:0] == OFF_SW);
    wire wr_is_freq  = c_w_fire && (c_wr_addr[15:0] == OFF_FREQ);
    wire wr_is_timer = c_w_fire && (c_wr_addr[15:0] == OFF_TIMER);

    // TIMER：自由运行；写任意值即清零（清零当拍为 0，下一拍起 +1）
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)               timer_q <= 32'd0;
        else if (wr_is_timer)     timer_q <= 32'd0;
        else                      timer_q <= timer_q + 32'd1;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            led_q <= 16'h0000;
            seg_q <= 32'h0000_0000;
        end else if (c_w_fire) begin
            case (c_wr_addr[15:0])
                OFF_LED: begin
                    if (wstrb[0]) led_q[ 7: 0] <= wdata[ 7: 0];
                    if (wstrb[1]) led_q[15: 8] <= wdata[15: 8];
                end
                OFF_SEG: begin
                    if (wstrb[0]) seg_q[ 7: 0] <= wdata[ 7: 0];
                    if (wstrb[1]) seg_q[15: 8] <= wdata[15: 8];
                    if (wstrb[2]) seg_q[23:16] <= wdata[23:16];
                    if (wstrb[3]) seg_q[31:24] <= wdata[31:24];
                end
                default: ;                       // SWITCH/FREQ 只读 ⇒ 不改
            endcase
        end
    end

    //==========================================================================
    // 6. 观测与轨迹
    //==========================================================================
    reg [31:0] ar_trace_addr [0:TRACE_DEPTH-1];
    reg [31:0] ar_trace_cyc  [0:TRACE_DEPTH-1];
    reg [31:0] aw_trace_addr [0:TRACE_DEPTH-1];
    reg [31:0] aw_trace_data [0:TRACE_DEPTH-1];
    reg [3:0]  aw_trace_strb [0:TRACE_DEPTH-1];
    reg [31:0] aw_trace_cyc  [0:TRACE_DEPTH-1];
    integer    ar_trace_n, aw_trace_n;

    // 误路由/并发在途检测（正常恒 0；非 0 ⇒ 本层不可信 ⇒ TB 判 FAIL）
    wire collision = (c_rd_busy & c_wr_busy) |
                     (rd_sel_conf & m_rvalid) |
                     (c_b_valid & m_bvalid) |
                     (c_rd_busy & m_arvalid & m_arready) |
                     (c_wr_busy & m_awvalid & m_awready);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            first_ar_seen       <= 1'b0;
            first_ar_addr       <= 32'h0;
            ar_fire_count       <= 32'd0;
            aw_fire_count       <= 32'd0;
            ar_fire_pulse       <= 1'b0;
            aw_fire_pulse       <= 1'b0;
            ar_fire_addr        <= 32'h0;
            aw_fire_addr        <= 32'h0;
            aw_fire_data        <= 32'h0;
            aw_fire_strb        <= 4'h0;
            conf_ar_count       <= 32'd0;
            conf_aw_count       <= 32'd0;
            conf_rd_unknown_off <= 32'd0;
            conf_wr_unknown_off <= 32'd0;
            conf_ro_wr_count    <= 32'd0;
            xact_collision_count<= 32'd0;
            led_wr_seen         <= 1'b0;
            sw_rd_seen          <= 1'b0;
            timer_rd_seen       <= 1'b0;
            freq_rd_seen        <= 1'b0;
            led_wr_data         <= 32'h0;
            led_wr_cycle        <= 32'h0;
            led_wr_count        <= 32'd0;
            seg_wr_data         <= 32'h0;
            seg_wr_count        <= 32'd0;
            timer_wr_data       <= 32'h0;
            timer_wr_count      <= 32'd0;
            timer_rd_data_first <= 32'h0;
            timer_rd_data_last  <= 32'h0;
            timer_rd_count      <= 32'd0;
            led_rd_data         <= 32'h0;
            led_rd_count        <= 32'd0;
            seg_rd_data         <= 32'h0;
            seg_rd_count        <= 32'd0;
            sw_rd_data          <= 32'h0;
            sw_rd_count         <= 32'd0;
            freq_rd_data        <= 32'h0;
            freq_rd_count       <= 32'd0;
            ar_trace_n          <= 0;
            aw_trace_n          <= 0;
        end else begin
            ar_fire_pulse <= ar_fire;
            aw_fire_pulse <= aw_fire;

            if (collision) xact_collision_count <= xact_collision_count + 32'd1;

            //------------------------------------------------------------------
            // 上游 AR 通道（C1 观测点）
            //------------------------------------------------------------------
            if (ar_fire) begin
                ar_fire_count <= ar_fire_count + 32'd1;
                ar_fire_addr  <= araddr;
                if (!first_ar_seen) begin
                    first_ar_seen <= 1'b1;
                    first_ar_addr <= araddr;
                end
                if (ar_trace_n < TRACE_DEPTH) begin
                    ar_trace_addr[ar_trace_n] <= araddr;
                    ar_trace_cyc [ar_trace_n] <= cyc_cnt;
                    ar_trace_n <= ar_trace_n + 1;
                end
                if (ar_hit) begin
                    conf_ar_count <= conf_ar_count + 32'd1;
                    case (araddr[15:0])
                        OFF_LED:   begin led_rd_count  <= led_rd_count  + 32'd1;
                                         led_rd_data   <= {16'h0000, led_q}; end
                        OFF_SEG:   begin seg_rd_count  <= seg_rd_count  + 32'd1;
                                         seg_rd_data   <= seg_q; end
                        OFF_SW:    begin sw_rd_seen    <= 1'b1;
                                         sw_rd_count   <= sw_rd_count   + 32'd1;
                                         sw_rd_data    <= {24'h000000, SWITCH_VAL}; end
                        OFF_FREQ:  begin freq_rd_seen  <= 1'b1;
                                         freq_rd_count <= freq_rd_count + 32'd1;
                                         freq_rd_data  <= FREQ_VAL; end
                        OFF_TIMER: begin timer_rd_seen <= 1'b1;
                                         timer_rd_count<= timer_rd_count+ 32'd1;
                                         timer_rd_data_last <= timer_q;
                                         if (timer_rd_count == 32'd0)
                                             timer_rd_data_first <= timer_q; end
                        default:   conf_rd_unknown_off <= conf_rd_unknown_off + 32'd1;
                    endcase
                end
            end

            //------------------------------------------------------------------
            // 上游 AW 通道（C4 观测点）
            //------------------------------------------------------------------
            if (aw_fire) begin
                aw_fire_count <= aw_fire_count + 32'd1;
                aw_fire_addr  <= awaddr;
                // 注意：AW 拍 W 可能尚未到 ⇒ 轨迹条目的 data/strb 先置 0，
                //       待上游 W 通道握手拍（无论归本层还是下游）回填真实值。
                if (aw_trace_n < TRACE_DEPTH) begin
                    aw_trace_addr[aw_trace_n] <= awaddr;
                    aw_trace_data[aw_trace_n] <= 32'h0;
                    aw_trace_strb[aw_trace_n] <= 4'h0;
                    aw_trace_cyc [aw_trace_n] <= cyc_cnt;
                    aw_trace_n <= aw_trace_n + 1;
                end
                if (aw_hit) conf_aw_count <= conf_aw_count + 32'd1;
            end

            // 上游 W 通道握手拍：记录真实写数据/字节使能（CONF 与下游两路都覆盖）
            if (wvalid & wready) begin
                if (aw_trace_n > 0) begin
                    aw_trace_data[aw_trace_n-1] <= wdata;
                    aw_trace_strb[aw_trace_n-1] <= wstrb;
                end
                aw_fire_data <= wdata;
                aw_fire_strb <= wstrb;
            end

            //------------------------------------------------------------------
            // CONFREG 写命中（数据在 W 拍有效）
            //------------------------------------------------------------------
            if (wr_is_led) begin
                led_wr_seen  <= 1'b1;
                led_wr_count <= led_wr_count + 32'd1;
                led_wr_data  <= wdata;
                led_wr_cycle <= cyc_cnt;
            end
            if (wr_is_seg) begin
                seg_wr_count <= seg_wr_count + 32'd1;
                seg_wr_data  <= wdata;
            end
            if (wr_is_timer) begin
                timer_wr_count <= timer_wr_count + 32'd1;
                timer_wr_data  <= wdata;
            end
            if (wr_is_sw || wr_is_freq) conf_ro_wr_count <= conf_ro_wr_count + 32'd1;
            if (c_w_fire && (c_wr_addr[15:0] != OFF_LED) && (c_wr_addr[15:0] != OFF_SEG) &&
                            (c_wr_addr[15:0] != OFF_SW)  && (c_wr_addr[15:0] != OFF_FREQ) &&
                            (c_wr_addr[15:0] != OFF_TIMER))
                conf_wr_unknown_off <= conf_wr_unknown_off + 32'd1;
        end
    end

    //==========================================================================
    // 7. 参数自检（不做兜底 PASS；仅打印配置，供日志留档）
    //==========================================================================
    initial begin
        $display("[confreg_axi_filter] CONFREG 窗口 = 0x%08h..0x%08h（开区间）；SWITCH=0x%02h；FREQ=%0d",
                 CONF_BASE, CONF_LIMIT, SWITCH_VAL, FREQ_VAL);
        if (CONF_LIMIT <= CONF_BASE) begin
            $display("[confreg_axi_filter] FAIL: CONF_LIMIT <= CONF_BASE（窗口非法）");
            $finish;
        end
    end

endmodule
