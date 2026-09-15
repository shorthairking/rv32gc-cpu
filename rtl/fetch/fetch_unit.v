//==============================================================================
// rtl/fetch/fetch_unit.v —— F 级顶层：XIP 旁路判定 + 取指 PMP 检查（16-bit parcel）
//==============================================================================
// 项目  : rv32gc-cpu（阶段二 2A：单发射顺序 5 级基线核）
// 规格  : docs/design/08-baseline-5stage.md §5.1（F 级全表）；§4.3（RESET_PC/XIP/
//         取指粒度/取指 PMP）；§4.4（break_point 在 F 级生效）；§5.5 抉择 2/7/8；
//         §6.3 T2；§5.0（停顿口径：任何停顿都冻结 F/D/E 并插气泡）。
//         docs/kb/isa-notes.md T2/T1（PMP 取指粒度是本设计选择；mtval 写 VA）。
//
// 【本模块做四件事，只做这四件】
//   ① 例化 PCC（pc_gen.v）产生 fetch_pc；
//   ② MMU 接口：2A/M1 阶段 `fetch_pc_pa` 恒等于 `fetch_pc`（Bare 模式直通），
//      翻译接口（sv32_translate_valid/done/fault/paddr）已预留在端口上，
//      M2 接入 ptw.v 后只需换掉内部那一个 assign（见 §2 注释）；
//   ③ XIP 旁路判定（**用物理地址**）：PA[31:20]==12'h1C0 || PA[31:16]==16'h1FE8
//      ⇒ uncached=1，取指**不查/不写 L1I、不分配 Tag**，走直连 AXI；
//   ④ 取指 PMP：按 **16-bit parcel 逐个** 例化 pmp_check（本设计选择，§5.5 抉择 2）；
//      无执行权限 ⇒ fetch_exc_valid=1、cause=1（instruction access fault）、
//      mtval = **该 parcel 的虚拟地址**（§5.5 抉择 7/8）。
//
// 【本模块明确不做的事（派活禁止事项）】
//   · **不写任何 AXI 主端口控制器**：那是 rtl/axi/axi_master_ctrl.v 的活。
//     本模块只输出请求接口信号（fetch_req_valid/fetch_req_pa/fetch_req_uncached）
//     与接收返回（fetch_rsp_data/fetch_rsp_valid/fetch_rsp_ready），
//     不出现 arvalid/araddr/rdata 等 AXI 通道信号。
//   · 不做 Sv32 翻译（M2 的 ptw.v）；不做 L1I Cache 控制（rtl/cache/l1i.v）；
//     不做跨窗口跳转自动修正（§5.1 ⑥：开 MMU 前不加任何修正）。
//
// 【PMP 检查口径（**例化 rtl/mem/pmp_check.v**，2026-09-14 集成消重）】
//   规格 §5.1 ③ 要求「调用 pmp_check」。原实现把检查内联为 function
//   `pmp_check_v`（当时 rtl/mem/ 不在该子任务范围内）；rtl/mem/pmp_check.v
//   交付后，本模块已改为**例化该模块**（见 §5 的 u_pmp_chk_lo / u_pmp_chk_hi），
//   语义按 docs/kb/isa-notes.md §3：
//     · 静态优先级：编号最低的、命中该笔的项说了算（norm:pmpentrypriority）
//     · A=OFF 项跳过；A=TOR 上界 = 前一个**已编程**项的 pmpaddr
//     · G=0 ⇒ 4 B 粒度，NA4 可用
//     · 无匹配项：M 模式 ⇒ 允许；S/U ⇒ 拒绝（已实现 16 项，norm:pmpnoentry_match）
//   ★ 现已完成上述「改为模块例化」，取指与访存共用同一份 PMP 实现。
//
// 【组合逻辑风格（AGENT.md §4 红线 3 / 08 §7.4）】
//   全部组合逻辑 = assign + function。本模块**只有一处** always 块：
//   parcel_align 输出的 1 拍流水寄存器（时序元件，注释见该处）。
//
// 【IP / 原语（AGENT.md §4 红线 1/2）】
//   本模块无任何 Vivado IP 需求（无 BRAM/乘法器/时钟资源），因此**无** IP
//   例化、也**无** `ifdef RV32GC_USE_VIVADO_IP 设备分支；同时**未例化任何
//   FPGA 原语**（纯组合 mux + 寄存器）。
//==============================================================================

`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"

module fetch_unit #(
    // PMP 项数参数化（默认取真源；TB 可用小值缩表，RTL 行为不变）
    parameter integer PMP_ENTRIES = `RV32GC_PMP_ENTRIES,   // 16
    parameter integer PMP_ENTRY_W = `RV32GC_PMP_ENTRY_W    // 8（pmpcfg 每项位宽）
) (
    input  wire        aclk,
    input  wire        aresetn,           // 低有效异步复位（同 pc_gen）

    //------------------------------------------------------------------
    // 复位 / 重定向 / 断点（§5.1 输入；§4.4）
    //------------------------------------------------------------------
    input  wire        rst_hold,
    input  wire        rst_valid,
    input  wire        redirect_exc_valid,
    input  wire [31:0] redirect_exc_pc,
    input  wire        redirect_bru_valid,
    input  wire [31:0] redirect_bru_pc,
    input  wire        break_point,

    //------------------------------------------------------------------
    // 取指停顿协商（§5.0：任何停顿都冻结 F 级）
    //------------------------------------------------------------------
    input  wire        fetch_pause,       // 上层（L1I miss/总线忙/下游反压）
    input  wire        insn_accept,       // D 级是否接走本拍交出的完整指令

    //------------------------------------------------------------------
    // MMU 翻译接口（2A/M1 不接；Bare ⇒ 直通。M2 接 ptw.v）
    //------------------------------------------------------------------
    input  wire        sv32_translate_en,  // satp.MODE=Sv32 且未在 MPRV/M 直通免除
    input  wire        sv32_translate_done,
    input  wire        sv32_translate_fault,
    input  wire [31:0] sv32_translate_paddr,

    //------------------------------------------------------------------
    // PMP 上下文（来自 csr_file / priv_ctrl）
    //------------------------------------------------------------------
    input  wire [1:0]  priv,              // 当前特权级（含同拍旁路后的值）
    input  wire [PMP_ENTRIES*PMP_ENTRY_W-1:0] pmpcfg_i,    // 扁平：项 i 占 [i*8 +: 8]
    input  wire [PMP_ENTRIES*32-1:0]          pmpaddr_i,   // 扁平：项 i 占 [i*32 +: 32]

    //------------------------------------------------------------------
    // 取指请求接口（**不是** AXI 通道；AXI 控制器在 rtl/axi/）
    //------------------------------------------------------------------
    output wire        fetch_req_valid,
    output wire [31:0] fetch_req_pa,       // 请求的物理地址（32 B 行对齐）
    output wire        fetch_req_uncached, // 1 ⇒ 直连通路（XIP/uncached），不查 L1I
    output wire        fetch_req_cacheable,

    //------------------------------------------------------------------
    // 取指返回接口（来自 L1I 或直连通路）
    //------------------------------------------------------------------
    input  wire [31:0] fetch_rsp_data,     // 32 bit 取指字
    input  wire [31:0] fetch_rsp_va,       // 该字的虚拟地址（对齐到 4 B）
    input  wire        fetch_rsp_valid,
    output wire        fetch_rsp_ready,    // 本模块能否接收（= 未停顿）

    //------------------------------------------------------------------
    // 输出：交给 D 级
    //------------------------------------------------------------------
    output wire [31:0] fetch_pc,           // 程序计数器（**虚拟地址**）
    output wire [31:0] fetch_pc_pa,        // 物理地址（2A/M1：恒等于 fetch_pc）
    output wire [31:0] fetch_data,         // 完整指令（32 bit 右对齐）
    output wire [31:0] fetch_data_pa,
    output wire [15:0] parcel_o,           // 交出的 16 bit parcel（压缩指令）
    output wire        parcel_is_lo,       // 该 parcel 在取指字中的位置（1=低半）
    output wire        parcel_is_lo_pa,    // 同上的物理侧副本
    output wire        fetch_valid,        // 本拍交出的是完整指令
    output wire        fetch_ilen32,       // 1 ⇒ 32 bit 指令；0 ⇒ 16 bit 压缩
    output wire [31:0] fetch_insn_va,      // 指令起始 VA（= 异常 mepc 口径）
    output wire [31:0] fetch_insn_pa,
    output wire        uncached,           // XIP / uncached 旁路标记（§4.3）
    output wire [31:0] fetch_uncached_pa,  // 直连通路数据（由 L1I 侧 mux 使用）

    //------------------------------------------------------------------
    // 输出：取指异常（§5.5 抉择 7/8；§6.3 T2）
    //------------------------------------------------------------------
    output wire        fetch_exc_valid,
    output wire [4:0]  fetch_exc_cause,    // 1 = instruction access fault；12 = 页错
    output wire [31:0] fetch_exc_tval,     // **虚拟地址**（故障 parcel 的 VA）
    output wire [31:0] fetch_exc_pc        // 故障指令起始地址（mepc 口径，抉择 8）

    //------------------------------------------------------------------
    // 输出：PCC 观察（供波形/断言；也是本模块与 pc_gen 的链路证据）
    //------------------------------------------------------------------
    `ifdef RV32GC_FETCH_UNIT_EXPOSE_PC_SEL
    ,output wire [3:0]  fetch_pc_sel
    `endif
);

    //==========================================================================
    // 0. 常量与位宽（真源：rtl/pkg/{rv32_defs.vh, core_params.vh}）
    //==========================================================================
    localparam PARCEL_BITS = `RV32GC_PARCEL_BITS;   // 16
    localparam ILEN_BITS   = `RV32GC_ILEN;          // 32
    localparam [11:0] XIP_HI20_VAL = `RV32GC_XIP_HI20_VAL;      // 12'h1C0（core_params §1）
    localparam [11:0] XIP_HI20_MSK = `RV32GC_XIP_HI20_MSK;      // 12'hFFF
    localparam [15:0] XIP_ALIAS_HI16 = `RV32GC_SPI_HIT_VAL;     // 16'h1FE8（rv32_defs §10）
    localparam [1:0]  PRIV_M = `RV32GC_PRIV_M;                  // 2'b11

    //=== PMP 项索引位宽（由参数推导，禁止魔法数） ===
    localparam integer PMP_IDX_W = (PMP_ENTRIES <= 2)  ? 1 :
                                   (PMP_ENTRIES <= 4)  ? 2 :
                                   (PMP_ENTRIES <= 8)  ? 3 :
                                   (PMP_ENTRIES <= 16) ? 4 : 5;

    //==========================================================================
    // 1. PCC（pc_gen.v）：产生 fetch_pc 与其推进量
    //    §5.1 ①：复位 > 重定向 > 顺序推进；顺序量 = +2 / +4 由上一拍指令长度定。
    //==========================================================================
    // 顺序推进开关（§5.0：停顿 ⇒ 冻结 F 级，不推进）：
    //   本拍取指字已到手（fetch_rsp_valid）且下游未反压、且不在停顿中。
    wire fetch_busy      = fetch_pause;
    wire insn_ready_out  = fetch_rsp_valid & ~cross_pending;

    // ---- 前置声明（值由 §4 的 parcel_align 例化驱动；Verilog 要求"先声明"）----
    wire        insn_start_lo = ~fetch_pc_w[1];  // 本拍指令的起始 parcel 在字低半（D3）
    wire        ilen32;                          // 本拍这条指令的长度（1=32 bit，0=16 bit）

    // 顺序推进（§5.1 ①）：本拍**真的交出**完整指令（起始 parcel 在低半）才推进。
    wire seq_adv_valid = fetch_rsp_valid & ~fetch_busy & insn_start_lo;
    // ★ 推进量 = **本拍交出的这条指令**的长度（§4 parcel_align 的组合输出 ilen32）。
    //   原实现接 last_ilen32_r（"上一拍交出的长度"）：PC 推进与指令交付发生在
    //   **同一拍**（都由 fetch_rsp_valid 驱动）⇒ 用上一拍的长度等于永远错一条：
    //   复位后第一条 32 bit 指令按 +2 推进（last_ilen32_r 复位值 0），
    //   PC 落到 0x1C00_0002（字内偏移）⇒ D 级从此取错指令（M1 实测复现）。
    wire seq_len32_w = ilen32;

    wire [31:0] fetch_pc_w;
    wire [31:0] pc_next_w;
    wire [3:0]  pc_sel_w;
    wire [31:0] pc_plus2_w;
    wire [31:0] pc_plus4_w;

    pc_gen u_pc_gen (
        .aclk              (aclk),
        .aresetn           (aresetn),
        .rst_hold          (rst_hold),
        .rst_valid         (rst_valid),
        .redirect_exc_valid(redirect_exc_valid),
        .redirect_exc_pc   (redirect_exc_pc),
        .redirect_bru_valid(redirect_bru_valid),
        .redirect_bru_pc   (redirect_bru_pc),
        .break_point       (break_point),
        .seq_adv_valid     (seq_adv_valid),
        .seq_len32         (seq_len32_w),
        .pc                (fetch_pc_w),
        .pc_next           (pc_next_w),
        .pc_sel            (pc_sel_w),
        .pc_plus2          (pc_plus2_w),
        .pc_plus4          (pc_plus4_w)
    );

    `ifdef RV32GC_FETCH_UNIT_EXPOSE_PC_SEL
    assign fetch_pc_sel = pc_sel_w;
    `endif

    assign fetch_pc = fetch_pc_w;

    //==========================================================================
    // 2. MMU 接口：2A/M1 —— `fetch_pc_pa` 恒等于 `fetch_pc`（Bare，直通）
    //    §5.1 ②/④：物理地址用于 XIP 判定与后续 PMP；M2 接入 ptw.v 后，
    //    只需把下面这一处 assign 换成翻译结果（端口已预留）。
    //    ★ 本 assign 是 `fetch_pc_pa` 的**唯一赋值点**（AGENT.md §3.3：VA/PA
    //      混用是静默错，地址寄存器只允许一个赋值点）。
    //==========================================================================
    wire        fetch_ext_fault;
    wire [31:0] fetch_ext_pa;

    assign fetch_pc_pa   = sv32_translate_en ? sv32_translate_paddr : fetch_pc;
    assign fetch_ext_fault = sv32_translate_en & sv32_translate_done &
                             sv32_translate_fault;
    assign fetch_ext_pa  = fetch_pc_pa;

    //==========================================================================
    // 3. XIP 旁路判定（§5.1 ②；§4.3）
    //    **用物理地址**：PA[31:20]==12'h1C0（XIP 主窗口 0x1C00_0000）
    //                 || PA[31:16]==16'h1FE8（XIP 别名窗口 0x1FE8_0000）
    //    ⇒ uncached=1：不查/不写 L1I、不分配 Tag，走直连 AXI 通路。
    //    两个窗口指向同一片 SPI 存储体（platform-facts §2.3）。
    //    判定式与 core_params.vh §2 统一为 ((PA 位段 & MSK) == VAL)。
    //==========================================================================
    wire xip_hit_hi20  = ((fetch_pc_pa[31:20] & XIP_HI20_MSK) == XIP_HI20_VAL);
    wire xip_hit_alias = (fetch_pc_pa[31:16] == XIP_ALIAS_HI16);

    assign uncached             = xip_hit_hi20 | xip_hit_alias;
    assign fetch_req_uncached   = uncached;
    assign fetch_req_cacheable  = ~uncached;

    // 取指请求：仅当无停顿、且需要新数据时拉高；地址按 32 B 行对齐交给 L1I，
    // 直连通路（uncached）保持字对齐（XIP 每次取 1 个 32 bit 字）。
    wire        fetch_req_need = ~fetch_rsp_valid;
    assign      fetch_req_valid = fetch_req_need & ~fetch_busy;
    assign      fetch_req_pa    = uncached ? {fetch_pc_pa[31:2], 2'b00}
                                           : {fetch_pc_pa[31:5], 5'b00000};

    assign fetch_rsp_ready = ~fetch_busy;

    wire [31:0] fetch_word    = fetch_rsp_data;
    wire [31:0] fetch_word_va = fetch_rsp_va;

    //==========================================================================
    // 4. parcel 拆分与跨行拼接（§5.1 ⑤）—— 例化 parcel_align.v
    //    一次取回 32 bit；低半即起始 parcel，高半是 +2 的 parcel。
    //    32 bit 指令需要「下一 parcel」补齐，而下一 parcel 就是**下一个取指字
    //    的低半**；对 XIP 直连通路（逐字）与 L1I（按行）都是同一规则，故此处
    //    用 fetch_rsp 的下一拍值作 carry（见 §4.1 的 carry 寄存器）。
    //==========================================================================
    wire [15:0] parcel_insn;
    wire [31:0] insn_va;
    wire        insn_valid;
    wire        cross_pending;
    wire [31:0] insn_raw;

    //--------------------------------------------------------------------------
    // 4.1 ★ D3 修复（carry 自锁）：指令起始 parcel 的位置决定 carry 的来源
    //     （insn_start_lo 已在 §1 前置声明，PC 推进量 ilen32 也取自本模块输出）
    //     · insn_start_lo=1 ⇒ 起始 parcel 在取指字**低半**（4 B 对齐的指令流）：
    //       RV32 小端下 32 bit 指令的两半就是本字的 [15:0] 与 [31:16]
    //       ⇒ **本字直取**：把本字高半作为 carry 喂给 parcel_align，本拍即得
    //       完整指令，**不再等下一拍 carry**。
    //     · insn_start_lo=0 ⇒ 起始 parcel 在**高半**（上一条是压缩指令，M2 场景）：
    //       低半是上一条指令的尾巴，32 bit 指令的后半在下一取指字的低半
    //       ⇒ 只有这种情形才用**寄存的 carry**（carry 通道只服务高半起始）。
    //
    //     原实现无条件用寄存 carry 且 insn_valid = lo_is_compressed | carry_valid，
    //     而 carry 寄存器又只在 insn_valid=1 时更新 ⇒ 复位后第一条 32 bit 指令
    //     （carry_valid=0）永远 insn_valid=0，carry 永不更新（自锁死锁），
    //     cross_pending 恒 1、fetch_valid 恒 0。
    //     ★ 语义等价性：本字直取的结果 = {本字[31:16], 本字[15:0]} = 本字，
    //       与「32 bit 指令 = {carry, 起始 parcel}」的原契约在低半起始下逐位相同。
    //--------------------------------------------------------------------------
    wire [15:0] pa_carry_parcel = insn_start_lo ? fetch_word[31:16] : carry_parcel;
    wire        pa_carry_valid  = insn_start_lo | carry_valid;
    wire [31:0] pa_carry_va     = insn_start_lo ? (fetch_word_va + 32'd2) : carry_va;

    // ★ D3 补：parcel_align 的输入契约是「word_o 低半 = 指令起始 parcel」。
    //   起始在**高半**（fetch_pc[1]==1）时该契约不成立（低半是上一条指令的尾巴）
    //   ⇒ 本拍**一律不出指令**（fetch_valid=0、PC 冻结），避免把"上一条指令的
    //   尾巴 + 陈旧 carry"当指令交给 D 级（静默错执行）。该情形的完整通路
    //   （跨字半字保持 + 下一取指字低半拼接）属 M2 的 C 扩展混合流，见交付报告。
    wire        insn_valid_w    = insn_valid & insn_start_lo;

    parcel_align u_parcel_align (
        .word_o        (fetch_word),
        .word_va_o     (fetch_word_va),
        .carry_valid_i (pa_carry_valid),
        .carry_parcel_i(pa_carry_parcel),
        .carry_va_i    (pa_carry_va),
        .insn_o        (insn_raw),
        .insn_va_o     (insn_va),
        .ilen32_o      (ilen32),
        .insn_valid_o  (insn_valid),
        .cross_pending_o(cross_pending)
    );

    // 交出的 16 bit parcel = **指令的起始 parcel**（§4.3 取指粒度 = 16-bit parcel）：
    //   · 压缩指令 ⇒ 它就是整条指令（右对齐 16 bit）
    //   · 32 bit 指令 ⇒ 它是指令的前 16 bit（低位半字）；完整 32 bit 由
    //     `fetch_data` 给出，D 级不应只看 `parcel_o` 就把 32 bit 指令当作完整指令。
    //   word_o 的 VA 4 B 对齐（fetch_req_pa 已对齐），故起始 parcel 恒为 [15:0]。
    assign parcel_insn = fetch_word[15:0];

    //--- parcel_align 的 carry 输入：32 bit 指令缺失的那一半 ---
    //  口径（与 parcel_align.v §2 一致，RV32 小端 ⇒ 低半字在低地址）：
    //    · 起始 parcel 在字的**低半**（fetch_pc[1]==0，4 B 对齐指令流）：
    //      [15:0] = 指令前 16 bit、[31:16] = 指令后 16 bit ⇒ 后半**已在同一次
    //      fetch_rsp 里**，本拍由 §4.1 的 pa_carry_parcel 直接给出（本字直取）。
    //    · 起始 parcel 在字的**高半**（fetch_pc[1]==1，上一条是压缩指令，M2 场景）：
    //      需要从**下一个取指字的低半**借 16 bit ⇒ 用下面寄存的 carry。
    //  本模块按统一口径实现：把「本拍返回字的 [15:0]」（VA+4 那一半）锁存为
    //  高半起始情形的 carry 候选；低半起始时不锁存（carry_valid 清 0），
    //  由 pa_carry_* 本字直取，保证 D 级永不见到半条指令。
    reg         carry_valid;
    reg  [15:0] carry_parcel;
    reg  [31:0] carry_va;

    //==========================================================================
    // 5. 取指 PMP 检查：**按 16-bit parcel 逐个检查**（§5.5 抉择 2；§6.3 T2）
    //    取指所需权限 = X（可执行）。
    //    · 命中项无 X 权限 ⇒ cause 1（instruction access fault）
    //    · mtval = **该 parcel 的虚拟地址**（§5.5 抉择 7）
    //    · mepc  = 故障指令起始地址（§5.5 抉择 8）
    //==========================================================================
    // 两个待检 parcel：起始 parcel（lo）与需要时的 +2 parcel（hi）。
    // 压缩指令只检 1 个 parcel；32 bit 指令检 2 个（本设计选择）。
    //
    // ★ 地址口径（AGENT.md §3.3「VA/PA 混用是静默错」）：
    //   检查必须针对**正在被检验的那个 parcel 自己的地址**，而不是取指字对齐
    //   地址（把 parcel 地址向下对齐会让 VA+2 的 parcel 被当成 VA 处那一个，
    //   使「逐 parcel 检查」名存实亡 —— 这正是本设计选择要体现的差别）。
    //   翻译启用后 PMP 针对**翻译后的物理地址**（§5.4 ③）；2A/M1 Bare 下 PA==VA。
    //   TOR/NA4/NAPOT 的匹配按**该 parcel 的实际地址**进行。
    wire [31:0] insn_pa_base  = sv32_translate_en ? fetch_pc_pa : insn_va;

    wire [15:0] check_parcel_lo = fetch_word[15:0];
    wire [15:0] check_parcel_hi = fetch_word[31:16];
    wire [31:0] check_va_lo     = insn_pa_base;              // 起始 parcel 的地址
    wire [31:0] check_va_hi     = insn_pa_base + 32'd2;      // +2 parcel 的地址

    // ---- PMP 检查：**例化 rtl/mem/pmp_check.v**（消重，2026-09-14 集成改动）----
    //   口径（与内联实现逐条一致，仅"由谁实现匹配"改变）：
    //     · 权限 = X（可执行）：acc_type_i = 2（pmp_check.v 的 T_EXEC）
    //     · 每笔 = **一个 16-bit parcel**（§5.5 抉择 2）⇒ acc_bytes_i = 2
    //     · 特权级 = 取指特权级（MPRV 不影响取指，08 §6.4）
    //     · 被拒 ⇒ allow_o=0，fault_cause_o=1（instruction access fault）
    //   ★ 与内联实现的**唯一语义差异**（有益且符合规范）：pmp_check 要求匹配项
    //     **覆盖该笔的全部字节**（norm:pmpfullmatch_required，08 §5.5 抉择 3）；
    //     内联版只比较起始地址。取指粒度（每 parcel 一次检查）不变。
    wire pmp_allow_lo, pmp_allow_hi;
    wire [`RV32GC_CAUSE_W-1:0] pmp_cause_lo, pmp_cause_hi;

    pmp_check #(
        .PMP_ENTRIES (PMP_ENTRIES)      // ★ pmp_check 无 PMP_ENTRY_W 参数（每项恒 8 bit）
    ) u_pmp_chk_lo (
        .clk             (aclk),
        .rst_n           (aresetn),
        .cfg_i           (pmpcfg_i),
        .addr_i          (pmpaddr_i),
        .acc_pa_i        (check_va_lo),
        .acc_bytes_i     (5'd2),
        .acc_priv_i      (priv),
        .acc_type_i      (2'd2),
        .allow_o         (pmp_allow_lo),
        .fault_cause_o   (pmp_cause_lo),
        .hit_o           (),
        .hit_idx_o       (),
        .denied_by_full_o()
    );

    pmp_check #(
        .PMP_ENTRIES (PMP_ENTRIES)      // ★ pmp_check 无 PMP_ENTRY_W 参数（每项恒 8 bit）
    ) u_pmp_chk_hi (
        .clk             (aclk),
        .rst_n           (aresetn),
        .cfg_i           (pmpcfg_i),
        .addr_i          (pmpaddr_i),
        .acc_pa_i        (check_va_hi),
        .acc_bytes_i     (5'd2),
        .acc_priv_i      (priv),
        .acc_type_i      (2'd2),
        .allow_o         (pmp_allow_hi),
        .fault_cause_o   (pmp_cause_hi),
        .hit_o           (),
        .hit_idx_o       (),
        .denied_by_full_o()
    );

    wire pmp_ok_lo = pmp_allow_lo;
    wire pmp_ok_hi = pmp_allow_hi;

    // 第一个故障 parcel 决定 tval（低地址优先，与「逐 parcel 顺序检查」一致）
    wire        pmp_fault      = ~pmp_ok_lo | (~pmp_ok_hi & ilen32);
    wire [31:0] pmp_fault_va   = ~pmp_ok_lo ? check_va_lo : check_va_hi;
    wire [15:0] pmp_fault_parcel = ~pmp_ok_lo ? check_parcel_lo : check_parcel_hi;

    // 保留：故障 parcel 位（供 TB/波形诊断核对 mtval 与 parcel 的对应关系）
    wire [15:0] fault_parcel_dbg = pmp_fault_parcel;

    //==========================================================================
    // 6. 取指异常汇总（§5.1 ③/④；§5.5 抉择 7/8）
    //    cause 1 = instruction access fault（PMP 无 X 权限，**本设计选择按 parcel**）
    //    cause 12 = instruction page fault（Sv32 翻译失败，M2 后）
    //    tval 恒为**虚拟地址**（norm:mtvalvaddrnot_paddr）；mp：故障指令起始地址。
    //==========================================================================
    assign fetch_exc_valid = pmp_fault | fetch_ext_fault;
    assign fetch_exc_cause = fetch_ext_fault ? `RV32GC_EXC_INSN_PAGE_FAULT
                                             : `RV32GC_EXC_INSN_ACCESS_FAULT;
    assign fetch_exc_tval  = fetch_ext_fault ? fetch_pc : pmp_fault_va;
    assign fetch_exc_pc    = insn_va;

    //==========================================================================
    // 7. 输出到 D 级（完整指令，绝不出现半条指令）
    //==========================================================================
    assign fetch_data        = insn_raw;
    assign fetch_data_pa     = insn_raw;                 // 2A：PA==VA（Bare）
    assign fetch_insn_va     = insn_va;
    assign fetch_insn_pa     = insn_va;
    assign fetch_ilen32      = ilen32;
    // ★ D2 修复（取指门控）：必须由 **fetch_rsp_valid（本拍真的有取指响应）** 门控。
    //   原式只用 insn_valid（= 本字可拼出完整指令），而复位后 fetch_word 恒 0
    //   （L1I 阵列未命中 / XIP 保持寄存器为空）⇒ 0x0000 的 [1:0]!=11 被判成
    //   "16 bit 压缩指令 0x0000"，fetch_valid 在**没有任何响应**的拍被拉高，
    //   D 级把 0 数据字当指令执行。新口径：有响应才有有效指令。
    assign fetch_valid       = fetch_rsp_valid & insn_valid_w &
                               ~pmp_fault & ~fetch_ext_fault & ~fetch_busy;
    assign fetch_uncached_pa = insn_raw;
    assign parcel_o          = parcel_insn;
    assign parcel_is_lo      = ~ilen32;
    assign parcel_is_lo_pa   = ~ilen32;

    //==========================================================================
    // 8. 时序元件（**本模块唯一的 always 块**）
    //    理由（AGENT.md §4 红线 3 / 08 §7.4 要求「确有必要并注释」）：
    //    这是不可用 assign 表达的状态：① 交出的指令长度（供 PCC 算 pc+2/+4）；
    //    ② 32 bit 指令跨字拼接所需的 carry（下一取指字）。二者都是寄存器。
    //    块内只做寄存器更新，无组合译码；所有译码都已在上面用 assign/function
    //    完成（红线 3「禁止给多个 reg 赋值的 always @(*)」不适用：此处无 @(*)）。
    //==========================================================================
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            carry_valid   <= 1'b0;
            carry_parcel  <= 16'h0000;
            carry_va      <= 32'h0000_0000;
        end else if (insn_valid_w & ~fetch_busy) begin
            // ---- D3：carry 寄存器**只服务"高半起始"**（fetch_pc[1]==1）----
            //   · 低半起始（4 B 对齐指令流）：本字已含 32 bit 指令的两半
            //     ⇒ carry_valid 清 0（原实现无条件置 1，使陈旧 carry 可能被下一条
            //       指令误用；且 carry 更新被 insn_valid 门控 ⇒ 与 insn_valid 的
            //       carry 依赖构成自锁，第一条 32 bit 指令永久卡死）。
            //   · 高半起始：缺失的一半 = **下一取指字（VA+4）的低半** ⇒ 锁存之，
            //     其 VA 记 VA+4，供下一拍拼接（M2 半字保持通路补齐后可达）。
            carry_valid  <= ~insn_start_lo & ilen32;
            carry_parcel <= fetch_word[15:0];
            carry_va     <= fetch_word_va + 32'd4;
        end
    end

    //==========================================================================
    // 9. PMP 检查（**已消重**：改为例化 rtl/mem/pmp_check.v，见 §5 的两处例化）
    //    本节原为内联 function `pmp_check_v`；2026-09-14 集成时按母 Agent 派活
    //    要求改为模块例化，使**取指与访存共用同一份** PMP 匹配实现，避免两处
    //    各自维护、口径漂移。语义差异见 §5 的 ★ 注。
    //==========================================================================


endmodule
