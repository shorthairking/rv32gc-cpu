//==============================================================================
// sim/functional/tb_privilege_semantics.sv
//   —— F1 特权模块（csr_file × priv_ctrl × trap_ctrl）功能级正反证用例
//==============================================================================
// 目的 : 用**同一份** TB 对两个源码根（DUT_ROOT）编译运行做对照：
//          · 当前（已修）源码 ⇒ 全部向量通过，打印机读摘要
//            `FUNCTIONAL_PRIVILEGE_VECTORS total=42 checks=<C> fails=0`、42 行
//            `VEC <i> checks=<d> fails=0` 与唯一整行 `FUNCTIONAL_PRIVILEGE: PASS`；
//          · 冻结基线 201acf61 ⇒ 定向缺陷标签必须触发 `PRIV FAIL [TAG]`（反向 oracle），
//            摘要 fails>0，退出码非 0，且**不**打印 PASS。
//        本 TB 只例化 rtl/csr/{csr_file,priv_ctrl,trap_ctrl}.v（本包依赖），不涉及其它 RTL 域。
//
// 机读输出契约（test_privilege.sh 严格解析；同前缀必须唯一）:
//   · `VEC <i> checks=<d> fails=<d>`：第 i 个向量结算行（i = 1..SPEC_VECTORS，恰各一次）；
//   · `FUNCTIONAL_PRIVILEGE_VECTORS total=<d> checks=<d> fails=<d>`：总摘要
//     （total 必须 == 42；checks == 各向量 checks 之和；fails == 0 才 PASS）；
//   · `FUNCTIONAL_PRIVILEGE: PASS`：仅当 total/逐向量/全局检查全过时打印（唯一 PASS 子串）。
//   失败行统一为 `PRIV FAIL [TAG]: ...`；每个向量在 TB 内自判"至少 1 项检查"
//   （缺检查 ⇒ `PRIV FAIL [VEC_EMPTY]` 且该向量行 fails=1）。
//
// 覆盖的根因（见 sim/audit/global-2026-10-18/01-privilege.md 与首轮独审 P1）:
//   · P0-02 PMP 写锁 = 本项 L 或后项 (L && A=TOR)，覆盖 i=0/中间/15 边界、后项非 TOR 不锁；
//   · P1-01 counteren：cycle/time/instret + 高半影子按 M/S/U 受 mcounteren/scounteren 门控；
//   · P1-02 TVM：S 访问 satp 在 TVM=1 时非法（M 不受限）；
//   · P1-05 sie/sip 为按 mideleg 受限别名（读/写都掩码，不清改未委托底层位），
//     且**两路预览 rdata_w / byp_rdata 与落盘实际读取逐位一致**（含委托同拍变化）；
//   · P1-04 未委托 SSI/STI/SEI 成为 M 目标候选（每 bit 先定目标再全局 IE；cause 保持源号），
//     且选中优先级 = **目标特权级 M 优先，再组内源序**；
//   · P1-06 priv_ctrl 同拍旁路为**替换**语义（能 1→0 清 MIE/SIE/MPRV/MPP/SUM/MXR/TVM/TW/TSR）。
//
// 标签口径 : 失败行统一为 `PRIV FAIL [TAG]: msg`。
//   · 缺陷标签（旧基线必须触发，两树区分）: PMP_OWN_L / PMP_MID_OWN_L / PMP_I15_OWN_L /
//     CNTR_S_DISABLED / CNTR_U_SCNT_DIS / CNTR_HALF_SHADOW / TVM_S_ILL /
//     SIE_ALIAS_READ / SIE_ALIAS_WRITE / SIE_PARTIAL_DELEG / SIP_ALIAS_READ /
//     SIP_UNDELEG_WRITE / SIP_PARTIAL_DELEG / IRQ_UNDELEG_M / IRQ_SRC_S_TO_M /
//     IRQ_SSI_U_TO_M / BYP_MPRV_1TO0 / BYP_SSTATUS_MASK / BYP_MPP_S_TO_U / BYP_MIE_1TO0 /
//     IRQ_MFIRST_U / IRQ_MFIRST_S / SIE_PREVIEW_DELEG / SIE_PREVIEW_PARTIAL /
//     SIP_PREVIEW_DELEG / SIE_PREVIEW_MIDELEG_SAME / MSTATUS_SD_DIRTY；
//   · 合法控制标签（两实现都必须通过，前缀 `CTRL_`）：PMP_SUCC_TOR / PMP_SUCC_NONTOR /
//     PMP_I15_PRED_FREE / CNTR_M_FREE / CNTR_S_ENABLED / CNTR_U_BOTH_EN / TVM_M_OK /
//     TVM_CLEARED_OK / SIP_DELEG_WRITE / IRQ_M_GATED / IRQ_DELEG_S / IRQ_DELEG_M_MASK /
//     IRQ_PRIORITY / IRQ_SGROUP_PRI / BYP_MPP_WARL / SIE_PREVIEW_FULL / SIP_PREVIEW_FULL
//     （SIE_PARTIAL_KEEP 等辅助检查行也随对应向量出现）。
//
// 判定 : 每个向量至少 1 条 `!==`（四态安全）实断言；任一失败 ⇒ 末尾 $fatal(1)，
//        **绝不**打印 PASS；全部通过才打印机读摘要与唯一 PASS 锚点。
// 顶层 : tb_privilege_semantics
//==============================================================================
`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"

module tb_privilege_semantics;

    //--------------------------------------------------------------------------
    // 冻结规格：向量总数（改动 TB 必须同步 test_privilege.sh 的 SPEC_VECTORS）
    //--------------------------------------------------------------------------
    localparam integer SPEC_VECTORS = 42;

    //--------------------------------------------------------------------------
    // 时钟 / 复位
    //--------------------------------------------------------------------------
    reg clk = 0;
    reg rst_n = 0;
    always #5 clk = ~clk;

    //--------------------------------------------------------------------------
    // 检查计数与失败/计分（fail-closed）
    //--------------------------------------------------------------------------
    integer n_pass = 0;
    integer n_fail = 0;
    integer n_vec  = 0;
    // ---- 逐向量记账（"每向量至少 1 项检查"的 TB 内自判）----
    integer vec_chk_base  = 0;
    integer vec_fail_base = 0;
    integer vec_sum_checks = 0;

    // 结算上一个向量：打印 `VEC <i> checks=<d> fails=<d>`；
    // 若该向量一项检查都没有 ⇒ 记一条 `PRIV FAIL [VEC_EMPTY]`（fail-closed）。
    task settle_vec;
        integer c;
        integer f;
        begin
            c = (n_pass + n_fail) - vec_chk_base;
            f = n_fail - vec_fail_base;
            if (c <= 0) begin
                f = f + 1;
                n_fail = n_fail + 1;
                $display("PRIV FAIL [VEC_EMPTY]: vector %0d checks=0", n_vec);
            end
            vec_sum_checks = vec_sum_checks + c;
            $display("VEC %0d checks=%0d fails=%0d", n_vec, c, f);
        end
    endtask

    // 开始一个新向量（自动结算上一个）
    task vec_begin;
        begin
            if (n_vec > 0) settle_vec;
            n_vec = n_vec + 1;
            vec_chk_base  = n_pass + n_fail;
            vec_fail_base = n_fail;
        end
    endtask

    task chk32;
        input [8*40-1:0] tag;
        input [31:0]     got;
        input [31:0]     exp;
        begin
            if (got !== exp) begin
                n_fail = n_fail + 1;
                $display("PRIV FAIL [%0s]: got=0x%08x exp=0x%08x (t=%0t)", tag, got, exp, $time);
            end else n_pass = n_pass + 1;
        end
    endtask

    task chk1;
        input [8*40-1:0] tag;
        input            got;
        input            exp;
        begin
            if (got !== exp) begin
                n_fail = n_fail + 1;
                $display("PRIV FAIL [%0s]: got=%0b exp=%0b (t=%0t)", tag, got, exp, $time);
            end else n_pass = n_pass + 1;
        end
    endtask

    //--------------------------------------------------------------------------
    // DUT 连接：csr_file × priv_ctrl × trap_ctrl（与 core_top 同口径的真实回路）
    //--------------------------------------------------------------------------
    reg  [11:0] raddr = 12'h0;
    wire [31:0] rdata;
    reg         wen = 0;
    reg  [11:0] waddr = 12'h0;
    reg  [31:0] wdata = 32'h0;
    reg         w_illegal = 0;
    wire [31:0] rdata_w;
    reg  [31:0] byp_wdata = 32'h0;   // M 级旁路预览输入（更年轻写）
    wire [31:0] byp_rdata;           // M 级旁路预览输出
    reg  [11:0] chk_addr = 12'h0;
    wire        chk_illegal, chk_ro_write;
    wire [31:0] mstatus_o;
    wire [31:0] pc_set, pc_clr;
    reg  [3:0]  trap_we = 4'h0;
    reg  [31:0] trap_epc_i = 32'h0, trap_cause_i = 32'h0;
    reg  [31:0] trap_tval_i = 32'h0, trap_data_i = 32'h0;
    wire [127:0] pmp_cfg_o;
    wire [511:0] pmp_addr_o;
    wire [31:0] satp_o, menvcfg_o, senvcfg_o, mcounteren_o, scounteren_o;
    wire [31:0] mtvec_o, stvec_o, medeleg_o, mideleg_o, mie_o, mip_o;
    // ---- M 级 pending 由核内设备驱动（MIP.MEIP/MTIP/MSIP 只读）：TB 显式驱动 ----
    reg         irq_msip_t = 1'b0, irq_mtip_t = 1'b0, irq_meip_t = 1'b0;

    csr_file dut (
        .clk(clk), .rst_n(rst_n),
        .raddr(raddr), .rdata(rdata),
        .wen(wen), .waddr(waddr), .wdata(wdata), .w_illegal(w_illegal),
        .rdata_w(rdata_w),
        .byp_wdata(byp_wdata), .byp_rdata(byp_rdata),
        .priv(pc_priv_o),
        .chk_addr(chk_addr), .chk_illegal(chk_illegal), .chk_ro_write(chk_ro_write),
        .mstatus_o(mstatus_o),
        .mstatus_set(pc_set), .mstatus_clr(pc_clr),
        .trap_we(trap_we), .trap_epc_i(trap_epc_i), .trap_cause_i(trap_cause_i),
        .trap_tval_i(trap_tval_i), .trap_data_i(trap_data_i),
        .irq_msip(irq_msip_t), .irq_mtip(irq_mtip_t), .irq_meip(irq_meip_t),
        .irq_stip(1'b0), .irq_seip(1'b0),
        .cycle_i(64'h0000_0001_CAFE_0000), .instret_i(64'h0000_0002_1234_0000),
        // ★ F1-B 新计数器端口：仅当前树连接；冻结基线 201acf61 的 csr_file 无这些端口，
        //   --check-baseline 以 -DRV32_CSR_NO_CNT_PORTS 编译本 TB（只为端口兼容，
        //   本包各向量不读 time 数据，语义不变）。
`ifndef RV32_CSR_NO_CNT_PORTS
        .mtime_i(64'h0000_00AA_BBCC_DDEE),
        .mcycle_we_o(), .mcycleh_we_o(), .minstret_we_o(), .minstreth_we_o(),
        .cnt_wdata_o(),
`endif
        .pmp_cfg_o(pmp_cfg_o), .pmp_addr_o(pmp_addr_o),
        .satp_o(satp_o), .menvcfg_o(menvcfg_o), .senvcfg_o(senvcfg_o),
        .mcounteren_o(mcounteren_o), .scounteren_o(scounteren_o),
        .mtvec_o(mtvec_o), .stvec_o(stvec_o),
        .medeleg_o(medeleg_o), .mideleg_o(mideleg_o),
        .mie_o(mie_o), .mip_o(mip_o)
    );

    // ---- priv_ctrl：架构特权级 + 同拍旁路（csr_wen 由 TB 作为"提交写"驱动）----
    reg         pc_trap_valid = 1'b0;
    reg  [1:0]  pc_trap_target = `RV32GC_PRIV_M;
    reg         pc_xret_valid = 1'b0;
    reg  [1:0]  pc_xret_kind = 2'b01;
    reg         p_csr_wen = 1'b0;
    reg  [11:0] p_csr_waddr = 12'h0;
    reg  [31:0] p_csr_wdata = 32'h0;
    wire [1:0]  pc_priv_o, pc_eff_priv_o, pc_priv_next_o, pc_mpp_o;
    wire        pc_mprv_o, pc_sum_o, pc_mxr_o, pc_tvm_o, pc_tw_o, pc_tsr_o;
    wire        pc_fetch_m, pc_flush_req, pc_stub_unused;

    priv_ctrl u_pc (
        .clk(clk), .rst_n(rst_n),
        .trap_valid(pc_trap_valid), .trap_target(pc_trap_target),
        .xret_valid(pc_xret_valid), .xret_kind(pc_xret_kind),
        .mstatus_i(mstatus_o), .csr_wen(p_csr_wen),
        .csr_waddr(p_csr_waddr), .csr_wdata(p_csr_wdata),
        .mstatus_set(pc_set), .mstatus_clr(pc_clr),
        .priv_o(pc_priv_o), .eff_priv_o(pc_eff_priv_o), .mprv_o(pc_mprv_o),
        .sum_o(pc_sum_o), .mxr_o(pc_mxr_o), .mpp_o(pc_mpp_o),
        .tvm_o(pc_tvm_o), .tw_o(pc_tw_o), .tsr_o(pc_tsr_o),
        .fetch_priv_is_m_o(pc_fetch_m), .flush_req(pc_flush_req),
        .priv_next_o(pc_priv_next_o)
    );

    // ---- trap_ctrl：中断目标判定（priv 取真实架构特权级；CSR 配置取真实存储）----
    reg  [31:0] commit_pc = 32'h8000_3000;
    reg  [31:0] commit_pc_next = 32'h8000_3004;
    reg  [31:0] commit_insn = 32'h0000_0073;
    wire        tc_trap_valid, tc_is_int;
    wire [1:0]  tc_target;
    wire [31:0] tc_cause, tc_tval, tc_epc, tc_pc, tc_redirect;
    wire [3:0]  tc_we;
    wire [31:0] tc_epc_i, tc_cause_i, tc_tval_i, tc_data_i;
    wire        tc_wm_epc, tc_wm_cause, tc_wm_tval, tc_ws_epc, tc_ws_cause, tc_ws_tval;

    trap_ctrl u_tc (
        .commit_valid(1'b1), .commit_pc(commit_pc),
        .commit_pc_next(commit_pc_next), .commit_insn(commit_insn),
        .exc_valid(1'b0), .exc_cause(5'd0), .exc_tval(32'h0), .exc_is_fetch(1'b0),
        .priv(pc_priv_o), .medeleg(medeleg_o), .mideleg(mideleg_o),
        .mip(mip_o), .mie(mie_o), .mstatus_i(mstatus_o),
        .mtvec(mtvec_o), .stvec(stvec_o),
        .trap_valid(tc_trap_valid), .trap_is_int(tc_is_int),
        .trap_target(tc_target), .trap_cause(tc_cause),
        .trap_tval(tc_tval), .trap_epc(tc_epc), .trap_pc(tc_pc),
        .trap_we(tc_we), .trap_epc_i(tc_epc_i), .trap_cause_i(tc_cause_i),
        .trap_tval_i(tc_tval_i), .trap_data_i(tc_data_i),
        .trap_wr_m_epc(tc_wm_epc), .trap_wr_m_cause(tc_wm_cause),
        .trap_wr_m_tval(tc_wm_tval),
        .trap_wr_s_epc(tc_ws_epc), .trap_wr_s_cause(tc_ws_cause),
        .trap_wr_s_tval(tc_ws_tval),
        .redirect_pc(tc_redirect)
    );

    assign pc_stub_unused = pc_fetch_m ^ pc_flush_req;

    //--------------------------------------------------------------------------
    // 通用激励
    //--------------------------------------------------------------------------
    // ---- CSR 写一拍（走真实提交写口；权限由 chk_illegal 单独表达）----
    task csr_write;
        input [11:0] addr;
        input [31:0] data;
        begin
            @(negedge clk);
            waddr = addr; wdata = data; wen = 1'b1; w_illegal = 1'b0;
            @(posedge clk); #1;
            @(negedge clk); wen = 1'b0;
            @(posedge clk); #1;
        end
    endtask

    // ---- 读 CSR 值（组合；供直接核对别名读视图）----
    task csr_read_val;
        input [11:0] addr;
        output [31:0] val;
        begin
            raddr = addr; #1; val = rdata;
        end
    endtask

    // ---- 复位（清 CSR + 特权级回 M）----
    task do_reset;
        begin
            rst_n = 0; repeat(4) @(posedge clk); #1;
            rst_n = 1; repeat(2) @(posedge clk); #1;
        end
    endtask

    // ---- 经真实 xRET 把架构特权级切到 target（只允许 M→S、M→U、S→U）----
    task goto_priv;
        input [1:0] tgt;
        begin
            if (pc_priv_o == `RV32GC_PRIV_M) begin
                // mret：xPP ← MPP，故先把 MPP 写成目标。
                csr_write(`RV32GC_CSR_MSTATUS,
                          (32'h0) | ({30'b0, tgt} << `RV32GC_MSTATUS_MPP_LSB));
                @(negedge clk); pc_xret_valid = 1'b1; pc_xret_kind = 2'b01;
                @(posedge clk); #1;
                @(negedge clk); pc_xret_valid = 1'b0; #1;
            end else begin
                // 当前 S → U：sret，SPP=0。
                csr_write(`RV32GC_CSR_SSTATUS, 32'h0);
                @(negedge clk); pc_xret_valid = 1'b1; pc_xret_kind = 2'b00;
                @(posedge clk); #1;
                @(negedge clk); pc_xret_valid = 1'b0; #1;
            end
        end
    endtask

    function [31:0] mstat;
        input m, s, mp, sp, spp, mprv, sum, mxr;
        input [1:0] mpp;
        begin
            mstat = ({31'b0, m}     << `RV32GC_MSTATUS_MIE_BIT)  |
                    ({31'b0, s}     << `RV32GC_MSTATUS_SIE_BIT)  |
                    ({31'b0, mp}    << `RV32GC_MSTATUS_MPIE_BIT) |
                    ({31'b0, sp}    << `RV32GC_MSTATUS_SPIE_BIT) |
                    ({31'b0, spp}   << `RV32GC_MSTATUS_SPP_BIT)  |
                    ({31'b0, mprv}  << `RV32GC_MSTATUS_MPRV_BIT) |
                    ({31'b0, sum}   << `RV32GC_MSTATUS_SUM_BIT)  |
                    ({31'b0, mxr}   << `RV32GC_MSTATUS_MXR_BIT)  |
                    ({30'b0, mpp}   << `RV32GC_MSTATUS_MPP_LSB);
        end
    endfunction

    //--------------------------------------------------------------------------
    // 主测试：32 个向量
    //--------------------------------------------------------------------------
    reg [31:0] rdv;

    initial begin
        $display("---- tb_privilege_semantics: F1 特权语义功能级正反证 ----");

        //======================================================================
        // V1..V5：PMP 写锁（P0-02）
        //======================================================================
        do_reset;

        // ---- V1：本项 L 锁本项 pmpaddr（i=0；A=NAPOT）----
        vec_begin;
        chk32("PRIVSW_INIT", {30'b0, pc_priv_o}, 32'h3);
        csr_write(`RV32GC_CSR_PMPCFG0, 32'h0000_009F);   // 项0 L=1 A=NAPOT RWX=7
        csr_write(`RV32GC_CSR_PMPADDR0, 32'h0000_1234);  // 本项 L ⇒ 必须被忽略
        csr_read_val(`RV32GC_CSR_PMPADDR0, rdv);
        chk32("PMP_OWN_L", rdv, 32'h0000_0000);
        chk_addr = `RV32GC_CSR_PMPADDR0; #1;
        chk1("CTRL_PMP_LOCK_SILENT", chk_illegal, 1'b0);   // 静默忽略：不抛非法
        chk1("CTRL_PMP_LOCK_NORO",   chk_ro_write, 1'b0);

        // ---- V2：中间项本项 L 锁本项（缺陷）；后项 (L&&TOR) 锁前驱（控制）----
        vec_begin;
        csr_write(`RV32GC_CSR_PMPCFG0, 32'h0000_889F);   // 项1 L=1 A=TOR（项0 已锁）
        csr_write(`RV32GC_CSR_PMPADDR1, 32'h0000_0077);  // 项1 本项 L ⇒ 忽略（旧树可写）
        csr_read_val(`RV32GC_CSR_PMPADDR1, rdv);
        chk32("PMP_MID_OWN_L", rdv, 32'h0000_0000);
        //   后项 TOR 锁前驱：用未被 V1 触碰、且旧树也能锁定的项 6/7（控制项）
        csr_write(`RV32GC_CSR_PMPCFG1, 32'h8800_0000);   // 项7 L=1 A=TOR，项6 L=0
        csr_write(`RV32GC_CSR_PMPADDR6, 32'h0000_00A5);
        csr_read_val(`RV32GC_CSR_PMPADDR6, rdv);
        chk32("CTRL_PMP_SUCC_TOR", rdv, 32'h0000_0000);

        // ---- V3：后项 L 但 A≠TOR ⇒ 不锁前驱（合法覆盖保留）----
        vec_begin;
        csr_write(`RV32GC_CSR_PMPCFG1, 32'h1F0F_9F0F);   // 项5 L=1 A=NAPOT
        csr_write(`RV32GC_CSR_PMPADDR4, 32'h0000_0BAD);
        csr_read_val(`RV32GC_CSR_PMPADDR4, rdv);
        chk32("CTRL_PMP_SUCC_NONTOR", rdv, 32'h0000_0BAD);

        // ---- V4：i=15 边界 —— 本项 L（A=OFF）仍锁 pmpaddr15 ----
        vec_begin;
        csr_write(`RV32GC_CSR_PMPCFG3, 32'h8000_0000);   // 项15 L=1 A=OFF
        csr_write(`RV32GC_CSR_PMPADDR15, 32'h0000_DEAD);
        csr_read_val(`RV32GC_CSR_PMPADDR15, rdv);
        chk32("PMP_I15_OWN_L", rdv, 32'h0000_0000);

        // ---- V5：i=15 的 A=OFF ⇒ 前驱 pmpaddr14 仍可写（控制）----
        vec_begin;
        csr_write(`RV32GC_CSR_PMPADDR14, 32'h0000_0BAD);
        csr_read_val(`RV32GC_CSR_PMPADDR14, rdv);
        chk32("CTRL_PMP_I15_PRED_FREE", rdv, 32'h0000_0BAD);

        //======================================================================
        // V6..V11：counteren（P1-01）
        //======================================================================
        do_reset;
        csr_write(`RV32GC_CSR_MCOUNTEREN, 32'h0000_0000);
        csr_write(`RV32GC_CSR_SCOUNTEREN, 32'h0000_0000);
        // ---- V6：M 不受门控（控制）----
        vec_begin;
        chk_addr = `RV32GC_CSR_CYCLE; #1;
        chk1("CTRL_CNTR_M_FREE", chk_illegal, 1'b0);
        chk_addr = `RV32GC_CSR_INSTRETH; #1;
        chk1("CTRL_CNTR_M_FREE_H", chk_illegal, 1'b0);

        goto_priv(`RV32GC_PRIV_S);
        // ---- V7：S + mcounteren=0 ⇒ 非法（旧树合法）----
        vec_begin;
        chk32("PRIVSW_S", {30'b0, pc_priv_o}, 32'h1);
        chk_addr = `RV32GC_CSR_CYCLE; #1;
        chk1("CNTR_S_DISABLED", chk_illegal, 1'b1);
        chk_addr = `RV32GC_CSR_TIME; #1;
        chk1("CNTR_S_DISABLED_TM", chk_illegal, 1'b1);
        chk_addr = `RV32GC_CSR_CYCLEH; #1;
        chk1("CNTR_S_DISABLED_H", chk_illegal, 1'b1);

        csr_write(`RV32GC_CSR_MCOUNTEREN, 32'h0000_0007);
        // ---- V8：S + mcounteren=7 ⇒ 合法（控制）----
        vec_begin;
        chk_addr = `RV32GC_CSR_CYCLE; #1;
        chk1("CTRL_CNTR_S_ENABLED", chk_illegal, 1'b0);
        chk_addr = `RV32GC_CSR_INSTRETH; #1;
        chk1("CTRL_CNTR_S_ENABLED_H", chk_illegal, 1'b0);

        csr_write(`RV32GC_CSR_SCOUNTEREN, 32'h0000_0000);
        goto_priv(`RV32GC_PRIV_U);
        // ---- V9：U + mcounteren=7 + scounteren=0 ⇒ 非法（旧树合法）----
        vec_begin;
        chk32("PRIVSW_U", {30'b0, pc_priv_o}, 32'h0);
        chk_addr = `RV32GC_CSR_CYCLE; #1;
        chk1("CNTR_U_SCNT_DIS", chk_illegal, 1'b1);
        chk_addr = `RV32GC_CSR_TIME; #1;
        chk1("CNTR_U_SCNT_DIS_TM", chk_illegal, 1'b1);

        csr_write(`RV32GC_CSR_SCOUNTEREN, 32'h0000_0007);
        // ---- V10：U + 两级全 1 ⇒ 合法（控制）----
        vec_begin;
        chk_addr = `RV32GC_CSR_CYCLE; #1;
        chk1("CTRL_CNTR_U_BOTH_EN", chk_illegal, 1'b0);
        chk_addr = `RV32GC_CSR_TIME; #1;
        chk1("CTRL_CNTR_U_BOTH_EN_TM", chk_illegal, 1'b0);

        csr_write(`RV32GC_CSR_SCOUNTEREN, 32'h0000_0001);   // 只使能 CY
        // ---- V11：U + 高半影子共用低位（TIMEH 需 TM，未使能 ⇒ 非法）----
        vec_begin;
        chk_addr = `RV32GC_CSR_TIMEH; #1;
        chk1("CNTR_HALF_SHADOW", chk_illegal, 1'b1);
        chk_addr = `RV32GC_CSR_CYCLEH; #1;
        chk1("CTRL_CNTR_HALF_CY_OK", chk_illegal, 1'b0);

        //======================================================================
        // V12..V14：TVM（P1-02）
        //======================================================================
        do_reset;
        csr_write(`RV32GC_CSR_MSTATUS, (32'h1 << `RV32GC_MSTATUS_TVM_BIT));
        // ---- V13：M + TVM=1 ⇒ satp 合法（控制）----
        vec_begin;
        chk_addr = `RV32GC_CSR_SATP; #1;
        chk1("CTRL_TVM_M_OK", chk_illegal, 1'b0);

        goto_priv(`RV32GC_PRIV_S);
        csr_write(`RV32GC_CSR_MSTATUS, (32'h1 << `RV32GC_MSTATUS_TVM_BIT));
        // ---- V12：S + TVM=1 ⇒ satp 非法（旧树合法）----
        vec_begin;
        chk_addr = `RV32GC_CSR_SATP; #1;
        chk1("TVM_S_ILL", chk_illegal, 1'b1);
        //   TVM 只拦 satp：同拍 stvec/sstatus 仍合法
        chk_addr = `RV32GC_CSR_STVEC; #1;
        chk1("CTRL_TVM_OTHER_OK", chk_illegal, 1'b0);

        csr_write(`RV32GC_CSR_MSTATUS, 32'h0);
        // ---- V14：S + TVM=0 ⇒ satp 合法（控制）----
        vec_begin;
        chk_addr = `RV32GC_CSR_SATP; #1;
        chk1("CTRL_TVM_CLEARED_OK", chk_illegal, 1'b0);

        //======================================================================
        // V15..V20：sie/sip 按 mideleg 受限别名（P1-05）
        //======================================================================
        do_reset;
        csr_write(`RV32GC_CSR_MIE,     32'h0000_0222);
        csr_write(`RV32GC_CSR_MIDELEG, 32'h0000_0000);
        // ---- V15：mideleg=0 ⇒ sie 读 0（旧树读出 0x222）----
        vec_begin;
        csr_read_val(`RV32GC_CSR_SIE, rdv);
        chk32("SIE_ALIAS_READ", rdv, 32'h0000_0000);
        chk32("CTRL_SIE_MIE_KEEP", mie_o, 32'h0000_0222);

        // ---- V16：mideleg=0 ⇒ 写 sie 不得清底层 mie（旧树会清）----
        vec_begin;
        csr_write(`RV32GC_CSR_SIE, 32'h0000_0000);
        chk32("SIE_ALIAS_WRITE", mie_o, 32'h0000_0222);

        // ---- V17：部分委托（仅 STI）⇒ 只显示/只写该位 ----
        vec_begin;
        csr_write(`RV32GC_CSR_MIDELEG, 32'h0000_0020);
        csr_read_val(`RV32GC_CSR_SIE, rdv);
        chk32("SIE_PARTIAL_DELEG", rdv, 32'h0000_0020);
        csr_write(`RV32GC_CSR_SIE, 32'h0000_0000);
        chk32("SIE_PARTIAL_KEEP", mie_o, 32'h0000_0202);

        // ---- V18：mideleg=0 ⇒ sip 读 0（旧树读出 SSIP）----
        vec_begin;
        csr_write(`RV32GC_CSR_MIDELEG, 32'h0000_0000);
        csr_write(`RV32GC_CSR_MIP,     32'h0000_0222);
        csr_read_val(`RV32GC_CSR_SIP, rdv);
        chk32("SIP_ALIAS_READ", rdv, 32'h0000_0000);

        // ---- V19：SSIP 未委托 ⇒ 写 sip 0 不得清底层 mip（旧树会清）----
        vec_begin;
        csr_write(`RV32GC_CSR_SIP, 32'h0000_0000);
        chk32("SIP_UNDELEG_WRITE", mip_o, 32'h0000_0222);

        // ---- V20：SSIP 已委托 ⇒ sip 只显示 SSIP；写 0 只清该位 ----
        vec_begin;
        csr_write(`RV32GC_CSR_MIDELEG, 32'h0000_0002);
        csr_read_val(`RV32GC_CSR_SIP, rdv);
        chk32("SIP_PARTIAL_DELEG", rdv, 32'h0000_0002);   // 旧树读出 0x222 ⇒ FAIL
        csr_write(`RV32GC_CSR_SIP, 32'h0000_0000);
        chk32("CTRL_SIP_DELEG_WRITE", mip_o, 32'h0000_0220);

        //======================================================================
        // V21..V27：未委托 S 源中断 → M 目标候选（P1-04）
        //======================================================================
        do_reset;
        csr_write(`RV32GC_CSR_MTVEC, 32'h1C00_5001);   // Vectored BASE=0x1C00_5000
        csr_write(`RV32GC_CSR_STVEC, 32'h1C00_6001);   // Vectored BASE=0x1C00_6000
        csr_write(`RV32GC_CSR_MIDELEG, 32'h0000_0000);
        csr_write(`RV32GC_CSR_MIE, (32'h1 << `RV32GC_MIP_STIP_BIT));
        csr_write(`RV32GC_CSR_MIP, (32'h1 << `RV32GC_MIP_STIP_BIT));
        csr_write(`RV32GC_CSR_MSTATUS, (32'h1 << `RV32GC_MSTATUS_MIE_BIT));
        // ---- V21：M + mideleg=0 + STIE/STIP + MIE=1 ⇒ M 目标，cause=0x8000_0005 ----
        vec_begin;
        chk1("IRQ_UNDELEG_M", tc_trap_valid, 1'b1);
        chk1("IRQ_UNDELEG_M_TGT", tc_target == `RV32GC_PRIV_M, 1'b1);
        chk32("IRQ_UNDELEG_M_CAUSE", tc_cause, 32'h8000_0005);
        chk1("IRQ_UNDELEG_M_WE", tc_we[0], 1'b1);

        csr_write(`RV32GC_CSR_MSTATUS, 32'h0);
        // ---- V22：M + MIE=0 ⇒ 不取（控制）----
        vec_begin;
        chk1("CTRL_IRQ_M_GATED", tc_trap_valid, 1'b0);

        goto_priv(`RV32GC_PRIV_S);
        csr_write(`RV32GC_CSR_MSTATUS, 32'h0);   // SIE=0、MIE=0
        // ---- V23：S + mideleg=0 ⇒ 非委托 STI 进 M（旧树被永久屏蔽）----
        vec_begin;
        chk1("IRQ_SRC_S_TO_M", tc_trap_valid, 1'b1);
        chk1("IRQ_SRC_S_TO_M_TGT", tc_target == `RV32GC_PRIV_M, 1'b1);
        chk32("IRQ_SRC_S_TO_M_CAUSE", tc_cause, 32'h8000_0005);

        goto_priv(`RV32GC_PRIV_U);
        csr_write(`RV32GC_CSR_MIE, (32'h1 << `RV32GC_MIP_SSIP_BIT));
        csr_write(`RV32GC_CSR_MIP, (32'h1 << `RV32GC_MIP_SSIP_BIT));
        // ---- V26：U + 非委托 SSI ⇒ M 目标，cause=0x8000_0001 ----
        vec_begin;
        chk1("IRQ_SSI_U_TO_M", tc_trap_valid, 1'b1);
        chk1("IRQ_SSI_U_TO_M_TGT", tc_target == `RV32GC_PRIV_M, 1'b1);
        chk32("IRQ_SSI_U_TO_M_CAUSE", tc_cause, 32'h8000_0001);

        do_reset;
        csr_write(`RV32GC_CSR_STVEC, 32'h1C00_6001);
        goto_priv(`RV32GC_PRIV_S);
        csr_write(`RV32GC_CSR_MIDELEG, 32'h0000_0020);
        csr_write(`RV32GC_CSR_MIE, (32'h1 << `RV32GC_MIP_STIP_BIT));
        csr_write(`RV32GC_CSR_MIP, (32'h1 << `RV32GC_MIP_STIP_BIT));
        csr_write(`RV32GC_CSR_MSTATUS, (32'h1 << `RV32GC_MSTATUS_SIE_BIT));
        // ---- V24：S + 已委托 STI + SIE=1 ⇒ 目标 S，cause 原源号（控制）----
        vec_begin;
        chk1("CTRL_IRQ_DELEG_S", tc_trap_valid, 1'b1);
        chk1("CTRL_IRQ_DELEG_S_TGT", tc_target == `RV32GC_PRIV_S, 1'b1);
        chk32("CTRL_IRQ_DELEG_S_CAUSE", tc_cause, 32'h8000_0005);
        chk1("CTRL_IRQ_DELEG_S_WE", tc_we[1], 1'b1);

        do_reset;
        csr_write(`RV32GC_CSR_MIDELEG, 32'h0000_0020);
        csr_write(`RV32GC_CSR_MIE, (32'h1 << `RV32GC_MIP_STIP_BIT));
        csr_write(`RV32GC_CSR_MIP, (32'h1 << `RV32GC_MIP_STIP_BIT));
        csr_write(`RV32GC_CSR_MSTATUS, (32'h1 << `RV32GC_MSTATUS_MIE_BIT));
        // ---- V25：M + 已委托 ⇒ 委托位在 M 屏蔽（控制）----
        vec_begin;
        chk1("CTRL_IRQ_DELEG_M_MASK", tc_trap_valid, 1'b0);

        csr_write(`RV32GC_CSR_MIDELEG, 32'h0000_0000);
        csr_write(`RV32GC_CSR_MIE, 32'h0000_0AAA);
        csr_write(`RV32GC_CSR_MIP, 32'h0000_0AAA);   // 只写软件位 1/5/9
        irq_msip_t = 1'b1; irq_mtip_t = 1'b1; irq_meip_t = 1'b1;   // 设备位 3/7/11
        csr_write(`RV32GC_CSR_MSTATUS, (32'h1 << `RV32GC_MSTATUS_MIE_BIT));
        // ---- V27：六源同挂起、全未委托 ⇒ 仍取 M 级最高优先 MEI(11)（控制）----
        vec_begin;
        chk32("CTRL_IRQ_PRIORITY", tc_cause, 32'h8000_000B);
        chk1("CTRL_IRQ_PRIORITY_TGT", tc_target == `RV32GC_PRIV_M, 1'b1);
        irq_msip_t = 1'b0; irq_mtip_t = 1'b0; irq_meip_t = 1'b0; #1;

        //======================================================================
        // V28..V32：priv_ctrl 同拍旁路 = 替换语义（P1-06）
        //======================================================================
        do_reset;
        // ---- V28：MPRV/MPP=S/SUM/MXR/MPIE… 全 1，同拍写 0 ⇒ 全部清 ----
        vec_begin;
        csr_write(`RV32GC_CSR_MSTATUS,
                  mstat(1'b1, 1'b1, 1'b1, 1'b1, 1'b1, 1'b1, 1'b1, 1'b1, `RV32GC_PRIV_S) |
                  (32'h1 << `RV32GC_MSTATUS_TVM_BIT) |
                  (32'h1 << `RV32GC_MSTATUS_TW_BIT)  |
                  (32'h1 << `RV32GC_MSTATUS_TSR_BIT));
        @(negedge clk); #1;
        chk1("BYP_PRE_SUM", pc_sum_o, 1'b1);      // 前置：eff_priv=S 且 SUM=1
        p_csr_wen = 1'b1; p_csr_waddr = `RV32GC_CSR_MSTATUS; p_csr_wdata = 32'h0; #1;
        chk1("BYP_MPRV_1TO0", pc_mprv_o, 1'b0);
        chk32("BYP_MPRV_EFF", {30'b0, pc_eff_priv_o}, 32'h3);
        chk1("BYP_SUM_1TO0",  pc_sum_o, 1'b0);
        chk1("BYP_MXR_1TO0",  pc_mxr_o, 1'b0);
        chk1("BYP_TVM_1TO0",  pc_tvm_o, 1'b0);
        chk1("BYP_TW_1TO0",   pc_tw_o,  1'b0);
        chk1("BYP_TSR_1TO0",  pc_tsr_o, 1'b0);
        p_csr_wen = 1'b0; #1;

        // ---- V29：sstatus 写掩码不越界（清 SUM/MXR，保留 MPRV/MPP/TVM）----
        vec_begin;
        csr_write(`RV32GC_CSR_MSTATUS,
                  mstat(1'b1, 1'b1, 1'b1, 1'b1, 1'b1, 1'b1, 1'b1, 1'b1, `RV32GC_PRIV_S) |
                  (32'h1 << `RV32GC_MSTATUS_TVM_BIT));
        @(negedge clk);
        p_csr_wen = 1'b1; p_csr_waddr = `RV32GC_CSR_SSTATUS; p_csr_wdata = 32'h0; #1;
        chk1("BYP_SSTATUS_MASK", pc_sum_o, 1'b0);          // SUM 属 sstatus 掩码 ⇒ 清
        chk1("BYP_SSTATUS_MXR",  pc_mxr_o, 1'b0);          // MXR 属掩码 ⇒ 清
        chk1("CTRL_SSTATUS_MPRV_KEEP", pc_mprv_o, 1'b1);   // 掩码外 ⇒ 保留
        chk1("CTRL_SSTATUS_TVM_KEEP",  pc_tvm_o,  1'b1);
        chk32("CTRL_SSTATUS_MPP_KEEP", {30'b0, pc_mpp_o}, 32'h1);
        p_csr_wen = 1'b0; #1;

        // ---- V30：MPP 由 S 同拍改 U ⇒ eff_priv=U（旧树 OR 残留 S）----
        vec_begin;
        csr_write(`RV32GC_CSR_MSTATUS, mstat(0,0,0,0,0, 1'b1,0,0, `RV32GC_PRIV_S));
        @(negedge clk);
        p_csr_wen = 1'b1; p_csr_waddr = `RV32GC_CSR_MSTATUS;
        p_csr_wdata = mstat(0,0,0,0,0, 1'b1,0,0, `RV32GC_PRIV_U); #1;
        chk32("BYP_MPP_S_TO_U", {30'b0, pc_eff_priv_o}, 32'h0);
        p_csr_wen = 1'b0; #1;

        // ---- V31：MPP 保留编码 2'b10 ⇒ 使用点合法化为 S（控制；旧树 OR 亦得 S）----
        vec_begin;
        csr_write(`RV32GC_CSR_MSTATUS, mstat(0,0,0,0,0, 1'b1,0,0, `RV32GC_PRIV_U));
        @(negedge clk);
        p_csr_wen = 1'b1; p_csr_waddr = `RV32GC_CSR_MSTATUS;
        p_csr_wdata = mstat(0,0,0,0,0, 1'b1,0,0, 2'b10); #1;
        chk32("CTRL_BYP_MPP_WARL", {30'b0, pc_mpp_o}, 32'h1);
        chk32("CTRL_BYP_MPP_WARL_EFF", {30'b0, pc_eff_priv_o}, 32'h1);
        p_csr_wen = 1'b0; #1;

        // ---- V32：MIE 1→0 同拍可见（经真实 mstatus_set 观测）----
        vec_begin;
        csr_write(`RV32GC_CSR_MSTATUS, (32'h1 << `RV32GC_MSTATUS_MIE_BIT));
        @(negedge clk);
        pc_trap_valid = 1'b1; pc_trap_target = `RV32GC_PRIV_M; #1;
        chk1("CTRL_BYP_MIE_PRE", pc_set[`RV32GC_MSTATUS_MPIE_BIT], 1'b1);
        p_csr_wen = 1'b1; p_csr_waddr = `RV32GC_CSR_MSTATUS; p_csr_wdata = 32'h0; #1;
        chk1("BYP_MIE_1TO0", pc_set[`RV32GC_MSTATUS_MPIE_BIT], 1'b0);
        p_csr_wen = 1'b0; pc_trap_valid = 1'b0; #1;

        //======================================================================
        // V33..V35：【首轮独审 P1】中断选中 = 目标特权级 M 优先，再组内源序
        //   （旧树按固定源序会让已委托 SEI→S 抢在未委托 STI→M 之前）
        //======================================================================
        do_reset;
        csr_write(`RV32GC_CSR_MTVEC, 32'h1C00_5001);
        csr_write(`RV32GC_CSR_STVEC, 32'h1C00_6001);
        // ---- V33：U + mideleg=0x200 + mie=mip=0x220 ⇒ M 目标 STI(5) 胜 S 目标 SEI(9) ----
        vec_begin;
        goto_priv(`RV32GC_PRIV_U);
        csr_write(`RV32GC_CSR_MIDELEG, 32'h0000_0200);
        csr_write(`RV32GC_CSR_MIE, 32'h0000_0220);
        csr_write(`RV32GC_CSR_MIP, 32'h0000_0220);
        csr_write(`RV32GC_CSR_MSTATUS, 32'h0);
        chk1("IRQ_MFIRST_U", tc_trap_valid, 1'b1);
        chk1("IRQ_MFIRST_U_TGT", tc_target == `RV32GC_PRIV_M, 1'b1);
        chk32("IRQ_MFIRST_U", tc_cause, 32'h8000_0005);
        // ---- V34：S + 同配置 + SIE=1 ⇒ 仍 M 目标优先（旧树取 SEI→S）----
        vec_begin;
        do_reset;
        csr_write(`RV32GC_CSR_MTVEC, 32'h1C00_5001);
        csr_write(`RV32GC_CSR_STVEC, 32'h1C00_6001);
        goto_priv(`RV32GC_PRIV_S);
        csr_write(`RV32GC_CSR_MIDELEG, 32'h0000_0200);
        csr_write(`RV32GC_CSR_MIE, 32'h0000_0220);
        csr_write(`RV32GC_CSR_MIP, 32'h0000_0220);
        csr_write(`RV32GC_CSR_MSTATUS, (32'h1 << `RV32GC_MSTATUS_SIE_BIT));
        chk1("IRQ_MFIRST_S", tc_trap_valid, 1'b1);
        chk1("IRQ_MFIRST_S_TGT", tc_target == `RV32GC_PRIV_M, 1'b1);
        chk32("IRQ_MFIRST_S", tc_cause, 32'h8000_0005);
        // ---- V35（控制）：S + mideleg=0x202 + mie=mip=0x202 + SIE=1 ⇒ S 组内 SEI(9)>SSI(1) ----
        vec_begin;
        do_reset;
        goto_priv(`RV32GC_PRIV_S);
        csr_write(`RV32GC_CSR_MIDELEG, 32'h0000_0202);
        csr_write(`RV32GC_CSR_MIE, 32'h0000_0202);
        csr_write(`RV32GC_CSR_MIP, 32'h0000_0202);
        csr_write(`RV32GC_CSR_MSTATUS, (32'h1 << `RV32GC_MSTATUS_SIE_BIT));
        chk1("CTRL_IRQ_SGROUP_PRI", tc_trap_valid, 1'b1);
        chk32("CTRL_IRQ_SGROUP_PRI_CAUSE", tc_cause, 32'h8000_0009);
        chk1("CTRL_IRQ_SGROUP_PRI_TGT", tc_target == `RV32GC_PRIV_S, 1'b1);

        //======================================================================
        // V36..V41：【首轮独审 P1】SIE/SIP 两路预览（rdata_w / byp_rdata）
        //   必须与落盘实际读取逐位一致（未/部分/全委托三档 + 委托同拍变化）
        //======================================================================
        do_reset;
        csr_write(`RV32GC_CSR_MIE, 32'h0000_0222);
        // ---- V36：未委托 ⇒ SIE 写 0x222 预览/落盘 = 0（旧树预览 0x222）----
        vec_begin;
        csr_write(`RV32GC_CSR_MIDELEG, 32'h0000_0000);
        @(negedge clk);
        raddr = `RV32GC_CSR_SIE; waddr = `RV32GC_CSR_SIE; wdata = 32'h0000_0222;
        wen = 1'b1; w_illegal = 1'b0; byp_wdata = 32'h0000_0222; #1;
        chk32("SIE_PREVIEW_DELEG", rdata_w, 32'h0);
        chk32("SIE_PREVIEW_DELEG_BYP", byp_rdata, 32'h0);
        @(posedge clk); #1;
        @(negedge clk); wen = 1'b0; byp_wdata = 32'h0;
        @(posedge clk); #1;
        csr_read_val(`RV32GC_CSR_SIE, rdv);
        chk32("SIE_PREVIEW_DELEG_LAND", rdv, 32'h0);
        // ---- V37：部分委托(0x020) ⇒ SIE 写 0x222 预览/落盘 = 0x020（旧树 0x222）----
        vec_begin;
        csr_write(`RV32GC_CSR_MIDELEG, 32'h0000_0020);
        @(negedge clk);
        raddr = `RV32GC_CSR_SIE; waddr = `RV32GC_CSR_SIE; wdata = 32'h0000_0222;
        wen = 1'b1; byp_wdata = 32'h0000_0000; #1;
        chk32("SIE_PREVIEW_PARTIAL", rdata_w, 32'h0000_0020);
        chk32("SIE_PREVIEW_PARTIAL_BYP", byp_rdata, 32'h0);
        @(posedge clk); #1;
        @(negedge clk); wen = 1'b0; byp_wdata = 32'h0;
        @(posedge clk); #1;
        csr_read_val(`RV32GC_CSR_SIE, rdv);
        chk32("SIE_PREVIEW_PARTIAL_LAND", rdv, 32'h0000_0020);
        // ---- V38（控制）：全委托 ⇒ SIE 写 0x202 预览/落盘 = 0x202 ----
        vec_begin;
        csr_write(`RV32GC_CSR_MIDELEG, 32'h0000_0222);
        @(negedge clk);
        raddr = `RV32GC_CSR_SIE; waddr = `RV32GC_CSR_SIE; wdata = 32'h0000_0202;
        wen = 1'b1; byp_wdata = 32'h0000_0002; #1;
        chk32("CTRL_SIE_PREVIEW_FULL_RDW", rdata_w, 32'h0000_0202);
        chk32("CTRL_SIE_PREVIEW_FULL_BYP", byp_rdata, 32'h0000_0002);
        @(posedge clk); #1;
        @(negedge clk); wen = 1'b0; byp_wdata = 32'h0;
        @(posedge clk); #1;
        csr_read_val(`RV32GC_CSR_SIE, rdv);
        chk32("CTRL_SIE_PREVIEW_FULL_LAND", rdv, 32'h0000_0202);
        // ---- V39：SIP 未委托 ⇒ 写 SIP=0 预览/落盘 = 0，不清底层 mip（旧树 0x220）----
        vec_begin;
        csr_write(`RV32GC_CSR_MIDELEG, 32'h0000_0000);
        csr_write(`RV32GC_CSR_MIP, 32'h0000_0222);
        @(negedge clk);
        raddr = `RV32GC_CSR_SIP; waddr = `RV32GC_CSR_SIP; wdata = 32'h0000_0000;
        wen = 1'b1; byp_wdata = 32'h0000_0000; #1;
        chk32("SIP_PREVIEW_DELEG", rdata_w, 32'h0);
        chk32("SIP_PREVIEW_DELEG_BYP", byp_rdata, 32'h0);
        @(posedge clk); #1;
        @(negedge clk); wen = 1'b0;
        @(posedge clk); #1;
        csr_read_val(`RV32GC_CSR_SIP, rdv);
        chk32("SIP_PREVIEW_DELEG_LAND", rdv, 32'h0);
        chk32("SIP_PREVIEW_DELEG_KEEP", mip_o & 32'h0000_0222, 32'h0000_0222);
        // ---- V40：委托同拍变化 —— W 写 mideleg=0（撤委托），读 SIE 预览按新值 ----
        vec_begin;
        csr_write(`RV32GC_CSR_MIDELEG, 32'h0000_0222);
        csr_write(`RV32GC_CSR_MIE, 32'h0000_0202);
        @(negedge clk);
        raddr = `RV32GC_CSR_SIE; waddr = `RV32GC_CSR_MIDELEG; wdata = 32'h0000_0000;
        wen = 1'b1; byp_wdata = 32'h0000_0222; #1;
        chk32("SIE_PREVIEW_MIDELEG_SAME", rdata_w, 32'h0);
        chk32("SIE_PREVIEW_MIDELEG_SAME_BYP", byp_rdata, 32'h0);
        @(posedge clk); #1;
        @(negedge clk); wen = 1'b0; byp_wdata = 32'h0;
        @(posedge clk); #1;
        csr_read_val(`RV32GC_CSR_SIE, rdv);
        chk32("SIE_PREVIEW_MIDELEG_SAME_LAND", rdv, 32'h0);
        // ---- V41（控制）：SIP 全委托 ⇒ 写 SIP=0 预览/落盘 = 0x220，置位预览 = 0x222 ----
        vec_begin;
        csr_write(`RV32GC_CSR_MIDELEG, 32'h0000_0222);
        csr_write(`RV32GC_CSR_MIP, 32'h0000_0222);
        @(negedge clk);
        raddr = `RV32GC_CSR_SIP; waddr = `RV32GC_CSR_SIP; wdata = 32'h0000_0000;
        wen = 1'b1; byp_wdata = 32'h0000_0222; #1;
        chk32("CTRL_SIP_PREVIEW_FULL_RDW", rdata_w, 32'h0000_0220);
        chk32("CTRL_SIP_PREVIEW_FULL_BYP", byp_rdata, 32'h0000_0222);
        @(posedge clk); #1;
        @(negedge clk); wen = 1'b0; byp_wdata = 32'h0;
        @(posedge clk); #1;
        csr_read_val(`RV32GC_CSR_SIP, rdv);
        chk32("CTRL_SIP_PREVIEW_FULL_LAND", rdv, 32'h0000_0220);

        // ---- V42：【SD 派生】FS=Off/Initial/Clean ⇒ SD=0；FS=Dirty ⇒ SD=1 ----
        //   machine.adoc:883-887（SD 汇总 dirty；编码 824-843：只有 FS=3 是 Dirty）；
        //   本核 VS/XS=0 ⇒ SD=(FS==3)。旧树 FS!=Off ⇒ FS=1 读回 0x8000_2000
        //   （Spike 0x2000）。★ 旧树红的新检查一律不用 CTRL_ 前缀（基线门禁要求 0 条
        //   CTRL fail），只有两树都应为真的才用 CTRL_。
        vec_begin;
        csr_write(`RV32GC_CSR_MSTATUS, 32'h0000_0000);
        csr_read_val(`RV32GC_CSR_MSTATUS, rdv);
        chk32("CTRL_SD_FS_OFF", rdv, 32'h0000_0000);
        csr_write(`RV32GC_CSR_MSTATUS, (2'b01 << `RV32GC_MSTATUS_FS_LSB));
        csr_read_val(`RV32GC_CSR_MSTATUS, rdv);
        chk32("MSTATUS_SD_DIRTY", rdv, 32'h0000_2000);          // ★ 旧树红（defect tag）
        chk32("SD_FS_INITIAL_MO", mstatus_o, 32'h0000_2000);    // ★ 旧树红（非 CTRL）
        csr_write(`RV32GC_CSR_MSTATUS, (2'b10 << `RV32GC_MSTATUS_FS_LSB));
        csr_read_val(`RV32GC_CSR_MSTATUS, rdv);
        chk32("SD_FS_CLEAN", rdv, 32'h0000_4000);               // ★ 旧树红（非 CTRL）
        csr_write(`RV32GC_CSR_MSTATUS, (2'b11 << `RV32GC_MSTATUS_FS_LSB));
        csr_read_val(`RV32GC_CSR_MSTATUS, rdv);
        chk32("CTRL_SD_FS_DIRTY", rdv, 32'h8000_6000);          // 两树皆真
        csr_write(`RV32GC_CSR_MSTATUS, 32'h8000_0000);
        csr_read_val(`RV32GC_CSR_MSTATUS, rdv);
        chk32("CTRL_SD_RO", rdv, 32'h0000_0000);                // 只读 SD 不可置脏
        csr_write(`RV32GC_CSR_SSTATUS, 32'h0000_6000);
        csr_read_val(`RV32GC_CSR_SSTATUS, rdv);
        chk32("CTRL_SD_SSTATUS", rdv, 32'h8000_6000);
        @(negedge clk);
        raddr = `RV32GC_CSR_MSTATUS; waddr = `RV32GC_CSR_MSTATUS;
        wdata = 32'h0000_2000; byp_wdata = 32'h0000_2000; wen = 1'b1; #1;
        chk32("SD_PREVIEW_CLEAR", rdata_w, 32'h0000_2000);      // ★ 旧树红（非 CTRL）
        chk32("SD_PREVIEW_CLEAR_BYP", byp_rdata, 32'h0000_2000);
        @(posedge clk); #1;
        @(negedge clk); wen = 1'b0; byp_wdata = 32'h0;
        @(posedge clk); #1;

        //======================================================================
        // 汇总（fail-closed）
        //   ★ 冻结规格：VECTORS_SPEC；每向量必须 >0 项检查（settle_vec 自判）；
        //     摘要行 `FUNCTIONAL_PRIVILEGE_VECTORS total=.. checks=.. fails=..` 是
        //     脚本的严格解析对象（同前缀必须唯一）。
        //======================================================================
        settle_vec;                      // 结算最后一个向量
        if (n_vec !== SPEC_VECTORS) begin
            n_fail = n_fail + 1;
            $display("PRIV FAIL [VECTOR_COUNT]: vectors=%0d exp=%0d", n_vec, SPEC_VECTORS);
        end
        if (vec_sum_checks <= 0) begin
            n_fail = n_fail + 1;
            $display("PRIV FAIL [ZERO_CHECKS]: checks=%0d", vec_sum_checks);
        end
        $display("---- tb_privilege_semantics: checks=%0d pass=%0d fail=%0d vectors=%0d ----",
                 n_pass + n_fail, n_pass, n_fail, n_vec);
        $display("FUNCTIONAL_PRIVILEGE_VECTORS total=%0d checks=%0d fails=%0d",
                 n_vec, vec_sum_checks, n_fail);
        if (n_fail != 0) begin
            $display("FUNCTIONAL_PRIVILEGE: FAIL %0d", n_fail);
            $fatal(1, "FUNCTIONAL_PRIVILEGE FAIL");
        end
        if ((n_pass == 0) || (n_vec == 0)) begin
            $display("FUNCTIONAL_PRIVILEGE: FAIL (未捕获任何检查)");
            $fatal(1, "FUNCTIONAL_PRIVILEGE FAIL");
        end
        $display("FUNCTIONAL_PRIVILEGE: PASS");
        $finish;
    end

    //--------------------------------------------------------------------------
    // 看门狗（fail-closed：超时 ⇒ 非零退出，绝不打印 PASS）
    //--------------------------------------------------------------------------
    initial begin
        #300000;
        $display("PRIV FAIL [TIMEOUT]: 超时（未走完向量）");
        $fatal(1, "FUNCTIONAL_PRIVILEGE FAIL");
    end

endmodule
