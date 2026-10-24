//==============================================================================
// sim/functional/tb_mmu_semantics.sv
//   —— F3 MMU 叶模块包（ptw × tlb × lsu）功能级正反证用例
//==============================================================================
// 目的 : 用**同一份** TB 对两个源码根（DUT_ROOT）编译运行做对照：
//          · 当前（已修）源码 ⇒ 全部向量通过，打印机读摘要
//            `FUNCTIONAL_MMU_VECTORS total=<N> checks=<C> fails=0`、N 行
//            `VEC <i> checks=<d> fails=0` 与唯一整行 `FUNCTIONAL_MMU: PASS`；
//          · 冻结基线 201acf61 ⇒ 定向缺陷标签必须触发 `MMU FAIL [TAG]`（反向 oracle），
//            摘要 fails>0，退出码非 0，且**不**打印 PASS。
//
// 真实请求/应答（不是各自假回包）:
//   · ptw 与 tlb **真实互联**：ptw 的 fill_* 端口直接驱动 tlb 的 fill_* 端口
//     （与 core_top 的接法一致）⇒ 每次成功翻译都走"PTW 填充 → TLB 命中"的真路径；
//   · PTE 读由本 TB 的**行为存储模型**应答（可配延迟，记录每一次物理读的地址）；
//   · PMP 由 TB 的可配禁止区间模型应答（与 tb_ptw 同口径）；
//   · 数据访存由 TB 在**翻译成功后**才发出（记录地址/写次数）——翻译失败时
//     一条数据请求都不会出现，这正是"高 PA 不得别名访问低地址"的观测点；
//   · lsu 例化**完整内部依赖**（pmp_check ×3 / mmio_route / amo_unit / cmo_unit），
//     CBM 的 PMP 权限由真实 pmp_check 判定，不用假信号。
//
// 覆盖的根因（sim/audit/global-2026-10-18/04-memory-bus.md 04-01/02/03/06）:
//   · 04-01 Svade：load 填表（A=1,D=0）后同 VA 的 **store 命中 TLB** 必须 page fault
//     且不得写；D=1 对照必须成功。TLB 不保存 D 时该序列会静默写脏。
//   · 04-02 SFENCE：`rs1!=x0, rs2=x0`（按 VA、全 ASID）**必须失效 global**；
//     `rs2!=x0` 的三个组合保留 global；并区分"rs2 字段=x0"与"普通寄存器值 0"。
//   · 04-03 Sv32 的 34 bit PA 在 32 bit 平台：根表/下级表/4KiB 叶/4MiB 叶高两位
//     非零 ⇒ 原访问类型 access fault，且**不发**该级 PTE 物理读、不产生别名访问。
//   · 04-06 Zicbom：CBM（acc=2'b11）权限 = load **或** store、查 A **不查 D**、
//     异常仍按 store 类；lsu 的 PMP 判定同口径（只读区/只写区都允许，cause 恒 7）。
//
// 机读输出契约（test_mmu.sh 严格解析；同前缀必须唯一）:
//   · `VEC <i> checks=<d> fails=<d>`：第 i 个向量结算行（i = 1..SPEC_VECTORS，恰各一次）；
//   · `FUNCTIONAL_MMU_VECTORS total=<d> checks=<d> fails=<d>`：总摘要
//     （total 必须 == SPEC_VECTORS；checks == 各向量 checks 之和；fails == 0 才 PASS）；
//   · `FUNCTIONAL_MMU: PASS`：仅当全部检查通过时打印（唯一 PASS 子串）。
//   失败行统一为 `MMU FAIL [TAG]: ...`；每个向量在 TB 内自判"至少 1 项检查"
//   （缺检查 ⇒ `MMU FAIL [VEC_EMPTY]` 且该向量行 fails=1）。
//
// 标签口径 :
//   · 缺陷标签（旧基线必须触发，两树区分）:
//       MMU_SVADE_D_TLB_HIT / MMU_SFENCE_GLOBAL_VA /
//       MMU_PA34_ROOT / MMU_PA34_L0 / MMU_PA34_LEAF4K / MMU_PA34_LEAF4M /
//       MMU_PA34_AF_LEGAL / MMU_CBM_RO_PTW / MMU_CBM_RO_TLB / MMU_CBM_D_CHECK /
//       MMU_LSU_CBM_RO / MMU_LSU_NEED_PERM / MMU_LOOKUP2_D0；
//   · 合法控制标签（两实现都必须通过，前缀 `CTRL_`）:
//       CTRL_PTW_TLB_HIT / CTRL_PTW_TLB_PA / CTRL_BASE_TR / CTRL_BIGPAGE /
//       CTRL_SVADE_D1 / CTRL_SVADE_A0 / CTRL_SFENCE_ASID_KEEP_G /
//       CTRL_SFENCE_VA_ASID_KEEP_G / CTRL_SFENCE_ALL / CTRL_PA_LOW /
//       CTRL_SFENCE_OTHER_VA / CTRL_SFENCE_GLOBAL_HIT / CTRL_CBM_FILL /
//       CTRL_CBM_A0 / CTRL_CBM_RESERVED / CTRL_STORE_RO /
//       CTRL_LSU_CBM_WO / CTRL_LSU_CBM_DENY / CTRL_LSU_STORE_RO / CTRL_LSU_LOAD_WO /
//       CTRL_XZ_DETECT / CTRL_PA34_PRIO_PERM / CTRL_PA34_SVADE /
//       CTRL_LOOKUP2_FETCH。
//
// 判定 : 每个向量至少 1 条 `!==`（四态安全）实断言；任一失败 ⇒ 末尾 $fatal(1)，
//        **绝不**打印 PASS；全部通过才打印机读摘要与唯一 PASS 锚点。
// 顶层 : tb_mmu_semantics
//==============================================================================
`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"

module tb_mmu_semantics;

    //--------------------------------------------------------------------------
    // 冻结规格：向量总数（改动 TB 必须同步 test_mmu.sh 的 SPEC_VECTORS）
    //--------------------------------------------------------------------------
    localparam integer SPEC_VECTORS = 32;

    //--------------------------------------------------------------------------
    // 常量
    //--------------------------------------------------------------------------
    localparam [1:0] PRIV_U = `RV32GC_PRIV_U;
    localparam [1:0] PRIV_S = `RV32GC_PRIV_S;
    localparam [1:0] PRIV_M = `RV32GC_PRIV_M;

    localparam [1:0] ACC_FETCH = 2'b00;
    localparam [1:0] ACC_LOAD  = 2'b01;
    localparam [1:0] ACC_STORE = 2'b10;
    localparam [1:0] ACC_CBM   = 2'b11;

    localparam [4:0] C_INSN_AF  = `RV32GC_EXC_INSN_ACCESS_FAULT;    // 1
    localparam [4:0] C_LOAD_AF  = `RV32GC_EXC_LOAD_ACCESS_FAULT;    // 5
    localparam [4:0] C_STORE_AF = `RV32GC_EXC_STORE_ACCESS_FAULT;   // 7
    localparam [4:0] C_INSN_PF  = `RV32GC_EXC_INSN_PAGE_FAULT;      // 12
    localparam [4:0] C_LOAD_PF  = `RV32GC_EXC_LOAD_PAGE_FAULT;      // 13
    localparam [4:0] C_STORE_PF = `RV32GC_EXC_STORE_PAGE_FAULT;     // 15

    // 页表布局（物理地址；全部 < 0x0004_0000，便于小存储模型）
    localparam [21:0] ROOT_PPN = 22'h000020;
    localparam [31:0] ROOT_BASE = 32'h0002_0000;
    localparam [21:0] L0_PPN   = 22'h000030;
    localparam [31:0] L0_BASE  = 32'h0003_0000;

    // 测试用 VA（同一 4 MiB 区，VPN1 = 0x100）
    localparam [31:0] VA_A = 32'h4000_0000;   // VPN0 = 0x000
    localparam [31:0] VA_B = 32'h4000_1000;   // VPN0 = 0x001
    localparam [31:0] VA_C = 32'h4000_2000;   // VPN0 = 0x002

    localparam [21:0] DATA_PPN = 22'h000050;  // PA 0x0005_0000

    // lsu 的访存类型编码
    localparam [2:0] LK_LOAD  = 3'd0;
    localparam [2:0] LK_STORE = 3'd1;
    localparam [2:0] LK_CBO   = 3'd5;

    //--------------------------------------------------------------------------
    // 时钟 / 复位
    //--------------------------------------------------------------------------
    reg clk = 0;
    reg rst_n = 0;
    always #5 clk = ~clk;

    //--------------------------------------------------------------------------
    // 检查计数与逐向量记账（fail-closed）
    //--------------------------------------------------------------------------
    integer n_pass = 0;
    integer n_fail = 0;
    integer n_vec  = 0;
    integer vec_chk_base  = 0;
    integer vec_fail_base = 0;
    integer vec_sum_checks = 0;
    reg     sim_ok = 1'b0;
    //   ★ 2026-10（独审 P1③）：每个向量必须绑定**固定 ID/name**，
    //     `VEC` 行带 name，脚本按冻结表逐 ID 校验 name 与 checks。
    reg [8*32-1:0] cur_vec_name = 32'h0;
    //   ★ 2026-10（独审 P1②）：四态安全 —— 活跃控制线出现 X/Z 必须**被观测到**，
    //     不能被 `if (valid)` 吞掉（X 走 false 分支会伪装成"无请求"）。
    integer xz_cnt = 0;
    reg     saw_pte_strict = 1'b0;   // pte_req_valid === 1（与 ready 无关）
    reg     saw_pmp_strict = 1'b0;
    reg     saw_tlb_strict = 1'b0;

    function xz_detect;
        input b;
        begin
            xz_detect = (b === 1'bx) || (b === 1'bz);
        end
    endfunction

    task settle_vec;
        integer c;
        integer f;
        begin
            //   ★ 四态观测：本向量执行期间活跃控制线出现 X/Z ⇒ 记一条失败
            //     （先结算 XZ，再结算"至少一项检查"，保证 checks 含 XZ 检查）。
            if (xz_cnt != 0) begin
                n_fail = n_fail + 1;
                $display("MMU FAIL [XZ_CONTROL]: vector %0d name=%0s xz=%0d",
                         n_vec, cur_vec_name, xz_cnt);
            end else begin
                n_pass = n_pass + 1;
            end
            c = (n_pass + n_fail) - vec_chk_base;
            f = n_fail - vec_fail_base;
            if (c <= 0) begin
                f = f + 1;
                n_fail = n_fail + 1;
                $display("MMU FAIL [VEC_EMPTY]: vector %0d checks=0", n_vec);
            end
            vec_sum_checks = vec_sum_checks + c;
            $display("VEC %0d name=%0s checks=%0d fails=%0d", n_vec, cur_vec_name, c, f);
        end
    endtask

    task vec_begin;
        input [8*32-1:0] nm;
        begin
            if (n_vec > 0) settle_vec;
            n_vec = n_vec + 1;
            cur_vec_name  = nm;
            vec_chk_base  = n_pass + n_fail;
            vec_fail_base = n_fail;
        end
    endtask

    task chk32;
        input [8*48-1:0] tag;
        input [31:0]     got;
        input [31:0]     exp;
        begin
            if (got !== exp) begin
                n_fail = n_fail + 1;
                $display("MMU FAIL [%0s]: got=0x%08x exp=0x%08x (t=%0t)",
                         tag, got, exp, $time);
            end else n_pass = n_pass + 1;
        end
    endtask

    task chk1;
        input [8*48-1:0] tag;
        input            got;
        input            exp;
        begin
            if (got !== exp) begin
                n_fail = n_fail + 1;
                $display("MMU FAIL [%0s]: got=%b exp=%b (t=%0t)", tag, got, exp, $time);
            end else n_pass = n_pass + 1;
        end
    endtask

    //--------------------------------------------------------------------------
    // DUT：ptw（默认 Svade = 1，显式写出以便审阅）
    //--------------------------------------------------------------------------
    reg         req_valid = 0;
    reg  [31:0] req_va = 0;
    reg  [1:0]  req_acc = ACC_LOAD;
    reg  [1:0]  req_priv = PRIV_S;
    reg         req_sum = 0;
    reg         req_mxr = 0;
    reg  [31:0] satp = 32'h0;

    wire        req_ready, req_done, fault_o;
    wire [31:0] pa_o;
    wire [4:0]  fault_cause_o;
    wire [31:0] fault_tval_o;
    wire        pte_req_valid;
    wire [31:0] pte_req_pa;
    wire        pte_req_ready;
    wire        pte_resp_valid;
    wire [31:0] pte_resp_data;
    wire        pte_resp_err;
    wire        pmp_req_valid;
    wire [31:0] pmp_req_addr;
    wire [1:0]  pmp_req_acc, pmp_req_priv;
    wire        pmp_resp_ok;
    wire        pte_ad_update;
    wire [31:0] pte_ad_pa, pte_ad_data;
    wire        ptw_fill_valid;
    wire [31:0] ptw_fill_va, ptw_fill_pa;
    wire [21:0] ptw_fill_ppn;
    wire [7:0]  ptw_fill_perm;

    ptw #(.SVADE(1)) u_ptw (
        .clk            (clk),
        .rst_n          (rst_n),
        .kill           (1'b0),
        .req_valid      (req_valid),
        .req_va         (req_va),
        .req_acc        (req_acc),
        .req_priv       (req_priv),
        .req_sum        (req_sum),
        .req_mxr        (req_mxr),
        .satp           (satp),
        .req_ready      (req_ready),
        .req_done       (req_done),
        .pa_o           (pa_o),
        .fault_o        (fault_o),
        .fault_cause_o  (fault_cause_o),
        .fault_tval_o   (fault_tval_o),
        .pte_req_valid  (pte_req_valid),
        .pte_req_pa     (pte_req_pa),
        .pte_req_ready  (pte_req_ready),
        .pte_resp_valid (pte_resp_valid),
        .pte_resp_data  (pte_resp_data),
`ifdef PTW_PTE_RESP_ERR_PORT
        .pte_resp_err   (pte_resp_err),
        .idle_o         (),
`endif
        .pmp_req_valid  (pmp_req_valid),
        .pmp_req_addr   (pmp_req_addr),
        .pmp_req_acc    (pmp_req_acc),
        .pmp_req_priv   (pmp_req_priv),
        .pmp_resp_ok    (pmp_resp_ok),
        .pte_ad_update  (pte_ad_update),
        .pte_ad_pa      (pte_ad_pa),
        .pte_ad_data    (pte_ad_data),
        .pte_ad_done    (1'b0),            // Svade=1 ⇒ 本通路恒不可达
        .fill_valid     (ptw_fill_valid),
        .fill_va        (ptw_fill_va),
        .fill_pa        (ptw_fill_pa),
        .fill_ppn       (ptw_fill_ppn),
        .fill_perm      (ptw_fill_perm)
    );

    //--------------------------------------------------------------------------
    // DUT：tlb（fill 端口**直连** ptw ⇒ 真实"PTW 填充 → TLB 命中"路径）
    //--------------------------------------------------------------------------
    reg         lk_valid = 0;
    reg  [31:0] lk_va = 0;
    reg  [1:0]  lk_acc = ACC_LOAD;
    reg  [1:0]  lk_priv = PRIV_S;
    reg         lk_sum = 0;
    reg         lk_mxr = 0;
    reg  [8:0]  asid_v = 9'h0;          // 当前 satp.ASID（同时驱动 fill_asid 与两个查询口）

    wire        tlb_hit, tlb_pf;
    wire [31:0] tlb_pa;
    wire        tlb_hit2, tlb_pf2;
    wire [31:0] tlb_pa2;
    //   第二查询口（取指侧）驱动：本包也要动态覆盖（独审 P2 边界项）
    reg         lk2_valid = 1'b0;
    reg  [31:0] lk2_va = 32'h0;
    reg  [1:0]  lk2_acc = ACC_FETCH;
    reg  [1:0]  lk2_priv = PRIV_S;
    reg         lk2_sum = 1'b0;
    reg         lk2_mxr = 1'b0;

    reg         sf_valid = 0;
    reg  [31:0] sf_va = 0;
    reg  [8:0]  sf_asid = 0;
    reg         sf_all_va = 0;
    reg         sf_all_asid = 0;

    tlb #(.ENTRIES(64), .AUTO_FLUSH_ON_ASID(0), .IDX_W(6)) u_tlb (
        .clk              (clk),
        .rst_n            (rst_n),
        .lookup_valid     (lk_valid),
        .lookup_va        (lk_va),
        .lookup_asid      (asid_v),
        .lookup_acc       (lk_acc),
        .lookup_priv      (lk_priv),
        .lookup_sum       (lk_sum),
        .lookup_mxr       (lk_mxr),
        .hit_o            (tlb_hit),
        .perm_fault_o     (tlb_pf),
        .pa_o             (tlb_pa),
        .lookup2_valid    (lk2_valid),
        .lookup2_va       (lk2_va),
        .lookup2_asid     (asid_v),
        .lookup2_acc      (lk2_acc),
        .lookup2_priv     (lk2_priv),
        .lookup2_sum      (lk2_sum),
        .lookup2_mxr      (lk2_mxr),
        .hit2_o           (tlb_hit2),
        .perm_fault2_o    (tlb_pf2),
        .pa2_o            (tlb_pa2),
        // ---- ★ 真实填充：PTW → TLB 直连（与 core_top 同接法）----
        .fill_valid       (ptw_fill_valid),
        .fill_va          (ptw_fill_va),
        .fill_ppn         (ptw_fill_ppn),
        .fill_perm        (ptw_fill_perm),
        .fill_asid        (asid_v),
        .sfence_valid     (sf_valid),
        .sfence_va        (sf_va),
        .sfence_asid      (sf_asid),
        .sfence_all_va    (sf_all_va),
        .sfence_all_asid  (sf_all_asid),
        .satp_we          (1'b0),
        .satp_asid_new    (asid_v),
        .hit_count_o      (),
        .miss_count_o     (),
        .flush_count_o    ()
    );

    //--------------------------------------------------------------------------
    // PTE 行为存储模型（同步读，可配延迟；记录每一次物理读）
    //--------------------------------------------------------------------------
    localparam integer PM_IDLE = 0;
    localparam integer PM_WAIT = 1;
    localparam integer PM_DATA = 2;
    localparam integer PM_RESP = 3;

    reg [31:0] pte_mem [0:65535];      // 索引 = PA[17:2]（覆盖 0x0–0x3_FFFF）
    integer    pm_lat = 1;             // 读延迟（拍）
    integer    pm_st = PM_IDLE;
    integer    pm_cnt = 0;
    reg [31:0] pm_addr = 0;
    reg        pte_err_en = 1'b0;
    reg [31:0] pte_err_pa = 32'h0;
    reg        pte_resp_err_r = 1'b0;
    assign pte_resp_err = pte_resp_err_r;

    function [15:0] pidx;
        input [31:0] pa;
        begin
            pidx = pa[17:2];
        end
    endfunction

    assign pte_req_ready = (pm_st == PM_IDLE);

    // ---- 物理读计数（"不得产生低地址别名访问"的观测点）----
    integer n_pte_req = 0;
    integer n_ptw_fill = 0;
    integer n_pmp_req = 0;
    integer n_data_req = 0;
    integer n_data_wr = 0;
    reg [31:0] last_data_pa = 32'h0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pm_st <= PM_IDLE;
            pm_cnt <= 0;
            pte_resp_valid_r <= 1'b0;
            pte_resp_err_r <= 1'b0;
        end else begin
            case (pm_st)
                PM_IDLE: begin
                    pte_resp_valid_r <= 1'b0;
                    pte_resp_err_r <= 1'b0;
                    if ((pte_req_valid === 1'b1) && (pte_req_ready === 1'b1)) begin
                        //   ★ 只在 valid===1 时采信 payload（X/Z 拍不得被当成地址）
                        pm_addr <= pte_req_pa;
                        pm_cnt  <= 0;
                        pm_st   <= PM_WAIT;
                    end
                end
                PM_WAIT: begin
                    if (pm_cnt >= pm_lat) begin
                        // 先把数据打进寄存器（valid 仍为 0）⇒ 下一拍 valid 时数据稳定
                        pte_resp_data_r <= pte_mem[pidx(pm_addr)];
                        pm_st <= PM_DATA;
                    end else begin
                        pm_cnt <= pm_cnt + 1;
                    end
                end
                PM_DATA: begin
                    pte_resp_valid_r <= 1'b1;
                    pte_resp_err_r <= pte_err_en && (pm_addr == pte_err_pa);
                    pm_st <= PM_RESP;
                end
                PM_RESP: begin
                    pte_resp_valid_r <= 1'b0;
                    pte_resp_err_r <= 1'b0;
                    pm_st <= PM_IDLE;
                end
                default: pm_st <= PM_IDLE;
            endcase
        end
    end

    reg        pte_resp_valid_r = 1'b0;
    reg [31:0] pte_resp_data_r  = 32'h0;
    assign pte_resp_valid = pte_resp_valid_r;
    assign pte_resp_data  = pte_resp_data_r;

    // ---- PMP 模型（PTE 隐式访存的应答；可配禁止区间）----
    reg        pmp_deny_en = 0;
    reg [31:0] pmp_deny_lo = 32'h0;
    reg [31:0] pmp_deny_hi = 32'h0;

    assign pmp_resp_ok = ~(pmp_deny_en &&
                           (pmp_req_addr >= pmp_deny_lo) &&
                           (pmp_req_addr <= pmp_deny_hi));

    // ---- 计数器（向量内累计）----
    //   ★ 2026-10（独审 P1②）：必须用**严格相等**判定 valid，否则 valid=X 时
    //     `if (valid)` 走 false 分支 ⇒ 计数保持 0 ⇒ "无请求"断言被误判为通过。
    //     另设严格粘滞标志（与 ready 无关），供"本条遍历一条物理读都没发"的断言。
    always @(posedge clk) begin
        if (rst_n) begin
            if ((pte_req_valid === 1'b1) && (pte_req_ready === 1'b1))
                n_pte_req <= n_pte_req + 1;
            if (ptw_fill_valid === 1'b1) n_ptw_fill <= n_ptw_fill + 1;
            if (pmp_req_valid === 1'b1) n_pmp_req <= n_pmp_req + 1;
            if (pte_req_valid === 1'b1) saw_pte_strict <= 1'b1;
            if (pmp_req_valid === 1'b1) saw_pmp_strict <= 1'b1;
            if ((tlb_hit === 1'b1) || (tlb_pf === 1'b1)) saw_tlb_strict <= 1'b1;
        end
    end

    // ---- 活跃控制线的四态监测（X/Z 计数；只观测，不 force DUT）----
    wire xz_active = xz_detect(pte_req_valid) | xz_detect(pte_req_ready) |
                     xz_detect(pte_resp_valid) | xz_detect(pmp_req_valid) |
                     xz_detect(req_done) | xz_detect(fault_o) |
                     xz_detect(tlb_hit) | xz_detect(tlb_pf) |
                     xz_detect(sf_valid) | xz_detect(lk_valid);
    always @(posedge clk) begin
        if (rst_n && (xz_active === 1'b1)) xz_cnt <= xz_cnt + 1;
    end

    // ---- PTW 完成粘滞（req_done 只维持 1 拍）----
    reg done_l = 1'b0;
    always @(posedge clk) if (req_done) done_l <= 1'b1;

    //--------------------------------------------------------------------------
    // DUT：lsu（含真实 pmp_check ×3 / mmio_route / amo_unit / cmo_unit）
    //--------------------------------------------------------------------------
    localparam integer NPMP = `RV32GC_PMP_ENTRIES;

    reg         lsu_req_valid = 0;
    reg  [31:0] lsu_rs1 = 0;
    reg  [31:0] lsu_imm = 0;
    reg  [2:0]  lsu_kind = LK_LOAD;
    reg  [1:0]  lsu_size = 2'd2;
    reg         lsu_unsigned = 0;
    reg  [4:0]  lsu_amo_f5 = 0;
    reg  [4:0]  lsu_cbo_rs2 = 0;
    reg  [31:0] lsu_store_data = 0;
    reg  [1:0]  lsu_cur_priv = PRIV_S;
    reg         lsu_mprv = 0;
    reg  [1:0]  lsu_mpp = PRIV_U;
    reg         lsu_sum = 0;
    reg         lsu_mxr = 0;
    reg         lsu_inval_dg = 0;
    reg  [31:0] lsu_ptw_pa = 0;
    reg         lsu_ptw_fault = 0;
    reg  [4:0]  lsu_ptw_cause = 0;
    reg  [NPMP*8-1:0]  lsu_pmp_cfg = {NPMP*8{1'b0}};
    reg  [NPMP*32-1:0] lsu_pmp_addr = {NPMP*32{1'b0}};

    wire [31:0] lsu_mem_va, lsu_mem_pa, lsu_mem_addr;
    wire        lsu_exc;
    wire [4:0]  lsu_exc_cause;
    wire [31:0] lsu_mtval;
    wire        lsu_misaligned, lsu_pmp_deny;
    wire        lsu_split;
    wire [1:0]  lsu_num_beats;
    wire [31:0] lsu_beat0_addr, lsu_beat1_addr;
    wire [4:0]  lsu_beat0_bytes, lsu_beat1_bytes;
    wire        lsu_beat0_ok, lsu_beat1_ok;
    wire [2:0]  lsu_route;
    wire        lsu_no_axi, lsu_clint_plic, lsu_xip, lsu_axi_unc, lsu_axi_cac;
    wire [3:0]  lsu_axi_cache;
    wire [31:0] lsu_amo_rd_old, lsu_amo_wdata;
    wire        lsu_sc_success, lsu_amo_busy;
    wire        lsu_cmo_valid;
    wire [1:0]  lsu_cmo_action;
    wire [31:0] lsu_cmo_blk_addr, lsu_cmo_blk_size;
    wire [1:0]  lsu_eff_priv, lsu_need_perm;
    wire        lsu_eff_sum, lsu_eff_mxr;

    lsu #(.PMP_ENTRIES(NPMP)) u_lsu (
        .clk              (clk),
        .rst_n            (rst_n),
        .req_valid_i      (lsu_req_valid),
        .rs1_i            (lsu_rs1),
        .imm_i            (lsu_imm),
        .mem_kind_i       (lsu_kind),
        .size_i           (lsu_size),
        .unsigned_i       (lsu_unsigned),
        .amo_f5_i         (lsu_amo_f5),
        .cbo_rs2_i        (lsu_cbo_rs2),
        .store_data_i     (lsu_store_data),
        .cur_priv_i       (lsu_cur_priv),
        .mprv_i           (lsu_mprv),
        .mpp_i            (lsu_mpp),
        .sum_i            (lsu_sum),
        .mxr_i            (lsu_mxr),
        .inval_downgrade_i(lsu_inval_dg),
        .ptw_pa_i         (lsu_ptw_pa),
        .ptw_fault_i      (lsu_ptw_fault),
        .ptw_cause_i      (lsu_ptw_cause),
        .pmp_cfg_i        (lsu_pmp_cfg),
        .pmp_addr_i       (lsu_pmp_addr),
        .mem_va_o         (lsu_mem_va),
        .mem_pa_o         (lsu_mem_pa),
        .mem_addr_o       (lsu_mem_addr),
        .exc_o            (lsu_exc),
        .exc_cause_o      (lsu_exc_cause),
        .mtval_o          (lsu_mtval),
        .misaligned_o     (lsu_misaligned),
        .pmp_deny_o       (lsu_pmp_deny),
        .split_o          (lsu_split),
        .num_beats_o      (lsu_num_beats),
        .beat0_addr_o     (lsu_beat0_addr),
        .beat1_addr_o     (lsu_beat1_addr),
        .beat0_bytes_o    (lsu_beat0_bytes),
        .beat1_bytes_o    (lsu_beat1_bytes),
        .beat0_ok_o       (lsu_beat0_ok),
        .beat1_ok_o       (lsu_beat1_ok),
        .route_o          (lsu_route),
        .no_axi_o         (lsu_no_axi),
        .mmio_clint_plic_o(lsu_clint_plic),
        .xip_direct_o     (lsu_xip),
        .axi_uncached_o   (lsu_axi_unc),
        .axi_cached_o     (lsu_axi_cac),
        .axi_cache_o      (lsu_axi_cache),
        .amo_rd_old_o     (lsu_amo_rd_old),
        .sc_success_o     (lsu_sc_success),
        .amo_wdata_o      (lsu_amo_wdata),
        .amo_busy_o       (lsu_amo_busy),
        .cmo_valid_o      (lsu_cmo_valid),
        .cmo_action_o     (lsu_cmo_action),
        .cmo_block_addr_o (lsu_cmo_blk_addr),
        .cmo_block_size_o (lsu_cmo_blk_size),
        .eff_priv_o       (lsu_eff_priv),
        .eff_sum_o        (lsu_eff_sum),
        .eff_mxr_o        (lsu_eff_mxr),
        .need_perm_o      (lsu_need_perm),
        .amo_rdata_i      (32'h0),
        .amo_rdata_valid_i(1'b0)
    );

    //--------------------------------------------------------------------------
    // 辅助：PTE 构造 / 页表布局
    //--------------------------------------------------------------------------
    function [31:0] mk_pte;
        input [21:0] ppn;
        input        d, a, g, u, x, w, r, v;
        begin
            mk_pte = (ppn << `RV32GC_PTE_PPN_LSB) |
                     ({31'b0, d}  << `RV32GC_PTE_D_BIT) |
                     ({31'b0, a}  << `RV32GC_PTE_A_BIT) |
                     ({31'b0, g}  << `RV32GC_PTE_G_BIT) |
                     ({31'b0, u}  << `RV32GC_PTE_U_BIT) |
                     ({31'b0, x}  << `RV32GC_PTE_X_BIT) |
                     ({31'b0, w}  << `RV32GC_PTE_W_BIT) |
                     ({31'b0, r}  << `RV32GC_PTE_R_BIT) |
                     ({31'b0, v}  << `RV32GC_PTE_V_BIT);
        end
    endfunction

    task pt_clear;
        integer i;
        begin
            for (i = 0; i < 65536; i = i + 1) pte_mem[i] = 32'h0;
        end
    endtask

    task set_pte;
        input [31:0] pa;
        input [31:0] val;
        begin
            pte_mem[pidx(pa)] = val;
        end
    endtask

    // 根 PTE 指针（VPN1 固定 0x100）+ 二级叶
    task set_root_ptr;
        input [21:0] l0_ppn;
        input        g;
        begin
            set_pte(ROOT_BASE + ((VA_A[31:22]) << 2),
                    mk_pte(l0_ppn, 1'b0, 1'b0, g, 1'b0, 1'b0, 1'b0, 1'b0, 1'b1));
        end
    endtask

    task set_l0_leaf;
        input [31:0] va;
        input [21:0] l0_ppn;
        input [21:0] leaf_ppn;
        input        d, a, g, u, x, w, r;
        begin
            set_pte({l0_ppn, 12'h000} + ((va[21:12]) << 2),
                    mk_pte(leaf_ppn, d, a, g, u, x, w, r, 1'b1));
        end
    endtask

    // 4 MiB 大页（一级叶；要求 PPN[0]=0）
    task set_big_leaf;
        input [31:0] va;
        input [21:0] ppn;
        input        d, a, g, r, w, x;
        begin
            set_pte(ROOT_BASE + ((va[31:22]) << 2),
                    mk_pte(ppn, d, a, g, 1'b0, x, w, r, 1'b1));
        end
    endtask

    // 标准两级布局：叶 PPN = DATA_PPN，A=1，D 由参数给
    task setup_std;
        input [31:0] va;
        input        d;
        input        r, w, x, a;
        begin
            set_root_ptr(L0_PPN, 1'b0);
            set_l0_leaf(va, L0_PPN, DATA_PPN, d, a, 1'b0, 1'b0, x, w, r);
        end
    endtask

    //--------------------------------------------------------------------------
    // 辅助：TLB 组合查询（不推进任何状态）
    //--------------------------------------------------------------------------
    task tlb_probe;
        input  [31:0] va;
        input  [1:0]  acc;
        input  [1:0]  pv;
        input         sm;
        input         mx;
        output        hit;
        output        pf;
        output [31:0] pa;
        begin
            @(negedge clk);
            lk_valid = 1'b1;
            lk_va    = va;
            lk_acc   = acc;
            lk_priv  = pv;
            lk_sum   = sm;
            lk_mxr   = mx;
            #1;
            hit = tlb_hit;
            pf  = tlb_pf;
            pa  = tlb_pa;
            @(negedge clk);
            lk_valid = 1'b0;
            #1;
        end
    endtask

    //--------------------------------------------------------------------------
    // 辅助：TLB **第二查询口** 组合查询（取指侧；不推进状态）
    //--------------------------------------------------------------------------
    task tlb_probe2;
        input  [31:0] va;
        input  [1:0]  acc;
        input  [1:0]  pv;
        input         sm;
        input         mx;
        output        hit;
        output        pf;
        output [31:0] pa;
        begin
            @(negedge clk);
            lk2_valid = 1'b1;
            lk2_va    = va;
            lk2_acc   = acc;
            lk2_priv  = pv;
            lk2_sum   = sm;
            lk2_mxr   = mx;
            #1;
            hit = tlb_hit2;
            pf  = tlb_pf2;
            pa  = tlb_pa2;
            @(negedge clk);
            lk2_valid = 1'b0;
            #1;
        end
    endtask

    //--------------------------------------------------------------------------
    // 辅助：跑一次真实页表遍历（PTW），成功时再回查 TLB 证明"填充→命中"
    //--------------------------------------------------------------------------
    task walk;
        input  [31:0] va;
        input  [1:0]  acc;
        input  [1:0]  pv;
        input         sm;
        input         mx;
        output        fault;
        output [4:0]  cause;
        output [31:0] pa;
        integer k;
        reg h, pf;
        reg [31:0] p2;
        begin
            done_l = 1'b0;
            @(negedge clk);
            req_valid = 1'b1;
            req_va    = va;
            req_acc   = acc;
            req_priv  = pv;
            req_sum   = sm;
            req_mxr   = mx;
            satp      = satp_v;
            @(negedge clk);
            req_valid = 1'b0;
            k = 0;
            while (!done_l && k < 400) begin
                @(posedge clk);
                #1;
                k = k + 1;
            end
            if (!done_l) begin
                n_fail = n_fail + 1;
                $display("MMU FAIL [VEC_HANG]: walk timeout va=0x%08x acc=%0d st=%0d",
                         va, acc, u_ptw.st);
            end
            fault = fault_o;
            cause = fault_cause_o;
            pa    = pa_o;
            if (!fault) begin
                // ★ PTW 填充 → TLB 命中：同一 TB 内**真实联测**，不用假回包
                tlb_probe(va, acc, pv, sm, mx, h, pf, p2);
                chk1("CTRL_PTW_TLB_HIT", h, 1'b1);
                chk1("CTRL_PTW_TLB_NOPF", pf, 1'b0);
                chk32("CTRL_PTW_TLB_PA", p2, pa);
            end
        end
    endtask

    // 数据访存（只在翻译成功后调用；记录地址/写次数）
    task data_access;
        input [31:0] pa;
        input        wr;
        begin
            n_data_req = n_data_req + 1;
            last_data_pa = pa;
            if (wr) n_data_wr = n_data_wr + 1;
        end
    endtask

    // SFENCE（一拍脉冲；判据是 rs1/rs2 的**字段**是否 x0，由调用方给 all_*）
    task do_sfence;
        input [31:0] va;
        input [8:0]  asid;
        input        all_va;
        input        all_asid;
        begin
            @(negedge clk);
            sf_valid    = 1'b1;
            sf_va       = va;
            sf_asid     = asid;
            sf_all_va   = all_va;
            sf_all_asid = all_asid;
            @(negedge clk);
            sf_valid    = 1'b0;
            #1;
        end
    endtask

    // 向量开始时清计数器（保证"本向量内"的观测独立）
    task clr_counters;
        begin
            n_pte_req = 0;
            n_ptw_fill = 0;
            n_pmp_req = 0;
            n_data_req = 0;
            n_data_wr = 0;
            last_data_pa = 32'h0;
            saw_pte_strict = 1'b0;
            saw_pmp_strict = 1'b0;
            saw_tlb_strict = 1'b0;
            xz_cnt = 0;
        end
    endtask

    // 用**真实遍历**填一个表项（ASID/global 由参数控制）
    task fill_entry;
        input [31:0] va;
        input [8:0]  asid;
        input        g;
        input [21:0] ppn;
        reg        h, pf, f;
        reg [4:0]  c;
        reg [31:0] p, p2;
        begin
            asid_v = asid;
            satp_v = 32'h8000_0000 | ({23'b0, asid} << 22) | ROOT_PPN;
            set_root_ptr(L0_PPN, 1'b0);
            set_l0_leaf(va, L0_PPN, ppn, 1'b1, 1'b1, g, 1'b0, 1'b0, 1'b1, 1'b1);
            tlb_probe(va, ACC_LOAD, PRIV_S, 1'b0, 1'b0, h, pf, p2);
            if (!h) begin
                walk(va, ACC_LOAD, PRIV_S, 1'b0, 1'b0, f, c, p);
            end
        end
    endtask

    // 当前 satp（含 ASID）——由各向量显式设置
    reg [31:0] satp_v = 32'h8000_0000 | ROOT_PPN;

    // lsu 的 PMP 配置助手
    task lsu_pmp_clear;
        integer i;
        begin
            for (i = 0; i < NPMP; i = i + 1) begin
                lsu_pmp_cfg[i*8 +: 8]  = 8'h0;
                lsu_pmp_addr[i*32 +: 32] = 32'h0;
            end
        end
    endtask

    task lsu_pmp_na4;
        input integer i;
        input [31:0]  pa;
        input         r, w, x;
        begin
            // {L=1, 2'b00, A=NA4(10), X, W, R}
            lsu_pmp_cfg[i*8 +: 8]    = {1'b1, 2'b00, 2'b10, x, w, r};
            lsu_pmp_addr[i*32 +: 32] = pa >> 2;
        end
    endtask

    // lsu 组合求值（lsu 本身无时序逻辑；#1 后采样）
    task lsu_eval;
        input [2:0]  kind;
        input [31:0] va;
        input [1:0]  pv;
        input [4:0]  cbo_rs2;
        begin
            lsu_req_valid  = 1'b1;
            lsu_rs1        = va;
            lsu_imm        = 32'h0;
            lsu_kind       = kind;
            lsu_size       = 2'd2;
            lsu_cbo_rs2    = cbo_rs2;
            lsu_cur_priv   = pv;
            lsu_mprv       = 1'b0;
            lsu_mpp        = PRIV_U;
            lsu_sum        = 1'b0;
            lsu_mxr        = 1'b0;
            lsu_ptw_pa     = va;
            lsu_ptw_fault  = 1'b0;
            lsu_ptw_cause  = 5'h0;
            #1;
        end
    endtask

    //--------------------------------------------------------------------------
    // 主测试
    //--------------------------------------------------------------------------
    integer i;
    reg        h, pf, f;
    reg [4:0]  c;
    reg [31:0] p, p2;

    initial begin
        $display("---- tb_mmu_semantics: F3 MMU（ptw × tlb × lsu）----");

        pt_clear;
        lsu_pmp_clear;
        rst_n = 0;
        repeat(4) @(posedge clk);
        #1;
        rst_n = 1;
        repeat(2) @(posedge clk);
        #1;

        //======================================================================
        // V1 CTRL_XZ_DETECT：四态观测器自证（**私有观测替身**，不 force DUT）
        //   独审 P1②：valid=X 被 `if` 吞掉会让"无请求"断言假绿 ⇒ 观测器必须真能
        //   分辨 X/Z 与 0/1；本向量只验证观测器本身，不驱动 DUT。
        //======================================================================
        vec_begin("CTRL_XZ_DETECT");
        clr_counters;
        chk1("CTRL_XZ_DETECT", xz_detect(1'bx), 1'b1);
        chk1("CTRL_XZ_DETECT", xz_detect(1'bz), 1'b1);
        chk1("CTRL_XZ_DETECT", xz_detect(1'b0), 1'b0);
        chk1("CTRL_XZ_DETECT", xz_detect(1'b1), 1'b0);

`ifdef MMU_XZ_NEG
        //======================================================================
        // ★ 负向刺激（只在 -DMMU_XZ_NEG 的私有不入库构建里编译）：
        //   把 **TB 驱动的活跃控制线** `lk_valid` 打成 X —— 不 force DUT 任何内部，
        //   走的是真实端口/真实 monitor：xz_cnt 必须 +1，本向量在 vecend 报
        //   `MMU FAIL [XZ_CONTROL]`，正式 gate 必须以 reason=xz_control 精确拒。
        //   删除 monitor 的变异体（见 test_mmu.sh --self-test）不会再出现该标签。
        //   注：pmp_req_valid 是 DUT **输出**，驱动它只能靠 force（本包禁止），
        //       故用同属 monitor 观测集的 TB 输入控制线做刺激。
        //======================================================================
        vec_begin("XZ_NEG_STIM");
        clr_counters;
        @(negedge clk);
        lk_valid = 1'bx;
        @(posedge clk);
        #1;
        @(negedge clk);
        lk_valid = 1'b0;
        chk1("XZ_NEG_STIM", xz_cnt > 0, 1'b1);
`endif

        //======================================================================
        // V2 CTRL_BASE_TR：两级页表 + PTW 填充 + TLB 命中（基线正控）
        //======================================================================
        vec_begin("CTRL_BASE_TR");
        clr_counters;
        setup_std(VA_A, 1'b1, 1'b1, 1'b1, 1'b0, 1'b1);   // RW, A=1, D=1
        satp_v = 32'h8000_0000 | ROOT_PPN;
        asid_v = 9'h0;
        walk(VA_A, ACC_LOAD, PRIV_S, 1'b0, 1'b0, f, c, p);
        chk1("CTRL_BASE_TR", f, 1'b0);
        chk32("CTRL_BASE_TR", p, {10'b0, DATA_PPN, 12'h000});
        chk32("CTRL_BASE_TR", n_pte_req, 32'd2);          // 两级各一次
        data_access(p, 1'b0);
        chk32("CTRL_BASE_TR", last_data_pa, {10'b0, DATA_PPN, 12'h000});
        // 再次查询 ⇒ TLB 命中（不再走 PTW）
        clr_counters;
        tlb_probe(VA_A, ACC_LOAD, PRIV_S, 1'b0, 1'b0, h, pf, p2);
        chk1("CTRL_BASE_TR", h, 1'b1);
        chk32("CTRL_BASE_TR", p2, {10'b0, DATA_PPN, 12'h000});
        chk32("CTRL_BASE_TR", n_pte_req, 32'd0);          // 命中不再发物理读
`ifdef PTW_PTE_RESP_ERR_PORT
        // New-interface-only error cases. Old 201acf61 compiles this TB without the
        // pin and keeps its frozen 32-vector/243-check role unchanged.
        do_sfence(32'h0, 9'h0, 1'b1, 1'b1);
        clr_counters;
        setup_std(VA_A, 1'b1, 1'b1, 1'b1, 1'b0, 1'b1);
        satp_v = 32'h8000_0000 | ROOT_PPN;
        pte_err_en = 1'b1;
        pte_err_pa = ROOT_BASE + 32'h400; // VA_A VPN1=0x100, root PTE read error
        walk(VA_A, ACC_LOAD, PRIV_S, 1'b0, 1'b0, f, c, p);
        pte_err_en = 1'b0;
        chk1("CTRL_BASE_TR PTE root load error", f, 1'b1);
        chk32("CTRL_BASE_TR root load AF5", {27'b0,c}, C_LOAD_AF);
        chk32("CTRL_BASE_TR root error tval", fault_tval_o, VA_A);
        chk32("CTRL_BASE_TR root error no fill", n_ptw_fill, 32'd0);
        chk32("CTRL_BASE_TR root error no data access", n_data_req, 32'd0);

        do_sfence(32'h0, 9'h0, 1'b1, 1'b1);
        clr_counters;
        setup_std(VA_A, 1'b1, 1'b1, 1'b1, 1'b0, 1'b1);
        pte_err_en = 1'b1;
        pte_err_pa = L0_BASE; // leaf PTE response error, not the root pointer response
        walk(VA_A, ACC_STORE, PRIV_S, 1'b0, 1'b0, f, c, p);
        pte_err_en = 1'b0;
        chk1("CTRL_BASE_TR PTE leaf store error", f, 1'b1);
        chk32("CTRL_BASE_TR leaf store AF7", {27'b0,c}, C_STORE_AF);
        chk32("CTRL_BASE_TR leaf error tval", fault_tval_o, VA_A);
        chk32("CTRL_BASE_TR leaf error no fill", n_ptw_fill, 32'd0);
        chk32("CTRL_BASE_TR leaf error no data access", n_data_req, 32'd0);
`endif

        //======================================================================
        // V2 CTRL_BIGPAGE：4 MiB 大页（一级叶，PPN[0]=0）
        //======================================================================
        vec_begin("CTRL_BIGPAGE");
        clr_counters;
        do_sfence(32'h0, 9'h0, 1'b1, 1'b1);
        set_big_leaf(VA_A, 22'h000400, 1'b1, 1'b1, 1'b0, 1'b1, 1'b1, 1'b0);
        walk(VA_A, ACC_LOAD, PRIV_S, 1'b0, 1'b0, f, c, p);
        chk1("CTRL_BIGPAGE", f, 1'b0);
        chk32("CTRL_BIGPAGE", p, 32'h0040_0000);          // (PPN[1]=1)<<22 | VA[21:0]
        chk32("CTRL_BIGPAGE", n_pte_req, 32'd1);          // 大页只读一级

        //======================================================================
        // V3 ★ MMU_SVADE_D_TLB_HIT（04-01）
        //   load 填表（A=1,D=0）后，同 VA 的 **store 命中 TLB** ⇒ 必须 page fault
        //   且**不得写**；旧实现在 TLB 里丢 D ⇒ 直接写成功（漏检）。
        //======================================================================
        vec_begin("MMU_SVADE_D_TLB_HIT");
        clr_counters;
        do_sfence(32'h0, 9'h0, 1'b1, 1'b1);
        setup_std(VA_A, 1'b0, 1'b1, 1'b1, 1'b0, 1'b1);   // RW, A=1, D=0
        satp_v = 32'h8000_0000 | ROOT_PPN;
        asid_v = 9'h0;
        walk(VA_A, ACC_LOAD, PRIV_S, 1'b0, 1'b0, f, c, p);
        chk1("CTRL_BASE_TR", f, 1'b0);                    // load 合法（不查 D）
        data_access(p, 1'b0);
        // ---- store 走**命中路径**（不发 PTW；pte 计数必须保持 0）----
        clr_counters;
        tlb_probe(VA_A, ACC_STORE, PRIV_S, 1'b0, 1'b0, h, pf, p2);
        chk1("MMU_SVADE_D_TLB_HIT", pf, 1'b1);            // 命中但必须 fault
        chk1("MMU_SVADE_D_TLB_HIT", h, 1'b0);             // 不得给 PA
        chk32("MMU_SVADE_D_TLB_HIT", n_pte_req, 32'd0);   // 证明走的是 TLB 命中路径
        chk32("MMU_SVADE_D_TLB_HIT", n_data_wr, 32'd0);   // 不得写

        //======================================================================
        // V4 CTRL_SVADE_D1：同一序列但 D=1 ⇒ store 命中必须成功
        //======================================================================
        vec_begin("CTRL_SVADE_D1");
        clr_counters;
        do_sfence(32'h0, 9'h0, 1'b1, 1'b1);
        setup_std(VA_A, 1'b1, 1'b1, 1'b1, 1'b0, 1'b1);   // RW, A=1, D=1
        walk(VA_A, ACC_LOAD, PRIV_S, 1'b0, 1'b0, f, c, p);
        chk1("CTRL_SVADE_D1", f, 1'b0);
        clr_counters;
        tlb_probe(VA_A, ACC_STORE, PRIV_S, 1'b0, 1'b0, h, pf, p2);
        chk1("CTRL_SVADE_D1", h, 1'b1);
        chk1("CTRL_SVADE_D1", pf, 1'b0);
        chk32("CTRL_SVADE_D1", p2, {10'b0, DATA_PPN, 12'h000});
        data_access(p2, 1'b1);
        chk32("CTRL_SVADE_D1", n_data_wr, 32'd1);

        //======================================================================
        // V5 CTRL_SVADE_A0：A=0 ⇒ Svade 直接 page fault（13/15），不填充
        //======================================================================
        vec_begin("CTRL_SVADE_A0");
        clr_counters;
        do_sfence(32'h0, 9'h0, 1'b1, 1'b1);
        setup_std(VA_A, 1'b0, 1'b1, 1'b1, 1'b0, 1'b0);   // RW, A=0
        walk(VA_A, ACC_LOAD, PRIV_S, 1'b0, 1'b0, f, c, p);
        chk1("CTRL_SVADE_A0", f, 1'b1);
        chk32("CTRL_SVADE_A0", {27'b0, c}, {27'b0, C_LOAD_PF});
        walk(VA_A, ACC_STORE, PRIV_S, 1'b0, 1'b0, f, c, p);
        chk1("CTRL_SVADE_A0", f, 1'b1);
        chk32("CTRL_SVADE_A0", {27'b0, c}, {27'b0, C_STORE_PF});
        tlb_probe(VA_A, ACC_LOAD, PRIV_S, 1'b0, 1'b0, h, pf, p2);
        chk1("CTRL_SVADE_A0", h, 1'b0);                   // 失败不得填充

        //======================================================================
        // V6 ★ MMU_SFENCE_GLOBAL_VA（04-02）
        //   `sfence.vma rs1!=x0, rs2=x0`（按 VA、**全 ASID**）必须失效该 VA 的
        //   **global** 项；旧实现无条件先排除 G ⇒ 旧翻译残留。
        //======================================================================
        vec_begin("MMU_SFENCE_GLOBAL_VA");
        clr_counters;
        do_sfence(32'h0, 9'h0, 1'b1, 1'b1);               // 先全刷
        fill_entry(VA_A, 9'd2, 1'b0, 22'h000050);         // 非 global，ASID=2
        fill_entry(VA_A, 9'd0, 1'b1, 22'h000051);         // **global**，ASID=0
        fill_entry(VA_C, 9'd0, 1'b1, 22'h000052);         // 另一 VA 的 global
        // 前置：global 项对任意 ASID 都应命中
        tlb_probe(VA_A, ACC_LOAD, PRIV_S, 1'b0, 1'b0, h, pf, p2);
        chk1("CTRL_SFENCE_GLOBAL_HIT", h, 1'b1);
        chk32("CTRL_SFENCE_GLOBAL_HIT", p2, 32'h0005_1000);
        do_sfence(VA_A, 9'h0, 1'b0, 1'b1);                // rs1=VA, rs2=x0
        // ---- global 项必须失效（旧实现保留 ⇒ 此处红）----
        tlb_probe(VA_A, ACC_LOAD, PRIV_S, 1'b0, 1'b0, h, pf, p2);
        chk1("MMU_SFENCE_GLOBAL_VA", h, 1'b0);
        // ---- 同 VA 的非 global（ASID=2）也必须失效（全 ASID）----
        //   该断言与 MMU_SFENCE_GLOBAL_VA **同根因**（旧实现把整个 rs2=x0 组合
        //   当成"G 保留 + VA 过滤"，两处都会红）⇒ 必须用**缺陷标签**，
        //   不能标成 CTRL_（否则旧树"红得不对"）。
        asid_v = 9'd2;
        tlb_probe(VA_A, ACC_LOAD, PRIV_S, 1'b0, 1'b0, h, pf, p2);
        chk1("MMU_SFENCE_GLOBAL_VA", h, 1'b0);
        // ---- 另一 VA 的 global 必须保留（VA 定向）----
        asid_v = 9'd0;
        tlb_probe(VA_C, ACC_LOAD, PRIV_S, 1'b0, 1'b0, h, pf, p2);
        chk1("CTRL_SFENCE_OTHER_VA", h, 1'b1);
        chk32("CTRL_SFENCE_OTHER_VA", p2, 32'h0005_2000);

        //======================================================================
        // V7 CTRL_SFENCE_ASID_KEEP_G：`rs1=x0, rs2!=x0`（普通寄存器值 0）
        //   ⇒ 只失效该 ASID 的非 global 项；**global 保留**（两实现都必须对）。
        //   同时证明"rs2 值 0 但寄存器非 x0"≠"rs2=x0"。
        //======================================================================
        vec_begin("CTRL_SFENCE_ASID_KEEP_G");
        clr_counters;
        do_sfence(32'h0, 9'h0, 1'b1, 1'b1);
        fill_entry(VA_A, 9'd0, 1'b1, 22'h000050);         // global
        fill_entry(VA_B, 9'd0, 1'b0, 22'h000051);         // 非 global，ASID=0
        do_sfence(32'h0, 9'd0, 1'b1, 1'b0);               // rs1=x0, rs2=t0(=0)
        tlb_probe(VA_A, ACC_LOAD, PRIV_S, 1'b0, 1'b0, h, pf, p2);
        chk1("CTRL_SFENCE_ASID_KEEP_G", h, 1'b1);         // global 保留
        tlb_probe(VA_B, ACC_LOAD, PRIV_S, 1'b0, 1'b0, h, pf, p2);
        chk1("CTRL_SFENCE_ASID_KEEP_G", h, 1'b0);         // ASID 定向失效

        //======================================================================
        // V8 CTRL_SFENCE_VA_ASID_KEEP_G：`rs1!=x0, rs2!=x0`（值 0）
        //   ⇒ VA∩ASID；global 保留。
        //======================================================================
        vec_begin("CTRL_SFENCE_VA_ASID_KEEP_G");
        clr_counters;
        do_sfence(32'h0, 9'h0, 1'b1, 1'b1);
        fill_entry(VA_A, 9'd0, 1'b1, 22'h000050);         // global
        fill_entry(VA_B, 9'd0, 1'b0, 22'h000051);         // 非 global 同 ASID
        do_sfence(VA_B, 9'd0, 1'b0, 1'b0);                // rs1=VA_B, rs2=t0(=0)
        tlb_probe(VA_A, ACC_LOAD, PRIV_S, 1'b0, 1'b0, h, pf, p2);
        chk1("CTRL_SFENCE_VA_ASID_KEEP_G", h, 1'b1);      // global 保留
        tlb_probe(VA_B, ACC_LOAD, PRIV_S, 1'b0, 1'b0, h, pf, p2);
        chk1("CTRL_SFENCE_VA_ASID_KEEP_G", h, 1'b0);      // 匹配项失效

        //======================================================================
        // V9 CTRL_SFENCE_ALL：`rs1=x0, rs2=x0` ⇒ 全失效（含 global）
        //======================================================================
        vec_begin("CTRL_SFENCE_ALL");
        clr_counters;
        do_sfence(32'h0, 9'h0, 1'b1, 1'b1);
        fill_entry(VA_A, 9'd0, 1'b1, 22'h000050);
        fill_entry(VA_B, 9'd3, 1'b0, 22'h000051);
        do_sfence(32'h0, 9'h0, 1'b1, 1'b1);
        tlb_probe(VA_A, ACC_LOAD, PRIV_S, 1'b0, 1'b0, h, pf, p2);
        chk1("CTRL_SFENCE_ALL", h, 1'b0);
        asid_v = 9'd3;
        tlb_probe(VA_B, ACC_LOAD, PRIV_S, 1'b0, 1'b0, h, pf, p2);
        chk1("CTRL_SFENCE_ALL", h, 1'b0);
        asid_v = 9'd0;

        //======================================================================
        // V10 ★ MMU_PA34_ROOT（04-03）：根表基址 PPN 高两位非零
        //   satp.ppn = 22'h100020 ⇒ 根表 PA = 0x1_0002_0000（34 bit，不可达）
        //   截断后恰为真实根表 0x0002_0000 ⇒ 旧实现会"成功"并返回翻译。
        //   要求：原访问类型 access fault，且**一条 PTE 物理读都不发**。
        //======================================================================
        vec_begin("MMU_PA34_ROOT");
        clr_counters;
        do_sfence(32'h0, 9'h0, 1'b1, 1'b1);
        setup_std(VA_A, 1'b1, 1'b1, 1'b1, 1'b0, 1'b1);
        satp_v = 32'h8000_0000 | 22'h100020;              // 根 PPN 高位
        walk(VA_A, ACC_LOAD, PRIV_S, 1'b0, 1'b0, f, c, p);
        chk1("MMU_PA34_ROOT", f, 1'b1);
        chk32("MMU_PA34_ROOT", {27'b0, c}, {27'b0, C_LOAD_AF});
        //   ★ 独审 P1②：用**严格粘滞**标志（valid===1 即锁），不用会被 X 吞掉的计数
        chk1("MMU_PA34_ROOT", saw_pte_strict, 1'b0);     // 不得读别名根表
        chk1("MMU_PA34_ROOT", saw_pmp_strict, 1'b0);     // 也不发 PMP 请求
        chk32("MMU_PA34_ROOT", n_pte_req, 32'd0);
        walk(VA_A, ACC_FETCH, PRIV_S, 1'b0, 1'b0, f, c, p);
        chk1("MMU_PA34_ROOT", f, 1'b1);
        chk32("MMU_PA34_ROOT", {27'b0, c}, {27'b0, C_INSN_AF});
        walk(VA_A, ACC_STORE, PRIV_S, 1'b0, 1'b0, f, c, p);
        chk1("MMU_PA34_ROOT", f, 1'b1);
        chk32("MMU_PA34_ROOT", {27'b0, c}, {27'b0, C_STORE_AF});
        tlb_probe(VA_A, ACC_LOAD, PRIV_S, 1'b0, 1'b0, h, pf, p2);
        chk1("MMU_PA34_ROOT", h, 1'b0);                   // 不得填充别名翻译

        //======================================================================
        // V11 ★ MMU_PA34_L0：下级表基址（一级 PTE 的 PPN）高位非零
        //   一级指针 PPN = 22'h100030 ⇒ 二级表 PA = 0x1_0003_0000（截断后=真实二级表）
        //   要求：store ⇒ cause 7，且只发**一级**那一次 PTE 读。
        //======================================================================
        vec_begin("MMU_PA34_L0");
        clr_counters;
        //   ★ 先全刷：本向量只观测"本级高地址 ⇒ 不发下级 PTE 读"，
        //     不让先前向量可能残留的**同 VA** 表项参与（TLB 的唯一性假设见 L2）。
        do_sfence(32'h0, 9'h0, 1'b1, 1'b1);
        satp_v = 32'h8000_0000 | ROOT_PPN;
        asid_v = 9'h0;
        set_root_ptr(22'h100030, 1'b0);                   // 指针 PPN 高位
        set_l0_leaf(VA_A, L0_PPN, DATA_PPN, 1'b1, 1'b1, 1'b0, 1'b0, 1'b0, 1'b1, 1'b1);
        walk(VA_A, ACC_STORE, PRIV_S, 1'b0, 1'b0, f, c, p);
        chk1("MMU_PA34_L0", f, 1'b1);
        chk32("MMU_PA34_L0", {27'b0, c}, {27'b0, C_STORE_AF});
        chk32("MMU_PA34_L0", n_pte_req, 32'd1);          // 只读一级，二级不发
        chk1("MMU_PA34_L0", saw_pte_strict, 1'b1);
        tlb_probe(VA_A, ACC_LOAD, PRIV_S, 1'b0, 1'b0, h, pf, p2);
        chk1("MMU_PA34_L0", h, 1'b0);

        //======================================================================
        // V12 ★ MMU_PA34_LEAF4K：4 KiB 叶 PPN 高位非零
        //   叶 PPN = 22'h100005 ⇒ PA = 0x1_0000_5000（截断后 0x0000_5000）
        //   要求：load ⇒ cause 5，且**不发数据请求**、不填充别名翻译。
        //======================================================================
        vec_begin("MMU_PA34_LEAF4K");
        clr_counters;
        do_sfence(32'h0, 9'h0, 1'b1, 1'b1);
        setup_std(VA_A, 1'b1, 1'b1, 1'b1, 1'b0, 1'b1);
        set_l0_leaf(VA_A, L0_PPN, 22'h100005, 1'b1, 1'b1, 1'b0, 1'b0, 1'b0, 1'b1, 1'b1);
        walk(VA_A, ACC_LOAD, PRIV_S, 1'b0, 1'b0, f, c, p);
        chk1("MMU_PA34_LEAF4K", f, 1'b1);
        chk32("MMU_PA34_LEAF4K", {27'b0, c}, {27'b0, C_LOAD_AF});
        chk32("MMU_PA34_LEAF4K", n_pte_req, 32'd2);       // 两级 PTE 读合法且发生
        chk32("MMU_PA34_LEAF4K", n_data_req, 32'd0);      // 绝不访问低地址别名
        tlb_probe(VA_A, ACC_LOAD, PRIV_S, 1'b0, 1'b0, h, pf, p2);
        chk1("MMU_PA34_LEAF4K", h, 1'b0);

        //======================================================================
        // V13 ★ MMU_PA34_LEAF4M：4 MiB 大页 PPN[1] 高位非零
        //   PPN = 22'h200000（PPN[1]=0x800）⇒ PA = 0x2_0000_0000
        //======================================================================
        vec_begin("MMU_PA34_LEAF4M");
        clr_counters;
        do_sfence(32'h0, 9'h0, 1'b1, 1'b1);
        set_big_leaf(VA_A, 22'h200000, 1'b1, 1'b1, 1'b0, 1'b1, 1'b1, 1'b0);
        walk(VA_A, ACC_LOAD, PRIV_S, 1'b0, 1'b0, f, c, p);
        chk1("MMU_PA34_LEAF4M", f, 1'b1);
        chk32("MMU_PA34_LEAF4M", {27'b0, c}, {27'b0, C_LOAD_AF});
        chk32("MMU_PA34_LEAF4M", n_data_req, 32'd0);
        tlb_probe(VA_A, ACC_LOAD, PRIV_S, 1'b0, 1'b0, h, pf, p2);
        chk1("MMU_PA34_LEAF4M", h, 1'b0);

        //======================================================================
        // V14a MMU_PA34_PRIO_PERM（独审 P1①）：高 PA 与**权限**叠加时，
        //   page-fault 判据（权限/U 位）必须先于高 PA 的 access fault。
        //======================================================================
        vec_begin("CTRL_PA34_PRIO_PERM");
        clr_counters;
        do_sfence(32'h0, 9'h0, 1'b1, 1'b1);
        satp_v = 32'h8000_0000 | ROOT_PPN;
        asid_v = 9'h0;
        //   U 模式 load 到 U=0 的高 PPN 页 ⇒ PF13（不是 AF5）
        set_root_ptr(L0_PPN, 1'b0);
        set_l0_leaf(VA_A, L0_PPN, 22'h100005, 1'b1, 1'b1, 1'b0, 1'b0, 1'b0, 1'b1, 1'b1);
        walk(VA_A, ACC_LOAD, PRIV_U, 1'b0, 1'b0, f, c, p);
        chk1("CTRL_PA34_PRIO_PERM", f, 1'b1);
        chk32("CTRL_PA34_PRIO_PERM", {27'b0, c}, {27'b0, C_LOAD_PF});
        //   S 模式 store 到只读（W=0）高 PPN 页 ⇒ PF15（不是 AF7）
        set_l0_leaf(VA_A, L0_PPN, 22'h100005, 1'b1, 1'b1, 1'b0, 1'b0, 1'b0, 1'b0, 1'b1);
        walk(VA_A, ACC_STORE, PRIV_S, 1'b0, 1'b0, f, c, p);
        chk1("CTRL_PA34_PRIO_PERM", f, 1'b1);
        chk32("CTRL_PA34_PRIO_PERM", {27'b0, c}, {27'b0, C_STORE_PF});
        //   S 模式取指到 X=0 的高 PPN 页 ⇒ PF12（不是 AF1）
        walk(VA_A, ACC_FETCH, PRIV_S, 1'b0, 1'b0, f, c, p);
        chk1("CTRL_PA34_PRIO_PERM", f, 1'b1);
        chk32("CTRL_PA34_PRIO_PERM", {27'b0, c}, {27'b0, C_INSN_PF});

        //======================================================================
        // V14b CTRL_PA34_AF_LEGAL：**权限合法**时高 PA 才报原访问类型 AF（1/5/7）
        //======================================================================
        vec_begin("MMU_PA34_AF_LEGAL");
        clr_counters;
        set_l0_leaf(VA_A, L0_PPN, 22'h100005, 1'b1, 1'b1, 1'b0, 1'b0, 1'b1, 1'b1, 1'b1); // RWX
        walk(VA_A, ACC_FETCH, PRIV_S, 1'b0, 1'b0, f, c, p);
        chk1("MMU_PA34_AF_LEGAL", f, 1'b1);
        chk32("MMU_PA34_AF_LEGAL", {27'b0, c}, {27'b0, C_INSN_AF});
        walk(VA_A, ACC_LOAD, PRIV_S, 1'b0, 1'b0, f, c, p);
        chk1("MMU_PA34_AF_LEGAL", f, 1'b1);
        chk32("MMU_PA34_AF_LEGAL", {27'b0, c}, {27'b0, C_LOAD_AF});
        walk(VA_A, ACC_STORE, PRIV_S, 1'b0, 1'b0, f, c, p);
        chk1("MMU_PA34_AF_LEGAL", f, 1'b1);
        chk32("MMU_PA34_AF_LEGAL", {27'b0, c}, {27'b0, C_STORE_AF});
        chk32("MMU_PA34_AF_LEGAL", n_data_req, 32'd0);   // 任何 AF 都不得产生数据访问

        //======================================================================
        // V14c MMU_PA34_SVADE（独审 P1①）：高 PA 叠加 Svade 的 A/D 缺失
        //   ⇒ 仍是 page-fault（A=0 ⇒ PF13；写且 D=0 ⇒ PF15），不是 AF。
        //======================================================================
        vec_begin("CTRL_PA34_SVADE");
        clr_counters;
        do_sfence(32'h0, 9'h0, 1'b1, 1'b1);
        //   A=0 + 高 PPN ⇒ PF13（load）
        set_l0_leaf(VA_A, L0_PPN, 22'h100005, 1'b1, 1'b0, 1'b0, 1'b0, 1'b0, 1'b1, 1'b1);
        walk(VA_A, ACC_LOAD, PRIV_S, 1'b0, 1'b0, f, c, p);
        chk1("CTRL_PA34_SVADE", f, 1'b1);
        chk32("CTRL_PA34_SVADE", {27'b0, c}, {27'b0, C_LOAD_PF});
        //   A=1,D=0 + 高 PPN ⇒ store PF15（Svade 的 D 检查先于 AF）
        set_l0_leaf(VA_A, L0_PPN, 22'h100005, 1'b0, 1'b1, 1'b0, 1'b0, 1'b0, 1'b1, 1'b1);
        walk(VA_A, ACC_STORE, PRIV_S, 1'b0, 1'b0, f, c, p);
        chk1("CTRL_PA34_SVADE", f, 1'b1);
        chk32("CTRL_PA34_SVADE", {27'b0, c}, {27'b0, C_STORE_PF});
        chk32("CTRL_PA34_SVADE", n_data_req, 32'd0);

        //======================================================================
        // V17 CTRL_PA_LOW：对照 —— 同样的 VA，只有 PPN 高位不同 ⇒ 正常成功
        //   （证明 V10–V13 的差异只来自"34 bit 高位"，不是把大 PPN 一律拒掉）
        //======================================================================
        vec_begin("CTRL_PA_LOW");
        clr_counters;
        do_sfence(32'h0, 9'h0, 1'b1, 1'b1);
        setup_std(VA_A, 1'b1, 1'b1, 1'b1, 1'b0, 1'b1);
        walk(VA_A, ACC_LOAD, PRIV_S, 1'b0, 1'b0, f, c, p);
        chk1("CTRL_PA_LOW", f, 1'b0);
        chk32("CTRL_PA_LOW", p, 32'h0005_0000);
        data_access(p, 1'b0);
        chk32("CTRL_PA_LOW", last_data_pa, 32'h0005_0000);
        chk32("CTRL_PA_LOW", n_data_req, 32'd1);

        //======================================================================
        // V15 ★ MMU_CBM_RO_PTW（04-06）：只读页（R=1,W=0,A=1,D=0）上的 CBM
        //   [norm:cbm_access]：load **或** store 允许即可 ⇒ 必须成功；
        //   [NOTE]：不检查 D。旧实现按 store 判 ⇒ page fault。
        //======================================================================
        vec_begin("MMU_CBM_RO_PTW");
        clr_counters;
        do_sfence(32'h0, 9'h0, 1'b1, 1'b1);
        setup_std(VA_A, 1'b0, 1'b1, 1'b0, 1'b0, 1'b1);   // RO, A=1, D=0
        walk(VA_A, ACC_CBM, PRIV_S, 1'b0, 1'b0, f, c, p);
        chk1("MMU_CBM_RO_PTW", f, 1'b0);
        chk32("MMU_CBM_RO_PTW", p, 32'h0005_0000);

        //======================================================================
        // V16 ★ MMU_CBM_RO_TLB：同一只读项经 **TLB 命中** 执行 CBM
        //======================================================================
        vec_begin("MMU_CBM_RO_TLB");
        clr_counters;
        do_sfence(32'h0, 9'h0, 1'b1, 1'b1);
        setup_std(VA_A, 1'b0, 1'b1, 1'b0, 1'b0, 1'b1);   // RO, A=1, D=0
        walk(VA_A, ACC_LOAD, PRIV_S, 1'b0, 1'b0, f, c, p);
        chk1("CTRL_CBM_FILL", f, 1'b0);
        clr_counters;
        tlb_probe(VA_A, ACC_CBM, PRIV_S, 1'b0, 1'b0, h, pf, p2);
        chk1("MMU_CBM_RO_TLB", h, 1'b1);
        chk1("MMU_CBM_RO_TLB", pf, 1'b0);
        chk32("MMU_CBM_RO_TLB", p2, 32'h0005_0000);
        chk32("MMU_CBM_RO_TLB", n_pte_req, 32'd0);

        //======================================================================
        // V17 ★ MMU_CBM_D_CHECK：可写页但 D=0 上的 CBM ⇒ 必须成功（不查 D）
        //======================================================================
        vec_begin("MMU_CBM_D_CHECK");
        clr_counters;
        do_sfence(32'h0, 9'h0, 1'b1, 1'b1);
        setup_std(VA_A, 1'b0, 1'b1, 1'b1, 1'b0, 1'b1);   // RW, A=1, D=0
        walk(VA_A, ACC_CBM, PRIV_S, 1'b0, 1'b0, f, c, p);
        chk1("MMU_CBM_D_CHECK", f, 1'b0);
        chk32("MMU_CBM_D_CHECK", p, 32'h0005_0000);
        tlb_probe(VA_A, ACC_CBM, PRIV_S, 1'b0, 1'b0, h, pf, p2);
        chk1("MMU_CBM_D_CHECK", h, 1'b1);

        //======================================================================
        // V18 CTRL_CBM_A0：A=0 页上的 CBM ⇒ page fault（查 A），cause 15
        //======================================================================
        vec_begin("CTRL_CBM_A0");
        clr_counters;
        do_sfence(32'h0, 9'h0, 1'b1, 1'b1);
        setup_std(VA_A, 1'b0, 1'b1, 1'b0, 1'b0, 1'b0);   // RO, A=0
        walk(VA_A, ACC_CBM, PRIV_S, 1'b0, 1'b0, f, c, p);
        chk1("CTRL_CBM_A0", f, 1'b1);
        chk32("CTRL_CBM_A0", {27'b0, c}, {27'b0, C_STORE_PF});
        tlb_probe(VA_A, ACC_CBM, PRIV_S, 1'b0, 1'b0, h, pf, p2);
        chk1("CTRL_CBM_A0", h, 1'b0);

        //======================================================================
        // V19 CTRL_CBM_RESERVED：R=0,W=1 是 Sv32 **非法编码**，CBM 也不得放行
        //   （"R0W1 不可当合法可写页"）
        //======================================================================
        vec_begin("CTRL_CBM_RESERVED");
        clr_counters;
        do_sfence(32'h0, 9'h0, 1'b1, 1'b1);
        set_root_ptr(L0_PPN, 1'b0);
        set_l0_leaf(VA_A, L0_PPN, DATA_PPN, 1'b1, 1'b1, 1'b0, 1'b0, 1'b0, 1'b1, 1'b0);
        walk(VA_A, ACC_CBM, PRIV_S, 1'b0, 1'b0, f, c, p);
        chk1("CTRL_CBM_RESERVED", f, 1'b1);
        chk32("CTRL_CBM_RESERVED", {27'b0, c}, {27'b0, C_STORE_PF});
        walk(VA_A, ACC_STORE, PRIV_S, 1'b0, 1'b0, f, c, p);
        chk1("CTRL_CBM_RESERVED", f, 1'b1);
        chk32("CTRL_CBM_RESERVED", {27'b0, c}, {27'b0, C_STORE_PF});

        //======================================================================
        // V20 CTRL_STORE_RO：对照 —— 同一只读页上的 store 必须 page fault（15）
        //======================================================================
        vec_begin("CTRL_STORE_RO");
        clr_counters;
        do_sfence(32'h0, 9'h0, 1'b1, 1'b1);
        setup_std(VA_A, 1'b1, 1'b1, 1'b0, 1'b0, 1'b1);   // RO, A=1, D=1
        walk(VA_A, ACC_STORE, PRIV_S, 1'b0, 1'b0, f, c, p);
        chk1("CTRL_STORE_RO", f, 1'b1);
        chk32("CTRL_STORE_RO", {27'b0, c}, {27'b0, C_STORE_PF});
        walk(VA_A, ACC_LOAD, PRIV_S, 1'b0, 1'b0, f, c, p);
        chk1("CTRL_STORE_RO", f, 1'b0);                   // load 仍可读

        //======================================================================
        // V21 ★ MMU_LSU_CBM_RO：lsu 的 CBM PMP 权限 = load OR store
        //   PMP 只读区（L=1,R=1,W=0）上的 cbo.clean ⇒ **必须放行**（旧实现按 W 判 ⇒ 拒）
        //======================================================================
        vec_begin("MMU_LSU_CBM_RO");
        lsu_pmp_clear;
        lsu_pmp_na4(0, 32'h0000_E000, 1'b1, 1'b0, 1'b0);  // 只读
        lsu_eval(LK_CBO, 32'h0000_E000, PRIV_S, `RV32GC_CBO_CLEAN);
        chk1("MMU_LSU_CBM_RO", lsu_exc, 1'b0);
        chk1("MMU_LSU_CBM_RO", lsu_pmp_deny, 1'b0);
        chk1("MMU_LSU_CBM_RO", lsu_beat0_ok, 1'b1);
        lsu_req_valid = 1'b0;
        #1;

        //======================================================================
        // V22 CTRL_LSU_CBM_WO：PMP 只写区（L=1,R=0,W=1）上的 CBM 也必须放行
        //   （store 侧允许即够；旧实现在此处**恰好**也放行 ⇒ 属合法控制标签）
        //======================================================================
        vec_begin("CTRL_LSU_CBM_WO");
        lsu_pmp_clear;
        lsu_pmp_na4(0, 32'h0000_E000, 1'b0, 1'b1, 1'b0);  // 只写
        lsu_eval(LK_CBO, 32'h0000_E000, PRIV_S, `RV32GC_CBO_FLUSH);
        chk1("CTRL_LSU_CBM_WO", lsu_exc, 1'b0);
        chk1("CTRL_LSU_CBM_WO", lsu_beat0_ok, 1'b1);
        lsu_req_valid = 1'b0;
        #1;

        //======================================================================
        // V23 ★ MMU_LSU_NEED_PERM：CBM 的 need_perm 必须是 R（load 口径）
        //======================================================================
        vec_begin("MMU_LSU_NEED_PERM");
        lsu_pmp_clear;
        lsu_pmp_na4(0, 32'h0000_E000, 1'b1, 1'b1, 1'b0);
        lsu_eval(LK_CBO, 32'h0000_E000, PRIV_S, `RV32GC_CBO_INVAL);
        chk32("MMU_LSU_NEED_PERM", {30'b0, lsu_need_perm}, 32'h2);   // {R,W} = 10
        lsu_req_valid = 1'b0;
        #1;

        //======================================================================
        // V24 CTRL_LSU_CBM_DENY：R/W 全拒（只给 X）⇒ CBM 拒且 cause **恒 7**
        //======================================================================
        vec_begin("CTRL_LSU_CBM_DENY");
        lsu_pmp_clear;
        lsu_pmp_na4(0, 32'h0000_E000, 1'b0, 1'b0, 1'b1);  // 只给 X
        lsu_eval(LK_CBO, 32'h0000_E000, PRIV_S, `RV32GC_CBO_CLEAN);
        chk1("CTRL_LSU_CBM_DENY", lsu_exc, 1'b1);
        chk32("CTRL_LSU_CBM_DENY", {27'b0, lsu_exc_cause}, {27'b0, C_STORE_AF});
        lsu_req_valid = 1'b0;
        #1;

        //======================================================================
        // V25 CTRL_LSU_STORE_RO：对照 —— 同一只读区上的 store 仍必须拒（cause 7）
        //   （证明 V21 的放行是 CBM 专属，不是把 PMP 放宽了）
        //======================================================================
        vec_begin("CTRL_LSU_STORE_RO");
        lsu_pmp_clear;
        lsu_pmp_na4(0, 32'h0000_E000, 1'b1, 1'b0, 1'b0);  // 只读
        lsu_eval(LK_STORE, 32'h0000_E000, PRIV_S, 5'd0);
        chk1("CTRL_LSU_STORE_RO", lsu_exc, 1'b1);
        chk32("CTRL_LSU_STORE_RO", {27'b0, lsu_exc_cause}, {27'b0, C_STORE_AF});
        lsu_req_valid = 1'b0;
        #1;

        //======================================================================
        // V27 CTRL_LOOKUP2_FETCH（独审 P2 边界）：TLB **第二查询口**（取指侧）
        //   最小正控：PTW 填充后取指查询必须命中且 PA 相同。
        //======================================================================
        vec_begin("CTRL_LOOKUP2_FETCH");
        clr_counters;
        do_sfence(32'h0, 9'h0, 1'b1, 1'b1);
        //   取指要求 X=1（S 模式不得在 U=1 页执行）⇒ 用 RWX、A=1、D=0 的页
        setup_std(VA_A, 1'b0, 1'b1, 1'b1, 1'b1, 1'b1);   // R=1,W=1,X=1, A=1, D=0
        asid_v = 9'h0;
        walk(VA_A, ACC_FETCH, PRIV_S, 1'b0, 1'b0, f, c, p);
        chk1("CTRL_LOOKUP2_FETCH", f, 1'b0);
        tlb_probe2(VA_A, ACC_FETCH, PRIV_S, 1'b0, 1'b0, h, pf, p2);
        chk1("CTRL_LOOKUP2_FETCH", h, 1'b1);
        chk1("CTRL_LOOKUP2_FETCH", pf, 1'b0);
        chk32("CTRL_LOOKUP2_FETCH", p2, 32'h0005_0000);
        //   取指口同样做 A/D 复核：A=1、D=0 的项对取指**允许**（不查 D）
        do_sfence(32'h0, 9'h0, 1'b1, 1'b1);
        setup_std(VA_A, 1'b0, 1'b1, 1'b1, 1'b1, 1'b1);
        walk(VA_A, ACC_LOAD, PRIV_S, 1'b0, 1'b0, f, c, p);
        chk1("CTRL_LOOKUP2_FETCH", f, 1'b0);
        tlb_probe2(VA_A, ACC_FETCH, PRIV_S, 1'b0, 1'b0, h, pf, p2);
        chk1("CTRL_LOOKUP2_FETCH", h, 1'b1);             // fetch 不查 D

        //======================================================================
        // V28 CTRL_LOOKUP2_D0（独审 P2 边界）：第二查询口的 D/A 口径
        //   同一 A=1,D=0 表项：store 查询 ⇒ perm_fault；CBM 查询 ⇒ 命中
        //   （即 TLB 两端口共用同一套 A/D 复核逻辑）。
        //======================================================================
        vec_begin("MMU_LOOKUP2_D0");
        clr_counters;
        do_sfence(32'h0, 9'h0, 1'b1, 1'b1);
        setup_std(VA_A, 1'b0, 1'b1, 1'b1, 1'b0, 1'b1);   // RW, A=1, D=0
        walk(VA_A, ACC_LOAD, PRIV_S, 1'b0, 1'b0, f, c, p);
        chk1("MMU_LOOKUP2_D0", f, 1'b0);
        tlb_probe2(VA_A, ACC_STORE, PRIV_S, 1'b0, 1'b0, h, pf, p2);
        chk1("MMU_LOOKUP2_D0", pf, 1'b1);               // store 且 D=0 ⇒ page fault
        chk1("MMU_LOOKUP2_D0", h, 1'b0);
        tlb_probe2(VA_A, ACC_CBM, PRIV_S, 1'b0, 1'b0, h, pf, p2);
        chk1("MMU_LOOKUP2_D0", h, 1'b1);                // CBM 不查 D
        chk1("MMU_LOOKUP2_D0", pf, 1'b0);

        //======================================================================
        // V29 CTRL_LSU_LOAD_WO：对照 —— 同一只写区上的 load 仍必须拒（cause 5）
        //======================================================================
        vec_begin("CTRL_LSU_LOAD_WO");
        lsu_pmp_clear;
        lsu_pmp_na4(0, 32'h0000_E000, 1'b0, 1'b1, 1'b0);  // 只写
        lsu_eval(LK_LOAD, 32'h0000_E000, PRIV_S, 5'd0);
        chk1("CTRL_LSU_LOAD_WO", lsu_exc, 1'b1);
        chk32("CTRL_LSU_LOAD_WO", {27'b0, lsu_exc_cause}, {27'b0, C_LOAD_AF});
        lsu_req_valid = 1'b0;
        #1;

        //======================================================================
        // 汇总
        //======================================================================
        settle_vec;                                        // 结算最后一个向量
        $display("FUNCTIONAL_MMU_VECTORS total=%0d checks=%0d fails=%0d",
                 SPEC_VECTORS, vec_sum_checks, n_fail);
        if (n_vec !== SPEC_VECTORS) begin
            $display("MMU FAIL [SPEC]: vectors=%0d expect=%0d", n_vec, SPEC_VECTORS);
            $fatal(1, "FUNCTIONAL_MMU: FAIL");
        end
        if (n_fail != 0) begin
            $fatal(1, "FUNCTIONAL_MMU: FAIL");
        end
        if (vec_sum_checks <= 0) begin
            $display("MMU FAIL [NO_CHECKS]: checks=0");
            $fatal(1, "FUNCTIONAL_MMU: FAIL");
        end
        sim_ok = 1'b1;
        $finish;
    end

    initial begin
        #2000000;
        $display("MMU FAIL [TIMEOUT]: 未在预算内完成");
        $fatal(1, "FUNCTIONAL_MMU: FAIL");
    end

    //--------------------------------------------------------------------------
    // PASS 横幅（唯一 PASS 字样，且保证是输出的**最后一行**）
    //   fail-closed：sim_ok 只有走完全部向量且 n_fail==0 时才置 1。
    //--------------------------------------------------------------------------
    final begin
        if (sim_ok && (n_fail == 0) && (vec_sum_checks > 0))
            $display("FUNCTIONAL_MMU: PASS");
    end

endmodule
