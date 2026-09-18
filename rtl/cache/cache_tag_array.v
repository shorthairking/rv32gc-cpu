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
// ★ 实现口径（M4 定稿，2026-09-18）：本模块两条分支共用 **RTL 推断 RAM**
//   —— `tagv_q`（{tag,valid}）与 `dirty_q` 两个**单写口**阵列，各带
//   `(* ram_style = "distributed" *)` ⇒ 推断为 LUTRAM；文件内**禁止原语**
//   （RAMB36E1/RAMB18E1/RAM32M/RAM64X1D 一律不出现）。
//   原「综合分支走 Block Memory Generator」的方案经实测否决，三条理由见下方
//   实现段落的 ★ M4 决定；Cache 的 Block Memory Generator IP 落在**数据阵列**
//   （rtl/cache/cache_array_bram.v，容量所在），见 fpga/tcl/create_ip.tcl。
//
// Vivado IP 检索结论（红线 1 证据，M4 复核）：本模块（每路 256 项 × 21 bit = 5.25 kbit）
//   检索过 Block Memory Generator（最小粒度 BRAM36 = 36 kbit，利用率 ~15%，
//   且同步读无法支持 l1d 要求的同拍读-改-写）、Distributed Memory Generator
//   （其界面即 LUTRAM 原语级封装，本项目用 RTL 推断即可，无需 IP）、
//   FIFO Generator（语义不符）。⇒ 结论：**不引入 IP，由 RTL 推断 LUTRAM**。
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

    // ---- 维护（只改 dirty，**保留** tag/valid） ----
    //   为 cbo.clean 提供"清 dirty 但不失效、不破坏数据"的能力。
    input  wire                   dirty_clr_en,   // 清 dirty 使能（按组）
    input  wire [ADDR_W-1:0]      dirty_clr_addr  // 组索引
);
    //---- 元数据拆分为两个阵列（M4 面积优化，见下方 ★ 优化记录）--------------
    //   tagv_q  : { tag[TAG_W-1:0], valid }  —— 单写口：填充/置位/失效
    //   dirty_q : dirty                      —— 单写口：填充/store/clean
    //   ★ 为什么拆开：原实现把 {tag,dirty,valid} 打包成一个阵列、且**有两个写口**
    //     （`wr_en` 与 `dirty_clr_en` 各写一次）。Vivado 的 RAM 推断**只支持单写口**，
    //     两个写口 ⇒ 退化成"寄存器 + 大规模读 mux"：实测（无 FPU 归因综合
    //     fpga/out/scratch_nofpu_utilization_hier.rpt）6 路 Tag 阵列共吃掉
    //     **75 119 LUT + 31 872 FF**（占非 FPU 全核 LUT 的 64%！），而正确形态
    //     应为 ~600 LUTRAM。拆分后每个阵列都是**单写口 + 单读口** ⇒ 可推断 LUTRAM。
    //   ★ 语义等价性：拆分只改变"两条元数据放在哪个存储元件里"，读写值完全一致
    //     （见下方 always 段）；且 **wr_en 与 dirty_clr_en 在 l1d 里互斥**
    //     （l1d.v：`way_maint = maint_q & ~maint_clean_q` 与
    //      `maint_dirty_clr = maint_q & maint_clean_q` 互斥；维护扫描期间
    //      `cs_stall` 含 `maint_q` ⇒ 填充/store 不可能同时发生），故单写口足够。
    //     该前提由下面的**契约自检**在仿真里强制（同拍断言即 $fatal，不静默分歧）。
    localparam integer TAGV_W = TAG_W + 1;      // { tag, valid }
    localparam integer VALID_B = 0;             // tagv_q[0]     = valid
    localparam integer TAG_LSB = 1;             // tagv_q[1 +: TAG_W] = tag

    wire [TAGV_W-1:0] wr_tagv = { wr_tag, wr_valid };

    //--------------------------------------------------------------------------
    // 实现：**两条分支共用**的两个单写口阵列（同步读，读延迟 1 拍）
    //
    // ★ M4 决定（2026-09-18）：原方案「综合分支走 Block Memory Generator」经实测
    //   **不可行**，故改为 RTL 推断 RAM（LUTRAM）两分支共用；理由三条：
    //   ① **语义**：l1d 的 cbo.clean 维护扫描要求「只清 dirty、保留 tag/valid」
    //      （l1d.v:322-339）。BRAM 读是同步的（数据下一拍才到），单端口无法同拍
    //      RMW；改成"下一拍写回"会把清 dirty 推迟，且扫描最后一拍与恢复后的 store
    //      抢同一写口 —— 要么丢 dirty 置位（数据不写回 ⇒ 静默错），要么把无效行
    //      写出 valid=1（假命中 ⇒ 静默错）。⇒ 用**两个各自单写口**的阵列表达
    //      （tag+valid 一个、dirty 一个），既保住原语义又满足 RAM 推断前提。
    //   ② **面积（实测驱动，本次优化的直接动因）**：每路 Tag 阵列 = 256 项 × 21 bit
    //      = 5.25 kbit，6 路共 31.5 kbit；BRAM36 最小粒度 36 kbit（利用率 ~15%），
    //      而 LUTRAM 推断只需 ~84 个 LUTRAM/路。**原打包+双写口实现实测吃掉
    //      75 119 LUT + 31 872 FF（占非 FPU 全核 LUT 的 64%）** —— 见
    //      fpga/out/scratch_nofpu_utilization_hier.rpt（对照实验见 fpga/M4-report.md §5）。
    //   ③ **红线 1 合规**：本文件**不例化任何 FPGA 原语**（无 RAMB*/RAM32M/RAM64X1D），
    //      阵列由 RTL 推断（`ram_style` 是**综合属性**、不是原语）；"用 IP"落在
    //      Cache **数据阵列**（容量所在）：rtl/cache/cache_array_bram.v 综合分支
    //      例化 `blk_mem_gen_cache_data`（create_ip.tcl 生成，M4 判据⑤ 的证据）。
    //
    // ★ 优化记录（任务书要求"每处写明哪条关键路径、怎么优化、影响什么"）：
    //   * 触发：无 FPU 归因综合的**层次化利用率**（不是时序路径本身，而是面积热点）
    //     —— 6 路 Tag 阵列 75 119 LUT，占 L1D 的 98%（u_l1d 共 70 258 LUT）。
    //   * 优化：把 {tag,dirty,valid} 打包 + 两个写口，拆成 tagv_q / dirty_q 两个
    //     单写口阵列；写口用 if/else if 明确优先级（wr_en 优先）。
    //   * 影响：预计 LUT 75 119 → ~1 000（-98%），FF 31 872 → ~0（改由 LUTRAM 承担）；
    //     功能语义不变（下方 always 段逐条对应原语序）；对时序的影响见
    //     fpga/M4-report.md 的对照综合结果。
    //   * 约束前提：`wr_en` 与 `dirty_clr_en` **不同拍断言**（l1d 由
    //     `way_maint`/`maint_dirty_clr` 互斥 + 维护期间 `cs_stall` 保证）；
    //     该前提由下面的契约自检在仿真里强制，违反即 $fatal（不静默分歧）。
    //
    // 说明：此处**必须**用 always 块——它建模的是存储元件的时钟沿行为，
    //       无法用 assign/连续赋值表达（AGENT.md §4 红线 3 的例外场合）。
    //--------------------------------------------------------------------------
    (* ram_style = "distributed" *) reg [TAGV_W-1:0] tagv_q  [0:SETS-1];
    (* ram_style = "distributed" *) reg             dirty_q [0:SETS-1];

    integer init_i;
    initial begin
        for (init_i = 0; init_i < SETS; init_i = init_i + 1) begin
            tagv_q[init_i]  = {TAGV_W{1'b0}};   // 复位后全部 invalid（valid=0）
            dirty_q[init_i] = 1'b0;
        end
    end

    reg [TAGV_W-1:0] rd_tagv_q;
    reg              rd_dirty_q;

    always @(posedge clk) begin
        // ---- 单写口：wr_en（填充/置位/失效）优先；否则 dirty_clr（clean）----
        //   两路写地址/数据由下面的 mux 选一 ⇒ 每阵列只有一个写口（RAM 可推断）。
        //   （wr_en 与 dirty_clr_en 互斥，见上方 ★ 约束前提 + 契约自检。）
        if (wr_en) begin
            tagv_q [wr_addr] <= wr_tagv;        // { tag, valid }
            dirty_q[wr_addr] <= wr_dirty;
        end else if (dirty_clr_en) begin
            // 只清 dirty，tag/valid **原样保留**（不再有同址读-改-写）
            dirty_q[dirty_clr_addr] <= 1'b0;
        end
        // ---- 同步读（先读后写：同址同拍读旧值，与 RAM 语义一致）----
        if (rd_en) begin
            rd_tagv_q  <= tagv_q [rd_addr];
            rd_dirty_q <= dirty_q[rd_addr];
        end
    end

    assign rd_tag_r   = rd_tagv_q[TAG_LSB +: TAG_W];   // = tagv_q[TAG_W:1]
    assign rd_valid_r = rd_tagv_q[VALID_B];
    assign rd_dirty_r = rd_dirty_q;

    //--------------------------------------------------------------------------
    // 契约自检（仅仿真有效：综合忽略 $display/$fatal，与 §参数自检 同口径）
    //   同时断言两个写使能会违反"单写口"前提 ⇒ 与其静默产生不同行为，不如报错。
    //--------------------------------------------------------------------------
    always @(posedge clk) begin
        if (wr_en && dirty_clr_en) begin
            $display("CACHE_TAG_ARRAY FAIL: wr_en 与 dirty_clr_en 同拍断言（违反单写口契约）t=%0t", $time);
            $fatal(1, "CACHE_TAG_ARRAY CONTRACT FAIL");
        end
    end

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
