//==============================================================================
// sim/tb/uart_ser_decoder.sv —— UART 字符序列校验器（并行捕获队列 / 8N1 串行位流）
//==============================================================================
// 项目  : rv32gc-cpu（阶段二 2A）
// 归属  : docs/design/08-baseline-5stage.md §3.2（uart_ser_decoder.sv 职责：
//         "UART 串行位流解码（供 M1/M5 判据）"）；§2 M1 判据②（UART 回显字符串）
//------------------------------------------------------------------------------
// 一、两条输入通路（二选一，由参数 SERIAL_EN 决定）
//------------------------------------------------------------------------------
//   ① **并行字符通路**（SERIAL_EN=0，M1 用这条）：
//        由仿真内存模型在 AXI 写 0x1FE0_01E0 时捕获到的字节序列驱动
//        （`push_valid` + `push_char`），本模块逐字符与 EXPECTED 比对。
//        —— 平台 UART 在 AXI 侧就是"数据寄存器写"（platform-facts §2.5），
//           因此 M1 判据的原始证据 = 这些写；解串行位流是 M5（真串口）才需要的。
//   ② **8N1 串行位流通路**（SERIAL_EN=1）：
//        对 `rx` 做 oversampling 解码：空闲高 → 起始位低 → 8 数据位（LSB 先）
//        → 停止位高；采样点在每 bit 中央（每 bit = CLKS_PER_BIT 个 clk）。
//        解出的字节进入**同一条**比对链路（证据等价）。
//------------------------------------------------------------------------------
// 二、判定口径（fail-closed）
//------------------------------------------------------------------------------
//   · `matched`  ：累计收到 exp_len 个字符且**逐字符**与 EXPECTED 相等（全程无 mismatch）
//   · `mismatch` ：任一字符与期望不符（锁存；TB 必须判 FAIL）
//   · `extra_count`：matched 之后再来的字符数（核多写了 UART ⇒ TB 判 FAIL）
//   · `rx_buf`   ：实际收到的字符序列（供日志/报告直接比对）
//   · `exp_len`  ：EXPECTED 的有效长度（到首个 0 字节为止）
//   本模块**不打印 PASS**：PASS 只由 TB 的唯一判据行给出（08 §8.1 纪律）。
//------------------------------------------------------------------------------
// 三、风格/红线
//------------------------------------------------------------------------------
//   · TESTBENCH 模型（不可综合）；无 FPGA 原语；无 Vivado IP；无旧项目标识。
//   · 采用 assign + function +（必需的）时序 always：状态是"接收计数/移位细胞"。
//==============================================================================
`timescale 1ns / 1ps

module uart_ser_decoder #(
    parameter integer     MAX_LEN       = 32,          // 期望串最大长度
    // ★ 期望串 = "RV32GC-M1-OK\r\n"（14 字符）。
    //   这里**故意写成拼接形式**而不是字符串字面量 `"...\r\n"`：
    //   iverilog 12.0 实测把字符串里的 `\r` 解析成**字面量 'r'**（丢掉反斜杠），
    //   使期望串变成 ...'K','r','\n'（14 字节但第 13 字节是 0x72，不是 0x0D），
    //   而核实际写出的字节是 0x0D ⇒ 假 FAIL。拼接形式无转义歧义，
    //   iverilog/Verilator 解析一致（实测：`"AB\r\n"`→41 42 72 0a；
    //   `{"AB",8'h0D,8'h0A}`→41 42 0d 0a）。
    parameter [8*MAX_LEN-1:0] EXPECTED  = {"RV32GC-M1-OK", 8'h0D, 8'h0A},
    parameter integer     SERIAL_EN     = 0,           // 0=并行字符通路；1=8N1 串行
    parameter integer     CLKS_PER_BIT  = 16           // SERIAL_EN=1 时每 bit 的 clk 数
) (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               clr,          // 同步清零（重新开始比对）

    // ---- ① 并行字符通路（内存模型捕获队列）----
    input  wire               push_valid,
    input  wire [7:0]         push_char,

    // ---- ② 8N1 串行通路 ----
    input  wire               rx,

    // ---- 结果 ----
    output reg                matched,      // 完整匹配 EXPECTED
    output reg                mismatch,     // 出现不匹配字符
    output reg  [15:0]        rx_count,     // 已接收字符数（含不匹配者）
    output reg  [15:0]        extra_count,  // matched 之后的额外字符数
    output reg  [8*MAX_LEN-1:0] rx_buf,     // 已收字符（低位 = 最新；见 rx_buf_left）
    output wire [8*MAX_LEN-1:0] rx_buf_left,// 已收字符**左对齐**视图（供 %s 打印）
    output reg  [7:0]         rx_char,      // 串行通路解出的字节
    output reg                rx_valid      // 串行通路字节有效脉冲
);

    // 已收字符的左对齐视图：第一个收到的字符落在最高字节 ⇒ 可直接 `%s` 打印
    assign rx_buf_left = rx_buf << (8 * (MAX_LEN - ((rx_count > MAX_LEN) ? MAX_LEN : rx_count)));

    //==========================================================================
    // 0. 期望串长度与"当前期望字符"
    //    ★ 位序注意：字符串参数赋给更宽的向量时 Verilog 规则是**左补零**
    //      （字符落在低位），不能直接取最高字节；按下式左移
    //      `8*(MAX_LEN - exp_len + rx_count)` 把"当前期望字符"搬到最高字节。
    //      （该位序已用 iverilog 实测确认：32 字节参数装 "ABC\r\n" 时
    //        最高字节是 0x00、低 5 字节才是字符）
    //==========================================================================
    integer exp_len;                        // EXPECTED 有效长度（initial 中算出）
    reg [8*MAX_LEN-1:0] exp_shifted;        // 当前期望字符被搬到最高字节后的视图

    integer si;
    reg [8*MAX_LEN-1:0] scan;
    initial begin
        scan    = EXPECTED;
        exp_len = 0;
        for (si = 0; si < MAX_LEN; si = si + 1) begin
            if (scan[8*MAX_LEN-1 -: 8] != 8'h00) exp_len = exp_len + 1;
            scan = scan << 8;
        end
        $display("[uart_ser_decoder] EXPECTED 长度 = %0d，期望串 = [%0s]",
                 exp_len, EXPECTED << (8*(MAX_LEN - exp_len)));
    end

    // 动态移位：把"当前期望字符"搬到最高字节
    always @(*) begin
        exp_shifted = EXPECTED << (8 * (MAX_LEN - exp_len + rx_count));
    end
    wire [7:0] exp_char = exp_shifted[8*MAX_LEN-1 -: 8];

    //==========================================================================
    // 1. 8N1 串行接收器（SERIAL_EN=1 时有效；SERIAL_EN=0 时不产生 rx_valid）
    //    状态：IDLE → START（半 bit 对齐）→ DATA（8 拍）→ STOP
    //==========================================================================
    localparam [1:0] S_IDLE = 2'd0, S_START = 2'd1, S_DATA = 2'd2, S_STOP = 2'd3;

    reg [1:0]  s_state;
    reg [15:0] s_cnt;                       // 位内计数器（clk 数）
    reg [2:0]  s_bit;                       // 数据位下标（0..7）
    reg [7:0]  s_shift;

    reg rx_sync1, rx_sync2;                 // 两级同步（抗亚稳；仿真亦保持好习惯）
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin rx_sync1 <= 1'b1; rx_sync2 <= 1'b1; end
        else        begin rx_sync1 <= rx;   rx_sync2 <= rx_sync1; end
    end
    wire rx_i = rx_sync2;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s_state  <= S_IDLE;
            s_cnt    <= 16'd0;
            s_bit    <= 3'd0;
            s_shift  <= 8'h00;
            rx_char  <= 8'h00;
            rx_valid <= 1'b0;
        end else begin
            rx_valid <= 1'b0;
            if (SERIAL_EN == 0) begin
                s_state <= S_IDLE;          // 不启用串行通路：保持静止
            end else begin
                case (s_state)
                    // ---- 空闲：等起始位（下降沿）----
                    S_IDLE: begin
                        s_cnt <= 16'd0;
                        s_bit <= 3'd0;
                        if (rx_i == 1'b0) s_state <= S_START;
                    end
                    // ---- 起始位：半 bit 后到中央再确认 ----
                    S_START: begin
                        if (s_cnt == (CLKS_PER_BIT/2 - 1)) begin
                            s_cnt <= 16'd0;
                            s_state <= (rx_i == 1'b0) ? S_DATA : S_IDLE;  // 中央仍低 ⇒ 真起始位
                        end else begin
                            s_cnt <= s_cnt + 16'd1;
                        end
                    end
                    // ---- 8 个数据位（LSB 先）：每位中央采样 ----
                    S_DATA: begin
                        if (s_cnt == (CLKS_PER_BIT - 1)) begin
                            s_cnt   <= 16'd0;
                            s_shift <= {rx_i, s_shift[7:1]};
                            if (s_bit == 3'd7) begin
                                s_bit   <= 3'd0;
                                s_state <= S_STOP;
                            end else begin
                                s_bit <= s_bit + 3'd1;
                            end
                        end else begin
                            s_cnt <= s_cnt + 16'd1;
                        end
                    end
                    // ---- 停止位（只诊断：错也不改判据，记在 rx_char 上）----
                    S_STOP: begin
                        if (s_cnt == (CLKS_PER_BIT - 1)) begin
                            s_cnt    <= 16'd0;
                            rx_char  <= s_shift;
                            rx_valid <= 1'b1;
                            s_state  <= S_IDLE;
                        end else begin
                            s_cnt <= s_cnt + 16'd1;
                        end
                    end
                    default: s_state <= S_IDLE;
                endcase
            end
        end
    end

    //==========================================================================
    // 2. 统一比对链路（并行字符 / 串行字节二选一）
    //==========================================================================
    wire       byte_v = SERIAL_EN ? rx_valid : push_valid;
    wire [7:0] byte_d = SERIAL_EN ? rx_char  : push_char;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            matched     <= 1'b0;
            mismatch    <= 1'b0;
            rx_count    <= 16'd0;
            extra_count <= 16'd0;
            rx_buf      <= {8*MAX_LEN{1'b0}};
        end else if (clr) begin
            matched     <= 1'b0;
            mismatch    <= 1'b0;
            rx_count    <= 16'd0;
            extra_count <= 16'd0;
            rx_buf      <= {8*MAX_LEN{1'b0}};
        end else if (byte_v) begin
            // 记录到 rx_buf（左移追加：低位 = 最新字符；打印用 rx_buf_left）
            rx_buf <= (rx_buf << 8) | {56'h0, byte_d};

            if (matched) begin
                // 已完整匹配后仍然来字符 ⇒ 核多写了 UART（TB 判 FAIL）
                extra_count <= extra_count + 16'd1;
                $display("[uart_ser_decoder] EXTRA: 匹配后再收到字符 0x%02h", byte_d);
            end else if (rx_count >= MAX_LEN) begin
                mismatch    <= 1'b1;
                extra_count <= extra_count + 16'd1;
                $display("[uart_ser_decoder] FAIL: 超过 MAX_LEN=%0d 仍未见完整期望串", MAX_LEN);
            end else begin
                if (byte_d !== exp_char) begin
                    mismatch <= 1'b1;       // 锁存：TB 必须判 FAIL
                    $display("[uart_ser_decoder] FAIL: 第 %0d 个字符 0x%02h 与期望 0x%02h 不符",
                             rx_count, byte_d, exp_char);
                end else if ((rx_count + 16'd1) == exp_len) begin
                    matched <= 1'b1;
                    $display("[uart_ser_decoder] 期望串完整匹配：%0d 字符", exp_len);
                end
                rx_count <= rx_count + 16'd1;
            end
        end
    end

endmodule
