//==============================================================================
// rtl/mem/cmo_unit.v —— Zicbom `cbo.*` 动作生成（M 级，经 L1D 执行）
//==============================================================================
// 项目    : rv32gc-cpu（阶段二 2A：单发射顺序 5 级基线核）
// 出处    : docs/design/08-baseline-5stage.md §5.4 行为要点 ⑥、§5.5 抉择列、§6.5
//           （含用户裁决口径 2026-09-14）
//           docs/kb/isa-notes.md T8
//           riscv-isa-manual/src/unpriv/cmo.adoc（CMO 语义；:409-410 no_addr_misaligned_excep）
// 唯一真源: rtl/pkg/rv32_defs.vh §3.11（CBO 编码，**2A 只含 clean/flush/inval**）
//           rtl/pkg/core_params.vh §7（CMO block size，**用户裁决**）
//------------------------------------------------------------------------------
// 用户裁决口径（08 §6.5，必须写入实现）：
//   · `cbo.clean`/`cbo.flush` 的 block = **64 B**（L2 行）⇒ `RV32GC_CBOM_BLOCK_SIZE`
//   · `cbo.zero` 的 block = **32 B**（L1D 行）⇒ `RV32GC_CBOZ_BLOCK_SIZE`
//     ★ **2A 不实现 Zicboz/cbo.zero**（08 §11 R1；rv32_defs.vh §3.11 明确不定义其编码）
//       ⇒ 本模块只生成 clean/flush/inval 三种动作，`is_cboz_i` 恒 0（保留端口便于后续）。
//
// 地址口径 [T8，规范强制]：
//   `cbo.*` 的 `rs1` **不要求块对齐**，CMO **不产生 address-misaligned 异常**。
//   ⇒ 本模块把地址**向下对齐到 block 边界**（内部完成），上层 lsu.v **不得**为 CMO
//      报 cause 6（`RV32GC_EXC_STORE_MISALIGNED`）。
//      [norm:cbo-flush_unaligned] / [norm:cbo-inval_unaligned] / [norm:no_addr_misaligned_excep]
//
// 权限口径 [cmo.adoc:395-405]：
//   CMO 期望被**像 store/AMO 一样处理** ⇒ 相应异常用 store/AMO 口径
//   （即被 PMP 拒 ⇒ cause 7，见 T4）。恒等性约束 [norm:PMP_same]/[norm:PMA_same]：
//   block 内所有物理地址的 PMP/PMA 必须一致 —— 2A 由上层保证，本模块只提地址与动作。
//
// 动作语义（action_o 编码，供 L1D 执行）：
//   ACT_CLEAN : 写回（若脏）并**保留**副本
//   ACT_FLUSH : 写回（若脏）并**失效**副本
//   ACT_INVAL : **不写回**，直接失效副本（丢失脏数据是软件责任）
//   ACT_NONE  : 无动作（非 cbo 指令 / 被门控拦下）
//
// ★ 门控（CBIE/CBCFE）在 D 级预判 + M 级二次校验（08 §5.2 行为要点 ④）；
//   本模块只做动作与地址生成，**不做门控判定**（门控由 lsu/trap 侧决定是否本拍发起
//   CMO，或改为抛非法指令）。`inval_downgrade_i` 输入表达 menvcfg.CBIE=01 的
//   「INVAL 降级为 FLUSH」用户裁决口径（08 §6.5 表）。
//
// 风格（AGENT.md §4.3）：无 always 块；全部 assign + function。
//
// 端口契约（供 lsu.v 例化）：
//   is_cbo_i        : 1 ⇒ 本笔是 cbo.* 指令
//   cbo_rs2_i[4:0]  : cbo 动作选择（insn[24:20]；`RV32GC_CBO_*`）
//   va_i[31:0]      : cbo 指令的地址（rs1 值，**不必对齐**）
//   inval_downgrade_i: 1 ⇒ CBIE=01 ⇒ INVAL 降级为 FLUSH（用户裁决）
//   valid_o         : 1 ⇒ 输出的动作/地址有效
//   action_o[1:0]   : ACT_* 动作码
//   block_addr_o[31:0]: 向下对齐后的 block 起始物理地址（发往 L1D）
//   block_size_o[31:0]: block 字节数（64）
//   cause7_o        : 1 ⇒ 该 CMO 应报 store/AMO access fault（cause 7，T4）
//==============================================================================
`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"

module cmo_unit #(
    parameter integer BLOCK_SIZE = `RV32GC_CBOM_BLOCK_SIZE,   // 64（L2 行，用户裁决）
    parameter integer BLOCK_LSB  = `RV32GC_CBOM_BLOCK_LSB      // 6 ⇒ 2^6=64 B
) (
    input  wire        is_cbo_i,           // 本笔是 cbo.*
    input  wire [4:0]  cbo_rs2_i,          // 动作选择（insn[24:20]）
    input  wire [31:0] va_i,               // 地址（rs1，不必对齐）

    // ---- 门控降级与权限 ----
    input  wire        inval_downgrade_i,  // CBIE=01 ⇒ INVAL→FLUSH（用户裁决）
    input  wire        pmp_deny_i,         // PMP 拒 ⇒ cause 7（T4）

    // ---- 输出 ----
    output wire        valid_o,
    output wire [1:0]  action_o,
    output wire [31:0] block_addr_o,
    output wire [31:0] block_size_o,
    output wire        cause7_o
);

    //==========================================================================
    // 1. 动作码（本模块私有；与 l1d 的动作端口约定一致）
    //==========================================================================
    localparam [1:0] ACT_NONE  = 2'd0;
    localparam [1:0] ACT_CLEAN = 2'd1;   // 写回 + 保留
    localparam [1:0] ACT_FLUSH = 2'd2;   // 写回 + 失效
    localparam [1:0] ACT_INVAL = 2'd3;   // 直接失效（不写回）

    //==========================================================================
    // 2. 地址向下对齐到 block 边界 [T8：rs1 不要求块对齐]
    //    block 大小 = 2^BLOCK_LSB 字节 ⇒ 块内偏移位宽 = BLOCK_LSB
    //==========================================================================
    // 掩码生成用常量表达式（参数可配；BLOCK_LSB=6 ⇒ 掩码低 6 位全 1）
    localparam [31:0] BLOCK_OFF_MSK = (32'd1 << BLOCK_LSB) - 32'd1;
    localparam [31:0] BLOCK_SZ      = (32'd1 << BLOCK_LSB);

    assign block_addr_o = va_i & ~BLOCK_OFF_MSK;   // 向下对齐
    assign block_size_o = BLOCK_SZ;                // 64

    //==========================================================================
    // 3. 动作解码（纯组合）
    //    ★ 只认 clean/flush/inval 三个码；cbo.zero（rs2=00100）在 2A
    //      **不定义编码**（rv32_defs.vh §3.11）⇒ 落到 default ⇒ ACT_NONE，
    //      由 D 级译码器判为非法指令（cause 2），本模块不生成任何动作。
    //==========================================================================
    wire is_clean = (cbo_rs2_i == `RV32GC_CBO_CLEAN);
    wire is_flush = (cbo_rs2_i == `RV32GC_CBO_FLUSH);
    wire is_inval = (cbo_rs2_i == `RV32GC_CBO_INVAL);

    // 2A 只实现 Zicbom ⇒ 任何合法 cbo 都要求 is_cbo_i 且动作码合法
    wire cbo_legal = is_cbo_i && (is_clean || is_flush || is_inval);

    // INVAL 降级为 FLUSH（CBIE=01，08 §6.5 表）
    wire inval_as_flush = is_inval && inval_downgrade_i;

    assign action_o = !cbo_legal           ? ACT_NONE  :
                      (is_clean)           ? ACT_CLEAN :
                      (is_flush)           ? ACT_FLUSH :
                      /* is_inval */        (inval_as_flush ? ACT_FLUSH : ACT_INVAL);

    //==========================================================================
    // 4. 有效性与异常
    //==========================================================================
    // valid：动作有效 ⇒L1D 可以执行。PMP 被拒时不产生动作（由 cause7_o 报错）。
    assign valid_o = cbo_legal && !pmp_deny_i;

    // [T4] CMO 被 PMP 拒 ⇒ 恒 cause 7（store/AMO access fault；cmo.adoc:395-405
    //   明确期望按 store/AMO 处理）
    assign cause7_o = cbo_legal && pmp_deny_i;

endmodule
