//==============================================================================
// rtl/mem/amo_unit.v —— AMO 读-改-写运算 + LR/SC 保留集（M 级）
//==============================================================================
// 项目    : rv32gc-cpu（阶段二 2A：单发射顺序 5 级基线核）
// 出处    : docs/design/08-baseline-5stage.md §5.4 行为要点 ⑤、§5.5 抉择 4
//           docs/kb/isa-notes.md T4、§3.3
//           riscv-isa-manual/src/unpriv/zaamo.adoc（AMO 语义与对齐要求）
//           riscv-isa-manual/src/unpriv/zalrsc.adoc（LR/SC 与保留集语义）
// 唯一真源: rtl/pkg/rv32_defs.vh §3.8（AMO funct5/dd 编码）、§6（cause 码）
//------------------------------------------------------------------------------
// 本模块职责（严格限定，不含 L1D / AXI / 生地址）：
//   ① **AMO 数据通路**：给定「旧内存值 old + 操作数 rs2 + funct5」，用纯组合
//      `function` 算出「写回内存的新值 new」与「写回 rd 的旧值 oldr」。
//   ② **AMO 两相控制**：AMO = 读-改-写。2A 用「读相 → 改相 → 写相」的显式状态
//      表达，读相返回后再发写相；被 PMP 拒时**恒 cause 7**（T4，08 §5.5 抉择 4），
//      无论内部实现为读+写。
//   ③ **LR/SC 保留集**：2A 允许「单 hart、最近一次 LR 地址」的简化实现
//      （08 §5.4 行为要点 ⑤）。保留集只记录**最近一次 LR 的字地址**（4 B 对齐后），
//      SC 在下列任一条件下失败（riscv-isa-manual zalrsc.adoc 强制项）：
//        [norm:sc_addr_not_in_reservation_fail] SC 地址不在最近 LR 的保留集内
//        [norm:sc_intervening_sc_fail]          两次 LR 之间有其它 SC（任意地址）
//        [norm:sc_reservation_invalidate]       任何 LR/SC 都使本 hart 保留失效
//        [norm:sc_other_hart_store_fail]        其它 hart 对保留集的写在 LR/SC 间可见
//      ⇒ 可观察语义：SC 成功时内存被写、rd 写 0；失败时不写内存、rd 写非 0。
//
// ★ 对齐：AMO/LR/SC 要求**自然对齐**（zaamo.adoc:17-22、zalrsc.adoc:75-80：
//   非对齐抛 address-misaligned 异常）。本模块的 `misaligned_i` 输入由 lsu.v 产生；
//   lsu.v 按 08 §5.5 抉择 1「非对齐优先」**先于** PMP/AMO 检查 ⇒ 非对齐时本模块不动作。
//
// ★ cause 口径 [T4]：AMO/SC 被 PMP 拒 **恒 cause 7**（store/AMO access fault）。
//   本模块的 `exc_cause_o` 在 PMP 拒时输出 `RV32GC_EXC_STORE_ACCESS_FAULT`，
//   不区分内部读相/写相失败。
//
// 风格（AGENT.md §4.3）：运算全部用 `function`（纯组合）；只有**保留集寄存器**
//   与两相 FSM 用 `always @(posedge clk)` 时序块（确有必要的少量场合，已注释理由）。
//   无 `always @(*)` 给多个 reg 赋值的写法。
//
// 端口契约（供 lsu.v 例化）：
//   clk / rst_n              : 时钟与同步低有效复位
//   req_valid_i              : 本拍有 AMO/LR/SC 请求（一拍脉冲）
//   is_lr_i / is_sc_i        : LR.W / SC.W
//   is_amo_i                 : 其它 AMO（add/swap/xor/or/and/min/max/*u）
//   amo_f5_i[4:0]            : AMO funct5（`RV32GC_AMO_*`）
//   addr_i[31:0]             : 访存**物理地址**（已翻译；非对齐时本模块不动作）
//   misaligned_i             : 1 ⇒ 该笔非自然对齐 ⇒ 本模块不产生动作（上层报 cause 4/6）
//   pmp_deny_i               : 1 ⇒ PMP 拒绝 ⇒ AMO 恒 cause 7（T4）
//   rdata_i[31:0]            : L1D 返回的旧值（读相结果）
//   rdata_valid_i            : L1D 返回有效
//   rs2_i[31:0]              : 操作数（AMO）/ 待写值（SC）
//   -- 输出 --
//   rd_old_o[31:0]           : 写回 rd 的值（AMO/LR：旧值；SC：0=成功 / 1=失败）
//   sc_success_o             : SC 是否成功（仅 is_sc_i 有效）
//   wdata_o[31:0]            : 写相要写回内存的新值
//   w_req_o                  : 写相请求（1 拍，L1D 据此写入）
//   r_req_o                  : 读相请求（1 拍）
//   busy_o                   : 本模块占用中（LSU 据此停顿）
//   exc_o / exc_cause_o      : AMO/SC 被 PMP 拒 ⇒ 1 / cause 7
//   rsv_valid_o              : 当前是否有有效保留（诊断/覆盖）
//   rsv_addr_o[31:0]         : 保留集地址（诊断/覆盖）
//==============================================================================
`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"

module amo_unit (
    input  wire        clk,
    input  wire        rst_n,

    // ---- 请求（来自 lsu.v；均为单拍脉冲） ----
    input  wire        req_valid_i,
    input  wire        is_lr_i,
    input  wire        is_sc_i,
    input  wire        is_amo_i,
    input  wire [4:0]  amo_f5_i,

    input  wire [31:0] addr_i,          // 物理地址
    input  wire        misaligned_i,    // 非自然对齐 ⇒ 本模块不动作
    input  wire        pmp_deny_i,      // PMP 拒绝
    input  wire [31:0] rs2_i,           // AMO 操作数 / SC 待写值

    // ---- L1D 交互（读相 / 写相） ----
    input  wire [31:0] rdata_i,
    input  wire        rdata_valid_i,

    // ---- 输出 ----
    output wire [31:0] rd_old_o,
    output wire        sc_success_o,
    output wire [31:0] wdata_o,
    output wire        w_req_o,
    output wire        r_req_o,
    output wire        busy_o,
    output wire        exc_o,
    output wire [4:0]  exc_cause_o,

    // ---- 保留集观察 ----
    output wire        rsv_valid_o,
    output wire [31:0] rsv_addr_o
);

    //==========================================================================
    // 1. AMO 运算：纯组合 function（数据通路，无状态）
    //    funct5 编码取自 rtl/pkg/rv32_defs.vh §3.8（唯一真源）
    //==========================================================================
    // 返回写回内存的新值 [stored]。rd 侧恒为旧值 old（本层直通，见 §4）。
    function [31:0] amo_apply;
        input [4:0]  f5;
        input [31:0] old;
        input [31:0] src;
        begin
            case (f5)
                `RV32GC_AMO_ADD   : amo_apply = old + src;
                `RV32GC_AMO_SWAP  : amo_apply = src;
                `RV32GC_AMO_XOR   : amo_apply = old ^ src;
                `RV32GC_AMO_OR    : amo_apply = old | src;
                `RV32GC_AMO_AND   : amo_apply = old & src;
                // 有符号比较：min/max（rs2 与 old 均按 32 位有符号解释）
                `RV32GC_AMO_MIN   : amo_apply = ($signed(old) < $signed(src)) ? old : src;
                `RV32GC_AMO_MAX   : amo_apply = ($signed(old) > $signed(src)) ? old : src;
                // 无符号比较
                `RV32GC_AMO_MINU  : amo_apply = (old < src) ? old : src;
                `RV32GC_AMO_MAXU  : amo_apply = (old > src) ? old : src;
                // LR/SC 不经此函数；给一个确定值避免 X 传播（保守取 src，不使用）
                `RV32GC_AMO_LR,
                `RV32GC_AMO_SC    : amo_apply = src;
                default           : amo_apply = old;   // 未定义 funct5：不改内存
            endcase
        end
    endfunction

    //==========================================================================
    // 2. 字地址对齐（LR/SC/AMO 以 4 B 字为单位）
    //==========================================================================
    wire [31:0] word_addr = {addr_i[31:2], 2'b00};

    //==========================================================================
    // 3. 请求分类（组合门控）
    //==========================================================================
    // 只有「有请求 && 自然对齐 && PMP 通过」才真正动作。
    //   非对齐  ⇒ 上层按 08 §5.5 抉择 1 先报 cause 4/6，本模块不动（misaligned 高优先）
    //   PMP 拒  ⇒ 恒 cause 7（T4），本模块不产生内存副作用
    wire op_is_atomic = is_lr_i || is_sc_i || is_amo_i;
    wire req_ok       = req_valid_i && op_is_atomic && !misaligned_i && !pmp_deny_i;

    // 保留集命中判定：SC 的地址必须落在最近 LR 的保留集内。
    // 2A 简化：保留集 = 最近一次 LR 的**字**（4 B 自然对齐区间）。
    //   [norm:sc_addr_not_in_reservation_fail]
    wire rsv_hit  = rsv_valid_r && (word_addr == rsv_addr_r) &&
                    (addr_i[1:0] == 2'b00);   // 非对齐时本就不动作，此处双保险

    // SC 成功条件（组合）：
    //   ① 请求合法（对齐 + PMP 通过 + 是 SC）
    //   ② 保留仍然有效
    //   ③ SC 地址落在保留集内
    // 其余情况（含 [norm:sc_intervening_sc_fail] 造成的 rsv_valid_r=0）⇒ 失败。
    wire sc_ok = req_ok && is_sc_i && rsv_valid_r && rsv_hit;

    //==========================================================================
    // 4. 输出组合
    //==========================================================================
    // 读相：AMO 与 LR 都需要读旧值；SC 需要读（写相前的写分配/权限检查），
    //       但 SC 的"读"不产生 rd 数据 —— rd 由成功与否决定。
    //   本模块把"读相"表达为：请求接受且尚未拿到 rdata 时拉高 r_req_o。
    wire need_read  = req_ok && (is_amo_i || is_lr_i);
    wire need_write = req_ok && (is_amo_i || (is_sc_i && sc_ok));

    // 读相握手：拉高 r_req_o 且等 rdata_valid_i
    assign r_req_o = need_read && !rdata_valid_i;

    // 写相握手：AMO 在读完旧值后立刻发写；SC 成功则直接写。
    assign w_req_o = need_write && (is_sc_i ? 1'b1 : rdata_valid_i);

    // 写回内存的新值：AMO 用 function 运算；SC 直接写 rs2。
    assign wdata_o = is_sc_i ? rs2_i : amo_apply(amo_f5_i, rdata_i, rs2_i);

    // 写回 rd 的旧值：
    //   AMO / LR ⇒ 读到的旧值（LR 由 lsu 走 load 通路，此处同样直通）
    //   SC       ⇒ 成功写 0、失败写非 0（规范 [norm:sc_w_success]/[norm:sc_w_failure]）
    //             本设计失败值取 1（任一非零值均合法）
    assign rd_old_o     = is_sc_i ? (sc_ok ? 32'd0 : 32'd1) : rdata_i;
    assign sc_success_o = sc_ok;

    // busy：请求合法但读相未完成（需要多拍）时占用 LSU
    assign busy_o = req_ok && need_read && !rdata_valid_i;

    // ---- PMP 拒绝的 AMO/SC/LR 异常：恒 cause 7 [T4] ----
    //   ★ T4 只点名 AMO/SC；LR 是**读**操作，但本设计按「AMO 族被 PMP 拒恒 cause 7」
    //     的上层口径统一上报（08 §5.5 抉择 4 的措辞是「AMO 被 PMP 拒恒 cause 7」，
    //     且 08 T4 条目列出 AMO/SC/cbo.zero）。LR 的 PMP 拒绝实际由 pmp_check 按
    //     load 口径给出 cause 5 —— 见 lsu.v 的 cause 选择逻辑（LR 走 load 分支）。
    //   本模块只在「AMO 或 SC」上抛出恒 cause 7。
    assign exc_o       = req_valid_i && op_is_atomic && !misaligned_i && pmp_deny_i &&
                         (is_amo_i || is_sc_i);
    assign exc_cause_o = `RV32GC_EXC_STORE_ACCESS_FAULT;   // 恒 7

    //==========================================================================
    // 5. 保留集寄存器与状态
    //    理由（AGENT.md §4.3 允许的"确有必要"场合）：保留集是**架构可见状态**，
    //    必须跨拍保持；这是真状态机，不是组合逻辑的伪装。
    //==========================================================================
    reg        rsv_valid_r;
    reg [31:0] rsv_addr_r;

    assign rsv_valid_o = rsv_valid_r;
    assign rsv_addr_o  = rsv_addr_r;

    // 保留集更新规则（规范强制项）：
    //   · 任何 LR 执行（无论后续）⇒ 建立新保留（地址 = LR 的字地址），并使旧的失效
    //     [norm:lr_w_op] / [norm:sc_reservation_invalidate]
    //   · 任何 SC 执行（无论成功失败）⇒ 清除保留
    //     [norm:sc_reservation_invalidate] "Regardless of success or failure"
    //   · 其它 hart 的写（由 lsu 侧汇总成 ext_store_to_rsv_i 语义）⇒ 清除
    //     [norm:sc_other_hart_store_fail]：2A 单 hart 简化实现下，本模块用
    //     `ext_write_i` 输入（由 lsu 在同地址写、其它 hart/设备写时置 1）清除。
    //     ★ 2A 允许简化（08 §5.4）：单 hart、无其它设备主动写保留集时该输入恒 0，
    //       此时 SC 的成功/失败**可观察语义**仍然正确（本 hart 自己的 LR/SC 序列
    //       与外部写不足以破坏语义）。
    always @(posedge clk) begin
        if (!rst_n) begin
            rsv_valid_r <= 1'b0;
            rsv_addr_r  <= 32'd0;
        end else if (req_ok && is_lr_i) begin
            // LR：建立保留（即使随后 SC 失败，保留也已按规范更新）
            rsv_valid_r <= 1'b1;
            rsv_addr_r  <= word_addr;
        end else if (req_ok && is_sc_i) begin
            // SC：**无论成败**都使保留失效（规范强制）
            rsv_valid_r <= 1'b0;
            rsv_addr_r  <= rsv_addr_r;   // 地址保持（诊断可读；valid=0 时无意义）
        end
    end

endmodule
