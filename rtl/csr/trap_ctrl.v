//==============================================================================
// trap_ctrl.v —— 陷阱/中断入口统一（cause/tval/epc 生成、委托判定、Vectored 取 pc）
//==============================================================================
// 依据    : docs/design/08-baseline-5stage.md §5.6（W 级统一入口，行为要点 ①②⑤）、
//           §6.3（T1–T8 陷阱口径）、§5.5 抉择 9（不从高特权级委托到低）、
//           §6.5（mtvec/stvec Vectored 用户裁决）、§8.5（反证实验）
//           docs/design/06-csr-privilege.md §3.2/§3.4/§3.6、§9
//           docs/kb/isa-notes.md §4 T1/T2/T5/T6
// 真源    : rtl/pkg/rv32_defs.vh（cause 码、mtvec MODE/对齐、medeleg/mideleg 掩码）
// 红线    : 无原语；组合逻辑用 assign/function；本模块**无 always 块**（纯组合 +
//           登记寄存器在上层），因此**不引入任何时序元件**。
//------------------------------------------------------------------------------
// 【本模块锁定的硬口径】
//  E1. **同步异常 pc = BASE**；**中断 pc = BASE + 4×cause**（Vectored）。
//      norm：machine.adoc › mtvec（MODE=1 时"interrupts cause pc ← BASE+4×cause"）。
//      用户裁决 2026-09-14（06 §11 P-3 / 08 §6.5）：**实现 Vectored**。
//      反证：把 pc 改成恒 BASE ⇒ tb_trap_ctrl 的中断 Vectored 用例必须 FAIL。
//  E2. **Vectored 要求 BASE 256 B 对齐**（低 8 位 0），故用 `BASE | (cause<<2)`
//      合成，**无加法器**（手册 NOTE 给出的动机）。Direct 只要求 4 B 对齐。
//      ⇒ 本模块做 BASE 对齐规范化：Vectored 下强制低 8 位为 0（WARL 语义）。
//  E3. **委托只在源特权级为 S/U 时生效**；**M 模式陷阱永不委托**（T5）。
//      norm:trap_never_trans_lower（machine.adoc:1281-1288）。
//      反证：去掉源特权级门控 ⇒ tb_trap_ctrl「不从高特权级委托到低」用例必须 FAIL。
//  E4. **中断取点 = 已提交指令边界之后**（T6 本设计纪律；规范未明说）。
//      ⇒ 本模块的中断有效条件里显式含 `commit_valid`（W 级提交完成），
//      且 mepc 指向**下一未执行指令**（pc_next）。
//  E5. **取 PTE / 取指的 tval 写虚拟地址**；mtval 写指令位（T1，本设计选择实现）。
//      06 §6.4 末：mtval 恒写 VA，即使是物理内存 access fault。
//  E6. 委托到 S 时**不写** mcause/mepc/mtval 与 mstatus.MPP/MPIE（norm:trapdelSmodenoMmode）。
//==============================================================================
`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"

module trap_ctrl (
    //--------------------------------------------------------------------------
    // 提交级（W）事件
    //--------------------------------------------------------------------------
    input  wire        commit_valid,     // 本拍有指令提交完成（副作用全局可见）
    input  wire [31:0] commit_pc,        // 提交指令 PC
    input  wire [31:0] commit_pc_next,   // 提交指令之后的 PC（下一未执行指令）
    input  wire [31:0] commit_insn,      // 提交指令的原始位（供 mtval，T1）

    //--------------------------------------------------------------------------
    // 异常请求（来自各级；本拍合并为一条）
    //--------------------------------------------------------------------------
    input  wire        exc_valid,        // 有同步异常待处理
    input  wire [4:0]  exc_cause,        // 异常码（不含 Interrupt 位）
    input  wire [31:0] exc_tval,         // 异常 tval（恒 VA；取指 PMP 写故障 parcel 的 VA）
    input  wire        exc_is_fetch,     // 取指异常（mepc 指向故障指令起始地址）

    //--------------------------------------------------------------------------
    // 特权级与委托配置（来自 priv_ctrl / csr_file）
    //--------------------------------------------------------------------------
    input  wire [1:0]  priv,             // 当前（源）特权级
    input  wire [31:0] medeleg,
    input  wire [31:0] mideleg,

    //--------------------------------------------------------------------------
    // 中断（来自 csr_file 的 mip 与 mie 有效值）
    //--------------------------------------------------------------------------
    input  wire [31:0] mip,
    input  wire [31:0] mie,
    input  wire [31:0] mstatus_i,        // 取 MIE/SIE 全局使能

    //--------------------------------------------------------------------------
    // 向量基址
    //--------------------------------------------------------------------------
    input  wire [31:0] mtvec,
    input  wire [31:0] stvec,

    //--------------------------------------------------------------------------
    // 输出：陷阱判定与入口信息
    //--------------------------------------------------------------------------
    output wire        trap_valid,       // 本拍取陷阱（同步异常或中断）
    output wire        trap_is_int,      // 1 = 中断，0 = 同步异常
    output wire [1:0]  trap_target,      // 目标特权级（M 或 S）
    output wire [31:0] trap_cause,       // mcause/scause 的原始值（含 bit31）
    output wire [31:0] trap_tval,        // mtval/stval 取值
    output wire [31:0] trap_epc,         // mepc/sepc 取值
    output wire [31:0] trap_pc,          // 陷阱入口 PC（Vectored 合成后）
    output wire [3:0]  trap_we,          // csr_file 写口分组使能（见 §6）
    output wire [31:0] trap_epc_i,       // 组的 epc 值
    output wire [31:0] trap_cause_i,     // 组的 cause 值
    output wire [31:0] trap_tval_i,      // 组的 tval 值
    output wire [31:0] trap_data_i,      // sscratch/mscratch 单写值（陷阱不用，恒 0）
    output wire        trap_wr_m_epc,    // 写 m 侧 epc
    output wire        trap_wr_m_cause,  // 写 m 侧 cause
    output wire        trap_wr_m_tval,   // 写 m 侧 tval
    output wire        trap_wr_s_epc,    // 写 s 侧 epc
    output wire        trap_wr_s_cause,  // 写 s 侧 cause
    output wire        trap_wr_s_tval,   // 写 s 侧 tval
    output wire [31:0] redirect_pc       // = trap_pc（供 pc_gen 重定向）
);

    //==========================================================================
    // 1. 常量与工具函数
    //==========================================================================
    localparam [1:0] PRIV_U = `RV32GC_PRIV_U;
    localparam [1:0] PRIV_S = `RV32GC_PRIV_S;
    localparam [1:0] PRIV_M = `RV32GC_PRIV_M;

    // ---- mcause 的 Interrupt 位（bit31）----
    //   真源宏 `RV32GC_MCAUSE_INT_MSK = (32'h1 << RV32GC_MCAUSE_INT_BIT)` 是**表达式**，
    //   iverilog 无法把它绑定到 localparam 的初始化（"Unable to bind parameter"），
    //   故这里用位移形式在**表达式位置**取用，不用 localparam 承载。
    //   值仍完全来自真源：位号取 `RV32GC_MCAUSE_INT_BIT`。
    wire [31:0] INT_BIT = (32'h1 << `RV32GC_MCAUSE_INT_BIT);

    // ---- 中断 cause 列表（本设计实现 1/3/5/7/9/11）与优先级 ----
    //   优先级（规范：M 级中断优先于任何低特权级中断）：11 > 3 > 7 > 9 > 1 > 5
    //   理由：MEI/MSI/MTI 是 M 专属；SEI/SSI/STI 是 S 级。M 级高优先。
    //   [ISA:norm:intr_M_mode_highest_pri]
    //   注：rv32_defs.vh §6.2 用 5'dNN 定义，直接赋给 [4:0] localparam 安全；
    //   为避免 iverilog 的位宽告警，统一走 5 位显式赋值（值仍取真源宏，不硬编码）。
    localparam [4:0] IRQ_MEI = `RV32GC_IRQ_M_EXTERNAL;   // 11
    localparam [4:0] IRQ_MSI = `RV32GC_IRQ_M_SOFTWARE;   // 3
    localparam [4:0] IRQ_MTI = `RV32GC_IRQ_M_TIMER;      // 7
    localparam [4:0] IRQ_SEI = `RV32GC_IRQ_S_EXTERNAL;   // 9
    localparam [4:0] IRQ_SSI = `RV32GC_IRQ_S_SOFTWARE;   // 1
    localparam [4:0] IRQ_STI = `RV32GC_IRQ_S_TIMER;      // 5
    //   编译期值守（编译失败即真源与实现失配，不静默）：
    //   本设计实现的中断集合必须是 {1,3,5,7,9,11}。
    initial begin
        if ((IRQ_MEI !== 5'd11) || (IRQ_MSI !== 5'd3) || (IRQ_MTI !== 5'd7) ||
            (IRQ_SEI !== 5'd9)  || (IRQ_SSI !== 5'd1) || (IRQ_STI !== 5'd5)) begin
            $display("TRAP_CTRL FAIL: 中断 cause 常量与 rv32_defs.vh 失配");
            $fatal(1, "TRAP_CTRL FAIL");
        end
    end

    //==========================================================================
    // 2. 委托判定（★ E3：只在源特权级为 S/U 时生效）
    //==========================================================================
    //   规范两条并列：
    //   (a) norm:medeleg_mideleg_op2：置位 ⇒ S/U 模式下发生的对应陷阱交 S 处理；
    //   (b) norm:trap_never_trans_lower：陷阱永不从高特权级转到低特权级。
    //   ⇒ 判据统一为：`src_is_lower (priv != M) && deleg_bit_set`。
    //   对中断另有 norm:trap_del_intr_priv_lvl：被委托的中断在委托者特权级被屏蔽
    //   （mideleg[5]=1 ⇒ STI 不在 M 模式取）。同一门控即覆盖。
    wire src_is_m      = (priv == PRIV_M);
    wire src_is_s      = (priv == PRIV_S);
    wire src_is_u      = (priv == PRIV_U);
    wire src_lower_m   = ~src_is_m;                  // S 或 U

    // ---- 同步异常委托位 ----
    //   exc_cause 恒 < 16（真源只定义 0..15），故无需 32 比较；索引安全。
    wire exc_deleg_bit = medeleg[exc_cause];
    wire exc_delegated = exc_valid & src_lower_m & exc_deleg_bit;

    // ---- 中断：逐位构造"可在本模式取"的中断集合 ----
    //   M 专属中断（3/7/11）：mideleg 中硬连 0（08 §6.2）⇒ 恒进 M。
    //   S 级中断（1/5/9）：mideleg 置位且在 S/U 模式 ⇒ 进 S；否则进 M。
    //   ★ 可移植性要点（本会话实测）：function 若**直接读模块级寄存器**
    //   （如 mstatus_i），Icarus Verilog 12.0 不会在该寄存器变化时重新求值
    //   调用它的连续赋值（Vivado/Verilator 会）。⇒ 所有被读的寄存器都必须
    //   作为**显式 input** 传入函数。
    function irq_visible;
        input [31:0] mip_v;
        input [31:0] mie_v;
        input [31:0] mideleg_v;
        input [31:0] mstatus_v;   // ★ 显式传入，勿改为读模块级 mstatus_i
        input [1:0]  cur_priv;
        input        is_s_irq;
        input [4:0]  code;
        begin
            // 挂起 & 使能
            //   ★★ G1 修复（2B-4 第 4b-3 段，母代理裁决："放开 2A 一行"+理由）：
            //     **M 级中断在下特权级恒开放** —— ISA（machine.adoc, mstatus.MIE/SIE 与中断取用
            //     条件）："an interrupt i will trap to M-mode if ... the privilege mode is less
            //     than M, **or** mstatus.MIE=1" ⇒ `priv < M` 时 M 级中断**不受 MIE/SIE 掩蔽**。
            //     旧式对"非 M 特权级"一律取 SIE ⇒ S 模式下已使能的 MEI 被误屏蔽（实测 p15：
            //     `mip.MEIP=1 & mie.MEIE=1 & mstatus.MIE=1` 仍不投递；置 `sstatus.SIE=1` 才投递）。
            //     M 级（is_s_irq=0）：(priv==M) ? MIE : 1'b1
            //     S 级（is_s_irq=1）：(priv==M) ? 0   : SIE   （M 模式下该中断不可见，见委托门控）
            //     —— 最小加法：只改"全局使能"一项的取值口径，其余（挂起/使能/委托门控）不变。
            irq_visible = mip_v[code] & mie_v[code] &
                          ( is_s_irq ? ((cur_priv == PRIV_M) ? 1'b0
                                                             : mstatus_v[`RV32GC_MSTATUS_SIE_BIT])
                                     : ((cur_priv == PRIV_M) ? mstatus_v[`RV32GC_MSTATUS_MIE_BIT]
                                                             : 1'b1) ) &
                          // 委托门控：被委托给 S 的中断**不在 M 模式取**
                          // （norm:trap_del_intr_priv_lvl）；未被委托的中断恒进 M
                          ( is_s_irq ? ((cur_priv != PRIV_M) ? mideleg_v[code] : 1'b0)
                                     : 1'b1 );
        end
    endfunction

    // ---- 各中断的可见性（M 专属中断 is_s_irq=0 ⇒ 恒进 M） ----
    wire irq_mei_v = irq_visible(mip, mie, mideleg, mstatus_i, priv, 1'b0, IRQ_MEI);
    wire irq_msi_v = irq_visible(mip, mie, mideleg, mstatus_i, priv, 1'b0, IRQ_MSI);
    wire irq_mti_v = irq_visible(mip, mie, mideleg, mstatus_i, priv, 1'b0, IRQ_MTI);
    wire irq_sei_v = irq_visible(mip, mie, mideleg, mstatus_i, priv, 1'b1, IRQ_SEI);
    wire irq_ssi_v = irq_visible(mip, mie, mideleg, mstatus_i, priv, 1'b1, IRQ_SSI);
    wire irq_sti_v = irq_visible(mip, mie, mideleg, mstatus_i, priv, 1'b1, IRQ_STI);

    // ---- ★ E4：中断只在"已提交指令边界之后"取 ----
    //   本设计纪律（T6；规范未明说）。实现为中断候选与 commit_valid 相与。
    wire any_irq_v = (irq_mei_v | irq_msi_v | irq_mti_v | irq_sei_v | irq_ssi_v | irq_sti_v)
                     & commit_valid & ~exc_valid;   // 同步异常优先于中断（同拍）

    // ---- 中断优先级编码（first-match，M 级优先） ----
    wire [4:0] irq_sel = irq_mei_v ? IRQ_MEI :
                         irq_msi_v ? IRQ_MSI :
                         irq_mti_v ? IRQ_MTI :
                         irq_sei_v ? IRQ_SEI :
                         irq_ssi_v ? IRQ_SSI :
                         irq_sti_v ? IRQ_STI : 5'd0;
    // 被委托的中断 ⇒ 进 S；否则进 M
    wire irq_sel_is_s  = (irq_sel == IRQ_SEI) | (irq_sel == IRQ_SSI) | (irq_sel == IRQ_STI);
    wire irq_goes_s    = any_irq_v & irq_sel_is_s & src_lower_m & mideleg[irq_sel];
    wire irq_goes_m    = any_irq_v & ~irq_goes_s;

    //==========================================================================
    // 3. 合并：同步异常优先于中断
    //==========================================================================
    wire exc_goes_s = exc_delegated;
    wire exc_goes_m = exc_valid & ~exc_delegated;

    assign trap_valid  = exc_valid | any_irq_v;
    assign trap_is_int = ~exc_valid & any_irq_v;
    // 目标特权级：S 或 M（U 模式 CSR 不落地 ⇒ 永不进 U，08 §6.2 裁决）
    assign trap_target = (exc_valid ? (exc_goes_s ? PRIV_S : PRIV_M)
                                    : (irq_goes_s ? PRIV_S : PRIV_M));

    //==========================================================================
    // 4. cause / tval / epc 生成
    //==========================================================================
    // ---- 4.1 cause：中断置 bit31（norm:mcause_interrupt_enc） ----
    assign trap_cause = trap_is_int ? (INT_BIT | {27'b0, irq_sel})
                                    : {27'b0, exc_cause};

    // ---- 4.2 tval ----
    //   T1：异常写"故障指令位"（右对齐、高位清零）= **本设计选择实现**。
    //       未实现的取值合法读 0；本设计选择实现，故对 illegal instruction
    //       写 commit_insn（高位自然清零，因为 commit_insn 就是 32 bit）。
    //   E5：其余异常写 **虚拟地址**（norm:mtvalvaddrnot_paddr）。
    //       取指 PMP 失败写**故障 parcel 的 VA**，但 mepc 指向**故障指令起始地址**
    //       （08 §5.5 抉择 7/8；06 §6.4 两条末注）。
    //   中断：tval 写 0（规范未定义信息性值）。
    wire exc_is_ill = (exc_cause == `RV32GC_EXC_ILLEGAL_INSN);
    assign trap_tval = trap_is_int ? 32'h0 :
                       exc_is_ill  ? commit_insn :   // T1：故障指令位
                       exc_tval;                     // E5：恒 VA

    // ---- 4.3 epc ----
    //   同步异常：mepc/sepc ← 故障指令的 PC（norm:mepc）、
    //             取指 PMP 违例时指向**故障指令起始地址**（08 §5.5 抉择 8）。
    //   中断    ：mepc/sepc ← **下一未执行指令**的地址（E4/T6；WFI 侧同口径
    //             machine.adoc:2697-2698 的 mepc = pc + 4）。
    //   epc[0] 恒 0（IALIGN=16，EPC_LSB=1）。
    wire [31:0] epc_raw = trap_is_int ? commit_pc_next : commit_pc;
    assign trap_epc = {epc_raw[31:1], 1'b0};

    //==========================================================================
    // 5. 陷阱入口 PC：★ E1/E2 Vectored 合成
    //==========================================================================
    //   MODE=0（Direct）  ：pc ← BASE
    //   MODE=1（Vectored）：同步异常 pc ← BASE；中断 pc ← BASE + 4 × cause
    //                       （例：M 定时器 cause=7 ⇒ BASE+0x1C）
    //   E2：Vectored 要求 BASE **256 B 对齐**（低 8 位 0）⇒ 用 `BASE | (cause<<2)`
    //       直接合成，无需加法器（手册 NOTE 明确给出的动机）。
    //       本模块对 BASE 做对齐规范化：Vectored ⇒ 低 8 位清 0（WARL 语义，
    //       csr_file 侧 mtvec/stvec 写已限制 MODE∈{0,1}）。
    wire        is_vectored = (trap_target == PRIV_M) ? (mtvec[1:0] == `RV32GC_TVEC_MODE_VECTORED)
                                                      : (stvec[1:0] == `RV32GC_TVEC_MODE_VECTORED);
    wire [31:0] vec_base_raw = (trap_target == PRIV_M) ? mtvec : stvec;
    // ---- 对齐规范化：Direct 保留低 2 位之外的全部；Vectored 清低 8 位 ----
    wire [31:0] vec_base = is_vectored ? {vec_base_raw[31:8], 8'h00}
                                       : {vec_base_raw[31:2], 2'b00};
    // ---- 中断向量偏移：4 × cause = cause << 2（cause 5 bit ⇒ 偏移 ∈ 0..124） ----
    wire [31:0] vec_offset = trap_is_int
                             ? (is_vectored ? ({27'b0, irq_sel} << 2) : 32'h0)
                             : 32'h0;
    assign trap_pc     = vec_base | vec_offset;   // Vectored BASE 256 B 对齐 ⇒ | 与 + 等价
    assign redirect_pc = trap_pc;

    //==========================================================================
    // 6. 写入目标 CSR 的选择（E6：委托到 S ⇒ 不写 M 侧；M 侧 ⇒ 不写 S 侧）
    //==========================================================================
    //   这是**唯一的**陷阱 CSR 写点（08 §5.6 行为要点 ①：不得在多处各自写 CSR）。
    //   六个使能两两互斥，故一次陷阱最多写 3 个 CSR（epc/cause/tval 各一）。
    wire wr_m = trap_valid & (trap_target == PRIV_M);
    wire wr_s = trap_valid & (trap_target == PRIV_S);

    wire wr_m_epc   = wr_m;
    wire wr_m_cause = wr_m;
    wire wr_m_tval  = wr_m;
    wire wr_s_epc   = wr_s;
    wire wr_s_cause = wr_s;
    wire wr_s_tval  = wr_s;

    // ---- csr_file 陷阱写端口：地址 + 数据 + 分组使能 ----
    //   为让一次陷阱同时落地 epc/cause/tval，csr_file 侧按 trap_addr 选中"三个
    //   连续地址的组"，数据分别取 trap_epc/trap_cause/trap_tval（见 csr_file §7
    //   的 trap_we/trap_addr/trap_wdata 端口语义）。
    //   本模块给出：地址 = epc 地址（组基址），数据 = epc 值，另有 cause/tval 两个
    //   伴随端口；使能 = 对应侧。
    assign trap_wr_m_epc   = wr_m_epc;
    assign trap_wr_m_cause = wr_m_cause;
    assign trap_wr_m_tval  = wr_m_tval;
    assign trap_wr_s_epc   = wr_s_epc;
    assign trap_wr_s_cause = wr_s_cause;
    assign trap_wr_s_tval  = wr_s_tval;

    // ---- csr_file 陷阱写端口（**分组语义**，见 csr_file §4.2）----
    //   trap_we[0] = M 组（mepc+mcause+mtval 同拍原子写）
    //   trap_we[1] = S 组（sepc+scause+stval 同拍原子写）
    //   trap_we[2]/[3] = sscratch/mscratch 单写（陷阱不用）
    //   ★ 这样一次陷阱只占**一个写点**，满足 08 §5.6 行为要点①
    //     "只在此处写 *epc/*cause/*tval"，不需要 3 拍逐 CSR 写。
    assign trap_we    = { 1'b0,     // [3] mscratch 单写（不用）
                          1'b0,     // [2] sscratch 单写（不用）
                          wr_s,     // [1] S 组
                          wr_m };   // [0] M 组
    assign trap_epc_i   = trap_epc;
    assign trap_cause_i = trap_cause;
    assign trap_tval_i  = trap_tval;
    assign trap_data_i  = 32'h0;

endmodule
