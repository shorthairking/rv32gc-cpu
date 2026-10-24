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
// 三、DUT trace 格式 v3（cmp_commit.py 的输入契约；一行 = 一条提交）
//------------------------------------------------------------------------------
//   `#` 仅前三行是固定元数据；trace 版本为 `DUT commit trace v3`（旧 v1/v2 无 SD 域，
//   比对器明确拒绝，不静默降级）。数据行**固定字段顺序**（全部字段每行必在）：
//
//     <idx> pc=0x%08x xw=%0d xrd=%0d xval=0x%08x fw=%0d frd=%0d fval=0x%016x
//           st=%0d ssz=%0d s0a=0x%08x s0p=0x%08x s0d=0x%08x s0b=0x%x
//           s1a=0x%08x s1p=0x%08x s1d=0x%08x s1b=0x%x
//           cw=%0d cad=0x%03x cva=0x%08x cvo=0x%08x fl=%0d ff=0x%05x fs=%0d sd=%0d obs=%0d
//
//   · idx/pc : 0 起提交序号 + debug0_wb_pc（真实提交 PC）
//   · xw/xrd/xval : w_rf_we 整数写回（x0 不写；xw=0 时 xrd=-1、xval 无意义）
//   · fw/frd/fval : mw_fp_we 浮点写回，fval 为 **64 bit**（S 结果高 32 位 NaN-box）
//   · st/ssz/...  : **DUT 真实 store 请求**（M_S_ISS 的 m_store_w32/m_store_strb/
//                   m_va/m_pa_eff）。st=0 无 store；st=1 一个 4 B 车道；st=2 两个
//                   4 B 车道（仅 fsd）。ssz：0=sb,1=sh,2=sw/fsw,3=fsd。
//                   s0a/s1a = 虚拟地址（Spike mem 口径），s0p/s1p = DUT 实际物理
//                   地址；Bare 程序由比对器逐相比 PA==VA，翻译模式显式 UNSUPPORTED。
//   · cw/cad/cva/cvo : 显式 CSR 写（csr_wen_w；cad 为 CSR 号，FCSR 由比对器展开）；
//                   cva = 提交后实际状态（mstatus/sstatus 实际读视图；fflags/frm/
//                   fcsr 实际更新后寄存器；其余 post-WARL landing，不是原始 operand），
//                   cvo = 写前 waddr 视角当前值。**仅 PMP addr（0x3B0..0x3BF）**有
//                   csr_file 专用 one-hot 现值路径，故只有该区间非零并可用于识别
//                   "锁写 no-op"；其他 CSR 的产品读视图是 raddr 视角，不伪造成 0
//                   参与 no-op 判定（比对器对其缺失记录仍按失败处理）。
//   · fl/ff      : 隐式浮点 flags 副作用。push 在 E 更新后一拍，ff 取**实际
//                   fflags_r poststate**（不重算 OR）；与 W 级 CSR flags 写同拍
//                   时标 taint，提交时明确失败（无法独立归属）。
//   · fs         : 延迟一拍写出该提交后的**实际 mstatus.FS**（不复制 DUT 规则）
//   · sd         : 同一时刻直接采样 CoreTop csr_mstatus_view[31] 真实读视图，非 fs 推算
//   · obs        : 本行被声明字段无 X/Z 且可采样（0 ⇒ 比对器/本 TB 必须失败）
//
//   末行 `# end ...` 另含 **DUT 侧 AXI 观测**（AW 地址与 W 数据/strb 配对）：
//   magic_aw/magic_w/magic_addr/magic_data/magic_strb、doorbell_aw/doorbell_w/
//   doorbell_addr/doorbell_data/doorbell_strb、obs_err、bus_err。它们是"程序真的
//   在 DUT 上跑到结尾"的独立证据；Spike 单方停机不能替代。
//   ★ 限制：store 的逐笔总线落地不逐条比较（提交 store trace ≠ 总线恰一次）；
//     只有 magic/doorbell 两个锚点要求 DUT 总线恰一次。fsd 需要两相都捕到，
//     否则比对器拒绝（不拿单相冒充 64 位落盘）。
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
//   C7 所有提交已声明观测域无 X/Z；fflags 事件无残留/无 taint（obs_err=0）
//   C8 DUT 侧 AXI magic 写恰一次：AW 地址 == MAGIC_ADDR、对应 W 数据 == MAGIC_VAL、
//      strb == 4'hF（AW/W 配对，不是只看数据）
//   C9 DUT 侧 AXI UART 结束铃恰一次：AW 地址 == DOORBELL_ADDR、W 数据 == 0x5A、
//      strb == 4'hF；且无 W 无 AW 的协议错
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
    // ---- 程序结束标记地址（与 prog/lock_hello.S 一致；C8/C9 判据）----
    parameter [31:0]      MAGIC_ADDR     = 32'h8000_2000,  // 魔数落点
    parameter [31:0]      MAGIC_VAL      = 32'h600D_5EED,  // 魔数
    parameter [3:0]       MAGIC_STRB     = 4'hF,           // sw 的字节使能
    parameter [31:0]      DOORBELL_ADDR  = `RV32GC_UART_BASE, // 0x1FE0_01E0 结束铃
    parameter [31:0]      DOORBELL_VAL   = 32'h0000_005A,
    parameter [3:0]       DOORBELL_STRB  = 4'hF
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

    always @(posedge clk) begin
        if (aresetn && ar_fire && (ar_dbg_n < 12)) begin
            $display("TB_LOCKSTEP_DIAG: AR[%0d]=0x%08h len=%0d size=%0d cache=%b 核内 fetch_pc=0x%08h",
                     ar_dbg_n, araddr, arlen, arsize, arcache, u_dut.u_fetch_unit.fetch_pc);
            ar_dbg_n = ar_dbg_n + 1;
        end
    end

    // ---- 观测域 X/Z 检测（已声明字段必须可采样；有 X/Z ⇒ obs=0 ⇒ TB/比对器失败）----
    function integer unk64;
        input [63:0] v;
        begin unk64 = ((^v) === 1'bx); end
    endfunction
    function integer unk32;
        input [31:0] v;
        begin unk32 = ((^v) === 1'bx); end
    endfunction
    function integer unk16;
        input [15:0] v;
        begin unk16 = ((^v) === 1'bx); end
    endfunction
    function integer unk12;
        input [11:0] v;
        begin unk12 = ((^v) === 1'bx); end
    endfunction
    function integer unk5;
        input [4:0] v;
        begin unk5 = ((^v) === 1'bx); end
    endfunction
    function integer unk4;
        input [3:0] v;
        begin unk4 = ((^v) === 1'bx); end
    endfunction
    function integer unk3;
        input [2:0] v;
        begin unk3 = ((^v) === 1'bx); end
    endfunction
    function integer unk2;
        input [1:0] v;
        begin unk2 = ((^v) === 1'bx); end
    endfunction
    function integer unk1;
        input v;
        begin unk1 = ((v === 1'bx) || (v === 1'bz)); end
    endfunction

    //==========================================================================
    // 6.5 DUT 侧副作用观测（store / CSR / FP / fflags / 总线锚点）
    //==========================================================================
    // ---- 6.5.1 DUT 侧 AXI 写观测：AW 地址与 W 数据/strb 配对，只给两个锚点记账 ----
    integer magic_aw_n, magic_w_n, doorbell_aw_n, doorbell_w_n, bus_err;
    reg [31:0] magic_data_q, doorbell_data_q;
    reg [3:0]  magic_strb_q, doorbell_strb_q;
    reg        bus_aw_pend;
    reg [31:0] bus_aw_addr;
    wire aw_fire = awvalid & awready;
    wire w_fire  = wvalid & wready;

    always @(posedge clk) begin
        if (!aresetn) begin
            magic_aw_n = 0; magic_w_n = 0; doorbell_aw_n = 0; doorbell_w_n = 0;
            bus_err = 0; bus_aw_pend = 1'b0; bus_aw_addr = 32'h0;
            magic_data_q = 32'h0; magic_strb_q = 4'h0;
            doorbell_data_q = 32'h0; doorbell_strb_q = 4'h0;
        end else begin
            if (w_fire) begin
                if (!(bus_aw_pend || aw_fire)) begin
                    bus_err = bus_err + 1;
                end else begin
                    if ((aw_fire ? awaddr : bus_aw_addr) == MAGIC_ADDR) begin
                        magic_w_n = magic_w_n + 1;
                        magic_data_q = wdata; magic_strb_q = wstrb;
                    end
                    if ((aw_fire ? awaddr : bus_aw_addr) == DOORBELL_ADDR) begin
                        doorbell_w_n = doorbell_w_n + 1;
                        doorbell_data_q = wdata; doorbell_strb_q = wstrb;
                    end
                end
            end
            if (aw_fire) begin
                bus_aw_pend = 1'b1; bus_aw_addr = awaddr;
                if (awaddr == MAGIC_ADDR)    magic_aw_n    = magic_aw_n + 1;
                if (awaddr == DOORBELL_ADDR) doorbell_aw_n = doorbell_aw_n + 1;
            end
            if (w_fire && wlast) bus_aw_pend = 1'b0;
        end
    end

    // ---- 6.5.2 store 观测：M_S_ISS 实际 LSU 请求 + 与提交 PC 对齐 ----
    //   s0* 是低 4 B 车道，s1* 仅 fsd 的高 4 B 车道（两相都由 M 级真实请求捕获）。
    //   s0a/s1a 用虚拟地址（Spike mem 口径），s0p/s1p 是 DUT 实际物理地址；
    //   Bare 下两者必须相等，比较器默认 --pa-mode bare 逐相比对。
    reg         stg_v, stg_hi_v;
    localparam [3:0] TB_M_S_ISS    = 4'd7;
    localparam [3:0] TB_MEM_STORE  = 4'd2;
    localparam [3:0] TB_MEM_FSTORE = 4'd8;
    reg  [31:0] stg_pc, stg_a0, stg_p0, stg_d0, stg_a1, stg_p1, stg_d1;
    reg  [3:0]  stg_b0, stg_b1;
    reg  [2:0]  stg_ssz;
    wire        m_iss_store = (u_dut.m_state_q == TB_M_S_ISS) && ~u_dut.m_kill_fsm &&
                              ((u_dut.em_mem_op == TB_MEM_STORE) ||
                               (u_dut.em_mem_op == TB_MEM_FSTORE)) &&
                              ~u_dut.lsu_exc && ~u_dut.m_page_fault_q &&
                              ~u_dut.m_fp8_misalign;

    always @(posedge clk) begin
        if (!aresetn) begin
            stg_v <= 1'b0; stg_hi_v <= 1'b0;
            stg_pc <= 32'h0; stg_a0 <= 32'h0; stg_p0 <= 32'h0; stg_d0 <= 32'h0;
            stg_b0 <= 4'h0; stg_a1 <= 32'h0; stg_p1 <= 32'h0; stg_d1 <= 32'h0;
            stg_b1 <= 4'h0; stg_ssz <= 3'd0;
        end else begin
            if (ws_valid || u_dut.trap_exc || u_dut.mw_exc_valid) begin
                stg_v <= 1'b0; stg_hi_v <= 1'b0;
            end
            if (m_iss_store) begin
                if (u_dut.m_size8) begin
                    if (!u_dut.m_hi_q) begin
                        stg_v   <= 1'b1; stg_hi_v <= 1'b0;
                        stg_pc  <= u_dut.em_pc;
                        stg_a0  <= u_dut.m_va;
                        stg_p0  <= u_dut.m_pa_eff;
                        stg_d0  <= u_dut.m_store_w32;
                        stg_b0  <= u_dut.m_store_strb;
                        stg_ssz <= 3'd3;
                    end else begin
                        stg_hi_v <= 1'b1;
                        stg_a1   <= stg_a0 + 32'd4;
                        stg_p1   <= u_dut.m_pa_eff;
                        stg_d1   <= u_dut.m_store_w32;
                        stg_b1   <= u_dut.m_store_strb;
                    end
                end else begin
                    stg_v   <= 1'b1; stg_hi_v <= 1'b0;
                    stg_pc  <= u_dut.em_pc;
                    stg_a0  <= u_dut.m_va;
                    stg_p0  <= u_dut.m_pa_eff;
                    stg_d0  <= u_dut.m_store_w32;
                    stg_b0  <= u_dut.m_store_strb;
                    stg_ssz <= u_dut.em_mem_size;
                end
            end
        end
    end

    // ---- 6.5.3 隐式 fflags：真实 poststate 事件 FIFO ----
    //   push 在 E 级更新后一拍，val 取**实际 fflags_r**（不重算 fflags_r|fpu_flags）；
    //   若同拍还有 W 级 CSR flags 写，则 poststate 混入 merge 值 ⇒ taint，
    //   提交时明确失败（E/W 多 owner 无法独立归属，不把年轻污染归老）。
    reg        fl_ev_d;
    reg [31:0] fl_ev_pc;
    reg        fl_ev_taint;
    wire       fl_push = fl_ev_d;
    wire [31:0] fl_push_pc = fl_ev_pc;
    wire [4:0]  fl_push_val = u_dut.fflags_r;
    wire       fl_push_taint = fl_ev_taint;
    wire [31:0] fl_head_pc;
    wire [4:0]  fl_head_val;
    wire        fl_head_taint, fl_head_valid;
    wire [2:0]  fl_cnt;
    wire        fl_ovf, fl_unf;

    // 待写出的提交快照（延迟一拍：flush 时读实际 post-commit mstatus.FS）
    reg        pend_v;
    reg [31:0] p_pc, p_xval, p_s0a, p_s0p, p_s0d, p_s1a, p_s1p, p_s1d;
    reg [31:0] p_cva, p_cvo;
    reg [63:0] p_fval;
    reg [4:0]  p_ff;
    reg [11:0] p_cad;
    reg [3:0]  p_s0b, p_s1b;
    reg [2:0]  p_ssz;
    reg [1:0]  p_stn;
    reg        p_xw, p_fw, p_cw, p_st, p_obs;
    integer    p_xrd, p_frd;

    wire fl_pop = pend_v && fl_head_valid && (fl_head_pc == p_pc);

    lockstep_fflags_fifo #(.DEPTH(4)) u_flq (
        .clk(clk), .rst_n(aresetn),
        .push(fl_push), .push_pc(fl_push_pc), .push_val(fl_push_val),
        .push_taint(fl_push_taint), .pop(fl_pop),
        .head_pc(fl_head_pc), .head_val(fl_head_val), .head_taint(fl_head_taint),
        .head_valid(fl_head_valid), .count(fl_cnt),
        .overflow(fl_ovf), .underflow(fl_unf)
    );

    always @(posedge clk) begin
        if (!aresetn) begin
            fl_ev_d <= 1'b0; fl_ev_pc <= 32'h0; fl_ev_taint <= 1'b0;
        end else begin
            fl_ev_d <= u_dut.e_fflags_we && (u_dut.fpu_fflags != 5'd0);
            fl_ev_pc <= u_dut.de_pc;
            fl_ev_taint <= u_dut.csr_wen_w &&
                           ((u_dut.mw_csr_addr == 12'h001) ||
                            (u_dut.mw_csr_addr == 12'h002) ||
                            (u_dut.mw_csr_addr == 12'h003));
        end
    end

    integer trace_fd;
    reg [8*512-1:0] trace_path_q;
    integer commit_n;
    integer cyc;
    integer drain;
    reg     stopped;
    reg     first_pc_chk_done;
    reg     first_pc_ok;
    reg [31:0] first_pc;
    reg     c1_ok, c2_ok, c3_ok, c4_ok, c5_ok, c6_ok, c7_ok, c8_ok, c9_ok;
    integer obs_err;
    integer store_n, csr_n, fp_n, fl_n;
    integer cap_obs;

    // 写出一拍前的提交快照：fs 取实际 post-commit mstatus_fs（不重算规则）
    task automatic flush_pending;
        reg fm;
        reg sd_now;
        reg [31:0] cva_now;
        integer o;
        begin
            fm = fl_head_valid && (fl_head_pc == p_pc);
            o  = p_obs;
            // 两者同一 flush 时刻采样：FS 是 Top 持有的实际状态；SD 直接取
            // CoreTop 现有软件 CSR 读视图，不从 FS 在 TB 里推导。
            sd_now = u_dut.csr_mstatus_view[31];
            // 显式 CSR 的 poststate 取值：优先读提交后实际状态/视图，而不是
            // 重算写规则。mstatus/sstatus 取实际读视图（含派生 SD）；fflags/frm/
            // fcsr 取实际更新后的寄存器；其余取 post-WARL landing（cva）。
            cva_now = p_cva;
            if (p_cw) begin
                if (p_cad == 12'h300)
                    cva_now = u_dut.u_csr_file.mstatus_o;
                else if (p_cad == 12'h100)
                    cva_now = u_dut.u_csr_file.sstatus_view;
                else if (p_cad == 12'h001)
                    cva_now = {27'b0, u_dut.fflags_r};
                else if (p_cad == 12'h002)
                    cva_now = {29'b0, u_dut.frm_r};
                else if (p_cad == 12'h003)
                    cva_now = {24'b0, u_dut.frm_r, u_dut.fflags_r};
            end
            if (p_cw && unk32(cva_now)) o = 0;
            if (unk2(u_dut.mstatus_fs)) o = 0;
            if (unk1(sd_now)) o = 0;
            if (fm && unk5(fl_head_val)) o = 0;
            if (fm && fl_head_taint) begin
                $display("TB_LOCKSTEP_DIAG: fflags 事件与 W 级 CSR flags 写重叠 pc=0x%08h（无法独立归属，失败）",
                         p_pc);
                obs_err = obs_err + 1;
            end
            if (!o) obs_err = obs_err + 1;
            if (p_st) store_n = store_n + 1;
            if (p_cw) csr_n   = csr_n + 1;
            if (p_fw) fp_n    = fp_n + 1;
            if (fm)   fl_n    = fl_n + 1;
            $fwrite(trace_fd, "%0d pc=0x%08h xw=%0d xrd=%0d xval=0x%08h fw=%0d frd=%0d fval=0x%016h st=%0d ssz=%0d s0a=0x%08h s0p=0x%08h s0d=0x%08h s0b=0x%0h s1a=0x%08h s1p=0x%08h s1d=0x%08h s1b=0x%0h cw=%0d cad=0x%03h cva=0x%08h cvo=0x%08h fl=%0d ff=0x%05h fs=%0d sd=%0d obs=%0d\n",
                    commit_n, p_pc, p_xw, p_xrd, p_xval, p_fw, p_frd, p_fval,
                    p_stn, p_st ? p_ssz : 3'd0,
                    p_st ? p_s0a : 32'h0, p_st ? p_s0p : 32'h0,
                    p_st ? p_s0d : 32'h0, p_st ? p_s0b : 4'h0,
                    (p_st && p_stn == 2) ? p_s1a : 32'h0,
                    (p_st && p_stn == 2) ? p_s1p : 32'h0,
                    (p_st && p_stn == 2) ? p_s1d : 32'h0,
                    (p_st && p_stn == 2) ? p_s1b : 4'h0,
                    p_cw, p_cw ? p_cad : 12'h0,
                    p_cw ? cva_now : 32'h0, p_cw ? p_cvo : 32'h0,
                    fm, fm ? fl_head_val : 5'h0,
                    u_dut.mstatus_fs, sd_now, o);
            commit_n = commit_n + 1;
            pend_v <= 1'b0;
        end
    endtask

    initial begin
        aresetn          = 1'b0;
        commit_n         = 0;
        cyc              = 0;
        stopped          = 1'b0;
        ar_dbg_n         = 0;
        trace_fd         = 0;
        trace_path_q     = DUT_TRACE;
        first_pc_chk_done= 1'b0;
        first_pc_ok      = 1'b0;
        first_pc         = 32'h0;
        pend_v           = 1'b0;
        c1_ok = 1'b0; c2_ok = 1'b0; c3_ok = 1'b0; c4_ok = 1'b0;
        c5_ok = 1'b0; c6_ok = 1'b0; c7_ok = 1'b0; c8_ok = 1'b0; c9_ok = 1'b0;
        obs_err = 0; store_n = 0; csr_n = 0; fp_n = 0; fl_n = 0;

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
        $fwrite(trace_fd, "# DUT commit trace v3 — RV32GC 2A Spike lockstep (sim/lockstep/tb_lockstep.sv)\n");
        $fwrite(trace_fd, "# format: <idx> pc=... xw= xrd= xval= fw= frd= fval= st= ssz= s0a= s0p= s0d= s0b= s1a= s1p= s1d= s1b= cw= cad= cva= cvo= fl= ff= fs= sd= obs=\n");
        $fwrite(trace_fd, "# x=真实 GPR 写回; f=真实 FP 64bit 写回; st=M_S_ISS 真实 store 请求; cw=显式 CSR 写; fl/ff=实际 fflags 更新; fs=实际 mstatus.FS; sd=实际 csr_mstatus_view[31]（不由 TB 推算）\n");

        #1;
        load_prog(PROG_HEX);

        repeat (RESET_CYCLES) @(posedge clk);
        @(negedge clk);
        aresetn = 1'b1;
        $display("TB_LOCKSTEP: aresetn 已释放（保持 %0d 拍）", RESET_CYCLES);

        while (!stopped && (cyc < TIMEOUT_CYCLES)) begin
            @(posedge clk);
            cyc = cyc + 1;

            // (1) 先 flush 上一拍捕获的提交：此时 mstatus_fs 已是该提交后的实际值
            if (pend_v) flush_pending;

            // (2) 再捕获本拍提交（不写；下一拍 flush）
            if (ws_valid) begin
                if (!first_pc_chk_done) begin
                    first_pc_chk_done = 1'b1;
                    first_pc          = debug0_wb_pc;
                    first_pc_ok       = (debug0_wb_pc == `RV32GC_RESET_PC);
                end
                if (debug0_wb_pc == TERM_PC) begin
                    stopped = 1'b1;              // 终止点：不记录本条及以后
                end else begin
                    pend_v <= 1'b1;
                    p_pc   <= debug0_wb_pc;
                    p_xw   <= u_dut.w_rf_we;
                    p_xrd  <= u_dut.w_rf_we ? u_dut.mw_rd : -1;
                    p_xval <= u_dut.w_rf_we ? u_dut.mw_wdata : 32'h0;
                    p_fw   <= u_dut.mw_fp_we;
                    p_frd  <= u_dut.mw_fp_we ? u_dut.mw_fp_rd : -1;
                    p_fval <= u_dut.mw_fp_we ? u_dut.mw_fp_wdata : 64'h0;
                    p_cw   <= u_dut.csr_wen_w;
                    p_cad  <= u_dut.csr_wen_w ? u_dut.mw_csr_addr : 12'h0;
                    p_cva  <= u_dut.csr_wen_w ? u_dut.u_csr_file.wval_final : 32'h0;
                    p_cvo  <= (u_dut.csr_wen_w &&
                               (u_dut.mw_csr_addr >= 12'h3B0) &&
                               (u_dut.mw_csr_addr <= 12'h3BF))
                              ? u_dut.u_csr_file.rd_waddr_cur : 32'h0;
                    p_st   <= stg_v && (stg_pc == debug0_wb_pc);
                    p_stn  <= (stg_v && (stg_pc == debug0_wb_pc))
                              ? (stg_hi_v ? 2'd2 : 2'd1) : 2'd0;
                    p_ssz  <= (stg_v && (stg_pc == debug0_wb_pc)) ? stg_ssz : 3'd0;
                    p_s0a  <= (stg_v && (stg_pc == debug0_wb_pc)) ? stg_a0 : 32'h0;
                    p_s0p  <= (stg_v && (stg_pc == debug0_wb_pc)) ? stg_p0 : 32'h0;
                    p_s0d  <= (stg_v && (stg_pc == debug0_wb_pc)) ? stg_d0 : 32'h0;
                    p_s0b  <= (stg_v && (stg_pc == debug0_wb_pc)) ? stg_b0 : 4'h0;
                    p_s1a  <= (stg_v && (stg_pc == debug0_wb_pc) && stg_hi_v) ? stg_a1 : 32'h0;
                    p_s1p  <= (stg_v && (stg_pc == debug0_wb_pc) && stg_hi_v) ? stg_p1 : 32'h0;
                    p_s1d  <= (stg_v && (stg_pc == debug0_wb_pc) && stg_hi_v) ? stg_d1 : 32'h0;
                    p_s1b  <= (stg_v && (stg_pc == debug0_wb_pc) && stg_hi_v) ? stg_b1 : 4'h0;

                    cap_obs = 1;
                    if (unk32(debug0_wb_pc)) cap_obs = 0;
                    if (u_dut.w_rf_we &&
                        (unk5(u_dut.mw_rd) || unk32(u_dut.mw_wdata))) cap_obs = 0;
                    if (u_dut.mw_fp_we &&
                        (unk5(u_dut.mw_fp_rd) || unk64(u_dut.mw_fp_wdata))) cap_obs = 0;
                    if (u_dut.csr_wen_w &&
                        (unk12(u_dut.mw_csr_addr) ||
                         unk32(u_dut.u_csr_file.wval_final))) cap_obs = 0;
                    if (u_dut.csr_wen_w &&
                        (u_dut.mw_csr_addr >= 12'h3B0) &&
                        (u_dut.mw_csr_addr <= 12'h3BF) &&
                        unk32(u_dut.u_csr_file.rd_waddr_cur)) cap_obs = 0;
                    if (stg_v && (stg_pc == debug0_wb_pc)) begin
                        if (unk32(stg_a0) || unk32(stg_p0) || unk32(stg_d0) ||
                            unk4(stg_b0) || unk3(stg_ssz)) cap_obs = 0;
                        if (stg_hi_v && (unk32(stg_a1) || unk32(stg_p1) ||
                                         unk32(stg_d1) || unk4(stg_b1))) cap_obs = 0;
                    end
                    p_obs <= cap_obs;
                end
            end
        end

        // 超时路径也把已捕获的一拍写出去（reason 仍是 TIMEOUT，判 FAIL）
        if (pend_v) flush_pending;

        for (drain = 0; drain < DRAIN_CYCLES; drain = drain + 1) @(posedge clk);
        cyc = cyc + DRAIN_CYCLES;

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
        $display("TB_LOCKSTEP_DIAG: 观测域条数 store=%0d csr=%0d fp64=%0d fflags=%0d obs_err=%0d",
                 store_n, csr_n, fp_n, fl_n, obs_err);
        $display("TB_LOCKSTEP_DIAG: DUT AXI 锚点 magic(aw=%0d,w=%0d,data=0x%08h,strb=0x%0h) doorbell(aw=%0d,w=%0d,data=0x%08h,strb=0x%0h) bus_err=%0d",
                 magic_aw_n, magic_w_n, magic_data_q, magic_strb_q,
                 doorbell_aw_n, doorbell_w_n, doorbell_data_q, doorbell_strb_q, bus_err);
        if (fl_cnt != 0) begin
            $display("TB_LOCKSTEP_DIAG: 残留 fflags 事件 fl_cnt=%0d fl_ovf=%0d fl_unf=%0d（未按提交 PC 对齐/被冲刷/溢出）",
                     fl_cnt, fl_ovf, fl_unf);
            obs_err = obs_err + 1;
        end
        if (fl_ovf != 0 || fl_unf != 0) obs_err = obs_err + 1;

        $fwrite(trace_fd, "# end commits=%0d cycles=%0d reason=%0s term_pc=0x%08h uart_writes=%0d magic_aw=%0d magic_w=%0d magic_addr=0x%08h magic_data=0x%08h magic_strb=0x%0h doorbell_aw=%0d doorbell_w=%0d doorbell_addr=0x%08h doorbell_data=0x%08h doorbell_strb=0x%0h obs_err=%0d bus_err=%0d\n",
                commit_n, cyc, stopped ? "TERM_PC" : "TIMEOUT", TERM_PC, u_mem.uart_write_count,
                magic_aw_n, magic_w_n, MAGIC_ADDR, magic_data_q, magic_strb_q,
                doorbell_aw_n, doorbell_w_n, DOORBELL_ADDR, doorbell_data_q, doorbell_strb_q,
                obs_err, bus_err);
        $fclose(trace_fd);

        c1_ok = (load_err == 0) && (xip_words_loaded == 2) && (ddr_words_loaded > 0);
        c2_ok = u_mem.first_ar_seen && (u_mem.first_ar_addr == `RV32GC_RESET_PC);
        c3_ok = first_pc_chk_done && first_pc_ok;
        c4_ok = stopped;
        c5_ok = (commit_n >= MIN_COMMITS);
        c6_ok = (u_mem.uart_write_count >= 1) && !u_mem.uart_overflow;
        c7_ok = (obs_err == 0);
        c8_ok = (magic_aw_n == 1) && (magic_w_n == 1) &&
                (magic_data_q == MAGIC_VAL) && (magic_strb_q == MAGIC_STRB);
        c9_ok = (doorbell_aw_n == 1) && (doorbell_w_n == 1) &&
                (doorbell_data_q == DOORBELL_VAL) && (doorbell_strb_q == DOORBELL_STRB) &&
                (bus_err == 0);

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
        if (!c7_ok) $display("TB_LOCKSTEP: FAIL C7 观测域含 X/Z、fflags 事件无法独立归属或残留（obs_err=%0d）",
                             obs_err);
        if (!c8_ok) $display("TB_LOCKSTEP: FAIL C8 DUT 侧 magic 写证据不足（aw=%0d w=%0d data=0x%08h/期望 0x%08h strb=0x%0h/期望 0x%0h）",
                             magic_aw_n, magic_w_n, magic_data_q, MAGIC_VAL, magic_strb_q, MAGIC_STRB);
        if (!c9_ok) $display("TB_LOCKSTEP: FAIL C9 DUT 侧 UART 结束铃证据不足（aw=%0d w=%0d data=0x%08h/期望 0x%08h strb=0x%0h/期望 0x%0h bus_err=%0d）",
                             doorbell_aw_n, doorbell_w_n, doorbell_data_q, DOORBELL_VAL,
                             doorbell_strb_q, DOORBELL_STRB, bus_err);

        if (c1_ok && c2_ok && c3_ok && c4_ok && c5_ok && c6_ok && c7_ok && c8_ok && c9_ok) begin
            $display("TB_LOCKSTEP: DUT_TRACE_OK commits=%0d cycles=%0d trace=%0s uart_writes=%0d store=%0d csr=%0d fp64=%0d fflags=%0d",
                     commit_n, cyc, str_lj(DUT_TRACE), u_mem.uart_write_count,
                     store_n, csr_n, fp_n, fl_n);
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
