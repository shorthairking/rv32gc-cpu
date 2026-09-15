//==============================================================================
// sim/lockstep/tb_lockstep.sv —— Spike 锁步 DUT 侧激励/观测平台（08 §8.3）
//==============================================================================
// 项目  : rv32gc-cpu（阶段二 2A）
// 归属  : docs/design/08-baseline-5stage.md §8.3（Spike 锁步）、§3.2（目录约定）
//         07-verification.md §4.3（仿真布局与内存映射差异处理，方案 2）
// 顶层名: tb_lockstep（run.sh 用 `-s tb_lockstep` 指定）
//------------------------------------------------------------------------------
// 一、为什么需要本 TB（而不是直接用 sim/tb/tb_core_top.sv）
//------------------------------------------------------------------------------
//   ① **地址布局硬冲突**：本核复位取指地址由 rtl/pkg/core_params.vh 的
//      `RV32GC_RESET_PC 固定为 0x1C00_0000（core_top.v:2764 的编译期自检禁止改动），
//      而 08 §8.3 的锁步布局是 Spike 习惯的 **0x8000_0000**（`-m0x80000000:...`）。
//      生产 RTL 禁止提供 0x8000_0000 别名（07-verification.md §4.3）⇒ DUT 侧靠
//      "复位向量处的 2 条跳转桩"进入 0x8000_0000（见 prog/lock_hello.S）。两条轨迹
//      都从 0x1C00_0000 的第 0 条指令开始，1:1 对齐，PC 逐条严格相等。
//   ② **内存窗口**：sim/tb/sim_mem_model.sv 的 XIP 窗口判定写死为宏（0x1C0/0x1FE8，
//      不可参数化），DDR3 窗口虽可参数化但 **ddr3_read() 以 `ddr3_mem[a[31:2]]` 作
//      绝对下标**（隐含 DDR3_BASE==0）⇒ 把 DDR3 参数改到 0x8000_0000 会读到数组越界
//      （返 x ⇒ 被"未写入按 0"逻辑折叠成 0，取回全 0 指令 ⇒ 非法指令陷阱）。
//      [本会话实测：AR 已到 0x80000000，但核内 fetch_pc 随即变 0x0]
//      ⇒ 本 TB **原样例化 sim_mem_model（默认窗口/默认 DDR3 基址 0x0）**，在 DUT 与
//        模型之间插一层**纯组合地址翻译** lockstep_addr_map：把 DUT 侧
//        0x8000_0000..0x800F_FFFF 映射到模型 DDR3 窗口内的 0x0010_0000..0x001F_FFFF，
//        其余地址原样透传（XIP 0x1C00_0000 跳转桩、UART 0x1FE0_01E0 结束铃都在原窗口）。
//        这正是 07-verification.md §4.3「方案 2：为仿真单独准备映射到 0x8000_0000 的
//        内存模型」的落地形式，且**不改 sim/tb/**（复用只读）。
//   ③ **结束条件不同**：tb_core_top 的判据是"M1 首条取指 + UART 回显 RV32GC-M1-OK"，
//      与锁步无关；本 TB 的判据是"提交 trace 逐条落盘 + 以 lockstep_spin 的提交为终止
//      + UART 结束铃证据"，trace 落文件供 cmp_commit.py 与 Spike 逐条比对。
//   ⇒ 结论：core_top 的 48 端口契约、sim_mem_model（协议/存储/UART 捕获）、debug0 提交
//      探针契约、PROG_HEX（objcopy -O verilog）载入口径**全部复用**；只新增"地址翻译 +
//      提交 trace 落盘 + 终止判定"这一层锁步适配。
//
//------------------------------------------------------------------------------
// 二、结构
//------------------------------------------------------------------------------
//   tb_lockstep
//     ├── u_dut : rtl/top/core_top.v（48 端口逐字例化，rtl 只读，同 tb_core_top）
//     ├── u_map : lockstep_addr_map（纯组合；0x8000_xxxx → 模型 DDR3 0x0010_xxxx）
//     ├── u_mem : sim/tb/sim_mem_model.sv（AXI4 从设备，**默认参数原样例化**）
//     ├── 载入   : load_prog() —— 解析 objcopy -O verilog 的 hex（两个 @ 段）：
//     │             @ = 0x1C00_0000 ⇒ u_mem.xip_mem[]（复位跳转桩 2 条）
//     │             @ = 0x8000_0000 ⇒ u_mem.ddr3_mem[翻译基址 + 窗口内下标]（程序主体）
//     │           （层次引用写入 = 仿真预载手段；iverilog 12.0 实测可用）
//     └── trace : 每次提交（ws_valid）落一行到 DUT_TRACE（格式见 §三）；
//                 提交 PC == TERM_PC（= prog 里 lockstep_spin 的地址）⇒ 停止记录
//
//------------------------------------------------------------------------------
// 三、DUT trace 格式（cmp_commit.py 的输入契约；一行 = 一条提交）
//------------------------------------------------------------------------------
//   `#` 开头为注释行（含末行 `# end ...` 结束证据）；数据行：
//     <idx> pc=0x%08x wen=%0d rd=%0d wdata=0x%08x
//     · idx   : 0 起的提交序号
//     · pc    : debug0_wb_pc（提交指令 PC）
//     · wen   : debug0_wb_rf_wen[0]（1 = 该指令写架构寄存器；2A 只驱动 bit0）
//     · rd    : wen=1 时为 debug0_wb_rf_wnum（0..31），wen=0 时记 -1
//     · wdata : debug0_wb_rf_wdata（wen=0 时无意义，仍记录便于定位）
//   ★ 口径限制（写清以免误判覆盖率）：2A 的提交探针**不含**访存地址/数据、不含 CSR
//     变更、且 FP 写回也用 rf_wen[0] + 浮点寄存器号上报（core_top.v:2755）⇒ 本任务
//     只比对 **PC 与整数 rd 写值**（任务口径），锁步程序里不出现 F/D 指令（见 .S 头注）。
//
//------------------------------------------------------------------------------
// 四、判据（fail-closed：任一不满足 ⇒ TB_LOCKSTEP: FAIL + $fatal，rc≠0）
//------------------------------------------------------------------------------
//   C1 PROG_HEX 两个窗口都载入成功（xip_words=2、ddr_words>0、load_err=0）
//   C2 首笔 AXI 读地址 == `RV32GC_RESET_PC（0x1C00_0000，与 M1 同一观测量）
//   C3 首条提交 PC == `RV32GC_RESET_PC（复位后第一条就是跳转桩）
//   C4 在 TIMEOUT_CYCLES 内提交到 TERM_PC（= lockstep_spin）而停止（非超时）
//   C5 提交条数 >= MIN_COMMITS（默认 60）
//   C6 UART 结束铃：u_mem.uart_write_count >= 1（程序确实跑到 0x1FE0_01E0 的写）
//   ★ 本 TB **不打印任何含 PASS 字样的兜底文案**；成功只打印唯一证据行
//     "TB_LOCKSTEP: DUT_TRACE_OK ..."（"LOCKSTEP: N/N PASS" 由 cmp_commit.py 输出）。
//
//------------------------------------------------------------------------------
// 五、复位/时钟口径
//------------------------------------------------------------------------------
//   · 时钟 10 ns 周期（仿真口径，与 tb_core_top 一致）；
//   · aresetn 低有效：保持 RESET_CYCLES 拍，在**负沿**释放；
//   · 预载在 #1（t=0 之后）进行：保证 sim_mem_model 的 XIP 上电清零 initial 块
//     已完成，避免"先写后被清"的竞态。
//------------------------------------------------------------------------------
// 六、风格/红线
//------------------------------------------------------------------------------
//   · TESTBENCH（不可综合）；无 FPGA 原语；无 Vivado IP；无旧项目标识；
//   · rtl/** 与 sim/tb/** 只读复用，本文件不修改它们；
//   · `always` 块只用于时钟与 AR 诊断观测（TB 必需）。
//==============================================================================
`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"

module tb_lockstep #(
    // ---- 输入/输出文件 ----
    parameter [8*512-1:0] PROG_HEX       = "sim/lockstep/build/lock_hello.hex",
    parameter [8*512-1:0] DUT_TRACE      = "sim/lockstep/build/dut.trace",
    // ---- 终止/判据参数（由 run.sh 用 -P 覆盖为 ELF 实测符号值）----
    parameter [31:0]      TERM_PC        = 32'h8000_0120,  // lockstep_spin
    parameter integer     MIN_COMMITS    = 60,
    parameter integer     TIMEOUT_CYCLES = 2000000,
    parameter integer     RESET_CYCLES   = 20,
    parameter integer     CLK_HALF_NS    = 5,
    parameter integer     DRAIN_CYCLES   = 400,            // 终止后再观察（等 AXI 写落地）
    // ---- 仿真布局 → 模型 DDR3 窗口的地址翻译（见头注 §一②）----
    parameter [31:0]      MAP_FROM       = 32'h8000_0000,  // DUT 侧窗口基址
    parameter [31:0]      MAP_TO         = 32'h0010_0000,  // 模型 DDR3 窗口内的落点
    parameter [31:0]      MAP_MASK       = 32'hFFF0_0000,  // 1 MiB 窗口判定掩码
    // ---- 程序结束标记地址（与 prog/lock_hello.S 一致；仅作诊断记录，不作判据）----
    parameter [31:0]      MAGIC_ADDR     = 32'h8000_2000,  // 魔数落点
    parameter [31:0]      MAGIC_VAL      = 32'h600D_5EED,  // 魔数
    parameter [31:0]      DOORBELL_ADDR  = `RV32GC_UART_BASE // 0x1FE0_01E0 结束铃
) ();

    //==========================================================================
    // 0. 常量
    //==========================================================================
    localparam integer XIP_WORDS   = `RV32GC_XIP_SIZE / 4;   // 262144
    localparam integer DDR_WIN_WORDS = (~MAP_MASK + 1) / 4;  // 1 MiB 窗口 = 262144 字
    localparam [31:0]  XIP_BASE    = `RV32GC_XIP_BASE;       // 0x1C00_0000
    localparam [31:0]  XIP_WIDX    = XIP_BASE >> 2;          // 0x0700_0000
    localparam [31:0]  MAP_WIDX    = MAP_TO  >> 2;           // 0x0004_0000

    //==========================================================================
    // 1. 时钟 / 复位
    //==========================================================================
    reg clk;
    reg aresetn;

    initial clk = 1'b0;
    always #(CLK_HALF_NS) clk = ~clk;

    //==========================================================================
    // 2. DUT 侧 AXI4 连线（观测量也取在这一侧：地址即 DUT 真实地址）
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

    // 调试组（提交探针）
    wire        ws_valid;
    wire [31:0] rf_rdata;
    wire [31:0] debug0_wb_pc;
    wire [3:0]  debug0_wb_rf_wen;
    wire [4:0]  debug0_wb_rf_wnum;
    wire [31:0] debug0_wb_rf_wdata;

    //==========================================================================
    // 3. DUT：rtl/top/core_top.v（48 端口逐字契约，只读复用）
    //==========================================================================
    core_top u_dut (
        .aclk              (clk),
        .intrpt            (8'h00),            // 锁步定向程序不使用中断
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
    // 4. 地址翻译（纯组合）→ sim_mem_model（默认参数原样复用）
    //==========================================================================
    wire [3:0]  m_arid;
    wire [31:0] m_araddr;
    wire [3:0]  m_arlen;
    wire [2:0]  m_arsize;
    wire [1:0]  m_arburst;
    wire [1:0]  m_arlock;
    wire [3:0]  m_arcache;
    wire [2:0]  m_arprot;
    wire        m_arvalid;
    wire        m_arready;

    wire [3:0]  m_rid;
    wire [31:0] m_rdata;
    wire [1:0]  m_rresp;
    wire        m_rlast;
    wire        m_rvalid;
    wire        m_rready;

    wire [3:0]  m_awid;
    wire [31:0] m_awaddr;
    wire [3:0]  m_awlen;
    wire [2:0]  m_awsize;
    wire [1:0]  m_awburst;
    wire [1:0]  m_awlock;
    wire [3:0]  m_awcache;
    wire [2:0]  m_awprot;
    wire        m_awvalid;
    wire        m_awready;

    wire [3:0]  m_wid;
    wire [31:0] m_wdata;
    wire [3:0]  m_wstrb;
    wire        m_wlast;
    wire        m_wvalid;
    wire        m_wready;

    wire [3:0]  m_bid;
    wire [1:0]  m_bresp;
    wire        m_bvalid;
    wire        m_bready;

    lockstep_addr_map #(
        .MAP_FROM (MAP_FROM),
        .MAP_TO   (MAP_TO),
        .MAP_MASK (MAP_MASK)
    ) u_map (
        .s_arid(arid), .s_araddr(araddr), .s_arlen(arlen), .s_arsize(arsize),
        .s_arburst(arburst), .s_arlock(arlock), .s_arcache(arcache), .s_arprot(arprot),
        .s_arvalid(arvalid), .s_arready(arready),
        .s_rid(rid), .s_rdata(rdata), .s_rresp(rresp), .s_rlast(rlast),
        .s_rvalid(rvalid), .s_rready(rready),
        .s_awid(awid), .s_awaddr(awaddr), .s_awlen(awlen), .s_awsize(awsize),
        .s_awburst(awburst), .s_awlock(awlock), .s_awcache(awcache), .s_awprot(awprot),
        .s_awvalid(awvalid), .s_awready(awready),
        .s_wid(wid), .s_wdata(wdata), .s_wstrb(wstrb), .s_wlast(wlast),
        .s_wvalid(wvalid), .s_wready(wready),
        .s_bid(bid), .s_bresp(bresp), .s_bvalid(bvalid), .s_bready(bready),

        .m_arid(m_arid), .m_araddr(m_araddr), .m_arlen(m_arlen), .m_arsize(m_arsize),
        .m_arburst(m_arburst), .m_arlock(m_arlock), .m_arcache(m_arcache), .m_arprot(m_arprot),
        .m_arvalid(m_arvalid), .m_arready(m_arready),
        .m_rid(m_rid), .m_rdata(m_rdata), .m_rresp(m_rresp), .m_rlast(m_rlast),
        .m_rvalid(m_rvalid), .m_rready(m_rready),
        .m_awid(m_awid), .m_awaddr(m_awaddr), .m_awlen(m_awlen), .m_awsize(m_awsize),
        .m_awburst(m_awburst), .m_awlock(m_awlock), .m_awcache(m_awcache), .m_awprot(m_awprot),
        .m_awvalid(m_awvalid), .m_awready(m_awready),
        .m_wid(m_wid), .m_wdata(m_wdata), .m_wstrb(m_wstrb), .m_wlast(m_wlast),
        .m_wvalid(m_wvalid), .m_wready(m_wready),
        .m_bid(m_bid), .m_bresp(m_bresp), .m_bvalid(m_bvalid), .m_bready(m_bready)
    );

    wire [7:0]  uart_char;
    wire        uart_char_valid;
    wire [31:0] uart_tx_count;
    wire        uart_overflow;
    wire [31:0] uart_bad_strb_count;

    sim_mem_model #(
        .READ_LAT_DLY (0)                      // 其余参数一律取默认（DDR3 基址 0x0）
    ) u_mem (
        .clk              (clk),
        .rst_n            (aresetn),

        .arid             (m_arid),
        .araddr           (m_araddr),
        .arlen            (m_arlen),
        .arsize           (m_arsize),
        .arburst          (m_arburst),
        .arlock           (m_arlock),
        .arcache          (m_arcache),
        .arprot           (m_arprot),
        .arvalid          (m_arvalid),
        .arready          (m_arready),

        .rid              (m_rid),
        .rdata            (m_rdata),
        .rresp            (m_rresp),
        .rlast            (m_rlast),
        .rvalid           (m_rvalid),
        .rready           (m_rready),

        .awid             (m_awid),
        .awaddr           (m_awaddr),
        .awlen            (m_awlen),
        .awsize           (m_awsize),
        .awburst          (m_awburst),
        .awlock           (m_awlock),
        .awcache          (m_awcache),
        .awprot           (m_awprot),
        .awvalid          (m_awvalid),
        .awready          (m_awready),

        .wid              (m_wid),
        .wdata            (m_wdata),
        .wstrb            (m_wstrb),
        .wlast            (m_wlast),
        .wvalid           (m_wvalid),
        .wready           (m_wready),

        .bid              (m_bid),
        .bresp            (m_bresp),
        .bvalid           (m_bvalid),
        .bready           (m_bready),

        .uart_char        (uart_char),
        .uart_char_valid  (uart_char_valid),
        .uart_tx_count    (uart_tx_count),
        .uart_overflow    (uart_overflow),
        .uart_bad_strb_count(uart_bad_strb_count)
    );

    //==========================================================================
    // 5. 工具函数
    //==========================================================================
    // 左对齐字符串（便于 `%0s` 打印路径；口径同 tb_core_top）
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
    // 6. 程序预载：解析 objcopy -O verilog 的 hex，按 @ 基址分派到两个窗口
    //    @ = 0x1C00_0000（XIP 主窗口）⇒ u_mem.xip_mem[窗口内下标]（跳转桩）
    //    @ = 0x8000_0000（仿真布局）  ⇒ u_mem.ddr3_mem[翻译基址 + 窗口内下标]（主体）
    //==========================================================================
    integer load_err;          // 0=OK；2=打不开；3=@ 基址不在已知窗口；4=越界
    integer xip_words_loaded;
    integer ddr_words_loaded;
    integer load_nonzero;

    task automatic load_prog;
        input [8*512-1:0] path;
        integer fd;
        integer c;
        integer v;
        integer widx;          // 归一化后的"窗口内字下标"
        integer seg;           // 0=未定 1=XIP 2=仿真布局
        integer xw;
        begin
            load_err          = 0;
            xip_words_loaded  = 0;
            ddr_words_loaded  = 0;
            load_nonzero      = 0;
            seg               = 0;
            widx              = 0;

            fd = $fopen(path, "r");
            if (fd == 0) begin
                load_err = 2;
                $display("TB_LOCKSTEP: FAIL 打不开 PROG_HEX = %0s", str_lj(path));
            end else begin
                c = $fgetc(fd);
                while (c != -1) begin
                    if (c == "@") begin
                        //---- 解析 @ 基址（16 进制）----
                        c = $fgetc(fd);
                        v = 0;
                        while (hex_digit(c) >= 0) begin
                            v = (v << 4) | hex_digit(c);
                            c = $fgetc(fd);
                        end
                        //---- 归一化：接受"数据字索引"（v<<2 == 基址）与"字节地址"两种写法 ----
                        if (((v << 2) == XIP_BASE) || (v == XIP_BASE)) begin
                            seg  = 1;
                            widx = ((v << 2) == XIP_BASE) ? (v - XIP_WIDX)
                                                          : ((v >> 2) - XIP_WIDX);
                        end else if (((v << 2) == MAP_FROM) || (v == MAP_FROM)) begin
                            seg  = 2;
                            widx = ((v << 2) == MAP_FROM) ? (v - (MAP_FROM >> 2))
                                                          : ((v >> 2) - (MAP_FROM >> 2));
                        end else begin
                            load_err = 3;
                            seg      = 0;
                            $display("TB_LOCKSTEP: FAIL PROG_HEX 的 @ 基址 0x%08h 既不是 XIP 0x%08h 也不是仿真布局 0x%08h",
                                     v, XIP_BASE, MAP_FROM);
                        end
                    end else if (hex_digit(c) >= 0) begin
                        //---- 解析一个数据字 ----
                        v = 0;
                        while (hex_digit(c) >= 0) begin
                            v = (v << 4) | hex_digit(c);
                            c = $fgetc(fd);
                        end
                        xw = widx;
                        if (seg == 1) begin
                            if ((xw >= 0) && (xw < XIP_WORDS)) begin
                                u_mem.xip_mem[xw] = v[31:0];
                                xip_words_loaded  = xip_words_loaded + 1;
                            end else begin
                                load_err = 4;
                                $display("TB_LOCKSTEP: FAIL hex 数据越出 XIP 窗口（字下标 %0d）", xw);
                            end
                        end else if (seg == 2) begin
                            if ((xw >= 0) && (xw < DDR_WIN_WORDS)) begin
                                // 写入模型的 DDR3 体，落点 = 翻译基址（MAP_TO）
                                u_mem.ddr3_mem[MAP_WIDX + xw] = v[31:0];
                                ddr_words_loaded  = ddr_words_loaded + 1;
                            end else begin
                                load_err = 4;
                                $display("TB_LOCKSTEP: FAIL hex 数据越出仿真布局窗口（字下标 %0d）", xw);
                            end
                        end else begin
                            load_err = 3;
                            $display("TB_LOCKSTEP: FAIL 出现未归属任何窗口的数据字");
                        end
                        if (v[31:0] != 32'h0) load_nonzero = load_nonzero + 1;
                        widx = widx + 1;
                    end else begin
                        c = $fgetc(fd);          // 跳过空白
                    end
                end
                $fclose(fd);
                $display("TB_LOCKSTEP: PROG_HEX 载入 path=%0s xip_words=%0d sim_words=%0d nonzero=%0d err=%0d",
                         str_lj(path), xip_words_loaded, ddr_words_loaded, load_nonzero, load_err);
            end
        end
    endtask

    //==========================================================================
    // 7. 主流程：预载 → 复位 → 放行 → 记录提交 trace 直到 TERM_PC → 汇总判定
    //==========================================================================
    // ---- 取指通路诊断：记录首若干笔 AR（地址/长度/cache 属性 + 核内 fetch_pc）----
    //   观测量取在 **DUT 侧**（araddr 即 DUT 真实地址）；层次引用 fetch_pc 仅作诊断
    //   （与 tb_core_top 同口径），判据一律用 AXI 观测量。
    integer ar_dbg_n;
    wire    ar_fire = arvalid & arready;

    // ---- 诊断：DUT 侧"魔数写 / 结束铃写"的 AXI 观测（**仅诊断，不作判据**）----
    //   理由：2A 的 PMA 判据下 0x8000_xxxx 属"非 DDR 默认通路 ⇒ AxCACHE=0 直写 AXI"
    //   （本会话实测：AW 0x0010_2000 + UART AW 均可见），故能观测；但若后续 RTL 把该
    //   区域改为写回缓存，本项会变 0 而 DUT 仍可能正确 ⇒ 不作为判据，只记录进 trace
    //   末行供人工/比对器佐证（魔数写的正确性由 Spike 侧 mem 字段锚定）。
    integer magic_aw_n;
    integer magic_w_n;
    wire    aw_fire = awvalid & awready;
    wire    w_fire  = wvalid & wready;

    always @(posedge clk) begin
        if (aresetn && aw_fire && (awaddr == MAGIC_ADDR)) magic_aw_n = magic_aw_n + 1;
        if (aresetn && w_fire  && (wdata  == MAGIC_VAL))  magic_w_n  = magic_w_n  + 1;
    end

    always @(posedge clk) begin
        if (aresetn && ar_fire && (ar_dbg_n < 12)) begin
            $display("TB_LOCKSTEP_DIAG: AR[%0d]=0x%08h len=%0d size=%0d cache=%b 核内 fetch_pc=0x%08h",
                     ar_dbg_n, araddr, arlen, arsize, arcache, u_dut.u_fetch_unit.fetch_pc);
            ar_dbg_n = ar_dbg_n + 1;
        end
    end

    integer trace_fd;
    // 路径参数先落到 reg 再交给 $fopen：iverilog 12.0 实测对"直接传 vpiParameter"
    // 会报 "$fopen's file name argument (vpiParameter) is not a valid string"
    // （参数向量右侧的 NUL 填充被视为非法字符串），经 reg/任务端口转换后正常。
    reg [8*512-1:0] trace_path_q;
    integer rd_dbg;            // trace 里的 rd 字段（-1 = 不写架构寄存器）
    integer commit_n;          // 已记录提交条数
    integer cyc;               // 复位释放后的拍数
    integer drain;
    reg     stopped;           // 已见到 TERM_PC（停止记录）
    reg     first_pc_chk_done;
    reg     first_pc_ok;
    reg [31:0] first_pc;
    reg     c1_ok, c2_ok, c3_ok, c4_ok, c5_ok, c6_ok;

    initial begin
        aresetn          = 1'b0;
        commit_n         = 0;
        cyc              = 0;
        stopped          = 1'b0;
        ar_dbg_n         = 0;
        magic_aw_n       = 0;
        magic_w_n        = 0;
        trace_fd         = 0;
        trace_path_q     = DUT_TRACE;
        first_pc_chk_done= 1'b0;
        first_pc_ok      = 1'b0;
        first_pc         = 32'h0;
        c1_ok = 1'b0; c2_ok = 1'b0; c3_ok = 1'b0; c4_ok = 1'b0; c5_ok = 1'b0; c6_ok = 1'b0;

        $display("========================================================================");
        $display("TB_LOCKSTEP: 开始（DUT 提交 trace → %0s；终止 PC = lockstep_spin = 0x%08h）",
                 str_lj(DUT_TRACE), TERM_PC);
        $display("  PROG_HEX = %0s", str_lj(PROG_HEX));
        $display("  仿真布局翻译 = 0x%08h..(掩码 0x%08h) → 模型 DDR3 0x%08h；XIP = 0x%08h",
                 MAP_FROM, MAP_MASK, MAP_TO, XIP_BASE);

        trace_fd = $fopen(trace_path_q, "w");
        if (trace_fd == 0) begin
            $display("TB_LOCKSTEP: FAIL 无法创建 DUT trace 文件 %0s", str_lj(DUT_TRACE));
            $fatal(1, "TB_LOCKSTEP FAIL trace file");
        end
        $fwrite(trace_fd, "# DUT commit trace — RV32GC 2A Spike lockstep (sim/lockstep/tb_lockstep.sv)\n");
        $fwrite(trace_fd, "# format: <idx> pc=0x%%08x wen=%%0d rd=%%0d wdata=0x%%08x\n");
        $fwrite(trace_fd, "# 一行 = 一次提交（ws_valid）；rd=-1 表示该指令不写架构寄存器\n");

        //----------------------------------------------------------------------
        // 7.1 预载（#1：等 sim_mem_model 的 XIP 上电清零 initial 块跑完）
        //----------------------------------------------------------------------
        #1;
        load_prog(PROG_HEX);

        //----------------------------------------------------------------------
        // 7.2 复位保持 RESET_CYCLES 拍，负沿释放
        //----------------------------------------------------------------------
        repeat (RESET_CYCLES) @(posedge clk);
        @(negedge clk);
        aresetn = 1'b1;
        $display("TB_LOCKSTEP: aresetn 已释放（保持 %0d 拍）", RESET_CYCLES);

        //----------------------------------------------------------------------
        // 7.3 逐拍记录提交，直到 TERM_PC（或超时）
        //----------------------------------------------------------------------
        while (!stopped && (cyc < TIMEOUT_CYCLES)) begin
            @(posedge clk);
            cyc = cyc + 1;
            if (ws_valid) begin
                if (!first_pc_chk_done) begin
                    first_pc_chk_done = 1'b1;
                    first_pc          = debug0_wb_pc;
                    first_pc_ok       = (debug0_wb_pc == `RV32GC_RESET_PC);
                end
                if (debug0_wb_pc == TERM_PC) begin
                    stopped = 1'b1;              // 终止点：不记录本条及以后
                end else begin
                    if (debug0_wb_rf_wen[0]) rd_dbg = debug0_wb_rf_wnum;
                    else                     rd_dbg = -1;   // 不写架构寄存器
                    $fwrite(trace_fd, "%0d pc=0x%08h wen=%0d rd=%0d wdata=0x%08h\n",
                            commit_n, debug0_wb_pc, debug0_wb_rf_wen[0],
                            rd_dbg, debug0_wb_rf_wdata);
                    commit_n = commit_n + 1;
                end
            end
        end

        //----------------------------------------------------------------------
        // 7.4 终止后再观察 DRAIN_CYCLES 拍：让 AXI 写（UART 结束铃）落地
        //----------------------------------------------------------------------
        for (drain = 0; drain < DRAIN_CYCLES; drain = drain + 1) @(posedge clk);
        cyc = cyc + DRAIN_CYCLES;

        //----------------------------------------------------------------------
        // 7.5 汇总证据
        //----------------------------------------------------------------------
        $display("------------------------------------------------------------------------");
        $display("TB_LOCKSTEP_DIAG: commits=%0d cycles=%0d stopped_at_term_pc=%b",
                 commit_n, cyc, stopped);
        $display("TB_LOCKSTEP_DIAG: AXI ar=%0d aw=%0d r_beat=%0d w_beat=%0d unknown_rd=%0d",
                 u_mem.ar_count, u_mem.aw_count, u_mem.r_beat_count,
                 u_mem.w_beat_count, u_mem.unknown_rd_count);
        $display("TB_LOCKSTEP_DIAG: 首笔 AR=0x%08h（模型侧，XIP 原窗口；seen=%b）；首条提交 PC=0x%08h",
                 u_mem.first_ar_addr, u_mem.first_ar_seen, first_pc);
        $display("TB_LOCKSTEP_DIAG: UART 写次数=%0d 捕获字节=%0d（结束铃）overflow=%b",
                 u_mem.uart_write_count, u_mem.uart_tx_count, u_mem.uart_overflow);
        $display("TB_LOCKSTEP_DIAG: 魔数写 AXI 观测（仅诊断）magic_aw=%0d magic_wdata=%0d（期望各 1）",
                 magic_aw_n, magic_w_n);

        // 结束证据写入 trace 末行（cmp_commit.py 必须读到）
        $fwrite(trace_fd, "# end commits=%0d cycles=%0d reason=%0s term_pc=0x%08h uart_writes=%0d magic_aw=%0d magic_wdata=%0d\n",
                commit_n, cyc, stopped ? "TERM_PC" : "TIMEOUT", TERM_PC, u_mem.uart_write_count,
                magic_aw_n, magic_w_n);
        $fclose(trace_fd);

        //----------------------------------------------------------------------
        // 7.6 判定（fail-closed：逐项列举，任一项不满足 ⇒ FAIL）
        //----------------------------------------------------------------------
        c1_ok = (load_err == 0) && (xip_words_loaded == 2) && (ddr_words_loaded > 0);
        c2_ok = u_mem.first_ar_seen && (u_mem.first_ar_addr == `RV32GC_RESET_PC);
        c3_ok = first_pc_chk_done && first_pc_ok;
        c4_ok = stopped;
        c5_ok = (commit_n >= MIN_COMMITS);
        c6_ok = (u_mem.uart_write_count >= 1) && !u_mem.uart_overflow;

        $display("------------------------------------------------------------------------");
        if (!c1_ok) $display("TB_LOCKSTEP: FAIL C1 PROG_HEX 载入不完整（xip=%0d sim=%0d err=%0d）",
                             xip_words_loaded, ddr_words_loaded, load_err);
        if (!c2_ok) $display("TB_LOCKSTEP: FAIL C2 首笔 AXI 读地址=0x%08h，期望 0x%08h（seen=%b）",
                             u_mem.first_ar_addr, `RV32GC_RESET_PC, u_mem.first_ar_seen);
        if (!c3_ok) $display("TB_LOCKSTEP: FAIL C3 首条提交 PC=0x%08h，期望 0x%08h（复位取指桩）",
                             first_pc, `RV32GC_RESET_PC);
        if (!c4_ok) $display("TB_LOCKSTEP: FAIL C4 %0d 拍内未提交到 TERM_PC=0x%08h（提交 %0d 条后超时）",
                             TIMEOUT_CYCLES, TERM_PC, commit_n);
        if (!c5_ok) $display("TB_LOCKSTEP: FAIL C5 提交条数 %0d < 下限 %0d",
                             commit_n, MIN_COMMITS);
        if (!c6_ok) $display("TB_LOCKSTEP: FAIL C6 未见 UART 结束铃（uart_write_count=%0d overflow=%b）",
                             u_mem.uart_write_count, u_mem.uart_overflow);

        if (c1_ok && c2_ok && c3_ok && c4_ok && c5_ok && c6_ok) begin
            $display("TB_LOCKSTEP: DUT_TRACE_OK commits=%0d cycles=%0d trace=%0s uart_writes=%0d",
                     commit_n, cyc, str_lj(DUT_TRACE), u_mem.uart_write_count);
            $display("========================================================================");
            $finish;
        end else begin
            $display("TB_LOCKSTEP: FAIL —— 判据未全部达成（详见上面各 Cx 行；本 TB 无兜底 PASS）");
            $display("========================================================================");
            $fatal(1, "TB_LOCKSTEP FAIL");
        end
    end

endmodule

//==============================================================================
// lockstep_addr_map —— 纯组合地址翻译层（锁步 TB 专用，见 tb_lockstep 头注 §一②）
//==============================================================================
// 作用：把 DUT 侧 0x8000_0000 起的仿真布局窗口，翻译到 sim_mem_model 默认 DDR3
//       窗口（0x0..0x07FF_FFFF）内的一段（默认 0x0010_0000），使模型**不必改参数**
//       就能承载 08 §8.3 要求的 0x8000_0000 布局；窗口外地址（XIP 0x1C00_0000、
//       UART 0x1FE0_01E0、DDR3 0x0..）一律原样透传。
// 纪律：无状态、无 always、无时钟（纯 assign）；不改变任何握手语义（valid/ready 直连），
//       仅改写 AR/AW 的地址字段；R/B/W 通道与 id/属性字段全部直连。
// 注意：本层是**仿真映射**，只存在于 TB；生产 RTL 不出现任何 0x8000_0000 别名逻辑
//       （07-verification.md §4.3 明令）。
//==============================================================================
module lockstep_addr_map #(
    parameter [31:0] MAP_FROM = 32'h8000_0000,
    parameter [31:0] MAP_TO   = 32'h0010_0000,
    parameter [31:0] MAP_MASK = 32'hFFF0_0000
) (
    // ---- 上游（DUT 侧）----
    input  wire [3:0]  s_arid,
    input  wire [31:0] s_araddr,
    input  wire [3:0]  s_arlen,
    input  wire [2:0]  s_arsize,
    input  wire [1:0]  s_arburst,
    input  wire [1:0]  s_arlock,
    input  wire [3:0]  s_arcache,
    input  wire [2:0]  s_arprot,
    input  wire        s_arvalid,
    output wire        s_arready,

    output wire [3:0]  s_rid,
    output wire [31:0] s_rdata,
    output wire [1:0]  s_rresp,
    output wire        s_rlast,
    output wire        s_rvalid,
    input  wire        s_rready,

    input  wire [3:0]  s_awid,
    input  wire [31:0] s_awaddr,
    input  wire [3:0]  s_awlen,
    input  wire [2:0]  s_awsize,
    input  wire [1:0]  s_awburst,
    input  wire [1:0]  s_awlock,
    input  wire [3:0]  s_awcache,
    input  wire [2:0]  s_awprot,
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

    // ---- 下游（sim_mem_model 侧）----
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
    output wire        m_bready
);

    function [31:0] map_addr;
        input [31:0] a;
        begin
            map_addr = ((a & MAP_MASK) == (MAP_FROM & MAP_MASK))
                       ? (a - MAP_FROM + MAP_TO)
                       : a;
        end
    endfunction

    // ---- AR ----
    assign m_araddr  = map_addr(s_araddr);
    assign m_arid    = s_arid;
    assign m_arlen   = s_arlen;
    assign m_arsize  = s_arsize;
    assign m_arburst = s_arburst;
    assign m_arlock  = s_arlock;
    assign m_arcache = s_arcache;
    assign m_arprot  = s_arprot;
    assign m_arvalid = s_arvalid;
    assign s_arready = m_arready;

    // ---- R ----
    assign s_rid    = m_rid;
    assign s_rdata  = m_rdata;
    assign s_rresp  = m_rresp;
    assign s_rlast  = m_rlast;
    assign s_rvalid = m_rvalid;
    assign m_rready = s_rready;

    // ---- AW ----
    assign m_awaddr  = map_addr(s_awaddr);
    assign m_awid    = s_awid;
    assign m_awlen   = s_awlen;
    assign m_awsize  = s_awsize;
    assign m_awburst = s_awburst;
    assign m_awlock  = s_awlock;
    assign m_awcache = s_awcache;
    assign m_awprot  = s_awprot;
    assign m_awvalid = s_awvalid;
    assign s_awready = m_awready;

    // ---- W ----
    assign m_wid    = s_wid;
    assign m_wdata  = s_wdata;
    assign m_wstrb  = s_wstrb;
    assign m_wlast  = s_wlast;
    assign m_wvalid = s_wvalid;
    assign s_wready = m_wready;

    // ---- B ----
    assign s_bid    = m_bid;
    assign s_bresp  = m_bresp;
    assign s_bvalid = m_bvalid;
    assign m_bready = s_bready;

endmodule
