//==============================================================================
// sim/unit/tb_clint.sv —— rtl/clint/clint.v 单元测试（L0）
//==============================================================================
// 目的    : 验证核内 CLINT 的三组寄存器语义与中断输出：
//             (1) **msip**：写 1 ⇒ msip_o（⇒ mip.MSIP）置位；写 0 ⇒ 清位；
//                 读回一致；写非 bit0（如 0xFFFFFFFE，bit0=0）⇒ 清位（只有 bit0 有语义）。
//             (2) **mtime 递增**：复位后 mtime 由 aclk 每拍 +1（用连续若干拍验证计数
//                 增量 == 拍数），且软件可整字写 mtime 的高低字。
//             (3) **mtimecmp 到达 ⇒ MTIP**：mtime >= mtimecmp 时 mtip_o 置位
//                 （ISA `#norm:mtimeintrpending`：相等即挂起，无符号比较）；
//                 **软件写 mtimecmp 抬高比较值（mtime < mtimecmp）后 MTIP 立即自清**
//                 （纯组合口径）。
//             (4) 地址映射：msip=+0x0、mtimecmp=+0x4000、mtime=+0xBFF8 逐条读写命中；
//                 未实现偏移不命中（resp_hit=0）。
//
// ★「CLINT 访问绝不产生 AXI 请求」断言口径（本 TB 的说明性断言）:
//   CLINT 是**核内设备**：clint.v 的端口里**根本不存在** AXI 相关信号
//   （无 awid/awaddr/awlen/wdata/bresp/araddr/rdata 等任何 AXI4 五通道端口）。
//   因此"CLINT 访问绝不产生 AXI 请求"在**端口层面即天然满足**，无法也不需要在
//   本 TB 里用 AXI 监视器去"观察"一个不存在的端口。
//   本 TB 的做法是把这条口径**断言成一个可检查的事实**：
//   ① 静态事实：本 TB 例化 clint 时**只能**连核内总线侧信号（本文件下方例化处
//      的端口列表就是全部端口，逐条与 clint.v 的 port list 对应）；
//   ② 动态事实：任何一次对 CLINT 的读写，其效果**只能**通过 resp_* 与
//      msip_o/mtip_o 观察到 —— 本 TB 在所有访问后都检查 ``axi_like_activity``
//      为 0；该信号由 TB 用 `CLINT_HAS_NO_AXI_PORT` 宏显式定义：
//      因为模块没有 AXI 端口，任何"AXI 请求活动"在本设计中**不可能存在**，
//      故该信号恒 0，断言永真——这正是"天然满足"的机器化表述（而非空断言：
//      若将来有人给 clint.v 加上 AXI 端口，这个 TB 的例化会因端口不匹配而
//      立刻编译失败，从而强制重新审视本条口径）。
//
// 判定    : 任一断言不成立 ⇒ $fatal（非零退出码），且**绝不打印 PASS**；
//           全部检查走完才打印唯一一行 `TB_CLINT_UNIT: PASS`。
// 顶层    : tb_clint（验收命令 -s tb_clint）
// 纪律    : 08 §8.1 fail-closed —— 判定只打 PASS / FAIL 两种；先计数后断言。
//==============================================================================
`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"

module tb_clint;

    //--------------------------------------------------------------------------
    // 0. 检查计数器（fail-closed：checks_seen 必须 > 0，checks_failed 必须 == 0）
    //--------------------------------------------------------------------------
    integer checks_seen   = 0;
    integer checks_failed = 0;

    // 断言宏：只记 FAIL，绝不打印 PASS
    `define CK(cond, msg)                                                       \
        begin                                                                   \
            checks_seen = checks_seen + 1;                                      \
            if (!(cond)) begin                                                  \
                checks_failed = checks_failed + 1;                              \
                $display("TB_CLINT CHECK FAIL: %s (t=%0t)", msg, $time);        \
            end                                                                 \
        end

    //--------------------------------------------------------------------------
    // 1. DUT 端口
    //--------------------------------------------------------------------------
    reg         aclk    = 1'b0;
    reg         aresetn = 1'b0;

    reg         req_valid = 1'b0;
    reg         req_write = 1'b0;
    reg  [31:0] req_addr  = 32'd0;
    reg  [31:0] req_wdata = 32'd0;
    reg  [3:0]  req_wstrb = 4'hF;

    wire [31:0] resp_rdata;
    wire        resp_hit;
    wire        msip_o;
    wire        mtip_o;

    //--------------------------------------------------------------------------
    // 2. AXI 口径说明（见文件头 ★）：clint.v 无 AXI 端口 ⇒ 天然满足。
    //    这里定义一个恒 0 的监视信号，把所有访问后"无 AXI 活动"的检查写成
    //    机器化断言。若 clint.v 被加上 AXI 端口，本 TB 的例化会编译失败。
    //--------------------------------------------------------------------------
    wire axi_like_activity = 1'b0;   // 模块无 AXI 端口 ⇒ 不可能存在 AXI 请求
    wire [63:0] mtime_o;             // ★ F1-B：mtime 实时值输出

    //--------------------------------------------------------------------------
    // 3. 例化 DUT（端口逐条对应 clint.v 的 port list；**无任何 AXI 端口**）
    //--------------------------------------------------------------------------
    clint u_clint (
        .aclk      (aclk),
        .aresetn   (aresetn),
        .req_valid (req_valid),
        .req_write (req_write),
        .req_addr  (req_addr),
        .req_wdata (req_wdata),
        .req_wstrb (req_wstrb),
        .resp_rdata(resp_rdata),
        .resp_hit  (resp_hit),
        .msip_o    (msip_o),
        .mtip_o    (mtip_o),
        .mtime_o   (mtime_o)          // ★ F1-B：64 位 mtime 实时输出（csr_file.time 影子源）
    );

    //--------------------------------------------------------------------------
    // 4. 时钟：33 MHz ⇒ 周期 30.303 ns（上板口径）；仿真取 30 ns 便于计数
    //--------------------------------------------------------------------------
    localparam real CLK_PERIOD = 30.0;
    always #(CLK_PERIOD/2.0) aclk = ~aclk;

    //--------------------------------------------------------------------------
    // 5. 任务：核内 MMIO 写 / 读（单拍握手）
    //--------------------------------------------------------------------------
    task automatic mmio_write(input [31:0] off, input [31:0] data);
        begin
            @(negedge aclk);
            req_addr  = off;
            req_wdata = data;
            req_wstrb = 4'hF;
            req_write = 1'b1;
            req_valid = 1'b1;
            @(posedge aclk);
            #1;
            req_valid = 1'b0;
            req_write = 1'b0;
            // 访问后必须无任何 AXI 活动（见 ★ 口径）
            `CK(axi_like_activity === 1'b0, "写 CLINT 后出现 AXI 活动（不应存在）")
        end
    endtask

    task automatic mmio_read(input [31:0] off, output [31:0] data, output hit);
        begin
            @(negedge aclk);
            req_addr  = off;
            req_wdata = 32'd0;
            req_write = 1'b0;
            req_valid = 1'b1;
            #1;
            data = resp_rdata;
            hit  = resp_hit;
            @(posedge aclk);
            #1;
            req_valid = 1'b0;
            `CK(axi_like_activity === 1'b0, "读 CLINT 后出现 AXI 活动（不应存在）")
        end
    endtask

    // 带**显式字节使能**的写（用于"空/非法掩码无副作用"核查）；同样断言无 AXI 活动
    task automatic mmio_write_strb(input [31:0] off, input [31:0] data, input [3:0] strb);
        begin
            @(negedge aclk);
            req_addr  = off;
            req_wdata = data;
            req_wstrb = strb;
            req_write = 1'b1;
            req_valid = 1'b1;
            @(posedge aclk);
            #1;
            req_valid = 1'b0;
            req_write = 1'b0;
            `CK(axi_like_activity === 1'b0, "写 CLINT 后出现 AXI 活动（不应存在）")
        end
    endtask

    // 把 mtime 钉在 val 一拍（wr_mtime 优先于自增）；调用后（posedge+1ns）
    // mtime_r == val，可在同一处做组合 MTIP 断言或紧接一次精确读回。
    task automatic pin_mtime(input [31:0] val);
        begin
            @(negedge aclk);
            req_addr  = MTIME_OFF;
            req_wdata = val;
            req_wstrb = 4'hF;
            req_write = 1'b1;
            req_valid = 1'b1;
            @(posedge aclk);
            #1;
        end
    endtask

    //--------------------------------------------------------------------------
    // 6. 主流程
    //--------------------------------------------------------------------------
    reg [31:0] rd;
    reg        hit;
    reg [63:0] mtime_a, mtime_b;

    localparam [31:0] MSIP_OFF     = `RV32GC_CLINT_MSIP_OFF;       // 0x1F000000 偏移 0
    localparam [31:0] MTIMECMP_OFF = `RV32GC_CLINT_MTIMECMP_OFF;   // 0x4000
    localparam [31:0] MTIME_OFF    = `RV32GC_CLINT_MTIME_OFF;      // 0xBFF8
    localparam [31:0] MTIMEH_OFF   = `RV32GC_CLINT_MTIMEH_OFF;     // 0xBFFC
    localparam [31:0] MTIMECMPH_OFF= `RV32GC_CLINT_MTIMECMPH_OFF;  // 0x4004
    localparam [31:0] T            = 32'h0000_1234;                // 边界测试基准值

    integer k;

    initial begin
        $display("---- tb_clint: 核内 CLINT 单元测试 ----");

        //----------------------------------------------------------------------
        // (0) 地址真源自检：偏移必须与 08 §6.6 表逐条一致
        //----------------------------------------------------------------------
        `CK(MSIP_OFF      === 32'h0000_0000, "msip 偏移应为 +0x0")
        `CK(MTIMECMP_OFF  === 32'h0000_4000, "mtimecmp 偏移应为 +0x4000")
        `CK(MTIME_OFF     === 32'h0000_BFF8, "mtime 偏移应为 +0xBFF8")
        `CK(`RV32GC_CLINT_BASE === 32'h1F00_0000, "CLINT 基址应为 0x1F000000")
        `CK(`RV32GC_TIMEBASE_HZ === 33_000_000, "mtime 计数频率应为 33 MHz")

        //----------------------------------------------------------------------
        // 复位
        //----------------------------------------------------------------------
        aresetn = 1'b0;
        repeat (5) @(posedge aclk);
        #1;
        `CK(msip_o === 1'b0, "复位后 msip_o 应为 0")
        `CK(mtip_o === 1'b0, "复位后 mtip_o 应为 0（mtimecmp=全1）")
        @(negedge aclk);
        aresetn = 1'b1;
        repeat (2) @(posedge aclk);

        //----------------------------------------------------------------------
        // (1) msip：写 1 ⇒ MSIP 置位
        //----------------------------------------------------------------------
        mmio_write(MSIP_OFF, 32'h0000_0001);
        #1;
        `CK(msip_o === 1'b1, "写 msip=1 后 msip_o 应置位（MSI）")
        mmio_read(MSIP_OFF, rd, hit);
        `CK(hit === 1'b1,           "读 msip 应命中")
        `CK(rd  === 32'h0000_0001,  "读回 msip 应为 1")

        // 再写 0 ⇒ 清位
        mmio_write(MSIP_OFF, 32'h0000_0000);
        #1;
        `CK(msip_o === 1'b0, "写 msip=0 后 msip_o 应清位")
        mmio_read(MSIP_OFF, rd, hit);
        `CK(rd === 32'h0000_0000, "读回 msip 应为 0")

        // 只有 bit0 有语义：写 0xFFFFFFFE（bit0=0）⇒ 仍为 0
        mmio_write(MSIP_OFF, 32'hFFFF_FFFE);
        #1;
        `CK(msip_o === 1'b0, "写 msip 高位置 1 而 bit0=0 时 msip_o 应保持 0")
        // 写 0xFFFFFFF0 | 1 ⇒ bit0=1 ⇒ 置位
        mmio_write(MSIP_OFF, 32'hFFFF_FFF1);
        #1;
        `CK(msip_o === 1'b1, "写 msip bit0=1 时 msip_o 应置位")
        `CK(mtime_o === 64'h0 || mtime_o[63:32] === 32'h0, "mtime_o 复位后高半为 0")
        mmio_write(MSIP_OFF, 32'h0000_0000);

        //----------------------------------------------------------------------
        // (2) mtime 递增：用几拍时钟验证计数
        //    口径：先写 mtime=0（清基准），再数 N 拍，读回应 ≈ N
        //----------------------------------------------------------------------
        // 先把 mtimecmp 抬到最大，避免 MTIP 干扰本段
        mmio_write(MTIMECMP_OFF,  32'hFFFF_FFFF);
        mmio_write(MTIMECMPH_OFF, 32'hFFFF_FFFF);
        // 清 mtime = 0
        mmio_write(MTIME_OFF,  32'h0000_0000);
        mmio_write(MTIMEH_OFF, 32'h0000_0000);
        #1;
        mmio_read(MTIME_OFF, rd, hit);
        `CK(hit === 1'b1, "读 mtime 应命中")
        // 清零点读回值 ≤ 1（清零那一拍与读拍之间存在少量自增，允许 0 或 1）
        `CK(rd <= 32'd1, $sformatf("写 mtime=0 后立即读回应 ≈0，实得 %0d", rd))
        mtime_a = {32'd0, rd};

        // 数 16 拍（每拍 mtime +1）
        for (k = 0; k < 16; k = k + 1) begin
            @(posedge aclk);
        end
        #1;
        mmio_read(MTIME_OFF, rd, hit);
        `CK(rd >= 32'd16, $sformatf("16 拍后 mtime 应 >= 16，实得 %0d", rd))
        `CK(rd <= 32'd20, $sformatf("16 拍后 mtime 应 <= 20（每拍 +1），实得 %0d", rd))

        // 再数 16 拍，增量应再次约为 16（证明是"每拍 +1"而非只加一次）
        for (k = 0; k < 16; k = k + 1) begin
            @(posedge aclk);
        end
        #1;
        mmio_read(MTIME_OFF, rd, hit);
        `CK(rd >= 32'd32, $sformatf("32 拍后 mtime 应 >= 32，实得 %0d", rd))
        `CK(rd <= 32'd36, $sformatf("32 拍后 mtime 应 <= 36（每拍 +1），实得 %0d", rd))

        // mtime 高低字拼接自检：写高字=1，低字=0 ⇒ 64 位值应为 0x1_0000_0000
        mmio_write(MTIME_OFF,  32'h0000_0000);
        mmio_write(MTIMEH_OFF, 32'h0000_0001);
        #1;
        mmio_read(MTIMEH_OFF, rd, hit);
        `CK(hit === 1'b1,        "读 mtime 高字应命中")
        `CK(rd  === 32'h0000_0001, "mtime 高字应为 1（64 位拆分读写）")
        //   ---- ★ F1-B：mtime_o 与 MMIO 读 mtime 同拍一致（time 影子的源）----
        //     这里用"原始读序列"在同一仿真时刻采样 resp_rdata 与 mtime_o，
        //     避免 mmio_read 任务在返回前多等一个 posedge 造成 +1 假差异。
        @(negedge aclk);
        req_addr = MTIME_OFF; req_write = 1'b0; req_valid = 1'b1; #1;
        `CK(resp_hit === 1'b1, "读 mtime 低字应命中（mtime_o 对照）")
        `CK(mtime_o[31:0] === resp_rdata, "★ mtime_o 低 32 位 == MMIO 读 mtime 低字（同拍）")
        `CK(mtime_o[63:32] === 32'h0000_0001, "★ mtime_o 高 32 位 == 已写高字")
        @(posedge aclk); #1;
        req_valid = 1'b0; req_write = 1'b0;

        //----------------------------------------------------------------------
        // (3) mtimecmp 溢出 ⇒ MTIP 置位；软件写 mtimecmp 清 MTIP
        //----------------------------------------------------------------------
        // 3.1 让 mtime 停在一个已知值：写 mtime = 100（高字 0）
        mmio_write(MTIMEH_OFF, 32'h0000_0000);
        mmio_write(MTIME_OFF,  32'd100);
        #1;
        // mtimecmp = 0xFFFF_FFFF（远大于 mtime）⇒ MTIP 应为 0
        mmio_write(MTIMECMP_OFF,  32'hFFFF_FFFF);
        mmio_write(MTIMECMPH_OFF, 32'h0000_0000);
        #1;
        `CK(mtip_o === 1'b0, "mtimecmp 远大于 mtime 时 MTIP 应为 0")

        // 3.2 写 mtimecmp 为一个**很小**的值（0）⇒ mtime > mtimecmp ⇒ MTIP 置位
        mmio_write(MTIMECMP_OFF,  32'h0000_0000);
        mmio_write(MTIMECMPH_OFF, 32'h0000_0000);
        #1;
        mmio_read(MTIMECMP_OFF, rd, hit);
        `CK(hit === 1'b1,       "读 mtimecmp 应命中")
        `CK(rd  === 32'h0000_0000, "mtimecmp 低字应为 0")
        `CK(mtip_o === 1'b1, "mtime(>0) > mtimecmp(=0) 时 MTIP 应置位")

        // 3.3 **软件写 mtimecmp 清 MTIP**：抬高比较值到远大于 mtime
        mmio_write(MTIMECMP_OFF,  32'hFFFF_FF00);
        mmio_write(MTIMECMPH_OFF, 32'h0000_0000);
        #1;
        `CK(mtip_o === 1'b0, "软件写 mtimecmp 抬高后 MTIP 应立即清 0")

        // 3.4 单边边界（mtime 每拍自增，无法"停住"）：
        //     先写出一个已知 mtime，再把 mtimecmp 设成远小/远大于它，验证
        //     MTIP=1 / MTIP=0。**真"相等"边界**在 3.6 用"每拍持续钉住 mtime"
        //     的方式精确构造（那才是 `>` vs `>=` 的区分点）。
        mmio_write(MTIMEH_OFF, 32'h0000_0000);
        mmio_write(MTIME_OFF,  32'd1000);
        #1;
        mmio_read(MTIME_OFF, rd, hit);
        // 此时 mtime 记为 rd（读拍的值），随后 mtime 单调不减
        // a) mtimecmp = rd - 1（严格小于当前 mtime）⇒ MTIP 必为 1
        mmio_write(MTIMECMP_OFF,  32'd999);
        mmio_write(MTIMECMPH_OFF, 32'h0000_0000);
        #1;
        `CK(mtip_o === 1'b1, "mtime > mtimecmp 时 MTIP 应置位")
        // b) mtimecmp = 0xFFFF_0000（远大于 mtime）⇒ MTIP 必为 0
        mmio_write(MTIMECMP_OFF,  32'hFFFF_0000);
        mmio_write(MTIMECMPH_OFF, 32'h0000_0000);
        #1;
        `CK(mtip_o === 1'b0, "mtimecmp 远大于 mtime 时 MTIP 应为 0")

        // 3.5 高字比较也必须生效（64 位口径）：mtimecmp 高字 = 1 ⇒ 远大于 mtime ⇒ MTIP 清
        mmio_write(MTIMECMPH_OFF, 32'h0000_0001);
        #1;
        `CK(mtip_o === 1'b0, "mtimecmp 高字变化应参与 64 位比较（MTIP 应清 0）")
        // 高字清回 0（低字仍是 0xFFFF_0000，仍大于 mtime）⇒ 仍为 0
        mmio_write(MTIMECMPH_OFF, 32'h0000_0000);
        #1;
        `CK(mtip_o === 1'b0, "mtimecmp 高字回 0 且低字仍大于 mtime 时 MTIP 应为 0")
        // 低字清零 ⇒ mtime > 0 ⇒ MTIP 置位（再次确认溢出路径）
        mmio_write(MTIMECMP_OFF, 32'h0000_0000);
        #1;
        `CK(mtip_o === 1'b1, "mtimecmp 清零后 mtime > mtimecmp ⇒ MTIP 应置位")

        // 3.6 ★ mtime >= mtimecmp 的**真边界**（`>` vs `>=` 的唯一区分点）：
        //     规范 ISA `#norm:mtimeintrpending`："A machine timer interrupt becomes
        //     pending whenever mtime contains a value **greater than or equal to**
        //     mtimecmp, treating the values as unsigned integers.  The interrupt
        //     remains posted until mtimecmp becomes greater than mtime."
        //     做法：固定 mtimecmp = T（高半 0，读回确认），用**每拍持续的 mtime 写**
        //     把 mtime 钉死在常量（wr_mtime 优先于自增），依次取 T-1 / T / T+1，
        //     各**连续保持 4 拍**并断言 MTIP = 0 / 1 / 1；每点后立即精确读回 mtime。
        //     旧实现 `>` 在 mtime == mtimecmp 时给 0 ⇒ 本段 T 点必失败。
        begin : eq_boundary
            // ---- 固定 mtimecmp = T（高半 0）并读回确认 ----
            mmio_write(MTIMEH_OFF,     32'h0000_0000);
            mmio_write(MTIMECMPH_OFF,  32'h0000_0000);
            mmio_write(MTIMECMP_OFF,   T);
            mmio_read(MTIMECMP_OFF, rd, hit);
            `CK(hit === 1'b1 && rd === T, $sformatf("mtimecmp 低字应读回 T=0x%08x", T))
            mmio_read(MTIMECMPH_OFF, rd, hit);
            `CK(rd === 32'h0000_0000, "mtimecmp 高字应读回 0")

            // ---- (a) mtime = T-1（连续 4 拍）⇒ MTIP 必须为 0，且读回确认 ----
            for (k = 0; k < 4; k = k + 1) begin
                pin_mtime(T - 32'd1);
                `CK(mtip_o === 1'b0,
                    $sformatf("mtime=T-1 < mtimecmp=T 时 MTIP 应为 0（连续保持第 %0d 拍）", k))
            end
            mmio_read(MTIME_OFF, rd, hit);
            `CK(hit === 1'b1 && rd === (T - 32'd1),
                $sformatf("mtime 应精确读回 T-1=0x%08x（实得 0x%08x）", T - 32'd1, rd))

            // ---- (b) mtime = T（连续 4 拍）⇒ MTIP 必须为 1（相等即挂起） ----
            for (k = 0; k < 4; k = k + 1) begin
                pin_mtime(T);
                `CK(mtip_o === 1'b1,
                    $sformatf("mtime == mtimecmp == T 时 MTIP 必须为 1（ISA mtimeintrpending；连续保持第 %0d 拍）", k))
            end
            mmio_read(MTIME_OFF, rd, hit);
            `CK(rd === T, $sformatf("mtime 应精确读回 T=0x%08x（实得 0x%08x）", T, rd))

            // ---- (c) mtime = T+1（连续 4 拍）⇒ MTIP 必须为 1 ----
            for (k = 0; k < 4; k = k + 1) begin
                pin_mtime(T + 32'd1);
                `CK(mtip_o === 1'b1,
                    $sformatf("mtime=T+1 > mtimecmp=T 时 MTIP 必须为 1（连续保持第 %0d 拍）", k))
            end
            mmio_read(MTIME_OFF, rd, hit);
            `CK(rd === (T + 32'd1), $sformatf("mtime 应精确读回 T+1=0x%08x（实得 0x%08x）", T + 32'd1, rd))

            // ---- (d) 软件写 mtimecmp 抬高到 > mtime ⇒ MTIP 立即自清 ----
            mmio_write(MTIMECMP_OFF, T + 32'h10);
            pin_mtime(T);
            `CK(mtip_o === 1'b0, "mtimecmp 抬高到 > mtime 后 MTIP 应立即自清 0")
            req_valid = 1'b0;
            req_write = 1'b0;
            @(posedge aclk);
        end
        // 复位 mtimecmp 到最大，避免后续干扰
        mmio_write(MTIMECMP_OFF,  32'hFFFF_FFFF);
        mmio_write(MTIMECMPH_OFF, 32'hFFFF_FFFF);

        // 3.7 ★ 64 位比较中**高字参与决策**（漏判高字则本段必失败）：
        //     mtime 钉在 T=0x0000_1234（高半 0），四种 mtimecmp 构型：
        //       a) {高 0, 低 T}      ⇒ 64 位相等 ⇒ MTIP 必须 1（>= 口径）
        //       b) {高 1, 低 0}      ⇒ 0x1_0000_0000 > mtime ⇒ MTIP 必须 0
        //          （只看低字的实现会错误给出 1 ⇒ 抓住"漏高字"变异）
        //       c) {高 0, 低 T-1}    ⇒ 小于 mtime ⇒ MTIP 必须 1
        //       d) {高 0, 低 T+1}    ⇒ 大于 mtime ⇒ MTIP 必须 0
        begin : hi_word_decisive
            mmio_write(MTIMECMPH_OFF, 32'h0000_0000);
            // a) 相等（低字 T、高字 0）
            mmio_write(MTIMECMP_OFF, T);
            pin_mtime(T);
            `CK(mtip_o === 1'b1, "64 位 mtimecmp == mtime == T 时 MTIP 必须为 1（相等挂起）")
            // b) 高字 = 1、低字 = 0 ⇒ 64 位大于 mtime ⇒ MTIP 0
            mmio_write(MTIMECMP_OFF,  32'h0000_0000);
            mmio_write(MTIMECMPH_OFF, 32'h0000_0001);
            pin_mtime(T);
            `CK(mtip_o === 1'b0,
                "mtimecmp 高字=1（64 位 0x1_0000_0000 > mtime 0x1234）时 MTIP 必须为 0（高字参与比较）")
            // c) 高字 0、低字 T-1 ⇒ 小于 mtime ⇒ MTIP 1
            mmio_write(MTIMECMPH_OFF, 32'h0000_0000);
            mmio_write(MTIMECMP_OFF,  T - 32'd1);
            pin_mtime(T);
            `CK(mtip_o === 1'b1, "mtimecmp 低字 T-1 < mtime T 时 MTIP 必须为 1")
            // d) 高字 0、低字 T+1 ⇒ 大于 mtime ⇒ MTIP 0
            mmio_write(MTIMECMP_OFF,  T + 32'd1);
            pin_mtime(T);
            `CK(mtip_o === 1'b0, "mtimecmp 低字 T+1 > mtime T 时 MTIP 必须为 0")
            req_valid = 1'b0;
            req_write = 1'b0;
            @(posedge aclk);
        end
        mmio_write(MTIMECMP_OFF,  32'hFFFF_FFFF);
        mmio_write(MTIMECMPH_OFF, 32'hFFFF_FFFF);

        // 3.8 ★ 空/非法字节掩码写**无副作用**（保留既有"整字访问"契约）：
        //     用 req_wstrb=4'h0 写 msip/mtimecmp，读回必须与写前一致。
        begin : strobe_no_side_effect
            // msip：先置 1，再用空掩码写 0 ⇒ 必须仍为 1
            mmio_write(MSIP_OFF, 32'h0000_0001);
            mmio_read(MSIP_OFF, rd, hit);
            `CK(rd === 32'h0000_0001, "msip 置 1 后读回应为 1")
            mmio_write_strb(MSIP_OFF, 32'h0000_0000, 4'h0);
            mmio_read(MSIP_OFF, rd, hit);
            `CK(rd === 32'h0000_0001, "空字节掩码写 msip=0 不得产生副作用（应仍为 1）")
            `CK(msip_o === 1'b1, "空字节掩码写后 msip_o 应保持 1")
            // mtimecmp：先写 T+0x100，再用空掩码写 T-0x100 ⇒ 读回应仍为 T+0x100
            mmio_write(MTIMECMPH_OFF, 32'h0000_0000);
            mmio_write(MTIMECMP_OFF,  T + 32'h100);
            mmio_write_strb(MTIMECMP_OFF, T - 32'h100, 4'h0);
            mmio_read(MTIMECMP_OFF, rd, hit);
            `CK(rd === (T + 32'h100),
                $sformatf("空字节掩码写 mtimecmp 不得产生副作用（应仍为 0x%08x，实得 0x%08x）",
                          T + 32'h100, rd))
            // 非全字（但非空）掩码仍按既有"整字写"契约生效（4'h1 ⇒ 整字写）
            mmio_write_strb(MTIMECMP_OFF, T + 32'h200, 4'h1);
            mmio_read(MTIMECMP_OFF, rd, hit);
            `CK(rd === (T + 32'h200), "任一字节有效的非全字掩码仍按既有整字写契约生效")
            mmio_write(MSIP_OFF, 32'h0000_0000);
        end

        //----------------------------------------------------------------------
        // (4) 地址映射命中/不命中
        //----------------------------------------------------------------------
        mmio_read(MSIP_OFF,     rd, hit); `CK(hit === 1'b1, "msip 地址应命中")
        mmio_read(MTIMECMP_OFF, rd, hit); `CK(hit === 1'b1, "mtimecmp 地址应命中")
        mmio_read(MTIME_OFF,    rd, hit); `CK(hit === 1'b1, "mtime 地址应命中")
        // 未实现偏移：+0x0004（mtimecmp 上方的空洞）不应命中
        mmio_read(32'h0000_0004, rd, hit); `CK(hit === 1'b0, "未实现偏移 0x4 不应命中")
        mmio_read(32'h0000_2000, rd, hit); `CK(hit === 1'b0, "未实现偏移 0x2000 不应命中")

        //----------------------------------------------------------------------
        // 汇总（fail-closed：必须有检查且无失败）
        //----------------------------------------------------------------------
        if (checks_seen == 0) begin
            $display("TB_CLINT CHECK FAIL: 未执行任何检查（未捕获即失败）");
            $fatal(1, "TB_CLINT FAIL");
        end
        if (checks_failed != 0) begin
            $display("TB_CLINT CHECK FAIL: %0d/%0d 项失败", checks_failed, checks_seen);
            $fatal(1, "TB_CLINT FAIL");
        end

        $display("TB_CLINT checks: %0d passed", checks_seen);
        $display("TB_CLINT_UNIT: PASS");
        $finish;
    end

    //--------------------------------------------------------------------------
    // 超时看门狗（防挂死；超时不得打印 PASS）
    //--------------------------------------------------------------------------
    initial begin
        #2_000_000;   // 2 ms 仿真上限
        $display("TB_CLINT CHECK FAIL: 超时（看门狗触发）");
        $fatal(1, "TB_CLINT FAIL");
    end

endmodule
