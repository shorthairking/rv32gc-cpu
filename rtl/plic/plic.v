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
// PLIC 语义（claim / complete / threshold 关键点；口径源
//   https://raw.githubusercontent.com/riscv/riscv-plic-spec/master/riscv-plic.adoc，
//   只作规范依据，不作为可执行文本）:
//   - gateway：每源最多一个请求在 PLIC core 中 pending（IP 位）。电平型源首次
//     有效 ⇒ 投递一个请求；**在收到 completion 之前不再投递新请求**（同一源）；
//     「The gateway does not have the facility to retract an interrupt request
//      once forwarded to the PLIC core」⇒ 源电平在 claim 前撤销**不清 IP**；
//     IP 只由 claim 清 0。「On receiving an interrupt completion message, if the
//     interrupt is level-triggered and the interrupt is still asserted, a new
//     interrupt request will be forwarded」⇒ completion 后电平仍有效则再投递。
//   - claim：读 claim 寄存器返回**本上下文**中「已使能且优先级 != 0」的最高
//     优先级 pending 源号（优先级相同取**最小源号**，= PLIC 规范的确定性仲裁），
//     同时**清该源的 pending 位**。规范明文「the claim operation is **not
//     affected** by the setting of the priority threshold register」⇒ **claim
//     不受 threshold 过滤**（threshold 置最大仍可 poll-claim）。
//   - complete：写 complete 寄存器（= 写 claim 同址）告知该源处理完毕。
//     规范明文「If the completion ID does not match an interrupt source that is
//     currently enabled for the target, the completion is **silently ignored**」
//     ⇒ 未使能该源的上下文写 completion 被忽略；生效时清该源 busy，若源电平
//     仍有效则再投递一个新请求。
//   - enable 屏蔽：源未使能 ⇒ 既不参与 claim，也不拉高 meip/seip。
//   - threshold 过滤：只作用于**通知**（meip/seip）：源优先级 <= threshold[ctx]
//     ⇒ 不产生该上下文的通知；**不影响 claim**。
//   - priority==0：源永不产生中断/不可 claim（规范：threshold=0 放行所有
//     **非零**优先级）。pending 位仍可被 gateway 置位。
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
    //     ★ M4 综合口径（2026-09-18）：原文用 SystemVerilog 定宽转换 `5'(SOURCE_MIN)`
    //       —— Vivado 的 Verilog（非 -sv）模式**不认**该语法，报
    //       `ERROR: [Synth 8-2716] syntax error near ''' 导致整核无法综合；
    //       本设计是 Verilog-2001 口径（不启用 -sv），故去掉转换直接比较：
    //       SOURCE_MIN/MAX 是 ≤31 的整型参数、prio_off_word 为 5 bit 无符号，
    //       比较结果与转换写法**逐位等价**（无符号零扩展），iverilog/Verilator 不变。
    wire        prio_id_ok     = (prio_off_word >= SOURCE_MIN) &&
                                 (prio_off_word <= SOURCE_MAX);
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

    wire wr_priority = req_valid &  req_write & sel_priority   & strb_word_ok;
    wire wr_enable_m = req_valid &  req_write & sel_enable_m   & strb_word_ok;
    wire wr_enable_s = req_valid &  req_write & sel_enable_s   & strb_word_ok;
    wire wr_thresh   = req_valid &  req_write & sel_thresh_any & strb_word_ok;
    wire wr_claim    = req_valid &  req_write & sel_claim_any  & strb_word_ok;

    wire rd_priority = req_valid & ~req_write & sel_priority;
    wire rd_enable_m = req_valid & ~req_write & sel_enable_m;
    wire rd_enable_s = req_valid & ~req_write & sel_enable_s;
    wire rd_thresh   = req_valid & ~req_write & sel_thresh_any;
    // ★ claim 读是**非幂等**访问（读即清 pending）：必须与 resp_hit 同受
    //   strb_word_ok 门控，否则"非全字读被拒绝（hit=0）却仍清 pending"。
    wire rd_claim    = req_valid & ~req_write & sel_claim_any & strb_word_ok;
    // pending 为只读（写被忽略，PLIC 规范口径）

    // req_wstrb 的显式消费点：PLIC 只支持 32 位整字访问，若外部送来的不是
    // "全字节使能"（4'hF）则视为非法访问 ⇒ **既不响应（命中拉低），也不产生
    // 任何寄存器副作用**（见 wr_* / rd_claim 的 strb_word_ok 门控）。保留既有
    // "全字访问命中 / 非全字拒绝"契约，只补上"拒绝时无时序副作用"。
    wire        strb_word_ok = (req_wstrb == 4'hF);

    //--------------------------------------------------------------------------
    // 3. 状态
    //--------------------------------------------------------------------------
    reg [2:0]  priority_r  [0:31];              // 每源优先级（1..7 有用，0 = 不产生中断）
    reg [31:0] pending_r   [0:NPENDW-1];        // pending 位图（源号即 bit 位置）
    reg [31:0] enable_r    [0:NUM_CONTEXTS-1];  // 每上下文使能位图
    reg [31:0] threshold_r [0:NUM_CONTEXTS-1];  // 每上下文阈值
    reg [NSRC:0] gw_busy_r;                     // 每源 gateway outstanding（投递后~completion；
                                                // [0] 恒 0 保留）

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
    // 5. 组合：per-上下文候选与仲裁
    //    官方 PLIC 规范（riscv-plic.adoc）两条**互相独立**的口径：
    //      · claim：「the PLIC core will atomically determine the ID of the
    //        highest-priority pending interrupt for the target」且「the claim
    //        operation is **not affected** by the setting of the priority
    //        threshold register」⇒ claim 候选 = pending & enable
    //        & priority != 0，**不含 threshold**。
    //      · notification：「The PLIC core forwards an interrupt notification
    //        to one or more targets if the targets have any pending interrupts
    //        enabled, and the priority of the pending interrupts **exceeds a
    //        per-target threshold**」⇒ meip/seip 候选 = claim 候选再叠加
    //        priority > threshold。
    //    两条候选共用同一仲裁函数（最高优先级，并列取最小源号）。
    //    in-service/gateway busy **不**进入候选门控：claim 已清 pending，且
    //    gateway 在 completion 前不再投递（见 §7），pending 本身已保证不重复
    //    claim；把它纳入反而会造成"同一上下文再也 claim 不到该源"的死锁。
    //--------------------------------------------------------------------------
    // 5.1 每上下文候选掩码（generate 逐位展开）
    //     cand_claim [gc][i] = pending & enable & (priority != 0)   （claim 候选）
    //     cand_notify[gc][i] = cand_claim & (priority > threshold)  （通知候选）
    wire [31:0] cand_claim  [0:NUM_CONTEXTS-1];
    wire [31:0] cand_notify [0:NUM_CONTEXTS-1];

    genvar gc;
    generate
        for (gc = 0; gc < NUM_CONTEXTS; gc = gc + 1) begin : g_cand
            wire [31:0] c;   // claim 候选（无 threshold）
            wire [31:0] n;   // 通知候选（claim 候选 + threshold 过滤）
            for (genvar gs = 0; gs < 32; gs = gs + 1) begin : g_bit
                if (gs >= SOURCE_MIN && gs <= SOURCE_MAX) begin : g_valid_src
                    assign c[gs] = pending_r[0][gs]
                                 & enable_r[gc][gs]
                                 & (priority_r[gs] != 3'd0);
                    assign n[gs] = c[gs]
                                 & (priority_r[gs] > threshold_r[gc][2:0]);
                end else begin : g_invalid_src
                    assign c[gs] = 1'b0;   // 源 0 保留 / 越界源恒 0
                    assign n[gs] = 1'b0;
                end
            end
            assign cand_claim[gc]  = c;
            assign cand_notify[gc] = n;
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

    // 5.3 各上下文的 claim 仲裁结果 / 通知存在性
    wire [31:0] claim_id   [0:NUM_CONTEXTS-1];
    wire        notify_any [0:NUM_CONTEXTS-1];
    generate
        for (gc = 0; gc < NUM_CONTEXTS; gc = gc + 1) begin : g_arb
            assign claim_id[gc]   = plic_arb(cand_claim[gc]);
            assign notify_any[gc] = |cand_notify[gc];
        end
    endgenerate

    // 5.4 中断输出（context 0 ⇒ MEIP、context 1 ⇒ SEIP）；受 threshold 过滤
    assign meip_o = notify_any[CTX_M];
    assign seip_o = notify_any[CTX_S];

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
    // 7. 时序：gateway、寄存器软写、claim/complete 副作用
    //    ★ always 块仅用于状态保持（红线 3 允许的必要场合）。
    //
    //    Gateway 语义（riscv-plic.adoc "Interrupt Gateways"）:
    //      · 每个源最多一个请求在 PLIC core 中 pending（IP 位）。
    //      · 电平型源：首次电平有效且 gateway 空闲 ⇒ 投递一个请求
    //        （IP=1，gw_busy=1）；此后**收到 completion 之前不再投递新请求**。
    //      · 「The gateway does not have the facility to **retract** an interrupt
    //        request once forwarded to the PLIC core」⇒ 源电平在 claim 之前撤销
    //        **不得**清 IP；IP 只由 claim 清 0（已投递请求不丢）。
    //      · 收到 completion 后：若电平仍有效则**再投递一个新请求**（IP=1）。
    //      · busy 期间的新沿：采用规范允许的「忽略」策略（"might either ignore
    //        additional matching edges or increment a counter"），completion
    //        前不提前投递。
    //--------------------------------------------------------------------------
    integer i;
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            pending_r[0] <= 32'd0;
            gw_busy_r    <= {(NSRC+1){1'b0}};   // 全 0（宽 = NSRC+1）
            for (i = 0; i < NUM_CONTEXTS; i = i + 1) begin
                enable_r[i]    <= 32'd0;
                threshold_r[i] <= 32'd0;
            end
            for (i = 0; i <= 31; i = i + 1) begin
                priority_r[i] <= 3'd0;
            end
        end else begin
            // ---- 7.1 gateway：空闲且电平有效 ⇒ 投递；否则保持、不撤回 ----
            for (i = 0; i <= 31; i = i + 1) begin
                if (i >= SOURCE_MIN && i <= SOURCE_MAX) begin
                    if (!gw_busy_r[i] && src_level[i]) begin
                        pending_r[0][i] <= 1'b1;   // 投递新请求（IP=1）
                        gw_busy_r[i]   <= 1'b1;   // busy 直到收到 completion
                    end
                    // else：busy（请求已投递 / 等待 completion）或电平无效
                    //       ⇒ 不投递，且**不清 IP**（规范禁止撤回已投递请求）。
                end else begin
                    pending_r[0][i] <= 1'b0;       // 源 0 / 越界源恒 0
                end
            end

            // ---- 7.2 claim：读 claim 且**确有可返回的源** ⇒ 清该源 pending ----
            //      pending 清 0 后 gateway 仍 busy，completion 前不会重投，
            //      故本上下文不会重复 claim 同一源。
            if (rd_claim) begin
                if (sel_claim_0 && (claim_id[0] != 32'd0))
                    pending_r[0][clr_idx_m] <= 1'b0;
                if (sel_claim_1 && (claim_id[1] != 32'd0))
                    pending_r[0][clr_idx_s] <= 1'b0;
            end

            // ---- 7.3 complete（写 claim 同址）----
            //      仅当该上下文**使能了**该源时生效（规范：未使能源的 completion
            //      静默忽略）；生效时清 busy，电平仍有效则再投递一个新请求。
            //      注：comp_id 取 req_wdata[4:0] 并做范围校验（源 0 保留 ⇒ 忽略）。
            //      src_level 索引用完整 5-bit comp_id（旧写法 comp_id[2:0] 在源号
            //      >7 时错位，本设计 NSRC=5 未暴露，参数化时必须用全宽）。
            if (wr_claim) begin
                if (sel_claim_0 && (comp_id >= SOURCE_MIN) &&
                    (comp_id <= SOURCE_MAX) && enable_r[0][comp_id]) begin
                    gw_busy_r[comp_id] <= 1'b0;
                    if (src_level[comp_id]) begin
                        pending_r[0][comp_id] <= 1'b1;   // 电平仍有效 ⇒ 再投递
                        gw_busy_r[comp_id]   <= 1'b1;
                    end
                end
                if (sel_claim_1 && (comp_id >= SOURCE_MIN) &&
                    (comp_id <= SOURCE_MAX) && enable_r[1][comp_id]) begin
                    gw_busy_r[comp_id] <= 1'b0;
                    if (src_level[comp_id]) begin
                        pending_r[0][comp_id] <= 1'b1;   // 电平仍有效 ⇒ 再投递
                        gw_busy_r[comp_id]   <= 1'b1;
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
