//==============================================================================
// priv_ctrl.v —— 特权级状态机 M/S/U、xRET、MPRV/SUM/MXR 有效值与同拍旁路
//==============================================================================
// 依据    : docs/design/08-baseline-5stage.md §6.1（特权级模型）、§5.6 行为要点 ③④、
//           §5.5 抉择 9（陷阱委托）；§6.4（MPRV/SUM/MXR 同拍旁路）、§8.5（反证实验）
//           docs/design/06-csr-privilege.md §1、§3.1、§4
//           docs/kb/isa-notes.md §4 T5/T6/T7
// 真源    : rtl/pkg/rv32_defs.vh（PRIV 编码、mstatus 位域）
// 红线    : 无原语；组合逻辑用 assign/function；always 仅用于特权级状态寄存器。
//------------------------------------------------------------------------------
// 【本模块锁定的三条硬口径】（每条都能被反证实验打掉，见 08 §8.5）
//  P1. **xRET 到 < M 才清 MPRV**：`mret` 回 M **不清** MPRV。
//      norm:mstatus_mprv_clr_mret_sret_less_priv（machine.adoc:599-600）。
//      反证：把清除改成"无条件清" ⇒ tb_trap_ctrl 的「回 M 不清」用例必须 FAIL。
//  P2. **陷阱不从高特权级委托到低特权级**：M 模式陷阱永远进 M。
//      norm:trap_never_trans_lower（machine.adoc:1281-1288）。
//  P3. **MPRV=1 按 MPP 语义**（MPP=M 即等效 M 权限），而非"MPRV 只在 MPP≠M 时生效"。
//      norm:mstatus_mprv_ldst_op（machine.adoc:588-597）。
//      取指的翻译与保护**不受** MPRV 影响（norm:mstatusmprvinstxlatop）。
//  P4. **SUM 只在 (私有效特权级 == S) 时生效**，含 MPRV=1 && MPP=S 的情形。
//      norm:mstatussumopmprvmpp（machine.adoc:627-628）。
//      MXR 只影响有效特权级 < M 的 load。
//      SUM/MXR **不得**进入 PMP 路径（norm:mstatussumopmvm 后的段落）。
//  P5. **同拍旁路**：CSR 写指令在 W 级提交时，其新值必须**同拍**供特权级/
//      SUM/MXR/PMP 判定使用（06 §4 实现口径 1）。
//==============================================================================
`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"

module priv_ctrl (
    input  wire        clk,
    input  wire        rst_n,

    //--------------------------------------------------------------------------
    // 提交级（W）的陷阱/返回事件
    //--------------------------------------------------------------------------
    input  wire        trap_valid,      // 本拍有陷阱/中断被取（来自 trap_ctrl）
    input  wire [1:0]  trap_target,     // 陷阱目标特权级（trap_ctrl 判定后）
    input  wire        xret_valid,      // 本拍有 mret/sret/uret 被提交
    input  wire [1:0]  xret_kind,       // 00=sret 01=mret 10=uret（保留）

    //--------------------------------------------------------------------------
    // mstatus 接口（csr_file）—— 同拍旁路用
    //--------------------------------------------------------------------------
    input  wire [31:0] mstatus_i,       // 架构 mstatus（组合读）
    input  wire        csr_wen,         // W 级提交的 CSR 写（已完成冲刷判定）
    input  wire [11:0] csr_waddr,
    input  wire [31:0] csr_wdata,
    output wire [31:0] mstatus_set,     // 陷阱入口对 mstatus 的置位
    output wire [31:0] mstatus_clr,     // 陷阱入口 / xRET 对 mstatus 的清除

    //--------------------------------------------------------------------------
    // 特权级与有效值输出
    //--------------------------------------------------------------------------
    output wire [1:0]  priv_o,          // 当前架构特权级
    output wire [1:0]  eff_priv_o,      // 访存"有效"特权级（含 MPRV 语义）
    output wire        mprv_o,
    output wire        sum_o,
    output wire        mxr_o,
    output wire [1:0]  mpp_o,
    output wire        tvm_o,
    output wire        tw_o,
    output wire        tsr_o,
    output wire        fetch_priv_is_m_o,  // 取指用：当前特权级是否 M（MPRV 不影响取指）

    //--------------------------------------------------------------------------
    // 特权级切换的流水线冲刷请求
    //--------------------------------------------------------------------------
    //--------------------------------------------------------------------------
    // xRET 返回目标特权级（纯组合；仅由 kind + 合法化 xPP 决定）
    //--------------------------------------------------------------------------
    //   ★ 0628/母确认：Top 的 IRQ 资格需"返回后有效 context"（MRET→MIE/SRET→SIE、
    //     MPP/SPP 取返回后值），不能依赖 trap_valid/priv_next（避免组合环）。
    //     本输出与 trap_valid 无关；只在 xret_valid=1 时有意义。
    output wire [1:0]  xret_target_priv_o,

    output wire        flush_req,       // xRET / 陷阱改变特权级 ⇒ 请求冲刷
    output wire [1:0]  priv_next_o      // 下一特权级（供调试/断言）
);

    // ---- 特权级常量 + MPP WARL 合法映射（§1 旁路与 §2 状态机共用同一口径）----
    localparam [1:0] PRIV_U = `RV32GC_PRIV_U;
    localparam [1:0] PRIV_S = `RV32GC_PRIV_S;
    localparam [1:0] PRIV_M = `RV32GC_PRIV_M;

    //   norm:mstatusxppwarl：xPP 可持有 x 与任何已实现且低于 x 的模式。
    //   本设计实现 U/S/M ⇒ MPP ∈ {U, S, M}，编码 2'b10(H) 为保留 ⇒ 归为 S
    //   （保证读回**合法值**，绝不解出 H）。06 §9「WARL 写入非法值须保留合法值」。
    //   ★ F1-B：csr_file 已在**落地**处做同一 mpp_warl；本模块的旁路也必须对
    //     csr_wdata 的 MPP 先合法化再替换，三者（落盘读回/rdata_w/byp_rdata）同口径。
    function [1:0] mpp_legal;
        input [1:0] v;
        begin
            case (v)
                PRIV_U:  mpp_legal = PRIV_U;
                PRIV_S:  mpp_legal = PRIV_S;
                PRIV_M:  mpp_legal = PRIV_M;
                default: mpp_legal = PRIV_S;   // 2'b10(保留/H) ⇒ 合法化为 S
            endcase
        end
    endfunction

    //==========================================================================
    // 1. mstatus 字段抽取（组合；含同拍旁路）
    //==========================================================================
    // ---- 同拍旁路：若本拍提交一条对 mstatus/sstatus 的 CSR 写，则用其**落盘后**值 ----
    //   ★ P1-06 修复（2026-10-19 F1 特权包）：旧式
    //       `(old & ~new) | (new & csr_wdata)` = `old | csr_wdata`（OR 语义）
    //     只能置位、不能同拍清位（1→0 失效）。正确形式是**按可写字段掩码替换**：
    //       eff = (old & ~mask) | (wdata & mask)
    //   掩码必须与 csr_file 的 WARL 掩码一致（csr_file.v §2 `wr_mask()`）：
    //     · mstatus：SIE/MIE/SPIE/MPIE/SPP/FS/MPP/MPRV/SUM/MXR/TVM/TW/TSR
    //       （UIE/UBE/XS/SD 只读，不在掩码内；SD 由 FS 派生，保留 old 值即可）
    //     · sstatus：SIE/SPIE/SPP/FS/SUM/MXR（**不含** MIE/MPIE/MPP/MPRV/TVM/TW/TSR）
    //   这两份掩码与 csr_file 逐位对齐（位号全部取自 rv32_defs.vh 唯一真源）；
    //   若将来 csr_file 增删可写字段，本处必须同步（本模块无第二份 WARL 引擎，
    //   只做"字段级替换"，MPP 的合法性仍由下方 `mpp_legal()` 在使用点保证）。
    //   ★ 端口/位宽不变：不改接口、不新增输入；写数据仍走既有 csr_wdata。
    localparam [31:0] MSTATUS_WR_MSK =
        (32'h1 << `RV32GC_MSTATUS_SIE_BIT)  |
        (32'h1 << `RV32GC_MSTATUS_MIE_BIT)  |
        (32'h1 << `RV32GC_MSTATUS_SPIE_BIT) |
        (32'h1 << `RV32GC_MSTATUS_MPIE_BIT) |
        (32'h1 << `RV32GC_MSTATUS_SPP_BIT)  |
        (`RV32GC_MSTATUS_FS_MSK  << `RV32GC_MSTATUS_FS_LSB)  |
        (`RV32GC_MSTATUS_MPP_MSK << `RV32GC_MSTATUS_MPP_LSB) |
        (32'h1 << `RV32GC_MSTATUS_MPRV_BIT) |
        (32'h1 << `RV32GC_MSTATUS_SUM_BIT)  |
        (32'h1 << `RV32GC_MSTATUS_MXR_BIT)  |
        (32'h1 << `RV32GC_MSTATUS_TVM_BIT)  |
        (32'h1 << `RV32GC_MSTATUS_TW_BIT)   |
        (32'h1 << `RV32GC_MSTATUS_TSR_BIT);
    localparam [31:0] SSTATUS_WR_MSK =
        (32'h1 << `RV32GC_MSTATUS_SIE_BIT)  |
        (32'h1 << `RV32GC_MSTATUS_SPIE_BIT) |
        (32'h1 << `RV32GC_MSTATUS_SPP_BIT)  |
        (`RV32GC_MSTATUS_FS_MSK << `RV32GC_MSTATUS_FS_LSB) |
        (32'h1 << `RV32GC_MSTATUS_SUM_BIT)  |
        (32'h1 << `RV32GC_MSTATUS_MXR_BIT);

    wire        mstat_hit = csr_wen &&
                            ((csr_waddr == `RV32GC_CSR_MSTATUS) ||
                             (csr_waddr == `RV32GC_CSR_SSTATUS));
    wire [31:0] mstat_byp_msk = ~mstat_hit ? 32'h0 :
                                (csr_waddr == `RV32GC_CSR_MSTATUS) ? MSTATUS_WR_MSK :
                                                                     SSTATUS_WR_MSK;
    //   ★ 替换语义（先清掩码内旧值，再置入写数据）；mstat_hit=0 时掩码为 0 ⇒ = 架构值。
    //   ★ F1-B：写 mstatus 时先把 MPP 字段合法化（与 csr_file 落地同一映射），
    //     使旁路值 == 落盘读回值；sstatus 无 MPP 字段，原样使用。
    wire [31:0] mstat_wdata_eff =
        (csr_waddr == `RV32GC_CSR_MSTATUS)
        ? ((csr_wdata & ~(32'h3 << `RV32GC_MSTATUS_MPP_LSB)) |
           ({30'b0, mpp_legal(csr_wdata[`RV32GC_MSTATUS_MPP_LSB +: 2])}
             << `RV32GC_MSTATUS_MPP_LSB))
        : csr_wdata;
    wire [31:0] mstat_eff = (mstatus_i & ~mstat_byp_msk) | (mstat_wdata_eff & mstat_byp_msk);

    // ---- 字段抽取（显式位选，便于 lint） ----
    wire       f_mie   = mstat_eff[`RV32GC_MSTATUS_MIE_BIT];
    wire       f_sie   = mstat_eff[`RV32GC_MSTATUS_SIE_BIT];
    wire       f_mpie  = mstat_eff[`RV32GC_MSTATUS_MPIE_BIT];
    wire       f_spie  = mstat_eff[`RV32GC_MSTATUS_SPIE_BIT];
    wire       f_spp   = mstat_eff[`RV32GC_MSTATUS_SPP_BIT];
    wire [1:0] f_mpp   = (mstat_eff >> `RV32GC_MSTATUS_MPP_LSB) & `RV32GC_MSTATUS_MPP_MSK;
    wire       f_mprv  = mstat_eff[`RV32GC_MSTATUS_MPRV_BIT];
    wire       f_sum   = mstat_eff[`RV32GC_MSTATUS_SUM_BIT];
    wire       f_mxr   = mstat_eff[`RV32GC_MSTATUS_MXR_BIT];
    wire       f_tvm   = mstat_eff[`RV32GC_MSTATUS_TVM_BIT];
    wire       f_tw    = mstat_eff[`RV32GC_MSTATUS_TW_BIT];
    wire       f_tsr   = mstat_eff[`RV32GC_MSTATUS_TSR_BIT];

    //==========================================================================
    // 2. 特权级状态机（唯一的架构状态；复位 = M）
    //==========================================================================
    //   理由：特权级是架构寄存器，必须时钟沿保持 ⇒ always 块不可省（AGENT.md §4.3）。
    reg [1:0] priv_r;

    wire [1:0] mpp_l = mpp_legal(f_mpp);

    // ---- 下一特权级：优先级 = 陷阱 > xRET > 不变 ----
    //   xRET 目标：mret ⇒ MPP（合法化后）；sret ⇒ SPP ? S : U；
    //   uret 在 U 模式 CSR 不落地时**不实现**（urt 由译码器报非法，见 08 §6.2 裁决）。
    wire [1:0] xret_target = (xret_kind == 2'b01) ? mpp_l :
                             (xret_kind == 2'b00) ? (f_spp ? PRIV_S : PRIV_U) :
                             PRIV_U;   // uret（保留；本设计不实现，译码阶段非法）
    wire [1:0] priv_next   = trap_valid ? trap_target :
                             xret_valid ? xret_target : priv_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) priv_r <= PRIV_M;          // 复位进入 M 模式（08 §6.1）
        else        priv_r <= priv_next;
    end

    assign priv_o      = priv_r;
    assign xret_target_priv_o = xret_target;   // 纯组合：mpp_l / SPP + kind
    assign priv_next_o = priv_next;
    assign flush_req   = (trap_valid | xret_valid) & (priv_next != priv_r);

    //==========================================================================
    // 3. mstatus 的陷阱入口更新 / xRET 更新（置位/清除向量，给 csr_file）
    //==========================================================================
    // 3.1 有序合成：xRET 先落地，trap 后落地（同拍时）
    //   ★ 新根因（MRET+IRQ 同拍，2026-10-22）：旧实现把 trap_set 与 xret_set 直接 OR。
    //     MPIE=1 的 MRET 会在 set 里重新置 MIE=1，压过 trap 的 MIE←0 ⇒ 入口 MIE=1，
    //     handler 第一条又取中断（2 次 IRQ，稳定值错成 1888）。
    //   ★ 正确语义（程序序）：xRET 先返回（MIE←MPIE、MPIE←1、MPP←U、按需清 MPRV），
    //     合法 trap 在返回**之后**按返回后的状态/模式落地（MPIE←MIE_after、MIE←0、
    //     MPP←y_after；S 组同理）。同拍 ⇒ 以 xret 后的值作 trap 的"陷阱前值"：
    //      最终 = (xret_after & ~trap_clr) | trap_set
    //     再与当前架构值（含同拍 CSR 写旁路）比较，导出精确的 set/clr 向量，
    //     使 csr_file 的 `(stored & ~clr) | set` 得到该最终值。
    //   非重叠情形与旧实现逐位等价（xret-only / trap-only 的结果不变）。
    wire        xret_s       = xret_valid && (xret_kind == 2'b00);
    wire        xret_m       = xret_valid && (xret_kind == 2'b01);
    wire        xret_low_priv = xret_valid && (xret_target != PRIV_M);

    wire [31:0] xret_after_pre =
        xret_m ? ((mstat_eff & ~((32'h1 << `RV32GC_MSTATUS_MIE_BIT) |
                                 (`RV32GC_MSTATUS_MPP_MSK << `RV32GC_MSTATUS_MPP_LSB))) |
                  (f_mpie ? (32'h1 << `RV32GC_MSTATUS_MIE_BIT) : 32'h0) |
                  (32'h1 << `RV32GC_MSTATUS_MPIE_BIT))
      : xret_s ? ((mstat_eff & ~((32'h1 << `RV32GC_MSTATUS_SIE_BIT) |
                                 (32'h1 << `RV32GC_MSTATUS_SPP_BIT))) |
                  (f_spie ? (32'h1 << `RV32GC_MSTATUS_SIE_BIT) : 32'h0) |
                  (32'h1 << `RV32GC_MSTATUS_SPIE_BIT))
      : mstat_eff;
    wire [31:0] xret_after = xret_low_priv
        ? (xret_after_pre & ~(32'h1 << `RV32GC_MSTATUS_MPRV_BIT))
        : xret_after_pre;
    //   "陷阱发生时"的特权级 = 返回后的特权级（同拍 xret 时）
    wire [1:0]  priv_after  = xret_valid ? xret_target : priv_r;
    wire        f_mie_after = xret_after[`RV32GC_MSTATUS_MIE_BIT];
    wire        f_sie_after = xret_after[`RV32GC_MSTATUS_SIE_BIT];

    // ---- 陷阱入口（06 §3.1；ISA norm:mstatusxpiexiexpptrap_op）----
    //   「When a trap is taken from privilege mode y into privilege mode x,
    //     xPIE ← xIE; xIE ← 0; xPP ← y.」 —— 其中 xIE/y 取**返回后**值。
    wire trap_to_s = trap_valid && (trap_target == PRIV_S);
    wire trap_to_m = trap_valid && (trap_target == PRIV_M);

    // ---- M 组：MPIE ← MIE(after)、MPP ← y(after)（替换）----
    wire [31:0] trap_set_m =
        trap_to_m ? ((({31'b0, f_mie_after})  << `RV32GC_MSTATUS_MPIE_BIT) |
                     (({30'b0, priv_after})   << `RV32GC_MSTATUS_MPP_LSB)) : 32'h0;
    wire [31:0] trap_clr_m =
        trap_to_m ? ((32'h1 << `RV32GC_MSTATUS_MIE_BIT) |
                     (32'h1 << `RV32GC_MSTATUS_MPIE_BIT) |
                     (`RV32GC_MSTATUS_MPP_MSK << `RV32GC_MSTATUS_MPP_LSB)) : 32'h0;

    // ---- S 组：SPIE ← SIE(after)、SPP ← y(after)（U⇒0 / S⇒1）----
    wire [31:0] trap_set_s =
        trap_to_s ? ((({31'b0, f_sie_after})              << `RV32GC_MSTATUS_SPIE_BIT) |
                     (({31'b0, (priv_after == PRIV_S)})   << `RV32GC_MSTATUS_SPP_BIT))  : 32'h0;
    wire [31:0] trap_clr_s =
        trap_to_s ? ((32'h1 << `RV32GC_MSTATUS_SIE_BIT) |
                     (32'h1 << `RV32GC_MSTATUS_SPIE_BIT) |
                     (32'h1 << `RV32GC_MSTATUS_SPP_BIT)) : 32'h0;

    wire [31:0] mstat_after = (xret_after & ~(trap_clr_m | trap_clr_s)) |
                              (trap_set_m | trap_set_s);

    // ---- 3.2 xRET（ISA norm:mstatusxretop）----
    //   「xIE ← xPIE; privilege ← xPP; xPIE ← 1; xPP ← 最低已实现特权级(U);
    //     if y ≠ M also mprv ← 0」
    //   ★ P1：只有目标 < M 才清 MPRV；mret 回 M 不清。
    wire [31:0] xret_clr_m =
        xret_m ? ((32'h1 << `RV32GC_MSTATUS_MIE_BIT) |
                  (`RV32GC_MSTATUS_MPP_MSK << `RV32GC_MSTATUS_MPP_LSB)) : 32'h0;
    wire [31:0] xret_set_m =
        xret_m ? ((f_mpie ? (32'h1 << `RV32GC_MSTATUS_MIE_BIT) : 32'h0) |
                  (32'h1 << `RV32GC_MSTATUS_MPIE_BIT)) : 32'h0;
    wire [31:0] xret_clr_s =
        xret_s ? ((32'h1 << `RV32GC_MSTATUS_SIE_BIT) |
                  (32'h1 << `RV32GC_MSTATUS_SPP_BIT)) : 32'h0;
    wire [31:0] xret_set_s =
        xret_s ? ((f_spie ? (32'h1 << `RV32GC_MSTATUS_SIE_BIT) : 32'h0) |
                  (32'h1 << `RV32GC_MSTATUS_SPIE_BIT)) : 32'h0;
    wire [31:0] xret_clr_mprv = xret_low_priv ? (32'h1 << `RV32GC_MSTATUS_MPRV_BIT) : 32'h0;

    //   ★ 同拍 xRET+trap：用"先返回后陷阱"的精确 set/clr（mstat_after 相对当前值）；
    //     非重叠（只 xret / 只 trap / 都没有）保持旧向量形式逐位不变
    //     （trap/xret 的既有单事件断言与行为零回归）。
    wire xret_trap_both = trap_valid && xret_valid;
    assign mstatus_set = xret_trap_both
        ? (mstat_after & ~mstat_eff)
        : (trap_set_m | trap_set_s | xret_set_m | xret_set_s);
    assign mstatus_clr = xret_trap_both
        ? (~mstat_after & mstat_eff)
        : (trap_clr_m | trap_clr_s | xret_clr_m | xret_clr_s | xret_clr_mprv);

    //==========================================================================
    // 4. 有效特权级与 SUM/MXR 有效值（★ P3/P4）
    //==========================================================================
    //   eff_priv = MPRV ? MPP : 当前特权级     ← ★ P3「按 MPP 语义」
    //   取指不受 MPRV 影响 ⇒ 另有 fetch_priv 输出为当前特权级。
    wire [1:0] eff_priv = f_mprv ? mpp_l : priv_r;
    assign eff_priv_o  = eff_priv;

    // ---- ★ P4：SUM 只在有效特权级 == S 时生效 ----
    //   规范原文："while sum is ordinarily ignored when not executing in S-mode,
    //   it is in effect when mprv=1 and mpp=S" ⇒ 判据的统一形式即 eff_priv == S。
    wire sum_eff = f_sum && (eff_priv == PRIV_S);
    // ---- MXR 只影响有效特权级 < M 的 load ----
    wire mxr_eff = f_mxr && (eff_priv != PRIV_M);

    assign mprv_o = f_mprv;
    assign sum_o  = sum_eff;
    assign mxr_o  = mxr_eff;
    assign mpp_o  = mpp_l;
    assign tvm_o  = f_tvm;
    assign tw_o   = f_tw;
    assign tsr_o  = f_tsr;
    // ---- 取指：MPRV 不影响取指的翻译与保护 ⇒ 恒用当前特权级 ----
    assign fetch_priv_is_m_o = (priv_r == PRIV_M);

endmodule
