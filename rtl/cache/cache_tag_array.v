//==============================================================================
// rtl/cache/cache_tag_array.v —— Cache Tag/valid/dirty 阵列（BRAM 双分支）
//==============================================================================
// 项目  : rv32gc-cpu（阶段二 2A：单发射顺序 5 级基线核）
// 归属  : docs/design/05-cache-memory.md §3.1、§8；08-baseline-5stage.md §7.3 第 6 条
// 作用  : 为 L1I/L1D 提供「按路例化」的 Tag 存储阵列。每项一条元数据：
//             { tag[TAG_W-1:0], dirty, valid }
//         由于 L1 索引与 4 KiB 页偏移对齐（VA[12:5]），同页内不存在别名，
//         2A **不把 ASID 放进 Tag**（05 §6：ASID 只影响 TLB 的虚拟地址匹配；
//         02 阶段无 ASID 参与 L1 匹配的实现需求）。
//
// ★ 双分支口径与 cache_array_bram.v 完全一致：
//   - 宏 `RV32GC_USE_VIVADO_IP **定义** ⇒ 综合走 Block Memory Generator；
//   - 宏**从不定义** ⇒ 逐拍等价行为模型（iverilog/Verilator 回归不依赖 Vivado）。
//
// ★ BRAM 只能同步读：本项目内 Tag 比较采用「上一拍预先读出、访问拍比对」
//   （l1i/l1d 的访问拍只做比较，不在组合路径上读阵列），即 tag 读数据
//   也是同步读（tag_rdata_r，读延迟 1 拍）。
//
// ★ 综合分支例化模板以注释给出（同 cache_array_bram.v），由 create_ip.tcl
//   生成 .xci；文件内**禁止原语**（RAMB36E1/RAMB18E1 等）。
//
// Vivado IP 检索结论（红线 1 证据）：选用 Block Memory Generator（简单双口）；
//   替代项不合适：Distributed Memory Generator（LUT 面积更大，Tag 阵列虽小，
//   但为与数据阵列统一 IP 生成流程仍用 BRAM）、FIFO Generator（语义不符）。
//==============================================================================
`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"

module cache_tag_array #(
    // ------------------------------------------------------------------------
    // 参数
    //   L1I：TAG_W = VA[31:13] ⇒ 19 bit（2 路 / 32 B 行 / 256 组）
    //   L1D：TAG_W = VA[31:13] ⇒ 19 bit（4 路 / 32 B 行 / 256 组）
    //   两项 tag 共用同一 TAG_W（两 L1 的索引/行大小相同）
    // ------------------------------------------------------------------------
    parameter integer TAG_W  = 19,     // 物理/虚拟 tag 位宽
    parameter integer SETS   = 256,    // 组数（每路一份 256 项）
    parameter integer ADDR_W = 8       // 组索引位宽 = log2(SETS)
) (
    input  wire                   clk,        // 同域时钟

    // ---- 写口（重填/写回后更新元数据；we 为整项写） ----
    input  wire                   wr_en,      // 写使能
    input  wire [ADDR_W-1:0]      wr_addr,    // 组索引（不含路号：路号由例化选择）
    input  wire [TAG_W-1:0]       wr_tag,     // 新 tag
    input  wire                   wr_valid,   // 新 valid
    input  wire                   wr_dirty,   // 新 dirty

    // ---- 读口（组合直达端口的同步读，读延迟 1 拍） ----
    input  wire                   rd_en,      // 读使能
    input  wire [ADDR_W-1:0]      rd_addr,    // 组索引
    output wire [TAG_W-1:0]       rd_tag_r,   // 读回 tag（1 拍后有效）
    output wire                   rd_valid_r, // 读回 valid（1 拍后有效）
    output wire                   rd_dirty_r, // 读回 dirty（1 拍后有效）

    // ---- 维护（RMW：只改 dirty，**保留** tag/valid） ----
    //   为 cbo.clean 提供"清 dirty 但不失效、不破坏数据"的能力。
    //   注：BRAM 是字级写口；此处用"读改写"在**同一拍**完成（读旧值 → 只改
    //   dirty 位 → 写回），读地址与写地址相同，行为模型与 BRAM 语义一致）。
    input  wire                   dirty_clr_en,   // 清 dirty 使能（按组）
    input  wire [ADDR_W-1:0]      dirty_clr_addr  // 组索引
);
    // ---- 元数据打包：单条 BRAM 字 = { tag, dirty, valid } ----
    localparam integer META_W = TAG_W + 2;              // 1 bit dirty + 1 bit valid
    localparam integer TAG_LSB  = 2;                    // meta[2 +: TAG_W] = tag
    localparam integer DIRTY_B  = 1;
    localparam integer VALID_B  = 0;

    wire [META_W-1:0] wr_meta = { wr_tag, wr_dirty, wr_valid };

    //--------------------------------------------------------------------------
    // 综合分支：Vivado Block Memory Generator（单口写 + 单口读，简单双口）
    //--------------------------------------------------------------------------
`ifdef RV32GC_USE_VIVADO_IP
    // ---- 读延迟 1 拍：不勾 Output Register ----
    // blk_mem_gen_cache_tag u_cache_tag (
    //     .clka  (clk),        // 写口时钟
    //     .ena   (wr_en),      // 写使能
    //     .wea   ({META_W{1'b1}}),  // 整项写（字节使能全 1；META_W 非 8 倍数，
    //                               //   IP 侧按 32 bit 字宽配置，高位补 0 即可）
    //     .addra (wr_addr),    // 写地址（组索引）
    //     .dina  (wr_meta),    // 写数据 = {tag, dirty, valid}
    //     .douta (),           // 未用
    //     .clkb  (clk),        // 读口时钟
    //     .enb   (rd_en),      // 读使能（Always Enabled 亦可）
    //     .web   ({META_W{1'b0}}),  // 读口不写
    //     .addrb (rd_addr),    // 读地址（组索引）
    //     .dinb  ({META_W{1'b0}}),
    //     .doutb ()            // 读数据（由行为模型同一接口提供，见下）
    // );
    // ※ 维护（只清 dirty）：同名 IP 的写口支持字节使能 ⇒ 用 wea 仅使能
    //   dirty 位所在字节即可（与仿真分支的"只改 dirty"语义逐拍等价）。
    // ※ 例化主体由 create_ip.tcl 生成（blk_mem_gen_cache_tag.xci）；
    //   META_W = TAG_W+2 需与 IP 的 Write/Read Width 一致（按 32 bit 对齐时取高位）。
`endif

    //--------------------------------------------------------------------------
    // 仿真分支（默认）：逐拍等价行为模型（同步读，读延迟 1 拍）
    //   必须用 always 块：建模存储元件的时钟沿行为，无法用 assign 表达。
    //--------------------------------------------------------------------------
`ifndef RV32GC_USE_VIVADO_IP
    reg [META_W-1:0] meta_q [0:SETS-1];

    integer init_i;
    initial begin
        for (init_i = 0; init_i < SETS; init_i = init_i + 1) begin
            meta_q[init_i] = {META_W{1'b0}};    // 复位后全部 invalid（valid=0）
        end
    end

    reg [META_W-1:0] rd_meta_q;

    always @(posedge clk) begin
        if (wr_en) meta_q[wr_addr] <= wr_meta;   // 同步写（整项）
        // ---- 维护：只清 dirty，保留 tag/valid（读改写，同址同拍） ----
        if (dirty_clr_en) begin
            meta_q[dirty_clr_addr][DIRTY_B] <= 1'b0;
        end
        if (rd_en) rd_meta_q <= meta_q[rd_addr]; // 同步读（先读后写：同址同拍读旧值）
    end

    assign rd_tag_r   = rd_meta_q[TAG_LSB +: TAG_W];
    assign rd_valid_r = rd_meta_q[VALID_B];
    assign rd_dirty_r = rd_meta_q[DIRTY_B];
`endif

    //--------------------------------------------------------------------------
    // 参数自检
    //--------------------------------------------------------------------------
    initial begin
        if ((1 << ADDR_W) != SETS) begin
            $display("CACHE_TAG_ARRAY FAIL: ADDR_W=%0d 与 SETS=%0d 不一致",
                     ADDR_W, SETS);
            $fatal(1, "CACHE_TAG_ARRAY PARAM FAIL");
        end
        if (TAG_W < 1 || TAG_W > 30) begin
            $display("CACHE_TAG_ARRAY FAIL: TAG_W=%0d 非法", TAG_W);
            $fatal(1, "CACHE_TAG_ARRAY PARAM FAIL");
        end
    end

endmodule
