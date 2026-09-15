//==============================================================================
// sim/tb/tb_arch_test.sv —— arch-test（ACT4）DUT 侧仿真 TB
//==============================================================================
// 项目  : rv32gc-cpu（阶段二 2A；docs/design/08-baseline-5stage.md §8.2/§8.2.1）
// 顶层名: tb_arch_test（run.sh 用 `-s tb_arch_test` 指定）
// 归属  : sim/arch_test/run.sh 的「DUT 仿真」一步：编译好的用例 ELF 经
//         objcopy 转 hex 后由 -P PROG_HEX 传入本 TB，跑到 HTIF 终止点，
//         把 signature 区导出成 `<addr> <data>` 行文件供与 Spike 参考签名逐行比对。
//------------------------------------------------------------------------------
// 一、结构（自洽，不依赖 sim/tb/sim_mem_model.sv）
//------------------------------------------------------------------------------
//   tb_arch_test
//     ├── u_dut : rtl/top/core_top.v（48 端口逐字例化，rtl 只读）
//     └── 本文件内置 AXI4 从设备存储体 + HTIF(tohost) 终端/退出语义
//
//   为什么不用 sim_mem_model.sv：
//     · 该模型的 DDR3 存储体按 `ddr3_mem[a[31:2]]` 直接寻址（平台布局 0x0 起），
//       搬到 0x8000_0000 会越界（数组只有 (LIMIT-BASE)/4 个元素）；
//     · arch-test 镜像按 `sim/arch_test/link.ld` 链接在 0x8000_0000，且需要
//       "多 @ 记录 hex 载入 + tohost 终止 + 签名导出"三件该模型不提供的能力；
//     · 该文件在本任务范围外（只许新建 sim/tb/tb_arch_test.sv），故不修改它。
//
//------------------------------------------------------------------------------
// 二、内存布局（与 sim/arch_test/link.ld、run.sh 的 spike -m 三者一致）
//------------------------------------------------------------------------------
//   0x8000_0000 + 1 MiB : 用例镜像 RAM（.text.init/.text.rvtest/.data/
//                         .text.rvmodel/.tohost；由 PROG_HEX 预载）
//   0x1C00_0000 + 64 字  : 复位向量窗口（.boot 复位桩；由同一个 PROG_HEX 预载）
//   0x1000_0000          : NS16550 风格 UART（THR=+0 写→打印；LSR=+5 读=0x20）
//                          —— 与 Spike 参考模型内建 UART 同址同语义
//   0x5000_0000 + 4 KiB  : **显式返回 DECERR** 的访问故障窗口
//                          （对应 rvmodel_macros.h 的 RVMODEL_ACCESS_FAULT_ADDRESS）
//   其余未登记地址        : 读 0、写忽略并告警（不静默变成故障；与平台口径一致）
//
//------------------------------------------------------------------------------
// 三、终止与签名（**判定口径**）
//------------------------------------------------------------------------------
//   终止信号 = HTIF 语义的 `tohost`（地址由 link.ld 固定在 RAM+0x000F_F000，
//   由 run.sh 用 nm 复核后经 -P TOHOST_ADDR 传入）。用例自身写 tohost：
//     · `sw 1, 0(tohost)` + `sw 0, 4(tohost)`        ⇒ PASS（程序跑到终止点）
//     · `sw 3, 0(tohost)` + `sw 0, 4(tohost)`        ⇒ FAIL（程序自报失败）
//     · `sw <ch>, 0(tohost)` + `sw 0x01010000, 4(...)` ⇒ HTIF 终端字符
//       （sig 版用例的 RVCP-SUMMARY/诊断串走这条通路；TB 原样打印到日志供取证）
//   本 TB **不猜**"程序是否跑完"：只见 tohost 终止码；到点前超时 ⇒ FAIL。
//
//   到终止点后把 [SIG_BASE, SIG_BASE + 4*SIG_WORDS) 导出到 SIG_FILE，
//   每行 `<8位地址> <8位数据>`（小端字值；与 Spike `+signature-granularity=4`
//   的每行一字等价，run.sh 比对时取数据列）。
//
//------------------------------------------------------------------------------
// 四、"未捕获即失败"（08 §8.1；AGENT.md §0.6）
//------------------------------------------------------------------------------
//   · PASS 判定要求**全部**条件成立：镜像载入无误、复位桩/入口字正确、
//     程序写到 PASS 终止码、签名区完全落在 RAM 内、签名文件成功写出且行数匹配；
//   · 任一条件不成立 ⇒ 打印 `TB_ARCH_TEST: FAIL ...` + `$fatal`（rc≠0），
//     绝不打印 PASS 字样；
//   · 本 TB 唯一 PASS 行 = `TB_ARCH_TEST: PASS`。
//
//------------------------------------------------------------------------------
// 五、风格/红线
//------------------------------------------------------------------------------
//   · TESTBENCH（不可综合）：状态机/存储体用 always 块描述是建模必需；
//   · 无 FPGA 原语、无 Vivado IP 依赖 ⇒ iverilog 回归自洽（红线 1/2 合规）；
//   · 本文件的 AXI 逻辑是**从设备行为模型（验证件）**，不是设计侧代码：
//     红线 4 的边界判据针对可综合 RTL（08 §7.1）。
//==============================================================================
`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"

module tb_arch_test #(
    // ---- 镜像与输出（由 run.sh 以 -P 覆盖）----
    parameter [8*512-1:0] PROG_HEX = "sim/arch_test/work/prog.hex",
    parameter [8*512-1:0] SIG_FILE = "sim/arch_test/work/prog.dut.signature",

    // ---- 内存布局 ----
    parameter [31:0]  RAM_BASE    = 32'h8000_0000,
    parameter integer RAM_WORDS   = 262144,          // 1 MiB
    parameter [31:0]  BOOT_BASE   = 32'h1C00_0000,   // 复位向量窗口（.boot）
    parameter integer BOOT_WORDS  = 64,
    parameter [31:0]  UART_BASE   = 32'h1000_0000,
    parameter [31:0]  FAULT_BASE  = 32'h5000_0000,   // DECERR 窗口
    parameter [31:0]  ENTRY_PC    = 32'h8000_0000,   // rvtest_entry_point

    // ---- 签名区（run.sh 用 nm 从 ELF 取，必须落在 RAM 内）----
    parameter [31:0]  SIG_BASE    = 32'h8000_0000,
    parameter integer SIG_WORDS   = 1,
    parameter [31:0]  TOHOST_ADDR = 32'h800F_F000,

    // ---- 判定参数 ----
    parameter integer TIMEOUT_CYCLES      = 4000000,  // 超时拍数 ⇒ FAIL
    parameter integer RESET_CYCLES        = 20,       // 复位保持拍数
    parameter integer CLK_HALF_NS         = 5,        // 半周期（10 ns 周期）
    parameter integer DIAG_NO_REQ_CYCLES  = 400,      // 无总线活动时的诊断点
    parameter integer COMMIT_PRINT_LIM    = 12,       // 提交观测打印上限（诊断）
    parameter integer HEARTBEAT_CYCLES    = 0,        // >0 ⇒ 每 N 拍打印一次进度（诊断）
    // 复位桩首字 = `lui x5, 0x80000`（见 sim/arch_test/boot_stub.S）；
    // 用于 fail-closed 校验"镜像里确实有复位桩"，防止空/错镜像假通过。
    parameter [31:0]  BOOT_STUB_W0        = 32'h8000_02B7
) ();

    //==========================================================================
    // 0. 辅助函数
    //==========================================================================
    // 右对齐定长串 → 左对齐（便于 %0s 打印路径）
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

    function integer hex_digit;
        input integer c;
        begin
            if ((c >= "0") && (c <= "9"))      hex_digit = c - "0";
            else if ((c >= "a") && (c <= "f")) hex_digit = c - "a" + 10;
            else if ((c >= "A") && (c <= "F")) hex_digit = c - "A" + 10;
            else                               hex_digit = -1;
        end
    endfunction

    //==========================================================================
    // 1. 时钟 / 复位
    //==========================================================================
    reg clk;
    reg aresetn;

    initial clk = 1'b0;
    always #(CLK_HALF_NS) clk = ~clk;

    //==========================================================================
    // 2. DUT ↔ 本 TB 的 AXI4 连线
    //==========================================================================
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

    wire        ws_valid;
    wire [31:0] rf_rdata;
    wire [31:0] debug0_wb_pc;
    wire [3:0]  debug0_wb_rf_wen;
    wire [4:0]  debug0_wb_rf_wnum;
    wire [31:0] debug0_wb_rf_wdata;

    //==========================================================================
    // 3. DUT：rtl/top/core_top.v（48 端口逐字契约，08 §4.1；rtl 只读）
    //==========================================================================
    core_top u_dut (
        .aclk              (clk),
        .intrpt            (8'h00),            // arch-test 非特权子集不触发外部中断
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
    // 4. 存储体与地址译码
    //==========================================================================
    localparam [1:0] RESP_OKAY   = `RV32GC_AXI_RESP_OKAY;
    localparam [1:0] RESP_DECERR = 2'b11;

    reg [31:0] ram  [0:RAM_WORDS-1];    // 0x8000_0000 起的用例镜像
    reg [31:0] boot [0:BOOT_WORDS-1];   // 0x1C00_0000 复位向量窗口

    function is_ram;    input [31:0] a; begin is_ram    = (a >= RAM_BASE)  && (a < RAM_BASE  + 4*RAM_WORDS);  end endfunction
    function is_boot;   input [31:0] a; begin is_boot   = (a >= BOOT_BASE) && (a < BOOT_BASE + 4*BOOT_WORDS); end endfunction
    function is_uart;   input [31:0] a; begin is_uart   = (a[31:8] == UART_BASE[31:8]); end endfunction
    function is_fault;  input [31:0] a; begin is_fault  = (a[31:24] == FAULT_BASE[31:24]); end endfunction

    // 读一个字（组合；未写过的字节按 0 返回 —— 与"上电全 0"等价）
    function [31:0] mem_read;
        input [31:0] a;
        reg [31:0] w;
        begin
            if (is_ram(a))       w = ram[(a - RAM_BASE) >> 2];
            else if (is_boot(a)) w = boot[(a - BOOT_BASE) >> 2];
            else                 w = 32'h0000_0000;

            if (is_uart(a)) begin
                mem_read = (a[7:0] == 8'h05) ? 32'h0000_0020   // LSR.THRE=1（THR 空）
                                                 : 32'h0000_0000;  // RBR/其它：0
            end else begin
                // 未写过的字节按 0 返回（x 传播会让取指通路"看似有指令"）
                mem_read = { (^w[31:24] === 1'bx) ? 8'h00 : w[31:24],
                             (^w[23:16] === 1'bx) ? 8'h00 : w[23:16],
                             (^w[15: 8] === 1'bx) ? 8'h00 : w[15: 8],
                             (^w[ 7: 0] === 1'bx) ? 8'h00 : w[ 7: 0] };
            end
        end
    endfunction

    // 响应：故障窗口返回 DECERR（供 access fault 类用例），其余 OKAY
    function [1:0] mem_resp;
        input [31:0] a;
        begin
            mem_resp = is_fault(a) ? RESP_DECERR : RESP_OKAY;
        end
    endfunction

    //==========================================================================
    // 5. HTIF 语义（tohost 写入：终端字符 / PASS / FAIL）
    //==========================================================================
    reg [31:0] htif_cmd;          // 高字（device/cmd）
    reg        htif_cmd_valid;    // 写高字后 1 拍有效
    reg [31:0] tohost_lo;         // 低字（payload）
    integer    uart_chars;        // 控制台字符计数

    // 可观测计数
    reg [31:0] ar_count, aw_count, r_beat_count, w_beat_count;
    reg [31:0] unknown_rd_count, unknown_wr_count;
    reg [31:0] bus_cycles;
    reg        first_ar_seen;
    reg [31:0] first_ar_addr;
    integer    commit_count;
    integer    i;

    // AXI 写：按 wstrb 落字节；并处理 tohost 的 HTIF 语义
    task automatic do_write;
        input [31:0] a;
        input [31:0] d;
        input [3:0]  strb;
        reg [31:0] widx;
        begin
            if (is_ram(a)) begin
                widx = (a - RAM_BASE) >> 2;
                if (strb[0]) ram[widx][ 7: 0] = d[ 7: 0];
                if (strb[1]) ram[widx][15: 8] = d[15: 8];
                if (strb[2]) ram[widx][23:16] = d[23:16];
                if (strb[3]) ram[widx][31:24] = d[31:24];
                // ---- HTIF：tohost 低字（payload）/ 高字（device+cmd）----
                if (a == TOHOST_ADDR) begin
                    tohost_lo = d;
                end else if (a == TOHOST_ADDR + 4) begin
                    if (d == 32'h0101_0000) begin           // device=1（终端）cmd=1（输出）
                        uart_chars = uart_chars + 1;
                        $write("%c", tohost_lo[7:0]);
                        if ((uart_chars % 64) == 0) $write("\n");
                    end else begin                           // 其余走主流程判定（退出码等）
                        htif_cmd       = d;
                        htif_cmd_valid = 1'b1;
                    end
                end
            end else if (is_boot(a)) begin
                $display("[tb_arch_test] WARN: 对复位向量窗口的写被忽略 addr=0x%08h", a);
            end else if (is_uart(a)) begin
                $display("[tb_arch_test] UART 写 addr=0x%08h data=0x%02h '%c'",
                         a, d[7:0], (d[7:0] > 8'h20) ? d[7:0] : 8'h2e);
            end else if (is_fault(a)) begin
                $display("[tb_arch_test] NOTE: 对故障窗口的写（预期产生 store access fault）addr=0x%08h", a);
            end else begin
                unknown_wr_count = unknown_wr_count + 1;
                if (unknown_wr_count <= 8)
                    $display("[tb_arch_test] WARN: 未登记区域写被忽略 addr=0x%08h data=0x%08h strb=%b",
                             a, d, strb);
            end
        end
    endtask

    //==========================================================================
    // 6. AXI4 从设备（单笔在途；AR→R 逐拍，AW/W→B；读延迟 1 拍）
    //==========================================================================
    reg        arready_r;
    reg        rd_active;
    reg        rd_pend;
    reg [31:0] rd_addr_q;
    reg [3:0]  rd_len_q;
    reg [3:0]  rd_id_q;
    reg [4:0]  rd_cnt_q;

    reg        awready_r;
    reg        wr_pend;
    reg        bvalid_r;
    reg [31:0] aw_addr_q;
    reg [3:0]  aw_len_q;
    reg [3:0]  aw_id_q;
    reg [4:0]  w_cnt_q;

    assign arready = arready_r;
    assign rid     = rd_id_q;
    assign rdata   = mem_read(rd_addr_q);
    assign rresp   = mem_resp(rd_addr_q);
    assign rvalid  = rd_active;
    assign rlast   = (rd_cnt_q[3:0] == rd_len_q);

    assign awready = awready_r;
    assign wready  = wr_pend & ~bvalid_r;
    assign bid     = aw_id_q;
    assign bresp   = mem_resp(aw_addr_q);
    assign bvalid  = bvalid_r;

    wire ar_fire = arvalid & arready;
    wire r_fire  = rvalid & rready;
    wire aw_fire = awvalid & awready;
    wire w_fire  = wvalid & wready;
    wire b_fire  = bvalid & bready;

    // 提交观测（诊断：证明核在真跑指令）
    initial commit_count = 0;
    always @(posedge clk) begin
        if (aresetn && ws_valid) begin
            if (commit_count < COMMIT_PRINT_LIM)
                $display("[tb_arch_test] 提交 #%0d pc=0x%08h wen=%b rd=x%0d wdata=0x%08h",
                         commit_count, debug0_wb_pc, debug0_wb_rf_wen[0],
                         debug0_wb_rf_wnum, debug0_wb_rf_wdata);
            commit_count = commit_count + 1;
        end
    end

    // 心跳（诊断：定位"卡在哪儿/多慢"）
    integer hb_cnt;
    initial hb_cnt = 0;
    always @(posedge clk) begin
        if (!aresetn) hb_cnt = 0;
        else if (HEARTBEAT_CYCLES > 0) begin
            hb_cnt = hb_cnt + 1;
            if (hb_cnt >= HEARTBEAT_CYCLES) begin
                hb_cnt = 0;
                $display("[tb_arch_test] 心跳: 拍=%0d 提交=%0d 最后提交 pc=0x%08h ar=%0d aw=%0d 首AR=0x%08h",
                         bus_cycles, commit_count, debug0_wb_pc, ar_count, aw_count, first_ar_addr);
                // 层次引用（仅诊断；判据一律用 AXI 观测）
                $display("[tb_arch_test]   DIAG: fetch_pc=0x%08h pipe_adv=%b fetch_pause=%b fu_req_v=%b fu_req_pa=0x%08h m_busy=%b",
                         u_dut.u_fetch_unit.fetch_pc, u_dut.pipe_adv, u_dut.fetch_pause,
                         u_dut.fu_fetch_req_valid, u_dut.fu_fetch_req_pa, u_dut.m_busy);
            end
        end
    end

    always @(posedge clk or negedge aresetn) begin
        if (!aresetn) begin
            arready_r        <= 1'b1;
            rd_active        <= 1'b0;
            rd_pend          <= 1'b0;
            rd_addr_q        <= 32'h0;
            rd_len_q         <= 4'h0;
            rd_id_q          <= 4'h0;
            rd_cnt_q         <= 5'h0;

            awready_r        <= 1'b1;
            wr_pend          <= 1'b0;
            bvalid_r         <= 1'b0;
            aw_addr_q        <= 32'h0;
            aw_len_q         <= 4'h0;
            aw_id_q          <= 4'h0;
            w_cnt_q          <= 5'h0;

            htif_cmd_valid   <= 1'b0;
            htif_cmd         <= 32'h0;
            tohost_lo        <= 32'h0;

            ar_count         <= 32'd0;
            aw_count         <= 32'd0;
            r_beat_count     <= 32'd0;
            w_beat_count     <= 32'd0;
            unknown_rd_count <= 32'd0;
            unknown_wr_count <= 32'd0;
            bus_cycles       <= 32'd0;
            first_ar_seen    <= 1'b0;
            first_ar_addr    <= 32'h0;
            uart_chars       = 0;
        end else begin
            htif_cmd_valid <= 1'b0;
            bus_cycles     <= bus_cycles + 32'd1;

            // ---- 读通道 ----
            if (ar_fire) begin
                ar_count  <= ar_count + 32'd1;
                rd_addr_q <= araddr;
                rd_len_q  <= arlen;
                rd_id_q   <= arid;
                rd_cnt_q  <= 5'd0;
                arready_r <= 1'b0;                  // 单笔在途
                rd_pend   <= 1'b1;                  // 1 拍读延迟
                if (!first_ar_seen) begin
                    first_ar_seen <= 1'b1;
                    first_ar_addr <= araddr;
                    $display("[tb_arch_test] 首笔 AR: addr=0x%08h len=%0d size=%0d burst=%b cache=%b id=%0d",
                             araddr, arlen, arsize, arburst, arcache, arid);
                end
                if (!is_ram(araddr) && !is_boot(araddr))
                    unknown_rd_count <= unknown_rd_count + 32'd1;
            end else if (rd_pend) begin
                rd_pend   <= 1'b0;
                rd_active <= 1'b1;
            end else if (r_fire) begin
                r_beat_count <= r_beat_count + 32'd1;
                if (rd_cnt_q[3:0] == rd_len_q) begin
                    rd_active <= 1'b0;
                    arready_r <= 1'b1;              // 释放：可接下一笔
                end else begin
                    rd_cnt_q  <= rd_cnt_q + 5'd1;
                    rd_addr_q <= rd_addr_q + 32'd4; // INCR
                end
            end

            // ---- 写通道 ----
            if (aw_fire) begin
                aw_count  <= aw_count + 32'd1;
                aw_addr_q <= awaddr;
                aw_len_q  <= awlen;
                aw_id_q   <= awid;
                w_cnt_q   <= 5'd0;
                wr_pend   <= 1'b1;
                awready_r <= 1'b0;                  // 单笔在途
            end

            if (w_fire) begin
                w_beat_count <= w_beat_count + 32'd1;
                do_write(aw_addr_q + {w_cnt_q, 2'b00}, wdata, wstrb);
                if (wlast) begin
                    wr_pend   <= 1'b0;
                    bvalid_r  <= 1'b1;
                    awready_r <= 1'b1;              // 释放：可接下一笔
                end else begin
                    w_cnt_q <= w_cnt_q + 5'd1;
                end
            end

            if (b_fire) bvalid_r <= 1'b0;
        end
    end

    //==========================================================================
    // 7. PROG_HEX 载入（多 @ 记录；@ 字段兼容"字索引"与"字节地址"两种写法）
    //    本机 objcopy -O verilog --verilog-data-width=4 输出的是**字索引**
    //    （实测：@07000000 ⇒ 0x1C00_0000；@20000000 ⇒ 0x8000_0000）。
    //    判定：@ 值本身命中窗口 ⇒ 字节地址；(@ 值 << 2) 命中窗口 ⇒ 字索引；
    //          两者都不命中 ⇒ load_err（fail-closed，不静默丢弃）。
    //==========================================================================
    integer load_err;      // 0=OK；2=打不开；3=@ 未命中窗口；4=数据越界/超宽
    integer load_words;
    integer load_nonzero;
    integer load_records;

    // 把解析出的字节地址映射成"存储体 + 字下标"；返回 0=OK、非 0=错误码
    //   bank_kind: 0 = RAM，1 = boot 窗口
    task automatic map_addr;
        input  [31:0] baddr;
        output integer bank_kind;
        output integer windex;
        begin
            if (is_ram(baddr)) begin
                bank_kind = 0;
                windex    = (baddr - RAM_BASE) >> 2;
            end else if (is_boot(baddr)) begin
                bank_kind = 1;
                windex    = (baddr - BOOT_BASE) >> 2;
            end else begin
                bank_kind = -1;
                windex    = -1;
            end
        end
    endtask

    task automatic load_hex;
        input [8*512-1:0] path;
        integer   fd;
        integer   c;
        integer   nd;
        reg [31:0] acc;
        reg [31:0] baddr;
        integer   bank_ok, wk, wd;
        begin
            load_err = 0; load_words = 0; load_nonzero = 0; load_records = 0;
            fd = $fopen(path, "r");
            if (fd == 0) begin
                load_err = 2;
                $display("[tb_arch_test] FAIL: 打不开 PROG_HEX = %0s", path);
            end else begin
                wk = -1;                    // 当前存储体（-1 = 未开始）
                wd = 0;                     // 当前字下标
                c  = $fgetc(fd);
                while (c != -1) begin
                    if (c == "@") begin
                        // ---- 解析 @ 基址（十六进制；按无符号累积）----
                        c = $fgetc(fd); acc = 32'h0; nd = 0;
                        while (hex_digit(c) >= 0) begin
                            acc = (acc << 4) | hex_digit(c);
                            nd  = nd + 1;
                            c   = $fgetc(fd);
                        end
                        load_records = load_records + 1;

                        bank_ok = -1; wd = -1;
                        if (is_ram(acc) || is_boot(acc)) begin
                            // 写法①：@ = 字节地址
                            baddr = acc;
                            map_addr(baddr, bank_ok, wd);
                        end
                        if (bank_ok < 0 && (is_ram(acc << 2) || is_boot(acc << 2))) begin
                            // 写法②：@ = 数据字索引（本机 objcopy 的写法）
                            baddr = acc << 2;
                            map_addr(baddr, bank_ok, wd);
                        end
                        if (bank_ok < 0) begin
                            if (load_err == 0) load_err = 3;
                            $display("[tb_arch_test] FAIL: @ 记录未命中任何窗口（字段=0x%08h）", acc);
                        end else begin
                            $display("[tb_arch_test] 载入记录 #%0d: @0x%08h（%0s）",
                                     load_records, baddr, (bank_ok == 0) ? "RAM" : "BOOT");
                        end
                        wk = bank_ok;
                    end else if (hex_digit(c) >= 0) begin
                        // ---- 解析一个数据字 ----
                        acc = 32'h0; nd = 0;
                        while (hex_digit(c) >= 0) begin
                            acc = (acc << 4) | hex_digit(c);
                            nd  = nd + 1;
                            c   = $fgetc(fd);
                        end
                        if (nd > 8) begin
                            if (load_err == 0) load_err = 4;
                            $display("[tb_arch_test] FAIL: 数据字宽 %0d 位十六进制（应为 8）", nd);
                        end
                        if (wk == 0) begin
                            if (wd < RAM_WORDS) begin
                                ram[wd] = acc;
                                load_words = load_words + 1;
                                if (acc != 32'h0) load_nonzero = load_nonzero + 1;
                                wd = wd + 1;
                            end else begin
                                if (load_err == 0) load_err = 4;
                                $display("[tb_arch_test] FAIL: RAM 越界（widx=%0d 上限 %0d）", wd, RAM_WORDS);
                            end
                        end else if (wk == 1) begin
                            if (wd < BOOT_WORDS) begin
                                boot[wd] = acc;
                                load_words = load_words + 1;
                                if (acc != 32'h0) load_nonzero = load_nonzero + 1;
                                wd = wd + 1;
                            end else begin
                                if (load_err == 0) load_err = 4;
                                $display("[tb_arch_test] FAIL: 复位窗口越界（widx=%0d 上限 %0d）", wd, BOOT_WORDS);
                            end
                        end else begin
                            if (load_err == 0) load_err = 3;
                            $display("[tb_arch_test] FAIL: 数据字出现在任何 @ 记录之前");
                        end
                    end else begin
                        c = $fgetc(fd);     // 空白/换行：跳过
                    end
                end
                $fclose(fd);
            end
        end
    endtask

    //==========================================================================
    // 8. 签名导出（`<addr> <data>` 每行一字，小端字值）
    //==========================================================================
    integer sig_fd;
    integer sig_lines;
    reg     dump_sig_err;

    task automatic dump_signature;
        input [8*512-1:0] path;
        integer k;
        reg [31:0] w;
        begin
            sig_lines = 0;
            sig_fd = $fopen(path, "w");
            if (sig_fd == 0) begin
                $display("[tb_arch_test] FAIL: 打不开签名输出文件 = %0s", path);
                dump_sig_err = 1'b1;
            end else begin
                for (k = 0; k < SIG_WORDS; k = k + 1) begin
                    w = ram[(SIG_BASE - RAM_BASE)/4 + k];
                    $fdisplay(sig_fd, "%08h %08h", SIG_BASE + 4*k, w);
                    sig_lines = sig_lines + 1;
                end
                $fclose(sig_fd);
            end
        end
    endtask

    //==========================================================================
    // 9. 主流程
    //==========================================================================
    integer cyc;
    reg     pass;
    reg     halt_seen;
    reg     halt_pass;

    initial begin
        pass         = 1'b0;
        halt_seen    = 1'b0;
        halt_pass    = 1'b0;
        dump_sig_err = 1'b0;
        uart_chars   = 0;
        aresetn      = 1'b0;

        // 存储体上电清零（放在载入之前，避免"零化 initial 与载入 initial 竞争"）
        for (i = 0; i < RAM_WORDS;  i = i + 1) ram[i]  = 32'h0000_0000;
        for (i = 0; i < BOOT_WORDS; i = i + 1) boot[i] = 32'h0000_0000;

        $display("========================================================================");
        $display("TB_ARCH_TEST: 开始（arch-test DUT 仿真；签名区 [0x%08h, 0x%08h) 共 %0d 字）",
                 SIG_BASE, SIG_BASE + 4*SIG_WORDS, SIG_WORDS);
        $display("  PROG_HEX = %0s", str_lj(PROG_HEX));
        $display("  SIG_FILE = %0s", str_lj(SIG_FILE));
        $display("  RAM      = [0x%08h, 0x%08h)  TOHOST=0x%08h  ENTRY=0x%08h",
                 RAM_BASE, RAM_BASE + 4*RAM_WORDS, TOHOST_ADDR, ENTRY_PC);

        // ---- 9.1 载入镜像 ----
        load_hex(PROG_HEX);
        $display("[tb_arch_test] 载入: err=%0d 记录=%0d 字=%0d 非零=%0d",
                 load_err, load_records, load_words, load_nonzero);
        $display("[tb_arch_test] 复位桩 boot[0..1] = %08h %08h；入口 ram[0..1] = %08h %08h",
                 boot[0], boot[1], ram[0], ram[1]);

        // ---- 9.2 复位保持，负沿释放 ----
        repeat (RESET_CYCLES) @(posedge clk);
        @(negedge clk);
        aresetn = 1'b1;
        $display("[tb_arch_test] aresetn 已释放（保持 %0d 拍）", RESET_CYCLES);

        // ---- 9.3 等 HTIF 终止码（PASS=1 / FAIL=3），带超时与无活动诊断 ----
        cyc = 0;
        while (!htif_cmd_valid && (cyc < TIMEOUT_CYCLES)) begin
            @(posedge clk);
            cyc = cyc + 1;
            if ((cyc == DIAG_NO_REQ_CYCLES) && !first_ar_seen)
                $display("[tb_arch_test] DIAG: %0d 拍内无任何 AXI 读请求（取指通路可能未启动）", cyc);
        end

        if (htif_cmd_valid) begin
            halt_seen = 1'b1;
            if (htif_cmd == 32'h0) begin                 // device=0/cmd=0 ⇒ 退出
                if (tohost_lo == 32'h1) begin
                    halt_pass = 1'b1;
                    $display("\n[tb_arch_test] HTIF 终止：tohost=1 ⇒ PASS（程序自报成功）");
                end else if (tohost_lo == 32'h3) begin
                    halt_pass = 1'b0;
                    $display("\n[tb_arch_test] HTIF 终止：tohost=3 ⇒ FAIL（程序自报失败）");
                end else begin
                    halt_pass = 1'b0;
                    $display("\n[tb_arch_test] HTIF 终止：未知退出码 tohost=%0d ⇒ 判失败", tohost_lo);
                end
            end else begin
                halt_pass = 1'b0;
                $display("\n[tb_arch_test] HTIF 命令未知：hi=0x%08h lo=0x%08h ⇒ 判失败",
                         htif_cmd, tohost_lo);
            end
        end else begin
            $display("\n[tb_arch_test] 超时：%0d 拍内未观察到 HTIF 终止码", TIMEOUT_CYCLES);
        end

        // ---- 9.4 导出签名（PASS/FAIL 都导出：失败时要能看分歧）----
        dump_signature(SIG_FILE);

        // ---- 9.5 汇总证据 ----
        $display("------------------------------------------------------------------------");
        $display("[tb_arch_test] 拍数=%0d 提交数=%0d 首笔AR=0x%08h(seen=%b) ar=%0d aw=%0d r_beat=%0d w_beat=%0d",
                 cyc, commit_count, first_ar_addr, first_ar_seen,
                 ar_count, aw_count, r_beat_count, w_beat_count);
        $display("[tb_arch_test] 未登记区域访问: 读=%0d 写=%0d；控制台字符=%0d",
                 unknown_rd_count, unknown_wr_count, uart_chars);
        if ((uart_chars > 0) && ((uart_chars % 64) != 0)) $write("\n");
        $display("[tb_arch_test] 签名导出行数=%0d ⇒ %0s", sig_lines, str_lj(SIG_FILE));
        $display("------------------------------------------------------------------------");

        // ---- 9.6 判定（fail-closed：逐项列举，任一不满足 ⇒ FAIL）----
        pass = 1'b1;
        if (load_err != 0) begin
            pass = 1'b0;
            $display("TB_ARCH_TEST: FAIL 镜像载入错误（load_err=%0d）", load_err);
        end
        if ((load_words == 0) || (load_nonzero < 8)) begin
            pass = 1'b0;
            $display("TB_ARCH_TEST: FAIL 镜像未载入（words=%0d nonzero=%0d）", load_words, load_nonzero);
        end
        if (boot[0] !== BOOT_STUB_W0) begin
            pass = 1'b0;
            $display("TB_ARCH_TEST: FAIL 复位向量窗口首字 = 0x%08h，期望复位桩 0x%08h",
                     boot[0], BOOT_STUB_W0);
        end
        if (ram[(ENTRY_PC - RAM_BASE)/4] === 32'h0) begin
            pass = 1'b0;
            $display("TB_ARCH_TEST: FAIL 入口 0x%08h 处指令字为 0（镜像入口缺失）", ENTRY_PC);
        end
        if ((SIG_BASE - RAM_BASE) + 4*SIG_WORDS > 4*RAM_WORDS) begin
            pass = 1'b0;
            $display("TB_ARCH_TEST: FAIL 签名区 [0x%08h,+%0d 字) 超出 RAM", SIG_BASE, SIG_WORDS);
        end
        if (!halt_seen) begin
            pass = 1'b0;
            $display("TB_ARCH_TEST: FAIL 未在 %0d 拍内到达 HTIF 终止点（超时）", TIMEOUT_CYCLES);
        end else if (!halt_pass) begin
            pass = 1'b0;
            $display("TB_ARCH_TEST: FAIL 程序以失败码终止（tohost=%0d）", tohost_lo);
        end
        if ((dump_sig_err != 1'b0) || (sig_lines != SIG_WORDS)) begin
            pass = 1'b0;
            $display("TB_ARCH_TEST: FAIL 签名导出不完整（err=%0d lines=%0d 期望 %0d）",
                     dump_sig_err, sig_lines, SIG_WORDS);
        end

        if (pass) begin
            $display("========================================================================");
            $display("TB_ARCH_TEST: PASS");                 // ★ 唯一 PASS 行
            $display("========================================================================");
            $finish;
        end else begin
            $display("========================================================================");
            $display("TB_ARCH_TEST: FAIL —— 判据未全部达成（详见上面各 FAIL 行；本 TB 无兜底 PASS）");
            $display("========================================================================");
            $fatal(1, "TB_ARCH_TEST FAIL");
        end
    end

endmodule
