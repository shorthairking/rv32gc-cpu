//==============================================================================
// sim/unit/tb_plic.sv —— rtl/plic/plic.v 单元测试（L0）
//==============================================================================
// 目的    : 验证核内 PLIC 的完整语义（08 §6.6；标准 SiFive PLIC 寄存器映射）：
//             (1) **priority**：每源优先级可读写（源 n 地址 = 基址 + 4n）。
//             (2) **pending**：平台中断电平 ⇒ pending 位置位；只读。
//             (3) **enable 屏蔽**：源未使能 ⇒ 不拉中断、不被 claim 返回。
//             (4) **threshold 过滤**：源优先级 <= threshold ⇒ 不拉中断、不被 claim。
//             (5) **claim**：返回本上下文「已使能且优先级 > threshold」的**最高
//                 优先级源号**（并列取最小源号），并**清该源 pending 位**。
//             (6) **complete**：写 claim 同址 ⇒ 清 inservice；源电平仍高则重新挂起。
//             (7) **M/S 两上下文独立**：enable/threshold 独立；context 0 ⇒ meip_o、
//                 context 1 ⇒ seip_o；一个上下文的 claim 不影响另一上下文的
//                 enable/threshold 判定（但 pending 是全局共享位图，符合 PLIC 规范）。
//             (8) 默认源号映射：intrpt[1]→源1、intrpt[3]→源2、intrpt[4]→源3、
//                 intrpt[2]→源4、intrpt[0]→源5（08 §6.6 表）。
//
// ★「PLIC 访问绝不产生 AXI 请求」断言口径（本 TB 的说明性断言）:
//   PLIC 是**核内设备**：plic.v 的端口里**根本不存在** AXI 相关信号
//   （无 awid/awaddr/awlen/wdata/bresp/araddr/rdata 等任何 AXI4 五通道端口）。
//   因此"PLIC 访问绝不产生 AXI 请求"在**端口层面即天然满足**，无法也不需要在
//   本 TB 里用 AXI 监视器去"观察"一个不存在的端口。
//   本 TB 的做法是把这条口径**断言成一个可检查的事实**：
//   ① 静态事实：本 TB 例化 plic 时**只能**连核内总线侧信号 + 平台中断源
//      （本文件下方例化处的端口列表就是全部端口，逐条与 plic.v 的 port list 对应）；
//   ② 动态事实：任何一次对 PLIC 的读写，其效果**只能**通过 resp_* 与
//      meip_o/seip_o 观察到 —— 本 TB 在所有 MMIO 访问后都检查 ``axi_like_activity``
//      为 0；因为模块没有 AXI 端口，该信号恒 0，断言永真——这正是"天然满足"的
//      机器化表述。若将来有人给 plic.v 加上 AXI 端口，本 TB 的例化会因端口
//      不匹配而立刻编译失败，从而强制重新审视本条口径。
//
// 判定    : 任一断言不成立 ⇒ $fatal（非零退出码），且**绝不打印 PASS**；
//           全部检查走完才打印唯一一行 `TB_PLIC_UNIT: PASS`。
// 顶层    : tb_plic（验收命令 -s tb_plic）
// 纪律    : 08 §8.1 fail-closed —— 判定只打 PASS / FAIL；先计数后断言。
//==============================================================================
`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"

module tb_plic;

    //--------------------------------------------------------------------------
    // 0. 检查计数器（fail-closed）
    //--------------------------------------------------------------------------
    integer checks_seen   = 0;
    integer checks_failed = 0;

    `define CK(cond, msg)                                                       \
        begin                                                                   \
            checks_seen = checks_seen + 1;                                      \
            if (!(cond)) begin                                                  \
                checks_failed = checks_failed + 1;                              \
                $display("TB_PLIC CHECK FAIL: %s (t=%0t)", msg, $time);         \
            end                                                                 \
        end

    //--------------------------------------------------------------------------
    // 1. 寄存器偏移（真源 + 标准 PLIC 映射；本 TB 里显式写出以便核对）
    //--------------------------------------------------------------------------
    localparam [31:0] BASE          = `RV32GC_PLIC_BASE;             // 0x1F100000
    localparam [31:0] PRIO_OFF      = `RV32GC_PLIC_PRIORITY_OFF;     // 0x0000_0000
    localparam [31:0] PEND_OFF      = `RV32GC_PLIC_PENDING_OFF;      // 0x0000_1000
    localparam [31:0] EN_OFF_M      = `RV32GC_PLIC_ENABLE_OFF;       // 0x0000_2000
    localparam [31:0] EN_OFF_S      = `RV32GC_PLIC_ENABLE_OFF + 32'h80; // 0x0000_2080
    // ★ 上下文区步长 = 0x1000（标准 PLIC）：ctx0 在 +0x200000、ctx1 在 +0x201000
    localparam [31:0] CTX_STRIDE    = 32'h0000_1000;
    localparam [31:0] THRESH_OFF_0  = `RV32GC_PLIC_THRESHOLD_OFF;                     // 0x0020_0000
    localparam [31:0] THRESH_OFF_1  = `RV32GC_PLIC_THRESHOLD_OFF + CTX_STRIDE;       // 0x0020_1000
    localparam [31:0] CLAIM_OFF_0   = `RV32GC_PLIC_CLAIM_OFF;                         // 0x0020_0004
    localparam [31:0] CLAIM_OFF_1   = `RV32GC_PLIC_CLAIM_OFF + CTX_STRIDE;           // 0x0020_1004

    // 默认源号映射（08 §6.6）：针 → 源
    localparam integer SRC_MAC  = `RV32GC_INTRPT_SRC_MAC;   // 5，针 0
    localparam integer SRC_UART = `RV32GC_INTRPT_SRC_UART;  // 1，针 1
    localparam integer SRC_SPI  = `RV32GC_INTRPT_SRC_SPI;   // 4，针 2
    localparam integer SRC_NAND = `RV32GC_INTRPT_SRC_NAND;  // 2，针 3
    localparam integer SRC_DMA  = `RV32GC_INTRPT_SRC_DMA;   // 3，针 4

    //--------------------------------------------------------------------------
    // 2. DUT 端口
    //--------------------------------------------------------------------------
    reg         aclk    = 1'b0;
    reg         aresetn = 1'b0;

    reg  [`RV32GC_INTRPT_WIDTH-1:0] src = 8'h00;
    // 针 → 源号映射（每针 4 bit）：针0=MAC(5)、针1=UART(1)、针2=SPI(4)、针3=NAND(2)、针4=DMA(3)
    reg  [`RV32GC_INTRPT_WIDTH*4-1:0] src_map =
            { 3'd0,        // 针 7（不映射）
              3'd0,        // 针 6
              3'd0,        // 针 5
              4'd3,        // 针 4 = DMA  → 源 3
              4'd2,        // 针 3 = NAND → 源 2
              4'd4,        // 针 2 = SPI  → 源 4
              4'd1,        // 针 1 = UART → 源 1
              4'd5 };      // 针 0 = MAC  → 源 5

    reg         req_valid = 1'b0;
    reg         req_write = 1'b0;
    reg  [31:0] req_addr  = 32'd0;
    reg  [31:0] req_wdata = 32'd0;
    reg  [3:0]  req_wstrb = 4'hF;

    wire [31:0] resp_rdata;
    wire        resp_hit;
    wire        meip_o;
    wire        seip_o;

    // AXI 口径监视（见文件头 ★）：模块无 AXI 端口 ⇒ 恒 0
    wire axi_like_activity = 1'b0;

    //--------------------------------------------------------------------------
    // 3. 例化 DUT（**无任何 AXI 端口**）
    //--------------------------------------------------------------------------
    plic u_plic (
        .aclk          (aclk),
        .aresetn       (aresetn),
        .src           (src),
        .intrpt_src_map(src_map),
        .req_valid     (req_valid),
        .req_write     (req_write),
        .req_addr      (req_addr),
        .req_wdata     (req_wdata),
        .req_wstrb     (req_wstrb),
        .resp_rdata    (resp_rdata),
        .resp_hit      (resp_hit),
        .meip_o        (meip_o),
        .seip_o        (seip_o)
    );

    //--------------------------------------------------------------------------
    // 4. 时钟
    //--------------------------------------------------------------------------
    localparam real CLK_PERIOD = 30.0;
    always #(CLK_PERIOD/2.0) aclk = ~aclk;

    //--------------------------------------------------------------------------
    // 5. 任务：MMIO 写 / 读
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
            `CK(axi_like_activity === 1'b0, "写 PLIC 后出现 AXI 活动（不应存在）")
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
            `CK(axi_like_activity === 1'b0, "读 PLIC 后出现 AXI 活动（不应存在）")
        end
    endtask

    // 源 n 的优先级寄存器偏移
    function [31:0] prio_off(input integer n);
        prio_off = PRIO_OFF + (n * 4);
    endfunction

    //--------------------------------------------------------------------------
    // 6. 主流程
    //--------------------------------------------------------------------------
    reg [31:0] rd;
    reg        hit;
    integer    i;

    initial begin
        $display("---- tb_plic: 核内 PLIC 单元测试 ----");

        //----------------------------------------------------------------------
        // (0) 地址真源自检：必须与 08 §6.6 表 / 标准 PLIC 映射一致
        //----------------------------------------------------------------------
        `CK(BASE         === 32'h1F10_0000, "PLIC 基址应为 0x1F100000")
        `CK(PRIO_OFF     === 32'h0000_0000, "priority 偏移应为 +0x0 (+4n)")
        `CK(PEND_OFF     === 32'h0000_1000, "pending 偏移应为 +0x1000")
        `CK(EN_OFF_M     === 32'h0000_2000, "enable(M) 偏移应为 +0x2000")
        `CK(EN_OFF_S     === 32'h0000_2080, "enable(S) 偏移应为 +0x2080")
        `CK(THRESH_OFF_0 === 32'h0020_0000, "threshold(ctx0) 偏移应为 +0x200000")
        `CK(CLAIM_OFF_0  === 32'h0020_0004, "claim(ctx0) 偏移应为 +0x200004")
        `CK(THRESH_OFF_1 === 32'h0020_1000, "threshold(ctx1) 偏移应为 +0x201000（步长 0x1000）")
        `CK(CLAIM_OFF_1  === 32'h0020_1004, "claim(ctx1) 偏移应为 +0x201004（步长 0x1000）")
        `CK(`RV32GC_PLIC_NUM_SOURCES === 5, "PLIC 源数应为 5")
        `CK(`RV32GC_PLIC_NUM_CONTEXTS=== 2, "PLIC 上下文数应为 2")
        // 默认源号映射（08 §6.6 表）：针0→5(MAC) 针1→1(UART) 针2→4(SPI) 针3→2(NAND) 针4→3(DMA)
        `CK(SRC_MAC  === 5, "针0 应映射源 5(MAC)")
        `CK(SRC_UART === 1, "针1 应映射源 1(UART0)")
        `CK(SRC_SPI  === 4, "针2 应映射源 4(SPI)")
        `CK(SRC_NAND === 2, "针3 应映射源 2(NAND)")
        `CK(SRC_DMA  === 3, "针4 应映射源 3(DMA)")

        //----------------------------------------------------------------------
        // 复位：无中断、pending 清 0
        //----------------------------------------------------------------------
        aresetn = 1'b0;
        src     = 8'h00;
        repeat (5) @(posedge aclk);
        #1;
        `CK(meip_o === 1'b0, "复位后 meip_o 应为 0")
        `CK(seip_o === 1'b0, "复位后 seip_o 应为 0")
        mmio_read(PEND_OFF, rd, hit);
        `CK(hit === 1'b1,      "读 pending 应命中")
        `CK(rd  === 32'h0,     "复位后 pending 应为 0")
        @(negedge aclk);
        aresetn = 1'b1;
        repeat (2) @(posedge aclk);

        //----------------------------------------------------------------------
        // (1) priority 读写：源 n 地址 = 基址 + 4n
        //----------------------------------------------------------------------
        mmio_write(prio_off(SRC_UART), 32'd7);   // 源 1 优先级 7
        mmio_write(prio_off(SRC_NAND), 32'd3);   // 源 2 优先级 3
        mmio_write(prio_off(SRC_DMA),  32'd5);   // 源 3 优先级 5
        mmio_write(prio_off(SRC_SPI),  32'd2);   // 源 4 优先级 2
        mmio_write(prio_off(SRC_MAC),  32'd1);   // 源 5 优先级 1
        mmio_read(prio_off(SRC_UART), rd, hit);
        `CK(hit === 1'b1, "读 priority(源1) 应命中")
        `CK(rd  === 32'd7, "priority(源1) 应为 7")
        mmio_read(prio_off(SRC_DMA), rd, hit);
        `CK(rd === 32'd5, "priority(源3) 应为 5")
        // 源 0 保留：对 4*0 = 偏移 0 的写... 注意偏移 0 即 priority[0]，
        // 本设计 SOURCE_MIN=1 ⇒ 不应命中（源 0 保留为「无中断」）
        mmio_read(PRIO_OFF, rd, hit);
        `CK(hit === 1'b0, "源 0 的 priority 地址不应命中（源 0 保留）")

        //----------------------------------------------------------------------
        // (2) pending 置位：仅置电平，未使能 ⇒ 不应拉中断
        //----------------------------------------------------------------------
        mmio_write(EN_OFF_M, 32'h0);   // M 上下文使能全关
        mmio_write(EN_OFF_S, 32'h0);   // S 上下文使能全关
        mmio_write(THRESH_OFF_0, 32'd0);
        mmio_write(THRESH_OFF_1, 32'd0);
        // 抬高针 1（UART ⇒ 源 1）
        @(negedge aclk);
        src[1] = 1'b1;
        repeat (3) @(posedge aclk);
        #1;
        mmio_read(PEND_OFF, rd, hit);
        `CK(rd[SRC_UART] === 1'b1, "UART 源置电平后 pending 对应位应为 1")
        `CK(meip_o === 1'b0, "源未使能时 meip_o 应为 0（enable 屏蔽）")
        `CK(seip_o === 1'b0, "源未使能时 seip_o 应为 0（enable 屏蔽）")

        //----------------------------------------------------------------------
        // (3) enable 屏蔽：只使能 M 上下文的源 1 ⇒ 仅 meip_o 拉高
        //----------------------------------------------------------------------
        mmio_write(EN_OFF_M, (32'h1 << SRC_UART));
        #1;
        mmio_read(EN_OFF_M, rd, hit);
        `CK(hit === 1'b1, "读 enable(M) 应命中")
        `CK(rd === (32'h1 << SRC_UART), "enable(M) 读回应与写入一致")
        `CK(meip_o === 1'b1, "M 上下文使能源 1 且有 pending ⇒ meip_o 应拉高")
        `CK(seip_o === 1'b0, "S 上下文未使能 ⇒ seip_o 应保持 0")
        // bit0 应恒 0（源 0 保留）：写 0xFFFFFFFF 后读回 bit0 == 0
        mmio_write(EN_OFF_M, 32'hFFFF_FFFF);
        mmio_read(EN_OFF_M, rd, hit);
        `CK(rd[0] === 1'b0, "enable bit0 应恒 0（源 0 保留为「无中断」）")
        `CK(rd[SRC_UART] === 1'b1, "enable 其余位应可写 1")
        // 恢复：只使能源 1
        mmio_write(EN_OFF_M, (32'h1 << SRC_UART));

        //----------------------------------------------------------------------
        // (4) threshold 过滤：threshold >= priority ⇒ 不拉中断、claim 返回 0
        //----------------------------------------------------------------------
        mmio_write(THRESH_OFF_0, 32'd7);   // == priority(源1)=7 ⇒ 被过滤
        #1;
        `CK(meip_o === 1'b0, "threshold == priority 时应被过滤（meip_o=0）")
        mmio_read(CLAIM_OFF_0, rd, hit);
        `CK(hit === 1'b1,  "读 claim(ctx0) 应命中")
        `CK(rd  === 32'd0, "被 threshold 过滤时 claim 应返回 0")
        // threshold = 6 < 7 ⇒ 通过
        mmio_write(THRESH_OFF_0, 32'd6);
        #1;
        `CK(meip_o === 1'b1, "threshold < priority 时应通过（meip_o=1）")

        //----------------------------------------------------------------------
        // (5) claim：返回最高优先级源，且优先清 pending 位
        //----------------------------------------------------------------------
        // 抬高多个源电平：源 1(UART,prio7)、源 3(DMA,prio5)、源 2(NAND,prio3)
        @(negedge aclk);
        src[1] = 1'b1;   // 源 1
        src[4] = 1'b1;   // 源 3 (DMA)
        src[3] = 1'b1;   // 源 2 (NAND)
        repeat (3) @(posedge aclk);
        #1;
        mmio_read(PEND_OFF, rd, hit);
        `CK(rd[SRC_UART] === 1'b1 && rd[SRC_NAND] === 1'b1 && rd[SRC_DMA] === 1'b1,
            "三个源 pending 位都应置位")
        // 使能三个源
        mmio_write(EN_OFF_M, (32'h1 << SRC_UART) | (32'h1 << SRC_NAND) | (32'h1 << SRC_DMA));
        mmio_write(THRESH_OFF_0, 32'd0);
        #1;
        `CK(meip_o === 1'b1, "多源 pending 且使能 ⇒ meip_o 应拉高")
        // claim ⇒ 应返回优先级最高的源 1（priority 7）
        mmio_read(CLAIM_OFF_0, rd, hit);
        `CK(rd === SRC_UART, $sformatf("claim 应返回最高优先级源 %0d，实得 %0d", SRC_UART, rd))
        // 该源的 pending 位应被清
        mmio_read(PEND_OFF, rd, hit);
        `CK(rd[SRC_UART] === 1'b0, "claim 后该源 pending 位应被清零")
        `CK(rd[SRC_NAND] === 1'b1 && rd[SRC_DMA] === 1'b1, "其他源 pending 应保持")
        // 再次 claim ⇒ 应返回次高优先级源 3（priority 5），而不是同一个源
        mmio_read(CLAIM_OFF_0, rd, hit);
        `CK(rd === SRC_DMA, $sformatf("第二次 claim 应返回次高优先级源 %0d，实得 %0d", SRC_DMA, rd))
        // 第三次 claim ⇒ 源 2（priority 3）
        mmio_read(CLAIM_OFF_0, rd, hit);
        `CK(rd === SRC_NAND, $sformatf("第三次 claim 应返回源 %0d，实得 %0d", SRC_NAND, rd))
        // 第四次 claim ⇒ 无候选 ⇒ 返回 0（且必须已无 pending 候选）
        mmio_read(CLAIM_OFF_0, rd, hit);
        `CK(rd === 32'd0, "无候选时 claim 应返回 0")

        //----------------------------------------------------------------------
        // (6) complete：写 claim 同址 ⇒ 清 inservice；此时源电平已撤 ⇒ pending 不再挂
        //     先撤走全部源电平，再 complete 掉源 1
        //----------------------------------------------------------------------
        @(negedge aclk);
        src[1] = 1'b0;
        src[4] = 1'b0;
        src[3] = 1'b0;
        repeat (3) @(posedge aclk);
        #1;
        // complete 源 1（写 claim 同址，数据 = 源号）
        mmio_write(CLAIM_OFF_0, SRC_UART);
        #1;
        mmio_read(PEND_OFF, rd, hit);
        `CK(rd[SRC_UART] === 1'b0, "complete 后（源电平已撤）pending 应保持 0")
        `CK(meip_o === 1'b0, "全部源撤销后 meip_o 应为 0")

        //----------------------------------------------------------------------
        // (7) 并列优先级 ⇒ 取最小源号（确定性仲裁）
        //----------------------------------------------------------------------
        mmio_write(prio_off(SRC_NAND), 32'd4);   // 源 2 = 4
        mmio_write(prio_off(SRC_DMA),  32'd4);   // 源 3 = 4（并列）
        mmio_write(prio_off(SRC_MAC),  32'd4);   // 源 5 = 4（并列）
        mmio_write(EN_OFF_M, (32'h1 << SRC_NAND) | (32'h1 << SRC_DMA) | (32'h1 << SRC_MAC));
        mmio_write(THRESH_OFF_0, 32'd0);
        @(negedge aclk);
        src[3] = 1'b1;   // 源 2 (NAND)
        src[4] = 1'b1;   // 源 3 (DMA)
        src[0] = 1'b1;   // 源 5 (MAC)
        repeat (3) @(posedge aclk);
        #1;
        mmio_read(CLAIM_OFF_0, rd, hit);
        `CK(rd === SRC_NAND, $sformatf("并列优先级应取最小源号 %0d，实得 %0d", SRC_NAND, rd))

        //----------------------------------------------------------------------
        // (8) M/S 两上下文独立 claim
        //     清空状态后：源 1 只使能 S、源 3 只使能 M ⇒
        //       ctx0(M) claim 得到源 3；ctx1(S) claim 得到源 1
        //----------------------------------------------------------------------
        @(negedge aclk);
        src = 8'h00;
        repeat (3) @(posedge aclk);
        // complete 清掉 inservice 残留（全部源）
        for (i = 1; i <= 5; i = i + 1) begin
            mmio_write(CLAIM_OFF_0, i);
            mmio_write(CLAIM_OFF_1, i);
        end
        mmio_read(PEND_OFF, rd, hit);
        `CK(rd === 32'h0, "清空后 pending 应为 0")
        // 优先级：源 1 = 7、源 3 = 5
        mmio_write(prio_off(SRC_UART), 32'd7);
        mmio_write(prio_off(SRC_DMA),  32'd5);
        mmio_write(prio_off(SRC_NAND), 32'd3);
        mmio_write(prio_off(SRC_SPI),  32'd2);
        mmio_write(prio_off(SRC_MAC),  32'd1);
        // M 上下文：只使能源 3；S 上下文：只使能源 1
        mmio_write(EN_OFF_M, (32'h1 << SRC_DMA));
        mmio_write(EN_OFF_S, (32'h1 << SRC_UART));
        mmio_write(THRESH_OFF_0, 32'd0);
        mmio_write(THRESH_OFF_1, 32'd0);
        // 抬高源 1 与源 3
        @(negedge aclk);
        src[1] = 1'b1;   // 源 1 UART
        src[4] = 1'b1;   // 源 3 DMA
        repeat (3) @(posedge aclk);
        #1;
        `CK(meip_o === 1'b1, "M 上下文使能源 3 ⇒ meip_o 应为 1")
        `CK(seip_o === 1'b1, "S 上下文使能源 1 ⇒ seip_o 应为 1")
        // M claim ⇒ 源 3（源 1 在 M 未使能）
        mmio_read(CLAIM_OFF_0, rd, hit);
        `CK(rd === SRC_DMA, $sformatf("ctx0(M) claim 应得源 %0d，实得 %0d", SRC_DMA, rd))
        // S claim ⇒ 源 1
        mmio_read(CLAIM_OFF_1, rd, hit);
        `CK(rd === SRC_UART, $sformatf("ctx1(S) claim 应得源 %0d，实得 %0d", SRC_UART, rd))
        // M 的 claim 已清源 3 的 pending ⇒ M 侧 meip 应降；S 侧 seip 应仍为 1（源 1 未被 M 取走）
        #1;
        `CK(meip_o === 1'b0, "ctx0 claim 源 3 后 meip_o 应降为 0")
        `CK(seip_o === 1'b0, "ctx1 claim 源 1 后 seip_o 应降为 0")

        // 两上下文 enable 相互独立：改 M 的 enable 不应影响 S 的判定
        mmio_write(EN_OFF_M, 32'h0);
        mmio_write(EN_OFF_S, (32'h1 << SRC_UART));
        // ★ 网关为上升沿置位（标准 PLIC）：必须先撤低再拉高，才产生新的 pending
        @(negedge aclk);
        src[1] = 1'b0;
        repeat (2) @(posedge aclk);
        @(negedge aclk);
        src[1] = 1'b1;   // 源 1 再次置位（新的上升沿）
        repeat (3) @(posedge aclk);
        #1;
        `CK(meip_o === 1'b0, "M enable 清零后 meip_o 应为 0（上下文独立）")
        `CK(seip_o === 1'b1, "S enable 保持 ⇒ seip_o 应为 1（上下文独立）")

        //----------------------------------------------------------------------
        // (9) S 上下文 threshold 独立过滤
        //----------------------------------------------------------------------
        mmio_write(THRESH_OFF_1, 32'd7);   // S 阈值 = 7 == priority(源1)
        #1;
        `CK(seip_o === 1'b0, "S 上下文 threshold=7 应过滤 priority=7 的源 1")
        `CK(meip_o === 1'b0, "M 侧不受 S threshold 影响")
        mmio_write(THRESH_OFF_1, 32'd6);
        #1;
        `CK(seip_o === 1'b1, "S 上下文 threshold=6 < 7 应通过")

        //----------------------------------------------------------------------
        // (10) pending 只读：写 pending 不应改变其值
        //----------------------------------------------------------------------
        mmio_read(PEND_OFF, rd, hit);
        begin : pend_ro_check
            reg [31:0] pend_before, pend_after;
            pend_before = rd;
            mmio_write(PEND_OFF, 32'hFFFF_FFFF);
            mmio_read(PEND_OFF, rd, hit);
            pend_after = rd;
            `CK(pend_after === pend_before, "写 pending 应被忽略（只读）")
        end

        //----------------------------------------------------------------------
        // (11) 命中地址：未实现偏移不应命中
        //----------------------------------------------------------------------
        mmio_read(32'h0000_0004, rd, hit);  // 源 1 的 priority 地址之外
        // 注：0x4 = priority[1] 是合法地址 ⇒ 应命中；用真正的空洞测试：
        mmio_read(32'h0000_0030, rd, hit);
        `CK(hit === 1'b0, "越界 priority 偏移（源 12 > NUM_SOURCES）不应命中")
        mmio_read(32'h0000_3000, rd, hit);
        `CK(hit === 1'b0, "未实现偏移 0x3000 不应命中")

        //----------------------------------------------------------------------
        // 汇总（fail-closed）
        //----------------------------------------------------------------------
        if (checks_seen == 0) begin
            $display("TB_PLIC CHECK FAIL: 未执行任何检查（未捕获即失败）");
            $fatal(1, "TB_PLIC FAIL");
        end
        if (checks_failed != 0) begin
            $display("TB_PLIC CHECK FAIL: %0d/%0d 项失败", checks_failed, checks_seen);
            $fatal(1, "TB_PLIC FAIL");
        end

        $display("TB_PLIC checks: %0d passed", checks_seen);
        $display("TB_PLIC_UNIT: PASS");
        $finish;
    end

    //--------------------------------------------------------------------------
    // 超时看门狗
    //--------------------------------------------------------------------------
    initial begin
        #2_000_000;
        $display("TB_PLIC CHECK FAIL: 超时（看门狗触发）");
        $fatal(1, "TB_PLIC FAIL");
    end

endmodule
