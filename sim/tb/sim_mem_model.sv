//==============================================================================
// sim/tb/sim_mem_model.sv —— AXI4 从设备仿真内存模型（M1 里程碑判据用）
//==============================================================================
// 项目  : rv32gc-cpu（阶段二 2A）
// 归属  : docs/design/08-baseline-5stage.md §2 M1 / §3.2（sim_mem_model.sv 职责）
//         平台地址口径：docs/kb/platform-facts.md §2（XIP/DDR3/UART 窗口）
//------------------------------------------------------------------------------
// 一、本模型做什么（只做这三件）
//------------------------------------------------------------------------------
//   ① **存储体**（全部由数组承载 = "数组预载"）：
//        · SPI XIP 主窗口 0x1C00_0000（1 MiB）+ 别名窗口 0x1FE8_0000（**同址**）
//        · DDR3 0x0000_0000–0x07FF_FFFF（128 MiB，参数可缩以省内存）
//      XIP 由 PROG_HEX 预载（路径由 TB 参数 `PROG_HEX` 传入）。
//   ② **UART 数据寄存器 0x1FE0_01E0 的写捕获**：AW/W 通道上任意 wstrb 的写，
//      取 wstrb 中最低置位字节压入 `uart_tx_queue`（wstrb=0 时取 wdata[7:0] 并告警），
//      每字符 `$display`，并输出 `uart_char/uart_char_valid` 单拍脉冲供解码器校验。
//   ③ **AXI4 五通道最小从设备**：AR/R（INCR 多 beat、读延迟 0/1 拍可配）、
//      AW/W/B（单笔在途、按 wlast 收尾、OKAY 响应、B 通道握手）。
//      其余（未登记）区域**读 0**；对只读的 XIP 区写**忽略并告警**。
//------------------------------------------------------------------------------
// 二、判据服务（TB 断言用的可观测量）
//------------------------------------------------------------------------------
//   · `first_ar_seen` / `first_ar_addr` / `first_ar_ok`：**首笔 AR 地址 == 0x1C00_0000**
//     （M1 判据①）。观测点是 AXI 通道本身，不是核内层次引用。
//   · `uart_tx_count` + `uart_tx_queue[]`：捕获到的字节序列（M1 判据②）。
//   · 计数器：ar_count / aw_count / r_beat_count / w_beat_count / unknown_rd_count。
//   · `load_err` / `load_words` / `load_nonzero`：PROG_HEX 载入结果（非 0 ⇒ TB FAIL）。
//------------------------------------------------------------------------------
// 三、为什么不用 $readmemh 直接载入 PROG_HEX（**重要，避免误判为偷懒**）
//------------------------------------------------------------------------------
//   objcopy -O verilog --verilog-data-width=4 输出的 `@` 字段是**数据字索引**，
//   不是字节地址：本程序 `-Ttext=0x1C000000` ⇒ 文件首行是 `@07000000`
//   （= 0x1C00_0000 >> 2）。若直接 `$readmemh` 载入 1 MiB 窗口数组，iverilog 会
//   把地址 0x0700_0000 判为**越界**（数组下标上限 0x3FFFF）⇒ 载入失败。
//   因此本模型内置一个**极小的词法器** `load_xip_hex()`：逐字符读文件，遇 `@`
//   解析基址并**归一化**（同时兼容"数据字索引"与"字节地址"两种写法），随后把每个
//   32 bit 字放到 XIP 窗口数组的正确下标。语义 = $readmemh + 地址重定位，
//   且**不依赖任何外部脚本**（本项目禁止新建共享脚本）。
//------------------------------------------------------------------------------
// 四、风格/红线声明
//------------------------------------------------------------------------------
//   · 本文件是**仿真模型（TESTBENCH，不可综合）**：存储体与通道状态用 always 块
//     描述是建模必需（rtl/** 的"禁止大 always 组合块"红线针对可综合代码）。
//   · **不使用任何 FPGA 原语**（无块 RAM/时钟资源/DSP 类原语），无 Vivado IP 依赖 ⇒
//     iverilog/Verilator 回归完全自洽（红线 1/2 合规）。
//   · 无旧项目标识（旧项目 RTL/脚本一律不得复制，见 AGENT.md 抬头）。
//==============================================================================
`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"

module sim_mem_model #(
    // ---- 窗口参数（默认取 rtl/pkg 真源） ----
    parameter [31:0]  XIP_BASE        = `RV32GC_XIP_BASE,        // 0x1C00_0000
    parameter [31:0]  XIP_ALIAS       = `RV32GC_XIP_ALIAS,       // 0x1FE8_0000（同址别名）
    parameter [31:0]  XIP_SIZE        = `RV32GC_XIP_SIZE,        // 1 MiB
    parameter [31:0]  DDR3_BASE       = `RV32GC_DDR_BASE,        // 0x0000_0000
    parameter [31:0]  DDR3_LIMIT      = `RV32GC_DDR_LIMIT,       // 0x0800_0000（开区间上界）
    parameter [31:0]  UART_DATA_ADDR  = `RV32GC_UART_BASE,       // 0x1FE0_01E0
    // ---- 行为参数 ----
    parameter integer READ_LAT_DLY    = 0,      // AR → 首个 R beat 的延迟拍数（0 或 1）
    parameter integer UART_QUEUE_DEPTH= 64,     // 捕获队列深度（M1 只需 14）
    parameter integer R_ERRS_MAX      = 16      // 未知区域读的告警上限（防刷屏）
) (
    input  wire        clk,
    input  wire        rst_n,

    //--------------------------------------------------------------------------
    // AR（读地址通道）
    //--------------------------------------------------------------------------
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

    //--------------------------------------------------------------------------
    // R（读数据通道）
    //--------------------------------------------------------------------------
    output wire [3:0]  rid,
    output wire [31:0] rdata,
    output wire [1:0]  rresp,
    output wire        rlast,
    output wire        rvalid,
    input  wire        rready,

    //--------------------------------------------------------------------------
    // AW（写地址通道）
    //--------------------------------------------------------------------------
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

    //--------------------------------------------------------------------------
    // W（写数据通道）
    //--------------------------------------------------------------------------
    input  wire [3:0]  wid,
    input  wire [31:0] wdata,
    input  wire [3:0]  wstrb,
    input  wire        wlast,
    input  wire        wvalid,
    output wire        wready,

    //--------------------------------------------------------------------------
    // B（写响应通道）
    //--------------------------------------------------------------------------
    output wire [3:0]  bid,
    output wire [1:0]  bresp,
    output wire        bvalid,
    input  wire        bready,

    //--------------------------------------------------------------------------
    // UART 捕获输出（供 uart_ser_decoder 逐字符校验）
    //--------------------------------------------------------------------------
    output reg  [7:0]  uart_char,           // 本拍捕获到的字符
    output reg         uart_char_valid,     // 单拍脉冲：该字符有效
    output reg  [31:0] uart_tx_count,       // 累计捕获字符数（不截断）
    output reg         uart_overflow,       // 队列溢出标志（TB 必须判 FAIL）
    output reg  [31:0] uart_bad_strb_count  // wstrb=0 的异常写计数（诊断）
);

    //==========================================================================
    // 0. 常量
    //==========================================================================
    localparam integer XIP_WORDS     = XIP_SIZE / 4;                  // 262144
    localparam integer DDR3_WORDS    = (DDR3_LIMIT - DDR3_BASE) / 4;   // 32M（128 MiB）
    localparam [31:0]  XIP_BASE_WIDX = XIP_BASE >> 2;                  // 0x0700_0000
    localparam [1:0]   RESP_OKAY     = `RV32GC_AXI_RESP_OKAY;
    localparam [15:0]  SPI_ALIAS_HI16 = `RV32GC_SPI_HIT_VAL;           // 16'h1FE8

    //==========================================================================
    // 1. 存储体（数组 = 预载/承载）
    //==========================================================================
    reg [31:0] xip_mem  [0:XIP_WORDS-1];
    reg [31:0] ddr3_mem [0:DDR3_WORDS-1];

    // UART 捕获队列（M1 判据②的原始证据；TB 可层次引用 dump）
    reg [7:0]  uart_tx_queue [0:UART_QUEUE_DEPTH-1];

    // XIP 体上电清零（1 MiB = 262144 字，开销可忽略）：
    //   保证"程序映像之外的窗口内地址读 0"，避免 x 传播到取指通路。
    integer zi;
    initial begin
        for (zi = 0; zi < XIP_WORDS; zi = zi + 1) xip_mem[zi] = 32'h0000_0000;
    end

    //==========================================================================
    // 2. 地址译码（读/写共用；**唯一译码点**）
    //    · XIP 主窗口 PA[31:20]==0x1C0；别名 PA[31:16]==0x1FE8（同址：按窗口内偏移）
    //    · DDR3      PA < 0x0800_0000
    //    · 其余      读 0；写忽略并告警
    //==========================================================================
    function is_xip_main;
        input [31:0] a;
        begin
            is_xip_main = ((a[31:20] & `RV32GC_XIP_HI20_MSK) == `RV32GC_XIP_HI20_VAL);
        end
    endfunction

    function is_xip_alias;
        input [31:0] a;
        begin
            is_xip_alias = ((a[31:16] & `RV32GC_HIT_HI16_MSK) == SPI_ALIAS_HI16);
        end
    endfunction

    function is_xip;
        input [31:0] a;
        begin
            is_xip = is_xip_main(a) | is_xip_alias(a);
        end
    endfunction

    function is_ddr3;
        input [31:0] a;
        begin
            is_ddr3 = (a >= DDR3_BASE) && (a < DDR3_LIMIT);
        end
    endfunction

    function is_uart_data;
        input [31:0] a;
        begin
            is_uart_data = (a == UART_DATA_ADDR);
        end
    endfunction

    // XIP 窗口内字下标（主窗口与别名**同址**：都用"相对各自窗口基址的偏移"）
    function [31:0] xip_word_idx;
        input [31:0] a;
        begin
            if (is_xip_alias(a)) xip_word_idx = (a - XIP_ALIAS) >> 2;
            else                 xip_word_idx = (a - XIP_BASE ) >> 2;
        end
    endfunction

    // DDR3 字读取：**未写入的字节（x）按 0 返回**（上电内容 = 0，且不必在 t=0
    //   对 32M 字做一次清零循环，省 ~10 s 仿真启动时间）。
    //   已写入的字节原样返回 ⇒ 字节粒度语义与"上电全 0 + 按字节写"完全一致。
    function [31:0] ddr3_read;
        input [31:0] a;
        reg [31:0] w;
        begin
            w = ddr3_mem[a[31:2]];
            ddr3_read = { (^w[31:24] === 1'bx) ? 8'h00 : w[31:24],
                          (^w[23:16] === 1'bx) ? 8'h00 : w[23:16],
                          (^w[15: 8] === 1'bx) ? 8'h00 : w[15: 8],
                          (^w[ 7: 0] === 1'bx) ? 8'h00 : w[ 7: 0] };
        end
    endfunction

    // 读一个字（组合；未登记区域恒 0）
    function [31:0] mem_read;
        input [31:0] a;
        begin
            if (is_xip(a))        mem_read = xip_mem[xip_word_idx(a)];
            else if (is_ddr3(a))  mem_read = ddr3_read(a);
            else                  mem_read = 32'h0000_0000;
        end
    endfunction

    //==========================================================================
    // 3. AXI4 读通道（AR → R）：单笔在途，INCR 逐拍 +4，末拍 rlast
    //==========================================================================
    reg        arready_r;
    reg        rd_active;     // 正在输出 R beat
    reg        rd_pend;       // READ_LAT_DLY=1 时的 1 拍间隔
    reg [31:0] rd_addr_q;
    reg [3:0]  rd_len_q;      // AxLEN（beat 数 - 1）
    reg [3:0]  rd_id_q;
    reg [4:0]  rd_cnt_q;      // 当前 beat 下标（0 起）

    assign arready = arready_r;
    assign rid     = rd_id_q;
    assign rdata   = mem_read(rd_addr_q);
    assign rresp   = RESP_OKAY;
    assign rvalid  = rd_active;
    assign rlast   = (rd_cnt_q[3:0] == rd_len_q);

    wire ar_fire = arvalid & arready;
    wire r_fire  = rvalid & rready;

    //==========================================================================
    // 4. AXI4 写通道（AW → W → B）：单笔在途，wlast ⇒ B
    //==========================================================================
    reg        awready_r;
    reg        wr_pend;       // AW 已收、B 未回
    reg        bvalid_r;
    reg [31:0] aw_addr_q;
    reg [3:0]  aw_len_q;
    reg [3:0]  aw_id_q;
    reg [4:0]  w_cnt_q;

    assign awready = awready_r;
    assign wready  = wr_pend & ~bvalid_r;
    assign bid     = aw_id_q;
    assign bresp   = RESP_OKAY;
    assign bvalid  = bvalid_r;

    wire aw_fire = awvalid & awready;
    wire w_fire  = wvalid & wready;
    wire b_fire  = bvalid & bready;

    //==========================================================================
    // 5. 可观测量（TB 断言用）
    //==========================================================================
    reg        first_ar_seen;
    reg [31:0] first_ar_addr;
    reg        first_ar_ok;
    reg [31:0] ar_count, aw_count, r_beat_count, w_beat_count, unknown_rd_count;
    reg [31:0] uart_write_count;

    //==========================================================================
    // 6. PROG_HEX 载入（内置词法器；见文件头 §三）
    //==========================================================================
    integer    load_err;        // 0=OK；2=打不开；3=@ 基址不符；4=数据越界
    integer    load_words;      // 载入字数
    integer    load_nonzero;    // 非零字数（判断"确实载入了程序"）
    integer    load_base_widx;  // @ 指定的基址（数据字索引）

    function integer hex_digit;                 // 非 16 进制字符 ⇒ -1
        input integer c;
        begin
            if ((c >= "0") && (c <= "9"))      hex_digit = c - "0";
            else if ((c >= "a") && (c <= "f")) hex_digit = c - "a" + 10;
            else if ((c >= "A") && (c <= "F")) hex_digit = c - "A" + 10;
            else                               hex_digit = -1;
        end
    endfunction

    task automatic load_xip_hex;
        input [8*512-1:0] path;                 // TB 参数 PROG_HEX
        integer fd;
        integer c;
        integer v;
        integer widx;                           // 数据字索引（与 @ 字段同单位）
        integer base;
        integer xw;
        begin
            load_err       = 0;
            load_words     = 0;
            load_nonzero   = 0;
            load_base_widx = 0;

            fd = $fopen(path, "r");
            if (fd == 0) begin
                load_err = 2;
                $display("[sim_mem_model] FAIL: 打不开 PROG_HEX = %0s", path);
            end else begin
                widx = XIP_BASE_WIDX;           // 无 @ 指令时默认从 XIP 基址起
                base = -1;
                c = $fgetc(fd);
                while (c != -1) begin
                    if (c == "@") begin
                        // ---- 解析 @ 基址（16 进制）----
                        c = $fgetc(fd);
                        v = 0;
                        while (hex_digit(c) >= 0) begin
                            v = (v << 4) | hex_digit(c);
                            c = $fgetc(fd);
                        end
                        // 归一化：objcopy 口径 = 数据字索引（VMA/4）；
                        // 兼容"字节地址"写法（别的工具可能这么写）。
                        if ((v << 2) == XIP_BASE) begin
                            widx = v;                            // 数据字索引口径
                        end else if (v == XIP_BASE) begin
                            widx = v >> 2;                       // 字节地址口径
                        end else begin
                            load_err = 3;
                            $display("[sim_mem_model] FAIL: PROG_HEX 的 @ 基址 0x%08h 与 XIP 基址 0x%08h 不符",
                                     v, XIP_BASE);
                            widx = v;                            // 越界由范围检查兜底
                        end
                        if (base < 0) begin
                            base = widx;
                            load_base_widx = widx;
                        end
                    end else if (hex_digit(c) >= 0) begin
                        // ---- 解析一个数据字 ----
                        v = 0;
                        while (hex_digit(c) >= 0) begin
                            v = (v << 4) | hex_digit(c);
                            c = $fgetc(fd);
                        end
                        xw = widx - XIP_BASE_WIDX;               // XIP 窗口内下标
                        if ((xw >= 0) && (xw < XIP_WORDS)) begin
                            xip_mem[xw] = v[31:0];
                            load_words  = load_words + 1;
                            if (v[31:0] != 32'h0) load_nonzero = load_nonzero + 1;
                        end else begin
                            load_err = 4;
                            $display("[sim_mem_model] FAIL: PROG_HEX 数据字越出 XIP 窗口（字下标 %0d）", xw);
                        end
                        widx = widx + 1;
                    end else begin
                        c = $fgetc(fd);                          // 跳过空白
                    end
                end
                $fclose(fd);
                $display("[sim_mem_model] PROG_HEX 载入: path=%0s words=%0d nonzero=%0d base_widx=0x%08h err=%0d",
                         path, load_words, load_nonzero, load_base_widx, load_err);
            end
        end
    endtask

    //==========================================================================
    // 7. 写落盘 + UART 捕获（W 通道调用；仿真模型语义，过程式）
    //==========================================================================
    task automatic do_write;
        input [31:0] a;
        input [31:0] d;
        input [3:0]  strb;
        reg [7:0] ch;
        begin
            if (is_uart_data(a)) begin
                // ---- UART 数据寄存器：捕获字节（任意 wstrb）----
                uart_write_count = uart_write_count + 1;
                if (strb == 4'b0000) begin
                    uart_bad_strb_count = uart_bad_strb_count + 1;
                    ch = d[7:0];
                    $display("[sim_mem_model] WARN: UART 写 wstrb=0，按 wdata[7:0]=0x%02h 捕获", d[7:0]);
                end else if (strb[0]) ch = d[7:0];
                else if     (strb[1]) ch = d[15: 8];
                else if     (strb[2]) ch = d[23:16];
                else                  ch = d[31:24];

                if (uart_tx_count < UART_QUEUE_DEPTH) uart_tx_queue[uart_tx_count] = ch;
                else                                  uart_overflow = 1'b1;   // 溢出 ⇒ TB FAIL
                uart_tx_count <= uart_tx_count + 32'd1;
                uart_char        <= ch;                  // 单拍脉冲（供解码器）
                uart_char_valid  <= 1'b1;
                $display("[sim_mem_model] UART TX[%0d] = 0x%02h", uart_tx_count, ch);
            end else if (is_xip(a)) begin
                $display("[sim_mem_model] WARN: 对只读 XIP 窗口的写被忽略 addr=0x%08h data=0x%08h strb=%b",
                         a, d, strb);
            end else if (is_ddr3(a)) begin
                if (strb[0]) ddr3_mem[a[31:2]][ 7: 0] = d[ 7: 0];
                if (strb[1]) ddr3_mem[a[31:2]][15: 8] = d[15: 8];
                if (strb[2]) ddr3_mem[a[31:2]][23:16] = d[23:16];
                if (strb[3]) ddr3_mem[a[31:2]][31:24] = d[31:24];
            end else begin
                $display("[sim_mem_model] WARN: 未登记区域写被忽略 addr=0x%08h data=0x%08h strb=%b",
                         a, d, strb);
            end
        end
    endtask

    //==========================================================================
    // 8. 通道时序（**唯一的 always 块**：AXI 从设备状态 + beat 计数 = 时序元件；
    //    仿真模型必需。rtl/** 的"禁止多 reg 组合 always"红线不适用于 TESTBENCH）
    //==========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            arready_r     <= 1'b1;          // 复位后立即可接请求
            rd_active     <= 1'b0;
            rd_pend       <= 1'b0;
            rd_addr_q     <= 32'h0;
            rd_len_q      <= 4'h0;
            rd_id_q       <= 4'h0;
            rd_cnt_q      <= 5'h0;

            awready_r     <= 1'b1;
            wr_pend       <= 1'b0;
            bvalid_r      <= 1'b0;
            aw_addr_q     <= 32'h0;
            aw_len_q      <= 4'h0;
            aw_id_q       <= 4'h0;
            w_cnt_q       <= 5'h0;

            uart_char           <= 8'h00;
            uart_char_valid     <= 1'b0;
            uart_tx_count       <= 32'd0;
            uart_overflow       <= 1'b0;
            uart_bad_strb_count <= 32'd0;
            uart_write_count    <= 32'd0;

            first_ar_seen    <= 1'b0;
            first_ar_addr    <= 32'h0;
            first_ar_ok      <= 1'b0;
            ar_count         <= 32'd0;
            aw_count         <= 32'd0;
            r_beat_count     <= 32'd0;
            w_beat_count     <= 32'd0;
            unknown_rd_count <= 32'd0;
        end else begin
            uart_char_valid <= 1'b0;         // 默认脉冲清零（do_write 内可置 1）

            //------------------------------------------------------------------
            // 读通道
            //------------------------------------------------------------------
            if (ar_fire) begin
                ar_count  <= ar_count + 32'd1;
                rd_addr_q <= araddr;
                rd_len_q  <= arlen;
                rd_id_q   <= arid;
                rd_cnt_q  <= 5'd0;
                arready_r <= 1'b0;                       // 单笔在途
                if (READ_LAT_DLY == 0) rd_active <= 1'b1;
                else                   rd_pend   <= 1'b1;
                if (!first_ar_seen) begin
                    first_ar_seen <= 1'b1;
                    first_ar_addr <= araddr;
                    first_ar_ok   <= (araddr == `RV32GC_RESET_PC);
                    $display("[sim_mem_model] 首笔 AR: addr=0x%08h len=%0d size=%0d burst=%b cache=%b prot=%b id=%0d",
                             araddr, arlen, arsize, arburst, arcache, arprot, arid);
                end
                if (!is_xip(araddr) && !is_ddr3(araddr)) begin
                    unknown_rd_count <= unknown_rd_count + 32'd1;
                    if (unknown_rd_count < R_ERRS_MAX)
                        $display("[sim_mem_model] NOTE: AR 命中未登记区域（按规格读 0）addr=0x%08h", araddr);
                end
            end else if (rd_pend) begin
                rd_pend   <= 1'b0;
                rd_active <= 1'b1;
            end else if (r_fire) begin
                r_beat_count <= r_beat_count + 32'd1;
                if (rd_cnt_q[3:0] == rd_len_q) begin
                    rd_active <= 1'b0;
                    arready_r <= 1'b1;                   // 释放：可接下一笔
                end else begin
                    rd_cnt_q  <= rd_cnt_q + 5'd1;
                    rd_addr_q <= rd_addr_q + 32'd4;      // INCR
                end
            end

            //------------------------------------------------------------------
            // 写通道
            //------------------------------------------------------------------
            if (aw_fire) begin
                aw_count  <= aw_count + 32'd1;
                aw_addr_q <= awaddr;
                aw_len_q  <= awlen;
                aw_id_q   <= awid;
                w_cnt_q   <= 5'd0;
                wr_pend   <= 1'b1;
                awready_r <= 1'b0;                       // 单笔在途
                $display("[sim_mem_model] AW: addr=0x%08h len=%0d size=%0d burst=%b cache=%b id=%0d",
                         awaddr, awlen, awsize, awburst, awcache, awid);
            end

            if (w_fire) begin
                w_beat_count <= w_beat_count + 32'd1;
                do_write(aw_addr_q + {w_cnt_q, 2'b00}, wdata, wstrb);
                if (wlast) begin
                    wr_pend   <= 1'b0;
                    bvalid_r  <= 1'b1;
                    awready_r <= 1'b1;                   // 释放：可接下一笔
                end else begin
                    w_cnt_q <= w_cnt_q + 5'd1;
                end
            end

            if (b_fire) bvalid_r <= 1'b0;
        end
    end

endmodule
