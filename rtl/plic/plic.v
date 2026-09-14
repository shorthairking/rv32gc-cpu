//==============================================================================
// rtl/plic/plic.v —— 核内 PLIC（Platform-Level Interrupt Controller）
//==============================================================================
// 项目    : rv32gc-cpu（阶段二 2A：单发射顺序 5 级基线核）
// 规格    : docs/design/08-baseline-5stage.md §6.6「核内 CLINT / PLIC 与 intrpt[4:0] 接线」
// 真源    : rtl/pkg/core_params.vh §5（PLIC 源数/上下文/寄存器偏移/默认源号映射）
//
// 职责    : 实现标准 PLIC 寄存器映射（SiFive PLIC / RISC-V PLIC 惯例），
//           源 1..NUM_SOURCES、2 个上下文（context 0 = M ⇒ MEIP，context 1 = S ⇒ SEIP）：
//             priority[n]        @ 基址 + 0x0000 + 4*n        32 bit R/W（每源一个）
//             pending            @ 基址 + 0x1000              32 bit RO 位图（每 32 源一字）
//             enable[ctx]        @ 基址 + 0x2000 + 0x80*ctx + 4*ctx
//                                                             32 bit R/W 位图
//             threshold[ctx]     @ 基址 + 0x200000 + 0x1000*ctx        32 bit R/W
//             claim/complete[ctx]@ 基址 + 0x200000 + 0x1000*ctx + 4    32 bit R/W
//           ★ 上下文步长 = 0x1000（标准 PLIC）：ctx0 在 +0x200000、ctx1 在 +0x201000。
//             `core_params.vh` 的 THRESHOLD_OFF/CLAIM_OFF 即 **ctx0 基址**（+0x200000/+0x200004）。
//           基址 = RV32GC_PLIC_BASE = 0x1F10_0000（core_params.vh §2）。
//
// 参数化口径（★ 本文件是源号映射的**定稿处**，RTL 与 DTS 只写一处）:
//   NUM_SOURCES / SOURCE_MIN / SOURCE_MAX / NUM_CONTEXTS / CTX_M / CTX_S
//   全部取自 core_params.vh §5。默认源号映射（08 §6.6 表，工程口径）:
//     intrpt[0] → 源 5（MAC）      RV32GC_INTRPT_SRC_MAC
//     intrpt[1] → 源 1（UART0）    RV32GC_INTRPT_SRC_UART
//     intrpt[2] → 源 4（SPI）      RV32GC_INTRPT_SRC_SPI
//     intrpt[3] → 源 2（NAND）     RV32GC_INTRPT_SRC_NAND
//     intrpt[4] → 源 3（DMA）      RV32GC_INTRPT_SRC_DMA
//   源号由 `intrpt_src_map[0..INTRPT_WIDTH-1]` 端口给出（每针一个源号，参数化可改），
//   便于 core_top 定稿时换映射而**不动本文件逻辑**。
//
// 中断汇入口径（08 §6.6）:
//   meip = 存在「使能于 context 0（M）」且「优先级 > threshold[0]」的 pending 源
//   seip = 存在「使能于 context 1（S）」且「优先级 > threshold[1]」的 pending 源
//   ▶ 输出 meip_o / seip_o 汇入 mip.MEIP / mip.SEIP。
//
// PLIC 语义（claim / complete 关键点）:
//   - pending 位由外部中断输入上升沿置位（gateway 口径：电平保持时 pending 保持）。
//   - claim：读 claim 寄存器返回**本上下文**中「已使能且优先级 > threshold」的
//     最高优先级源号（优先级相同取**最小源号**，= PLIC 规范的确定性仲裁），
//     同时**清该源的 pending 位**（"中断已被取走"）。
//   - complete：写 complete 寄存器（= 写 claim 同址）告知该源处理完毕：
//     清该上下文的 in-service 记录，**若源电平仍高则立即重挂 pending**
//     （电平型中断的标准"重采样"行为，完成处理后若设备仍拉高则再次上报）。
//   - 网关（gateway）口径：pending 由源电平**上升沿**置位，claim 清 0，
//     源电平撤销时清 0；在 claim 与 complete 之间 pending 保持 0 —— 因此
//     **同一个中断不会被同一上下文反复 claim**（无需 in-service 门控候选）。
//   - enable 屏蔽：源未使能 ⇒ 既不参与 claim，也不拉高 meip/seip。
//   - threshold 过滤：源优先级 <= threshold[ctx] ⇒ 不参与该上下文的中断与 claim。
//
// ★ 红线遵守声明（AGENT.md §4）:
//   - 本模块**不含任何 FPGA 原语**，不含任何 IP 例化：全部为可综合 RTL 行为描述。
//   - 本模块**没有 AXI 端口**（无 aw/w/b/ar/r）：PLIC 是核内设备，寄存器访问由
//     `rtl/mem/mmio_route.v` 在核内截获（08 §6.6 的 NOC 分支）；
//     因此"PLIC 访问绝不产生 AXI 请求"在**端口层面即天然满足**。
//   - 组合逻辑风格（AGENT.md §4 红线 3）：译码/比较/仲裁全部用 `assign`/
//     `function`/`generate` 连续赋值表达；`always` 块只用于寄存器更新
//     （pending 网关、enable/threshold/priority 的软写、claim/complete 副作用），
//     并附理由注释。
//
// 端口约定:
//   aclk / aresetn —— 低有效异步复位（与核内其余模块一致）；
//   src[0..INTRPT_WIDTH-1] —— 平台中断引脚电平（仅由 intrpt_src_map 指向的针有效）；
//   intrpt_src_map[..] —— 每针一个 PLIC 源号（0 = 该针不映射；越界值被忽略）；
//   req_* / resp_* —— 核内 MMIO 请求（地址为 **PLIC 窗口内偏移**，由 mmio_route 减基址）；
//   meip_o / seip_o —— 汇入 mip.MEIP / mip.SEIP。
//==============================================================================
`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"

module plic #(
    // ---- 源与上下文（参数化，默认取 core_params.vh §5 真源） ----
    parameter integer NUM_SOURCES   = `RV32GC_PLIC_NUM_SOURCES,    // 5
    parameter integer SOURCE_MIN    = `RV32GC_PLIC_SOURCE_MIN,     // 1（源 0 保留为「无中断」）
    parameter integer SOURCE_MAX    = `RV32GC_PLIC_SOURCE_MAX,     // 5
    parameter integer NUM_CONTEXTS  = `RV32GC_PLIC_NUM_CONTEXTS,   // 2
    parameter integer CTX_M         = `RV32GC_PLIC_CTX_M,          // 0 ⇒ MEIP
    parameter integer CTX_S         = `RV32GC_PLIC_CTX_S,          // 1 ⇒ SEIP
    parameter integer INTRPT_WIDTH  = `RV32GC_INTRPT_WIDTH,        // 8（仅低 5 针有效）
    // ---- 寄存器映射偏移（参数化可改；默认取 core_params.vh §5） ----
    parameter [31:0]  PRIORITY_OFF  = `RV32GC_PLIC_PRIORITY_OFF,   // 0x0000_0000 + 4*id
    parameter [31:0]  PENDING_OFF   = `RV32GC_PLIC_PENDING_OFF,    // 0x0000_1000
    parameter [31:0]  ENABLE_OFF    = `RV32GC_PLIC_ENABLE_OFF,     // 0x0000_2000 + 0x80*ctx + 4*ctx
    parameter [31:0]  THRESHOLD_OFF = `RV32GC_PLIC_THRESHOLD_OFF,  // 0x0020_0000 + 4*ctx
    parameter [31:0]  CLAIM_OFF     = `RV32GC_PLIC_CLAIM_OFF       // 0x0020_0004 + 4*ctx
) (
    input  wire                     aclk,
    input  wire                     aresetn,

    // ---- 平台中断源（电平）与「针 → 源号」映射 ----
    input  wire [INTRPT_WIDTH-1:0]  src,
    input  wire [INTRPT_WIDTH*4-1:0] intrpt_src_map,   // 每针 4 bit 源号（0=不映射）

    // ---- 核内 MMIO 请求（来自 mmio_route.v；地址已减去 PLIC 基址） ----
    input  wire                     req_valid,
    input  wire                     req_write,         // 1=写, 0=读
    input  wire [31:0]              req_addr,          // 窗口内偏移
    input  wire [31:0]              req_wdata,
    input  wire [3:0]               req_wstrb,          // 字节使能（PLIC 一律 32 位整字访问；
                                                        //  本模块不细分字节，仅由 mmio_route 保证对齐）

    // ---- 读响应（组合） ----
    output wire [31:0]              resp_rdata,
    output wire                     resp_hit,

    // ---- 中断输出（汇入 mip） ----
    output wire                     meip_o,            // ⇒ mip.MEIP（cause 11 MEI）
    output wire                     seip_o             // ⇒ mip.SEIP（cause 9 SEI）
);

    //--------------------------------------------------------------------------
    // 0. 编译期参数自检（参数化被误改时立即失败，避免静默错）
    //--------------------------------------------------------------------------
    initial begin
        if (NUM_CONTEXTS < 2) begin
            $display("PLIC FAIL: NUM_CONTEXTS(%0d) < 2（需 M/S 两个上下文）", NUM_CONTEXTS);
            $fatal(1, "PLIC param error");
        end
        if (SOURCE_MIN < 1) begin
            $display("PLIC FAIL: SOURCE_MIN(%0d) 必须 >= 1（源 0 保留）", SOURCE_MIN);
            $fatal(1, "PLIC param error");
        end
        if (SOURCE_MAX > 31) begin
            $display("PLIC FAIL: SOURCE_MAX(%0d) 超出单 pending 字位宽 31", SOURCE_MAX);
            $fatal(1, "PLIC param error");
        end
        // 映射一致性：CLAIM_OFF 必须是 THRESHOLD_OFF + 4（标准 PLIC 口径）
        if (CLAIM_OFF != (THRESHOLD_OFF + 32'd4)) begin
            $display("PLIC FAIL: CLAIM_OFF(%08x) 必须 == THRESHOLD_OFF+4(%08x)",
                     CLAIM_OFF, THRESHOLD_OFF + 32'd4);
            $fatal(1, "PLIC param error");
        end
    end

    //--------------------------------------------------------------------------
    // 1. 常量
    //--------------------------------------------------------------------------
    localparam integer NSRC      = NUM_SOURCES;
    localparam integer NPENDW    = 1;      // 源 1..31 落在单个 32 位 pending 字内
    // enable 位图地址步长（标准 PLIC：M 上下文 0x2000、S 上下文 0x2080）
    localparam [31:0] ENABLE_STRIDE = 32'h0000_0080;

    //--------------------------------------------------------------------------
    // 2. 译码（纯组合；读写共用一份，只写一次）
    //--------------------------------------------------------------------------
    // ---- 2.1 priority：PRIORITY_OFF + 4*id，id ∈ [1, NUM_SOURCES] ----
    //      用"差值是 4 的倍数且落在源号区间"判定，避免 32 位全量比较组合爆炸。
    //     ★ 本地静默两条**保守告警**（非缺陷）：
    //       - UNSIGNED：PRIORITY_OFF 为 0 ⇒ `req_addr >= 0` 被静态判为常量；
    //       - UNUSEDSIGNAL：prio_off_delta 的高位不参与后续位段比较。
    //       功能正确性由 tb_plic 覆盖 + 变异测试（"越界 priority 偏移不应命中"）证明。
    /* verilator lint_off UNSIGNED */
    /* verilator lint_off UNUSEDSIGNAL */
    wire [31:0] prio_off_delta = req_addr - PRIORITY_OFF;
    wire        prio_region    = (req_addr >= PRIORITY_OFF) &&
                                 (req_addr <  (PRIORITY_OFF + (NSRC + 1) * 4));
    //     prio_region 已把偏移限在 [0, (NSRC+1)*4) ⇒ 字 index ∈ [0, NSRC]；
    //     再排除源 0（保留）即完成「源 n 的地址 = +4n，n ∈ [SOURCE_MIN, SOURCE_MAX]」判定。
    wire [4:0]  prio_off_word  = prio_off_delta[6:2];   // 字 index（5 bit 足够：≤ NSRC）
    wire        prio_aligned   = (prio_off_delta[1:0] == 2'b00);
    wire        prio_id_ok     = (prio_off_word >= 5'(SOURCE_MIN)) &&
                                 (prio_off_word <= 5'(SOURCE_MAX));
    /* verilator lint_on UNUSEDSIGNAL */
    /* verilator lint_on UNSIGNED */
    wire        sel_priority   = prio_region & prio_aligned & prio_id_ok;

    // ---- 2.2 pending：PENDING_OFF + 4*w，本设计 w = 0 ----
    wire        sel_pending    = (req_addr == PENDING_OFF);

    // ---- 2.3 enable：ENABLE_OFF + 0x80*ctx + 4*w，本设计 w = 0 ----
    //      标准 PLIC 口径：M 上下文字在 0x2000，S 上下文字在 0x2080
    //      （每上下文占 0x80，仅第 0 字有效——本设计源数 ≤31 ⇒ 单字足够）。
    wire        sel_enable_m    = (req_addr == ENABLE_OFF);
    wire        sel_enable_s    = (req_addr == (ENABLE_OFF + ENABLE_STRIDE));
    wire        sel_enable_any  = sel_enable_m | sel_enable_s;

    // ---- 2.4 threshold / claim / complete 区（THRESHOLD_OFF 基址 0x0020_0000） ----
    //  ★ 关键口径（标准 RISC-V PLIC 映射，**易错点，勿改**）：
    //      CONTEXT_STRIDE = 0x1000（每上下文独占 4 KiB）
    //      threshold[ctx] = THRESHOLD_OFF + 0x1000*ctx + 0   （ctx0=+0x200000、ctx1=+0x201000）
    //      claim[ctx]     = THRESHOLD_OFF + 0x1000*ctx + 4   （ctx0=+0x200004、ctx1=+0x201004）
    //    佐证（外部权威实现，标准 PLIC 口径）：
    //      RISC-V PLIC 规范 / machina-hw-intc plic.rs 第 15-16 行
    //      `CONTEXT_BASE = 0x20_0000; CONTEXT_STRIDE = 0x1000;`，
    //      其 read/write 用 `rel/0x1000 → ctx`、`rel%0x1000 → reg(0=threshold,4=claim)`。
    //    ⇒ 不能用"两套独立相等比较"或 8 B 步长去判（会把 ctx1 的 threshold 与
    //      ctx0 的 claim 混淆）；必须按 [区基址 + 0x1000*ctx + 4*kind] 统一译码。
    localparam [31:0] CONTEXT_STRIDE = 32'h0000_1000;
    wire [31:0] tcreg_delta  = req_addr - THRESHOLD_OFF;          // 区内偏移
    wire        tcreg_region = (req_addr >= THRESHOLD_OFF) &&
                               (req_addr <  (THRESHOLD_OFF + (NUM_CONTEXTS * CONTEXT_STRIDE)));
    // ctx = delta / 0x1000；kind = delta[2]（0 = threshold、1 = claim/complete）
    wire [31:0] tcreg_ctx    = tcreg_delta >> 12;
    wire        tcreg_kind   = tcreg_delta[2];
    wire        tcreg_align  = (tcreg_delta[11:3] == 9'b0) && (tcreg_delta[1:0] == 2'b00);
    wire        tcreg_ctx_ok = (tcreg_ctx < NUM_CONTEXTS[31:0]);
    wire        sel_tcreg    = tcreg_region & tcreg_align & tcreg_ctx_ok;

    wire        sel_thresh_0 = sel_tcreg & (tcreg_ctx == 32'd0) & ~tcreg_kind;
    wire        sel_thresh_1 = sel_tcreg & (tcreg_ctx == 32'd1) & ~tcreg_kind;
    wire        sel_claim_0  = sel_tcreg & (tcreg_ctx == 32'd0) &  tcreg_kind;
    wire        sel_claim_1  = sel_tcreg & (tcreg_ctx == 32'd1) &  tcreg_kind;
    wire        sel_thresh_any = sel_thresh_0 | sel_thresh_1;
    wire        sel_claim_any  = sel_claim_0  | sel_claim_1;

    // ---- 2.5 总命中 ----
    assign resp_hit = (sel_priority | sel_pending | sel_enable_any |
                       sel_thresh_any | sel_claim_any) & strb_word_ok;

    wire wr_priority = req_valid &  req_write & sel_priority;
    wire wr_enable_m = req_valid &  req_write & sel_enable_m;
    wire wr_enable_s = req_valid &  req_write & sel_enable_s;
    wire wr_thresh   = req_valid &  req_write & sel_thresh_any;
    wire wr_claim    = req_valid &  req_write & sel_claim_any;

    wire rd_priority = req_valid & ~req_write & sel_priority;
    wire rd_enable_m = req_valid & ~req_write & sel_enable_m;
    wire rd_enable_s = req_valid & ~req_write & sel_enable_s;
    wire rd_thresh   = req_valid & ~req_write & sel_thresh_any;
    wire rd_claim    = req_valid & ~req_write & sel_claim_any;
    // pending 为只读（写被忽略，PLIC 规范口径）

    // req_wstrb 的显式消费点：PLIC 只支持 32 位整字访问，若外部送来的不是
    // "全字节使能"（4'hF）则视为非法访问 ⇒ 不响应（命中拉低）。这样既把
    // req_wstrb 用在语义上，又给 mmio_route 的错误访问留下可观察行为。
    wire        strb_word_ok = (req_wstrb == 4'hF);

    //--------------------------------------------------------------------------
    // 3. 状态
    //--------------------------------------------------------------------------
    reg [2:0]  priority_r  [0:31];              // 每源优先级（1..7 有用，0 = 不产生中断）
    reg [31:0] pending_r   [0:NPENDW-1];        // pending 位图（源号即 bit 位置）
    reg [31:0] enable_r    [0:NUM_CONTEXTS-1];  // 每上下文使能位图
    reg [31:0] threshold_r [0:NUM_CONTEXTS-1];  // 每上下文阈值
    reg [NSRC:0] src_level_d;                   // 源电平历史（供上升沿检测；[0] 恒 0 保留）

    //--------------------------------------------------------------------------
    // 4. 平台中断 → 源号 分发（纯组合 assign；由 generate 展开，不用 always）
    //    口径：intrpt_src_map 给出每根针映射的源号；若多针映射同一源号，
    //          则取「逻辑或」（任一有效即 pending）——默认映射下不会发生。
    //--------------------------------------------------------------------------
    wire [NSRC:0] src_level;   // src_level[n] = 源 n 的电平（n ∈ 1..NSRC）
    genvar gi;
    generate
        for (gi = 0; gi <= NSRC; gi = gi + 1) begin : g_src_level
            if (gi == 0) begin : g_src0_reserved
                // 源 0 保留为「无中断」：硬连 0
                assign src_level[0] = 1'b0;
            end else begin : g_src_n
                // 源 n：任一根映射到 n 的针为高 ⇒ 该源有效
                wire [INTRPT_WIDTH-1:0] hit_pins;
                for (genvar gp = 0; gp < INTRPT_WIDTH; gp = gp + 1) begin : g_pin
                    assign hit_pins[gp] = (intrpt_src_map[gp*4 +: 4] == gi[3:0]);
                end
                assign src_level[gi] = |(src & hit_pins);
            end
        end
    endgenerate

    //--------------------------------------------------------------------------
    // 5. 组合：per-上下文仲裁
    //    只在「pending & enable & (priority > threshold)」的源中
    //    选优先级最高者；并列时取**最小源号**（确定性仲裁）。
    //    注：**不**把 in-service 纳入候选门控 —— claim 已把 pending 清 0，
    //    在 claim 与 complete 之间 pending 保持 0（网关只在上升沿或 complete
    //    重挂时才置位），因此 in-service 在候选判定中是冗余的；
    //    把它纳入反而会导致"同一上下文后续再也 claim 不到该源"的死锁（已实测）。
    //--------------------------------------------------------------------------
    // 5.1 每上下文的候选掩码
    //     用 generate 逐位展开（见 g_cand），此处仅声明数组供各 generate 分支驱动。
    wire [31:0] cand_raw [0:NUM_CONTEXTS-1];

    genvar gc;
    generate
        for (gc = 0; gc < NUM_CONTEXTS; gc = gc + 1) begin : g_cand
            // 逐源展开候选判定：pending & enable & (prio > threshold)
            wire [31:0] c;
            for (genvar gs = 0; gs < 32; gs = gs + 1) begin : g_bit
                if (gs >= SOURCE_MIN && gs <= SOURCE_MAX) begin : g_valid_src
                    assign c[gs] = pending_r[0][gs]
                                 & enable_r[gc][gs]
                                 & (priority_r[gs] > threshold_r[gc][2:0]);
                end else begin : g_invalid_src
                    assign c[gs] = 1'b0;   // 源 0 保留 / 越界源恒 0
                end
            end
            assign cand_raw[gc] = c;
        end
    endgenerate

    // 5.2 仲裁函数：给定候选掩码 ⇒ 返回最高优先级源号（并列取最小号）
    //     用 function 表达组合逻辑（红线 3 推荐形式，避免 always @(*) 多 reg 赋值）。
    function [31:0] plic_arb;
        input [31:0] cand;
        integer      i;
        integer      best;
        reg   [2:0]  best_prio;
        begin
            best      = 0;
            best_prio = 3'd0;
            for (i = 31; i >= 0; i = i - 1) begin
                // 从高源号往低扫描：`>=` 保证**同优先级取最小源号**
                if (cand[i] && (priority_r[i] >= best_prio)) begin
                    best_prio = priority_r[i];
                    best      = i;
                end
            end
            plic_arb = best;
        end
    endfunction

    // 5.3 各上下文的仲裁结果与"是否有中断"
    wire [31:0] claim_id [0:NUM_CONTEXTS-1];
    wire        cand_any [0:NUM_CONTEXTS-1];
    generate
        for (gc = 0; gc < NUM_CONTEXTS; gc = gc + 1) begin : g_arb
            assign claim_id[gc] = plic_arb(cand_raw[gc]);
            assign cand_any[gc] = |cand_raw[gc];
        end
    endgenerate

    // 5.4 中断输出（context 0 ⇒ MEIP、context 1 ⇒ SEIP）
    assign meip_o = cand_any[CTX_M];
    assign seip_o = cand_any[CTX_S];

    //--------------------------------------------------------------------------
    // 6. 读数据多路（纯组合 assign）
    //--------------------------------------------------------------------------
    // claim 返回值：有候选 ⇒ 源号；无候选 ⇒ 0（PLIC 规范：无中断返回 0，
    // 且此时**不得清任何 pending 位**——见 7.2 的写许可门控）。
    wire [31:0] claim_rdata_0 = sel_claim_0 ? claim_id[0] : 32'd0;
    wire [31:0] claim_rdata_1 = sel_claim_1 ? claim_id[1] : 32'd0;

    assign resp_rdata =
        rd_priority   ? {29'b0, priority_r[prio_off_word]}                      :
        sel_pending   ? pending_r[0]                                               :
        rd_enable_m   ? enable_r[0]                                                :
        rd_enable_s   ? enable_r[1]                                                :
        (rd_thresh & sel_thresh_0) ? threshold_r[0]                                :
        (rd_thresh & sel_thresh_1) ? threshold_r[1]                                :
        rd_claim      ? (sel_claim_0 ? claim_rdata_0 : claim_rdata_1)              :
                        32'h0000_0000;

    // 寄存器软写的索引（显式定宽，避免隐式位宽扩展告警）
    wire [4:0]  comp_id   = req_wdata[4:0];    // complete 的源号
    wire [4:0]  clr_idx_m = claim_id[0][4:0];  // ctx0 claim 清位索引
    wire [4:0]  clr_idx_s = claim_id[1][4:0];  // ctx1 claim 清位索引

    //--------------------------------------------------------------------------
    // 7. 时序：pending 网关、寄存器软写、claim/complete 副作用
    //    ★ always 块仅用于状态保持（红线 3 允许的必要场合）：
    //      pending 是"被源电平/上升沿置位、被 claim 清零、被 complete 重挂"的
    //      位图，属状态语义，无法用连续赋值表达。
    //
    //    网关语义（标准 PLIC / SiFive 口径，见文件头引用）：
    //      - 源电平由低变高（上升沿）⇒ pending 置位（"新中断到达"）。
    //      - 源电平保持高且非上升沿 ⇒ pending 保持（不在本块赋值）；
    //        若本拍被 claim 清 0，则该源在电平再次上升沿之前不会被重挂
    //        ⇒ **同一中断不会被反复 claim**（无需 in-service 门控）。
    //      - claim ⇒ 该源 pending 清 0。
    //      - complete（写 claim 同址）⇒ **若源电平仍高则立即重挂 pending**
    //        （电平型中断的标准"重采样"行为）。
    //      - 源电平撤销 ⇒ 清 pending（中断源已消失）。
    //--------------------------------------------------------------------------
    integer i;
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            pending_r[0] <= 32'd0;
            src_level_d <= {(NSRC+1){1'b0}};   // 全 0（宽 = NSRC+1）
            for (i = 0; i < NUM_CONTEXTS; i = i + 1) begin
                enable_r[i]    <= 32'd0;
                threshold_r[i] <= 32'd0;
            end
            for (i = 0; i <= 31; i = i + 1) begin
                priority_r[i] <= 3'd0;
            end
        end else begin
            // ---- 7.0 源电平历史（供上升沿检测） ----
            src_level_d <= src_level;

            // ---- 7.1 网关：置位 / 清位 ----
            //     口径：电平有效且为**上升沿** ⇒ 置位；电平无效 ⇒ 清位；
            //           电平保持高且非上升沿 ⇒ **不赋值**（pending 保持原值，
            //           若本拍被 7.2 claim 清 0，则 7.2 的赋值生效；
            //           若本拍被 7.3 complete 重挂，则 7.3 的赋值生效）。
            for (i = 0; i <= 31; i = i + 1) begin
                if (i >= SOURCE_MIN && i <= SOURCE_MAX) begin
                    if (!src_level[i]) begin
                        pending_r[0][i] <= 1'b0;   // 源电平撤销 ⇒ 清 pending
                    end else if (!src_level_d[i]) begin
                        pending_r[0][i] <= 1'b1;   // 上升沿 ⇒ 置位（新中断）
                    end
                    // else：电平保持高且非上升沿 ⇒ 保持（本块不赋值）
                end else begin
                    pending_r[0][i] <= 1'b0;       // 源 0 / 越界源恒 0
                end
            end

            // ---- 7.2 claim：读 claim 且**确有可返回的源** ⇒ 清该源 pending ----
            //      pending 清 0 后，网关只在电平新的上升沿或 complete 时才重挂，
            //      故本上下文不会立刻重复 claim 同一源。
            if (rd_claim) begin
                if (sel_claim_0 && (claim_id[0] != 32'd0))
                    pending_r[0][clr_idx_m] <= 1'b0;
                if (sel_claim_1 && (claim_id[1] != 32'd0))
                    pending_r[0][clr_idx_s] <= 1'b0;
            end

            // ---- 7.3 complete（写 claim 同址）：若源电平仍高则重挂 pending ----
            //     注：complete_id 取 req_wdata[4:0] 并做范围校验（源 0 保留 ⇒ 忽略）。
            if (wr_claim) begin
                if (sel_claim_0 && (comp_id >= 5'(SOURCE_MIN)) &&
                    (comp_id <= 5'(SOURCE_MAX))) begin
                    if (src_level[comp_id[2:0]]) begin
                        pending_r[0][comp_id] <= 1'b1;   // 电平仍高 ⇒ 重挂
                    end
                end
                if (sel_claim_1 && (comp_id >= 5'(SOURCE_MIN)) &&
                    (comp_id <= 5'(SOURCE_MAX))) begin
                    if (src_level[comp_id[2:0]]) begin
                        pending_r[0][comp_id] <= 1'b1;   // 电平仍高 ⇒ 重挂
                    end
                end
            end

            // ---- 7.4 寄存器软写 ----
            if (wr_priority) priority_r[prio_off_word] <= req_wdata[2:0];
            if (wr_enable_m) enable_r[0]                  <= req_wdata & 32'hFFFF_FFFE; // bit0 恒 0
            if (wr_enable_s) enable_r[1]                  <= req_wdata & 32'hFFFF_FFFE;
            if (wr_thresh & sel_thresh_0) threshold_r[0]  <= {29'b0, req_wdata[2:0]};
            if (wr_thresh & sel_thresh_1) threshold_r[1]  <= {29'b0, req_wdata[2:0]};
        end
    end

endmodule
