//==============================================================================
// sim/functional/tb_devices_semantics.sv
//   —— CLINT / PLIC 设备语义**功能级**正反证用例（单一顶层，供 test_devices.sh
//      在当前源码与冻结基线 201acf61 上分别编译运行）
//==============================================================================
// 目的 : 用**同一份** TB 对两个源码根（DUT_ROOT）做对照：
//          · 当前（已修）源码 ⇒ 全部通过，打印唯一 `FUNCTIONAL_DEVICES: PASS`；
//          · 冻结基线 201acf61 ⇒ 定向缺陷标签必须触发 FAIL（反向 oracle）。
//        本 TB 只例化 rtl/clint/clint.v 与 rtl/plic/plic.v（不涉及其它 RTL 域）。
//
// 规范锚点（只作依据，不在本文件中执行任何外部文本）:
//   · ISA `#norm:mtimeintrpending`（riscv-isa-manual/src/priv/machine.adoc）:
//     "A machine timer interrupt becomes pending whenever mtime contains a value
//      greater than or equal to mtimecmp, treating the values as unsigned
//      integers."  ⇒ mtime == mtimecmp 必须挂起。
//   · PLIC 规范（https://raw.githubusercontent.com/riscv/riscv-plic-spec/master/riscv-plic.adoc）:
//     - gateway "does not have the facility to retract an interrupt request once
//       forwarded to the PLIC core" ⇒ claim 前撤电平不得丢请求；
//     - gateway 收到 completion 前不再转发 ⇒ completion 前新沿不得重投；
//     - "the claim operation is not affected by the setting of the priority
//       threshold register" ⇒ claim 不受 threshold 过滤；
//     - "If the completion ID does not match an interrupt source that is currently
//       enabled for the target, the completion is silently ignored."
//
// 标签口径 : 失败行统一为 `DEVICES FAIL [TAG]: msg`。
//   · 缺陷标签（旧基线必须触发）: MTIP_EQ / PLIC_CLAIM_THRESH / PLIC_RETRACT /
//     PLIC_REEDGE / PLIC_COMP_EN / PLIC_CLAIM_STROBE / PLIC_STROBE / CLINT_STROBE；
//   · 合法控制标签（两实现都应通过，勿作区分）: 前缀 `CTRL_`。
//
// 判定   : 任一检查失败 ⇒ 末尾 $fatal(1)，**绝不**打印 PASS；
//          全部通过才打印 `FUNCTIONAL_DEVICES_VECTORS: <n>` 与
//          唯一整行 `FUNCTIONAL_DEVICES: PASS`。
//   ★ 末尾另以冻结规格 SPEC_VECTORS=55 自判 checks_seen（防 Standalone 少跑），
//     与 sim/functional/test_devices.sh 的 SPEC_VECTORS 必须同步。
// 顶层   : tb_devices_semantics
//==============================================================================
`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"

module tb_devices_semantics;

    //--------------------------------------------------------------------------
    // 0. 检查计数器 + 失败宏（fail-closed）
    //--------------------------------------------------------------------------
    integer checks_seen   = 0;
    integer checks_failed = 0;

    `define DF(cond, tag, msg)                                                  \
        begin                                                                   \
            checks_seen = checks_seen + 1;                                      \
            if (!(cond)) begin                                                  \
                checks_failed = checks_failed + 1;                              \
                $display("DEVICES FAIL [%s]: %s (t=%0t)", tag, msg, $time);     \
            end                                                                 \
        end

    //--------------------------------------------------------------------------
    // 1. 地址常量
    //--------------------------------------------------------------------------
    localparam [31:0] MSIP      = `RV32GC_CLINT_MSIP_OFF;        // 0x0000
    localparam [31:0] MTIMECMP  = `RV32GC_CLINT_MTIMECMP_OFF;    // 0x4000
    localparam [31:0] MTIMECMPH = `RV32GC_CLINT_MTIMECMPH_OFF;   // 0x4004
    localparam [31:0] MTIME     = `RV32GC_CLINT_MTIME_OFF;       // 0xBFF8
    localparam [31:0] MTIMEH    = `RV32GC_CLINT_MTIMEH_OFF;      // 0xBFFC
    localparam [31:0] T         = 32'h0000_1234;

    localparam [31:0] PRIO    = `RV32GC_PLIC_PRIORITY_OFF;       // 0x0000
    localparam [31:0] PEND    = `RV32GC_PLIC_PENDING_OFF;        // 0x1000
    localparam [31:0] EN_M    = `RV32GC_PLIC_ENABLE_OFF;         // 0x2000
    localparam [31:0] EN_S    = `RV32GC_PLIC_ENABLE_OFF + 32'h80;// 0x2080
    localparam [31:0] TH_0    = `RV32GC_PLIC_THRESHOLD_OFF;      // 0x200000
    localparam [31:0] TH_1    = `RV32GC_PLIC_THRESHOLD_OFF + 32'h1000;
    localparam [31:0] CLAIM_0 = `RV32GC_PLIC_CLAIM_OFF;          // 0x200004
    localparam [31:0] CLAIM_1 = `RV32GC_PLIC_CLAIM_OFF + 32'h1000;

    localparam integer SRC_UART = 1, SRC_NAND = 2, SRC_DMA = 3, SRC_SPI = 4, SRC_MAC = 5;
    localparam integer PIN_UART = 1, PIN_SPI = 2, PIN_NAND = 3, PIN_DMA = 4, PIN_MAC = 0;

    // 冻结规格（TB 本体自判，与 sim/functional/test_devices.sh 的 SPEC_VECTORS 同步）：
    //   checks_seen 必须恰等于本值，防止 Standalone 少跑若干检查仍自洽通过。
    localparam integer SPEC_VECTORS = 55;

    //--------------------------------------------------------------------------
    // 2. 时钟 / 复位
    //--------------------------------------------------------------------------
    reg aclk    = 1'b0;
    reg aresetn = 1'b0;
    always #15.0 aclk = ~aclk;   // 30 ns 周期

    //--------------------------------------------------------------------------
    // 3. CLINT 例化（仅核内总线侧端口）
    //--------------------------------------------------------------------------
    reg         c_valid = 1'b0, c_write = 1'b0;
    reg  [31:0] c_addr  = 32'd0, c_wdata = 32'd0;
    reg  [3:0]  c_strb  = 4'hF;
    wire [31:0] c_rdata;
    wire        c_hit, msip_o, mtip_o;

    clint u_clint (
        .aclk(aclk), .aresetn(aresetn),
        .req_valid(c_valid), .req_write(c_write), .req_addr(c_addr),
        .req_wdata(c_wdata), .req_wstrb(c_strb),
        .resp_rdata(c_rdata), .resp_hit(c_hit),
        .msip_o(msip_o), .mtip_o(mtip_o)
    );

    //--------------------------------------------------------------------------
    // 4. PLIC 例化（仅核内总线侧端口 + 平台中断源）
    //--------------------------------------------------------------------------
    reg  [`RV32GC_INTRPT_WIDTH-1:0]   src     = 8'h00;
    reg  [`RV32GC_INTRPT_WIDTH*4-1:0] src_map =
            { 3'd0, 3'd0, 3'd0,
              4'd3,    // 针 4 = DMA  ⇒ 源 3
              4'd2,    // 针 3 = NAND ⇒ 源 2
              4'd4,    // 针 2 = SPI  ⇒ 源 4
              4'd1,    // 针 1 = UART ⇒ 源 1
              4'd5 };  // 针 0 = MAC  ⇒ 源 5
    reg         p_valid = 1'b0, p_write = 1'b0;
    reg  [31:0] p_addr  = 32'd0, p_wdata = 32'd0;
    reg  [3:0]  p_strb  = 4'hF;
    wire [31:0] p_rdata;
    wire        p_hit, meip_o, seip_o;

    plic u_plic (
        .aclk(aclk), .aresetn(aresetn),
        .src(src), .intrpt_src_map(src_map),
        .req_valid(p_valid), .req_write(p_write), .req_addr(p_addr),
        .req_wdata(p_wdata), .req_wstrb(p_strb),
        .resp_rdata(p_rdata), .resp_hit(p_hit),
        .meip_o(meip_o), .seip_o(seip_o)
    );

    //--------------------------------------------------------------------------
    // 5. 任务：CLINT 总线访问
    //--------------------------------------------------------------------------
    task automatic cw(input [31:0] off, input [31:0] d);
        begin
            @(negedge aclk);
            c_addr = off; c_wdata = d; c_strb = 4'hF; c_write = 1'b1; c_valid = 1'b1;
            @(posedge aclk); #1;
            c_valid = 1'b0; c_write = 1'b0;
        end
    endtask

    task automatic cws(input [31:0] off, input [31:0] d, input [3:0] s);
        begin
            @(negedge aclk);
            c_addr = off; c_wdata = d; c_strb = s; c_write = 1'b1; c_valid = 1'b1;
            @(posedge aclk); #1;
            c_valid = 1'b0; c_write = 1'b0;
        end
    endtask

    task automatic cr(input [31:0] off, output [31:0] d, output h);
        begin
            @(negedge aclk);
            c_addr = off; c_wdata = 32'd0; c_strb = 4'hF; c_write = 1'b0; c_valid = 1'b1;
            #1; d = c_rdata; h = c_hit;
            @(posedge aclk); #1;
            c_valid = 1'b0;
        end
    endtask

    // 把 mtime 钉在 v 一拍（wr_mtime 优先于自增）；返回时 mtime_r == v
    task automatic pin_mtime(input [31:0] v);
        begin
            @(negedge aclk);
            c_addr = MTIME; c_wdata = v; c_strb = 4'hF; c_write = 1'b1; c_valid = 1'b1;
            @(posedge aclk); #1;
        end
    endtask

    //--------------------------------------------------------------------------
    // 6. 任务：PLIC 总线访问
    //--------------------------------------------------------------------------
    function [31:0] prio(input integer n);
        prio = PRIO + (n * 4);
    endfunction

    task automatic pw(input [31:0] off, input [31:0] d);
        begin
            @(negedge aclk);
            p_addr = off; p_wdata = d; p_strb = 4'hF; p_write = 1'b1; p_valid = 1'b1;
            @(posedge aclk); #1;
            p_valid = 1'b0; p_write = 1'b0;
        end
    endtask

    task automatic pws(input [31:0] off, input [31:0] d, input [3:0] s);
        begin
            @(negedge aclk);
            p_addr = off; p_wdata = d; p_strb = s; p_write = 1'b1; p_valid = 1'b1;
            @(posedge aclk); #1;
            p_valid = 1'b0; p_write = 1'b0;
        end
    endtask

    task automatic pr(input [31:0] off, output [31:0] d, output h);
        begin
            @(negedge aclk);
            p_addr = off; p_wdata = 32'd0; p_strb = 4'hF; p_write = 1'b0; p_valid = 1'b1;
            #1; d = p_rdata; h = p_hit;
            @(posedge aclk); #1;
            p_valid = 1'b0;
        end
    endtask

    // 带显式字节使能的读（用于"非全字 claim 读被拒绝且无副作用"回归）
    task automatic prs(input [31:0] off, input [3:0] s, output [31:0] d, output h);
        begin
            @(negedge aclk);
            p_addr = off; p_wdata = 32'd0; p_strb = s; p_write = 1'b0; p_valid = 1'b1;
            #1; d = p_rdata; h = p_hit;
            @(posedge aclk); #1;
            p_valid = 1'b0;
        end
    endtask

    task automatic set_src(input [7:0] mask);
        begin
            @(negedge aclk);
            src = mask;
            repeat (3) @(posedge aclk);
            #1;
        end
    endtask

    //--------------------------------------------------------------------------
    // 7. 场景前置：双 DUT 复位
    //--------------------------------------------------------------------------
    task automatic reset_duts;
        begin
            aresetn = 1'b0;
            src     = 8'h00;
            c_valid = 1'b0; c_write = 1'b0; c_strb = 4'hF;
            p_valid = 1'b0; p_write = 1'b0; p_strb = 4'hF;
            repeat (4) @(posedge aclk);
            #1;
            @(negedge aclk);
            aresetn = 1'b1;
            repeat (2) @(posedge aclk);
            #1;
        end
    endtask

    //--------------------------------------------------------------------------
    // 8. 主流程（每个场景前复位，保证新旧实现的分歧不跨场景串扰）
    //--------------------------------------------------------------------------
    reg [31:0] rd;
    reg        hit;
    integer    k;

    initial begin
        $display("---- tb_devices_semantics: CLINT/PLIC 语义功能验证 ----");

        //======================================================================
        // S1: CLINT —— msip / mtimecmp 读回 / MTIP 边界（含相等缺陷）
        //======================================================================
        reset_duts();
        cw(MSIP, 32'h0000_0001); #1;
        `DF(msip_o === 1'b1, "CTRL_MSIP", "msip 写 1 应置位 msip_o")
        cw(MSIP, 32'h0000_0000); #1;
        `DF(msip_o === 1'b0, "CTRL_MSIP", "msip 写 0 应清位 msip_o")
        // mtimecmp = T（高半 0），读回确认
        cw(MTIMECMPH, 32'h0000_0000);
        cw(MTIMECMP,  T);
        cr(MTIMECMP, rd, hit);  `DF(hit === 1'b1 && rd === T, "CTRL_CLINT_RB", "mtimecmp 低字读回应为 T")
        cr(MTIMECMPH, rd, hit); `DF(rd === 32'h0000_0000, "CTRL_CLINT_RB", "mtimecmp 高字读回应为 0")
        // mtime = T-1（连续 3 拍）⇒ MTIP 必须 0
        for (k = 0; k < 3; k = k + 1) begin
            pin_mtime(T - 32'd1);
            `DF(mtip_o === 1'b0, "CTRL_MTIP_LT", "mtime < mtimecmp 时 MTIP 应为 0")
        end
        cr(MTIME, rd, hit); `DF(rd === (T - 32'd1), "CTRL_CLINT_RB", "mtime 应精确读回 T-1")
        // mtime = T（连续 3 拍）⇒ ISA 要求挂起（旧实现 `>` 在此 FAIL）
        for (k = 0; k < 3; k = k + 1) begin
            pin_mtime(T);
            `DF(mtip_o === 1'b1, "MTIP_EQ",
                "mtime == mtimecmp 时 MTIP 必须为 1（ISA mtimeintrpending）")
        end
        // mtime = T+1（连续 3 拍）⇒ MTIP 必须 1
        for (k = 0; k < 3; k = k + 1) begin
            pin_mtime(T + 32'd1);
            `DF(mtip_o === 1'b1, "CTRL_MTIP_GT", "mtime > mtimecmp 时 MTIP 应为 1")
        end
        c_valid = 1'b0; c_write = 1'b0;
        // 空字节掩码写 CLINT 不得有副作用（旧实现无 strobe 门控 ⇒ FAIL）
        cw(MTIMECMPH, 32'h0000_0000);
        cw(MTIMECMP,  T + 32'h100);
        cws(MTIMECMP, T - 32'h100, 4'h0);
        cr(MTIMECMP, rd, hit);
        `DF(rd === (T + 32'h100), "CLINT_STROBE",
            "空字节掩码写 mtimecmp 不得产生副作用（旧实现会改写）")
        // 地址映射控制
        cr(MSIP, rd, hit); `DF(hit === 1'b1, "CTRL_MAP", "msip 地址应命中")
        cr(32'h0000_0004, rd, hit); `DF(hit === 1'b0, "CTRL_MAP", "未实现偏移 0x4 不应命中")

        //======================================================================
        // S2: PLIC 合法控制（priority / enable / claim 顺序 / M-S 独立）
        //======================================================================
        reset_duts();
        pw(prio(SRC_UART), 32'd7);
        pr(prio(SRC_UART), rd, hit);
        `DF(hit === 1'b1 && rd === 32'd7, "CTRL_PRIO", "priority(源1) 读回应为 7")
        pr(PRIO, rd, hit); `DF(hit === 1'b0, "CTRL_MAP", "源 0 priority 地址不应命中")
        pw(EN_M, 32'hFFFF_FFFF);
        pr(EN_M, rd, hit);
        `DF(rd[0] === 1'b0 && rd[SRC_UART] === 1'b1, "CTRL_ENABLE", "enable bit0 应恒 0、其余可写")
        // claim 顺序：threshold=0 时两实现语义一致
        pw(prio(SRC_UART), 32'd7);
        pw(prio(SRC_DMA),  32'd5);
        pw(prio(SRC_NAND), 32'd3);
        pw(EN_M, (32'h1 << SRC_UART) | (32'h1 << SRC_DMA) | (32'h1 << SRC_NAND));
        pw(TH_0, 32'd0);
        set_src(8'h1A);   // 针 1(源1)、针 3(源2)、针 4(源3)
        pr(CLAIM_0, rd, hit); `DF(rd === SRC_UART, "CTRL_CLAIM_ORDER", "claim 应返回最高优先级源 1")
        pr(CLAIM_0, rd, hit); `DF(rd === SRC_DMA,  "CTRL_CLAIM_ORDER", "第二次 claim 应返回源 3")
        pr(CLAIM_0, rd, hit); `DF(rd === SRC_NAND, "CTRL_CLAIM_ORDER", "第三次 claim 应返回源 2")
        pr(CLAIM_0, rd, hit); `DF(rd === 32'd0,    "CTRL_CLAIM_ORDER", "无候选 claim 应返回 0")
        set_src(8'h00);
        // M/S 上下文独立
        reset_duts();
        pw(prio(SRC_UART), 32'd7);
        pw(prio(SRC_DMA),  32'd5);
        pw(EN_M, (32'h1 << SRC_DMA));
        pw(EN_S, (32'h1 << SRC_UART));
        pw(TH_0, 32'd0); pw(TH_1, 32'd0);
        set_src(8'h12);   // 针 1(源1)、针 4(源3)
        `DF(meip_o === 1'b1, "CTRL_CTX", "M 上下文使能源 3 ⇒ meip_o 应为 1")
        `DF(seip_o === 1'b1, "CTRL_CTX", "S 上下文使能源 1 ⇒ seip_o 应为 1")
        pr(CLAIM_0, rd, hit); `DF(rd === SRC_DMA,  "CTRL_CTX", "ctx0(M) claim 应得源 3")
        pr(CLAIM_1, rd, hit); `DF(rd === SRC_UART, "CTRL_CTX", "ctx1(S) claim 应得源 1")
        set_src(8'h00);

        //======================================================================
        // S3: claim 不得受 threshold 过滤（缺陷 PLIC_CLAIM_THRESH）
        //======================================================================
        reset_duts();
        pw(prio(SRC_UART), 32'd7);
        pw(EN_M, (32'h1 << SRC_UART));
        pw(TH_0, 32'd7);   // == priority(源1)
        set_src(8'h02);
        `DF(meip_o === 1'b0, "CTRL_THRESH_NOTIFY", "threshold == priority 时通知应被屏蔽")
        pr(CLAIM_0, rd, hit);
        `DF(rd === SRC_UART, "PLIC_CLAIM_THRESH",
            "claim 不得被 threshold 屏蔽（应返回源 1；旧实现返回 0）")
        pr(PEND, rd, hit);
        `DF(rd[SRC_UART] === 1'b0, "PLIC_CLAIM_THRESH", "claim 后该源 pending 应被清 0")
        set_src(8'h00);
        pw(CLAIM_0, SRC_UART);

        //======================================================================
        // S4: gateway 不撤回已投递请求（缺陷 PLIC_RETRACT）
        //======================================================================
        reset_duts();
        pw(prio(SRC_UART), 32'd7);
        pw(EN_M, (32'h1 << SRC_UART));
        pw(TH_0, 32'd0);
        set_src(8'h02);
        pr(PEND, rd, hit); `DF(rd[SRC_UART] === 1'b1, "CTRL_PEND_SET", "投递后 pending 应为 1")
        set_src(8'h00);    // ★ claim 之前撤电平
        pr(PEND, rd, hit);
        `DF(rd[SRC_UART] === 1'b1, "PLIC_RETRACT",
            "claim 前撤电平后 pending 必须保持 1（不得撤回已投递请求）")
        `DF(meip_o === 1'b1, "PLIC_RETRACT", "请求未丢 ⇒ meip_o 应仍为 1")
        pr(CLAIM_0, rd, hit);
        `DF(rd === SRC_UART, "PLIC_RETRACT", "撤电平后仍应能 claim 到源 1（请求未丢）")
        pw(CLAIM_0, SRC_UART);

        //======================================================================
        // S5: completion 之前不得重投（缺陷 PLIC_REEDGE）
        //======================================================================
        reset_duts();
        pw(prio(SRC_UART), 32'd7);
        pw(EN_M, (32'h1 << SRC_UART));
        pw(TH_0, 32'd0);
        set_src(8'h02);
        pr(CLAIM_0, rd, hit); `DF(rd === SRC_UART, "CTRL_CLAIM_FIRST", "首次 claim 应返回源 1")
        // completion 之前制造新边沿：低 → 高
        set_src(8'h00);
        set_src(8'h02);
        pr(PEND, rd, hit);
        `DF(rd[SRC_UART] === 1'b0, "PLIC_REEDGE",
            "completion 之前的新上升沿不得重投 pending（旧实现会重投）")
        `DF(meip_o === 1'b0, "PLIC_REEDGE", "completion 之前不得产生新通知")
        pr(CLAIM_0, rd, hit);
        `DF(rd === 32'd0, "PLIC_REEDGE", "completion 之前不得再次 claim 到同一源")
        set_src(8'h00);
        pw(CLAIM_0, SRC_UART);

        //======================================================================
        // S6: 未使能源的上下文写 completion 必须被忽略（缺陷 PLIC_COMP_EN）
        //======================================================================
        reset_duts();
        pw(prio(SRC_UART), 32'd7);
        pw(EN_M, (32'h1 << SRC_UART));
        pw(EN_S, 32'h0000_0000);   // S 不使能源 1
        pw(TH_0, 32'd0); pw(TH_1, 32'd0);
        set_src(8'h02);
        pr(CLAIM_0, rd, hit); `DF(rd === SRC_UART, "CTRL_CLAIM_FIRST", "M 上下文 claim 应返回源 1")
        pr(PEND, rd, hit);    `DF(rd[SRC_UART] === 1'b0, "CTRL_PEND_CLR", "claim 后 pending 应为 0")
        pw(CLAIM_1, SRC_UART);   // S 未使能 ⇒ 必须静默忽略
        #1;
        pr(PEND, rd, hit);
        `DF(rd[SRC_UART] === 1'b0, "PLIC_COMP_EN",
            "未使能源的上下文写 completion 必须被忽略（旧实现会重挂 pending）")
        `DF(meip_o === 1'b0, "PLIC_COMP_EN", "被忽略的 completion 不得产生 meip_o")
        pr(CLAIM_1, rd, hit); `DF(rd === 32'd0, "CTRL_CTX", "S 未使能源 1 ⇒ claim 应返回 0")
        set_src(8'h00);
        pw(CLAIM_0, SRC_UART);

        //======================================================================
        // S7: 空/非法字节掩码写无副作用（缺陷 PLIC_STROBE）
        //======================================================================
        reset_duts();
        pw(prio(SRC_UART), 32'd7);
        pw(EN_M, (32'h1 << SRC_UART));
        pw(TH_0, 32'd3);
        #1;
        pr(EN_M, rd, hit);
        begin : strobe_en
            reg [31:0] v_b, v_a;
            v_b = rd;
            pws(EN_M, 32'hFFFF_FFFF, 4'h0);
            pr(EN_M, rd, hit); v_a = rd;
            `DF(v_a === v_b, "PLIC_STROBE",
                "空字节掩码写 enable 不得产生副作用（旧实现会改写）")
        end
        pr(TH_0, rd, hit);
        begin : strobe_th
            reg [31:0] v_b, v_a;
            v_b = rd;
            pws(TH_0, 32'd0, 4'h0);
            pr(TH_0, rd, hit); v_a = rd;
            `DF(v_a === v_b, "PLIC_STROBE", "空字节掩码写 threshold 不得产生副作用")
        end
        pr(prio(SRC_UART), rd, hit);
        begin : strobe_prio
            reg [31:0] v_b, v_a;
            v_b = rd;
            pws(prio(SRC_UART), 32'd0, 4'h0);
            pr(prio(SRC_UART), rd, hit); v_a = rd;
            `DF(v_a === v_b, "PLIC_STROBE", "空字节掩码写 priority 不得产生副作用")
        end
        // 非全字访问仍应被拒绝（既有契约，两实现一致）
        begin : strobe_reject
            reg [31:0] d; reg h;
            @(negedge aclk);
            p_addr = EN_M; p_wdata = 32'd0; p_strb = 4'h1; p_write = 1'b0; p_valid = 1'b1;
            #1; d = p_rdata; h = p_hit;
            @(posedge aclk); #1; p_valid = 1'b0;
            `DF(h === 1'b0, "CTRL_STRB_REJECT", "非全字（4'h1）访问 enable 不应命中")
        end

        //======================================================================
        // S8: 非全字 claim **读**被拒绝且无副作用（缺陷 PLIC_CLAIM_STROBE）
        //     claim 读是非幂等访问（读即清 pending）：mask 0/1 时 hit 必须为 0
        //     且 pending 不动。控制项（合法全字 claim 仍成功）单独用**干净状态**
        //     复跑，避免被旧实现的非法读副作用污染而误挂 CTRL_。
        //======================================================================
        reset_duts();
        pw(prio(SRC_UART), 32'd7);
        pw(EN_M, (32'h1 << SRC_UART));
        pw(TH_0, 32'd0);
        set_src(8'h02);
        pr(PEND, rd, hit);
        `DF(rd[SRC_UART] === 1'b1, "CTRL_PEND_SET", "非法 claim 读前置：源 1 pending 应为 1")
        prs(CLAIM_0, 4'h0, rd, hit);
        `DF(hit === 1'b0, "PLIC_CLAIM_STROBE", "非全字(mask0) claim 读应命中为 0（拒绝）")
        pr(PEND, rd, hit);
        `DF(rd[SRC_UART] === 1'b1, "PLIC_CLAIM_STROBE",
            "非全字(mask0) claim 读不得清 pending（旧实现会误清）")
        prs(CLAIM_0, 4'h1, rd, hit);
        `DF(hit === 1'b0, "PLIC_CLAIM_STROBE", "非全字(mask1) claim 读应命中为 0（拒绝）")
        pr(PEND, rd, hit);
        `DF(rd[SRC_UART] === 1'b1, "PLIC_CLAIM_STROBE",
            "非全字(mask1) claim 读不得清 pending（旧实现会误清）")
        // ---- 合法路径控制（干净状态独立复跑；两实现都应绿）----
        reset_duts();
        pw(prio(SRC_UART), 32'd7);
        pw(EN_M, (32'h1 << SRC_UART));
        pw(TH_0, 32'd0);
        set_src(8'h02);
        pr(CLAIM_0, rd, hit);
        `DF(hit === 1'b1 && rd === SRC_UART, "CTRL_CLAIM_FULL", "全字 claim 读仍应成功返回源 1")
        pr(PEND, rd, hit);
        `DF(rd[SRC_UART] === 1'b0, "CTRL_CLAIM_CLEAR", "全字 claim 后该源 pending 应被清 0")
        set_src(8'h00);
        pw(CLAIM_0, SRC_UART);

        //======================================================================
        // 汇总（fail-closed）
        //======================================================================
        // 固定 N 自判（防 Standalone 少跑）：checks_seen 必须等于冻结规格 SPEC_VECTORS
        if (checks_seen != SPEC_VECTORS) begin
            checks_failed = checks_failed + 1;
            $display("DEVICES FAIL [VECTOR_COUNT]: checks_seen=%0d expect=%0d",
                     checks_seen, SPEC_VECTORS);
        end
        if (checks_seen == 0) begin
            $display("FUNCTIONAL_DEVICES: FAIL (未执行任何检查)");
            $fatal(1, "FUNCTIONAL_DEVICES FAIL");
        end
        $display("FUNCTIONAL_DEVICES_VECTORS: %0d", checks_seen);
        if (checks_failed != 0) begin
            $display("FUNCTIONAL_DEVICES: FAIL %0d/%0d", checks_failed, checks_seen);
            $fatal(1, "FUNCTIONAL_DEVICES FAIL");
        end
        $display("FUNCTIONAL_DEVICES: PASS");
        $finish;
    end

    // 看门狗
    initial begin
        #4_000_000;
        $display("DEVICES FAIL [TIMEOUT]: 超时（看门狗触发）");
        $fatal(1, "FUNCTIONAL_DEVICES FAIL");
    end

endmodule
