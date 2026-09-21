//==============================================================================
// sw/m5_board/tb/tb_m5_board.sv —— M5 上板程序的**核级仿真验证** TB（上板前）
//==============================================================================
// 归属 : sw/m5_board/tb/（本任务唯一可写目录；rtl/**、sim/** 一律只读）
// 顶层 : tb_m5_board（`-s tb_m5_board`）
//
// 结构 :
//   tb_m5_board
//     ├── u_dut  : rtl/top/core_top.v   （48 端口逐字例化；RTL 冻结、只读）
//     ├── u_conf : sw/m5_board/tb/confreg_axi_filter.v
//     │            （AXI 地址过滤 + 上板 CONFREG 行为模型：LED/数码管/SWITCH/FREQ/TIMER）
//     └── u_mem  : sim/tb/sim_mem_model.sv（XIP 1 MiB + DDR3 + UART 0x1FE001E0 捕获）
//   通路 : core_top ──AXI4──► u_conf ──AXI4（原样透传）──► u_mem
//
// 时钟/复位（上板口径）:
//   · 周期 30.303 ns（半周期 15.1515 ns ⇒ 33.0 MHz；与 runbook "33 MHz 同域"一致）
//   · aresetn 低有效：保持 RESET_CYCLES 拍后在**负沿**释放
//   · intrpt = 0、break_point = 0、infor_flag = 0、reg_num = 0（程序不用中断）
//
// 判据（fail-closed：**全部满足**才打印唯一 PASS 锚点；任一不满足 ⇒ 打印
//       `TB_M5_BOARD: FAIL <条目>` + `$fatal`，vvp 退出码 ≠ 0）:
//   C0（测试台自检，附加但必需）PROG_HEX 载入无错且有非零字；UART 捕获队列不溢出；
//      过滤层无"误路由/并发在途"计数（xact_collision_count == 0）
//   C1 首笔 AXI 读地址 == 0x1C00_0000（观测点 = 上游 AR 通道；复位取指口径）
//   C2 UART 捕获序列中出现子串 "RV32GC-M5 board test"（与 m5_board.S 的 .rodata 逐字节一致）
//   C3 UART 捕获序列中出现子串 "RESULT: RV32GC-M5-OK"
//   C4 捕获到对 0x1FD0_F000（LED）的写，且至少一次对 +0xF020（switch）、+0xE000（TIMER）、
//      +0xF030（FREQ）的读 —— 观测点全部在 AXI 通道上（confreg_axi_filter 的 AR/AW 握手）
//   C5 超时保护：TIMEOUT_CYCLES 拍内未同时命中 C2/C3 ⇒ FAIL
//
// ★ 本 TB **不打印任何兜底 PASS**：唯一 PASS 行是 `TB_M5_BOARD: PASS`，且只在 C0–C5
//   全部通过时打印一次；FAIL 路径的诊断文字一律避开 "PASS" 字样。
//==============================================================================
`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"

module tb_m5_board #(
    // ---- 被测程序映像（-P tb_m5_board.PROG_HEX=\"...\" 覆盖）----
    parameter [8*512-1:0]  PROG_HEX       = "sw/m5_board/out/m5_board.hex",
    // ---- 期望子串（与 m5_board.S 的 .rodata 逐字节一致）----
    parameter [8*32-1:0]   EXPECT_C2      = "RV32GC-M5 board test",
    parameter [8*32-1:0]   EXPECT_C3      = "RESULT: RV32GC-M5-OK",
    // 结果行前缀：命中它 + 宽限 GRACE_BYTES 字节后，OK/BAD 必已确定 ⇒ 可提前收尾
    //   （★ 不放宽任何判据：C3 仍要求完整子串 "RESULT: RV32GC-M5-OK" 出现；
    //     程序输出格式为 前缀+"OK"/"BAD"+CRLF ⇒ 宽限 4 字节即可判定完毕）
    parameter [8*32-1:0]   EXPECT_C3_PFX   = "RESULT: RV32GC-M5-",
    parameter integer      GRACE_BYTES     = 4,
    // ---- 时钟/复位（上板 33 MHz：半周期 15.1515 ns ⇒ 周期 30.303 ns）----
    parameter real         CLK_HALF_NS    = 15.1515,
    parameter integer      RESET_CYCLES   = 20,
    // ---- 判据参数 ----
    parameter integer      TIMEOUT_CYCLES = 4000000,
    parameter integer      PROGRESS_EVERY = 100000,
    parameter integer      TRACE_PRINT_N  = 48,          // 轨迹打印条数
    parameter integer      UART_PRINT_MAX = 4096,        // UART 捕获打印上限（字节）
    // ---- CONFREG 行为参数 ----
    parameter [7:0]        SWITCH_VAL     = 8'hA5,
    parameter [31:0]       FREQ_VAL       = 32'd33000000,
    // ---- sim_mem_model 参数（★ 队列必须够深：程序每轮主循环打印约 700 字节）----
    parameter integer      UART_QUEUE_DEPTH = 65536,
    parameter integer      SIM_TRACE_DEPTH  = 2048,
    // ---- 过滤层 R 数据保持（1 = 上板 confreg_syn 口径；0 = A/B 对照，见 tb/README-tb.md）----
    parameter integer      R_STICKY         = 1,
    // ---- ★ 下游（DDR3/XIP 侧）R 数据保持口径（透传给 confreg_axi_filter）----
    //   0（默认）= 原样透传（历史行为：sim_mem_model 在握手后仍把数据留在总线上）；
    //   1        = **非保持型 R 通道模型**（严格 AXI4 / 真实 MIG 口径：RDATA 只在
    //              R 握手拍 `m_rvalid & m_rready` 有效，其余拍呈现 0）—— 用于复现
    //              M5 上板"uncached 数据读在 R 握手后第 2 拍采样 ⇒ .data/.bss 读回垃圾"。
    //   只改从设备行为模型，**不改 C0–C5 判据语义**。
    parameter integer      DDR_R_NONHOLD    = 0,
    // ---- 逐拍 R 通道探针（>0 = 对**首笔 CONFREG 读**打印这么多拍的 R 通道/M 级采样）----
    //   纯诊断（层次引用），不参与判据；用于给"核在 R 握手后第几拍取 rdata"留证据。
    parameter integer      RD_TRACE_WINDOW  = 0
) ();

    localparam integer SLEN = 32;                 // 期望串参数宽度（字节）
    localparam [31:0]  RESET_PC_EXP = `RV32GC_RESET_PC;   // 0x1C00_0000

    //==========================================================================
    // 0. 时钟 / 复位
    //==========================================================================
    reg clk;
    reg aresetn;

    initial clk = 1'b0;
    always #(CLK_HALF_NS) clk = ~clk;

    //==========================================================================
    // 1. 上游 AXI4 连线（core_top ↔ 过滤层）
    //==========================================================================
    wire [3:0]  arid;    wire [31:0] araddr;  wire [3:0]  arlen;
    wire [2:0]  arsize;  wire [1:0]  arburst; wire [1:0]  arlock;
    wire [3:0]  arcache; wire [2:0]  arprot;  wire        arvalid; wire arready;
    wire [3:0]  rid;     wire [31:0] rdata;   wire [1:0]  rresp;
    wire        rlast;   wire        rvalid;  wire        rready;
    wire [3:0]  awid;    wire [31:0] awaddr;  wire [3:0]  awlen;
    wire [2:0]  awsize;  wire [1:0]  awburst; wire [1:0]  awlock;
    wire [3:0]  awcache; wire [2:0]  awprot;  wire        awvalid; wire awready;
    wire [3:0]  wid;     wire [31:0] wdata;   wire [3:0]  wstrb;
    wire        wlast;   wire        wvalid;  wire        wready;
    wire [3:0]  bid;     wire [1:0]  bresp;   wire        bvalid; wire bready;

    // 调试组（平台契约，恒 0 输入 / 仅观测输出）
    wire        ws_valid;
    wire [31:0] rf_rdata;
    wire [31:0] debug0_wb_pc;
    wire [3:0]  debug0_wb_rf_wen;
    wire [4:0]  debug0_wb_rf_wnum;
    wire [31:0] debug0_wb_rf_wdata;

    //==========================================================================
    // 2. DUT：core_top（48 端口逐字契约；rtl 只读）
    //==========================================================================
    core_top u_dut (
        .aclk              (clk),
        .intrpt            (8'h00),
        .aresetn           (aresetn),

        .arid              (arid),
        .araddr            (araddr),
        .arlen             (arlen),
        .arsize            (arsize),
        .arburst           (arburst),
        .arlock            (arlock),
        .arcache           (arcache),
        .arprot            (arprot),
        .arvalid           (arvalid),
        .arready           (arready),

        .rid               (rid),
        .rdata             (rdata),
        .rresp             (rresp),
        .rlast             (rlast),
        .rvalid            (rvalid),
        .rready            (rready),

        .awid              (awid),
        .awaddr            (awaddr),
        .awlen             (awlen),
        .awsize            (awsize),
        .awburst           (awburst),
        .awlock            (awlock),
        .awcache           (awcache),
        .awprot            (awprot),
        .awvalid           (awvalid),
        .awready           (awready),

        .wid               (wid),
        .wdata             (wdata),
        .wstrb             (wstrb),
        .wlast             (wlast),
        .wvalid            (wvalid),
        .wready            (wready),

        .bid               (bid),
        .bresp             (bresp),
        .bvalid            (bvalid),
        .bready            (bready),

        .ws_valid          (ws_valid),
        .break_point       (1'b0),
        .infor_flag        (1'b0),
        .reg_num           (5'd0),
        .rf_rdata          (rf_rdata),
        .debug0_wb_pc      (debug0_wb_pc),
        .debug0_wb_rf_wen  (debug0_wb_rf_wen),
        .debug0_wb_rf_wnum (debug0_wb_rf_wnum),
        .debug0_wb_rf_wdata(debug0_wb_rf_wdata)
    );

    //==========================================================================
    // 3. 过滤层（CONFREG 自答；其余透传）+ 内存模型
    //==========================================================================
    // 中间 AXI4（过滤层 → 内存模型）
    wire [3:0]  m_arid;   wire [31:0] m_araddr; wire [3:0]  m_arlen;
    wire [2:0]  m_arsize; wire [1:0]  m_arburst;wire [1:0]  m_arlock;
    wire [3:0]  m_arcache;wire [2:0]  m_arprot; wire        m_arvalid; wire m_arready;
    wire [3:0]  m_rid;    wire [31:0] m_rdata;  wire [1:0]  m_rresp;
    wire        m_rlast;  wire        m_rvalid; wire        m_rready;
    wire [3:0]  m_awid;   wire [31:0] m_awaddr; wire [3:0]  m_awlen;
    wire [2:0]  m_awsize; wire [1:0]  m_awburst;wire [1:0]  m_awlock;
    wire [3:0]  m_awcache;wire [2:0]  m_awprot; wire        m_awvalid; wire m_awready;
    wire [3:0]  m_wid;    wire [31:0] m_wdata;  wire [3:0]  m_wstrb;
    wire        m_wlast;  wire        m_wvalid; wire        m_wready;
    wire [3:0]  m_bid;    wire [1:0]  m_bresp;  wire        m_bvalid; wire m_bready;

    // 过滤层观测
    wire [31:0] c_cyc, c_first_ar_addr, c_ar_cnt, c_aw_cnt;
    wire        c_first_ar_seen, c_ar_pulse, c_aw_pulse;
    wire [31:0] c_ar_addr, c_aw_addr, c_aw_data;
    wire [3:0]  c_aw_strb;
    wire [31:0] c_conf_ar, c_conf_aw, c_conf_rd_un, c_conf_wr_un, c_conf_ro_wr, c_collision;
    wire        c_led_wr, c_sw_rd, c_timer_rd, c_freq_rd;
    wire [31:0] c_led_wr_data, c_led_wr_cycle, c_led_wr_count;
    wire [31:0] c_seg_wr_data, c_seg_wr_count;
    wire [31:0] c_timer_wr_data, c_timer_wr_count;
    wire [31:0] c_timer_rd_first, c_timer_rd_last, c_timer_rd_count;
    wire [31:0] c_led_rd_data, c_led_rd_count;
    wire [31:0] c_seg_rd_data, c_seg_rd_count;
    wire [31:0] c_sw_rd_data,  c_sw_rd_count;
    wire [31:0] c_freq_rd_data, c_freq_rd_count;
    wire [15:0] c_led_q;
    wire [31:0] c_seg_q, c_timer_q;

    confreg_axi_filter #(
        .SWITCH_VAL  (SWITCH_VAL),
        .FREQ_VAL    (FREQ_VAL),
        .TRACE_DEPTH (SIM_TRACE_DEPTH),
        .R_STICKY    (R_STICKY),
        .DDR_R_NONHOLD (DDR_R_NONHOLD)
    ) u_conf (
        .clk (clk), .rst_n (aresetn),

        .arid (arid), .araddr (araddr), .arlen (arlen), .arsize (arsize),
        .arburst (arburst), .arlock (arlock), .arcache (arcache), .arprot (arprot),
        .arvalid (arvalid), .arready (arready),
        .rid (rid), .rdata (rdata), .rresp (rresp), .rlast (rlast),
        .rvalid (rvalid), .rready (rready),

        .awid (awid), .awaddr (awaddr), .awlen (awlen), .awsize (awsize),
        .awburst (awburst), .awlock (awlock), .awcache (awcache), .awprot (awprot),
        .awvalid (awvalid), .awready (awready),
        .wid (wid), .wdata (wdata), .wstrb (wstrb), .wlast (wlast),
        .wvalid (wvalid), .wready (wready),
        .bid (bid), .bresp (bresp), .bvalid (bvalid), .bready (bready),

        .m_arid (m_arid), .m_araddr (m_araddr), .m_arlen (m_arlen), .m_arsize (m_arsize),
        .m_arburst (m_arburst), .m_arlock (m_arlock), .m_arcache (m_arcache),
        .m_arprot (m_arprot), .m_arvalid (m_arvalid), .m_arready (m_arready),
        .m_rid (m_rid), .m_rdata (m_rdata), .m_rresp (m_rresp), .m_rlast (m_rlast),
        .m_rvalid (m_rvalid), .m_rready (m_rready),

        .m_awid (m_awid), .m_awaddr (m_awaddr), .m_awlen (m_awlen), .m_awsize (m_awsize),
        .m_awburst (m_awburst), .m_awlock (m_awlock), .m_awcache (m_awcache),
        .m_awprot (m_awprot), .m_awvalid (m_awvalid), .m_awready (m_awready),
        .m_wid (m_wid), .m_wdata (m_wdata), .m_wstrb (m_wstrb), .m_wlast (m_wlast),
        .m_wvalid (m_wvalid), .m_wready (m_wready),
        .m_bid (m_bid), .m_bresp (m_bresp), .m_bvalid (m_bvalid), .m_bready (m_bready),

        .cyc_cnt (c_cyc),
        .first_ar_seen (c_first_ar_seen), .first_ar_addr (c_first_ar_addr),
        .ar_fire_count (c_ar_cnt), .aw_fire_count (c_aw_cnt),
        .ar_fire_pulse (c_ar_pulse), .ar_fire_addr (c_ar_addr),
        .aw_fire_pulse (c_aw_pulse), .aw_fire_addr (c_aw_addr),
        .aw_fire_data (c_aw_data), .aw_fire_strb (c_aw_strb),
        .conf_ar_count (c_conf_ar), .conf_aw_count (c_conf_aw),
        .conf_rd_unknown_off (c_conf_rd_un), .conf_wr_unknown_off (c_conf_wr_un),
        .conf_ro_wr_count (c_conf_ro_wr), .xact_collision_count (c_collision),
        .led_wr_seen (c_led_wr), .sw_rd_seen (c_sw_rd),
        .timer_rd_seen (c_timer_rd), .freq_rd_seen (c_freq_rd),
        .led_wr_data (c_led_wr_data), .led_wr_cycle (c_led_wr_cycle), .led_wr_count (c_led_wr_count),
        .seg_wr_data (c_seg_wr_data), .seg_wr_count (c_seg_wr_count),
        .timer_wr_data (c_timer_wr_data), .timer_wr_count (c_timer_wr_count),
        .timer_rd_data_first (c_timer_rd_first), .timer_rd_data_last (c_timer_rd_last),
        .timer_rd_count (c_timer_rd_count),
        .led_rd_data (c_led_rd_data), .led_rd_count (c_led_rd_count),
        .seg_rd_data (c_seg_rd_data), .seg_rd_count (c_seg_rd_count),
        .sw_rd_data  (c_sw_rd_data),  .sw_rd_count (c_sw_rd_count),
        .freq_rd_data (c_freq_rd_data), .freq_rd_count (c_freq_rd_count),
        .led_q (c_led_q), .seg_q (c_seg_q), .timer_q (c_timer_q)
    );

    // UART 捕获输出
    wire [7:0]  uart_char;
    wire        uart_char_valid;
    wire [31:0] uart_tx_count;
    wire        uart_overflow;
    wire [31:0] uart_bad_strb_count;

    sim_mem_model #(
        .READ_LAT_DLY       (0),
        .UART_QUEUE_DEPTH   (UART_QUEUE_DEPTH)
    ) u_mem (
        .clk (clk), .rst_n (aresetn),

        .arid (m_arid), .araddr (m_araddr), .arlen (m_arlen), .arsize (m_arsize),
        .arburst (m_arburst), .arlock (m_arlock), .arcache (m_arcache), .arprot (m_arprot),
        .arvalid (m_arvalid), .arready (m_arready),
        .rid (m_rid), .rdata (m_rdata), .rresp (m_rresp), .rlast (m_rlast),
        .rvalid (m_rvalid), .rready (m_rready),

        .awid (m_awid), .awaddr (m_awaddr), .awlen (m_awlen), .awsize (m_awsize),
        .awburst (m_awburst), .awlock (m_awlock), .awcache (m_awcache), .awprot (m_awprot),
        .awvalid (m_awvalid), .awready (m_awready),
        .wid (m_wid), .wdata (m_wdata), .wstrb (m_wstrb), .wlast (m_wlast),
        .wvalid (m_wvalid), .wready (m_wready),
        .bid (m_bid), .bresp (m_bresp), .bvalid (m_bvalid), .bready (m_bready),

        .uart_char (uart_char), .uart_char_valid (uart_char_valid),
        .uart_tx_count (uart_tx_count), .uart_overflow (uart_overflow),
        .uart_bad_strb_count (uart_bad_strb_count)
    );

    //==========================================================================
    // 4. 工具函数：字符串/分类/打印
    //==========================================================================
    // 参数串有效字节数（去两端 0；兼容左/右对齐）
    function integer str_nbytes;
        input [8*SLEN-1:0] s;
        integer i, first, last;
        begin
            first = -1; last = -1;
            for (i = 0; i < SLEN; i = i + 1)
                if (s[8*i +: 8] != 8'h00) begin
                    if (first < 0) first = i;
                    last = i;
                end
            str_nbytes = (first < 0) ? 0 : (last - first + 1);
        end
    endfunction

    // 参数串第 i 个字符（i=0 = 串首）
    // ★ iverilog 把字符串字面量**左对齐**放进宽向量：串首在**最高**字节 ⇒ 字符顺序
    //   是字节下标从 last 递减到 first（大端序即串序）。
    function [7:0] str_byte;
        input [8*SLEN-1:0] s;
        input integer i;
        integer j, first, last;
        begin
            first = -1; last = -1;
            for (j = 0; j < SLEN; j = j + 1)
                if (s[8*j +: 8] != 8'h00) begin
                    if (first < 0) first = j;
                    last = j;
                end
            str_byte = (first < 0) ? 8'h00 : s[8*(last - i) +: 8];
        end
    endfunction

    // AXI 地址区域分类
    localparam integer R_XIP = 0, R_DDR3 = 1, R_CONF = 2, R_UART = 3, R_FE = 4, R_OTH = 5;
    localparam integer NREGION = 6;
    function integer region_of;
        input [31:0] a;
        begin
            if      ((a & 32'hFFF00000) == 32'h1C000000) region_of = R_XIP;   // SPI XIP 主窗口 1 MiB
            else if (a < 32'h08000000)                   region_of = R_DDR3;  // DDR3
            else if ((a & 32'hFFFF0000) == 32'h1FD00000) region_of = R_CONF;  // CONFREG 窗口
            else if ((a & 32'hFFFFF000) == 32'h1FE00000) region_of = R_UART;  // UART 4 KiB 页
            else if ((a & 32'hFFF00000) == 32'h1FE00000) region_of = R_FE;    // 0x1FE 段其它（XIP 别名等）
            else                                         region_of = R_OTH;
        end
    endfunction

    function [8*16-1:0] region_name;
        input integer r;
        begin
            case (r)
                R_XIP:   region_name = "XIP(1C000000)   ";
                R_DDR3:  region_name = "DDR3            ";
                R_CONF:  region_name = "CONFREG(1FD0)   ";
                R_UART:  region_name = "UART-page       ";
                R_FE:    region_name = "0x1FE-other     ";
                default: region_name = "UNMAPPED        ";
            endcase
        end
    endfunction

    task print_char_esc;
        input [7:0] b;
        begin
            if      (b == 8'h0D)                  $write("\\r");
            else if (b == 8'h0A)                  $write("\\n");
            else if ((b >= 8'h20) && (b < 8'h7F)) $write("%c", b);
            else                                  $write("<%02h>", b);
        end
    endtask

    // 打印参数串的**有效**字节（不打印右对齐填充；避免 %0s 对齐歧义）
    task print_pstr;
        input [8*SLEN-1:0] s;
        integer n, k;
        begin
            n = str_nbytes(s);
            for (k = 0; k < n; k = k + 1) $write("%c", str_byte(s, k));
        end
    endtask

    //==========================================================================
    // 5. UART 子串匹配（滚动窗口，逐字节增量；含命中拍/命中字节序号）
    //==========================================================================
    localparam integer WIN = 32;
    reg [7:0]  rx_win [0:WIN-1];
    reg [31:0] rx_total;
    reg        rx_push_q;
    reg        c2_hit, c3_hit;
    reg        c3p_hit;                       // 结果行前缀命中（仅用于"提前收尾"）
    reg [31:0] c2_cycle, c3_cycle, c2_byte, c3_byte, c3p_byte;
    integer    wi;

    // 提前收尾：① C2/C3 都命中；或 ② 结果行前缀命中且宽限字节已到（OK/BAD 必已确定）
    wire c3_decided = c3p_hit && (rx_total >= (c3p_byte + GRACE_BYTES));
    wire stop_early = (c2_hit && c3_hit) || (c2_hit && c3_decided);

    reg [31:0] gcyc;                     // 复位释放后全局拍数
    always @(posedge clk or negedge aresetn) begin
        if (!aresetn) gcyc <= 32'd0;
        else          gcyc <= gcyc + 32'd1;
    end

    function match_tail;
        input [8*SLEN-1:0] needle;
        integer m, j;
        reg ok;
        begin
            m  = str_nbytes(needle);
            ok = (m > 0) && (rx_total >= m);
            for (j = 0; j < m; j = j + 1)
                if (rx_win[m-1-j] !== str_byte(needle, j)) ok = 1'b0;
            match_tail = ok;
        end
    endfunction

    always @(posedge clk or negedge aresetn) begin
        if (!aresetn) begin
            rx_push_q <= 1'b0;
            rx_total  <= 32'd0;
            for (wi = 0; wi < WIN; wi = wi + 1) rx_win[wi] <= 8'h00;
            c2_hit <= 1'b0; c3_hit <= 1'b0;
            c3p_hit <= 1'b0;
            c2_cycle <= 32'd0; c3_cycle <= 32'd0;
            c2_byte  <= 32'd0; c3_byte  <= 32'd0;
        end else begin
            rx_push_q <= uart_char_valid;
            if (uart_char_valid) begin
                for (wi = WIN-1; wi > 0; wi = wi - 1) rx_win[wi] <= rx_win[wi-1];
                rx_win[0] <= uart_char;
                rx_total  <= rx_total + 32'd1;
            end
            if (rx_push_q) begin
                if (!c2_hit && match_tail(EXPECT_C2)) begin
                    c2_hit   <= 1'b1;
                    c2_cycle <= gcyc;
                    c2_byte  <= rx_total;
                end
                if (!c3_hit && match_tail(EXPECT_C3)) begin
                    c3_hit   <= 1'b1;
                    c3_cycle <= gcyc;
                    c3_byte  <= rx_total;
                end
                if (!c3p_hit && match_tail(EXPECT_C3_PFX)) begin
                    c3p_hit   <= 1'b1;
                    c3p_byte  <= rx_total;
                end
            end
        end
    end

    //==========================================================================
    // 6. AXI 轨迹直方图（区域统计 + 非 XIP 精确地址统计）
    //==========================================================================
    localparam integer NHIST = 40;
    reg [31:0] ar_region_cnt [0:NREGION-1];
    reg [31:0] aw_region_cnt [0:NREGION-1];
    reg [31:0] ar_hist_addr  [0:NHIST-1];
    reg [31:0] ar_hist_cnt   [0:NHIST-1];
    reg [31:0] aw_hist_addr  [0:NHIST-1];
    reg [31:0] aw_hist_cnt   [0:NHIST-1];
    reg [31:0] aw_hist_data  [0:NHIST-1];
    integer    ar_hist_n, aw_hist_n;
    integer    hh, hfound;

    task hist_add;                                  // 只统计非 XIP 地址（XIP 取指每拍都不同）
        input [31:0] addr;
        input [31:0] dat;
        input        is_wr;
        integer k; reg fnd;
        begin
            fnd = 1'b0;
            if (is_wr) begin
                for (k = 0; k < aw_hist_n; k = k + 1)
                    if (aw_hist_addr[k] == addr) begin
                        aw_hist_cnt[k] = aw_hist_cnt[k] + 32'd1;
                        aw_hist_data[k] = dat;
                        fnd = 1'b1;
                    end
                if (!fnd && (aw_hist_n < NHIST)) begin
                    aw_hist_addr[aw_hist_n] = addr;
                    aw_hist_cnt [aw_hist_n] = 32'd1;
                    aw_hist_data[aw_hist_n] = dat;
                    aw_hist_n = aw_hist_n + 1;
                end
            end else begin
                for (k = 0; k < ar_hist_n; k = k + 1)
                    if (ar_hist_addr[k] == addr) begin
                        ar_hist_cnt[k] = ar_hist_cnt[k] + 32'd1;
                        fnd = 1'b1;
                    end
                if (!fnd && (ar_hist_n < NHIST)) begin
                    ar_hist_addr[ar_hist_n] = addr;
                    ar_hist_cnt [ar_hist_n] = 32'd1;
                    ar_hist_n = ar_hist_n + 1;
                end
            end
        end
    endtask

    always @(posedge clk or negedge aresetn) begin
        if (!aresetn) begin
            for (hh = 0; hh < NREGION; hh = hh + 1) begin
                ar_region_cnt[hh] <= 32'd0;
                aw_region_cnt[hh] <= 32'd0;
            end
            ar_hist_n <= 0; aw_hist_n <= 0;
        end else begin
            if (c_ar_pulse) begin
                ar_region_cnt[region_of(c_ar_addr)] <= ar_region_cnt[region_of(c_ar_addr)] + 32'd1;
                if (region_of(c_ar_addr) != R_XIP) hist_add(c_ar_addr, 32'h0, 1'b0);
            end
            if (c_aw_pulse) begin
                aw_region_cnt[region_of(c_aw_addr)] <= aw_region_cnt[region_of(c_aw_addr)] + 32'd1;
                if (region_of(c_aw_addr) != R_XIP) hist_add(c_aw_addr, c_aw_data, 1'b1);
            end
        end
    end

    //==========================================================================
    // 7. 主流程
    //==========================================================================
    integer    cyc;
    integer    i, j;
    reg        pass;
    reg        timed_out;
    integer    commit_count;
    integer    commit_print_lim;

    initial begin
        aresetn = 1'b0;
        commit_count     = 0;
        commit_print_lim = 16;

        $display("========================================================================");
        $display("TB_M5_BOARD: 开始 —— M5 上板程序核级仿真（core_top + CONFREG 过滤层 + sim_mem_model）");
        $write("  PROG_HEX    = ");                         print_pstr(PROG_HEX);  $write("\n");
        $write("  C2 期望子串 = \"");                        print_pstr(EXPECT_C2); $write("\"\n");
        $write("  C3 期望子串 = \"");                        print_pstr(EXPECT_C3); $write("\"\n");
        $display("  时钟        = 半周期 %f ns ⇒ 周期 %f ns（%f MHz）",
                 CLK_HALF_NS, CLK_HALF_NS*2.0, 1000.0/(CLK_HALF_NS*2.0));
        $display("  超时预算    = %0d 拍；复位 %0d 拍；SWITCH=0x%02h；FREQ=%0d",
                 TIMEOUT_CYCLES, RESET_CYCLES, SWITCH_VAL, FREQ_VAL);

        //----------------------------------------------------------------------
        // 7.1 载入程序映像（XIP 预载）
        //----------------------------------------------------------------------
        u_mem.load_xip_hex(PROG_HEX);
        $display("TB_M5_DIAG : XIP 前 8 字 = %08h %08h %08h %08h %08h %08h %08h %08h",
                 u_mem.xip_mem[0], u_mem.xip_mem[1], u_mem.xip_mem[2], u_mem.xip_mem[3],
                 u_mem.xip_mem[4], u_mem.xip_mem[5], u_mem.xip_mem[6], u_mem.xip_mem[7]);

        //----------------------------------------------------------------------
        // 7.2 复位保持 RESET_CYCLES 拍，负沿释放
        //----------------------------------------------------------------------
        repeat (RESET_CYCLES) @(posedge clk);
        @(negedge clk);
        aresetn = 1'b1;
        $display("TB_M5_DIAG : aresetn 已释放（保持 %0d 拍）", RESET_CYCLES);

        //----------------------------------------------------------------------
        // 7.3 等待 C2/C3 命中或超时
        //----------------------------------------------------------------------
        cyc = 0;
        while (!(c2_hit && c3_hit) && !stop_early && (cyc < TIMEOUT_CYCLES)) begin
            @(posedge clk);
            cyc = cyc + 1;
            if ((cyc % PROGRESS_EVERY) == 0) begin
                $display("TB_M5_PROGRESS: cyc=%0d uart_bytes=%0d c2=%b c3=%b first_ar=0x%08h(seen=%b) ar=%0d aw=%0d conf_ar=%0d conf_aw=%0d timer=0x%08h last16=[",
                         cyc, uart_tx_count, c2_hit, c3_hit, c_first_ar_addr, c_first_ar_seen,
                         c_ar_cnt, c_aw_cnt, c_conf_ar, c_conf_aw, c_timer_q);
                for (i = (uart_tx_count > 16) ? uart_tx_count-16 : 0; i < uart_tx_count; i = i + 1)
                    print_char_esc(u_mem.uart_tx_queue[i]);
                $write("]\n");
            end
        end
        timed_out = (cyc >= TIMEOUT_CYCLES);
        if (c3p_hit && !c3_hit && !timed_out)
            $display("TB_M5_DIAG : 命中结果行前缀 \"RESULT: RV32GC-M5-\" 后宽限 %0d 字节 ⇒ 判定已确定（非 OK）⇒ 提前收尾于第 %0d 拍",
                     GRACE_BYTES, cyc);
        else if (c3_hit)
            $display("TB_M5_DIAG : 结果行判定为 OK ⇒ 提前收尾于第 %0d 拍（超时预算 %0d）", cyc, TIMEOUT_CYCLES);

        //----------------------------------------------------------------------
        // 7.4 证据汇总
        //----------------------------------------------------------------------
        $display("------------------------------------------------------------------------");
        $display("TB_M5_DIAG : PROG_HEX 载入 err=%0d words=%0d nonzero=%0d",
                 u_mem.load_err, u_mem.load_words, u_mem.load_nonzero);
        $display("TB_M5_DIAG : 跑完拍数 = %0d（超时预算 %0d）；仿真时间 = %0.1f ns ⇒ 实测周期 = %0.4f ns（%0.4f MHz）",
                 cyc, TIMEOUT_CYCLES, $realtime,
                 $realtime / (cyc + RESET_CYCLES), 1000.0 * (cyc + RESET_CYCLES) / $realtime);
        $display("TB_M5_DIAG : AXI 上游握手计数 AR=%0d AW=%0d；过滤层自答 conf_ar=%0d conf_aw=%0d",
                 c_ar_cnt, c_aw_cnt, c_conf_ar, c_conf_aw);
        $display("TB_M5_DIAG : sim_mem_model 侧 AR=%0d AW=%0d r_beat=%0d w_beat=%0d unknown_rd=%0d",
                 u_mem.ar_count, u_mem.aw_count, u_mem.r_beat_count,
                 u_mem.w_beat_count, u_mem.unknown_rd_count);
        $display("TB_M5_DIAG : UART 捕获字节数=%0d overflow=%b bad_strb=%0d",
                 uart_tx_count, uart_overflow, uart_bad_strb_count);
        $display("TB_M5_DIAG : 过滤层一致性：collision=%0d 窗口内未登记读=%0d 未登记写=%0d 只读寄存器被写=%0d",
                 c_collision, c_conf_rd_un, c_conf_wr_un, c_conf_ro_wr);

        // ---- AXI 区域统计（"程序到底访问了哪些地址空间"的直接证据）----
        $display("TB_M5_TRACE: 读地址(AR)区域统计：");
        for (i = 0; i < NREGION; i = i + 1)
            $display("             AR  %0s 0x%08h", region_name(i), ar_region_cnt[i]);
        $display("TB_M5_TRACE: 写地址(AW)区域统计：");
        for (i = 0; i < NREGION; i = i + 1)
            $display("             AW  %0s 0x%08h", region_name(i), aw_region_cnt[i]);

        $display("TB_M5_TRACE: 非 XIP 读地址直方图（addr ×count）：");
        for (i = 0; i < ar_hist_n; i = i + 1)
            $display("             AR  0x%08h ×%0d", ar_hist_addr[i], ar_hist_cnt[i]);
        $display("TB_M5_TRACE: 非 XIP 写地址直方图（addr ×count last_data）：");
        for (i = 0; i < aw_hist_n; i = i + 1)
            $display("             AW  0x%08h ×%0d last_data=0x%08h", aw_hist_addr[i], aw_hist_cnt[i], aw_hist_data[i]);

        // ---- AXI 轨迹（前 TRACE_PRINT_N 条，带拍戳）----
        $display("TB_M5_TRACE: AR 轨迹前 %0d 条（cyc addr）：", TRACE_PRINT_N);
        for (i = 0; i < TRACE_PRINT_N && i < u_conf.ar_trace_n; i = i + 1)
            $display("             AR  cyc=%0d addr=0x%08h", u_conf.ar_trace_cyc[i], u_conf.ar_trace_addr[i]);
        $display("TB_M5_TRACE: AW 轨迹前 %0d 条（cyc addr data strb）：", TRACE_PRINT_N);
        for (i = 0; i < TRACE_PRINT_N && i < u_conf.aw_trace_n; i = i + 1)
            $display("             AW  cyc=%0d addr=0x%08h data=0x%08h strb=%b",
                     u_conf.aw_trace_cyc[i], u_conf.aw_trace_addr[i],
                     u_conf.aw_trace_data[i], u_conf.aw_trace_strb[i]);

        // ---- CONFREG 行为模型状态 ----
        $display("TB_M5_CONF : CONFREG 访问：LED 写=%0d(seen=%b) 数码管写=%0d SWITCH 读=%0d(seen=%b) TIMER 读=%0d(seen=%b) FREQ 读=%0d(seen=%b)",
                 c_led_wr_count, c_led_wr, c_seg_wr_count, c_sw_rd_count, c_sw_rd,
                 c_timer_rd_count, c_timer_rd, c_freq_rd_count, c_freq_rd);
        $display("TB_M5_CONF : CONFREG 值：LED=0x%04h 数码管=0x%08h TIMER(末)=0x%08h；LED 最后写=0x%08h@cyc%0d 数码管最后写=0x%08h",
                 c_led_q, c_seg_q, c_timer_q, c_led_wr_data, c_led_wr_cycle, c_seg_wr_data);
        $display("TB_M5_CONF : TIMER 首读=0x%08h 末读=0x%08h（写清零 %0d 次，最后写值=0x%08h）；SWITCH 读回=0x%02h；FREQ 读回=0x%08h",
                 c_timer_rd_first, c_timer_rd_last, c_timer_wr_count, c_timer_wr_data,
                 c_sw_rd_data[7:0], c_freq_rd_data);
        $display("TB_M5_CONF : 首笔上游 AR = 0x%08h（seen=%b，期望 0x%08h）",
                 c_first_ar_addr, c_first_ar_seen, RESET_PC_EXP);
        $display("TB_M5_DIAG : 提交指令数（ws_valid 计数）= %0d ws_valid=%b", commit_count, ws_valid);

        // ---- UART 捕获序列（C2/C3 的原始证据）----
        $display("TB_M5_UART : 捕获序列（%0d 字节，转义显示；上限 %0d）：", uart_tx_count, UART_PRINT_MAX);
        $write("             [");
        for (i = 0; i < uart_tx_count && i < UART_PRINT_MAX; i = i + 1) print_char_esc(u_mem.uart_tx_queue[i]);
        $write("]\n");
        if (uart_tx_count > UART_PRINT_MAX) $display("             ...（截断，共 %0d 字节）", uart_tx_count);
        $write("TB_M5_UART : 子串匹配 C2 \""); print_pstr(EXPECT_C2);
        $display("\" ⇒ %0s（命中字节序号 %0d，拍 %0d）", c2_hit ? "HIT" : "MISS", c2_byte, c2_cycle);
        $write("TB_M5_UART : 子串匹配 C3 \""); print_pstr(EXPECT_C3);
        $display("\" ⇒ %0s（命中字节序号 %0d，拍 %0d）", c3_hit ? "HIT" : "MISS", c3_byte, c3_cycle);
        $write("TB_M5_UART : 结果行前缀 \""); print_pstr(EXPECT_C3_PFX);
        $display("\" ⇒ %0s（命中字节序号 %0d；宽限 %0d 字节后判定确定=%b）",
                 c3p_hit ? "HIT" : "MISS", c3p_byte, GRACE_BYTES, c3_decided);
        $display("------------------------------------------------------------------------");

        //----------------------------------------------------------------------
        // 7.5 判定（fail-closed；任一不满足 ⇒ FAIL + $fatal）
        //----------------------------------------------------------------------
        pass = 1'b1;

        // ---- C0：测试台自检（载入/队列/路由一致性）----
        if (u_mem.load_err != 0) begin
            pass = 1'b0;
            $write("TB_M5_BOARD: FAIL C0 PROG_HEX 载入失败 load_err=%0d path=\"", u_mem.load_err);
            print_pstr(PROG_HEX);
            $write("\"\n");
        end
        if ((u_mem.load_words == 0) || (u_mem.load_nonzero < 8)) begin
            pass = 1'b0;
            $display("TB_M5_BOARD: FAIL C0 程序映像未真正载入 words=%0d nonzero=%0d", u_mem.load_words, u_mem.load_nonzero);
        end
        if (uart_overflow) begin
            pass = 1'b0;
            $display("TB_M5_BOARD: FAIL C0 UART 捕获队列溢出（深度 %0d，实收 %0d）—— 测试台证据不完整",
                     UART_QUEUE_DEPTH, uart_tx_count);
        end
        if (c_collision != 0) begin
            pass = 1'b0;
            $display("TB_M5_BOARD: FAIL C0 过滤层检测到 %0d 次误路由/并发在途（观测不可信）", c_collision);
        end else begin
            $display("TB_M5_CHECK: C0 测试台自检（映像载入/队列/路由）OK：words=%0d nonzero=%0d overflow=%b collision=%0d",
                     u_mem.load_words, u_mem.load_nonzero, uart_overflow, c_collision);
        end

        // ---- C1：首笔 AXI 读地址 ----
        if (!c_first_ar_seen) begin
            pass = 1'b0;
            $display("TB_M5_BOARD: FAIL C1 复位后未观察到任何 AXI 读请求（期望首笔 AR=0x%08h）", RESET_PC_EXP);
        end else if (c_first_ar_addr !== RESET_PC_EXP) begin
            pass = 1'b0;
            $display("TB_M5_BOARD: FAIL C1 首笔 AXI 读地址=0x%08h，期望 0x%08h", c_first_ar_addr, RESET_PC_EXP);
        end else begin
            $display("TB_M5_CHECK: C1 首笔 AXI 读地址=0x%08h（复位取指口径）OK", c_first_ar_addr);
        end

        // ---- C2：启动横幅子串 ----
        if (!c2_hit) begin
            pass = 1'b0;
            $write("TB_M5_BOARD: FAIL C2 UART 捕获序列中未出现子串 \"");
            print_pstr(EXPECT_C2);
            $display("\"（已收 %0d 字节）", uart_tx_count);
        end else begin
            $write("TB_M5_CHECK: C2 UART 子串 \"");
            print_pstr(EXPECT_C2);
            $display("\" 命中（第 %0d 字节，拍 %0d）OK", c2_byte, c2_cycle);
        end

        // ---- C3：结果子串 ----
        if (!c3_hit) begin
            pass = 1'b0;
            $write("TB_M5_BOARD: FAIL C3 UART 捕获序列中未出现子串 \"");
            print_pstr(EXPECT_C3);
            if (c3_decided) $display("\"（结果行已出现且判定为**非 OK**：第 %0d 字节处以 \"RESULT: RV32GC-M5-\" 开头）", c3p_byte);
            else            $display("\"（已收 %0d 字节）", uart_tx_count);
        end else begin
            $write("TB_M5_CHECK: C3 UART 子串 \"");
            print_pstr(EXPECT_C3);
            $display("\" 命中（第 %0d 字节，拍 %0d）OK", c3_byte, c3_cycle);
        end

        // ---- C4：CONFREG 五步访问（AXI 通道观测）----
        if (!c_led_wr) begin
            pass = 1'b0;
            $display("TB_M5_BOARD: FAIL C4 未捕获到对 0x1FD0F000（LED）的写");
        end
        if (!c_sw_rd) begin
            pass = 1'b0;
            $display("TB_M5_BOARD: FAIL C4 未捕获到对 0x1FD0F020（switch）的读");
        end
        if (!c_timer_rd) begin
            pass = 1'b0;
            $display("TB_M5_BOARD: FAIL C4 未捕获到对 0x1FD0E000（TIMER）的读");
        end
        if (!c_freq_rd) begin
            pass = 1'b0;
            $display("TB_M5_BOARD: FAIL C4 未捕获到对 0x1FD0F030（FREQ）的读");
        end
        if (c_led_wr && c_sw_rd && c_timer_rd && c_freq_rd) begin
            $display("TB_M5_CHECK: C4 CONFREG 五步访问齐备（LED 写 %0d 次 / switch 读 %0d 次 / TIMER 读 %0d 次 / FREQ 读 %0d 次）OK",
                     c_led_wr_count, c_sw_rd_count, c_timer_rd_count, c_freq_rd_count);
        end else begin
            $display("TB_M5_CHECK: C4 CONFREG 窗口内观测：AR=%0d 次、AW=%0d 次（期望 LED 写 ≥1、switch/TIMER/FREQ 读各 ≥1）",
                     c_conf_ar, c_conf_aw);
        end

        // ---- C5：超时保护 ----
        if (timed_out) begin
            pass = 1'b0;
            $display("TB_M5_BOARD: FAIL C5 %0d 拍内未出现结果行（超时保护触发；已收 %0d 字节）", TIMEOUT_CYCLES, uart_tx_count);
        end else begin
            $display("TB_M5_CHECK: C5 判定在 %0d 拍预算内完成（实用 %0d 拍）OK", TIMEOUT_CYCLES, cyc);
        end

        $display("TB_M5_SUMMARY: cycles=%0d uart_bytes=%0d c2=%b c3=%b first_ar=0x%08h conf_ar=%0d conf_aw=%0d led_wr=%b sw_rd=%b timer_rd=%b freq_rd=%b collision=%0d",
                 cyc, uart_tx_count, c2_hit, c3_hit, c_first_ar_addr,
                 c_conf_ar, c_conf_aw, c_led_wr, c_sw_rd, c_timer_rd, c_freq_rd, c_collision);

        if (pass) begin
            $display("========================================================================");
            $display("TB_M5_BOARD: PASS");
            $display("========================================================================");
            $finish;
        end else begin
            $display("========================================================================");
            $display("TB_M5_BOARD: FAIL 判据未全部达成（逐条见上；本 TB 无兜底 PASS 文案）");
            $display("========================================================================");
            $fatal(1, "TB_M5_BOARD FAIL");
        end
    end

    //==========================================================================
    // 8. 提交观测（诊断：证明核在真跑指令）
    //==========================================================================
    always @(posedge clk) begin
        if (aresetn && ws_valid) begin
            if (commit_count < commit_print_lim)
                $display("TB_M5_DIAG : 提交 #%0d pc=0x%08h wen=%b rd=x%0d wdata=0x%08h",
                         commit_count, debug0_wb_pc, debug0_wb_rf_wen[0],
                         debug0_wb_rf_wnum, debug0_wb_rf_wdata);
            commit_count = commit_count + 1;
        end
    end

    //==========================================================================
    // 9. 逐拍 R 通道探针（诊断；R 数据"何时被核取走"的直接证据）
    //    · 触发：过滤层 `conf_ar_count` 首次变化（= 首笔 CONFREG 读的 AR 被观测到）
    //    · 打印：R 通道五通道信号 + 核内 M 级 AXI 完成记账与采样寄存器（**层次引用，
    //      仅诊断**；判据观测点仍是 AXI 通道本身）
    //    · `u_dut.m_rd_data_q` 出现 CONFREG 数据的那一拍 = 核实际取走 rdata 的拍
    //==========================================================================
    reg        rdt_armed;
    reg [31:0] rdt_i;
    reg [31:0] conf_ar_d;
    always @(posedge clk or negedge aresetn) begin
        if (!aresetn) begin
            rdt_armed <= 1'b0;
            rdt_i     <= 32'd0;
            conf_ar_d <= 32'd0;
        end else begin
            conf_ar_d <= c_conf_ar;
            if (RD_TRACE_WINDOW > 0) begin
                if (!rdt_armed && (c_conf_ar != conf_ar_d)) begin
                    rdt_armed <= 1'b1;
                    rdt_i     <= 32'd1;
                    $display("TB_M5_RDTRACE: 首笔 CONFREG 读 AR 出现（gcyc=%0d）⇒ 逐拍打印 R 通道", gcyc);
                end else if (rdt_armed && (rdt_i <= RD_TRACE_WINDOW)) begin
                    rdt_i <= rdt_i + 32'd1;
                    $display("TB_M5_RDTRACE: +%0d rvalid=%b rready=%b rdata=0x%08h rlast=%b | core: axi_done_q=%b axi_owner_q=%0d m_state_q=%0d m_rd_data_q=0x%08h",
                             rdt_i, rvalid, rready, rdata, rlast,
                             u_dut.axi_done_q, u_dut.axi_owner_q, u_dut.m_state_q, u_dut.m_rd_data_q);
                end
            end
        end
    end

endmodule
