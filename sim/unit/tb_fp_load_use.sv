//==============================================================================
// sim/unit/tb_fp_load_use.sv —— FP load-use 显式互锁回归 TB（core_top 级，自包含）
//==============================================================================
// 项目  : rv32gc-cpu（阶段二 2A 单发射顺序 5 级基线核）
// 顶层名: tb_fp_load_use（scripts/regress.sh 自动发现 sim/unit/tb_*.sv 后用 -s 指定）
// 依据  : AGENT.md §0.6（未捕获即失败）、§3.3（旁路/转发网络漏洞是最常见缺陷源）；
//         docs/design/08-baseline-5stage.md §5.0（load-use 互锁口径）；
//         NEXT_SESSION.md §1.5 遗留①「FP load-use 未显式互锁」。
//------------------------------------------------------------------------------
// 一、这个 TB 测什么（唯一目标）
//------------------------------------------------------------------------------
//   缺陷：`flw/fld` 之后紧邻的 FP 消费者（OP-FP/FMA 的 fs1/fs2/fs3，或 FP store
//   的存数 fs2）会从 fregfile 读到旧值：
//     · fregfile 的写优先旁路只覆盖 W 槽（写口在 W，见 fregfile.v §11②）；
//     · 而"紧邻消费者"在 E 级时，生产者才刚到 M 槽 ⇒ 组合读口拿到旧值；
//     · FPU 是"派发拍采样操作数"的单元（fpu.v §2：单拍类 done=req_valid、
//       div/sqrt 在 start 拍锁存）⇒ 一旦带旧操作数派发，后续停拍也救不回来。
//   ⇒ 判据：程序里每组「FP load → 紧邻消费其结果」都必须得到架构正确结果。
//
//   ★ 为什么必须程序驻 RAM（本 TB 的关键设计，别改回单一 XIP 区）：
//     板级复位向量在 XIP 窗口 0x1C00_0000，但该窗口取指绕过 I-Cache、
//     每取一条要一次单拍 AXI 读（实测 len=0、约 10 余拍）⇒ 流水被塞满取指气泡，
//     "紧邻消费"根本不会发生（实测：程序整体放 XIP 时本缺陷测不出来）。
//     本 TB 因此分两段（与 sim/arch_test 的 boot_stub 同口径）：
//       .boot @0x1C00_0000（2 条：lui+jr 跳到 RAM）
//       .main @0x8000_0000（34 条，取指走 L1I ⇒ 指令 back-to-back 进流水）
//     数据区在 RAM 0x8000_0400（route=ROUTE_AXI ⇒ M_S_AXI 两阶段 8 B 通路，
//     与 8 B fld/fsd 的真实通路一致），由程序自身用整数 store 初始化。
//
//------------------------------------------------------------------------------
// 二、结构（自包含：不依赖 sim/tb/*、不依赖外部 hex/脚本/cwd）
//------------------------------------------------------------------------------
//   tb_fp_load_use
//     ├── u_dut : rtl/top/core_top.v（48 端口逐字例化，rtl 只读）
//     └── 本文件内置 AXI4 从设备 + 两个存储体：
//           · boot[0x1C00_0000 + 4 KiB] ：复位桩（内嵌 2 字）
//           · ram [0x8000_0000 + 1 KiB] ：主程序（内嵌 34 字）+ 数据/结果区（+0x400）
//   程序真源 = sim/unit/prog/fp_load_use.S（汇编命令见该文件头；两侧逐字一致，
//   TB 内的字面量与 §四 objdump 反汇编一一对应）。
//
//------------------------------------------------------------------------------
// 三、判据（全部 fail-closed；任一不满足 ⇒ 打印 TB_FP_LOAD_USE: FAIL ... + $fatal）
//------------------------------------------------------------------------------
//   C1 程序映像载入无误（.boot[0]/[1] 与 .main[0] 逐字 == 反汇编，非零字 ≥ 30）
//      —— 防"空/错镜像"假通过；
//   C2 首笔 AXI 读地址 == RESET_PC（0x1C00_0000）—— 证明核真的从 XIP 窗口取指；
//   C3 在 TIMEOUT_CYCLES 内观察到 数据区+96 == 完成标志 0x5A5A_A5A5（程序跑到终点，
//      且它是最后一条 store ⇒ 其前所有结果 store 均已落地）；
//   C4 A–F 六组期望值逐字相等（64 bit 值按低/高两字比，32 bit 值按整字比）；
//   C5 全程无未登记地址访问（unknown_rd/wr == 0）；
//   C6 场景可达性：EMU_FETCH_BUFFER=1（取指缓冲仿真口径）时**必须**观察到
//      「E 槽 FP 消费者 ∩ M 槽 FP load 未完成」状态（> 0 拍），否则判 FAIL ——
//      防"测试空跑"；正常口径（=0）下只作诊断打印（原因见 §六）。
//   C7 协议断言（**FP load-use 互锁的直接判据**）：在「消费者在 E、生产者在 M 且
//      未就绪」的每一拍，若 FPU 被派发（e_fp_go），则被消费端口（按 fpu 内部类别选
//      通 a/b/c）采样到的值必须等于该 load 的期望值（按 VA/尺寸从存储体取，
//      flw 按 NaN-box）；不等即违规。
//   C8 协议断言（FP store 存数）：若 E 槽是 FP store 且其存数寄存器命中紧邻在途
//      FP load 的 rd，且本拍发生 E→M 捕获，则下一拍 em_fp_store 必须 == load 期望值。
//   ★ 唯一成功行 = TB_FP_LOAD_USE: PASS（整行，恰好一次）；失败路径只打印
//     TB_FP_LOAD_USE: FAIL ...，绝无兜底成功文案。
//
//------------------------------------------------------------------------------
// 六、证据矩阵（criterion ①：测试必须对该洞敏感；本项目 AGENT.md §3.2 变异纪律）
//------------------------------------------------------------------------------
//   ★ 重要实测结论：**本核当前（未修复基线）正常口径下该洞不可达** ——
//     取指单元与流水强耦合（fetch_unit.v:246 `fetch_req_valid = need & ~fetch_busy`，
//     停顿时完全不取指）+ L1I 命中 1 拍 + FD/DE 同步更新 ⇒ 取指吞吐 ≈ 1 条/2 拍，
//     且**任何占住 M 的访存指令后面必然插一个取指气泡**：消费者要等 load 完成
//     （load 进 W）之后才进 E，于是被 fregfile 写优先旁路覆盖。
//     实测：C6 场景拍数在"基线正常口径/修复后正常口径"下**都是 0**（见矩阵）。
//     ⇒ 这也是整数 load-use 停拍项至今"看不出效果"的同一个原因。
//     因此本 TB 给出 `EMU_FETCH_BUFFER=1` 开关（**用 force 把 F/D 槽提前一拍填上
//     load 的下一条指令**，等价于给取指加 1 项缓冲）来真实构造该状态；
//     并用 `DISABLE_INTERLOCK=1`（force 掉修复新增的停拍项）做变异。
//     注意：注入会让消费者指令被**重复执行**一次（取指稍后仍会再交一次），
//     端到端内存结果会被第二次执行"自动修正" ⇒ 故判据以 **C7/C8 协议断言**为准。
//
//   复现命令（iverilog 12.0；RTL 源集合同 scripts/regress.sh）：
//     R="$(find rtl -name '*.v' | sort)"
//     # ① 修复后 + 取指缓冲仿真 ⇒ 期望 PASS（C6>0、C7=C8=0）
//     iverilog -g2012 -I rtl/pkg -I . -s tb_fp_load_use \
//       -P tb_fp_load_use.EMU_FETCH_BUFFER=1 -o /tmp/a.vvp $R sim/unit/tb_fp_load_use.sv
//     vvp /tmp/a.vvp
//     # ② 修复前基线 + 取指缓冲仿真 ⇒ 期望 FAIL（C7 违规 4 次：A/B/C/E 四例旧值）
//     #    做法：把 rtl/top/core_top.v 换成修复前副本（cp 备份/还原，禁 git checkout）
//     # ③ 修复后 + 取指缓冲仿真 + DISABLE_INTERLOCK=1 ⇒ 期望 FAIL（变异必红）
//     # ④ 正常口径（不带 -P）⇒ 任意版本都 PASS（= §六 的掩蔽结论本身）
//
//------------------------------------------------------------------------------
// 四、程序反汇编（真源 = sim/unit/prog/fp_load_use.S；共 2 + 34 字）
//------------------------------------------------------------------------------
//   Disassembly（objdump 原文，逐条与下面数组一一对应）：
//     1c000000 <_boot>:
//     1c000000:	800002b7          	lui	t0,0x80000
//     1c000004:	00028067          	jr	t0 # 80000000 <_start>
//     80000000 <_start>:
//     80000000:	000062b7          	lui	t0,0x6
//     80000004:	30029073          	csrw	mstatus,t0
//     80000008:	80000537          	lui	a0,0x80000
//     8000000c:	40050513          	addi	a0,a0,1024 # 80000400 <_start+0x400>
//     80000010:	00052023          	sw	zero,0(a0)
//     80000014:	400802b7          	lui	t0,0x40080
//     80000018:	00552223          	sw	t0,4(a0)
//     8000001c:	40400337          	lui	t1,0x40400
//     80000020:	00652423          	sw	t1,8(a0)
//     80000024:	06400f13          	li	t5,100
//     80000028:	00700f93          	li	t6,7
//     8000002c:	03ff43b3          	div	t2,t5,t6
//     80000030:	00053007          	fld	ft0,0(a0)
//     80000034:	02007153          	fadd.d	ft2,ft0,ft0
//     80000038:	00253827          	fsd	ft2,16(a0)
//     8000003c:	03ff43b3          	div	t2,t5,t6
//     80000040:	00852187          	flw	ft3,8(a0)
//     80000044:	0031f253          	fadd.s	ft4,ft3,ft3
//     80000048:	00452c27          	fsw	ft4,24(a0)
//     8000004c:	03ff43b3          	div	t2,t5,t6
//     80000050:	00053287          	fld	ft5,0(a0)
//     80000054:	2a52f343          	fmadd.d	ft6,ft5,ft5,ft5
//     80000058:	02653027          	fsd	ft6,32(a0)
//     8000005c:	03ff43b3          	div	t2,t5,t6
//     80000060:	00053387          	fld	ft7,0(a0)
//     80000064:	02753827          	fsd	ft7,48(a0)
//     80000068:	03ff43b3          	div	t2,t5,t6
//     8000006c:	00852407          	flw	fs0,8(a0)
//     80000070:	02852c27          	fsw	fs0,56(a0)
//     80000074:	03ff43b3          	div	t2,t5,t6
//     80000078:	00852487          	flw	fs1,8(a0)
//     8000007c:	e0048e53          	fmv.x.w	t3,fs1
//     80000080:	05c52023          	sw	t3,64(a0)
//     80000084:	03ff43b3          	div	t2,t5,t6
//     80000088:	00053507          	fld	fa0,0(a0)
//     8000008c:	07b00e93          	li	t4,123
//     80000090:	02a575d3          	fadd.d	fa1,fa0,fa0
//     80000094:	04b53427          	fsd	fa1,72(a0)
//     80000098:	5a5aaf37          	lui	t5,0x5a5aa
//     8000009c:	5a5f0f13          	addi	t5,t5,1445 # 5a5aa5a5 <_boot+0x3e5aa5a5>
//     800000a0:	07e52023          	sw	t5,96(a0)
//     800000a4:	0000006f          	j	800000a4 <_start+0xa4>
//
//   ★ 数据区（a0 = 0x8000_0400；小端：低字在低地址）：
//     +0  D3 = 3.0（+0=0, +4=0x4008_0000）    +8  S3 = 3.0f（0x4040_0000）
//     +16 A(fadd.d 6.0)  +24 B(fadd.s 6.0f)   +32 C(fmadd.d 12.0)
//     +48 D1(fsd 3.0)    +56 D2(fsw 3.0f)     +64 E(fmv.x.w 0x4040_0000)
//     +72 F(fadd.d 6.0)  +96 完成标志
//
//------------------------------------------------------------------------------
// 五、风格/红线
//------------------------------------------------------------------------------
//   · TESTBENCH（不可综合）：存储体/通道状态用 always 块建模是必需；
//   · 无 FPGA 原语、无 Vivado IP 依赖 ⇒ iverilog 回归自洽（红线 1/2 合规）；
//   · 本文件的 AXI 逻辑是从设备行为模型（验证件），不是设计侧代码：
//     红线 4 的边界判据针对可综合 RTL（08 §7.1）。
//==============================================================================
`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"

module tb_fp_load_use #(
    // ---- 时钟/复位 ----
    parameter integer CLK_HALF_NS        = 5,      // 半周期 5 ns ⇒ 10 ns
    parameter integer RESET_CYCLES       = 20,     // 复位保持拍数
    // ---- 判定参数 ----
    parameter integer TIMEOUT_CYCLES     = 300000, // 超时拍数 ⇒ FAIL
    parameter integer DIAG_NO_REQ_CYCLES = 20000,  // 无进展时的诊断打印点
    parameter integer COMMIT_PRINT_LIM   = 6,      // 提交观测打印上限（诊断）
    // ---- 内存布局 ----
    parameter [31:0]  BOOT_BASE          = 32'h1C00_0000,   // 复位向量窗口（= RESET_PC）
    parameter integer BOOT_WORDS         = 1024,            // 4 KiB
    parameter [31:0]  RAM_BASE           = 32'h8000_0000,   // 主程序 + 数据区
    parameter integer RAM_WORDS          = 512,             // 2 KiB（数据区起 +0x400 ⇒ 需 ≥ 0x460）
    parameter [31:0]  DATA_BASE          = 32'h8000_0400,   // 数据/结果区（= a0）
    // ---- 反证实验开关（**默认 0 = 正常回归口径**；证据矩阵见 §六）----
    //   EMU_FETCH_BUFFER=1：用 `force` 把 F/D 槽提前一拍填上"load 的下一条指令"，
    //     等价于给取指加 1 项缓冲（去掉本核取指与流水的强耦合）。**只是实验**：
    //     本核当前取指在停顿时不取指（fetch_unit.v:246 `& ~fetch_busy`）+ L1I 命中
    //     1 拍 ⇒ 实测吞吐 ≈ 1 条/2 拍且 load 后必插气泡 ⇒「E 槽消费者 ∩ M 槽未完成
    //     load」状态本身不可达（见 §六）。开此开关才能真实构造该状态。
    //   DISABLE_INTERLOCK=1：把修复新增的 `fp_load_use_stall` 强制为 0（互锁变异），
    //     用于证明"关掉互锁 ⇒ 本 TB 必 FAIL"（AGENT.md §3.2 变异测试纪律）。
    parameter integer EMU_FETCH_BUFFER   = 0,
    parameter integer DISABLE_INTERLOCK  = 0
) ();

    //==========================================================================
    // 0. 程序映像（真源 = sim/unit/prog/fp_load_use.S；见 §四 反汇编）
    //==========================================================================
    localparam integer BOOT_LEN = 2;
    localparam integer MAIN_LEN = 42;
    localparam [31:0]  BOOT_W0  = 32'h800002B7;   // 复位桩首字（镜像自检锚点）
    localparam [31:0]  MAIN_W0  = 32'h000062B7;   // 主程序首字（镜像自检锚点）

    reg [31:0] boot_prog [0:BOOT_LEN-1];
    reg [31:0] main_prog [0:MAIN_LEN-1];
    initial begin
        // ==== .boot / .main（真源 sim/unit/prog/fp_load_use.S）====
        boot_prog[ 0] = 32'h800002b7;
        boot_prog[ 1] = 32'h00028067;

        // ==== .boot / .main（真源 sim/unit/prog/fp_load_use.S）====
        main_prog[ 0] = 32'h000062b7;
        main_prog[ 1] = 32'h30029073;
        main_prog[ 2] = 32'h80000537;
        main_prog[ 3] = 32'h40050513;
        main_prog[ 4] = 32'h00052023;
        main_prog[ 5] = 32'h400802b7;
        main_prog[ 6] = 32'h00552223;
        main_prog[ 7] = 32'h40400337;
        main_prog[ 8] = 32'h00652423;
        main_prog[ 9] = 32'h06400f13;
        main_prog[10] = 32'h00700f93;
        main_prog[11] = 32'h03ff43b3;
        main_prog[12] = 32'h00053007;
        main_prog[13] = 32'h02007153;
        main_prog[14] = 32'h00253827;
        main_prog[15] = 32'h03ff43b3;
        main_prog[16] = 32'h00852187;
        main_prog[17] = 32'h0031f253;
        main_prog[18] = 32'h00452c27;
        main_prog[19] = 32'h03ff43b3;
        main_prog[20] = 32'h00053287;
        main_prog[21] = 32'h2a52f343;
        main_prog[22] = 32'h02653027;
        main_prog[23] = 32'h03ff43b3;
        main_prog[24] = 32'h00053387;
        main_prog[25] = 32'h02753827;
        main_prog[26] = 32'h03ff43b3;
        main_prog[27] = 32'h00852407;
        main_prog[28] = 32'h02852c27;
        main_prog[29] = 32'h03ff43b3;
        main_prog[30] = 32'h00852487;
        main_prog[31] = 32'he0048e53;
        main_prog[32] = 32'h05c52023;
        main_prog[33] = 32'h03ff43b3;
        main_prog[34] = 32'h00053507;
        main_prog[35] = 32'h07b00e93;
        main_prog[36] = 32'h02a575d3;
        main_prog[37] = 32'h04b53427;
        main_prog[38] = 32'h5a5aaf37;
        main_prog[39] = 32'h5a5f0f13;
        main_prog[40] = 32'h07e52023;
        main_prog[41] = 32'h0000006f;
    end

    //==========================================================================
    // 1. 时钟 / 复位
    //==========================================================================
    reg clk;
    reg aresetn;

    initial clk = 1'b0;
    always #(CLK_HALF_NS) clk = ~clk;

    integer rst_cnt;
    initial begin
        aresetn = 1'b0;
        for (rst_cnt = 0; rst_cnt < RESET_CYCLES; rst_cnt = rst_cnt + 1) @(posedge clk);
        @(negedge clk);                 // 负沿释放：避免与 posedge 竞争
        aresetn = 1'b1;
    end

    //==========================================================================
    // 2. DUT ↔ TB 的 AXI4 连线
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
    // 4. 存储体与地址译码
    //==========================================================================
    localparam [1:0] RESP_OKAY = `RV32GC_AXI_RESP_OKAY;

    reg [31:0] boot [0:BOOT_WORDS-1];   // 0x1C00_0000 复位向量窗口（复位桩）
    reg [31:0] ram  [0:RAM_WORDS-1];    // 0x8000_0000 主程序 + 数据区

    function is_boot; input [31:0] a; begin is_boot = (a >= BOOT_BASE) && (a < BOOT_BASE + 4*BOOT_WORDS); end endfunction
    function is_ram;  input [31:0] a; begin is_ram  = (a >= RAM_BASE)  && (a < RAM_BASE  + 4*RAM_WORDS);  end endfunction

    // 组合读：未写过的字节按 0 返回（x 传播会让取指通路"看似有指令"）
    function [31:0] mem_read;
        input [31:0] a;
        reg [31:0] w;
        begin
            if (is_boot(a))      w = boot[(a - BOOT_BASE) >> 2];
            else if (is_ram(a))  w = ram [(a - RAM_BASE ) >> 2];
            else                 w = 32'h0000_0000;
            mem_read = { (^w[31:24] === 1'bx) ? 8'h00 : w[31:24],
                         (^w[23:16] === 1'bx) ? 8'h00 : w[23:16],
                         (^w[15: 8] === 1'bx) ? 8'h00 : w[15: 8],
                         (^w[ 7: 0] === 1'bx) ? 8'h00 : w[ 7: 0] };
        end
    endfunction

    // 可观测计数
    reg [31:0] ar_count, aw_count, r_beat_count, w_beat_count;
    reg [31:0] unknown_rd_count, unknown_wr_count, bus_cycles;
    reg        first_ar_seen;
    reg [31:0] first_ar_addr;
    integer    commit_count;

    // AXI 写：按 wstrb 落字节
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
            end else if (is_boot(a)) begin
                $display("[tb_fp_load_use] WARN: 对复位向量窗口的写被忽略 addr=0x%08h", a);
            end else begin
                unknown_wr_count = unknown_wr_count + 1;
                if (unknown_wr_count <= 8)
                    $display("[tb_fp_load_use] WARN: 未登记区域写被忽略 addr=0x%08h data=0x%08h strb=%b",
                             a, d, strb);
            end
        end
    endtask

    //==========================================================================
    // 5. AXI4 从设备（单笔在途；AR→R 逐拍 INCR 多 beat；AW/W→B；读延迟 1 拍）
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
    assign rresp   = RESP_OKAY;
    assign rvalid  = rd_active;
    assign rlast   = (rd_cnt_q[3:0] == rd_len_q);

    assign awready = awready_r;
    assign wready  = wr_pend & ~bvalid_r;
    assign bid     = aw_id_q;
    assign bresp   = RESP_OKAY;
    assign bvalid  = bvalid_r;

    wire ar_fire = arvalid & arready;
    wire r_fire  = rvalid & rready;
    wire aw_fire = awvalid & awready;
    wire w_fire  = wvalid & wready;
    wire b_fire  = bvalid & bready;

    integer i;
    initial begin
        // 存储体上电清零 + 程序映像载入（复位保持期内完成，见 §1 的 RESET_CYCLES）
        for (i = 0; i < BOOT_WORDS; i = i + 1) boot[i] = 32'h0;
        for (i = 0; i < RAM_WORDS;  i = i + 1) ram [i] = 32'h0;
        for (i = 0; i < BOOT_LEN;   i = i + 1) boot[i] = boot_prog[i];
        for (i = 0; i < MAIN_LEN;   i = i + 1) ram [i] = main_prog[i];
    end

    // 提交观测（诊断：证明核在真跑指令）
    initial commit_count = 0;
    always @(posedge clk) begin
        if (aresetn && ws_valid) begin
            if (commit_count < COMMIT_PRINT_LIM)
                $display("[tb_fp_load_use] 提交 #%0d pc=0x%08h wen=%b rd=x%0d wdata=0x%08h",
                         commit_count, debug0_wb_pc, debug0_wb_rf_wen[0],
                         debug0_wb_rf_wnum, debug0_wb_rf_wdata);
            commit_count = commit_count + 1;
        end
    end

    // ---- C6 场景护栏：E 槽 FP 消费者命中 M 槽"尚未完成"的 FP load 的 rd ----
    //   用层次引用读 E/M 槽（只做"场景是否发生"的证据；结果判定一律用内存内容）
    localparam [3:0] TB_MEM_FLOAD  = 4'd7;
    localparam [3:0] TB_MEM_FSTORE = 4'd8;
    localparam [3:0] TB_OPT_FP     = 4'd11;
    wire tb_use_fs1 = (u_dut.de_op_type == TB_OPT_FP);                        // OP-FP/FMA
    wire tb_use_fs2 = (u_dut.de_op_type == TB_OPT_FP) |
                      (u_dut.de_mem_op  == TB_MEM_FSTORE);                     // + FP store 存数
    wire tb_use_fs3 = (u_dut.de_op_type == TB_OPT_FP);                        // FMA 的 rs3
    wire tb_src_hit = (tb_use_fs1 & (u_dut.de_rs1 == u_dut.em_fp_rd)) |
                      (tb_use_fs2 & (u_dut.de_rs2 == u_dut.em_fp_rd)) |
                      (tb_use_fs3 & (u_dut.de_rs3 == u_dut.em_fp_rd));
    wire tb_hazard_live = u_dut.de_valid & u_dut.em_valid &
                          (u_dut.em_mem_op == TB_MEM_FLOAD) & ~u_dut.m_mem_done & tb_src_hit;

    integer hazard_cycles;
    integer stall_cycles;
    initial hazard_cycles = 0;
    initial stall_cycles  = 0;
    always @(posedge clk) begin
        if (!aresetn) begin
            hazard_cycles = 0;
            stall_cycles  = 0;
        end else begin
            if (tb_hazard_live) hazard_cycles = hazard_cycles + 1;
            // 诊断：E 级 load-use 互锁断言拍数（只是证据，不是判据 ——
            //   规格允许"停拍/转发"两种实现，测试不得绑定某一实现细节）
            if (u_dut.load_use_stall) stall_cycles = stall_cycles + 1;
        end
    end

    //==========================================================================
    // 5.5 反证实验（**只在显式开开关时生效**；正常回归两条都不生效）
    //--------------------------------------------------------------------------
    //  (a) EMU_FETCH_BUFFER=1：模拟"取指有 1 项缓冲"——在 FP load 处于 E 槽的那一拍
    //      把 F/D 槽 force 成"load 的下一条指令"（pc+4，指令字取自程序存储体）。
    //      正常核里这一拍 F/D 槽是取指气泡（取指停顿时不取指），所以消费者要等 load
    //      完成后才进 E；强填后消费者与 load 真正背靠背，洞才会现形。
    //  (b) DISABLE_INTERLOCK=1：把 `fp_load_use_stall` 强制 0（等价"互锁逻辑关掉"）。
    //==========================================================================
    reg fd_forced;
    initial fd_forced = 1'b0;
    always @(negedge clk) begin
        if (EMU_FETCH_BUFFER != 0) begin
            if (!fd_forced && aresetn && u_dut.de_valid &&
                (u_dut.de_mem_op == TB_MEM_FLOAD)) begin
                force u_dut.fd_valid     = 1'b1;
                force u_dut.fd_pc        = u_dut.de_pc + 32'd4;
                force u_dut.fd_insn      = ram[(u_dut.de_pc + 32'd4 - RAM_BASE) >> 2];
                force u_dut.fd_ilen32    = 1'b1;
                force u_dut.fd_exc_valid = 1'b0;
                fd_forced = 1'b1;
            end else if (fd_forced) begin
                release u_dut.fd_valid;
                release u_dut.fd_pc;
                release u_dut.fd_insn;
                release u_dut.fd_ilen32;
                release u_dut.fd_exc_valid;
                fd_forced = 1'b0;
            end
        end
    end

    generate
        if (DISABLE_INTERLOCK != 0) begin : g_mutate
            // 互锁变异：新增的 FP load-use 停拍项恒 0（前递仍在，但未就绪就派发 ⇒ 旧值）
            initial begin
                @(posedge aresetn);
                force u_dut.fp_load_use_stall = 1'b0;
            end
        end
    endgenerate

    //==========================================================================
    // 5.6 协议级断言 C7/C8（**版本无关**：只读两端 RTL 都有的信号 + fpu 端口/类别）
    //--------------------------------------------------------------------------
    //   为什么需要它（而不是只比内存结果）：
    //     ①"FP load 的紧邻消费者"这一状态在本核当前取指口径下不可达（§六），
    //       所以端到端结果本身测不出互锁缺失；
    //     ②EMU_FETCH_BUFFER=1 的注入会让同一条消费者指令**被重复执行**一次
    //       （强填 F/D 槽后取指单元稍后仍会再交一次），第二次执行时数据已就绪 ⇒
    //       端到端结果被"自动修正"，同样测不出。故必须做**逐拍协议断言**：
    //       在"消费者在 E、生产者在 M 且未就绪"的每一拍，检查消费者这一拍真正
    //       采样到的值是否就是被 load 的那个值 —— 未互锁时它必然是旧值。
    //   C7（FPU 采样）：该拍若派发 FPU（e_fp_go），则被消费的端口（按 fpu 内部类别
    //       选通：a/b/c）必须等于 load 期望值（按 VA/尺寸从存储体取，flw 按 NaN-box）。
    //   C8（FP store 存数）：E 槽是 FP store 且其存数寄存器命中在途 load 的 rd 时，
    //       若该拍发生 E→M 捕获（pipe_adv=1），下一拍检查 em_fp_store == load 期望值。
    //   ★ 两条断言在正常口径（无 load 在途）恒不触发 ⇒ 不是"把测试写松"，而是
    //     "把该洞必须满足的不变量写成判定"。
    //==========================================================================
    // load 期望值（从存储体按 M 槽访问的 VA / 尺寸重建）
    wire [31:0] haz_va = u_dut.em_rs1_val + u_dut.em_imm_val;
    wire        haz_va_ok = (haz_va >= RAM_BASE) &&
                            (haz_va < (RAM_BASE + 4*RAM_WORDS - 32'd8));
    wire [31:0] haz_lo = ram[(haz_va - RAM_BASE) >> 2];
    wire [31:0] haz_hi = ram[(haz_va - RAM_BASE + 32'd4) >> 2];
    wire [63:0] haz_exp = (u_dut.em_mem_size == 3'd3) ? {haz_hi, haz_lo}
                                                      : {32'hFFFF_FFFF, haz_lo};
    // 端口是否真被该 FP 指令消费（取 fpu.v 的类别译码；口径见上）
    wire tb_fpu_use_a = u_dut.u_fpu.op_addsub | u_dut.u_fpu.op_mul | u_dut.u_fpu.op_div |
                        u_dut.u_fpu.op_sqrt   | u_dut.u_fpu.op_cmp | u_dut.u_fpu.op_cvt;
    wire tb_fpu_use_b = u_dut.u_fpu.op_addsub | u_dut.u_fpu.op_mul | u_dut.u_fpu.op_div |
                        u_dut.u_fpu.op_fma;
    wire tb_fpu_use_c = u_dut.u_fpu.op_fma;
    wire haz_hit_a = tb_use_fs1 & (u_dut.de_rs1 == u_dut.em_fp_rd);
    wire haz_hit_b = tb_use_fs2 & (u_dut.de_rs2 == u_dut.em_fp_rd);
    wire haz_hit_c = tb_use_fs3 & (u_dut.de_rs3 == u_dut.em_fp_rd);

    integer vio_disp;          // C7 违规拍数
    integer vio_store;         // C8 违规拍数
    initial vio_disp  = 0;
    initial vio_store = 0;

    // C7：在途 load 未就绪 + 消费者在 E + 本拍派发 FPU ⇒ 采样值必须是 load 值
    wire haz_disp_stale = tb_hazard_live & u_dut.e_fp_go & haz_va_ok &
                          ((haz_hit_a & tb_fpu_use_a & (u_dut.u_fpu.a !== haz_exp)) |
                           (haz_hit_b & tb_fpu_use_b & (u_dut.u_fpu.b !== haz_exp)) |
                           (haz_hit_c & tb_fpu_use_c & (u_dut.u_fpu.c !== haz_exp)));

    // C8：在途 load + E 槽 FP store 存数命中 + 本拍发生 E→M 捕获 ⇒ 下一拍查 em_fp_store
    wire haz_store_adj = u_dut.de_valid & u_dut.em_valid &
                         (u_dut.em_mem_op == TB_MEM_FLOAD) &
                         (u_dut.de_mem_op == TB_MEM_FSTORE) &
                         (u_dut.de_rs2 == u_dut.em_fp_rd) &
                         ~u_dut.m_exc_any & haz_va_ok;
    wire        kill_young_tb = u_dut.kill_young;      // 只读（门控用）
    wire        haz_store_cap = haz_store_adj & u_dut.pipe_adv & ~kill_young_tb;
    reg         haz_store_cap_q;
    reg  [31:0] haz_store_pc_q;
    reg  [63:0] haz_exp_q;
    initial haz_store_cap_q = 1'b0;
    initial haz_store_pc_q  = 32'h0;
    initial haz_exp_q       = 64'h0;

    always @(posedge clk) begin
        if (!aresetn) begin
            vio_disp        <= 0;
            vio_store       <= 0;
            haz_store_cap_q <= 1'b0;
            haz_store_pc_q  <= 32'h0;
            haz_exp_q       <= 64'h0;
        end else begin
            if (haz_disp_stale) begin
                vio_disp <= vio_disp + 1;
                if (vio_disp < 4)
                    $display("[tb_fp_load_use] C7 违规：E pc=0x%08h 消费 f%0d，而 M 槽 load(pc=0x%08h) 未就绪却已派发 FPU（a=0x%016h b=0x%016h c=0x%016h，期望 0x%016h）",
                             u_dut.de_pc, u_dut.em_fp_rd, u_dut.em_pc,
                             u_dut.u_fpu.a, u_dut.u_fpu.b, u_dut.u_fpu.c, haz_exp);
            end
            // 捕获拍已登记且 M 槽仍是同一条 store ⇒ 检查捕获到的存数
            if (haz_store_cap_q && (u_dut.em_pc == haz_store_pc_q) &&
                (u_dut.em_fp_store !== haz_exp_q)) begin
                vio_store <= vio_store + 1;
                if (vio_store < 4)
                    $display("[tb_fp_load_use] C8 违规：M pc=0x%08h 的 FP store 存数=0x%016h，而紧邻 FP load(pc=0x%08h) 的结果应为 0x%016h",
                             u_dut.em_pc, u_dut.em_fp_store, haz_store_pc_q - 32'd4, haz_exp_q);
            end
            haz_store_cap_q <= haz_store_cap;
            haz_store_pc_q  <= u_dut.em_pc;
            haz_exp_q       <= haz_exp;
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

            ar_count         <= 32'd0;
            aw_count         <= 32'd0;
            r_beat_count     <= 32'd0;
            w_beat_count     <= 32'd0;
            unknown_rd_count <= 32'd0;
            unknown_wr_count <= 32'd0;
            bus_cycles       <= 32'd0;
            first_ar_seen    <= 1'b0;
            first_ar_addr    <= 32'h0;
        end else begin
            bus_cycles <= bus_cycles + 32'd1;

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
                    $display("[tb_fp_load_use] 首笔 AR: addr=0x%08h len=%0d size=%0d burst=%b cache=%b id=%0d",
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

            // ---- 写通道（B 被收下后才放开下一笔 AW，避免 wready 死锁）----
            if (aw_fire) begin
                aw_count  <= aw_count + 32'd1;
                aw_addr_q <= awaddr;
                aw_len_q  <= awlen;
                aw_id_q   <= awid;
                w_cnt_q   <= 5'd0;
                wr_pend   <= 1'b1;
                awready_r <= 1'b0;
            end

            if (w_fire) begin
                w_beat_count <= w_beat_count + 32'd1;
                do_write(aw_addr_q + {w_cnt_q, 2'b00}, wdata, wstrb);
                if (wlast) begin
                    wr_pend  <= 1'b0;
                    bvalid_r <= 1'b1;
                end else begin
                    w_cnt_q <= w_cnt_q + 5'd1;
                end
            end

            if (b_fire) begin
                bvalid_r  <= 1'b0;
                awready_r <= 1'b1;
            end
        end
    end

    //==========================================================================
    // 6. 判定
    //==========================================================================
    // 期望值表（地址 = DATA_BASE + 偏移；程序见 §四 反汇编）
    localparam [31:0] D3_LO = 32'h0000_0000, D3_HI = 32'h4008_0000;  // 3.0
    localparam [31:0] S3    = 32'h4040_0000;                          // 3.0f
    localparam [31:0] R6_LO = 32'h0000_0000, R6_HI = 32'h4018_0000;  // 6.0
    localparam [31:0] R6S   = 32'h40C0_0000;                          // 6.0f
    localparam [31:0] R12_LO= 32'h0000_0000, R12_HI= 32'h4028_0000;  // 12.0
    localparam [31:0] MAGIC = 32'h5A5A_A5A5;

    localparam [31:0] DOFF   = DATA_BASE - RAM_BASE;   // 数据区相对 RAM_BASE 的字节偏移

    integer mismatches;
    integer idx, jdx;
    reg [31:0] rd_data;

    task automatic chk32;
        input [31:0] off;         // 相对 RAM_BASE 的字节偏移
        input [31:0] exp;
        input [255:0] label;      // 定长字符串（左对齐打印）
        begin
            rd_data = ram[off >> 2];
            if (rd_data !== exp) begin
                mismatches = mismatches + 1;
                $display("[tb_fp_load_use] MISMATCH %0s @RAM+0x%03h: dut=0x%08h 期望=0x%08h",
                         label, off, rd_data, exp);
            end else begin
                $display("[tb_fp_load_use]   OK %0s @RAM+0x%03h = 0x%08h", label, off, rd_data);
            end
        end
    endtask

    function [8*32-1:0] lj;       // 32 字符定长串左对齐（打印用；iverilog 不支持 %-0s）
        input [8*32-1:0] s;
        integer k, n;
        reg [8*32-1:0] t;
        begin
            t = s; n = 0;
            for (k = 0; k < 32; k = k + 1) begin
                if (t[8*32-1 -: 8] != 8'h00) n = n + 1;
                t = t << 8;
            end
            lj = s << (8*(32 - n));
        end
    endfunction

    integer prog_nonzero;
    integer wait_cnt;
    reg     magic_seen;

    initial begin
        mismatches  = 0;
        magic_seen  = 1'b0;
        wait_cnt    = 0;

        // ---- 复位释放 ----
        @(posedge aresetn);
        @(posedge clk);

        // ---- C1 镜像自检 ----
        prog_nonzero = 0;
        for (idx = 0; idx < MAIN_LEN; idx = idx + 1) if (main_prog[idx] != 32'h0) prog_nonzero = prog_nonzero + 1;
        if (boot_prog[0] !== BOOT_W0 || main_prog[0] !== MAIN_W0 || prog_nonzero < 30) begin
            $display("[tb_fp_load_use] TB_FP_LOAD_USE: FAIL C1 程序映像异常（boot[0]=0x%08h main[0]=0x%08h 非零字=%0d）",
                     boot_prog[0], main_prog[0], prog_nonzero);
            $fatal(1, "FP_LOAD_USE PROG IMAGE");
        end
        $display("[tb_fp_load_use] C1 程序映像 OK：boot %0d 字 + main %0d 字（非零 %0d）",
                 BOOT_LEN, MAIN_LEN, prog_nonzero);

        // ---- C3 等完成标志（超时 ⇒ FAIL）----
        while (!magic_seen && wait_cnt < TIMEOUT_CYCLES) begin
            @(posedge clk);
            wait_cnt = wait_cnt + 1;
            if (ram[(DOFF + 32'd96) >> 2] === MAGIC) magic_seen = 1'b1;
            if (DIAG_NO_REQ_CYCLES > 0 && (wait_cnt % DIAG_NO_REQ_CYCLES) == 0) begin
                $display("[tb_fp_load_use] 进度: 拍=%0d 提交=%0d 首AR=%s0x%08h ar=%0d aw=%0d 场景拍=%0d 互锁拍=%0d",
                         wait_cnt, commit_count, first_ar_seen ? "" : "未见 ",
                         first_ar_addr, ar_count, aw_count, hazard_cycles, stall_cycles);
                $display("[tb_fp_load_use]   DIAG: fetch_pc=0x%08h pipe_adv=%b m_busy=%b load_use_stall=%b",
                         u_dut.u_fetch_unit.fetch_pc, u_dut.pipe_adv, u_dut.m_busy,
                         u_dut.load_use_stall);
            end
        end
        if (!magic_seen) begin
            $display("[tb_fp_load_use] TB_FP_LOAD_USE: FAIL C3 超时 %0d 拍未见完成标志（@RAM+0x%03h=0x%08h，期望 0x%08h）",
                     TIMEOUT_CYCLES, DOFF + 32'd96, ram[(DOFF + 32'd96) >> 2], MAGIC);
            $fatal(1, "FP_LOAD_USE TIMEOUT");
        end
        $display("[tb_fp_load_use] C3 完成标志 @RAM+0x%03h = 0x%08h（拍=%0d，提交=%0d）",
                 DOFF + 32'd96, ram[(DOFF + 32'd96) >> 2], wait_cnt, commit_count);

        // ---- C6 场景护栏（真在测这个洞）----
        //   正常口径（EMU_FETCH_BUFFER=0）：只作**诊断**打印 —— 本核取指与流水强耦合
        //     （停顿时不取指 + L1I 命中 1 拍 ⇒ 1 条/2 拍且 load 后必插气泡），该状态
        //     当前**不可达**（实测恒 0，见 §六）；把它当判据会让 TB 永远红。
        //   反证口径（EMU_FETCH_BUFFER=1）：必须 > 0，否则测试无效 ⇒ FAIL（fail-closed）。
        if (EMU_FETCH_BUFFER != 0 && hazard_cycles == 0) begin
            $display("[tb_fp_load_use] TB_FP_LOAD_USE: FAIL C6 取指缓冲仿真模式下仍未构造出紧邻消费场景 —— 测试无效");
            $fatal(1, "FP_LOAD_USE NO HAZARD SCENARIO");
        end
        $display("[tb_fp_load_use] C6 紧邻消费场景拍数=%0d（E 级 load-use 互锁断言 %0d 拍；取指缓冲仿真=%0d）",
                 hazard_cycles, stall_cycles, EMU_FETCH_BUFFER);

        // ---- C2 首笔取指地址 ----
        if (!first_ar_seen || first_ar_addr !== `RV32GC_RESET_PC) begin
            $display("[tb_fp_load_use] TB_FP_LOAD_USE: FAIL C2 首笔 AR 异常（seen=%b addr=0x%08h 期望=0x%08h）",
                     first_ar_seen, first_ar_addr, `RV32GC_RESET_PC);
            $fatal(1, "FP_LOAD_USE FIRST AR");
        end

        // ---- 让最后几笔写落地（流水已空：标志是最后一条 store）----
        for (jdx = 0; jdx < 20; jdx = jdx + 1) @(posedge clk);

        // ---- C4 结果逐字比对 ----
        $display("[tb_fp_load_use] ---- 结果比对（期望值与程序注释一一对应）----");
        chk32(DOFF + 32'd0,  D3_LO, lj("A0 数据初始化 D3.lo"));
        chk32(DOFF + 32'd4,  D3_HI, lj("A0 数据初始化 D3.hi"));
        chk32(DOFF + 32'd8,  S3,    lj("A0 数据初始化 S3"));
        chk32(DOFF + 32'd16, R6_LO, lj("A  fld->fadd.d  lo"));
        chk32(DOFF + 32'd20, R6_HI, lj("A  fld->fadd.d  hi"));
        chk32(DOFF + 32'd24, R6S,   lj("B  flw->fadd.s"));
        chk32(DOFF + 32'd32, R12_LO,lj("C  fld->fmadd.d lo"));
        chk32(DOFF + 32'd36, R12_HI,lj("C  fld->fmadd.d hi"));
        chk32(DOFF + 32'd48, D3_LO, lj("D1 fld->fsd     lo"));
        chk32(DOFF + 32'd52, D3_HI, lj("D1 fld->fsd     hi"));
        chk32(DOFF + 32'd56, S3,    lj("D2 flw->fsw"));
        chk32(DOFF + 32'd64, S3,    lj("E  flw->fmv.x.w"));
        chk32(DOFF + 32'd72, R6_LO, lj("F  fld->nop->fadd.d lo"));
        chk32(DOFF + 32'd76, R6_HI, lj("F  fld->nop->fadd.d hi"));

        // ---- C5 未登记地址访问 ----
        if (unknown_rd_count != 0 || unknown_wr_count != 0) begin
            mismatches = mismatches + 1;
            $display("[tb_fp_load_use] MISMATCH C5 未登记地址访问 rd=%0d wr=%0d",
                     unknown_rd_count, unknown_wr_count);
        end

        // ---- C7/C8 协议级断言（FP load-use 互锁的直接判据）----
        if ((vio_disp != 0) || (vio_store != 0)) begin
            $display("[tb_fp_load_use] TB_FP_LOAD_USE: FAIL C7/C8 协议违规：C7(未就绪派发 FPU)=%0d 次，C8(FP store 存旧值)=%0d 次",
                     vio_disp, vio_store);
            $fatal(1, "FP_LOAD_USE PROTOCOL");
        end

        if (mismatches != 0) begin
            $display("[tb_fp_load_use] TB_FP_LOAD_USE: FAIL C4 有 %0d 处结果不符（FP load-use 互锁缺失或前递错误）",
                     mismatches);
            $fatal(1, "FP_LOAD_USE MISMATCH");
        end

        $display("[tb_fp_load_use] C2 首笔取指地址=0x%08h（= RESET_PC）OK；C4 六组结果全部一致；C5 无未登记访问；C7/C8 协议断言无违规",
                 first_ar_addr);
        $display("[tb_fp_load_use] 统计：拍=%0d 提交=%0d AR=%0d AW=%0d 场景拍=%0d 互锁拍=%0d C7违规=%0d C8违规=%0d",
                 wait_cnt, commit_count, ar_count, aw_count, hazard_cycles, stall_cycles,
                 vio_disp, vio_store);
        $display("TB_FP_LOAD_USE: PASS");
        $finish;
    end

endmodule
