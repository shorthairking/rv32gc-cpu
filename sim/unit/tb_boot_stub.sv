//==============================================================================
// sim/unit/tb_boot_stub.sv —— 引导桩（SPI XIP → DDR3 拷贝 → 跳 OpenSBI）core_top 级 TB
//==============================================================================
// 项目  : rv32gc-cpu（阶段三 B-3.5 引导链）
// 顶层名: tb_boot_stub（scripts/regress.sh 自动发现 sim/unit/tb_*.sv 后用 -s 指定）
// 依据  : docs/porting/01-overview.md §2.2（复位取指 0x1C00_0000、纯 PC 相对、不开 MMU）、
//         §2.3（DDR 布局：OpenSBI 0x0100_0000 / U-Boot 0x0200_0000 / DTB 0x0300_0000）、
//         §2.4（入口寄存器：a0=hartid、a1=DTB 地址、a2=平台私有）、
//         AGENT.md §0.6（未捕获即失败）、§3.2（变异测试/反证纪律）
// 桩源码: sw/boot/boot_stub.S（**真源**；本 TB 不重写桩，只用生成的镜像字表）
// 字表  : sim/unit/prog/boot_stub_words.svh（`include；由
//         `sw/boot/check_stub_layout.sh --update-sim-words` 从**汇编后的桩 ELF 符号表**
//         生成 ⇒ 改桩源码 ⇒ 重跑生成器 ⇒ 本 TB 立刻跟着变）
// 占位  : sim/unit/prog/boot_stub_probe.S（"迷你 OpenSBI"：把入口寄存器写进 DDR 邮箱后停机）
//
//------------------------------------------------------------------------------
// 一、这个 TB 测什么（一条链，五个环节，全部 fail-closed）
//------------------------------------------------------------------------------
//   ① XIP 取指启动：复位后首笔 AXI 读地址 == RESET_PC（0x1C00_0000），桩就地执行；
//   ② 桩按**段表**把三段 payload 从 Flash 拷到 DDR3（本 TB 用仿真小段长：
//      OpenSBI 4 KiB / U-Boot 8 KiB / DTB 1 KiB，偏移与目的地址与真实镜像完全一致）；
//   ③ **逐字节**判定 DDR 内三段 payload == 期望（占位程序字 + 地址相关模式字节），
//      且各段**每个字恰好被写一次**（多写/少写/写错地址都判红）；
//   ④ 跳转与入口寄存器：桩跳 0x0100_0000（= 拷贝过去的占位程序）并置 a0/a1/a2；
//      占位程序**能跑起来**把 {a0,a1,a2,magic,sig} 写进 DDR 邮箱 ⇒ TB 读邮箱判定；
//   ⑤ 无越界：AXI 上不得出现未建模 DDR 窗口之外的地址事务（异常/跑飞都会落在这里）；
//      Flash 读地址必须落在"桩自身代码区 ∪ 三段 payload 源区间"内（源偏移写错即红）。
//
//------------------------------------------------------------------------------
// 二、结构（自包含：不依赖 sim/tb/*、不依赖外部 hex/脚本/cwd；只有一处 `include）
//------------------------------------------------------------------------------
//   tb_boot_stub
//     ├── u_dut : rtl/top/core_top.v（48 端口逐字契约；rtl 只读）
//     └── 本文件内置 AXI4 从设备 + 存储模型：
//           · flash[0:262143]  XIP 主窗口 0x1C00_0000（1 MiB，RTL 口径 = 主窗口地址空间）
//                              + 别名窗口 0x1FE8_0000（同一片存储体，桩当前走主窗口读）
//           · DDR 只建模 4 个窗口（其余地址一律计为"未建模访问"⇒ 判红）：
//               0x0100_0000 +64 KiB  OpenSBI 段（含占位程序）
//               0x0200_0000 +64 KiB  U-Boot 段
//               0x0300_0000 +64 KiB  DTB 段
//               0x0080_0000 +64 B    占位程序邮箱
//             ——只建模"期望被写"的窗口，任何其它 DDR 访问都说明桩跑偏了。
//
//------------------------------------------------------------------------------
// 三、判据（C0..C9；任一不满足 ⇒ 打印含 FAIL 的行 + $fatal，rc≠0）
//------------------------------------------------------------------------------
//   C0  镜像自检 + **布局交叉核对**：桩 .equ 常量（字表）与本 TB 独立布局逐项一致、
//       桩字写入 Flash 后逐字和相等（不符只记 FAIL 不中止 ⇒ 一次运行给出全部证据）
//   C1  复位后首笔 AR 地址 == RESET_PC（XIP 取指启动）
//   C2  TIMEOUT_CYCLES 内见到邮箱 MAGIC（否则判超时 FAIL，并打印现场）
//   C3  入口寄存器：a0 == hartid(0)、a1 == DTB 目的地址、a2 == 0
//   C4  DDR 三段 payload **逐字节** == 期望（占位/模式）；打印首个不符字节的三要素
//   C5  各段写入字数 == 段长/4（恰好一次）；邮箱写入字数 == EXP_MBOX_WORDS（占位程序只跑一遍）
//   C6  总线交叉核对：W 拍数 == 三段总字数 + 邮箱字数（当前基线 DDR 写走 MDTA 单 beat、旁路 L1D，
//      core_top.v §13）；写事务地址必须落在期望窗口内
//   C7  Flash 读分类：无"未登记 Flash 读"；三段源区间各至少被读过一次（覆盖性）
//   C8  未建模 DDR 访问 == 0（读/写分开计数；异常落 0x0 / 跑飞到别处都会在这里现形）
//   C9  占位程序签名（PROBE_SIG）与 MAGIC 都到位 ⇒ 拷贝→跳转→执行整条链闭合
//   ★ 唯一成功行 = TB_BOOT_STUB: PASS（整行，恰好一次）；失败路径只打印含 FAIL 的行
//
//------------------------------------------------------------------------------
// 四、反证开关（默认 0 = 正常回归口径；开开关后**必须** FAIL）
//------------------------------------------------------------------------------
//   MUT_FLASH_SHIFT=1 : TB 把三段 payload 在 Flash 里的**实际落点整体后移 4 字节**
//                       （只改 TB 侧的 Flash 内容，不改桩）⇒ 桩按声明的源偏移读到的
//                       内容整体错位 ⇒ C4/C7 必红。用来证明"逐字节判定确实在判定"。
//   两种开关方式等价（任一为 1 即生效）：
//     ① vvp 运行期 plusarg ： vvp <vvp> +MUT_FLASH_SHIFT=1
//     ② iverilog 编译期参数： iverilog … -P tb_boot_stub.MUT_FLASH_SHIFT=1 …
//   复现命令（从仓库根；$R = rtl 源集合，见 scripts/regress.sh）：
//     R="$(find rtl -name '*.v' | sort)"
//     iverilog -g2012 -I rtl/pkg -I . -s tb_boot_stub -o /tmp/stub.vvp $R sim/unit/tb_boot_stub.sv
//     vvp /tmp/stub.vvp                       # 正常 ⇒ 唯一成功行
//     vvp /tmp/stub.vvp +MUT_FLASH_SHIFT=1    # 反证①（Flash 内容错位）⇒ 必红
//   反证②（源码级）：临时把 sw/boot/boot_stub.S 的 BOOT_SRC_OPENSBI 改错一个常量
//     ⇒ sw/boot/check_stub_layout.sh --update-sim-words 刷新字表 ⇒ 本 TB 必红
//     （步骤与实测输出见交付说明与 sw/boot/README.md §反证）。
//
//------------------------------------------------------------------------------
// 五、风格/红线
//------------------------------------------------------------------------------
//   · TESTBENCH（不可综合）：AXI 从设备/存储模型/开关用 always + force 是必需；
//   · 无 FPGA 原语、无 Vivado IP 依赖 ⇒ iverilog 回归自洽（AGENT.md §4 红线 1/2）；
//   · 本文件的 AXI 逻辑是**从设备行为模型（验证件）**，不是设计侧代码。
//==============================================================================
`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"

module tb_boot_stub #(
    // ---- 时钟/复位 ----
    parameter integer CLK_HALF_NS   = 5,
    parameter integer RESET_CYCLES  = 20,
    // ---- 判定参数 ----
    //   预算：三段共 (4 KiB+8 KiB+1 KiB)/4 = 3328 字；**实测正常路径 ≈19.7 万拍**
    //   （本机 iverilog ≈5–10 k 拍/秒 ⇒ ≈20–40 s）⇒ 取 40 万拍（**2× 余量**）：
    //   正常/异常都能在 regress 的 300 s 墙钟兜底内给出结论（超时路径 ≈40–80 s）。
    parameter integer TIMEOUT_CYCLES = 400000,
    parameter integer DIAG_PERIOD    = 50000,
    // ---- 存储模型容量 ----
    parameter integer FLASH_WORDS    = 262144,   // XIP 主窗口 1 MiB
    parameter integer REGION_WORDS   = 16384,    // 每个 DDR 段窗口 64 KiB
    parameter integer MBOX_WORDS     = 16,       // 邮箱窗口（占位程序用 5 个字）
    // ---- 反证开关（§四；默认 0 = 正常回归口径）----
    parameter integer MUT_FLASH_SHIFT = 0
) ();

    //==========================================================================
    // 0. 期望常量（与字表独立：字表说"桩声明的布局"，这里说"TB 期望的仿真构型"）
    //    两侧不一致 ⇒ C0 判红（防"生成器用了别的段长、TB 却照跑"的静默错配）
    //==========================================================================
    localparam integer EXP_LEN_OPENSBI = 4096;   // = check_stub_layout.sh 的 --sim-lens 默认值
    localparam integer EXP_LEN_UBOOT   = 8192;
    localparam integer EXP_LEN_DTB     = 1024;
    localparam [31:0]  RESP_OKAY       = `RV32GC_AXI_RESP_OKAY;
    localparam [31:0]  DDR_MBOX        = 32'h0080_0000;   // 与占位程序 PROBE_MBOX 独立声明
    //   占位程序的 sw 条数（= 邮箱窗口的期望写入字数）与其字数：改
    //   sim/unit/prog/boot_stub_probe.S 后必须同步改这两个值（C0 会核对字数 ⇒ 不漏改）
    localparam integer EXP_MBOX_WORDS  = 5;
    localparam integer EXP_PROBE_WORDS = 11;
    //--------------------------------------------------------------------------
    // ★ TB 侧**独立布局**（= sw/boot/build_spi_image.sh 的 LAYOUT_*，故意**不**读桩 .equ）
    //   为什么必须独立：如果 TB 按"桩自己声明的偏移"去摆 Flash 内容，那么"桩把源偏移
    //   写错了"这件事会**自我一致**地通过（桩从错的偏移读、TB 把内容摆在错的位置）——
    //   判据就变成了空转。因此本 TB 自己持有一份布局真值：
    //     · Flash 内容按 TB_SRC_* 摆；
    //     · DDR 期望按 TB_DST_*/TB_LEN_* 判；
    //     · Flash 读地址分类也按 TB_SRC_* 划界；
    //   桩汇编出来的布局（`include 的 BOOT_SIM_*）只在 C0 与之**交叉核对**：任何漂移
    //   都会同时（a）C0 报不符，（b）拷贝内容逐字节不符，（c）Flash 读落在界外。
    //   实测：把桩 BOOT_SRC_UBOOT 改成 0x080100 后，本 TB 三层判据同时判红。
    //--------------------------------------------------------------------------
    localparam integer TB_SRC_OPENSBI = 32'h004000;
    localparam integer TB_SRC_UBOOT   = 32'h080000;
    localparam integer TB_SRC_DTB     = 32'h0E8000;
    localparam [31:0]  TB_DST_OPENSBI = 32'h0100_0000;
    localparam [31:0]  TB_DST_UBOOT   = 32'h0200_0000;
    localparam [31:0]  TB_DST_DTB     = 32'h0300_0000;
    localparam [31:0]  TB_NEXT_ENTRY  = 32'h0100_0000;
    localparam [31:0]  TB_FDT_DST     = 32'h0300_0000;
    localparam integer TB_HARTID      = 0;
    localparam integer TB_SEG_COUNT   = 3;

    //==========================================================================
    // 1. 存储模型 + 字表（`include 的 task 需要 flash[] 先声明）
    //==========================================================================
    reg [31:0] flash [0:FLASH_WORDS-1];

    `include "sim/unit/prog/boot_stub_words.svh"

    // ---- DDR 窗口 ----
    localparam [31:0] REG_OSB_BASE = TB_DST_OPENSBI;
    localparam [31:0] REG_UB_BASE  = TB_DST_UBOOT;
    localparam [31:0] REG_DTB_BASE = TB_DST_DTB;
    localparam [31:0] REG_MB_BASE  = DDR_MBOX;

    reg [31:0] ddr_osb [0:REGION_WORDS-1];
    reg [31:0] ddr_ub  [0:REGION_WORDS-1];
    reg [31:0] ddr_dtb [0:REGION_WORDS-1];
    reg [31:0] ddr_mb  [0:MBOX_WORDS-1];

    //==========================================================================
    // 2. 地址译码（Flash 主窗口/别名窗口 + 四个 DDR 窗口；其余=未建模 ⇒ 判红）
    //==========================================================================
    function is_flash_main; input [31:0] a;
        begin is_flash_main = (a >= BOOT_SIM_FLASH_BASE) &&
                              (a <  BOOT_SIM_FLASH_BASE + 4*FLASH_WORDS); end endfunction
    function is_flash_alias; input [31:0] a;
        begin is_flash_alias = (a[31:16] == `RV32GC_SPI_HIT_VAL); end endfunction
    function is_flash; input [31:0] a;
        begin is_flash = is_flash_main(a) || is_flash_alias(a); end endfunction
    //   DDR 窗口编号：0 = OpenSBI 段、1 = U-Boot 段、2 = DTB 段、3 = 邮箱、-1 = 未建模
    function integer ddr_region; input [31:0] a;
        begin
            if ((a >= REG_OSB_BASE) && (a < REG_OSB_BASE + 4*REGION_WORDS))      ddr_region = 0;
            else if ((a >= REG_UB_BASE) && (a < REG_UB_BASE + 4*REGION_WORDS))   ddr_region = 1;
            else if ((a >= REG_DTB_BASE) && (a < REG_DTB_BASE + 4*REGION_WORDS)) ddr_region = 2;
            else if ((a >= REG_MB_BASE) && (a < REG_MB_BASE + 4*MBOX_WORDS))     ddr_region = 3;
            else                                                                 ddr_region = -1;
        end
    endfunction
    function [31:0] ddr_index; input [31:0] a;
        begin
            case (ddr_region(a))
                0: ddr_index = (a - REG_OSB_BASE) >> 2;
                1: ddr_index = (a - REG_UB_BASE)  >> 2;
                2: ddr_index = (a - REG_DTB_BASE) >> 2;
                3: ddr_index = (a - REG_MB_BASE)  >> 2;
                default: ddr_index = 32'h0;
            endcase
        end
    endfunction

    // 总线读：未写过的字节按 0 返回（x 传播会让取指"看似有指令"；判定侧用 raw 版本）
    function [31:0] mem_read; input [31:0] a;
        reg [31:0] w;
        begin
            if (is_flash_main(a)) begin
                w = flash[(a - BOOT_SIM_FLASH_BASE) >> 2];
            end else if (is_flash_alias(a)) begin
                w = flash[((a & 32'h0000_FFFC) >> 2) % FLASH_WORDS];
            end else begin
                case (ddr_region(a))
                    0: w = ddr_osb[ddr_index(a)];
                    1: w = ddr_ub [ddr_index(a)];
                    2: w = ddr_dtb[ddr_index(a)];
                    3: w = ddr_mb [ddr_index(a)];
                    default: w = 32'h0;      // 未建模：读回 0 并计入违规（C8）
                endcase
            end
            mem_read = { (^w[31:24] === 1'bx) ? 8'h00 : w[31:24],
                         (^w[23:16] === 1'bx) ? 8'h00 : w[23:16],
                         (^w[15: 8] === 1'bx) ? 8'h00 : w[15: 8],
                         (^w[ 7: 0] === 1'bx) ? 8'h00 : w[ 7: 0] };
        end
    endfunction

    // DDR raw 字节取（判定用；未写过的位保持 x ⇒ `!==` 必然不符）
    function [7:0] ddr_byte;
        input integer region; input integer b;
        reg [31:0] w;
        begin
            case (region)
                0: w = ddr_osb[b >> 2];
                1: w = ddr_ub [b >> 2];
                2: w = ddr_dtb[b >> 2];
                3: w = ddr_mb [b >> 2];
                default: w = 32'h0;
            endcase
            ddr_byte = w[8*(b & 3) +: 8];
        end
    endfunction

    //==========================================================================
    // 3. 期望值：占位程序字 + 地址相关模式（逐字节；错位/错段/漏拷都会现形）
    //==========================================================================
    function [7:0] pat_byte;                 // 段内字节偏移 → 伪随机但确定
        input [31:0] off;
        reg [31:0] h;
        begin
            h = off * 32'h9E37_79B1 + 32'hA5A5_A5A5;
            pat_byte = h[15:8] ^ h[23:16] ^ {4'b0, off[3:0]};
        end
    endfunction
    function [31:0] pat_word; input [31:0] off;
        begin pat_word = { pat_byte(off+3), pat_byte(off+2), pat_byte(off+1), pat_byte(off) }; end
    endfunction
    function [7:0] probe_byte;               // 占位程序第 i 个字节
        input integer i;
        reg [31:0] w;
        begin
            w = boot_sim_probe_word(i/4);
            probe_byte = w[8*(i%4) +: 8];
        end
    endfunction
    localparam integer LEN_OSB = EXP_LEN_OPENSBI;   // ★ 判据用 TB 侧长度（见上）
    localparam integer LEN_UB  = EXP_LEN_UBOOT;
    localparam integer LEN_DTB = EXP_LEN_DTB;

    function [7:0] exp_byte;                 // 段内字节偏移 → 期望字节
        input integer seg; input integer i;
        begin
            if ((seg == 0) && (i < BOOT_SIM_PROBE_WORDS*4)) exp_byte = probe_byte(i);
            else case (seg)
                0: exp_byte = pat_byte(TB_SRC_OPENSBI + i);
                1: exp_byte = pat_byte(TB_SRC_UBOOT   + i);
                2: exp_byte = pat_byte(TB_SRC_DTB     + i);
                default: exp_byte = 8'h00;
            endcase
        end
    endfunction
    function [31:0] exp_word; input integer seg; input integer widx;
        begin
            exp_word = { exp_byte(seg, 4*widx+3), exp_byte(seg, 4*widx+2),
                         exp_byte(seg, 4*widx+1), exp_byte(seg, 4*widx) };
        end
    endfunction

    //==========================================================================
    // 4. 时钟 / 复位 / AXI 连线
    //==========================================================================
    reg clk;
    reg aresetn;
    initial clk = 1'b0;
    always #(CLK_HALF_NS) clk = ~clk;

    integer rst_cnt;
    initial begin
        aresetn = 1'b0;
        for (rst_cnt = 0; rst_cnt < RESET_CYCLES; rst_cnt = rst_cnt + 1) @(posedge clk);
        @(negedge clk);
        aresetn = 1'b1;
    end

    wire [3:0]  arid, arlen, awid, awlen, rid, wid, bid;
    wire [31:0] araddr, awaddr, rdata, wdata;
    wire [2:0]  arsize, arprot, awsize, awprot;
    wire [1:0]  arburst, arlock, awburst, awlock, rresp, bresp;
    wire [3:0]  arcache, awcache, wstrb;
    wire        arvalid, arready, rvalid, rready, rlast;
    wire        awvalid, awready, wvalid, wready, wlast, bvalid, bready;
    wire        ws_valid;
    wire [31:0] rf_rdata, debug0_wb_pc, debug0_wb_rf_wdata;
    wire [3:0]  debug0_wb_rf_wen;
    wire [4:0]  debug0_wb_rf_wnum;

    //==========================================================================
    // 5. DUT：rtl/top/core_top.v（48 端口逐字契约）
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
    // 6. 可观测计数
    //==========================================================================
    reg [31:0] ar_count, aw_count, r_beat_count, w_beat_count;
    reg [31:0] flash_ar_code, flash_ar_data, flash_ar_bad;
    reg [31:0] flash_rd_seg [0:2];              // 三段源区间各命中多少次读
    reg [31:0] ddr_wr_words [0:3];              // 各窗口写入字数
    reg [31:0] unmodeled_rd, unmodeled_wr;
    reg [31:0] first_unmodeled_addr;
    reg        first_ar_seen;
    reg [31:0] first_ar_addr;
    integer    commit_count;
    reg [31:0] mut_shift;                        // 反证：Flash 实际落点偏移量

    // Flash 读地址分类（C7）
    function integer flash_ar_class;             // 0 = 桩代码区、1..3 = 某段源区间、-1 = 未登记
        input [31:0] a;
        reg [31:0] off;
        begin
            off = a - BOOT_SIM_FLASH_BASE;
            if (off < 4*BOOT_SIM_STUB_WORDS)                          flash_ar_class = 0;
            else if ((off >= TB_SRC_OPENSBI) &&
                     (off <  TB_SRC_OPENSBI + LEN_OSB))               flash_ar_class = 1;
            else if ((off >= TB_SRC_UBOOT) &&
                     (off <  TB_SRC_UBOOT + LEN_UB))                  flash_ar_class = 2;
            else if ((off >= TB_SRC_DTB) &&
                     (off <  TB_SRC_DTB + LEN_DTB))                   flash_ar_class = 3;
            else                                                      flash_ar_class = -1;
        end
    endfunction

    //==========================================================================
    // 7. AXI4 从设备（单笔在途；AR→R 逐拍 INCR 多 beat；AW/W→B；读延迟 1 拍）
    //==========================================================================
    reg        arready_r, rd_active, rd_pend;
    reg [31:0] rd_addr_q;
    reg [3:0]  rd_len_q, rd_id_q;
    reg [4:0]  rd_cnt_q;

    reg        awready_r, wr_pend, bvalid_r;
    reg [31:0] aw_addr_q;
    reg [3:0]  aw_len_q, aw_id_q;
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

    integer i, j;
    task automatic do_write;
        input [31:0] a;
        input [31:0] d;
        input [3:0]  strb;
        integer reg_id;
        begin
            reg_id = ddr_region(a);
            if (reg_id < 0) begin
                unmodeled_wr = unmodeled_wr + 1;
                if (unmodeled_wr == 1) first_unmodeled_addr = a;
                if (unmodeled_wr < 8)   // 打印限流（计数全量）
                    $display("[tb_boot_stub] 违规：未建模 DDR 写 addr=0x%08h data=0x%08h", a, d);
            end else if (is_flash(a)) begin
                $display("[tb_boot_stub] 警告：对 Flash/XIP 窗口的写被忽略 addr=0x%08h", a);
            end else begin
                ddr_wr_words[reg_id] = ddr_wr_words[reg_id] + 1;
                case (reg_id)
                    0: begin
                        if (strb[0]) ddr_osb[ddr_index(a)][ 7: 0] = d[ 7: 0];
                        if (strb[1]) ddr_osb[ddr_index(a)][15: 8] = d[15: 8];
                        if (strb[2]) ddr_osb[ddr_index(a)][23:16] = d[23:16];
                        if (strb[3]) ddr_osb[ddr_index(a)][31:24] = d[31:24];
                    end
                    1: begin
                        if (strb[0]) ddr_ub[ddr_index(a)][ 7: 0] = d[ 7: 0];
                        if (strb[1]) ddr_ub[ddr_index(a)][15: 8] = d[15: 8];
                        if (strb[2]) ddr_ub[ddr_index(a)][23:16] = d[23:16];
                        if (strb[3]) ddr_ub[ddr_index(a)][31:24] = d[31:24];
                    end
                    2: begin
                        if (strb[0]) ddr_dtb[ddr_index(a)][ 7: 0] = d[ 7: 0];
                        if (strb[1]) ddr_dtb[ddr_index(a)][15: 8] = d[15: 8];
                        if (strb[2]) ddr_dtb[ddr_index(a)][23:16] = d[23:16];
                        if (strb[3]) ddr_dtb[ddr_index(a)][31:24] = d[31:24];
                    end
                    3: begin
                        if (strb[0]) ddr_mb[ddr_index(a)][ 7: 0] = d[ 7: 0];
                        if (strb[1]) ddr_mb[ddr_index(a)][15: 8] = d[15: 8];
                        if (strb[2]) ddr_mb[ddr_index(a)][23:16] = d[23:16];
                        if (strb[3]) ddr_mb[ddr_index(a)][31:24] = d[31:24];
                    end
                    default: ;
                endcase
            end
        end
    endtask

    initial begin
        for (i = 0; i < FLASH_WORDS; i = i + 1) flash[i] = 32'h0;
        for (i = 0; i < REGION_WORDS; i = i + 1) begin
            ddr_osb[i] = 32'h0; ddr_ub[i] = 32'h0; ddr_dtb[i] = 32'h0;
        end
        for (i = 0; i < MBOX_WORDS; i = i + 1) ddr_mb[i] = 32'h0;
    end

    always @(posedge clk) if (aresetn && ws_valid) commit_count = commit_count + 1;

    always @(posedge clk or negedge aresetn) begin
        if (!aresetn) begin
            arready_r <= 1'b1;  rd_active <= 1'b0;  rd_pend <= 1'b0;
            rd_addr_q <= 32'h0; rd_len_q  <= 4'h0;  rd_id_q <= 4'h0; rd_cnt_q <= 5'h0;
            awready_r <= 1'b1;  wr_pend   <= 1'b0;  bvalid_r <= 1'b0;
            aw_addr_q <= 32'h0; aw_len_q  <= 4'h0;  aw_id_q <= 4'h0; w_cnt_q <= 5'h0;
            ar_count <= 0; aw_count <= 0; r_beat_count <= 0; w_beat_count <= 0;
            flash_ar_code <= 0; flash_ar_data <= 0; flash_ar_bad <= 0;
            flash_rd_seg[0] <= 0; flash_rd_seg[1] <= 0; flash_rd_seg[2] <= 0;
            ddr_wr_words[0] <= 0; ddr_wr_words[1] <= 0;
            ddr_wr_words[2] <= 0; ddr_wr_words[3] <= 0;
            unmodeled_rd <= 0; unmodeled_wr <= 0; first_unmodeled_addr <= 32'h0;
            first_ar_seen <= 1'b0; first_ar_addr <= 32'h0;
            commit_count <= 0;
        end else begin
            // ---- 读通道 ----
            if (ar_fire) begin
                ar_count <= ar_count + 32'd1;
                rd_addr_q <= araddr;  rd_len_q <= arlen;  rd_id_q <= arid;  rd_cnt_q <= 5'd0;
                arready_r <= 1'b0;
                rd_pend   <= 1'b1;
                if (!first_ar_seen) begin
                    first_ar_seen <= 1'b1;
                    first_ar_addr <= araddr;
                    $display("[tb_boot_stub] 首笔 AR: addr=0x%08h len=%0d burst=%b cache=%b",
                             araddr, arlen, arburst, arcache);
                end
                if (is_flash(araddr)) begin
                    case (flash_ar_class(araddr))
                        0: flash_ar_code <= flash_ar_code + 32'd1;
                        1: begin flash_ar_data <= flash_ar_data + 32'd1; flash_rd_seg[0] <= flash_rd_seg[0] + 32'd1; end
                        2: begin flash_ar_data <= flash_ar_data + 32'd1; flash_rd_seg[1] <= flash_rd_seg[1] + 32'd1; end
                        3: begin flash_ar_data <= flash_ar_data + 32'd1; flash_rd_seg[2] <= flash_rd_seg[2] + 32'd1; end
                        default: begin
                            flash_ar_bad <= flash_ar_bad + 32'd1;
                            //   ★ 打印限流（前 8 笔）：跑飞/变异时可能是"每拍一笔"的打印风暴，
                            //     既拖慢仿真又刷屏；计数照旧全量累计 ⇒ 判据不受影响。
                            if (flash_ar_bad < 8)
                                $display("[tb_boot_stub] 违规：未登记 Flash 读 addr=0x%08h（既不在桩代码区也不在三段源区间）", araddr);
                        end
                    endcase
                end else if (ddr_region(araddr) < 0) begin
                    unmodeled_rd <= unmodeled_rd + 32'd1;
                    if ((unmodeled_rd == 1) && (unmodeled_wr == 0)) first_unmodeled_addr <= araddr;
                    if (unmodeled_rd < 8)   // 同上：打印限流，计数全量
                        $display("[tb_boot_stub] 违规：未建模 DDR 读 addr=0x%08h", araddr);
                end
            end else if (rd_pend) begin
                rd_pend   <= 1'b0;
                rd_active <= 1'b1;
            end else if (r_fire) begin
                r_beat_count <= r_beat_count + 32'd1;
                if (rd_cnt_q[3:0] == rd_len_q) begin
                    rd_active <= 1'b0;
                    arready_r <= 1'b1;
                end else begin
                    rd_cnt_q  <= rd_cnt_q + 5'd1;
                    rd_addr_q <= rd_addr_q + 32'd4;
                end
            end

            // ---- 写通道 ----
            if (aw_fire) begin
                aw_count  <= aw_count + 32'd1;
                aw_addr_q <= awaddr;  aw_len_q <= awlen;  aw_id_q <= awid;
                w_cnt_q   <= 5'd0;    wr_pend  <= 1'b1;   awready_r <= 1'b0;
                if (!is_flash(awaddr) && (ddr_region(awaddr) < 0) && (aw_count < 8)) begin
                    // 写地址不落在任何期望窗口：逐 beat 计数在 do_write 里（那里也有打印限流）
                    $display("[tb_boot_stub] 违规：未建模 DDR 写事务首地址 addr=0x%08h", awaddr);
                end
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
    // 8. 反证开关生效值
    //==========================================================================
    integer pa_shift;
    initial begin
        mut_shift = (MUT_FLASH_SHIFT != 0) ? 32'd4 : 32'd0;
        if ($value$plusargs("MUT_FLASH_SHIFT=%d", pa_shift)) mut_shift = (pa_shift != 0) ? 32'd4 : 32'd0;
    end

    //==========================================================================
    // 9. 辅助
    //==========================================================================
    function [8*32-1:0] lj;                 // 定长串左对齐（打印用；iverilog 无 %-0s）
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

    integer fails;
    task automatic chk32;
        input [31:0] got;
        input [31:0] exp;
        input [8*32-1:0] label;
        begin
            if (got !== exp) begin
                fails = fails + 1;
                $display("[tb_boot_stub] mismatch %0s: got=0x%08h exp=0x%08h => FAIL", label, got, exp);
            end else begin
                $display("[tb_boot_stub]   OK %0s = 0x%08h", label, got);
            end
        end
    endtask

    task automatic chkint;
        input integer got;
        input integer exp;
        input [8*32-1:0] label;
        begin
            if (got !== exp) begin
                fails = fails + 1;
                $display("[tb_boot_stub] mismatch %0s: got=%0d exp=%0d => FAIL", label, got, exp);
            end else begin
                $display("[tb_boot_stub]   OK %0s = %0d", label, got);
            end
        end
    endtask

    // 逐字节比对一段 payload（seg: 0/1/2；期望 = 占位程序字 + 模式字节）
    task automatic chk_payload_bytes;
        input integer seg;
        input integer len;
        input [8*32-1:0] label;
        integer b, bad, first_bad;
        begin
            bad = 0; first_bad = -1;
            for (b = 0; b < len; b = b + 1) begin
                if (ddr_byte(seg, b) !== exp_byte(seg, b)) begin
                    bad = bad + 1;
                    if (first_bad < 0) first_bad = b;
                end
            end
            if (bad == 0) begin
                $display("[tb_boot_stub]   OK %0s 逐字节一致（%0d B，0 不符）", label, len);
            end else begin
                fails = fails + 1;
                $display("[tb_boot_stub] mismatch %0s：%0d/%0d 字节不符；首个不符 @段内+0x%0h（实得 0x%02h 期望 0x%02h）=> FAIL",
                         label, bad, len, first_bad, ddr_byte(seg, first_bad), exp_byte(seg, first_bad));
            end
        end
    endtask

    //==========================================================================
    // 10. 主流程
    //==========================================================================
    integer prog_nonzero, wait_cnt;
    reg     magic_seen, timed_out;
    reg [31:0] mb_a0, mb_a1, mb_a2, mb_magic, mb_sig;
    reg [31:0] stub_sum_chk;

    initial begin
        fails      = 0;
        magic_seen = 1'b0;
        timed_out  = 1'b0;
        wait_cnt   = 0;

        $display("========================================================================");
        $display("[tb_boot_stub] 开始：仿真段长 OpenSBI=%0d B U-Boot=%0d B DTB=%0d B（占位程序 %0d 字）",
                 LEN_OSB, LEN_UB, LEN_DTB, BOOT_SIM_PROBE_WORDS);

        //----------------------------------------------------------------------
        // C0：字表/镜像自检（防"空/错字表"与"生成器用了别的段长"的静默错配）
        //----------------------------------------------------------------------
        //   交叉核对（软失败：记录不符后**继续**跑内容判据 —— 这样一次运行能同时给出
        //   "常量漂移"与"拷贝内容/Flash 读地址"两层证据）
        if (BOOT_SIM_SEG_COUNT !== TB_SEG_COUNT) begin
            fails = fails + 1;
            $display("[tb_boot_stub] C0 段数不符：桩 .equ=%0d，本 TB 期望 %0d => FAIL", BOOT_SIM_SEG_COUNT, TB_SEG_COUNT);
        end
        if (BOOT_SIM_SRC_OPENSBI !== TB_SRC_OPENSBI) begin
            fails = fails + 1; $display("[tb_boot_stub] C0 桩 BOOT_SRC_OPENSBI=0x%05h ≠ TB 期望 0x%05h => FAIL", BOOT_SIM_SRC_OPENSBI, TB_SRC_OPENSBI);
        end
        if (BOOT_SIM_SRC_UBOOT !== TB_SRC_UBOOT) begin
            fails = fails + 1; $display("[tb_boot_stub] C0 桩 BOOT_SRC_UBOOT=0x%05h ≠ TB 期望 0x%05h => FAIL", BOOT_SIM_SRC_UBOOT, TB_SRC_UBOOT);
        end
        if (BOOT_SIM_SRC_DTB !== TB_SRC_DTB) begin
            fails = fails + 1; $display("[tb_boot_stub] C0 桩 BOOT_SRC_DTB=0x%05h ≠ TB 期望 0x%05h => FAIL", BOOT_SIM_SRC_DTB, TB_SRC_DTB);
        end
        if (BOOT_SIM_LEN_OPENSBI !== EXP_LEN_OPENSBI) begin
            fails = fails + 1; $display("[tb_boot_stub] C0 桩 BOOT_LEN_OPENSBI=0x%0h ≠ TB 期望 0x%0h => FAIL", BOOT_SIM_LEN_OPENSBI, EXP_LEN_OPENSBI);
        end
        if (BOOT_SIM_LEN_UBOOT !== EXP_LEN_UBOOT) begin
            fails = fails + 1; $display("[tb_boot_stub] C0 桩 BOOT_LEN_UBOOT=0x%0h ≠ TB 期望 0x%0h => FAIL", BOOT_SIM_LEN_UBOOT, EXP_LEN_UBOOT);
        end
        if (BOOT_SIM_LEN_DTB !== EXP_LEN_DTB) begin
            fails = fails + 1; $display("[tb_boot_stub] C0 桩 BOOT_LEN_DTB=0x%0h ≠ TB 期望 0x%0h => FAIL", BOOT_SIM_LEN_DTB, EXP_LEN_DTB);
        end
        if (BOOT_SIM_DST_OPENSBI !== TB_DST_OPENSBI) begin
            fails = fails + 1; $display("[tb_boot_stub] C0 桩 BOOT_DST_OPENSBI=0x%08h ≠ TB 期望 0x%08h => FAIL", BOOT_SIM_DST_OPENSBI, TB_DST_OPENSBI);
        end
        if (BOOT_SIM_DST_UBOOT !== TB_DST_UBOOT) begin
            fails = fails + 1; $display("[tb_boot_stub] C0 桩 BOOT_DST_UBOOT=0x%08h ≠ TB 期望 0x%08h => FAIL", BOOT_SIM_DST_UBOOT, TB_DST_UBOOT);
        end
        if (BOOT_SIM_DST_DTB !== TB_DST_DTB) begin
            fails = fails + 1; $display("[tb_boot_stub] C0 桩 BOOT_DST_DTB=0x%08h ≠ TB 期望 0x%08h => FAIL", BOOT_SIM_DST_DTB, TB_DST_DTB);
        end
        if (BOOT_SIM_NEXT_ENTRY !== TB_NEXT_ENTRY) begin
            fails = fails + 1; $display("[tb_boot_stub] C0 桩 BOOT_NEXT_ENTRY=0x%08h ≠ TB 期望 0x%08h => FAIL", BOOT_SIM_NEXT_ENTRY, TB_NEXT_ENTRY);
        end
        if (BOOT_SIM_FDT_DST !== TB_FDT_DST) begin
            fails = fails + 1; $display("[tb_boot_stub] C0 桩 BOOT_FDT_DST=0x%08h ≠ TB 期望 0x%08h => FAIL", BOOT_SIM_FDT_DST, TB_FDT_DST);
        end
        if (BOOT_SIM_HARTID !== TB_HARTID) begin
            fails = fails + 1; $display("[tb_boot_stub] C0 桩 BOOT_HARTID=%0d ≠ TB 期望 %0d => FAIL", BOOT_SIM_HARTID, TB_HARTID);
        end
        if (fails == 0)
            $display("[tb_boot_stub] C0 桩 .equ 常量与本 TB 独立布局逐项一致（偏移/目的/长度/入口/段数）");
        if ((BOOT_SIM_STUB_WORDS < 8) || (BOOT_SIM_STUB_WORDS*4 > 4096)) begin
            $display("[tb_boot_stub] C0 桩镜像字数异常：%0d（期望 8..1024 字）", BOOT_SIM_STUB_WORDS);
            $fatal(1, "TB_BOOT_STUB IMAGE_CONST");
        end
        if (BOOT_SIM_PROBE_WORDS !== EXP_PROBE_WORDS) begin
            $display("[tb_boot_stub] C0 占位程序字数变了（实得 %0d，本 TB 常量 %0d）⇒ 请复核 EXP_MBOX_WORDS（当前 %0d）与 sim/unit/prog/boot_stub_probe.S",
                     BOOT_SIM_PROBE_WORDS, EXP_PROBE_WORDS, EXP_MBOX_WORDS);
            $fatal(1, "TB_BOOT_STUB PROBE_WORDS");
        end
        if ((BOOT_SIM_PROBE_WORDS*4 > LEN_OSB) || (BOOT_SIM_PROBE_MBOX !== DDR_MBOX)) begin
            $display("[tb_boot_stub] C0 占位程序越界或邮箱口径不一致：probe_bytes=%0d len_osb=%0d mbox(字表)=0x%08h mbox(TB)=0x%08h",
                     BOOT_SIM_PROBE_WORDS*4, LEN_OSB, BOOT_SIM_PROBE_MBOX, DDR_MBOX);
            $fatal(1, "TB_BOOT_STUB PROBE");
        end
        if ((LEN_OSB + BOOT_SIM_SRC_OPENSBI > BOOT_SIM_XIP_SIZE) ||
            (LEN_UB  + BOOT_SIM_SRC_UBOOT   > BOOT_SIM_XIP_SIZE) ||
            (LEN_DTB + BOOT_SIM_SRC_DTB     > BOOT_SIM_XIP_SIZE)) begin
            $display("[tb_boot_stub] C0 仿真段越出 XIP 窗口（1 MiB）：0x%0h/0x%0h/0x%0h",
                     BOOT_SIM_SRC_OPENSBI+LEN_OSB, BOOT_SIM_SRC_UBOOT+LEN_UB, BOOT_SIM_SRC_DTB+LEN_DTB);
            $fatal(1, "TB_BOOT_STUB XIP_RANGE");
        end
        if ((LEN_OSB > 4*REGION_WORDS) || (LEN_UB > 4*REGION_WORDS) || (LEN_DTB > 4*REGION_WORDS)) begin
            $display("[tb_boot_stub] C0 仿真段超过 DDR 模型窗口（%0d B）", 4*REGION_WORDS);
            $fatal(1, "TB_BOOT_STUB DDR_WINDOW");
        end

        // 桩镜像 → Flash[0..]；逐字和核对（字表里带着生成时的和）
        load_boot_stub_words();
        stub_sum_chk = 32'h0;
        for (i = 0; i < BOOT_SIM_STUB_WORDS; i = i + 1) stub_sum_chk = stub_sum_chk + flash[i];
        if ((stub_sum_chk !== BOOT_SIM_STUB_SUM) ||
            (flash[0] !== BOOT_SIM_STUB_W0) ||
            (flash[BOOT_SIM_STUB_WORDS-1] !== BOOT_SIM_STUB_WLAST)) begin
            $display("[tb_boot_stub] C0 桩字表自检不符：sum=0x%08h(exp 0x%08h) w0=0x%08h(exp 0x%08h) wlast=0x%08h(exp 0x%08h)",
                     stub_sum_chk, BOOT_SIM_STUB_SUM, flash[0], BOOT_SIM_STUB_W0,
                     flash[BOOT_SIM_STUB_WORDS-1], BOOT_SIM_STUB_WLAST);
            $fatal(1, "TB_BOOT_STUB IMAGE_SUM");
        end
        prog_nonzero = 0;
        for (i = 0; i < BOOT_SIM_STUB_WORDS; i = i + 1) if (flash[i] != 32'h0) prog_nonzero = prog_nonzero + 1;
        $display("[tb_boot_stub] C0 桩字表自检 OK：%0d 字（非零 %0d，逐字和 0x%08h，首字 0x%08h）",
                 BOOT_SIM_STUB_WORDS, prog_nonzero, stub_sum_chk, flash[0]);

        //----------------------------------------------------------------------
        // 装载三段 payload 到 Flash（GB: 期望值同源；反证开关整体后移 4 字节）
        //----------------------------------------------------------------------
        for (i = 0; i < LEN_OSB/4; i = i + 1)
            flash[(TB_SRC_OPENSBI >> 2) + i + (mut_shift >> 2)] = exp_word(0, i);
        for (i = 0; i < LEN_UB/4; i = i + 1)
            flash[(TB_SRC_UBOOT >> 2) + i + (mut_shift >> 2)] = exp_word(1, i);
        for (i = 0; i < LEN_DTB/4; i = i + 1)
            flash[(TB_SRC_DTB >> 2) + i + (mut_shift >> 2)] = exp_word(2, i);
        $display("[tb_boot_stub] Flash 装载完成：OpenSBI@0x%05h、U-Boot@0x%05h、DTB@0x%05h（各 %0d/%0d/%0d B；反证位移=%0d B）",
                 TB_SRC_OPENSBI, TB_SRC_UBOOT, TB_SRC_DTB, LEN_OSB, LEN_UB, LEN_DTB, mut_shift);

        //----------------------------------------------------------------------
        // 等复位释放 → C2 轮询邮箱
        //----------------------------------------------------------------------
        @(posedge aresetn);
        @(posedge clk);
        $display("[tb_boot_stub] 反证开关生效值：Flash 落点整体后移=%0d B（0 = 正常口径）", mut_shift);

        while (!magic_seen && (wait_cnt < TIMEOUT_CYCLES)) begin
            @(posedge clk);
            wait_cnt = wait_cnt + 1;
            if (ddr_mb[3] === BOOT_SIM_PROBE_MAGIC) magic_seen = 1'b1;
            if ((DIAG_PERIOD > 0) && ((wait_cnt % DIAG_PERIOD) == 0))
                $display("[tb_boot_stub] 进度: 拍=%0d 提交=%0d AR=%0d AW=%0d R拍=%0d W拍=%0d Flash读=%0d(坏 %0d) 未建模(rd=%0d wr=%0d)",
                         wait_cnt, commit_count, ar_count, aw_count, r_beat_count, w_beat_count,
                         flash_ar_code + flash_ar_data, flash_ar_bad, unmodeled_rd, unmodeled_wr);
        end
        if (!magic_seen) begin
            timed_out = 1'b1;
            $display("[tb_boot_stub] C2 超时 %0d 拍未见邮箱标志（邮箱字 @0x%08h = 0x%08h，期望 0x%08h）",
                     TIMEOUT_CYCLES, DDR_MBOX + 12, ddr_mb[3], BOOT_SIM_PROBE_MAGIC);
            $display("[tb_boot_stub] 超时现场：提交=%0d AR=%0d AW=%0d W拍=%0d；DDR 写字数 osb=%0d ub=%0d dtb=%0d mb=%0d；未建模 rd=%0d wr=%0d",
                     commit_count, ar_count, aw_count, w_beat_count,
                     ddr_wr_words[0], ddr_wr_words[1], ddr_wr_words[2], ddr_wr_words[3],
                     unmodeled_rd, unmodeled_wr);
            $fatal(1, "TB_BOOT_STUB TIMEOUT");
        end
        //   ★ 次级有界等待：MAGIC 与 SIG 之间还隔着"取指线填充 + 两条 li"，20 拍不够
        //     （实测：只等 20 拍时 SIG 尚未落盘 ⇒ C5/C6 假红）。这里按拍数有界等待 SIG，
        //     上限 4096 拍；到上限仍未到 ⇒ 保留原值进入 C9 判定（判红，不让它变成超时）。
        for (j = 0; (j < 4096) && (ddr_mb[4] !== BOOT_SIM_PROBE_SIG); j = j + 1) @(posedge clk);
        if (ddr_mb[4] !== BOOT_SIM_PROBE_SIG)
            $display("[tb_boot_stub] 提示：等待占位程序最后一笔写（SIG）4096 拍未到，继续判定");
        $display("[tb_boot_stub] C2 邮箱标志已见到（拍=%0d 提交=%0d，SIG 等待额外 %0d 拍）",
                 wait_cnt, commit_count, j);
        //   ★ 收尾排水：占位程序停机循环里可能仍有"已在途"的写通道拍（实测：AW 比 W 拍
        //     多 1 —— 正是最后那笔 store 的 W 尚未落盘）。这里给 64 拍把在途写排空，
        //     之后才做总线计数判定，避免把"在途"误判成"少写"。
        for (j = 0; j < 64; j = j + 1) @(posedge clk);
        $display("[tb_boot_stub] 排水后总线计数：AW=%0d W拍=%0d R拍=%0d（邮箱字3=0x%08h 字4=0x%08h）",
                 aw_count, w_beat_count, r_beat_count, ddr_mb[3], ddr_mb[4]);

        //----------------------------------------------------------------------
        // C1：首笔取指地址 == RESET_PC（XIP 启动）
        //----------------------------------------------------------------------
        if (!first_ar_seen || (first_ar_addr !== `RV32GC_RESET_PC)) begin
            fails = fails + 1;
            $display("[tb_boot_stub] C1 首笔 AR 异常（seen=%b addr=0x%08h 期望=0x%08h）=> FAIL",
                     first_ar_seen, first_ar_addr, `RV32GC_RESET_PC);
        end else begin
            $display("[tb_boot_stub] C1 首笔取指地址 = 0x%08h（= RESET_PC/XIP 主窗口）OK", first_ar_addr);
        end

        //----------------------------------------------------------------------
        // C3：入口寄存器（桩置 a0/a1/a2 后跳转；占位程序把它们写进邮箱）
        //----------------------------------------------------------------------
        mb_a0    = ddr_mb[0];
        mb_a1    = ddr_mb[1];
        mb_a2    = ddr_mb[2];
        mb_magic = ddr_mb[3];
        mb_sig   = ddr_mb[4];
        chk32(mb_a0,    TB_HARTID,            lj("C3 a0=hartid"));
        chk32(mb_a1,    TB_FDT_DST,           lj("C3 a1=dtb_addr"));
        chk32(mb_a2,    32'h0,                lj("C3 a2=priv_info"));
        chk32(mb_magic, BOOT_SIM_PROBE_MAGIC, lj("C9 probe_magic"));
        chk32(mb_sig,   BOOT_SIM_PROBE_SIG,   lj("C9 probe_sig"));

        //----------------------------------------------------------------------
        // C4：三段 payload 逐字节比对（合并/拆分都以"字节"为单位判定）
        //----------------------------------------------------------------------
        $display("[tb_boot_stub] ---- C4 DDR 三段 payload 逐字节比对（期望=占位程序字+地址相关模式）----");
        chk_payload_bytes(0, LEN_OSB, lj("C4 payload_opensbi"));
        chk_payload_bytes(1, LEN_UB,  lj("C4 payload_uboot"));
        chk_payload_bytes(2, LEN_DTB, lj("C4 payload_dtb"));

        //----------------------------------------------------------------------
        // C5：各段写入字数 == 段长/4（恰好一次）；邮箱 == 5 字
        //----------------------------------------------------------------------
        $display("[tb_boot_stub] ---- C5 各窗口写入字数（写入侧计数）----");
        chkint(ddr_wr_words[0], LEN_OSB/4, lj("C5 wr_words_opensbi"));
        chkint(ddr_wr_words[1], LEN_UB/4,  lj("C5 wr_words_uboot"));
        chkint(ddr_wr_words[2], LEN_DTB/4, lj("C5 wr_words_dtb"));
        chkint(ddr_wr_words[3], EXP_MBOX_WORDS, lj("C5 wr_words_mailbox"));

        //----------------------------------------------------------------------
        // C6：总线交叉核对（DDR 写经 MDTA 单 beat、旁路 L1D ⇒ W 拍 == 总字数）
        //----------------------------------------------------------------------
        $display("[tb_boot_stub] ---- C6 总线交叉核对 ----");
        $display("[tb_boot_stub] AXI 总计：AR=%0d AW=%0d R拍=%0d W拍=%0d；Flash 读：代码区=%0d 数据区=%0d 未登记=%0d",
                 ar_count, aw_count, r_beat_count, w_beat_count, flash_ar_code, flash_ar_data, flash_ar_bad);
        chkint(w_beat_count, (LEN_OSB + LEN_UB + LEN_DTB)/4 + EXP_MBOX_WORDS, lj("C6 w_beats=payload_words+mbox"));
        chkint(aw_count,     (LEN_OSB + LEN_UB + LEN_DTB)/4 + EXP_MBOX_WORDS, lj("C6 aw_count"));

        //----------------------------------------------------------------------
        // C7：Flash 读分类 + 三段覆盖性
        //----------------------------------------------------------------------
        $display("[tb_boot_stub] ---- C7 Flash 读分类（代码区/三段源区间）----");
        chk32(flash_ar_bad, 32'h0, lj("C7 flash_ar_unexpected"));
        if (flash_rd_seg[0] == 0) begin fails = fails + 1; $display("[tb_boot_stub] C7 OpenSBI 源区间从未被读 => FAIL"); end
        if (flash_rd_seg[1] == 0) begin fails = fails + 1; $display("[tb_boot_stub] C7 U-Boot 源区间从未被读 => FAIL"); end
        if (flash_rd_seg[2] == 0) begin fails = fails + 1; $display("[tb_boot_stub] C7 DTB 源区间从未被读 => FAIL"); end
        $display("[tb_boot_stub]   Flash 源区间读次数：OpenSBI=%0d U-Boot=%0d DTB=%0d（每段 ≥1 即覆盖）",
                 flash_rd_seg[0], flash_rd_seg[1], flash_rd_seg[2]);

        //----------------------------------------------------------------------
        // C8：未建模访问
        //----------------------------------------------------------------------
        chkint(unmodeled_rd, 0, lj("C8 unmodeled_rd"));
        chkint(unmodeled_wr, 0, lj("C8 unmodeled_wr"));
        if ((unmodeled_rd != 0) || (unmodeled_wr != 0))
            $display("[tb_boot_stub]   首个未建模地址 = 0x%08h", first_unmodeled_addr);

        //----------------------------------------------------------------------
        // 汇总
        //----------------------------------------------------------------------
        $display("------------------------------------------------------------------------");
        $display("[tb_boot_stub] 汇总: 拍=%0d 提交=%0d 不符项=%0d", wait_cnt, commit_count, fails);
        $display("------------------------------------------------------------------------");
        if (fails == 0) begin
            $display("TB_BOOT_STUB: PASS");                  // ★ 唯一成功行
            $finish;
        end else begin
            $display("[tb_boot_stub] %0d 项判据不符（反证开关打开时属预期）⇒ 本 TB 无兜底成功文案", fails);
            $fatal(1, "TB_BOOT_STUB FAIL");
        end
    end

endmodule
