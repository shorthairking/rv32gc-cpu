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
    //   ★ 占位：陷阱交付属第 4 段（本段只观测，不产生异常处理行为）
    wire        trap_valid_w;
    wire [31:0] trap_pc_w, trap_tval_w;
    wire [3:0]  trap_cause_w;

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
    wire        sv32_en      = 1'b0;                  // ★ 占位（Bare）
    wire        sv32_done    = f_tlb_hit | ptw_req_done;
    wire        sv32_fault   = f_tlb_perm_fault | ptw_fault;
    wire [31:0] sv32_paddr   = f_tlb_hit ? f_tlb_pa : ptw_pa_out;

    tlb #(.ENTRIES(64), .AUTO_FLUSH_ON_ASID(0), .IDX_W(6)) u_tlb (
        .clk(aclk), .rst_n(aresetn),
        // ---- 第一查询口（数据侧）：本段无数据侧翻译 ⇒ 恒空闲 ----
        .lookup_valid(1'b0), .lookup_va(32'h0), .lookup_asid(9'h0),
        .lookup_acc(2'b01), .lookup_priv(`RV32GC_PRIV_M),
        .lookup_sum(1'b0), .lookup_mxr(1'b0),
        .hit_o(), .perm_fault_o(), .pa_o(),
        // ---- 第二查询口 = 取指（2A §5.2.2/§9.4.1 同法）----
        .lookup2_valid(tr_req_valid), .lookup2_va(tr_req_va), .lookup2_asid(9'h0),
        .lookup2_acc(2'b00), .lookup2_priv(`RV32GC_PRIV_M),
        .lookup2_sum(1'b0), .lookup2_mxr(1'b0),
        .hit2_o(f_tlb_hit), .perm_fault2_o(f_tlb_perm_fault), .pa2_o(f_tlb_pa),
        .fill_valid(ptw_fill_valid), .fill_va(ptw_fill_va), .fill_ppn(ptw_fill_ppn),
        .fill_perm(ptw_fill_perm), .fill_asid(9'h0),
        // ---- sfence.vma：本段无 CSR 提交源 ⇒ 恒无效（第 4 段接提交点）----
        .sfence_valid(1'b0), .sfence_va(32'h0), .sfence_asid(9'h0),
        .sfence_all_va(1'b1), .sfence_all_asid(1'b1),
        .satp_we(1'b0), .satp_asid_new(9'h0),
        .hit_count_o(), .miss_count_o(), .flush_count_o()
    );

    ptw u_ptw (
        .clk(aclk), .rst_n(aresetn),
        .kill(1'b0),
        //   ★ 占位：Bare ⇒ 不发起遍历（`sv32_en=0`）；接法已按 2A 口径就位
        .req_valid(sv32_en & ~f_tlb_hit & tr_req_valid),
        .req_va(tr_req_va), .req_acc(2'b00), .req_priv(`RV32GC_PRIV_M),
        .req_sum(1'b0), .req_mxr(1'b0), .satp(32'h0),
        .req_ready(), .req_done(ptw_req_done), .pa_o(ptw_pa_out),
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

    //   PTE 取也要过 PMP（08 §5.4 ④）；本段 PMP 上下文占位（全 0 + M ⇒ 放行）
    pmp_check #(.PMP_ENTRIES(N_PMP)) u_pmp_pte (
        .clk(aclk), .rst_n(aresetn),
        .cfg_i({N_PMP*8{1'b0}}), .addr_i({N_PMP*32{1'b0}}),
        .acc_pa_i(ptw_pmp_req_addr), .acc_bytes_i(5'd4),
        .acc_priv_i(ptw_pmp_req_priv), .acc_type_i(2'b00),   // 取指口径（X）
        .allow_o(ptw_pmp_ok), .fault_cause_o(), .hit_o(), .hit_idx_o(), .denied_by_full_o()
    );

    //==========================================================================
    // 3. front4_top（4 宽取指 + 预测器 + 检查点 + RAS）
    //==========================================================================
    front4_top #(.SPEC_GHR(0), .SEL_FORCE(0)) u_front (
        .clk(aclk), .rst_n(aresetn), .rst_hold(1'b0),
        .redirect_valid(redirect_valid), .redirect_pc(redirect_pc),
        .redirect_use_ckpt(redirect_use_ckpt), .redirect_ckpt(redirect_ckpt),
        .break_point(break_point), .fe_stall(1'b0),
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
        .sv32_translate_en(sv32_en), .sv32_translate_done(sv32_done),
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

    wire        l1i_cs_req = l1i_req_valid;
    wire [31:0] l1i_cs_vaddr = l1i_req_addr;

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
    wire        lsu_req_v, lsu_req_we;
    wire [31:0] lsu_req_a, lsu_req_d;
    wire [3:0]  lsu_req_strb;
    wire [`BACK2_MEM_TAG_W-1:0] lsu_req_tag;

    // ---- uncached 判定（2A `mmio_route` 只读复用；窗口口径不与 2A 分叉）----
    wire [2:0]  d_mr_route;
    wire        d_mr_no_axi, d_mr_clint_plic, d_mr_xip, d_mr_unc, d_mr_cac;
    mmio_route u_mmio_route_d (
        .pa_i(lsu_req_a), .route_o(d_mr_route), .no_axi_o(d_mr_no_axi),
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
    localparam [1:0] AD_IDLE = 2'd0, AD_REQ = 2'd1, AD_WAIT = 2'd2, AD_RETRY = 2'd3;

    reg [1:0]   ad_st_q;
    reg         d_we_q;
    reg         d_unc_q;                 // 该笔走 uncached 直通（AXI 单 beat）
    reg         d_cp_q;                  // 该笔落 CLINT/PLIC 窗口（本段无总线事务，占位）
    reg [31:0]  d_a_q, d_d_q;
    reg [3:0]   d_strb_q;
    reg [`BACK2_MEM_TAG_W-1:0] d_tag_q;

    wire        l1d_busy_w = ~l1d_idle;              // FSM 非空闲（填充/写回/维护）
    wire        d_idle     = (ad_st_q == AD_IDLE);
    assign      d_ready_w  = d_idle & ~l1d_busy_w;   // 可接管新请求
    wire        d_start    = d_ready_w & lsu_req_v;

    // 请求发射：AD_REQ 拍恰好一次（重试时等 L1D 回到 IDLE）
    wire        l1d_cs_req_w = (ad_st_q == AD_REQ);
    wire [31:0] d_rdata_w    = d_unc_q ? d_unc_rdata_w : l1d_cs_rdata;
    assign      d_rsp_v_w    = (ad_st_q == AD_WAIT) & ~d_we_q &
                               (d_cp_q ? 1'b1 :
                                d_unc_q ? d_unc_done_w : l1d_cs_ready);
    assign      d_rsp_d_w    = d_cp_q ? 32'h0 : d_rdata_w;
    assign      d_rsp_tag_w  = d_tag_q;

    l1d #(.OWNER_D_FILL(2'd1), .OWNER_WRBACK(2'd2)) u_l1d (
        .clk(aclk), .rst_n(aresetn),
        .cs_req(l1d_cs_req_w), .cs_we(d_we_q), .cs_wstrb(d_strb_q),
        .cs_paddr(d_a_q), .cs_vaddr(d_a_q), .cs_wdata(d_d_q),
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
        .inval_all(1'b0), .clean_all(1'b0), .idle(l1d_idle)
    );

    // ---- 适配器时序 ----
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            ad_st_q <= AD_IDLE;
            d_we_q <= 1'b0; d_unc_q <= 1'b0; d_cp_q <= 1'b0;
            d_a_q <= 32'h0; d_d_q <= 32'h0; d_strb_q <= 4'h0;
            d_tag_q <= {`BACK2_MEM_TAG_W{1'b0}};
        end else begin
            case (ad_st_q)
                AD_IDLE: begin
                    if (d_start) begin
                        d_we_q   <= lsu_req_we;
                        d_a_q    <= lsu_req_a;
                        d_d_q    <= lsu_req_d;
                        d_strb_q <= lsu_req_strb;
                        d_tag_q  <= lsu_req_tag;
                        d_unc_q  <= d_unc_w;
                        d_cp_q   <= d_clint_plic;
                        ad_st_q  <= (d_unc_w | d_clint_plic) ? AD_WAIT : AD_REQ;
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
        .cnt_commit_o(cnt_commit), .cnt_squash_o(cnt_squash),
        .cnt_commit4_o(), .cnt_issue_o(),
        .dbg_rob_cnt_o(), .dbg_iq_cnt_o(), .dbg_stq_cnt_o(dbg_stq_cnt_w)
    );

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
