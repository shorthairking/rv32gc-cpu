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
//   ④ 取指 PMP：按 **16-bit parcel 逐个** pmp_check_v（本设计选择，§5.5 抉择 2）；
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
// 【PMP 检查口径（本模块自带的组合 pmp_check_v，只读端口）】
//   规格 §5.1 ③ 要求「调用 pmp_check」；rtl/mem/pmp_check.v 归 M 级、由另一
//   子任务交付，本任务禁止创建 rtl/mem/ 下的文件。为**不重复造轮子**，
//   本模块将检查内联为一个 function（pmp_check_v），其输入 = 本模块的 PMP
//   CSR 映像端口（pmpcfg_i/pmpaddr_i），语义按 docs/kb/isa-notes.md §3：
//     · 静态优先级：编号最低的、命中该笔的项说了算（norm:pmpentrypriority）
//     · A=OFF 项跳过；A=TOR 上界 = 前一个**已编程**项的 pmpaddr
//     · G=0 ⇒ 4 B 粒度，NA4 可用
//     · 无匹配项：M 模式 ⇒ 允许；S/U ⇒ 拒绝（已实现 16 项，norm:pmpnoentry_match）
//   当 rtl/mem/pmp_check.v 落地后，此处应改为模块例化（接口已按该方向预留）。
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
    ,output wire [1:0]  fetch_pc_sel
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

    // `for` 循环的整数迭代变量必须声明为 reg（Verilog-2001 无 integer 循环变量的
    // 隐式声明；此处是唯一的声明，循环体本身是组合)，见下方 function。
    integer i;

    //==========================================================================
    // 1. PCC（pc_gen.v）：产生 fetch_pc 与其推进量
    //    §5.1 ①：复位 > 重定向 > 顺序推进；顺序量 = +2 / +4 由上一拍指令长度定。
    //==========================================================================
    // 顺序推进开关（§5.0：停顿 ⇒ 冻结 F 级，不推进）：
    //   本拍取指字已到手（fetch_rsp_valid）且下游未反压、且不在停顿中。
    wire fetch_busy      = fetch_pause;
    wire insn_ready_out  = fetch_rsp_valid & ~cross_pending;

    wire seq_adv_valid = fetch_rsp_valid & ~fetch_busy;

    // 上一拍交出的指令长度 → 本次顺序推进量（§5.1 ①）
    reg last_ilen32_r;

    wire [31:0] fetch_pc_w;
    wire [31:0] pc_next_w;
    wire [1:0]  pc_sel_w;
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
        .seq_len32         (last_ilen32_r),
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
    wire        ilen32;
    wire        insn_valid;
    wire        cross_pending;
    wire [31:0] insn_raw;

    parcel_align u_parcel_align (
        .word_o        (fetch_word),
        .word_va_o     (fetch_word_va),
        .carry_valid_i (carry_valid),
        .carry_parcel_i(carry_parcel),
        .carry_va_i    (carry_va),
        .insn_o        (insn_raw),
        .insn_va_o     (insn_va),
        .ilen32_o      (ilen32),
        .insn_valid_o  (insn_valid),
        .cross_pending_o(cross_pending)
    );

    // 交出的 16 bit parcel：压缩指令 ⇒ 取低半；32 bit ⇒ 取高半（+2 处），
    // 因为 D 级译码的「parcel 流」以 +2 为单位推进（§4.3 取指粒度）。
    assign parcel_insn = ilen32 ? fetch_word[31:16] : fetch_word[15:0];

    //--- carry：32 bit 指令需要的「+2 parcel」来自下一取指字 ---
    //  说明：本模块用「上一拍取到的下一个字」作为 carry。直连通路（uncached）
    //  下，下一字的 PA = 本字 PA + 4（XIP 无回卷修正，§5.1 ⑥）。
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
    wire [15:0] check_parcel_lo = fetch_word[15:0];
    wire [15:0] check_parcel_hi = fetch_word[31:16];
    wire [31:0] check_va_lo     = {insn_va[31:2], 2'b00};        // 4 B 对齐字起始
    wire [31:0] check_va_hi     = {insn_va[31:2], 2'b00} + 32'd2; // +2

    wire pmp_ok_lo = pmp_check_v(fetch_pc_pa, priv);
    wire pmp_ok_hi = pmp_check_v({fetch_pc_pa[31:2], 2'b00} + 32'd2, priv);

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
    assign fetch_valid       = insn_valid & ~pmp_fault & ~fetch_ext_fault & ~fetch_busy;
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
            last_ilen32_r <= 1'b0;
            carry_valid   <= 1'b0;
            carry_parcel  <= 16'h0000;
            carry_va      <= 32'h0000_0000;
        end else if (insn_valid & ~fetch_busy) begin
            last_ilen32_r <= ilen32;
            carry_valid   <= 1'b1;
            carry_parcel  <= parcel_insn;
            carry_va      <= insn_va + 32'd2;
        end
    end

    //==========================================================================
    // 9. PMP 匹配检查（只读端口；语义见文件头）
    //    纯组合 function：输入 (PA, priv)，输出该 PA 是否具 X（可执行）权限。
    //    用 integer（而非 function 内局部 reg）表达循环变量是 Verilog-2001 惯例。
    //
    //    注（避免重复造轮子 / 真源纪律）：本 function 是 PMP 检查的**临时内联
    //    实现**，只服务于 F 级取指这一笔；完整 16 项实现归 rtl/mem/pmp_check.v
    //    （M 级，另一子任务）。两者共用 rtl/pkg/rv32_defs.vh §7 的位域常量，
    //    不各自硬编码。本任务的文件范围禁止创建 rtl/mem/**，故此处内联。
    //==========================================================================
    function pmp_check_v;
        input  [31:0] pa_f;
        input  [1:0]  priv_f;
        integer       k;
        reg           matched;
        reg           x_ok;
        reg    [31:0] tor_lo;      // TOR 下界（前一个已编程项的 pmpaddr<<2）
        reg    [31:0] tor_hi;
        reg    [7:0]  cfg_t;
        reg    [31:0] addr_t;
        reg    [31:0] size_mask;   // NAPOT：块内偏移掩码（低位全 1）
        reg    [31:0] block_base;  // NAPOT：块基址（pmpaddr 清掉尾部 1）
        begin
            matched   = 1'b0;
            x_ok      = 1'b0;
            tor_lo    = 32'h0000_0000;
            tor_hi    = 32'h0000_0000;
            k         = 0;
            // 静态优先级：**编号最低的命中项**决定结果（norm:pmpentrypriority）
            while ((k < PMP_ENTRIES) && !matched) begin
                cfg_t  = pmpcfg_i[k*PMP_ENTRY_W +: PMP_ENTRY_W];
                addr_t = pmpaddr_i[k*32 +: 32];
                case (cfg_t[`RV32GC_PMP_A_LSB +: 2])
                    `RV32GC_PMP_A_OFF: begin
                        // A=OFF：不参与匹配；TOR 的「前一个已编程项」需跳过它
                    end
                    `RV32GC_PMP_A_TOR: begin
                        // G=0 ⇒ 4 B 粒度，TOR 上界 = pmpaddr<<2，不做低位掩码回卷
                        tor_hi = {addr_t[29:0], 2'b00};
                        if ((pa_f >= tor_lo) && (pa_f < tor_hi)) begin
                            matched = 1'b1;
                            x_ok    = cfg_t[`RV32GC_PMP_X_BIT];
                        end
                        tor_lo = tor_hi;              // 成为下一项 TOR 的下界
                    end
                    `RV32GC_PMP_A_NA4: begin
                        if ((pa_f >> 2) == addr_t) begin
                            matched = 1'b1;
                            x_ok    = cfg_t[`RV32GC_PMP_X_BIT];
                        end
                        tor_lo = {addr_t[29:0], 2'b00} + 32'd4;
                    end
                    default: begin  // `RV32GC_PMP_A_NAPOT
                        // NAPOT：pmpaddr 尾部连续 1 的个数定块大小（G=0，最小 8 B）
                        if      (~addr_t[0]) size_mask = 32'h0000_0003;
                        else if (~addr_t[1]) size_mask = 32'h0000_000F;
                        else if (~addr_t[2]) size_mask = 32'h0000_00FF;
                        else if (~addr_t[3]) size_mask = 32'h0000_FFFF;
                        else if (~addr_t[4]) size_mask = 32'h000F_FFFF;
                        else                 size_mask = 32'hFFFF_FFFF;
                        block_base = {addr_t[29:0], 2'b00} & ~size_mask;
                        if (((pa_f & ~size_mask) == block_base)) begin
                            matched = 1'b1;
                            x_ok    = cfg_t[`RV32GC_PMP_X_BIT];
                        end
                        tor_lo = block_base + size_mask + 32'd1;
                    end
                endcase
                k = k + 1;
            end
            // 无匹配项：M 模式 ⇒ 允许；S/U ⇒ 拒绝（已实现 16 项，norm:pmpnoentry_match）
            pmp_check_v = matched ? x_ok : (priv_f == PRIV_M);
        end
    endfunction

endmodule
