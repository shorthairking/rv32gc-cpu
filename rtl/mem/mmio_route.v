//==============================================================================
// rtl/mem/mmio_route.v —— 核内 MMIO 分流 / 地址译码（M 级，纯组合）
//==============================================================================
// 项目    : rv32gc-cpu（阶段二 2A：单发射顺序 5 级基线核）
// 出处    : docs/design/08-baseline-5stage.md §5.4 行为要点 ⑦、§6.6 与地址译码流程图
//           docs/design/05-cache-memory.md §5.1（PMA 表口径）
// 唯一真源: rtl/pkg/rv32_defs.vh §10（CLINT_HIT_VAL / PLIC_HIT_VAL / *_HIT_VAL 掩码）
//           rtl/pkg/core_params.vh §1（XIP 主窗口）、§2（平台地址映射与 MMIO 掩码）
//           **include 顺序：先 rv32_defs.vh 后 core_params.vh**（AGENT.md §3.2）
//------------------------------------------------------------------------------
// 为什么必须有这个模块（08 §6.6）：
//   平台 `axi_mux_syn.v` 的从设备命中向量只有 5 项，**0x1F00/0x1F10 都不在其中** ⇒
//   自动命中 `addr_hit[0] = ~|addr_hit[4:1]` ⇒ **落到 DDR3 默认通路**。
//   后果是**静默数据损坏**（写 mtimecmp 会改掉 0x1F00_0000 处的 DDR3 内容），不报任何错。
//   因此核内**必须**截获 CLINT/PLIC，且**绝不发 AXI**。
//
// 译码优先级（严格按下表，逐级 if-else 语义用 assign + 遮蔽表达）：
//   ① 非对齐判定在**上游 lsu.v** 完成（08 §5.5 抉择 1：非对齐先于 PMP/分流）。
//   ② PA[31:16]==0x1F00 ⇒ 核内 CLINT          → route=ROUTE_CLINT，**绝不发 AXI**
//   ③ PA[31:16]==0x1F10 ⇒ 核内 PLIC           → route=ROUTE_PLIC ，**绝不发 AXI**
//   ④ PA[31:20]==0x1C0  ⇒ XIP 主窗口（直连）  → route=ROUTE_XIP
//      PA[31:16]==0x1FE8 ⇒ XIP 别名窗口（直连）→ route=ROUTE_XIP
//      （XIP 是**直连 AXI**、不查/不写 L1I，但它是独立通路，不是核内寄存器；
//       故单独一类，供 fetch/l1i 旁路使用 —— 08 §5.1 行为要点 ②）
//   ⑤ 平台外设窗口（1FE0 UART / 1FE7 NAND / 1FD0 confreg_syn / 1FAF confreg_sim /
//      1FF0 MAC）⇒ route=ROUTE_AXI（**非缓存**，AxCACHE=4'b0000）
//   ⑥ 其余（0x0–0x07FF_FFFF DDR3 默认通路）⇒ route=ROUTE_AXI（**可缓存**）
//
// ★ 本模块**只做分流判定**，不发请求、不实现协议：AXI 请求描述符的生成属
//   `rtl/axi/axi_req_desc.v`（cache/axi 组别），LSU 只依据本模块的 route 输出
//   选择通路。窗口判定与 axi_req_desc **共用同一份 PMA 表**（08 §7.1 要点 6），
//   表源即本文件与 rtl/pkg 的宏；改动必须两侧同步。
//
// 风格（AGENT.md §4.3）：无 always 块，全部 assign 连续赋值。
//
// 端口契约：
//   pa_i[31:0]      : 访问物理地址（翻译后）
//   is_fetch_i      : 1=取指通路（XIP 直连仅对取指有意义；数据侧命中 XIP 亦直连）
//   route_o[2:0]    : 见 localparam ROUTE_*
//   no_axi_o        : 1 ⇒ **绝不发 AXI**（CLINT/PLIC 核内截获）
//   axi_uncached_o  : 1 ⇒ 走 AXI 且必须置 AxCACHE=4'b0000（平台外设 / XIP）
//   axi_cached_o    : 1 ⇒ 走 AXI 且置 AxCACHE=4'b1111（DDR3 可缓存默认通路）
//   clint_plic_o    : 1 ⇒ 核内 MMIO（CLINT 或 PLIC）
//==============================================================================
`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"

module mmio_route #(
    parameter integer ADDR_W = 32
) (
    input  wire [ADDR_W-1:0] pa_i,            // 访问物理地址

    // ---- 分流结果 ----
    output wire [2:0]        route_o,         // ROUTE_*（纯 assign 驱动，无 always）
    output wire              no_axi_o,        // 1 ⇒ 绝不发 AXI（核内截获）
    output wire              clint_plic_o,    // 1 ⇒ 核内 CLINT 或 PLIC
    output wire              xip_direct_o,    // 1 ⇒ XIP 直连（1C0 / 1FE8）
    output wire              axi_uncached_o,  // 1 ⇒ 走 AXI，AxCACHE=4'b0000
    output wire              axi_cached_o,    // 1 ⇒ 走 AXI，AxCACHE=4'b1111

    // ---- 细分命中（供 clint/plic 例化与 TB 断言） ----
    output wire              clint_hit_o,     // 命中 0x1F00_0000 窗口
    output wire              plic_hit_o,      // 命中 0x1F10_0000 窗口
    output wire              periph_hit_o     // 命中平台外设窗口（UART/NAND/conf/MAC）
);

    //==========================================================================
    // 1. 路由编码（本模块私有；与 lsu.v 的 localparam 保持一致）
    //==========================================================================
    localparam [2:0] ROUTE_NONE  = 3'd0;   // 保留（不应出现）
    localparam [2:0] ROUTE_CLINT = 3'd1;   // 核内 CLINT —— 绝不发 AXI
    localparam [2:0] ROUTE_PLIC  = 3'd2;   // 核内 PLIC  —— 绝不发 AXI
    localparam [2:0] ROUTE_XIP   = 3'd3;   // XIP 直连（1C0 主窗口 / 1FE8 别名）
    localparam [2:0] ROUTE_AXI   = 3'd4;   // 经核内 AXI 主端口控制器

    //==========================================================================
    // 2. 窗口命中判定（全部走“掩码比较”统一形式，与 axi_req_desc 共用一份表）
    //    形式统一为 ((PA[hi:lo] & MSK) == VAL)，掩码取自 rtl/pkg 真源。
    //==========================================================================
    // ---- 2.1 核内私有窗口（PA[31:16] 全比较） --------------------------------
    // [DOC:08 §6.6；rv32_defs.vh §10]
    // 地址字面量登记（供 grep 复核与代码走查；与 rv32_defs.vh/core_params.vh 一致）：
    //   CLINT_BASE = 0x1F00_0000     PLIC_BASE = 0x1F10_0000
    //   XIP 主窗口 = 0x1C00_0000     XIP 别名  = 0x1FE8_0000
    wire [15:0] pa_hi16 = pa_i[31:16];

    // CLINT 0x1F00_0000 —— ★ 绝不发 AXI（核内截获，见 §6.6 的静默数据损坏说明）
    wire clint_hit = ((pa_hi16 & `RV32GC_CLINT_HIT_MSK) == `RV32GC_CLINT_HIT_VAL);
    // PLIC  0x1F10_0000 —— ★ 绝不发 AXI（核内截获）
    wire plic_hit  = ((pa_hi16 & `RV32GC_CLINT_HIT_MSK) == `RV32GC_PLIC_HIT_VAL);

    assign clint_hit_o  = clint_hit;
    assign plic_hit_o   = plic_hit;
    assign clint_plic_o = clint_hit || plic_hit;

    // ---- 2.2 XIP 窗口（主窗口 PA[31:20]==0x1C0；别名窗口 PA[31:16]==0x1FE8）---
    // [DOC:core_params.vh §1；08 §5.1 行为要点 ②]
    wire [11:0] pa_hi20    = pa_i[31:20];
    wire        xip_main   = ((pa_hi20 & `RV32GC_XIP_HI20_MSK) == `RV32GC_XIP_HI20_VAL);
    wire        xip_alias  = ((pa_hi16 & `RV32GC_CLINT_HIT_MSK) == `RV32GC_SPI_HIT_VAL);
    wire        xip_hit    = xip_main || xip_alias;

    assign xip_direct_o = xip_hit;

    // ---- 2.3 平台外设窗口（核内**不实现**，只登记以便正确标记非缓存） --------
    //   1FE0 UART / 1FE7 NAND / 1FD0 confreg_syn / 1FAF confreg_sim / 1FF0 MAC
    wire periph_uart  = ((pa_hi16 & `RV32GC_CLINT_HIT_MSK) == `RV32GC_APB_UART_VAL);
    wire periph_nand  = ((pa_hi16 & `RV32GC_CLINT_HIT_MSK) == `RV32GC_APB_NAND_VAL);
    wire periph_csyn  = ((pa_hi16 & `RV32GC_CLINT_HIT_MSK) == `RV32GC_CONF_SYN_VAL);
    wire periph_csim  = ((pa_hi16 & `RV32GC_CLINT_HIT_MSK) == `RV32GC_CONF_SIM_VAL);
    wire periph_mac   = ((pa_hi16 & `RV32GC_CLINT_HIT_MSK) == `RV32GC_MAC_HIT_VAL);
    wire periph_hit   = periph_uart | periph_nand | periph_csyn | periph_csim | periph_mac;

    assign periph_hit_o = periph_hit;

    //==========================================================================
    // 3. 优先级分流（CLINT > PLIC > XIP > 平台外设 > DDR3/AXI）
    //    用掩码链表达严格优先级，避免嵌套三元表达式难以复核。
    //==========================================================================
    wire sel_clint = clint_hit;
    wire sel_plic  = !sel_clint && plic_hit;
    wire sel_xip   = !(sel_clint || sel_plic) && xip_hit;
    wire sel_periph= !(sel_clint || sel_plic || sel_xip) && periph_hit;
    // 其余一律落 AXI（DDR3 默认通路 0x0–0x07FF_FFFF 及任何未登记地址）
    wire sel_axi   = !(sel_clint || sel_plic || sel_xip);

    assign route_o = sel_clint  ? ROUTE_CLINT :
                     sel_plic   ? ROUTE_PLIC  :
                     sel_xip    ? ROUTE_XIP   : ROUTE_AXI;

    //==========================================================================
    // 4. AXI 归属与缓存属性
    //==========================================================================
    // no_axi_o：**全部核内截获窗口** ⇒ 绝不发 AXI
    //   （CLINT/PLIC 是核内寄存器；XIP 虽直连平台 SPI 通路，但为 uncached 直连，
    //    仍由 AXI 主端口控制器发出 —— 见下 axi_uncached_o 的门控）
    assign no_axi_o = sel_clint || sel_plic;

    // 走 AXI 的两类缓存属性：
    //   · XIP 直连 / 平台外设 ⇒ 非缓存（AxCACHE=4'b0000）
    //   · 其余（DDR3）        ⇒ 可缓存（AxCACHE=4'b1111）
    assign axi_uncached_o = !no_axi_o && (sel_xip || sel_periph);
    assign axi_cached_o   = !no_axi_o && !(sel_xip || sel_periph);

endmodule
