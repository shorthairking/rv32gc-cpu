//==============================================================================
// rtl/top/core_top_2b.v —— 2B-4 第 2 段：**CPU 顶层合体**（front4 + backend_top）
//==============================================================================
// 项目  : rv32gc-cpu（阶段二 2B-4）
// 规格  : docs/design/02-pipeline.md（F1–F4 / D1–D3 / I1–I2 / E1 / W1）、
//         docs/design/03-out-of-order.md（ROB/重命名/发射/LSQ）、
//         docs/design/08-baseline-5stage.md §4.3/§5.1（RESET_PC、XIP 直通、
//         L1I/PTW 契约与"PTW 串行复用"纪律）；
//         入口台账：sim/unit/back2_report.md §B4.1（本段交付）与 §B4.2。
//
// 【本文件是什么】
//   把 2A 顺序核（rtl/top/core_top.v）的 **F/D/E 段**换成
//   `front4_top`（4 宽取指 + 锦标赛预测器 + 检查点）＋ `backend_top`（ROB 128 +
//   重命名 + 分布式发射 + LSQ），**取指侧**按 2A 口径接 I-TLB/PTW → L1I → XIP 直通
//   → 核内 AXI 读引擎（复用 2A 的 `axi_master_ctrl`）；**数据侧**本段为显式占位。
//
// 【端口契约】48 个契约端口与 `rtl/top/core_top.v` **逐端口同名同向同位宽**
//   （核对表见报告 §B4.2.2）。**2B-4 第 3 段起：不再有占位端口**（`oo_mem_*` 已删除，
//   数据侧接 2A `l1d` + 核内 AXI 引擎）。
//
// 【本段"真实现"清单】
//   ① 取指：RESET_PC=0x1C00_0000（由 front4/pc_gen4 内置）→ XIP 直通（不查 L1I）
//      → 跳板 → DDR3 走 L1I 行填充；XIP 与 L1I 的"陈旧响应归属校验"按 2A 口径；
//   ② L1I：2A `l1i` 实例（16 KB/2 路/32 B 行）+ 行填充握手；
//   ③ 核内 AXI 读引擎：单笔在途、三请求源（XIP 单字 / L1I 行填充 / **PTE 单字**）
//      共用 2A `axi_master_ctrl`（协议逻辑不重写；本文件只写"核内请求粘合"）；
//   ④ front4 ↔ backend_top 全接口（重定向/训练/检查点/RAS/D2）；
//   ⑤ backend_top：ROB/重命名/发射/PRF/LSQ/b2_csr 过渡栈（提交点 CSR）；
//   ⑥ 调试口：`ws_valid`/`debug0_wb_*` 由 backend 的提交流驱动；`break_point` 接 front4。
//
// 【★ 本段"结构性就位但功能未验证"清单（不得读作已实现）】
//   · `tlb`/`ptw`/PTE 用 `pmp_check` 已按 2A 口径**实例化并接线**（取指第二查询口
//     `lookup2_*` + PTW 请求/PTE 读通路），但 **satp 占位 = 0（Bare）** ⇒
//     `sv32_translate_en = 0` ⇒ 本段**功能上不启用 Sv32**（第 4 段接完整 CSR 后启用）。
//   · PTW 的 **A/D 更新写通路未实现**（`pte_ad_done` 恒 0 ⇒ 若 Sv32 被启用会**挂死**，
//     fail-closed；第 4 段补 AXI 写通路）。
//   · PMP 取指检查：`pmpcfg_i/pmpaddr_i` 恒 0 + `priv = M` ⇒ M 模式无匹配项 ⇒ 放行
//     （第 4 段接 csr_file 的 PMP 上下文）。
//
// 【★ 本段"占位"清单（必须注释标注；报告 §B4.2.3 同步登记）】
//   · **数据侧（LSU）**：**2B-4 第 3 段已接入** 2A `l1d`（32 KB/4 路/32 B 行）+
//     核内 AXI 引擎；I/D 共用单笔在途总线口，仲裁优先序按 2A §11.1：
//     写回 > D 填充 > uncached 数据/PTE > XIP 取指 > I 填充。
//   · **完整 CSR / 陷阱 / 中断**：本段用 `backend_top` 内的 `b2_csr` 过渡栈
//     （mscratch/mepc/mcause/mtvec/mstatus + fcsr）；`intrpt[7:0]` **本段不接**
//     （CLINT/PLIC 端口按任务书悬空/契约电平）；完整特权与异常交付留**第 4 段**。
//   · `infor_flag/reg_num/rf_rdata`（调试寄存器读口）本段恒 0（占位）；
//     `debug0_wb_*` 只取**提交组 lane 0**（多宽提交时其余 lane 不输出，与 2A 单发射
//     口径的差异见报告 §B4.2.3）。
//   · XIP 窗口外的 uncached 取指（MMIO 取指）未接：`unc_req_valid` 只可能来自 XIP
//     窗口（front4 判定），窗口外不会产生 ✓。
//
// 风格  : 组合逻辑用 `assign` + 条件表达式；`always` 块只用于少量时序元件
//         （XIP 字保持、L1I 响应归属、I 侧 AXI 引擎、程序计数器类）。
//==============================================================================

`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"
`include "rtl/front4/front4_params.vh"
`include "rtl/back2/back2_params.vh"

module core_top_2b (
    //--------------------------------------------------------------------------
    // 时钟 / 复位 / 中断（08 §4.1 #1–#3）—— 契约端口
    //   ★ `intrpt` 本段**不接**（中断交付属第 4 段；CLINT/PLIC 未接）
    //--------------------------------------------------------------------------
    input  wire        aclk,               // = cpu_clk（同域）
    input  wire [7:0]  intrpt,             // ★ 占位：本段未使用（第 4 段）
    input  wire        aresetn,            // 低有效复位

    //--------------------------------------------------------------------------
    // AXI4 读地址通道 AR（#4–#13）—— 契约端口（本段由取指使用）
    //--------------------------------------------------------------------------
    output wire [3:0]  arid,
    output wire [31:0] araddr,
    output wire [3:0]  arlen,
    output wire [2:0]  arsize,
    output wire [1:0]  arburst,
    output wire [1:0]  arlock,             // ★ 只驱动 [0]，[1] 显式置 0
    output wire [3:0]  arcache,
    output wire [2:0]  arprot,
    output wire        arvalid,
    input  wire        arready,

    //--------------------------------------------------------------------------
    // AXI4 读数据通道 R（#14–#19）
    //--------------------------------------------------------------------------
    input  wire [3:0]  rid,
    input  wire [31:0] rdata,
    input  wire [1:0]  rresp,
    input  wire        rlast,
    input  wire        rvalid,
    output wire        rready,

    //--------------------------------------------------------------------------
    // AXI4 写地址通道 AW（#20–#29）—— 本段无写主设备 ⇒ 契约电平（恒 0）
    //--------------------------------------------------------------------------
    output wire [3:0]  awid,
    output wire [31:0] awaddr,
    output wire [3:0]  awlen,
    output wire [2:0]  awsize,
    output wire [1:0]  awburst,
    output wire [1:0]  awlock,
    output wire [3:0]  awcache,
    output wire [2:0]  awprot,
    output wire        awvalid,
    input  wire        awready,

    //--------------------------------------------------------------------------
    // AXI4 写数据通道 W（#30–#35）—— 契约电平（恒 0）
    //--------------------------------------------------------------------------
    output wire [3:0]  wid,
    output wire [31:0] wdata,
    output wire [3:0]  wstrb,
    output wire        wlast,
    output wire        wvalid,
    input  wire        wready,

    //--------------------------------------------------------------------------
    // AXI4 写响应通道 B（#36–#39）
    //--------------------------------------------------------------------------
    input  wire [3:0]  bid,
    input  wire [1:0]  bresp,
    input  wire        bvalid,
    output wire        bready,

    //--------------------------------------------------------------------------
    // 调试组（#40–#48；口径 08 §4.4）
    //--------------------------------------------------------------------------
    output wire        ws_valid,           // 提交拍（backend 提交流非空）
    input  wire        break_point,        // 平台断点探针（F 级生效）
    input  wire        infor_flag,         // ★ 占位：本段未接（第 4 段）
    input  wire [4:0]  reg_num,            // ★ 占位：本段未接（第 4 段）
    output wire [31:0] rf_rdata,           // ★ 占位：恒 0（第 4 段接架构寄存器读口）
    output wire [31:0] debug0_wb_pc,       // 提交组 lane 0 的 PC
    output wire [3:0]  debug0_wb_rf_wen,   // ★ [3:0]；本文件只驱动 [0]（与 2A 同口径）
    output wire [4:0]  debug0_wb_rf_wnum,  // 目的架构寄存器号（提交组 lane 0）
    output wire [31:0] debug0_wb_rf_wdata  // 写回数据（提交组 lane 0）
    //   ★ 2B-4 第 3 段：数据侧占位端口 `oo_mem_*` **已删除** —— LSU 访存口改接
    //     `l1d` 实例 + 核内 AXI 引擎（§4b/§5）⇒ 端口契约 = **纯 48 端口**。
);

    //==========================================================================
    // 0. 常量
    //==========================================================================
    localparam integer N_PMP = `RV32GC_PMP_ENTRIES;
    localparam [31:0]  XIP_BASE_M = `RV32GC_XIP_BASE;      // 0x1C00_0000
    localparam [31:0]  XIP_ALIAS_M= `RV32GC_XIP_ALIAS;     // 0x1FE8_0000
    localparam         AXI_ID_IFILL = `RV32GC_AXI_ID_I_FILL;

    //==========================================================================
    // 1. front4 ↔ backend_top：块接口（4 宽派发）
    //==========================================================================
    wire        blk_valid, blk_ready, blk_taken, fe_fetch_fault, fe_frozen;
    wire [3:0]  blk_mask;
    wire [31:0] blk_next_pc;
    wire [127:0] lane_pc, lane_pa, lane_insn, lane_pred_target, lane_btb_target, lane_fault_tval;
    wire [3:0]  lane_len32, lane_pred_taken, lane_pred_selg, lane_pred_gdir, lane_pred_ldir;
    wire [3:0]  lane_btb_hit, lane_btb_way, lane_btb_cond, lane_btb_call, lane_btb_ret;
    wire [3:0]  lane_fault, lane_ckpt_valid;
    wire [11:0] lane_cls;
    wire [19:0] lane_fault_cause;
    wire [15:0] lane_ckpt;

    wire        redirect_valid, redirect_use_ckpt;
    wire [31:0] redirect_pc;
    wire [3:0]  redirect_ckpt;
    wire        train_valid, train_ready;
    wire [31:0] train_pc, train_target, train_pred_target;
    wire        train_is_cond, train_taken, train_is_indirect, train_is_call, train_is_return;
    wire        train_pred_taken, train_pred_sel_global, train_pred_gdir, train_pred_ldir;
    wire        train_pred_valid, train_btb_hit, train_btb_way;
    wire        ckpt_free_valid;
    wire [3:0]  ckpt_free_id;
    wire        ras_cmt_push, ras_cmt_pop;
    wire        d2_push_valid, d2_pop_valid;
    wire [31:0] d2_push_addr, d2_pop_addr;
    wire        ras_repair_valid;
    wire [31:0] ras_repair_addr;

    // 取指侧（front4 ↔ L1I/XIP/TLB）
    wire        l1i_req_valid, l1i_uncached_w;
    wire [31:0] l1i_req_addr, l1i_req_line;
    wire        l1i_ready_w, l1i_miss_w;
    wire [31:0] l1i_rdata_w;
    wire        unc_req_valid;
    wire [31:0] unc_req_pa;
    wire        unc_rsp_valid;
    wire [31:0] unc_rsp_pa, unc_rsp_data;
    wire        tr_req_valid;
    wire [31:0] tr_req_va;

    // 提交流（调试口 + 观测）
    wire [3:0]  commit_valid;
    wire [127:0] commit_pc, commit_arch_rd_wdata;
    wire [19:0] commit_arch_rd;
    wire [3:0]  commit_arch_we;
    wire [31:0] cnt_commit, cnt_squash;
    wire [7:0]  dbg_stq_cnt_w;
    //   ★★ 2B-4 第 4a 段：**陷阱/中断交付已落地**（不再是占位）
    wire        trap_valid_w;
    wire [31:0] trap_pc_w, trap_tval_w;
    wire [3:0]  trap_cause_w;
    wire        xret_cmt_w, irq_mti_w;
    wire [31:0] csr_mtvec_w, csr_mepc_w;
    //   ★★ 2B-4 第 4b-1a 段：**CSR 文件搬到顶层**（行为等价重构）
    //     后端只留"读口/写口/陷阱写口"三类接口；CSR 寄存器本体在本层例化。
    wire [11:0] csr_raddr_w;
    wire [31:0] csr_rdata_w;
    wire        csr_we_w;
    wire [11:0] csr_waddr_w;
    wire [31:0] csr_wdata_w;
    //   ★★ 4b-1c：`csr_frm_w`/`csr_ff_w`（FPU 舍入模式 / fcsr.fflags 回灌）在 4a 由 `b2_csr`
    //     输出；换成 2A `csr_file` 后它没有对应的**读侧派生输出**（2A 的 FPU 走 `csr_file`
    //     自己的 fcsr 视图，FP 集成时再接）。本核 `core_top_2b` 尚无 FP 程序/FP 提交路径
    //     （TB 七个程序全整数）⇒ 先接 `frm = RNE(0)`、`fflags = 0`（= fcsr 复位值，语义正确），
    //     并把"软件写 frm 对 FPU 可见"列入 FP 集成待办（报告 §B4.6.4-⑩）。
    wire [2:0]  csr_frm_w = 3'h0;
    wire [4:0]  csr_ff_w  = 5'h0;
    wire [1:0]  xret_kind_w;
    //   ★★ 2B-4 第 4b-2a 段：维护操作（fence.i / sfence.vma / cbo.*）
    wire [2:0]  maint_kind_w;
    wire        maint_cmt_w;
    wire [31:0] maint_pc_w;
    wire [31:0] csr_menvcfg_w;
    wire [1:0]  cbo_perm_w = {csr_menvcfg_w[6], |csr_menvcfg_w[5:4]};   // {CBCFE, CBIE≠0}
    //   fence.i 的"全阵列失效"扫掠（照 2A `core_top.v:885-905/3744-3749`：8 bit 索引
    //   256 拍，每拍以 `{19'b0, idx, 5'b00000}` 作为 L1I 的 index 输入）
    reg         fencei_busy, fencei_busy_q;
    reg         fencei_wait_q;          // ★ K1：等 L1I 空闲再启动扫掠（避免打断在途请求）
    reg  [7:0]  fencei_idx_q;
    reg  [31:0] fencei_pc_q;
    wire        fencei_hold_w = fencei_busy | fencei_busy_q;
    wire        fencei_pend_w = fencei_busy | fencei_wait_q | fencei_busy_q;
    wire        maint_fencei_w = maint_cmt_w & (maint_kind_w == 3'd1);
    wire        maint_sfence_w = maint_cmt_w & (maint_kind_w == 3'd2);
    wire        maint_cbo_w    = maint_cmt_w & (maint_kind_w >= 3'd3);
    //   ★★ 2B-4 内存序缺口修复（修法 1）：维护动作**等"数据通道排空"再发**。
    //      `maint_wait_cdq_q`：维护已提交但排空未完 ⇒ 挂起（保持冲刷与冻结）；
    //      `maint_kind_save_q`：挂起期间锁存动作码（提交脉冲只有一拍）；
    //      `maint_act_q`：**排空后发出的单拍动作脉冲**（维护口全部由它驱动）。
    reg         maint_wait_cdq_q;
    reg  [2:0]  maint_kind_save_q;
    reg         maint_act_q;
    //   ★★ 注意：动作码**必须用锁存值** `maint_kind_save_q` —— `maint_act_q` 是在
    //     "提交拍之后"（立即路径下一拍 / 排空后那一拍）才拉高的，而 `maint_kind_w`
    //     只在提交拍有效（下一拍就归 0）⇒ 用 `maint_kind_w` 会让动作码退化成 0
    //     （实测：p11 的 2 次 sfence 维护动作全部丢失，`n_tlb_sfence` 计数 = 0）。
    wire [2:0]  maint_kind_act_w = maint_kind_save_q;
    //   维护口（TB 可探针）
    wire        maint_l1i_inval_w  = fencei_busy;                       // fence.i 扫掠期间拉高
    //   ★ K1'' 修正：**sfence.vma 不动 L1D**（本核 L1D 为物理索引/标签 ⇒ VA 重映射无需
    //     失效数据缓存；失效反而丢脏数据——实测 p11 第 12 条 load 读到 0 而非 0x11223344）。
    //     只有 cbo.inval / cbo.flush 才失效 L1D（Zicbom 的 INVAL 本就是破坏性的）。
    //   ★★ p12 根因修正：动作码判据必须是 **3=inval / 4=clean / 5=flush**（imm12[1:0] 口径，
    //      见 backend_top `maint_kind_f`）。原先按 `funct3` 区分 ⇒ 三条 cbo 全落 flush
    //      ⇒ 每次 cbo 都 `inval_all`+`clean_all` ⇒ L1D 无写回整体失效 ⇒ store 数据丢失。
    //   ★★ 口径登记（conservative flush）：`cbo.flush` 的 **INVAL 部分本段不实现** ——
    //      2A L1D 维护口只有"清 valid（inval_all）/清 dirty（clean_all）"两条路，
    //      **没有维护写回通道** ⇒ 真 flush 会丢已提交脏行（实测 p12 第 12/13 条 load
    //      读到 0）。本核为单核、无外部缓存代理 ⇒ 取"数据不丢"的保守语义：flush 只 clean。
    //      待 2A L1D 维护写回通道落地后再补 INVAL（报告 §B4.18 待办）。
    wire        maint_l1d_inval_w  = maint_act_q & (maint_kind_act_w == 3'd3);   // cbo.inval
    wire        maint_l1d_clean_w  = maint_act_q & (maint_kind_act_w >= 3'd4);   // clean/flush
    //   （fence.i **不刷 TLB** —— 它只管指令缓存；sfence.vma 才刷 TLB，2A 同口径）
    wire        maint_tlb_sfence_w = maint_act_q & (maint_kind_act_w == 3'd2);
    wire [6:0]  dbg_rob_cnt_w;
    wire        cdq_empty_w;        // ★ 修法 1：已提交 store 全部排空（LSQ→backend→本层）
    //   ★★ 2B-4 第 4b-1b 段：2A `csr_file`+`priv_ctrl`+`trap_ctrl` 替换 `b2_csr`
    wire [31:0] csr_mtvec_o, csr_stvec_o, csr_medeleg_o, csr_mideleg_o;
    wire [31:0] csr_mie_o, csr_mip_o, csr_mepc_o, csr_sepc_o, csr_satp_o;
    wire [31:0] csr_mstatus_raw;
    wire [1:0]  csr_priv_2, csr_eff_priv;
    wire [31:0] mstatus_set, mstatus_clr;
    wire [N_PMP*8-1:0]  pmp_cfg_flat;
    wire [N_PMP*32-1:0] pmp_addr_flat;
    reg  [63:0] cycle_cnt, instret_cnt;
    wire        tc_trap_valid, tc_trap_is_int, tc_trap_we;
    //   ★ `trap_ctrl.trap_target` 是**目的特权级**（送 `priv_ctrl`），不是 PC！
    //     陷阱入口 PC 是 `redirect_pc`（= `trap_pc`，含 Direct/Vectored 合成）
    wire [1:0]  tc_trap_target;
    wire [31:0] tc_redirect_pc, tc_trap_cause, tc_trap_tval, tc_trap_epc, tc_trap_pc;
    wire [31:0] tc_trap_epc_i, tc_trap_cause_i, tc_trap_tval_i;
    wire        rob_any_w = (dbg_rob_cnt_w != 7'd0);
    //   ★ 裁决①：ecall 的 mtval 按 **Spike = 0**（2A 是 PC，偏差登记在册）；
    //     断点 cause 3 取 PC（Spike 实测口径）；非法指令由 trap_ctrl 用 commit_insn 覆盖；
    //     其余（取指/访存异常）沿用载荷 TVAL（= 故障 VA）。
    wire [31:0] exc_tval_adapt_w =
        (trap_cause_w == `BACK2_EXC_BREAK)                        ? trap_pc_w :
        ((trap_cause_w == `BACK2_EXC_ECALL_M) |
         (trap_cause_w == `BACK2_EXC_ECALL_S) |
         (trap_cause_w == `BACK2_EXC_ECALL_U))                    ? 32'h0 :
                                                                    trap_tval_w;
    wire [2:0]  cmt_num_w = {2'b0, commit_valid[0]} + {2'b0, commit_valid[1]} +
                            {2'b0, commit_valid[2]} + {2'b0, commit_valid[3]};
    //   ★ 陷阱 FSM 的**组合**出口（声明必须在 backend_top 例化之前；否则隐式 1 位网）
    wire        be_trp_flush, be_trp_redirect_v, trp_halt_w;
    wire [31:0] be_trp_redirect_pc;
    //   ★★ 2B-4 第 4a 段（第 4 步）：**核内 CLINT MTIP**（2A `clint` 模块只读复用）
    wire        clint_mtip_w, clint_msip_w;

    //==========================================================================
    // 2. 取指翻译（I-TLB / PTW）：**结构性就位，satp 占位 = Bare ⇒ 本段不启用**
    //--------------------------------------------------------------------------
    //  2A 口径（core_top.v §9.4.1）：TLB 第二查询口负责取指（纯组合、命中零等待），
    //  PTW 由 M 级引擎**串行复用**驱动。本段数据侧为占位（无数据侧翻译请求）
    //  ⇒ PTW 只服务取指，无争用；第 3 段接 L1D 后**必须**恢复 2A 的串行复用纪律
    //  （单请求口 ⇒ 两方共用需仲裁 + `m_tr_src` 归属）。
    //==========================================================================
    wire        f_tlb_hit, f_tlb_perm_fault;
    wire [31:0] f_tlb_pa;
    wire        ptw_fill_valid;
    wire [31:0] ptw_fill_va;
    wire [21:0] ptw_fill_ppn;
    wire [7:0]  ptw_fill_perm;
    wire        ptw_req_done, ptw_fault, ptw_pte_req_valid;
    wire [31:0] ptw_pa_out, ptw_pte_req_pa;
    wire        ptw_pmp_req_valid;
    wire [31:0] ptw_pmp_req_addr;
    wire [1:0]  ptw_pmp_req_acc, ptw_pmp_req_priv;
    wire [4:0]  ptw_fault_cause;
    wire [31:0] ptw_fault_tval;
    wire        ptw_pmp_ok, ptw_pte_ad_update;
    wire [31:0] ptw_pte_ad_pa, ptw_pte_ad_data;
    //   PTW 的 PTE 读口 / A-D 写口（由 §5 的核内 AXI 引擎驱动；先声明后使用）
    wire        pte_req_ready_w;
    wire        pte_resp_valid_w;
    wire [31:0] pte_resp_data_w;

    //   ★ 占位：satp = 0（Bare）、无 Sv32 ⇒ 取指直通（VA=PA）。
    //     第 4 段把 `satp` 换成 csr_file 的真值并接 `sv32_translate_*` 控制器。
    //   ★★ 4b-1c：`satp` 改接 `csr_file.satp_o`（4b-2 的 Sv32 全链路从这条线开始）。
    //     复位后 `satp = 0` ⇒ MODE=0（Bare）⇒ `sv32_en = 0` ⇒ **行为与替换前逐拍相同**；
    //     4b-2 再把 D 侧 TLB 查询口、PTW 串行复用（数据优先）、PTE A/D 写通路、
    //     `sfence.vma`/`cbo.*` 接提交点补齐（见报告 §B4.5.3）。
    wire        sv32_en      = csr_satp_o[`RV32GC_SATP_MODE_BIT];
    //   ★★ 4b-2b：PTW 归属寄存器（0 = 数据侧 / 1 = 取指侧，2A `m_tr_src_q` 同构）。
    //     取指侧的 done/fault 必须按归属过滤 —— 否则**数据侧遍历完成时会误当取指翻译完成**
    //     （`ptw_req_done` 是共享的）。
    reg         m_tr_src_q;
    wire        ptw_owner_fetch_w = (m_tr_src_q == 1'b1);
    //   ★★ 4b-2b：取指翻译/保护**不受 MPRV 影响**（norm:mstatusmprvinstxlatop；
    //     2A `priv_ctrl.v:19/237-239` 亦明示）⇒ 取指侧必须用**当前特权级** `csr_priv_2`，
    //     **不能**用含 MPRV 语义的 `csr_eff_priv`（否则 M 模式 + MPRV=1 时取指会被误翻译，
    //     实测：p13 里取指侧抢走 PTW 并做了一笔错误的遍历）。
    wire        f_xlate_on_w = (csr_priv_2 != `RV32GC_PRIV_M);
    wire        sv32_done    = f_tlb_hit | (ptw_req_done & ptw_owner_fetch_w);
    wire        sv32_fault   = f_tlb_perm_fault | (ptw_fault & ptw_owner_fetch_w);
    wire [31:0] sv32_paddr   = f_tlb_hit ? f_tlb_pa : ptw_pa_out;

    //==========================================================================
    // 2b. 数据侧翻译（2B-4 第 4b-2b 段）：TLB 口 1 + PTW 串行复用（数据优先）
    //--------------------------------------------------------------------------
    //  2A 口径（`core_top.v` §9.4.1 / `:1587-1595` / `:1790-1797`）：TLB 第一查询口给
    //  数据侧（纯组合命中、零等待），**PTW 是单请求口、由 I/D 串行复用**，`m_tr_src_q`
    //  记录"本笔遍历归谁"（0 = 数据侧 / 1 = 取指侧），完成时据此选择结果去向。
    //  本核把数据侧翻译做在 LSU 适配器里（新增 `AD_XLATE` / `AD_TR` 两级状态）：
    //    · 不需要翻译（satp = Bare，或 M 模式且未置 MPRV）⇒ **整级跳过**，逐拍与旧版相同
    //    · 需要翻译：VA 送 TLB 口 1；命中 ⇒ 直接用 PA；缺失 ⇒ 向 PTW 发请求并等 `req_done`
    //    · 权限错（TLB perm_fault）/ PTW 故障 ⇒ 以"正常响应 + err=1"回一笔给 LSQ
    //      ⇒ 该 load 以**精确页错误**（cause 13、mtval = VA）结束（不写回数据）
    //    · **数据优先**：数据请求到来时若 PTW 正被取指占用 ⇒ `kill` 取指遍历
    //      （取指侧 `tr_req_valid` 是电平保持 ⇒ 释放后自动重发；与 2A 同法）
    //==========================================================================
    //   ★ 4b-2b：状态码扩到 3 bit（新增 AD_XLATE/AD_TR —— 2 bit 会截断成 0/1 与 IDLE/REQ 撞车）
    localparam [2:0] AD_IDLE = 3'd0, AD_REQ = 3'd1, AD_WAIT = 3'd2, AD_RETRY = 3'd3;
    localparam [2:0] AD_XLATE = 3'd4, AD_TR = 3'd5;     // ★ 4b-2b：数据侧翻译两级

    reg [2:0]   ad_st_q;
    reg         d_we_q;
    reg         d_unc_q;                 // 该笔走 uncached 直通（AXI 单 beat）
    reg         d_cp_q;                  // 该笔落 CLINT/PLIC 窗口（本段无总线事务，占位）
    reg [31:0]  d_a_q, d_d_q;            // ★ `d_a_q` = **物理地址**（翻译后）
    reg [31:0]  d_va_q;                  // ★ 4b-2b：翻译前的虚拟地址（异常 tval / 重发用）
    reg [3:0]   d_strb_q;
    reg [`BACK2_MEM_TAG_W-1:0] d_tag_q;

    //   LSU 的存储口（先声明，§4b 使用）
    wire        lsu_req_v, lsu_req_we;
    wire [31:0] lsu_req_a, lsu_req_d;
    wire [3:0]  lsu_req_strb;
    wire [`BACK2_MEM_TAG_W-1:0] lsu_req_tag;

    //   ★ 4b-2b：数据侧访问类型 / 有效特权级（MPRV=1 ⇒ 按 mstatus.MPP 判权限，2A 同口径）
    wire        d_mprv_w      = csr_mstatus_raw[`RV32GC_MSTATUS_MPRV_BIT];
    //   口径（ISA）：MPRV 只在 **MPP ≠ M** 时生效 —— MPP=M 时按"未置 MPRV"处理
    //   （否则陷阱处理程序在 M 模式下会被误按 MPP 翻译）
    wire        d_mprv_eff_w  = d_mprv_w & (csr_mstatus_raw[`RV32GC_MSTATUS_MPP_LSB +: 2]
                                            != `RV32GC_PRIV_M);
    wire [1:0]  d_eff_priv_w  = d_mprv_eff_w ? csr_mstatus_raw[`RV32GC_MSTATUS_MPP_LSB +: 2]
                                             : csr_eff_priv;
    wire [1:0]  d_acc_w       = d_we_q ? 2'b10 : 2'b01;      // 10=store / 01=load
    wire        d_xlate_on_w  = (csr_eff_priv != `RV32GC_PRIV_M) | d_mprv_eff_w;
    wire        d_xlat_need_w = sv32_en & d_xlate_on_w;
    wire        d_tlb_hit, d_tlb_perm_fault;
    wire [31:0] d_tlb_pa;

    //   PTW 请求仲裁（数据优先；取指在途被抢占时 `kill`）
    wire        ptw_req_ready_w;
    wire        d_ptw_want_w = (ad_st_q == AD_TR);
    wire        f_ptw_want_w = sv32_en & f_xlate_on_w & tr_req_valid & ~f_tlb_hit;
    wire        ptw_free_w   = ptw_req_ready_w;              // PTW 空闲（可接受新请求）
    wire        ptw_kill_w   = d_ptw_want_w & ~ptw_free_w & ptw_owner_fetch_w;
    wire        ptw_req_v_w  = d_ptw_want_w | (f_ptw_want_w & ~d_ptw_want_w);
    wire [31:0] ptw_req_va_w = d_ptw_want_w ? d_va_q : tr_req_va;

    //   路由（MMIO/uncached 判定，2A `mmio_route`）必须吃**物理地址**：
    //   翻译两级用各自的 PA；其余（Bare/空闲）用本拍请求 VA（= 旧行为，逐拍不变）
    wire [31:0] d_route_a_w  = (ad_st_q == AD_XLATE) ? d_tlb_pa :
                               (ad_st_q == AD_TR)    ? ptw_pa_out : lsu_req_a;

    tlb #(.ENTRIES(64), .AUTO_FLUSH_ON_ASID(0), .IDX_W(6)) u_tlb (
        .clk(aclk), .rst_n(aresetn),
        // ---- 第一查询口 = 数据侧（4b-2b 接通；`AD_XLATE` 拍纯组合命中）----
        .lookup_valid(ad_st_q == AD_XLATE), .lookup_va(d_va_q), .lookup_asid(9'h0),
        .lookup_acc(d_acc_w), .lookup_priv(d_eff_priv_w),
        .lookup_sum(csr_mstatus_raw[`RV32GC_MSTATUS_SUM_BIT]),
        .lookup_mxr(csr_mstatus_raw[`RV32GC_MSTATUS_MXR_BIT]),
        .hit_o(d_tlb_hit), .perm_fault_o(d_tlb_perm_fault), .pa_o(d_tlb_pa),
        // ---- 第二查询口 = 取指（2A §5.2.2/§9.4.1 同法）----
        .lookup2_valid(tr_req_valid), .lookup2_va(tr_req_va), .lookup2_asid(9'h0),
        .lookup2_acc(2'b00), .lookup2_priv(csr_priv_2),   // ★ 取指：当前特权级（不含 MPRV）
        .lookup2_sum(1'b0), .lookup2_mxr(1'b0),
        .hit2_o(f_tlb_hit), .perm_fault2_o(f_tlb_perm_fault), .pa2_o(f_tlb_pa),
        .fill_valid(ptw_fill_valid), .fill_va(ptw_fill_va), .fill_ppn(ptw_fill_ppn),
        .fill_perm(ptw_fill_perm), .fill_asid(9'h0),
        // ---- sfence.vma：本段无 CSR 提交源 ⇒ 恒无效（第 4 段接提交点）----
        //   ★ 4b-2a：sfence.vma ⇒ **全失效**（本核单地址空间/无 ASID，全刷恒正确；
        //     2A 做精确 va/asid 匹配，见 `core_top.v:1759`；口径差异登记 §B4.9.4）
        .sfence_valid(maint_tlb_sfence_w), .sfence_va(32'h0), .sfence_asid(9'h0),
        .sfence_all_va(1'b1), .sfence_all_asid(1'b1),
        //   写 satp（0x180）⇒ 刷 ASID（2A 同法）
        .satp_we(csr_we_w & (csr_waddr_w == 12'h180)),
        .satp_asid_new(csr_wdata_w[30:22]),
        .hit_count_o(), .miss_count_o(), .flush_count_o()
    );

    ptw u_ptw (
        .clk(aclk), .rst_n(aresetn),
        //   ★★ 4b-2b：**数据优先**抢占（取指遍历被 kill 后会自动重发；见 §2b 说明）
        .kill(ptw_kill_w),
        //   ★★ 4b-2b：I/D **串行复用**同一请求口（2A `m_tr_src_q` 同构）——
        //     数据侧在 `AD_TR` 期间占用；否则取指侧（且仅 S/U 模式）使用
        .req_valid(ptw_req_v_w),
        .req_va(ptw_req_va_w), .req_acc(d_ptw_want_w ? d_acc_w : 2'b00),
        .req_priv(d_eff_priv_w),
        .req_sum(d_ptw_want_w ? csr_mstatus_raw[`RV32GC_MSTATUS_SUM_BIT] : 1'b0),
        .req_mxr(d_ptw_want_w ? csr_mstatus_raw[`RV32GC_MSTATUS_MXR_BIT] : 1'b0),
        .satp(csr_satp_o),
        .req_ready(ptw_req_ready_w), .req_done(ptw_req_done), .pa_o(ptw_pa_out),
        .fault_o(ptw_fault), .fault_cause_o(ptw_fault_cause), .fault_tval_o(ptw_fault_tval),
        .pte_req_valid(ptw_pte_req_valid), .pte_req_pa(ptw_pte_req_pa),
        .pte_req_ready(pte_req_ready_w),
        .pte_resp_valid(pte_resp_valid_w), .pte_resp_data(pte_resp_data_w),
        .pmp_req_valid(ptw_pmp_req_valid), .pmp_req_addr(ptw_pmp_req_addr),
        .pmp_req_acc(ptw_pmp_req_acc), .pmp_req_priv(ptw_pmp_req_priv),
        .pmp_resp_ok(ptw_pmp_ok),
        .pte_ad_update(ptw_pte_ad_update), .pte_ad_pa(ptw_pte_ad_pa),
        .pte_ad_data(ptw_pte_ad_data),
        //   ★ 占位（fail-closed）：A/D 更新写通路**本段未实现** ⇒ 恒 0。
        //     不可达（Bare）；若第 4 段启用 Sv32 而忘了实现，会在此挂死而非静默跳过。
        .pte_ad_done(1'b0),
        .fill_valid(ptw_fill_valid), .fill_va(ptw_fill_va), .fill_pa(),
        .fill_ppn(ptw_fill_ppn), .fill_perm(ptw_fill_perm)
    );

    //   ★ 4b-1b：PTW 的访问类型 → PMP 检查类型（**逐字照抄 2A** `core_top.v:471-479`，
    //     不改 2A 文件；功能等价于"取指遍历的 PTE 按 X、数据侧按 LOAD/STORE"）
    function [1:0] pmp_acc_xlat;
        input [1:0] acc_ptw;
        begin
            case (acc_ptw)
                2'b00:   pmp_acc_xlat = 2'd2;   // 取指 ⇒ X
                2'b01:   pmp_acc_xlat = 2'd0;   // load ⇒ LOAD
                2'b10:   pmp_acc_xlat = 2'd1;   // store ⇒ STORE
                default: pmp_acc_xlat = 2'd3;   // 保留
            endcase
        end
    endfunction

    //   PTE 取也要过 PMP（08 §5.4 ④）；4b-1b 起接 `csr_file` 的 pmp_cfg/pmp_addr 真值
    pmp_check #(.PMP_ENTRIES(N_PMP)) u_pmp_pte (
        .clk(aclk), .rst_n(aresetn),
        .cfg_i(pmp_cfg_flat), .addr_i(pmp_addr_flat),
        .acc_pa_i(ptw_pmp_req_addr), .acc_bytes_i(5'd4),
        .acc_priv_i(ptw_pmp_req_priv),
        //   ★ 4b-1b：按母代理裁决**照抄 2A**（`core_top.v:1855` + `:471-479`）：
        //     `pmp_acc_xlat(ptw_pmp_req_acc)` —— 取指遍历的 PTE 按 X、数据侧按 LOAD/STORE
        .acc_type_i(pmp_acc_xlat(ptw_pmp_req_acc)),
        .allow_o(ptw_pmp_ok), .fault_cause_o(), .hit_o(), .hit_idx_o(), .denied_by_full_o()
    );

    //==========================================================================
    // 3. front4_top（4 宽取指 + 预测器 + 检查点 + RAS）
    //==========================================================================
    front4_top #(.SPEC_GHR(0), .SEL_FORCE(0)) u_front (
        .clk(aclk), .rst_n(aresetn), .rst_hold(1'b0),
        .redirect_valid(redirect_valid), .redirect_pc(redirect_pc),
        .redirect_use_ckpt(redirect_use_ckpt), .redirect_ckpt(redirect_ckpt),
        //   ★★ 4b-2a-fix（K1 定案后修复）：**维护/扫掠期间冻结前端** ——
        //     实测根因：fence.i 扫掠期间本核只把送进 L1I 的 `cs_req` 门控为 0，却让前端
        //     继续跑 ⇒ 前端的"请求已发出"簿记与 L1I 实际受理不一致，扫掠结束后出现
        //     **重叠、乱序的取指块**（实测：[k1-blk] 依次呈现 0x…040、0x…050、**0x…044**、
        //     0x…054、0x…064 ⇒ 回退重叠并跳过一条维护指令所在块）⇒ PC 流丢/跳指令。
        //     修法：复用 `front4_top` **既有**的 `fe_stall`（`freeze_in(fe_stall|break_point)`，
        //     `front4_top.v:302`）在维护窗口/扫掠期间冻结前端（**无需改 front4**）：
        //       · fence.i 扫掠（256 拍）：冻结 + L1I 地址切扫掠 + cs_req=0
        //       · 单拍维护（sfence/cbo）的冻结窗口：冻结，窗口末尾再重定向
        //   ★★ K1' 修正（实测）：**只有 fence.i 扫掠需要冻结前端**（因为要借用 L1I 的
        //     index 输入做 256 拍全阵列失效）；sfence/cbo 只需后端冲刷 + L1D/TLB 维护，
        //     不冻结前端。原因：在前端有在途 push（`l1i_pend_q`/`l1i_own`）时冻结它，
        //     会留下"幻影 push_gives_next"——解冻后该块的 `can_grow=1` 但既无 parcel
        //     也无在途响应 ⇒ 块永远拼不齐 ⇒ 该指令永不提交（实测 p11 末尾 `j .`@0xa4 停摆：
        //     `[k1h] req_v=0 cs_req=0 pend=0 own=0 f4v=0 f4rsp=0 cangrow=1 fz=0`）。
        //   ★ 冻结只在**扫掠进行中**（`fencei_busy`）——等待态不冻前端（否则可能在
        //     "等前端排空"时把前端冻住 ⇒ 永不排空 ⇒ 死锁，实测 idx7 停摆）。
        .break_point(break_point), .fe_stall(fencei_busy),
        //   ★ K1'：整机冲刷拍清空检查点池（`be_trp_flush` = 陷阱/xRET/维护的冲刷）
        .ckpt_clear_all(be_trp_flush),
        .blk_valid(blk_valid), .blk_ready(blk_ready), .blk_mask(blk_mask),
        .blk_next_pc(blk_next_pc), .blk_taken(blk_taken),
        .lane_pc(lane_pc), .lane_pa(lane_pa), .lane_insn(lane_insn),
        .lane_len32(lane_len32), .lane_cls(lane_cls),
        .lane_pred_taken(lane_pred_taken), .lane_pred_selg(lane_pred_selg),
        .lane_pred_gdir(lane_pred_gdir), .lane_pred_ldir(lane_pred_ldir),
        .lane_pred_target(lane_pred_target),
        .lane_btb_hit(lane_btb_hit), .lane_btb_way(lane_btb_way),
        .lane_btb_cond(lane_btb_cond), .lane_btb_call(lane_btb_call),
        .lane_btb_ret(lane_btb_ret), .lane_btb_target(lane_btb_target),
        .lane_fault(lane_fault), .lane_fault_cause(lane_fault_cause),
        .lane_fault_tval(lane_fault_tval),
        .lane_ckpt(lane_ckpt), .lane_ckpt_valid(lane_ckpt_valid),
        .fe_fetch_fault(fe_fetch_fault), .fe_frozen(fe_frozen),
        .train_valid(train_valid), .train_pc(train_pc),
        .train_is_cond(train_is_cond), .train_taken(train_taken),
        .train_is_indirect(train_is_indirect), .train_is_call(train_is_call),
        .train_is_return(train_is_return), .train_target(train_target),
        .train_pred_taken(train_pred_taken), .train_pred_sel_global(train_pred_sel_global),
        .train_pred_gdir(train_pred_gdir), .train_pred_ldir(train_pred_ldir),
        .train_pred_target(train_pred_target), .train_pred_valid(train_pred_valid),
        .train_btb_hit(train_btb_hit), .train_btb_way(train_btb_way),
        .train_ready(train_ready),
        .ckpt_free_valid(ckpt_free_valid), .ckpt_free_id(ckpt_free_id),
        .ras_cmt_push_valid(ras_cmt_push), .ras_cmt_pop_valid(ras_cmt_pop),
        .d2_push_valid(d2_push_valid), .d2_push_addr(d2_push_addr),
        .d2_pop_valid(d2_pop_valid), .d2_pop_addr(d2_pop_addr),
        .ras_repair_valid(ras_repair_valid), .ras_repair_addr(ras_repair_addr),
        // ---- MMU：本段 Bare（占位）；PMP 占位（全 0 + M ⇒ 放行）----
        //   ★★ 4b-2b：**取指翻译只在 S/U 模式启用**（M 模式取指恒不翻译；
        //     MPRV 只影响取数侧 ⇒ 数据侧另由 `d_xlat_need_w` 判）
        .sv32_translate_en(sv32_en & f_xlate_on_w), .sv32_translate_done(sv32_done),
        .sv32_translate_fault(sv32_fault), .sv32_translate_paddr(sv32_paddr),
        .tr_req_valid(tr_req_valid), .tr_req_va(tr_req_va),
        .priv(`RV32GC_PRIV_M), .pmpcfg_i({N_PMP*8{1'b0}}), .pmpaddr_i({N_PMP*32{1'b0}}),
        // ---- L1I / XIP ----
        .l1i_req_valid(l1i_req_valid), .l1i_req_addr(l1i_req_addr),
        .l1i_req_line(l1i_req_line), .l1i_ready(l1i_ready_w),
        .l1i_rdata(l1i_rdata_w), .l1i_miss(l1i_miss_w), .l1i_uncached(l1i_uncached_w),
        .unc_req_valid(unc_req_valid), .unc_req_pa(unc_req_pa),
        .unc_rsp_valid(unc_rsp_valid), .unc_rsp_pa(unc_rsp_pa), .unc_rsp_data(unc_rsp_data),
        .fetch_pc_o(), .head_pc_o(), .epoch_o(), .ghr_o(),
        .bpu_br_total(), .bpu_br_mispred(), .bpu_dir_mispred(), .bpu_target_mispred(),
        .bpu_gshare_right(), .bpu_local_right(), .bpu_sel_global(), .bpu_sel_local(),
        .bpu_ras_push(), .bpu_ras_pop(), .bpu_ras_overflow(), .bpu_ras_repair(),
        .bpu_ckpt_full_stall(), .bpu_train_overflow(), .bpu_btb_alloc(),
        .cnt_grp(), .cnt_parcels(), .cnt_fault(), .cnt_restart(), .cnt_stall(),
        .cnt_req(), .cnt_redirect()
    );

    //==========================================================================
    // 4. L1I（2A 实例）+ XIP 直通 + 核内 AXI 读引擎
    //--------------------------------------------------------------------------
    //  取指侧口径与 2A 逐条一致：
    //   · cacheable ⇒ 查 L1I（miss ⇒ 行填充，8 beat）；
    //   · XIP 窗口（0x1C00_0000 / 0x1FE8_0000 别名）⇒ **不查 L1I**，单 beat 直读后
    //     保持到 PC 前移（`xip_hit_held` 地址比对，防陈旧响应）；
    //   · L1I 响应按"**请求归属校验**"消费（响应属于上一拍被接受的请求 ⇒
    //     重定向后必须丢弃，2A §5.3 的同款修复）。
    //==========================================================================
    wire        l1i_cs_ready, l1i_cs_uncached, l1i_cs_miss;
    wire [31:0] l1i_cs_rdata;
    wire        l1i_fill_req;
    wire [31:0] l1i_fill_paddr;
    wire [1:0]  l1i_fill_owner;
    wire [4:0]  l1i_fill_beats;
    wire        l1i_idle;
    //   L1I 回填握手（由 §5 的核内 AXI 引擎驱动；先声明后使用）
    wire        l1i_fill_accepted;
    wire        l1i_fill_valid;
    wire [31:0] l1i_fill_data;
    wire [4:0]  l1i_fill_word_idx;
    wire        l1i_fill_done;

    // D 侧（§4b）
    wire        d_ready_w, d_rsp_v_w;
    wire [31:0] d_rsp_d_w;
    wire [`BACK2_MEM_TAG_W-1:0] d_rsp_tag_w;
    wire        l1d_cs_ready, l1d_cs_miss, l1d_cs_stall, l1d_cs_wr_done, l1d_idle;
    wire [31:0] l1d_cs_rdata;
    wire        l1d_fill_req;
    wire [31:0] l1d_fill_paddr;
    wire [1:0]  l1d_fill_owner;
    wire [4:0]  l1d_fill_beats;
    wire        l1d_fill_accepted, l1d_fill_valid, l1d_fill_done;
    wire [31:0] l1d_fill_data;
    wire [4:0]  l1d_fill_word_idx;
    wire        l1d_wb_req, l1d_wb_accepted, l1d_wb_done, l1d_wb_ready;
    wire [31:0] l1d_wb_paddr, l1d_wb_data;
    wire [1:0]  l1d_wb_way, l1d_wb_owner;
    wire [4:0]  l1d_wb_beats, l1d_wb_word_idx;
    // uncached 直通（由 §5 引擎服务）
    wire        d_unc_done_w;
    wire [31:0] d_unc_rdata_w;
    // §5 引擎内部
    wire        axi_wdata_ready_w, axi_done_w;
    wire [2:0]  arlock_raw, awlock_raw;  // axi_master_ctrl 的 lock 为 3 bit（只用 [0]）

    //   ★ 4b-2a：fence.i 扫掠期间，L1I 的 index 输入切到扫掠地址、且**不接受取指请求**
    //     （照 2A `core_top.v:901` 的 `l1i_cs_vaddr` mux 与 `:926` 的 `~fencei_busy` 门控）
    wire        l1i_cs_req   = l1i_req_valid & ~fencei_busy;
    wire [31:0] l1i_cs_vaddr = fencei_busy ? {19'b0, fencei_idx_q, 5'b00000} : l1i_req_addr;

    // 响应归属：记录"最近一次被 L1I 接受（~ready）的请求地址"
    reg         l1i_pend_q;
    reg  [31:0] l1i_pa_q;
    wire        l1i_own = l1i_pend_q & (l1i_pa_q == l1i_cs_vaddr);
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            l1i_pend_q <= 1'b0; l1i_pa_q <= 32'h0;
        end else if (l1i_cs_req & ~l1i_cs_ready) begin
            l1i_pend_q <= 1'b1; l1i_pa_q <= l1i_cs_vaddr;
        end else if (l1i_cs_ready) begin
            l1i_pend_q <= 1'b0;
        end
    end
    assign l1i_ready_w = l1i_cs_ready & l1i_own;
    assign l1i_rdata_w = l1i_cs_rdata;
    assign l1i_miss_w  = l1i_cs_miss;
    assign l1i_uncached_w = l1i_cs_uncached;

    l1i #(.OWNER_I_FILL(2'd0)) u_l1i (
        .clk(aclk), .rst_n(aresetn),
        .cs_req(l1i_cs_req), .cs_paddr(l1i_req_addr), .cs_vaddr(l1i_cs_vaddr),
        .cs_ready(l1i_cs_ready), .cs_rdata(l1i_cs_rdata),
        .cs_uncached(l1i_cs_uncached), .cs_miss(l1i_cs_miss),
        .fill_req(l1i_fill_req), .fill_paddr(l1i_fill_paddr),
        .fill_owner(l1i_fill_owner), .fill_beats(l1i_fill_beats),
        .fill_accepted(l1i_fill_accepted),
        .fill_valid(l1i_fill_valid), .fill_data(l1i_fill_data),
        .fill_word_idx(l1i_fill_word_idx), .fill_done(l1i_fill_done),
        //   ★ 维护（fence.i / cbo.inval）：本段无 CSR 提交源 ⇒ 恒 0（第 4 段接）
        .inval_all(1'b0),
        .idle(l1i_idle)
    );

    // ---- XIP 直连取指：单 beat 读 + 保持到 PC 前移（2A §5.4 同法）----
    reg  [31:0] xip_word_pa_q, xip_word_data_q;
    reg         xip_word_vld_q, xip_req_pend_q;
    wire [31:0] xip_req_pa = unc_req_pa;
    wire        xip_req_go = unc_req_valid & ~xip_word_vld_q & ~xip_req_pend_q;
    wire        xip_hit_held = xip_word_vld_q & (unc_req_pa == xip_word_pa_q);
    assign unc_rsp_valid = xip_hit_held;
    assign unc_rsp_pa    = xip_word_pa_q;
    assign unc_rsp_data  = xip_word_data_q;

    //==========================================================================
    // 4b. 数据侧：LSU ↔ L1D（2A 实例）+ uncached 分流（★ 2B-4 第 3 段新增）
    //--------------------------------------------------------------------------
    //   LSU 的存储口是"单请求 + 带标签响应"（`lsq_simple` §3.3）：
    //    · load ：`mem_req_valid`(we=0) 握手 ⇒ 之后等 `mem_rsp_valid` 且 tag 匹配；
    //    · store：`mem_req_valid`(we=1) 握手即视为"已落地"（STQ 项当拍释放）
    //      ⇒ 适配器在**握手拍接管** store 的 {addr,data,strb}，此后自行完成
    //        （可能要先填充整行），LSU 不再过问。
    //   适配器状态机（组合判据 + 少量寄存器；与 2A M 级 LSU 的状态口径同构）：
    //    IDLE → (cacheable) 发 `l1d.cs_req` → HIT：读命中 `cs_ready` 次拍回数据、
    //            写命中 `cs_wr_done` 当拍完成；
    //          MISS：L1D 自行先写回脏受害者（`wb_req`）再请求填充（`fill_req`），
    //                两个握手都由 §5 的核内 AXI 引擎服务；期间 `cs_stall=1`
    //                ⇒ 适配器进入 RETRY，等 L1D 回到 IDLE 后**重发**同一次访问。
    //    IDLE → (uncached：XIP 窗口/MMIO，由 2A `mmio_route` 判定) 直接走 §5 引擎
    //             的单 beat 读/写（不查 L1D）—— 与 2A 的 MDTA 口径一致。
    //   ★ 本段 `cs_vaddr = cs_paddr`（Bare；`satp` 占位见 §2），第 4 段接 Sv32 后
    //     两者分离（tag/index 用 VA）。
    //==========================================================================
    //   （`lsu_req_*` 与适配器寄存器、`AD_*` 状态码已在 §2b 提前声明 —— TLB 口 1 要用）

    // ---- uncached 判定（2A `mmio_route` 只读复用；窗口口径不与 2A 分叉）----
    //   ★★ 4b-2b：判定输入是**物理地址**（`d_route_a_w`：翻译两级取各自 PA，其余取请求 VA）
    wire [2:0]  d_mr_route;
    wire        d_mr_no_axi, d_mr_clint_plic, d_mr_xip, d_mr_unc, d_mr_cac;
    mmio_route u_mmio_route_d (
        .pa_i(d_route_a_w), .route_o(d_mr_route), .no_axi_o(d_mr_no_axi),
        .clint_plic_o(d_mr_clint_plic), .xip_direct_o(d_mr_xip),
        .axi_uncached_o(d_mr_unc), .axi_cached_o(d_mr_cac),
        .clint_hit_o(), .plic_hit_o(), .periph_hit_o()
    );
    //   ★ 本段：CLINT/PLIC 未接（第 4 段）⇒ 落到该窗口的访问**不产生总线事务**、
    //     立即"完成"（读回 0 / 写丢弃），避免挂死；报告 §B4.3.3 登记为占位。
    wire        d_clint_plic = (d_mr_route != 3'd0) & d_mr_clint_plic;
    wire        d_unc_w      = (d_mr_route != 3'd0) & (d_mr_unc | d_mr_xip | d_mr_no_axi) &
                               ~d_clint_plic;


    //   ★★ 组合环警告（本段踩过）：**不得**把 `l1d.cs_stall` 用在"是否发请求"的组合式里
    //      —— `cs_stall = access | cs_miss | (ms_state!=IDLE) | maint`，而 `access = cs_req`
    //      ⇒ `cs_req ← cs_stall ← access = cs_req` 成环（iverilog 判环 ⇒ 全网 x ⇒ 一条不提交）。
    //      重试判据只用 **纯寄存器量**：`l1d.idle = (ms_state_q==MS_IDLE) & ~maint_q` ✓。
    //   （`AD_*` 状态码与适配器寄存器已在 §2b 提前声明）
    wire        l1d_busy_w = ~l1d_idle;              // FSM 非空闲（填充/写回/维护）
    //   ★★ 4b-2a：**维护操作/陷阱/xRET 的冲刷拍必须放弃在途的数据侧访问**。
    //     实测（p11 的 `sfence.vma` 后整机停摆）：sfence 触发 L1D `inval_all` 时适配器
    //     正停在 `AD_WAIT` 等一个不会到来的 `l1d_cs_ready` ⇒ `d_ready_w` 永久为 0
    //     ⇒ 之后所有访存全部挂住。2A 对应 `m_kill_fsm`（core_top.v:3749-3752 的
    //     "异常 / fence.i 同步：放弃在途访存"）⇒ 本核给适配器补同样的 kill。
    //   ★★ p12 收口修正：**kill 不能杀"已提交的 store 排空"**。
    //     本核的 store 是在**提交点**才被排空（CDQ）⇒ 一旦被适配器接管（`d_start`），
    //     它就是**已提交**的写，杀掉即丢数据（实测 p12：`cbo.clean/flush` 前后 4 次 load
    //     只有 1 次读到 0x55667788 —— 被杀的 store 从未落进 L1D/内存）。
    //     load 则相反：其请求者会被冲刷并重新执行 ⇒ kill 安全。
    //   ★★ p12 定案后的精确修法：kill **不得抢占"正在被接管的请求"**。
    //     根因链：CDQ（已提交 store 排空 FIFO）在 `flush_all` 下**不会**被清 ✓（设计正确），
    //     但当冲刷拍恰好与适配器"接管该 store"同拍时：LSQ 看到 `mem_req_valid & mem_req_ready`
    //     成立 ⇒ **CDQ 已弹出该项**，而适配器被 kill ⇒ 该笔已提交写**从未落到 L1D**
    //     ⇒ 后续同地址 load 读到内存旧值 0（实测 p12 idx10/12/13）。
    //     `d_we_q` 在接管当拍尚未锁存 ⇒ 仅 `& ~d_we_q` 挡不住 ⇒ 必须再排除接管拍（`~d_start`）。
    wire        d_kill_w = be_trp_flush & ~d_we_q & ~d_start;
    wire        d_idle     = (ad_st_q == AD_IDLE);
    //   ★★ p12 收口加固（实测波形抓出）：维护动作脉冲那一拍**不得再接管新请求**。
    //     若维护脉冲与"适配器接管一笔新访问"同拍，则该访问会在下一拍与 L1D 维护扫描
    //     的第 0 组写入重叠（tag 写口/dirty 清口同组竞争）⇒ 落进 L1D 的 store 可能被
    //     维护扫描的 dirty 清零吃掉（数据在、dirty 丢 ⇒ 后续逐出丢数据）。实测：三次
    //      维护脉冲里两次都有 `st=AD_REQ/csreq=1`（load）同拍 ⇒ 必须挡。
    assign      d_ready_w  = d_idle & ~l1d_busy_w & ~maint_act_q;
    wire        d_start    = d_ready_w & lsu_req_v;

    //--------------------------------------------------------------------------
    // 4b.1 ★★ 核内 CLINT（2B-4 第 4a 段第 4 步）：MMIO 截获，**绝不发 AXI**
    //--------------------------------------------------------------------------
    //  口径与 2A `core_top.v:2405-2425` 逐条对齐：
    //    · 窗口 = `RV32GC_CLINT_BASE`(0x1F00_0000) 起 64 KiB（`mmio_route` 判定），
    //      送入 CLINT 的 `req_addr` 是**窗口内偏移**（2A 同式：减基址）；
    //    · 单拍握手：请求在 `AD_WAIT` 拍呈现一次，CLINT 的 `resp_hit/resp_rdata`
    //      同拍组合给出 ⇒ 读响应与写副作用都在该拍完成（`clint` 内部为组合读 +
    //      时序寄存器，mtime 由 `aclk` 每拍 +1）；
    //    · 本段**只接 CLINT**；PLIC 窗口的访问仍走"立即完成、读回 0 / 写丢弃"的
    //      占位（`clint_hit=0` 时 `d_rsp_d_w=0`），不产生总线事务、不挂死
    //      ⇒ 报告 §B4.4.4 登记为 4b/后续（PLIC 需 MEIP 优先级仲裁，属中断控制器范畴）。
    //--------------------------------------------------------------------------
    wire [31:0] clint_req_addr  = d_a_q - `RV32GC_CLINT_BASE;
    wire        clint_req_vld   = (ad_st_q == AD_WAIT) & d_cp_q;
    wire        clint_req_wr    = d_we_q;
    wire [31:0] clint_req_wdata = d_d_q;
    wire [3:0]  clint_req_strb  = d_strb_q;
    wire [31:0] clint_rdata_w;
    wire        clint_hit_w;

    clint u_clint (
        .aclk      (aclk),
        .aresetn   (aresetn),
        .req_valid (clint_req_vld),
        .req_write (clint_req_wr),
        .req_addr  (clint_req_addr),
        .req_wdata (clint_req_wdata),
        .req_wstrb (clint_req_strb),
        .resp_rdata(clint_rdata_w),
        .resp_hit  (clint_hit_w),
        .msip_o    (clint_msip_w),
        .mtip_o    (clint_mtip_w)
    );

    // 请求发射：AD_REQ 拍恰好一次（重试时等 L1D 回到 IDLE）
    wire        l1d_cs_req_w = (ad_st_q == AD_REQ);
    wire [31:0] d_rdata_w    = d_unc_q ? d_unc_rdata_w : l1d_cs_rdata;
    //   ★★ 4b-2b：**数据侧翻译故障**（TLB 权限错 / PTW 故障）⇒ 以"正常响应 + err=1"
    //     回一笔（tag 仍是该 load 的标签）⇒ LSQ 标 done+异常 ⇒ ROB 精确抛页错误。
    //     · 只在 load 上精确（store 的翻译发生在提交后排空 ⇒ 见 §B4.19 登记）
    wire        d_tlb_fault_cyc_w = (ad_st_q == AD_XLATE) & d_tlb_perm_fault;
    wire        d_ptw_fault_cyc_w = (ad_st_q == AD_TR) & ptw_req_done &
                                    ~ptw_owner_fetch_w & ptw_fault;
    wire        d_rsp_err_w   = ~d_we_q & (d_tlb_fault_cyc_w | d_ptw_fault_cyc_w);
    assign      d_rsp_v_w    = d_rsp_err_w |
                               ((ad_st_q == AD_WAIT) & ~d_we_q &
                                (d_cp_q ? 1'b1 :
                                 d_unc_q ? d_unc_done_w : l1d_cs_ready));
    //   CLINT 命中取 CLINT 读数据；窗口内未接部分（PLIC）仍回 0（占位，fail-safe）
    assign      d_rsp_d_w    = d_cp_q ? (clint_hit_w ? clint_rdata_w : 32'h0) : d_rdata_w;
    assign      d_rsp_tag_w  = d_tag_q;

    l1d #(.OWNER_D_FILL(2'd1), .OWNER_WRBACK(2'd2)) u_l1d (
        .clk(aclk), .rst_n(aresetn),
        .cs_req(l1d_cs_req_w), .cs_we(d_we_q), .cs_wstrb(d_strb_q),
        //   ★★ 4b-2b：L1D 是 **VIPT**（`cs_vaddr` 同时出 index 与 tag，见 l1d.v:112-113/480-481）
        //     ⇒ Sv32 下必须把**物理 tag** 送进去（否则同一 VA 重映射后命中旧行 ⇒ 陈旧数据）：
        //       tag 段用 PA[31:12]（页对齐标签）、index 段用 VA[11:0]（本 L1D 几何：
        //       128 组 × 32 B 行 ⇒ index = VA[11:5]、tag = addr[31:12]）。
        //     Bare（VA==PA）时该复合式与 `d_a_q` 逐位相同 ⇒ 既有行为不变。
        .cs_paddr(d_a_q), .cs_vaddr({d_a_q[31:12], d_va_q[11:0]}), .cs_wdata(d_d_q),
        .cs_ready(l1d_cs_ready), .cs_rdata(l1d_cs_rdata),
        .cs_miss(l1d_cs_miss), .cs_stall(l1d_cs_stall), .cs_wr_done(l1d_cs_wr_done),
        .fill_req(l1d_fill_req), .fill_paddr(l1d_fill_paddr), .fill_owner(l1d_fill_owner),
        .fill_beats(l1d_fill_beats), .fill_accepted(l1d_fill_accepted),
        .fill_valid(l1d_fill_valid), .fill_data(l1d_fill_data),
        .fill_word_idx(l1d_fill_word_idx), .fill_done(l1d_fill_done),
        .wb_req(l1d_wb_req), .wb_paddr(l1d_wb_paddr), .wb_way(l1d_wb_way),
        .wb_owner(l1d_wb_owner), .wb_beats(l1d_wb_beats), .wb_accepted(l1d_wb_accepted),
        .wb_word_idx(l1d_wb_word_idx), .wb_data(l1d_wb_data), .wb_done(l1d_wb_done),
        .wb_ready(l1d_wb_ready),
        //   ★ 占位：L1D 维护（fence.i / cbo.inval / clean）本段无 CSR 提交源 ⇒ 恒 0
        .inval_all(maint_l1d_inval_w), .clean_all(maint_l1d_clean_w), .idle(l1d_idle)
    );

    // ---- 适配器时序 ----
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            ad_st_q <= AD_IDLE;
            d_we_q <= 1'b0; d_unc_q <= 1'b0; d_cp_q <= 1'b0;
            d_a_q <= 32'h0; d_va_q <= 32'h0; d_d_q <= 32'h0; d_strb_q <= 4'h0;
            d_tag_q <= {`BACK2_MEM_TAG_W{1'b0}};
            m_tr_src_q <= 1'b1;             // 复位后 PTW 归取指侧（与旧行为一致）
        end else begin
            //   ★ 4b-2b：PTW 归属 —— 请求被**接受**的那一拍记录归属（2A `m_tr_src_q` 同法）
            if (ptw_req_v_w & ptw_free_w) m_tr_src_q <= d_ptw_want_w ? 1'b0 : 1'b1;
            //   ★ 4b-2a：维护/陷阱/xRET 冲刷 ⇒ 放弃在途访问（看上面 `d_kill_w` 的说明）
            if (d_kill_w) begin
                ad_st_q <= AD_IDLE;
            end else case (ad_st_q)
                AD_IDLE: begin
                    if (d_start) begin
                        d_we_q   <= lsu_req_we;
                        d_d_q    <= lsu_req_d;
                        d_strb_q <= lsu_req_strb;
                        d_tag_q  <= lsu_req_tag;
                        if (d_xlat_need_w) begin
                            //   ★ 4b-2b：先做 VA→PA 翻译（`AD_XLATE` 拍 TLB 组合查询）
                            d_va_q  <= lsu_req_a;
                            ad_st_q <= AD_XLATE;
                        end else begin
                            d_a_q   <= lsu_req_a;
                            d_va_q  <= lsu_req_a;   // Bare：VA==PA（cs_vaddr 的 index 段用）
                            d_unc_q <= d_unc_w;
                            d_cp_q  <= d_clint_plic;
                            ad_st_q <= (d_unc_w | d_clint_plic) ? AD_WAIT : AD_REQ;
                        end
                    end
                end
                AD_XLATE: begin
                    //   TLB 口 1 当拍出结果（纯组合）
                    if (d_tlb_hit) begin
                        d_a_q   <= d_tlb_pa;
                        d_unc_q <= d_unc_w;             // 路由按 **PA** 重算
                        d_cp_q  <= d_clint_plic;
                        ad_st_q <= (d_unc_w | d_clint_plic) ? AD_WAIT : AD_REQ;
                    end else if (d_tlb_perm_fault) begin
                        ad_st_q <= AD_IDLE;             // 本拍已回"带错响应"（见 `d_rsp_err_w`）
                    end else begin
                        ad_st_q <= AD_TR;               // 缺失 ⇒ 向 PTW 发请求
                    end
                end
                AD_TR: begin
                    //   等本笔遍历结束（归属必须是数据侧 —— 取指侧的 done 不算）
                    if (ptw_req_done & ~ptw_owner_fetch_w) begin
                        if (ptw_fault) begin
                            ad_st_q <= AD_IDLE;         // 本拍已回"带错响应"
                        end else begin
                            d_a_q   <= ptw_pa_out;
                            d_unc_q <= d_unc_w;
                            d_cp_q  <= d_clint_plic;
                            ad_st_q <= (d_unc_w | d_clint_plic) ? AD_WAIT : AD_REQ;
                        end
                    end
                end
                AD_REQ: begin
                    // 请求已呈现一拍：写命中当拍完成（st_hit 组合），否则进 AD_WAIT
                    ad_st_q <= l1d_cs_wr_done ? AD_IDLE : AD_WAIT;
                end
                AD_WAIT: begin
                    if (d_cp_q)                                          ad_st_q <= AD_IDLE;
                    else if (d_unc_q) begin if (d_unc_done_w)            ad_st_q <= AD_IDLE; end
                    else if (d_we_q ? l1d_cs_wr_done : l1d_cs_ready)     ad_st_q <= AD_IDLE;
                    else if (l1d_cs_miss)                                ad_st_q <= AD_RETRY;
                end
                AD_RETRY: begin
                    // 缺失/写回由 L1D 自理（请求已由 §5 引擎服务）；回到 IDLE 后重发访问
                    if (l1d_idle) ad_st_q <= AD_REQ;
                end
                default: ad_st_q <= AD_IDLE;
            endcase
        end
    end

    //==========================================================================
    // 5. 核内 AXI 引擎（单笔在途；I/D 共用；★ 第 3 段扩为"读 + 写"）
    //--------------------------------------------------------------------------
    //  ★ 只写"核内请求粘合"：AXI 五通道握手全部在 2A `axi_master_ctrl` 内
    //    （红线：不重写 AXI 协议逻辑）。单笔在途 + 归属寄存器（`i_own_q`）。
    //  请求源与优先序（**逐条对齐 2A core_top §11.1**）：
    //    ① L1D 脏行写回 `l1d_wb_req`（写突发，8 beat）
    //    ② L1D 行填充   `l1d_fill_req`（读突发，8 beat）
    //    ③ uncached 数据 `d_unc_q`（单 beat，读/写；含 XIP 窗口数据访问）
    //       —— 2A 把 PTE 取也归在 M 级 MDTA 一档，本引擎把 PTE 读放在同一档
    //    ④ PTE 读 `ptw_pte_req_valid`（单 beat）
    //    ⑤ XIP 取指字 `xip_req_go`（单 beat）
    //    ⑥ L1I 行填充 `l1i_fill_req`（读突发，8 beat）
    //  读拍按 `i_own_q` 分发；写拍的 W 数据按来源取（L1D 写回取 `wb_data`，
    //  uncached store 取接管时锁存的数据/字节使能）。
    //==========================================================================
    localparam [2:0] IOWN_WRBK = 3'd0, IOWN_DFIL = 3'd1, IOWN_DUNC = 3'd2,
                     IOWN_PTE  = 3'd3, IOWN_XIPF = 3'd4, IOWN_IFIL = 3'd5;
    localparam [1:0] IST_IDLE = 2'd0, IST_RD = 2'd1, IST_WR = 2'd2, IST_WB = 2'd3;

    reg [1:0]  ist_q;
    reg [2:0]  i_own_q;
    reg [4:0]  i_cnt_q;          // 已处理 beat 数（从 0 起）
    reg [4:0]  i_last_q;         // 末 beat 序号（= beat 数 - 1）
    reg [1:0]  i_wdly_q;         // 写回数据建立等待（行缓冲读延迟；2 拍保险）

    wire        i_free   = (ist_q == IST_IDLE);
    wire        d_unc_rd = (ad_st_q == AD_WAIT) & d_unc_q & ~d_we_q;
    wire        d_unc_wr = (ad_st_q == AD_WAIT) & d_unc_q &  d_we_q;

    // ---- 仲裁（2A §11.1 优先序）----
    wire        g_wrbk = i_free &  l1d_wb_req;
    wire        g_dfil = i_free & ~l1d_wb_req &  l1d_fill_req;
    wire        g_dunc = i_free & ~l1d_wb_req & ~l1d_fill_req & (d_unc_rd | d_unc_wr);
    wire        g_pte  = i_free & ~l1d_wb_req & ~l1d_fill_req & ~(d_unc_rd | d_unc_wr) &
                         ptw_pte_req_valid;
    wire        g_xipf = i_free & ~l1d_wb_req & ~l1d_fill_req & ~(d_unc_rd | d_unc_wr) &
                         ~ptw_pte_req_valid & xip_req_go;
    wire        g_ifil = i_free & ~l1d_wb_req & ~l1d_fill_req & ~(d_unc_rd | d_unc_wr) &
                         ~ptw_pte_req_valid & ~xip_req_go & l1i_fill_req;

    wire        i_req_v   = g_wrbk | g_dfil | g_dunc | g_pte | g_xipf | g_ifil;
    wire        i_req_wr  = g_wrbk | d_unc_wr;
    wire [2:0]  i_own_new = g_wrbk ? IOWN_WRBK : g_dfil ? IOWN_DFIL : g_dunc ? IOWN_DUNC :
                            g_pte  ? IOWN_PTE  : g_xipf ? IOWN_XIPF : IOWN_IFIL;
    wire [31:0] i_addr_new= g_wrbk ? l1d_wb_paddr : g_dfil ? l1d_fill_paddr :
                            g_dunc ? d_a_q : g_pte ? ptw_pte_req_pa :
                            g_xipf ? xip_req_pa : l1i_fill_paddr;
    wire [4:0]  i_beats_new = g_wrbk ? (l1d_wb_beats + 5'd1) :
                              g_dfil ? (l1d_fill_beats + 5'd1) :
                              g_ifil ? (l1i_fill_beats + 5'd1) : 5'd1;
    wire [3:0]  i_cache_new = (g_wrbk | g_dfil | g_ifil) ? 4'b1111 : 4'b0000;
    wire [3:0]  i_strb_new  = g_dunc ? d_strb_q : 4'hF;

    wire        axi_req_ready_w;
    wire        i_fire = i_req_v & axi_req_ready_w;

    // 归属/接受握手（同拍）
    assign l1d_fill_accepted = i_fire & (i_own_new == IOWN_DFIL);
    assign l1i_fill_accepted = i_fire & (i_own_new == IOWN_IFIL);
    assign l1d_wb_accepted   = i_fire & (i_own_new == IOWN_WRBK);
    assign pte_req_ready_w   = i_fire & (i_own_new == IOWN_PTE);

    // R 拍：`r_fire_w` = R 握手拍
    wire        r_fire_w = rvalid & rready;

    // W 拍数据源
    wire        w_beat_now  = (ist_q == IST_WR) & (i_wdly_q == 2'd0);
    wire        w_is_wrbk   = (i_own_q == IOWN_WRBK);
    wire [31:0] w_data_sel  = w_is_wrbk ? l1d_wb_data : d_d_q;
    wire        w_ready_w   = axi_wdata_ready_w;
    wire        w_fire      = w_beat_now & w_ready_w;

    // ---- 时序 ----
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            ist_q <= IST_IDLE; i_own_q <= IOWN_XIPF; i_cnt_q <= 5'd0; i_last_q <= 5'd0;
            i_wdly_q <= 2'd0;
        end else begin
            case (ist_q)
                IST_IDLE: begin
                    if (i_fire) begin
                        i_own_q  <= i_own_new;
                        i_cnt_q  <= 5'd0;
                        i_last_q <= i_beats_new - 5'd1;
                        ist_q    <= i_req_wr ? IST_WR : IST_RD;
                        i_wdly_q <= 2'd2;      // 写回数据建立（行缓冲读延迟）
                    end
                end
                IST_RD: begin
                    if (r_fire_w) begin
                        if (i_cnt_q == i_last_q) ist_q <= IST_IDLE;
                        else                     i_cnt_q <= i_cnt_q + 5'd1;
                    end
                end
                IST_WR: begin
                    if (i_wdly_q != 2'd0) i_wdly_q <= i_wdly_q - 2'd1;
                    else if (w_fire) begin
                        if (i_cnt_q == i_last_q) begin
                            ist_q   <= IST_WB;
                            i_wdly_q<= 2'd2;
                        end else begin
                            i_cnt_q <= i_cnt_q + 5'd1;
                            i_wdly_q<= 2'd2;
                        end
                    end
                end
                IST_WB: begin
                    // 等 B 响应 / 控制器 done（写事务收尾）
                    if (axi_done_w) ist_q <= IST_IDLE;
                end
                default: ist_q <= IST_IDLE;
            endcase
        end
    end

    // ---- 读拍分发 ----
    assign l1d_fill_valid    = r_fire_w & (i_own_q == IOWN_DFIL);
    assign l1d_fill_data     = rdata;
    assign l1d_fill_word_idx = i_cnt_q;
    assign l1d_fill_done     = r_fire_w & (i_own_q == IOWN_DFIL) & (i_cnt_q == i_last_q);
    assign l1i_fill_valid    = r_fire_w & (i_own_q == IOWN_IFIL);
    assign l1i_fill_data     = rdata;
    assign l1i_fill_word_idx = i_cnt_q;
    assign l1i_fill_done     = r_fire_w & (i_own_q == IOWN_IFIL) & (i_cnt_q == i_last_q);
    assign pte_resp_valid_w  = r_fire_w & (i_own_q == IOWN_PTE);
    assign pte_resp_data_w   = rdata;

    // ---- 写拍分发（L1D 写回：逐字取行缓冲；uncached store：单 beat）----
    assign l1d_wb_word_idx = i_cnt_q;
    assign l1d_wb_done     = (ist_q == IST_WR) & w_is_wrbk & w_fire & (i_cnt_q == i_last_q);

    // XIP 字锁存 + 在途跟踪
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            xip_word_pa_q <= 32'h0; xip_word_data_q <= 32'h0000_0013;
            xip_word_vld_q <= 1'b0; xip_req_pend_q <= 1'b0;
        end else begin
            if (i_fire & (i_own_new == IOWN_XIPF)) begin
                xip_req_pend_q <= 1'b1;
                xip_word_vld_q <= 1'b0;
                xip_word_pa_q  <= xip_req_pa;
            end
            if (r_fire_w & (i_own_q == IOWN_XIPF) & (i_cnt_q == i_last_q)) begin
                xip_req_pend_q  <= 1'b0;
                xip_word_vld_q  <= 1'b1;
                xip_word_data_q <= rdata;
            end
            if (xip_word_vld_q & ~xip_hit_held) xip_word_vld_q <= 1'b0;
        end
    end

    // uncached 数据完成/数据（读：R 拍锁存；写：最后一个 W 拍 + B）
    reg        d_unc_done_r;
    reg [31:0] d_unc_rdata_r;
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            d_unc_done_r <= 1'b0; d_unc_rdata_r <= 32'h0;
        end else begin
            d_unc_done_r <= 1'b0;
            if (r_fire_w & (i_own_q == IOWN_DUNC)) begin
                d_unc_rdata_r <= rdata;
                if (i_cnt_q == i_last_q) d_unc_done_r <= 1'b1;
            end
            if (ist_q == IST_WB) d_unc_done_r <= axi_done_w;   // 写事务收尾
        end
    end
    assign d_unc_done_w  = d_unc_done_r;
    assign d_unc_rdata_w = d_unc_rdata_r;

    axi_master_ctrl #(
        .ADDR_W(32), .DATA_W(32), .STRB_W(4), .ID_W(4), .LEN_W(4),
        .SIZE_W(3), .BURST_W(2), .CACHE_W(4), .PROT_W(3), .OWNER_W(3),
        .USE_REQ_ATTRS(1)
    ) u_axi (
        .clk(aclk), .rst_n(aresetn),
        .req_valid(i_req_v),
        .req_is_write(i_req_wr),
        .req_owner(3'd0),
        .req_addr(i_addr_new),
        .req_len(i_beats_new[3:0] - 4'd1),
        .req_beats(i_beats_new),
        .req_split(1'b0),                    // 32 B 行/单字均不跨 4 K
        .req_beats_1(i_beats_new),
        .req_beats_2(5'd0),
        .req_id(AXI_ID_IFILL),
        .req_ready(axi_req_ready_w),
        .req_cache(i_cache_new),
        .req_strb(i_strb_new),
        .wdata_valid(w_beat_now), .wdata_data(w_data_sel), .wdata_ready(axi_wdata_ready_w),
        .rdata_valid(), .rdata_data(), .rdata_hold(), .rdata_id(), .rdata_last(),
        .rdata_ready(1'b1),
        .done(axi_done_w), .done_owner(), .done_addr(), .resp_error(), .resp_code(),
        .m_awid(awid), .m_awaddr(awaddr), .m_awlen(awlen), .m_awsize(awsize),
        .m_awburst(awburst), .m_awlock(awlock_raw), .m_awcache(awcache), .m_awprot(awprot),
        .m_awvalid(awvalid), .m_awready(awready),
        .m_wdata(wdata), .m_wstrb(wstrb), .m_wlast(wlast),
        .m_wvalid(wvalid), .m_wready(wready),
        .m_bid(bid), .m_bresp(bresp), .m_bvalid(bvalid), .m_bready(bready),
        .m_arid(arid), .m_araddr(araddr), .m_arlen(arlen), .m_arsize(arsize),
        .m_arburst(arburst), .m_arlock(arlock_raw), .m_arcache(arcache), .m_arprot(arprot),
        .m_arvalid(arvalid), .m_arready(arready),
        .m_rid(rid), .m_rdata(rdata), .m_rresp(rresp), .m_rlast(rlast),
        .m_rvalid(rvalid), .m_rready(rready),
        .busy(), .owner()
    );
    //   `arlock/awlock` 只驱动 [0]（契约注释口径）
    assign arlock = {1'b0, arlock_raw[0]};
    assign awlock = {1'b0, awlock_raw[0]};

    //==========================================================================
    // 6. backend_top（ROB 128 + 重命名 + 发射队列 + PRF + LSQ + 过渡 CSR 栈）
    //==========================================================================
    backend_top u_back (
        .clk(aclk), .rst_n(aresetn),
        .blk_valid_i(blk_valid), .blk_ready_o(blk_ready), .blk_mask_i(blk_mask),
        .blk_next_pc_i(blk_next_pc), .blk_taken_i(blk_taken),
        .lane_pc_i(lane_pc), .lane_pa_i(lane_pa), .lane_insn_i(lane_insn),
        .lane_len32_i(lane_len32), .lane_cls_i(lane_cls),
        .lane_pred_taken_i(lane_pred_taken), .lane_pred_selg_i(lane_pred_selg),
        .lane_pred_gdir_i(lane_pred_gdir), .lane_pred_ldir_i(lane_pred_ldir),
        .lane_pred_target_i(lane_pred_target),
        .lane_btb_hit_i(lane_btb_hit), .lane_btb_way_i(lane_btb_way),
        .lane_btb_cond_i(lane_btb_cond), .lane_btb_call_i(lane_btb_call),
        .lane_btb_ret_i(lane_btb_ret), .lane_btb_target_i(lane_btb_target),
        .lane_fault_i(lane_fault), .lane_fault_cause_i(lane_fault_cause),
        .lane_fault_tval_i(lane_fault_tval),
        .lane_ckpt_i(lane_ckpt), .lane_ckpt_valid_i(lane_ckpt_valid),
        .fe_fetch_fault_i(fe_fetch_fault),
        .redirect_valid_o(redirect_valid), .redirect_pc_o(redirect_pc),
        .redirect_use_ckpt_o(redirect_use_ckpt), .redirect_ckpt_o(redirect_ckpt),
        .train_valid_o(train_valid), .train_pc_o(train_pc),
        .train_is_cond_o(train_is_cond), .train_taken_o(train_taken),
        .train_is_indirect_o(train_is_indirect), .train_is_call_o(train_is_call),
        .train_is_return_o(train_is_return), .train_target_o(train_target),
        .train_pred_taken_o(train_pred_taken), .train_pred_sel_global_o(train_pred_sel_global),
        .train_pred_gdir_o(train_pred_gdir), .train_pred_ldir_o(train_pred_ldir),
        .train_pred_target_o(train_pred_target), .train_pred_valid_o(train_pred_valid),
        .train_btb_hit_o(train_btb_hit), .train_btb_way_o(train_btb_way),
        .train_ready_i(train_ready),
        .ckpt_free_valid_o(ckpt_free_valid), .ckpt_free_id_o(ckpt_free_id),
        .ras_cmt_push_valid_o(ras_cmt_push), .ras_cmt_pop_valid_o(ras_cmt_pop),
        .d2_push_valid_o(d2_push_valid), .d2_push_addr_o(d2_push_addr),
        .d2_pop_valid_o(d2_pop_valid), .d2_pop_addr_o(d2_pop_addr),
        // ---- ★ 占位：数据侧访存口直连 TB 内存模型（第 3 段换 L1D/AXI）----
        .mem_req_valid_o(lsu_req_v), .mem_req_wen_o(lsu_req_we),
        .mem_req_addr_o(lsu_req_a), .mem_req_wdata_o(lsu_req_d),
        .mem_req_wstrb_o(lsu_req_strb), .mem_req_tag_o(lsu_req_tag),
        .mem_req_ready_i(d_ready_w),
        .mem_rsp_valid_i(d_rsp_v_w), .mem_rsp_rdata_i(d_rsp_d_w),
        .mem_rsp_tag_i(d_rsp_tag_w),
        .commit_valid_o(commit_valid), .commit_pc_o(commit_pc),
        .commit_arch_rd_o(commit_arch_rd), .commit_arch_rd_wdata_o(commit_arch_rd_wdata),
        .commit_arch_we_o(commit_arch_we),
        .trap_valid_o(trap_valid_w), .trap_pc_o(trap_pc_w),
        .trap_cause_o(trap_cause_w), .trap_tval_o(trap_tval_w),
        //   ★★ 2B-4 第 4a 段：特权/陷阱/中断路径（顶层 trap FSM ↔ 后端）
        .mem_rsp_err_i(d_rsp_err_w),
        .trp_flush_v_i(be_trp_flush), .trp_redirect_v_i(be_trp_redirect_v),
        .trp_redirect_pc_i(be_trp_redirect_pc), .trp_halt_o(trp_halt_w),
        .xret_cmt_o(xret_cmt_w),
        //   ★ 4b-1a：CSR 文件接口（本体在下方 §6c 例化）
        .csr_raddr_o(csr_raddr_w), .csr_rdata_i(csr_rdata_w),
        .csr_frm_i(csr_frm_w), .csr_fflags_i(csr_ff_w),
        .csr_we_o(csr_we_w), .csr_waddr_o(csr_waddr_w), .csr_wdata_o(csr_wdata_w),
        .xret_kind_o(xret_kind_w),
        .cbo_perm_i(cbo_perm_w), .maint_kind_o(maint_kind_w), .maint_cmt_o(maint_cmt_w),
        .maint_pc_o(maint_pc_w), .maint_rdy_i(l1d_idle),
        .cnt_commit_o(cnt_commit), .cnt_squash_o(cnt_squash),
        .cnt_commit4_o(), .cnt_issue_o(),
        .dbg_rob_cnt_o(dbg_rob_cnt_w), .dbg_iq_cnt_o(), .dbg_stq_cnt_o(dbg_stq_cnt_w),
        .cdq_empty_o(cdq_empty_w)
    );

    //==========================================================================
    // 6c. ★★ CSR 文件（2B-4 第 4b-1a 段：从 `backend_top` 搬到本层）
    //--------------------------------------------------------------------------
    //  本阶段**行为等价**：仍是 4a 的 `b2_csr` 过渡栈（4b-1b 才换 2A 的
    //  `csr_file`+`priv_ctrl`+`trap_ctrl`），只是寄存器本体与写口在本层。
    //  读写口语义与 4a 完全一致：
    //    · 读口组合（执行拍；CSR 指令只在 ROB 头发射 ⇒ 读到的是已提交状态）
    //    · 写口在提交点（`csr_we_w/csr_waddr_w/csr_wdata_w` 由后端提交级合成）
    //    · 陷阱进入/退出由后端的 `csr_trp_*` 事件驱动（4a 口径）
    //==========================================================================
    //   ★★ 4b-1b：CSR 全集 + 特权状态 + 陷阱决策（2A 模块只读例化，接法照 `rtl/top/core_top.v`）
    csr_file u_csr_file (
        .clk(aclk), .rst_n(aresetn),
        .raddr(csr_raddr_w), .rdata(csr_rdata_w), .wen(csr_we_w),
        .waddr(csr_waddr_w), .wdata(csr_wdata_w), .w_illegal(1'b0),
        .rdata_w(), .byp_wdata(32'h0), .byp_rdata(),
        .priv(csr_priv_2), .chk_addr(12'h0), .chk_illegal(), .chk_ro_write(),
        .mstatus_o(csr_mstatus_raw), .mstatus_set(mstatus_set), .mstatus_clr(mstatus_clr),
        .trap_we(tc_trap_we), .trap_epc_i(tc_trap_epc_i), .trap_cause_i(tc_trap_cause_i),
        .trap_tval_i(tc_trap_tval_i), .trap_data_i(32'h0),
        .irq_msip(clint_msip_w), .irq_mtip(clint_mtip_w), .irq_meip(1'b0),
        .irq_stip(1'b0), .irq_seip(1'b0),
        .cycle_i(cycle_cnt), .instret_i(instret_cnt),
        .pmp_cfg_o(pmp_cfg_flat), .pmp_addr_o(pmp_addr_flat), .satp_o(csr_satp_o),
        .menvcfg_o(csr_menvcfg_w), .senvcfg_o(), .mcounteren_o(), .scounteren_o(),
        .mtvec_o(csr_mtvec_o), .stvec_o(csr_stvec_o),
        .medeleg_o(csr_medeleg_o), .mideleg_o(csr_mideleg_o),
        .mie_o(csr_mie_o), .mip_o(csr_mip_o), .mepc_o(csr_mepc_o), .sepc_o(csr_sepc_o)
    );

    priv_ctrl u_priv_ctrl (
        .clk(aclk), .rst_n(aresetn),
        .trap_valid(tc_trap_valid), .trap_target(tc_trap_target),
        .xret_valid(xret_cmt_w), .xret_kind(xret_kind_w),
        .mstatus_i(csr_mstatus_raw),
        .csr_wen(csr_we_w), .csr_waddr(csr_waddr_w), .csr_wdata(csr_wdata_w),
        .mstatus_set(mstatus_set), .mstatus_clr(mstatus_clr),
        .priv_o(csr_priv_2), .eff_priv_o(csr_eff_priv),
        .mprv_o(), .sum_o(), .mxr_o(), .mpp_o(),
        .tvm_o(), .tw_o(), .tsr_o(), .fetch_priv_is_m_o(),
        .flush_req(), .priv_next_o()
    );

    //   ★ 适配层（"ROB 头当 W 拍"）：
    //     · commit_valid/commit_pc = ROB 头（最老未提交指令）
    //     · 裁决②：commit_pc_next **= commit_pc** —— 本核取点在头部**提交前**，
    //       "下一条未执行指令"就是头部本身（2A 是 W 已提交，故其 pc_next = pc+4）
    //     · exc_valid 与 commit_valid 相与（2A `core_top.v:2571-2579` 的教训：裸 exc_valid
    //       会在槽被清空后逐拍重复取同一次陷阱）
    //     · exc_tval 按裁决① 适配（ecall→0 / 断点→PC / 其余→载荷 TVAL）
    //     · mie 按 ROB 非空掩码 ⇒ ROB 空时不取中断（无"下一条未执行指令"）
    trap_ctrl u_trap_ctrl (
        .commit_valid (rob_any_w),
        .commit_pc    (trap_pc_w),
        .commit_pc_next(trap_pc_w),
        .commit_insn  (trap_tval_w),
        .exc_valid    (trap_valid_w & rob_any_w),
        .exc_cause    ({1'b0, trap_cause_w}),
        .exc_tval     (exc_tval_adapt_w),
        .exc_is_fetch (1'b0),          // 裁决④：本核载荷暂无取指异常标记（待办）
        .priv         (csr_priv_2),
        .medeleg      (csr_medeleg_o),
        .mideleg      (csr_mideleg_o),
        .mip          (csr_mip_o),
        .mie          (csr_mie_o & {32{rob_any_w}}),
        .mstatus_i    (csr_mstatus_raw),
        .mtvec        (csr_mtvec_o),
        .stvec        (csr_stvec_o),
        .trap_valid   (tc_trap_valid),
        .trap_is_int  (tc_trap_is_int),
        .trap_target  (tc_trap_target),
        .trap_cause   (tc_trap_cause),
        .trap_tval    (tc_trap_tval),
        .trap_epc     (tc_trap_epc),
        .trap_pc      (tc_trap_pc),
        .trap_we      (tc_trap_we),
        .trap_epc_i   (tc_trap_epc_i),
        .trap_cause_i (tc_trap_cause_i),
        .trap_tval_i  (tc_trap_tval_i),
        .trap_data_i  (),              // trap_ctrl 的输出（csr_file 侧那份按 2A 接 0）
        .trap_wr_m_epc(), .trap_wr_m_cause(), .trap_wr_m_tval(),
        .trap_wr_s_epc(), .trap_wr_s_cause(), .trap_wr_s_tval(),
        .redirect_pc  (tc_redirect_pc)
    );
    //   ★ 4b-1c：`irq_mti_w` 保留为**观测口**（= 本拍真的在交付中断）；判定本体在 `trap_ctrl`
    assign irq_mti_w = tc_trap_valid & tc_trap_is_int;

    //   ★ mcycle/minstret（Zicntr；4b-1c 的读回单调性判据用）
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            cycle_cnt   <= 64'h0;
            instret_cnt <= 64'h0;
        end else begin
            cycle_cnt   <= cycle_cnt + 64'd1;
            instret_cnt <= instret_cnt + {61'b0, cmt_num_w};
        end
    end

    //==========================================================================
    // 6b. ★★ 特权/陷阱/中断 FSM（2B-4 第 4a 段）
    //--------------------------------------------------------------------------
    //  口径（与 2A `trap_ctrl` 同精神，简化为"单拍组合交付"）：
    //    · 交付点 = **ROB 头部**（`trap_valid_w`：最老指令已就绪且带异常码）
    //      ⇒ 精确异常：更老的指令都已提交，更年轻的全部冲刷（后端 `flush_all`）。
    //    · 三种事件共用一条"冲刷 + 重定向"通道，优先级
    //        异常（头部精确） > xRET（提交点特权恢复） > MTI 中断（提交组边界采样）
    //    · 重定向目标：
    //        异常/中断 ⇒ mtvec（MODE=0 直接；MODE=1 向量 = base + 4×cause）
    //        xRET      ⇒ mepc（mret/sret 语义；本段无 S 模式 ⇒ 只可能 mret）
    //    · 全程**无状态**（不需要 pending 寄存器）：`trp_flush_v_i` 与
    //      `trp_redirect_v_i` 同拍有效，与 2A `core_top.v:2619` 的
    //      `redirect_exc_pc = trap_valid ? trap_redirect_pc : ...` 同构。
    //      ⇒ 后端同一拍：清空 ROB/重命名/IQ/LSQ（flush_all）＋ 前端重定向取 mtvec/mepc。
    //==========================================================================
    //   ★ 4b-1b：异常与中断统一来自 `trap_ctrl.trap_valid`（含取中断判定），xRET 仍取提交点
    wire        trp_exc_w  = tc_trap_valid & ~tc_trap_is_int;    // 同步异常
    wire        trp_xret_w = xret_cmt_w & ~tc_trap_valid;        // 提交点 mret/sret
    wire        trp_irq_w  = tc_trap_valid & tc_trap_is_int;     // 中断
    wire        trp_take_w = tc_trap_valid | trp_xret_w;

    //   ★★ 4b-1b/1c：目标合成（Direct/Vectored、委托、MTVEC/STVEC 选择）**全在 2A `trap_ctrl` 内**；
    //     本层只做"谁优先"的选择：陷阱 > xRET(mepc/sepc)（4a 的 `trp_mode_w/trp_base_w/
    //     trp_vect_w/trp_cause4_w` 合成已删净）
    wire [31:0] trp_target_w = tc_trap_valid ? tc_redirect_pc :
                               (xret_kind_w == 2'd2) ? csr_sepc_o : csr_mepc_o;

    //   ★★ 4b-2a：维护操作的"提交序执行"语义 ——
    //     · fence.i：**冲刷流水并冻结 256 拍**（L1I 全阵列扫掠），扫掠结束后重定向到
    //       fence.i 的下一条（`fencei_pc_q`）；冻结期间 `flush_all` 持续有效 ⇒ ROB/派发全停，
    //       不会用旧行取指（2A 用 `fencei_hold` 冻结前端，`core_top.v:885-905/3742-3749`）
    //     · sfence.vma / cbo.*：单拍完成（L1D 自身有维护 FSM 逐组扫描，`l1d.idle` 反映），
    //       当拍冲刷 + 重定向到头部 PC+4
    //     · 与陷阱/xRET 的优先级：陷阱 > xRET > fence.i 扫掠 > 维护单拍
    //   ★★ 4b-2a-fix（K1）：单拍维护操作（sfence/cbo）改为**"冻结窗口 + 末尾重定向"** ——
    //     提交拍起保持 `flush_all` 4 拍（把前端在途块与已派发项彻底排空），窗口最后一拍
    //     才发重定向 ⇒ 不再出现"夹在中间的块被二次冲刷丢掉"（K1 实测症状）
    wire        maint_take_w = (maint_sfence_w | maint_cbo_w) & maint_drain_w;
    reg  [2:0]  maint_wait_q;
    reg  [31:0] maint_pc_save_q;
    wire        maint_hold_w  = (maint_wait_q != 3'd0);
    //   ★★ 2B-4 内存序缺口修复（修法 1）：**整机冲刷等 CDQ 排空 + 适配器空闲再生效**。
    //     · `cdq_empty_w`：`lsq_simple` 的已提交 store 排空 FIFO 为空（`~dr_any` 引到顶层）；
    //     · `ad_st_q == AD_IDLE`：数据适配器无在途访问 ⇒ 最后一笔 store 的**写已落进 L1D**
    //       （适配器只在 `cs_wr_done`/写完成那拍才回 IDLE）⇒ 二者相与才是"真的排空"。
    //     若 cbo/sfence 提交拍尚未排空：先挂起（`maint_wait_cdq_q`，期间保持冲刷+冻结前端），
    //     排空后**先发维护动作脉冲（`maint_act_q`）**，再走 4 拍冻结窗口 + 末尾重定向。
    //     · 代价（登记口径）：维护提交到重定向之间多等 ≤ CDQ 深度 + 适配器在途拍（本核
    //       CDQ 深度 4、适配器最多 1 笔在途 ⇒ 最坏 ~5 拍量级），只影响维护延迟、不影响语义。
    wire        maint_drain_w = cdq_empty_w & (ad_st_q == AD_IDLE);
    wire        maint_pend_w  = maint_take_w | maint_wait_cdq_q;
    wire        maint_redir_w = (maint_wait_q == 3'd1);        // 窗口最后一拍才重定向
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            maint_wait_q <= 3'd0; maint_pc_save_q <= 32'h0; maint_wait_cdq_q <= 1'b0;
            maint_kind_save_q <= 3'd0; maint_act_q <= 1'b0;
        end else begin
            maint_act_q <= 1'b0;                    // 单拍脉冲：默认清零
            if (maint_wait_cdq_q) begin
                //   等排空：排空后**发维护动作**并进入 4 拍冻结窗口
                if (maint_drain_w) begin
                    maint_wait_cdq_q <= 1'b0;
                    maint_wait_q     <= 3'd4;
                    maint_act_q      <= 1'b1;
                end
            end else if ((maint_sfence_w | maint_cbo_w) & ~maint_drain_w) begin
                //   维护操作已提交但数据通道未排空 ⇒ 挂起（继续冲刷、保持 PC、锁存动作码）
                maint_wait_cdq_q  <= 1'b1;
                maint_kind_save_q <= maint_kind_w;
                maint_pc_save_q   <= maint_pc_w + 32'd4;
            end else if (maint_take_w) begin
                maint_wait_q      <= 3'd4;
                maint_pc_save_q   <= maint_pc_w + 32'd4;
                maint_kind_save_q <= maint_kind_w;   // ★ 动作码锁存（下一拍脉冲用）
                maint_act_q       <= 1'b1;
            end else if (maint_hold_w) begin
                maint_wait_q <= maint_wait_q - 3'd1;
            end
        end
    end

    assign be_trp_flush       = trp_take_w | fencei_pend_w | maint_pend_w | maint_hold_w;
    assign be_trp_redirect_v  = trp_take_w | maint_redir_w | (fencei_busy_q & ~fencei_busy);
    assign be_trp_redirect_pc = trp_take_w          ? trp_target_w :
                                maint_redir_w       ? maint_pc_save_q :
                                (fencei_busy_q & ~fencei_busy) ? fencei_pc_q :
                                                      trp_target_w;

    //   ★★ K1 收口修正（实测）：**扫掠必须等 L1I 空闲再启动**。
    //     现象：p11 最后一条指令（`j .` @0xa4）永不提交，`[k1tail]` 显示前端停在该 PC、
    //     块呈现恒 0、后端全空闲 ⇒ 前端在等一个"永不返回"的取指响应。
    //     根因：扫掠启动时若 L1I 仍有**在途请求/回填**，`l1i_cs_vaddr` 被切到扫掠地址 ⇒
    //     在途那笔的响应与前端簿记对不上 ⇒ 前端挂死（`~freeze_all` 只防住"冻结期间新发请求"，
    //     防不住"冻结前已发出、响应在途"的那一笔）。
    //     修法：fence.i 提交后先进入 `fencei_wait_q`（期间保持冲刷 + 冻结前端 + 不发新请求），
    //     等 `l1i_idle` 为 1 才真正开始 256 拍扫掠。
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            fencei_busy <= 1'b0; fencei_busy_q <= 1'b0; fencei_wait_q <= 1'b0;
            fencei_idx_q <= 8'd0; fencei_pc_q <= 32'h0;
        end else begin
            fencei_busy_q <= fencei_busy;
            if (maint_fencei_w) begin
                //   fence.i 提交拍：先存下"下一条 PC"；等 L1I 空闲后再扫掠
                fencei_pc_q  <= maint_pc_w + 32'd4;
                //   启动条件：L1I 空闲 **且** 顶层没有在途取指请求/响应（`l1i_pend_q`/
                //   `l1i_own` 皆 0）⇒ 扫掠不会打断任何一笔在途取指，也就不会留下幻影 push
                fencei_wait_q<= ~(l1i_idle & ~l1i_pend_q & ~l1i_own);
                fencei_busy  <=  (l1i_idle & ~l1i_pend_q & ~l1i_own);
                fencei_idx_q <= 8'd0;
            end else if (fencei_wait_q) begin
                if (l1i_idle & ~l1i_pend_q & ~l1i_own) begin
                    fencei_wait_q <= 1'b0;
                    fencei_busy   <= 1'b1;
                    fencei_idx_q  <= 8'd0;
                end
            end else if (fencei_busy) begin
                if (fencei_idx_q == 8'hFF) fencei_busy <= 1'b0;
                fencei_idx_q <= fencei_idx_q + 8'd1;
            end
        end
    end
    //   `trp_halt_w` = 后端观测（历史"陷阱即停机"痕迹；不再参与冲刷/派发门控）

    //==========================================================================
    // 7. 调试口（08 §4.4 口径）
    //--------------------------------------------------------------------------
    //  `debug0_wb_*` 取**提交组 lane 0**（2A 是单发射 ⇒ 逐条一致；本核 4 宽提交时
    //  每拍只输出最老一条，其余 lane 见报告 §B4.2.3 的差异说明）。
    //==========================================================================
    wire [31:0] p0_pc   = commit_pc[0 +: 32];
    wire [4:0]  p0_arn  = commit_arch_rd[0 +: 5];
    wire        p0_we   = commit_arch_we[0];
    wire [31:0] p0_wd   = commit_arch_rd_wdata[0 +: 32];

    assign ws_valid            = |commit_valid;
    assign debug0_wb_pc        = p0_pc;
    assign debug0_wb_rf_wen    = {3'b000, p0_we & (p0_arn != 5'd0)};
    assign debug0_wb_rf_wnum   = p0_arn;
    assign debug0_wb_rf_wdata  = (p0_we & (p0_arn != 5'd0)) ? p0_wd : 32'h0;
    //   ★ 占位：架构寄存器读口（infor_flag/reg_num）第 4 段接（需按架构 RAT 选 PRF）
    assign rf_rdata            = 32'h0;

endmodule
