//==============================================================================
// sim/tb/tb_core_top.sv —— core_top 顶层集成 TB（M1 里程碑：首条取指 + UART 回显）
//==============================================================================
// 项目  : rv32gc-cpu（阶段二 2A）
// 归属  : docs/design/08-baseline-5stage.md §2 M1（判据①②）、§3.2、§4（48 端口
//         逐字契约）、§8.1（单元/集成测试"未捕获即失败"纪律）
// 顶层名: tb_core_top（验收命令用 `-s tb_core_top` 指定）
//------------------------------------------------------------------------------
// 一、结构
//------------------------------------------------------------------------------
//   tb_core_top
//     ├── u_dut  : rtl/top/core_top.v（48 端口逐字例化，rtl 只读）
//     ├── u_mem  : sim/tb/sim_mem_model.sv（AXI4 从设备：XIP/DDR3 数组 + UART 捕获）
//     └── u_uart : sim/tb/uart_ser_decoder.sv（期望串 "RV32GC-M1-OK\r\n" 校验）
//
//   程序映像：TB 参数 `PROG_HEX`（默认 sim/tb/prog/m1_uart.S 经 as/ld/objcopy 生成的
//             m1_uart.hex），由 u_mem 的 `load_xip_hex()` 预载到 XIP 窗口。
//
//------------------------------------------------------------------------------
// 二、判据（全部 fail-closed；任一不满足 ⇒ 打印 TB_M1: FAIL ... + $fatal，rc≠0）
//------------------------------------------------------------------------------
//   C1 复位释放后**首笔 AXI 读地址 = 0x1C00_0000**（M1 判据①）。
//      观测点 = AXI AR 通道（u_mem.first_ar_addr），**不是**核内层次引用；
//      层次引用（u_dut.u_fetch_unit.fetch_pc）只作诊断打印。
//   C2 在时限内 UART 数据寄存器 0x1FE0_01E0 被写入完整 "RV32GC-M1-OK\r\n"
//      （14 字符，逐字符比对；M1 判据②）。
//   C3 程序映像确实载入（load_err=0 且有足够多的非零字）；
//   C4 无多余字符（匹配后再写 UART ⇒ FAIL）、无 UART 队列溢出。
//   C5 超时（TIMEOUT_CYCLES 拍内未匹配）⇒ FAIL。
//   ★ 本 TB **不打印任何兜底 PASS**：唯一 PASS 行是
//       "TB_M1_CORE_TOP_UNIT: PASS"
//     且只在 C1–C4 全部通过时打印一次。
//
//------------------------------------------------------------------------------
// 三、复位/时钟口径
//------------------------------------------------------------------------------
//   · 时钟 10 ns 周期（仿真用；上板 33 MHz 同域，见 platform-facts §5）；
//   · aresetn 低有效：先保持 RESET_CYCLES 拍，在**负沿**释放（避免与 posedge 竞争）。
//   · intrpt=0（M1 不做中断）、break_point=0、infor_flag=0、reg_num=0。
//------------------------------------------------------------------------------
// 四、风格/红线
//------------------------------------------------------------------------------
//   · TESTBENCH（不可综合）；无 FPGA 原语；无 Vivado IP；无旧项目标识。
//   · `always` 块只用于时钟、复位、提交观测计数（TB 必需），无综合语义要求。
//==============================================================================
`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"

module tb_core_top #(
    // ---- 程序映像（可用 -P tb_core_top.PROG_HEX=\"...\" 覆盖）----
    parameter [8*512-1:0]  PROG_HEX       = "sim/tb/prog/m1_uart.hex",
    // ---- 判据参数 ----
    // 期望串 = "RV32GC-M1-OK\r\n"（14 字符；★ 用拼接形式而非 `"...\r\n"` 字面量：
    //   iverilog 12.0 实测把 `\r` 解析成字面量 'r'，会与核写出的 0x0D 假冲突）
    parameter [8*32-1:0]   EXPECT_STR     = {"RV32GC-M1-OK", 8'h0D, 8'h0A},
    parameter integer      TIMEOUT_CYCLES = 200000,               // 超时拍数
    parameter integer      POST_MATCH_DRAIN = 200,                // 匹配后再观察（抓多余字符）
    parameter integer      RESET_CYCLES   = 20,                   // 复位保持拍数
    parameter integer      CLK_HALF_NS    = 5,                    // 半周期 5 ns ⇒ 10 ns
    parameter integer      READ_LAT_DLY   = 0,                    // AXI 从设备读延迟
    parameter integer      DIAG_NO_REQ_CYCLES = 200               // 无读请求时的诊断打印点
) ();

    // 左对齐字符串（把右对齐的参数串搬到高位，便于 `%0s` 打印路径）
    function [8*512-1:0] str_lj;
        input [8*512-1:0] s;
        integer j, n;
        reg [8*512-1:0] t;
        begin
            t = s; n = 0;
            for (j = 0; j < 512; j = j + 1) begin
                if (t[8*512-1 -: 8] != 8'h00) n = n + 1;
                t = t << 8;
            end
            str_lj = s << (8*(512 - n));
        end
    endfunction

    //==========================================================================
    // 0. 时钟 / 复位
    //==========================================================================
    reg clk;
    reg aresetn;

    initial clk = 1'b0;
    always #(CLK_HALF_NS) clk = ~clk;

    //==========================================================================
    // 1. DUT ↔ TB 的 AXI4 连线
    //==========================================================================
    // AR
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
    // R
    wire [3:0]  rid;
    wire [31:0] rdata;
    wire [1:0]  rresp;
    wire        rlast;
    wire        rvalid;
    wire        rready;
    // AW
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
    // W
    wire [3:0]  wid;
    wire [31:0] wdata;
    wire [3:0]  wstrb;
    wire        wlast;
    wire        wvalid;
    wire        wready;
    // B
    wire [3:0]  bid;
    wire [1:0]  bresp;
    wire        bvalid;
    wire        bready;

    // 调试组（平台契约；M1 输入恒 0，输出仅观测）
    wire        ws_valid;
    wire [31:0] rf_rdata;
    wire [31:0] debug0_wb_pc;
    wire [3:0]  debug0_wb_rf_wen;
    wire [4:0]  debug0_wb_rf_wnum;
    wire [31:0] debug0_wb_rf_wdata;

    //======================================================================
    // 2. DUT：rtl/top/core_top.v（48 端口逐字契约，08 §4.1）
    //======================================================================
    core_top u_dut (
        // ---- 时钟 / 复位 / 中断（#1–#3）----
        .aclk              (clk),
        .intrpt            (8'h00),            // M1 不做中断（高 3 位恒 0）
        .aresetn           (aresetn),

        // ---- AR（#4–#13）----
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

        // ---- R（#14–#19）----
        .rid               (rid),
        .rdata             (rdata),
        .rresp             (rresp),
        .rlast             (rlast),
        .rvalid            (rvalid),
        .rready            (rready),

        // ---- AW（#20–#29）----
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

        // ---- W（#30–#35）----
        .wid               (wid),
        .wdata             (wdata),
        .wstrb             (wstrb),
        .wlast             (wlast),
        .wvalid            (wvalid),
        .wready            (wready),

        // ---- B（#36–#39）----
        .bid               (bid),
        .bresp             (bresp),
        .bvalid            (bvalid),
        .bready            (bready),

        // ---- 调试组（#40–#48）----
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

    //======================================================================
    // 3. 仿真内存模型（AXI4 从设备 + UART 捕获）
    //======================================================================
    wire [7:0]  uart_char;
    wire        uart_char_valid;
    wire [31:0] uart_tx_count;
    wire        uart_overflow;
    wire [31:0] uart_bad_strb_count;

    sim_mem_model #(
        .READ_LAT_DLY     (READ_LAT_DLY)
    ) u_mem (
        .clk              (clk),
        .rst_n            (aresetn),

        .arid             (arid),
        .araddr           (araddr),
        .arlen            (arlen),
        .arsize           (arsize),
        .arburst          (arburst),
        .arlock           (arlock),
        .arcache          (arcache),
        .arprot           (arprot),
        .arvalid          (arvalid),
        .arready          (arready),

        .rid              (rid),
        .rdata            (rdata),
        .rresp            (rresp),
        .rlast            (rlast),
        .rvalid           (rvalid),
        .rready           (rready),

        .awid             (awid),
        .awaddr           (awaddr),
        .awlen            (awlen),
        .awsize           (awsize),
        .awburst          (awburst),
        .awlock           (awlock),
        .awcache          (awcache),
        .awprot           (awprot),
        .awvalid          (awvalid),
        .awready          (awready),

        .wid              (wid),
        .wdata            (wdata),
        .wstrb            (wstrb),
        .wlast            (wlast),
        .wvalid           (wvalid),
        .wready           (wready),

        .bid              (bid),
        .bresp            (bresp),
        .bvalid           (bvalid),
        .bready           (bready),

        .uart_char        (uart_char),
        .uart_char_valid  (uart_char_valid),
        .uart_tx_count    (uart_tx_count),
        .uart_overflow    (uart_overflow),
        .uart_bad_strb_count(uart_bad_strb_count)
    );

    //======================================================================
    // 4. UART 期望串校验器（并行字符通路；M1 判据②）
    //======================================================================
    wire        uart_matched;
    wire        uart_mismatch;
    wire [15:0] uart_rx_count;
    wire [15:0] uart_extra_count;
    wire [8*32-1:0] uart_rx_buf_left;

    uart_ser_decoder #(
        .MAX_LEN      (32),
        .EXPECTED     (EXPECT_STR),           // "RV32GC-M1-OK\r\n"
        .SERIAL_EN    (0),                    // M1：走 AXI 写捕获的并行字符通路
        .CLKS_PER_BIT (16)
    ) u_uart (
        .clk          (clk),
        .rst_n        (aresetn),
        .clr          (1'b0),
        .push_valid   (uart_char_valid),
        .push_char    (uart_char),
        .rx           (1'b1),                 // 串行口空闲高（本 TB 不用串行通路）
        .matched      (uart_matched),
        .mismatch     (uart_mismatch),
        .rx_count     (uart_rx_count),
        .extra_count  (uart_extra_count),
        .rx_buf       (),
        .rx_buf_left  (uart_rx_buf_left),
        .rx_char      (),
        .rx_valid     ()
    );

    //======================================================================
    // 5. 判据①：首条取指 AR 地址（AXI 观测；层次引用仅诊断）
    //======================================================================
    reg        chk_ar_done;
    reg [31:0] chk_ar_addr;
    reg [31:0] diag_cyc;                    // 复位释放后的拍数（用于"无请求"诊断）
    reg        diag_done;

    always @(posedge clk) begin
        if (!aresetn) begin
            chk_ar_done <= 1'b0;
            chk_ar_addr <= 32'h0;
            diag_cyc    <= 32'd0;
            diag_done   <= 1'b0;
        end else begin
            if (!chk_ar_done && u_mem.first_ar_seen) begin
                chk_ar_done <= 1'b1;
                chk_ar_addr <= u_mem.first_ar_addr;
                $display("TB_M1_CHECK: 首条取指 AR 地址 = 0x%08h（期望 0x%08h：RESET_PC=XIP 主窗口） ⇒ %0s",
                         u_mem.first_ar_addr, `RV32GC_RESET_PC,
                         (u_mem.first_ar_addr == `RV32GC_RESET_PC) ? "OK" : "FAIL");
                // ★ 层次引用：只作诊断（判据用上面的 AXI 观测）
                $display("TB_M1_DIAG : core_top 内部 fetch_pc = 0x%08h（层次引用，仅诊断）",
                         u_dut.u_fetch_unit.fetch_pc);
            end
            // 长时间没有任何读请求 ⇒ 打一次核内观测（定位"卡在 F 级/组合环"用）
            if (!chk_ar_done) begin
                diag_cyc <= diag_cyc + 32'd1;
                if (!diag_done && (diag_cyc == DIAG_NO_REQ_CYCLES)) begin
                    diag_done <= 1'b1;
                    $display("TB_M1_DIAG : %0d 拍内未见任何 AXI 读请求；核内观测（层次引用，仅诊断）: fetch_pc=0x%08h pipe_adv=%b fetch_pause=%b fu_fetch_req_valid=%b fu_fetch_req_pa=0x%08h fu_fetch_req_uncached=%b xip_fetch_busy=%b m_busy=%b",
                             DIAG_NO_REQ_CYCLES,
                             u_dut.u_fetch_unit.fetch_pc, u_dut.pipe_adv, u_dut.fetch_pause,
                             u_dut.fu_fetch_req_valid, u_dut.fu_fetch_req_pa,
                             u_dut.fu_fetch_req_uncached, u_dut.xip_fetch_busy, u_dut.m_busy);
                end
            end
        end
    end

    //======================================================================
    // 6. 提交观测（诊断：证明核在真跑指令）
    //======================================================================
    integer commit_count;
    integer commit_print_lim;
    initial begin
        commit_count      = 0;
        commit_print_lim  = 24;              // 只打印前若干条，避免刷屏
    end
    always @(posedge clk) begin
        if (aresetn && ws_valid) begin
            if (commit_count < commit_print_lim)
                $display("TB_M1_DIAG : 提交 #%0d pc=0x%08h wen=%b rd=x%0d wdata=0x%08h insn 侧 pc_next 观测于 debug0_wb_pc",
                         commit_count, debug0_wb_pc, debug0_wb_rf_wen[0],
                         debug0_wb_rf_wnum, debug0_wb_rf_wdata);
            commit_count = commit_count + 1;
        end
    end

    //======================================================================
    // 7. 主流程：载入程序 → 复位 → 放行 → 等判据 → 汇总判定
    //======================================================================
    integer cyc;
    reg     pass;
    integer i;

    initial begin
        //------------------------------------------------------------------
        // 7.1 载入程序映像（XIP 预载）
        //------------------------------------------------------------------
        aresetn = 1'b0;
        $display("========================================================================");
        $display("TB_M1_CORE_TOP_UNIT: 开始（M1：首条取指 0x%08h + UART 回显 \"RV32GC-M1-OK\\r\\n\"）",
                 `RV32GC_RESET_PC);
        $display("  PROG_HEX = %0s", str_lj(PROG_HEX));
        u_mem.load_xip_hex(PROG_HEX);
        $display("TB_M1_DIAG : XIP 前 8 字 = %08h %08h %08h %08h %08h %08h %08h %08h",
                 u_mem.xip_mem[0], u_mem.xip_mem[1], u_mem.xip_mem[2], u_mem.xip_mem[3],
                 u_mem.xip_mem[4], u_mem.xip_mem[5], u_mem.xip_mem[6], u_mem.xip_mem[7]);

        //------------------------------------------------------------------
        // 7.2 复位保持 RESET_CYCLES 拍，负沿释放
        //------------------------------------------------------------------
        repeat (RESET_CYCLES) @(posedge clk);
        @(negedge clk);
        aresetn = 1'b1;
        $display("TB_M1_DIAG : aresetn 已释放（保持 %0d 拍）", RESET_CYCLES);

        //------------------------------------------------------------------
        // 7.3 等判据：matched / mismatch / 超时
        //------------------------------------------------------------------
        cyc = 0;
        while (!uart_matched && !uart_mismatch && (cyc < TIMEOUT_CYCLES)) begin
            @(posedge clk);
            cyc = cyc + 1;
        end

        // 匹配后再观察一段，抓"多余字符"（C4）
        if (uart_matched) begin
            repeat (POST_MATCH_DRAIN) @(posedge clk);
            cyc = cyc + POST_MATCH_DRAIN;
        end

        //------------------------------------------------------------------
        // 7.4 汇总证据
        //------------------------------------------------------------------
        $display("------------------------------------------------------------------------");
        $display("TB_M1_DIAG : PROG_HEX 载入 err=%0d words=%0d nonzero=%0d",
                 u_mem.load_err, u_mem.load_words, u_mem.load_nonzero);
        $display("TB_M1_DIAG : AXI 计数 ar=%0d aw=%0d r_beat=%0d w_beat=%0d unknown_rd=%0d",
                 u_mem.ar_count, u_mem.aw_count, u_mem.r_beat_count,
                 u_mem.w_beat_count, u_mem.unknown_rd_count);
        $display("TB_M1_DIAG : 首笔 AR 地址 = 0x%08h（seen=%b）",
                 u_mem.first_ar_addr, u_mem.first_ar_seen);
        $display("TB_M1_DIAG : core_top 内部 fetch_pc = 0x%08h（层次引用，仅诊断）",
                 u_dut.u_fetch_unit.fetch_pc);
        $display("TB_M1_DIAG : 提交指令数 = %0d，最后提交 pc=0x%08h",
                 commit_count, debug0_wb_pc);

        // UART 捕获字节逐字符 dump（判据②的原始证据）
        $write(   "TB_M1_UART : 捕获 %0d 字节 = ", u_mem.uart_tx_count);
        for (i = 0; i < 24; i = i + 1) begin
            if (i < uart_tx_count) begin
                $write("0x%02h '%c' | ", u_mem.uart_tx_queue[i], u_mem.uart_tx_queue[i]);
            end
        end
        $write("\n");
        $display("TB_M1_UART : 解码器收到 = [%0s]（count=%0d matched=%b mismatch=%b extra=%0d）",
                 uart_rx_buf_left, uart_rx_count, uart_matched, uart_mismatch,
                 uart_extra_count);
        $display("------------------------------------------------------------------------");

        //------------------------------------------------------------------
        // 7.5 判定（fail-closed：逐项列举，任一项不满足 ⇒ FAIL）
        //------------------------------------------------------------------
        pass = 1'b1;
        if (u_mem.load_err != 0) begin
            pass = 1'b0;
            $display("TB_M1: FAIL C3 PROG_HEX 载入失败（load_err=%0d）", u_mem.load_err);
        end
        if (u_mem.load_words == 0 || u_mem.load_nonzero < 8) begin
            pass = 1'b0;
            $display("TB_M1: FAIL C3 程序映像未载入（words=%0d nonzero=%0d）",
                     u_mem.load_words, u_mem.load_nonzero);
        end
        if (!u_mem.first_ar_seen) begin
            pass = 1'b0;
            $display("TB_M1_CHECK: C1 首条取指 AR 地址 = <未观测到任何 AXI 读请求>（期望 0x%08h） ⇒ FAIL",
                     `RV32GC_RESET_PC);
            $display("TB_M1: FAIL C1 复位后未观察到任何 AXI 读请求（取指通路未发起总线请求）");
        end else if (u_mem.first_ar_addr != `RV32GC_RESET_PC) begin
            pass = 1'b0;
            $display("TB_M1: FAIL C1 首条取指 AR 地址 = 0x%08h，期望 0x%08h",
                     u_mem.first_ar_addr, `RV32GC_RESET_PC);
        end else begin
            $display("TB_M1_CHECK: C1 首条取指 AR 地址 = 0x%08h ⇒ OK", u_mem.first_ar_addr);
        end
        if (uart_overflow) begin
            pass = 1'b0;
            $display("TB_M1: FAIL C4 UART 捕获队列溢出");
        end
        if (uart_mismatch) begin
            pass = 1'b0;
            $display("TB_M1: FAIL C2 UART 字符与期望串不符（已收 %0d 字符）", uart_rx_count);
        end
        if (uart_extra_count != 0) begin
            pass = 1'b0;
            $display("TB_M1: FAIL C4 匹配后仍收到 %0d 个多余字符", uart_extra_count);
        end
        if (!uart_matched) begin
            pass = 1'b0;
            $display("TB_M1: FAIL C2/C5 %0d 拍内未收到完整期望串 \"RV32GC-M1-OK\\r\\n\"（已收 %0d 字符）",
                     TIMEOUT_CYCLES, uart_rx_count);
        end else begin
            $display("TB_M1_CHECK: C2 已收到完整期望串（14 字符）⇒ OK");
        end

        $display("TB_M1_SUMMARY: cycles=%0d load_err=%0d first_ar=0x%08h ar=%0d aw=%0d uart_bytes=%0d matched=%b",
                 cyc, u_mem.load_err, u_mem.first_ar_addr, u_mem.ar_count,
                 u_mem.aw_count, u_mem.uart_tx_count, uart_matched);

        if (pass) begin
            $display("========================================================================");
            $display("TB_M1_CORE_TOP_UNIT: PASS");       // ★ 唯一 PASS 行
            $display("========================================================================");
            $finish;
        end else begin
            $display("========================================================================");
            $display("TB_M1: FAIL —— 判据未全部达成（详见上面各 Cx 行；本 TB 无兜底 PASS）");
            $display("========================================================================");
            $fatal(1, "TB_M1 FAIL");
        end
    end

endmodule
