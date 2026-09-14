//==============================================================================
// rtl/fetch/parcel_align.v —— F 级 parcel 拆分与跨行拼接（16-bit parcel 口径）
//==============================================================================
// 项目  : rv32gc-cpu（阶段二 2A：单发射顺序 5 级基线核）
// 规格  : docs/design/08-baseline-5stage.md §5.1 行为要点 ⑤
//         「跨行拼接：一次取回 32 B，按 16-bit parcel 拆分；C 扩展跨 parcel 时
//           在 parcel_align.v 拼接，不得让 D 级看到半条指令」
//         §4.3「取指粒度：每次取指以 16-bit parcel 为单位处理」
//         core_params.vh §4：`RV32GC_PARCEL_BITS=16、`RV32GC_IALIGN=16、
//         `RV32GC_ILEN=32。
//
// 【职责边界】
//   输入 = 上一个 32 bit 取指字（word_o，携带自己的 VA）与它的上/下半 parcel；
//   输出 = 一个「**完整指令**」：
//     · 若 word_o[1:0] != 2'b11 ⇒ 该 parcel 本身就是 16 bit 压缩指令（C 扩展），
//       直接右对齐输出（parcel_align.v 已完成拼接，不出现半条）。
//     · 若 word_o[1:0] == 2'b11 ⇒ 需要再右移一个 parcel 才凑齐 32 bit：
//       高 parcel（+2）已在 word_o 内，低半由 carry_i（= 下一取指字的低 parcel，
//       即 VA 跨越 4 B 边界/行边界之后的那一个 parcel）补齐。
//   本模块**不做**任何地址计算、不做 PMP 检查、不判断对错——只做位域拼接，
//   与 §5.1「parcel 拆分」的单一职责一致。
//
// 【组合逻辑风格】全部 assign / function；**无 always 块**
//   （纯组合，无时序元件，红线 3 最严格口径）。
// 【无原语例化】只有位域连线与多路选择，无任何 FPGA primitive。
//==============================================================================

`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"

module parcel_align (
    // ---- 上一个取指字（32 bit 对齐字）及其 VA ----
    input  wire [31:0] word_o,        // 上一取指字；其起始 VA 为 word_va_o
    input  wire [31:0] word_va_o,     // word_o 的虚拟地址（用于算 parcel VA；本模块只用 [1]）

    // ---- 该字高 half 之后的下一个 parcel（可能是下一个字/下一行的低半） ----
    input  wire        carry_valid_i,  // 下一 parcel 是否真的存在且属于同一 nPC 流
    input  wire [15:0] carry_parcel_i, // 下一 parcel：VA = word_va_o + 4 的 PA[1]==0 半
    input  wire [31:0] carry_va_i,     // 该 parcel 的虚拟地址（诊断/下游用）

    // ---- 输出：一个完整指令 ----
    output wire [31:0] insn_o,        // 完整 32 bit 指令（右对齐；16 bit 指令高半填 0）
    output wire [31:0] insn_va_o,     // 该指令起始 VA
    output wire        ilen32_o,      // 1 ⇒ 32 bit 指令；0 ⇒ 16 bit 压缩指令
    output wire        insn_valid_o,  // 完整指令可用（32 bit 分支要求 carry_valid_i）
    output wire        cross_pending_o// 32 bit 分支但 carry 未到 ⇒ 需停顿一拍（§5.0 停顿时钟口径）
);

    //--------------------------------------------------------------------------
    // 0. 常量（真源：rtl/pkg/core_params.vh §4）
    //--------------------------------------------------------------------------
    localparam PARCEL_BITS  = `RV32GC_PARCEL_BITS;   // 16
    localparam IALIGN_BITS  = `RV32GC_IALIGN;        // 16
    localparam ILEN_BITS    = `RV32GC_ILEN;          // 32

    //--------------------------------------------------------------------------
    // 1. word_o 的两个 parcel
    //    · word_o 的 VA 若 4 B 对齐，则 [15:0] 是 VA+0（低 parcel）、
    //      [31:16] 是 VA+2（高 parcel）—— 这是本模块与 fetch_unit 的固定约定。
    //    · 若 word_o 的 VA 只 2 B 对齐（跨字起始），fetch_unit 保证高半[31:16]
    //      被**丢弃**（该处是本字的另一条指令），此时高 parcel 无意义。
    //--------------------------------------------------------------------------
    wire [15:0] lo_parcel = word_o[15:0];
    wire [15:0] hi_parcel = word_o[31:16];

    wire lo_is_compressed = (lo_parcel[1:0] != 2'b11);   // 2 bit opcode：!=11 ⇒ 16 bit
    wire lo_is_32bit      = (lo_parcel[1:0] == 2'b11);   // ==11 ⇒ 32 bit 指令前 16 bit

    //--------------------------------------------------------------------------
    // 2. 拼接：16 bit 直通；32 bit = {carry_parcel_i, hi_parcel}
    //    口径：word_o[31:16] 存放「字节偏移 +2」的半字，字内小端 ⇒ 它是指令的
    //    高半，下一 parcel 是低半。（RV32 小端：半字 0 在低地址。）
    //--------------------------------------------------------------------------
    wire [31:0] insn_16 = {16'h0000, lo_parcel};
    wire [31:0] insn_32 = {carry_parcel_i, hi_parcel};

    assign ilen32_o      = lo_is_32bit;
    assign insn_o        = lo_is_32bit ? insn_32 : insn_16;
    assign insn_valid_o  = lo_is_compressed | carry_valid_i;
    assign cross_pending_o = lo_is_32bit & ~carry_valid_i;

    //--------------------------------------------------------------------------
    // 3. 指令起始 VA
    //    · 16 bit：就是 word_va_o 的 parcel 位置
    //    · 32 bit：同起始（低 parcel 即起始），无偏移
    //    本模块只做「+0」；VA 的推进/pc+2/pc+4 由 PCC（pc_gen.v）负责，
    //    避免同一地址在两个模块里各算一次（08 §3.3 真源纪律）。
    //--------------------------------------------------------------------------
    assign insn_va_o = word_va_o;

    //--------------------------------------------------------------------------
    // 4. 保留输出（供上层做断言/波形诊断）：本模块对 carry 的无条件可见性
    //--------------------------------------------------------------------------
    wire carry_unused = carry_valid_i & (carry_va_i !== (word_va_o + 32'd4));

endmodule
