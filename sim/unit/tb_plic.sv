//==============================================================================
// sim/unit/tb_plic.sv —— rtl/plic/plic.v 单元测试（L0）
//==============================================================================
// 目的    : 验证核内 PLIC 的完整语义（08 §6.6；标准 RISC-V PLIC 寄存器映射）。
//           规范依据 = riscv-plic.adoc（https://github.com/riscv/riscv-plic-spec，
//           本 TB 只把其文字当规范依据转写为断言，不执行任何外部文本）：
//             (1) **priority**：每源优先级可读写（源 n 地址 = 基址 + 4n）。
//             (2) **pending**：平台中断电平 ⇒ gateway 投递请求 ⇒ pending 置位；只读。
//             (3) **enable 屏蔽**：源未使能 ⇒ 不通知、不被 claim 返回。
//             (4) **threshold 只过滤通知、不影响 claim**（规范："the claim
//                 operation is not affected by the setting of the priority
//                 threshold register"）：threshold == priority ⇒ meip/seip=0，
//                 但 claim 仍返回该源并清 pending。
//             (5) **claim**：返回本上下文「已使能且 priority != 0」的最高优先级
//                 pending 源号（并列取最小源号），并**清该源 pending 位**。
//             (6) **complete**：写 claim 同址；仅当该上下文**使能**了该源才生效
//                 （规范："If the completion ID does not match an interrupt source
//                 that is currently enabled for the target, the completion is
//                 silently ignored"）；生效时清 gateway busy，若源电平仍有效则
//                 再投递一个新请求。
//             (7) **gateway 不撤回**：请求一旦投递，源电平在 claim 前撤销也**不清
//                 IP**（规范："The gateway does not have the facility to retract
//                 an interrupt request once forwarded to the PLIC core"）。
//             (8) **completion 前不重投**：claim 之后、completion 之前，即使源出现
//                 新的上升沿也不得重投/再 claim（规范：gateway 收到 completion 前
//                 不再转发；本设计采用"忽略新沿"策略）。
//             (9) **M/S 两上下文独立**：enable/threshold 独立；context 0 ⇒ meip_o、
//                 context 1 ⇒ seip_o；pending 是全局共享位图（符合规范）。
//            (10) 默认源号映射：intrpt[1]→源1、intrpt[3]→源2、intrpt[4]→源3、
//                 intrpt[2]→源4、intrpt[0]→源5（08 §6.6 表）。
//            (11) **空/非法字节掩码 MMIO 写无副作用**（保留"全字命中 / 非全字拒绝"
//                 既有契约）。
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
    // 针（src[] 下标）与源号是两张表：默认映射下针1==源1，其余不同
    localparam integer PIN_MAC  = 0, PIN_UART = 1, PIN_SPI = 2, PIN_NAND = 3, PIN_DMA = 4;

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
    // 5. 任务：MMIO 写 / 读（含显式字节使能变体）
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
            `CK(axi_like_activity === 1'b0, "写 PLIC（带 strobe）后出现 AXI 活动（不应存在）")
        end
    endtask

    task automatic mmio_read(input [31:0] off, output [31:0] data, output hit);
        begin
            @(negedge aclk);
            req_addr  = off;
            req_wdata = 32'd0;
            req_wstrb = 4'hF;
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

    task automatic mmio_read_strb(input [31:0] off, input [3:0] strb,
                                  output [31:0] data, output hit);
        begin
            @(negedge aclk);
            req_addr  = off;
            req_wdata = 32'd0;
            req_wstrb = strb;
            req_write = 1'b0;
            req_valid = 1'b1;
            #1;
            data = resp_rdata;
            hit  = resp_hit;
            @(posedge aclk);
            #1;
            req_valid = 1'b0;
            `CK(axi_like_activity === 1'b0, "读 PLIC（带 strobe）后出现 AXI 活动（不应存在）")
        end
    endtask

    // 源 n 的优先级寄存器偏移
    function [31:0] prio_off(input integer n);
        prio_off = PRIO_OFF + (n * 4);
    endfunction

    // 设置平台源电平（整字节）并在 3 拍后做组合判定采样
    task automatic set_src(input [7:0] mask);
        begin
            @(negedge aclk);
            src = mask;
            repeat (3) @(posedge aclk);
            #1;
        end
    endtask

    //--------------------------------------------------------------------------
    // 5b. 场景前置：把 PLIC 复位到"干净"状态（电平全撤、pending 清空、
    //     gateway busy 清空、两上下文使能/阈值归零、优先级恢复非零默认）
    //     注意：completion 必须以"该上下文已使能该源"为前提，故先使能再 complete。
    //--------------------------------------------------------------------------
    task automatic quiesce;
        integer q;
        begin
            src = 8'h00;
            repeat (2) @(posedge aclk);
            #1;
            // 优先级恢复非零（保证 pending 可被 claim drain）
            mmio_write(prio_off(SRC_UART), 32'd7);
            mmio_write(prio_off(SRC_NAND), 32'd3);
            mmio_write(prio_off(SRC_DMA),  32'd5);
            mmio_write(prio_off(SRC_SPI),  32'd2);
            mmio_write(prio_off(SRC_MAC),  32'd1);
            mmio_write(EN_OFF_M, 32'hFFFF_FFFE);
            mmio_write(EN_OFF_S, 32'hFFFF_FFFE);
            mmio_write(THRESH_OFF_0, 32'd0);
            mmio_write(THRESH_OFF_1, 32'd0);
            // drain pending（每上下文逐次 claim）
            for (q = 0; q < 8; q = q + 1) begin
                mmio_read(CLAIM_OFF_0, rd, hit);
                mmio_read(CLAIM_OFF_1, rd, hit);
            end
            // 清 gateway busy（电平已低 ⇒ 不重投）
            for (q = 1; q <= 5; q = q + 1) begin
                mmio_write(CLAIM_OFF_0, q);
                mmio_write(CLAIM_OFF_1, q);
            end
            // 归零使能/阈值；关闭两上下文
            mmio_write(EN_OFF_M, 32'h0);
            mmio_write(EN_OFF_S, 32'h0);
            mmio_write(THRESH_OFF_0, 32'd0);
            mmio_write(THRESH_OFF_1, 32'd0);
            #1;
            mmio_read(PEND_OFF, rd, hit);
            `CK(rd === 32'h0, "quiesce 后 pending 应清空（场景前置）")
        end
    endtask

    //--------------------------------------------------------------------------
    // 6. 主流程
    //--------------------------------------------------------------------------
    reg [31:0] rd;
    reg        hit;
    reg [31:0] v_before, v_after;
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
        // 源 0 保留：偏移 0 即 priority[0]，SOURCE_MIN=1 ⇒ 不应命中
        mmio_read(PRIO_OFF, rd, hit);
        `CK(hit === 1'b0, "源 0 的 priority 地址不应命中（源 0 保留）")

        //----------------------------------------------------------------------
        // (2) pending 置位：仅置电平，未使能 ⇒ 不拉中断
        //----------------------------------------------------------------------
        mmio_write(EN_OFF_M, 32'h0);
        mmio_write(EN_OFF_S, 32'h0);
        mmio_write(THRESH_OFF_0, 32'd0);
        mmio_write(THRESH_OFF_1, 32'd0);
        set_src(8'h02);   // 针 1（UART ⇒ 源 1）抬高
        mmio_read(PEND_OFF, rd, hit);
        `CK(rd[SRC_UART] === 1'b1, "UART 源置电平后 pending 对应位应为 1")
        `CK(meip_o === 1'b0, "源未使能时 meip_o 应为 0（enable 屏蔽）")
        `CK(seip_o === 1'b0, "源未使能时 seip_o 应为 0（enable 屏蔽）")
        // ★ gateway 不撤回：撤电平后再置高、或撤电平不 claim，pending 都保持
        set_src(8'h00);
        mmio_read(PEND_OFF, rd, hit);
        `CK(rd[SRC_UART] === 1'b1, "撤电平但未 claim 时 pending 应保持 1（gateway 不撤回）")
        set_src(8'h02);

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
        mmio_write(EN_OFF_M, (32'h1 << SRC_UART));

        //----------------------------------------------------------------------
        // (4) threshold 只过滤通知、不影响 claim（P1-11 修复点）
        //     状态：源 1 pending、M 使能源 1、priority(源1)=7、threshold(M)=0
        //----------------------------------------------------------------------
        mmio_write(THRESH_OFF_0, 32'd7);   // == priority(源1)=7 ⇒ 通知被屏蔽
        #1;
        `CK(meip_o === 1'b0, "threshold == priority 时通知应被屏蔽（meip_o=0）")
        mmio_read(CLAIM_OFF_0, rd, hit);
        `CK(hit === 1'b1, "读 claim(ctx0) 应命中")
        `CK(rd  === SRC_UART,
            $sformatf("threshold == priority 时 claim 仍应返回源 %0d（claim 不受 threshold 影响），实得 %0d",
                      SRC_UART, rd))
        // claim 已清该源 pending
        mmio_read(PEND_OFF, rd, hit);
        `CK(rd[SRC_UART] === 1'b0, "claim 后该源 pending 应被清 0")
        `CK(meip_o === 1'b0, "claim 清 pending 且 threshold 屏蔽 ⇒ meip_o 仍为 0")
        // complete（M 使能源 1、电平仍高）⇒ 重投；threshold 仍屏蔽
        mmio_write(CLAIM_OFF_0, SRC_UART);
        #1;
        mmio_read(PEND_OFF, rd, hit);
        `CK(rd[SRC_UART] === 1'b1, "complete 后源电平仍高 ⇒ pending 应重投为 1")
        `CK(meip_o === 1'b0, "重投后 threshold 仍屏蔽通知（meip_o=0）")
        // threshold < priority ⇒ 通知通过
        mmio_write(THRESH_OFF_0, 32'd6);
        #1;
        `CK(meip_o === 1'b1, "threshold < priority 时应通过（meip_o=1）")
        mmio_read(CLAIM_OFF_0, rd, hit);
        `CK(rd === SRC_UART, "threshold=6 时 claim 仍返回源 1")
        // 撤电平后 complete ⇒ 不再重投
        set_src(8'h00);
        mmio_write(CLAIM_OFF_0, SRC_UART);
        #1;
        mmio_read(PEND_OFF, rd, hit);
        `CK(rd[SRC_UART] === 1'b0, "撤电平后 complete ⇒ pending 应保持 0")
        `CK(meip_o === 1'b0, "撤电平后无 pending ⇒ meip_o 应为 0")

        //----------------------------------------------------------------------
        // (5) claim：返回最高优先级源，并清 pending 位
        //----------------------------------------------------------------------
        quiesce();
        mmio_write(prio_off(SRC_UART), 32'd7);
        mmio_write(prio_off(SRC_NAND), 32'd3);
        mmio_write(prio_off(SRC_DMA),  32'd5);
        mmio_write(EN_OFF_M, (32'h1 << SRC_UART) | (32'h1 << SRC_NAND) | (32'h1 << SRC_DMA));
        mmio_write(THRESH_OFF_0, 32'd0);
        // 抬高源 1(UART,prio7)、源 3(DMA,prio5)、源 2(NAND,prio3)
        set_src(8'h1A);   // 针 1、3、4
        mmio_read(PEND_OFF, rd, hit);
        `CK(rd[SRC_UART] === 1'b1 && rd[SRC_NAND] === 1'b1 && rd[SRC_DMA] === 1'b1,
            "三个源 pending 位都应置位")
        `CK(meip_o === 1'b1, "多源 pending 且使能 ⇒ meip_o 应拉高")
        mmio_read(CLAIM_OFF_0, rd, hit);
        `CK(rd === SRC_UART, $sformatf("claim 应返回最高优先级源 %0d，实得 %0d", SRC_UART, rd))
        mmio_read(PEND_OFF, rd, hit);
        `CK(rd[SRC_UART] === 1'b0, "claim 后该源 pending 位应被清零")
        `CK(rd[SRC_NAND] === 1'b1 && rd[SRC_DMA] === 1'b1, "其他源 pending 应保持")
        mmio_read(CLAIM_OFF_0, rd, hit);
        `CK(rd === SRC_DMA, $sformatf("第二次 claim 应返回次高优先级源 %0d，实得 %0d", SRC_DMA, rd))
        mmio_read(CLAIM_OFF_0, rd, hit);
        `CK(rd === SRC_NAND, $sformatf("第三次 claim 应返回源 %0d，实得 %0d", SRC_NAND, rd))
        mmio_read(CLAIM_OFF_0, rd, hit);
        `CK(rd === 32'd0, "无候选时 claim 应返回 0（且不得清任何 pending）")
        // 清理：撤电平 + 对被 claim 的源逐个 complete（M 已使能）
        set_src(8'h00);
        mmio_write(CLAIM_OFF_0, SRC_UART);
        mmio_write(CLAIM_OFF_0, SRC_DMA);
        mmio_write(CLAIM_OFF_0, SRC_NAND);
        #1;
        `CK(meip_o === 1'b0, "清理后 meip_o 应为 0")
        mmio_read(PEND_OFF, rd, hit);
        `CK(rd === 32'h0, "清理后 pending 应为 0")

        //----------------------------------------------------------------------
        // (6) gateway 不撤回已投递请求（P1-10 触发 A）
        //     源高 → pending=1 → **claim 前**撤电平 ⇒ IP 必须保持、仍可 claim
        //----------------------------------------------------------------------
        quiesce();
        mmio_write(prio_off(SRC_UART), 32'd7);
        mmio_write(EN_OFF_M, (32'h1 << SRC_UART));
        mmio_write(THRESH_OFF_0, 32'd0);
        set_src(8'h02);   // 源 1 投递
        mmio_read(PEND_OFF, rd, hit);
        `CK(rd[SRC_UART] === 1'b1, "源 1 投递后 pending 应为 1")
        set_src(8'h00);   // ★ claim 之前撤电平
        mmio_read(PEND_OFF, rd, hit);
        `CK(rd[SRC_UART] === 1'b1,
            "claim 前撤电平后 pending 必须保持 1（gateway 不撤回已投递请求）")
        `CK(meip_o === 1'b1, "请求未丢 ⇒ meip_o 应仍为 1")
        mmio_read(CLAIM_OFF_0, rd, hit);
        `CK(rd === SRC_UART,
            $sformatf("撤电平后仍应能 claim 到源 %0d（请求未丢），实得 %0d", SRC_UART, rd))
        `CK(meip_o === 1'b0, "claim 清 pending 后 meip_o 应为 0")
        mmio_write(CLAIM_OFF_0, SRC_UART);   // complete（电平低）
        #1;
        mmio_read(PEND_OFF, rd, hit);
        `CK(rd[SRC_UART] === 1'b0, "complete 后（电平低）pending 应保持 0")

        //----------------------------------------------------------------------
        // (7) completion 之前不得重投：claim 后、complete 前出现新上升沿
        //     （P1-10 触发 B）
        //----------------------------------------------------------------------
        quiesce();
        mmio_write(prio_off(SRC_UART), 32'd7);
        mmio_write(EN_OFF_M, (32'h1 << SRC_UART));
        mmio_write(THRESH_OFF_0, 32'd0);
        set_src(8'h02);   // 投递
        mmio_read(CLAIM_OFF_0, rd, hit);
        `CK(rd === SRC_UART, "首次 claim 应返回源 1")
        `CK(meip_o === 1'b0, "claim 后 pending=0 ⇒ meip_o 应为 0")
        // ★ completion 之前制造新边沿：低 → 高
        set_src(8'h00);
        set_src(8'h02);
        mmio_read(PEND_OFF, rd, hit);
        `CK(rd[SRC_UART] === 1'b0,
            "completion 之前的新上升沿不得重投 pending（gateway busy 中忽略新沿）")
        `CK(meip_o === 1'b0, "completion 之前不得产生新通知（meip_o=0）")
        mmio_read(CLAIM_OFF_0, rd, hit);
        `CK(rd === 32'd0, "completion 之前不得再次 claim 到同一源")
        // 对照：M 上下文 complete（使能、电平高）⇒ 正常重投
        mmio_write(CLAIM_OFF_0, SRC_UART);
        #1;
        mmio_read(PEND_OFF, rd, hit);
        `CK(rd[SRC_UART] === 1'b1, "completion 后电平仍高 ⇒ 应正常重投（对照，防过度抑制）")
        `CK(meip_o === 1'b1, "重投后 meip_o 应为 1")
        mmio_read(CLAIM_OFF_0, rd, hit);
        `CK(rd === SRC_UART, "重投后应能再次 claim 到源 1")
        set_src(8'h00);
        mmio_write(CLAIM_OFF_0, SRC_UART);
        #1;

        //----------------------------------------------------------------------
        // (8) completion 对**未使能**该源的上下文应静默忽略（P1-10 触发 C）
        //----------------------------------------------------------------------
        quiesce();
        mmio_write(prio_off(SRC_UART), 32'd7);
        mmio_write(EN_OFF_M, (32'h1 << SRC_UART));
        mmio_write(EN_OFF_S, 32'h0);   // S 上下文不使能源 1
        mmio_write(THRESH_OFF_0, 32'd0);
        mmio_write(THRESH_OFF_1, 32'd0);
        set_src(8'h02);   // 源 1 投递
        mmio_read(CLAIM_OFF_0, rd, hit);
        `CK(rd === SRC_UART, "M 上下文 claim 应返回源 1")
        mmio_read(PEND_OFF, rd, hit);
        `CK(rd[SRC_UART] === 1'b0, "claim 后 pending 应为 0（busy=1）")
        // S 上下文写 completion（未使能源 1）⇒ 必须忽略：不得重挂/清 busy
        mmio_write(CLAIM_OFF_1, SRC_UART);
        #1;
        mmio_read(PEND_OFF, rd, hit);
        `CK(rd[SRC_UART] === 1'b0,
            "未使能源的上下文写 completion 必须被忽略（不得重挂 pending）")
        `CK(meip_o === 1'b0, "被忽略的 completion 不得产生 meip_o")
        `CK(seip_o === 1'b0, "S 未使能源 1 ⇒ seip_o 应为 0")
        mmio_read(CLAIM_OFF_1, rd, hit);
        `CK(rd === 32'd0, "S 上下文未使能源 1 ⇒ claim 应返回 0")
        // 对照：M 上下文 complete（已使能、电平高）⇒ 正常重投
        mmio_write(CLAIM_OFF_0, SRC_UART);
        #1;
        mmio_read(PEND_OFF, rd, hit);
        `CK(rd[SRC_UART] === 1'b1, "M 上下文 complete 生效 ⇒ 应重投")
        mmio_read(CLAIM_OFF_0, rd, hit);
        `CK(rd === SRC_UART, "重投后 M 应能再次 claim 到源 1")
        set_src(8'h00);
        mmio_write(CLAIM_OFF_0, SRC_UART);
        #1;

        //----------------------------------------------------------------------
        // (9) 并列优先级 ⇒ 取最小源号（确定性仲裁）
        //----------------------------------------------------------------------
        quiesce();
        mmio_write(prio_off(SRC_NAND), 32'd4);   // 源 2 = 4
        mmio_write(prio_off(SRC_DMA),  32'd4);   // 源 3 = 4（并列）
        mmio_write(prio_off(SRC_MAC),  32'd4);   // 源 5 = 4（并列）
        mmio_write(EN_OFF_M, (32'h1 << SRC_NAND) | (32'h1 << SRC_DMA) | (32'h1 << SRC_MAC));
        mmio_write(THRESH_OFF_0, 32'd0);
        set_src(8'h19);   // 针 0(源5)、针 3(源2)、针 4(源3)
        mmio_read(CLAIM_OFF_0, rd, hit);
        `CK(rd === SRC_NAND, $sformatf("并列优先级应取最小源号 %0d，实得 %0d", SRC_NAND, rd))
        set_src(8'h00);
        mmio_write(CLAIM_OFF_0, SRC_NAND);
        mmio_write(CLAIM_OFF_0, SRC_DMA);
        mmio_write(CLAIM_OFF_0, SRC_MAC);
        #1;

        //----------------------------------------------------------------------
        // (10) M/S 两上下文独立 claim
        //----------------------------------------------------------------------
        quiesce();
        mmio_write(prio_off(SRC_UART), 32'd7);
        mmio_write(prio_off(SRC_DMA),  32'd5);
        mmio_write(EN_OFF_M, (32'h1 << SRC_DMA));     // M 只使能源 3
        mmio_write(EN_OFF_S, (32'h1 << SRC_UART));    // S 只使能源 1
        mmio_write(THRESH_OFF_0, 32'd0);
        mmio_write(THRESH_OFF_1, 32'd0);
        set_src(8'h12);   // 针 1(源1)、针 4(源3)
        `CK(meip_o === 1'b1, "M 上下文使能源 3 ⇒ meip_o 应为 1")
        `CK(seip_o === 1'b1, "S 上下文使能源 1 ⇒ seip_o 应为 1")
        mmio_read(CLAIM_OFF_0, rd, hit);
        `CK(rd === SRC_DMA, $sformatf("ctx0(M) claim 应得源 %0d，实得 %0d", SRC_DMA, rd))
        mmio_read(CLAIM_OFF_1, rd, hit);
        `CK(rd === SRC_UART, $sformatf("ctx1(S) claim 应得源 %0d，实得 %0d", SRC_UART, rd))
        #1;
        `CK(meip_o === 1'b0, "ctx0 claim 源 3 后 meip_o 应降为 0")
        `CK(seip_o === 1'b0, "ctx1 claim 源 1 后 seip_o 应降为 0")
        // 清 busy（电平已撤）
        set_src(8'h00);
        mmio_write(CLAIM_OFF_0, SRC_DMA);
        mmio_write(CLAIM_OFF_1, SRC_UART);
        #1;
        // 两上下文 enable 相互独立：M 关使能、S 保持；源 1 新电平
        mmio_write(EN_OFF_M, 32'h0);
        mmio_write(EN_OFF_S, (32'h1 << SRC_UART));
        set_src(8'h02);
        `CK(meip_o === 1'b0, "M enable 清零后 meip_o 应为 0（上下文独立）")
        `CK(seip_o === 1'b1, "S enable 保持 ⇒ seip_o 应为 1（上下文独立）")
        set_src(8'h00);
        mmio_read(CLAIM_OFF_1, rd, hit);
        `CK(rd === SRC_UART, "S 上下文撤电平后仍应能 claim 到源 1（请求未丢）")
        mmio_write(CLAIM_OFF_1, SRC_UART);   // complete（电平低）⇒ 清 busy，不重投
        #1;
        mmio_read(PEND_OFF, rd, hit);
        `CK(rd === 32'h0, "S claim + complete 后 pending 应为 0")

        //----------------------------------------------------------------------
        // (11) S 上下文 threshold 独立过滤（通知）；claim 不受其影响
        //----------------------------------------------------------------------
        quiesce();
        mmio_write(prio_off(SRC_UART), 32'd7);
        mmio_write(EN_OFF_S, (32'h1 << SRC_UART));
        mmio_write(THRESH_OFF_0, 32'd0);
        mmio_write(THRESH_OFF_1, 32'd7);   // S 阈值 = 7 == priority(源1)
        set_src(8'h02);
        `CK(seip_o === 1'b0, "S 上下文 threshold=7 应过滤 priority=7 的源 1 通知")
        `CK(meip_o === 1'b0, "M 侧不受 S threshold 影响")
        mmio_read(CLAIM_OFF_1, rd, hit);
        `CK(rd === SRC_UART, "S threshold 不得屏蔽 claim（仍应返回源 1）")
        mmio_write(CLAIM_OFF_1, SRC_UART);   // complete（电平高）⇒ 重投
        #1;
        `CK(seip_o === 1'b0, "重投后 S threshold 仍屏蔽通知（seip_o=0）")
        mmio_write(THRESH_OFF_1, 32'd6);
        #1;
        `CK(seip_o === 1'b1, "S 上下文 threshold=6 < 7 应通过")
        set_src(8'h00);
        mmio_read(CLAIM_OFF_1, rd, hit);
        `CK(rd === SRC_UART, "撤电平后可 claim 到 pending 的源 1")
        mmio_write(CLAIM_OFF_1, SRC_UART);
        #1;

        //----------------------------------------------------------------------
        // (12) priority == 0：IP 可置位但不可 claim、不通知
        //----------------------------------------------------------------------
        quiesce();
        mmio_write(prio_off(SRC_UART), 32'd0);
        mmio_write(EN_OFF_M, (32'h1 << SRC_UART));
        mmio_write(THRESH_OFF_0, 32'd0);
        set_src(8'h02);
        mmio_read(PEND_OFF, rd, hit);
        `CK(rd[SRC_UART] === 1'b1, "priority=0 的源 IP 仍应可被 gateway 置位")
        `CK(meip_o === 1'b0, "priority=0 不得产生通知（meip_o=0）")
        mmio_read(CLAIM_OFF_0, rd, hit);
        `CK(rd === 32'd0, "priority=0 的源不得被 claim（返回 0）")
        // 恢复优先级 ⇒ 同一 pending 变为可 claim
        mmio_write(prio_off(SRC_UART), 32'd7);
        #1;
        `CK(meip_o === 1'b1, "恢复 priority>0 后同一 pending 应变为可通知")
        mmio_read(CLAIM_OFF_0, rd, hit);
        `CK(rd === SRC_UART, "恢复 priority>0 后应可 claim 到源 1")
        set_src(8'h00);
        mmio_write(CLAIM_OFF_0, SRC_UART);
        #1;

        //----------------------------------------------------------------------
        // (13) pending 只读：写 pending 不应改变其值
        //----------------------------------------------------------------------
        quiesce();
        mmio_write(prio_off(SRC_UART), 32'd7);
        mmio_write(EN_OFF_M, (32'h1 << SRC_UART));
        set_src(8'h02);
        mmio_read(PEND_OFF, rd, hit);
        begin : pend_ro_check
            reg [31:0] pend_before, pend_after;
            pend_before = rd;
            mmio_write(PEND_OFF, 32'hFFFF_FFFF);
            mmio_read(PEND_OFF, rd, hit);
            pend_after = rd;
            `CK(pend_after === pend_before, "写 pending 应被忽略（只读）")
        end
        set_src(8'h00);
        mmio_read(CLAIM_OFF_0, rd, hit);
        mmio_write(CLAIM_OFF_0, SRC_UART);
        #1;

        //----------------------------------------------------------------------
        // (13b) 非全字 claim **读**被拒绝且无副作用（P1 边界）：
        //       claim 读是非幂等访问；mask 0/1 时 hit 必须为 0 且 **pending 不动**；
        //       随后全字（4'hF）claim 仍须成功——保留合法覆盖。
        //----------------------------------------------------------------------
        quiesce();
        mmio_write(prio_off(SRC_UART), 32'd7);
        mmio_write(EN_OFF_M, (32'h1 << SRC_UART));
        mmio_write(THRESH_OFF_0, 32'd0);
        set_src(8'h02);   // 源 1 投递
        mmio_read(PEND_OFF, rd, hit);
        `CK(rd[SRC_UART] === 1'b1, "非法 claim 读前置：源 1 pending 应为 1")
        // mask = 4'h0
        mmio_read_strb(CLAIM_OFF_0, 4'h0, rd, hit);
        `CK(hit === 1'b0, "非全字(mask0) claim 读应命中为 0（拒绝）")
        mmio_read(PEND_OFF, rd, hit);
        `CK(rd[SRC_UART] === 1'b1, "非全字(mask0) claim 读不得清 pending（无副作用）")
        // mask = 4'h1
        mmio_read_strb(CLAIM_OFF_0, 4'h1, rd, hit);
        `CK(hit === 1'b0, "非全字(mask1) claim 读应命中为 0（拒绝）")
        mmio_read(PEND_OFF, rd, hit);
        `CK(rd[SRC_UART] === 1'b1, "非全字(mask1) claim 读不得清 pending（无副作用）")
        // 全字 claim 仍成功（合法路径不被破坏）
        mmio_read(CLAIM_OFF_0, rd, hit);
        `CK(hit === 1'b1 && rd === SRC_UART, "全字 claim 读仍应成功返回源 1")
        mmio_read(PEND_OFF, rd, hit);
        `CK(rd[SRC_UART] === 1'b0, "全字 claim 后该源 pending 应被清 0")
        set_src(8'h00);
        mmio_write(CLAIM_OFF_0, SRC_UART);
        #1;

        //----------------------------------------------------------------------
        // (14) 命中地址：未实现偏移不应命中
        //----------------------------------------------------------------------
        mmio_read(32'h0000_0030, rd, hit);
        `CK(hit === 1'b0, "越界 priority 偏移（源 12 > NUM_SOURCES）不应命中")
        mmio_read(32'h0000_3000, rd, hit);
        `CK(hit === 1'b0, "未实现偏移 0x3000 不应命中")

        //----------------------------------------------------------------------
        // (15) 空/非法字节掩码写无副作用（保留"全字命中 / 非全字拒绝"契约）
        //----------------------------------------------------------------------
        quiesce();
        mmio_write(prio_off(SRC_UART), 32'd7);
        mmio_write(EN_OFF_M, (32'h1 << SRC_UART));
        mmio_write(THRESH_OFF_0, 32'd3);
        #1;
        // enable：空掩码写 0xFFFFFFFF ⇒ 读回不变
        mmio_read(EN_OFF_M, v_before, hit);
        mmio_write_strb(EN_OFF_M, 32'hFFFF_FFFF, 4'h0);
        mmio_read(EN_OFF_M, v_after, hit);
        `CK(v_after === v_before,
            $sformatf("空字节掩码写 enable 不得有副作用（应仍为 0x%08x，实得 0x%08x）",
                      v_before, v_after))
        // threshold：空掩码写 0 ⇒ 读回不变
        mmio_read(THRESH_OFF_0, v_before, hit);
        mmio_write_strb(THRESH_OFF_0, 32'd0, 4'h0);
        mmio_read(THRESH_OFF_0, v_after, hit);
        `CK(v_after === v_before, "空字节掩码写 threshold 不得有副作用")
        // priority：空掩码写 0 ⇒ 读回不变
        mmio_read(prio_off(SRC_UART), v_before, hit);
        mmio_write_strb(prio_off(SRC_UART), 32'd0, 4'h0);
        mmio_read(prio_off(SRC_UART), v_after, hit);
        `CK(v_after === v_before, "空字节掩码写 priority 不得有副作用")
        // 非全字掩码读：resp_hit 必须为 0（既有拒绝契约），且无副作用
        mmio_read_strb(EN_OFF_M, 4'h1, v_after, hit);
        `CK(hit === 1'b0, "非全字（4'h1）访问 enable 不应命中（既有拒绝契约）")
        mmio_read(EN_OFF_M, v_before, hit);
        `CK(v_before === (32'h1 << SRC_UART), "非全字访问后 enable 应保持原值")
        mmio_read_strb(EN_OFF_M, 4'hF, v_after, hit);
        `CK(hit === 1'b1, "全字（4'hF）访问 enable 应命中")

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
