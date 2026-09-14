//==============================================================================
// sim/unit/tb_lsu.sv —— M 级访存顶层 lsu.v 单元测试（L0）
//==============================================================================
// 项目    : rv32gc-cpu（阶段二 2A）
// 依据    : docs/design/08-baseline-5stage.md §5.4/§5.5（十项抉择）/§6.4/§6.5
//           docs/kb/isa-notes.md T1–T8
//
// 覆盖要求（验收判据 ④，逐条对应）：
//   · lb/lbu/lh/lhu/lw/sb/sh/sw **对齐**访问：无异常、地址/字节数/权限正确
//   · **非对齐优先于 PMP**（抉择 1）：构造「非对齐 **且** PMP 必拒」的场景，
//     断言报的是 cause 4/6（非对齐）而**不是** cause 5/7（PMP）
//   · **MPRV=1 且 MPP=S 时按 S 权限**：同一配置下 M 直访放行、MPRV+MPP=S 拒
//   · **mtval 恒 VA**：物理 access fault 时 mtval 仍是虚拟地址（抉择 7）
//   · 无原语；不出现已废弃的旧项目名（旧项目名口径见 AGENT.md §8，此处不书写）
//
// 判定纪律（08 §8.1"未捕获即失败"）：
//   · 任何断言不成立 ⇒ 立即 $fatal（非零退出码），且**绝不打印 PASS**；
//   · 全部通过才打印最后一行 `TB_LSU: PASS`。
//
// 顶层    : tb_lsu_top（验收命令用 -s tb_lsu_top）
//==============================================================================
`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"

module tb_lsu_top;

    //--------------------------------------------------------------------------
    // 0. 常量镜像
    //--------------------------------------------------------------------------
    localparam integer N     = `RV32GC_PMP_ENTRIES;
    localparam integer CFG_W = 8;

    localparam [1:0] A_OFF   = `RV32GC_PMP_A_OFF;
    localparam [1:0] A_TOR   = `RV32GC_PMP_A_TOR;
    localparam [1:0] A_NA4   = `RV32GC_PMP_A_NA4;
    localparam [1:0] A_NAPOT = `RV32GC_PMP_A_NAPOT;

    localparam [1:0] PRIV_U = `RV32GC_PRIV_U;
    localparam [1:0] PRIV_S = `RV32GC_PRIV_S;
    localparam [1:0] PRIV_M = `RV32GC_PRIV_M;

    // lsu 的 mem_kind 编码（与 lsu.v 头部一致）
    localparam [2:0] A_LOAD  = 3'd0;
    localparam [2:0] A_STORE = 3'd1;
    localparam [2:0] A_AMO   = 3'd2;
    localparam [2:0] A_LR    = 3'd3;
    localparam [2:0] A_SC    = 3'd4;
    localparam [2:0] A_CBO   = 3'd5;

    // size 编码
    localparam [1:0] SZ_1B = 2'd0;
    localparam [1:0] SZ_2B = 2'd1;
    localparam [1:0] SZ_4B = 2'd2;

    // cause 码
    localparam [4:0] C_LOAD_MIS   = `RV32GC_EXC_LOAD_MISALIGNED;   // 4
    localparam [4:0] C_LOAD_ACC   = `RV32GC_EXC_LOAD_ACCESS_FAULT; // 5
    localparam [4:0] C_ST_MIS     = `RV32GC_EXC_STORE_MISALIGNED;  // 6
    localparam [4:0] C_ST_ACC     = `RV32GC_EXC_STORE_ACCESS_FAULT;// 7

    // pmpcfg 位域
    localparam integer B_R = `RV32GC_PMP_R_BIT;
    localparam integer B_W = `RV32GC_PMP_W_BIT;
    localparam integer B_X = `RV32GC_PMP_X_BIT;
    localparam integer B_A = `RV32GC_PMP_A_LSB;
    localparam integer B_L = `RV32GC_PMP_L_BIT;

    // 路由编码
    localparam [2:0] ROUTE_CLINT = 3'd1;
    localparam [2:0] ROUTE_PLIC  = 3'd2;
    localparam [2:0] ROUTE_XIP   = 3'd3;
    localparam [2:0] ROUTE_AXI   = 3'd4;

    //--------------------------------------------------------------------------
    // 1. DUT 驱动
    //--------------------------------------------------------------------------
    reg         clk, rst_n;

    reg         req_valid;
    reg  [31:0] rs1, imm;
    reg  [2:0]  mem_kind;
    reg  [1:0]  size;
    reg         unsign;
    reg  [4:0]  amo_f5;
    reg  [4:0]  cbo_rs2;
    reg  [31:0] store_data;

    reg  [1:0]  cur_priv;
    reg         mprv;
    reg  [1:0]  mpp;
    reg         sum, mxr;
    reg         inval_dg;

    reg  [31:0] ptw_pa;
    reg         ptw_fault;
    reg  [4:0]  ptw_cause;

    reg  [N*CFG_W-1:0]  pmp_cfg;
    reg  [N*32-1:0]     pmp_addr;

    wire [31:0] mem_va, mem_pa, mem_addr;
    wire        exc;
    wire [4:0]  exc_cause;
    wire [31:0] mtval;
    wire        misaligned, pmp_deny;
    wire        split;
    wire [1:0]  num_beats;
    wire [31:0] beat0_addr, beat1_addr;
    wire [4:0]  beat0_bytes, beat1_bytes;
    wire        beat0_ok, beat1_ok;
    wire [2:0]  route;
    wire        no_axi, clint_plic, xip_direct, axi_unc, axi_cac;
    wire [3:0]  axi_cache;
    wire [31:0] amo_rd_old, amo_wdata;
    wire        sc_success, amo_busy;
    wire        cmo_valid;
    wire [1:0]  cmo_action;
    wire [31:0] cmo_blk_addr, cmo_blk_size;
    wire [1:0]  eff_priv, need_perm;
    wire        eff_sum, eff_mxr;

    lsu #(
        .PMP_ENTRIES (N)
    ) dut (
        .clk              (clk),
        .rst_n            (rst_n),
        .req_valid_i      (req_valid),
        .rs1_i            (rs1),
        .imm_i            (imm),
        .mem_kind_i       (mem_kind),
        .size_i           (size),
        .unsigned_i       (unsign),
        .amo_f5_i         (amo_f5),
        .cbo_rs2_i        (cbo_rs2),
        .store_data_i     (store_data),
        .cur_priv_i       (cur_priv),
        .mprv_i           (mprv),
        .mpp_i            (mpp),
        .sum_i            (sum),
        .mxr_i            (mxr),
        .inval_downgrade_i(inval_dg),
        .ptw_pa_i         (ptw_pa),
        .ptw_fault_i      (ptw_fault),
        .ptw_cause_i      (ptw_cause),
        .pmp_cfg_i        (pmp_cfg),
        .pmp_addr_i       (pmp_addr),
        .mem_va_o         (mem_va),
        .mem_pa_o         (mem_pa),
        .mem_addr_o       (mem_addr),
        .exc_o            (exc),
        .exc_cause_o      (exc_cause),
        .mtval_o          (mtval),
        .misaligned_o     (misaligned),
        .pmp_deny_o       (pmp_deny),
        .split_o          (split),
        .num_beats_o      (num_beats),
        .beat0_addr_o     (beat0_addr),
        .beat1_addr_o     (beat1_addr),
        .beat0_bytes_o    (beat0_bytes),
        .beat1_bytes_o    (beat1_bytes),
        .beat0_ok_o       (beat0_ok),
        .beat1_ok_o       (beat1_ok),
        .route_o          (route),
        .no_axi_o         (no_axi),
        .mmio_clint_plic_o(clint_plic),
        .xip_direct_o     (xip_direct),
        .axi_uncached_o   (axi_unc),
        .axi_cached_o     (axi_cac),
        .axi_cache_o      (axi_cache),
        .amo_rd_old_o     (amo_rd_old),
        .sc_success_o     (sc_success),
        .amo_wdata_o      (amo_wdata),
        .amo_busy_o       (amo_busy),
        .cmo_valid_o      (cmo_valid),
        .cmo_action_o     (cmo_action),
        .cmo_block_addr_o (cmo_blk_addr),
        .cmo_block_size_o (cmo_blk_size),
        .eff_priv_o       (eff_priv),
        .eff_sum_o        (eff_sum),
        .eff_mxr_o        (eff_mxr),
        .need_perm_o      (need_perm)
    );

    //--------------------------------------------------------------------------
    // 2. 辅助 task
    //--------------------------------------------------------------------------
    integer n_checks, n_align, n_prio, n_mprv, n_tval, n_mmio;

    task set_entry(input integer i, input [1:0] a, input l, input r, input w, input x);
        reg [CFG_W-1:0] v;
        begin
            v = {CFG_W{1'b0}};
            v[B_R] = r; v[B_W] = w; v[B_X] = x;
            v[B_A] = a[0]; v[B_A+1] = a[1];
            v[B_L] = l;
            pmp_cfg[i*CFG_W +: CFG_W] = v;
        end
    endtask

    task set_addr(input integer i, input [31:0] a);
        begin
            pmp_addr[i*32 +: 32] = a;
        end
    endtask

    // 默认环境：全部 OFF（M 模式可访，S/U 全拒）；关闭翻译；无页错误
    task env_default;
        integer i;
        begin
            for (i = 0; i < N; i = i + 1) begin
                set_entry(i, A_OFF, 1'b0, 1'b0, 1'b0, 1'b0);
                set_addr(i, 32'd0);
            end
            req_valid = 1'b0;
            rs1 = 32'd0; imm = 32'd0;
            mem_kind = A_LOAD; size = SZ_4B; unsign = 1'b0;
            amo_f5 = 5'd0; cbo_rs2 = 5'd0; store_data = 32'd0;
            cur_priv = PRIV_M; mprv = 1'b0; mpp = PRIV_U;
            sum = 1'b0; mxr = 1'b0; inval_dg = 1'b0;
            ptw_pa = 32'd0; ptw_fault = 1'b0; ptw_cause = 5'd0;
        end
    endtask

    // 单笔对齐访问检查：无异常 + VA/PA/权限正确
    task check_aligned(input [255:0] name, input [31:0] expect_va,
                       input [2:0] expect_perm);
        begin
            n_checks = n_checks + 1;
            if (exc !== 1'b0) begin
                $display("FAIL[%0s]: 对齐访问不应异常，实际 exc=%b cause=%0d", name, exc, exc_cause);
                $fatal(1, "TB_LSU FAIL");
            end
            if (misaligned !== 1'b0) begin
                $display("FAIL[%0s]: 不应判非对齐", name);
                $fatal(1, "TB_LSU FAIL");
            end
            if (mem_va !== expect_va) begin
                $display("FAIL[%0s]: VA 期望 %08x 实际 %08x", name, expect_va, mem_va);
                $fatal(1, "TB_LSU FAIL");
            end
            if (need_perm !== expect_perm) begin
                $display("FAIL[%0s]: need_perm 期望 %b 实际 %b", name, expect_perm, need_perm);
                $fatal(1, "TB_LSU FAIL");
            end
        end
    endtask

    task check_cause(input [255:0] name, input [4:0] cause_expected);
        begin
            n_checks = n_checks + 1;
            if (exc !== 1'b1) begin
                $display("FAIL[%0s]: 期望异常，实际 exc=0", name);
                $fatal(1, "TB_LSU FAIL");
            end
            if (exc_cause !== cause_expected) begin
                $display("FAIL[%0s]: cause 期望 %0d 实际 %0d", name, cause_expected, exc_cause);
                $fatal(1, "TB_LSU FAIL");
            end
        end
    endtask

    task check_no_exc(input [255:0] name);
        begin
            n_checks = n_checks + 1;
            if (exc !== 1'b0) begin
                $display("FAIL[%0s]: 期望无异常，实际 cause=%0d", name, exc_cause);
                $fatal(1, "TB_LSU FAIL");
            end
        end
    endtask

    //==========================================================================
    // 3. 测试主体
    //==========================================================================
    integer i;

    initial begin
        $display("======== tb_lsu : M 级访存判定与异常优先级 ========");

        clk = 1'b0; rst_n = 1'b0;
        n_checks = 0; n_align = 0; n_prio = 0; n_mprv = 0; n_tval = 0; n_mmio = 0;
        env_default;
        #1; rst_n = 1'b1; #1;

        //======================================================================
        // 组 A：lb/lbu/lh/lhu/lw/sb/sh/sw **对齐**访问（判据 ④ 第一项）
        //   全部在 M 模式（PMP 全 OFF ⇒ M 可访），翻译关闭（PA=VA）
        //======================================================================
        env_default;
        ptw_pa = 32'h0000_2000;                  // PA=VA 口径下的物理地址
        cur_priv = PRIV_M;

        // A-1：lw —— 4 B、需 R
        rs1 = 32'h0000_2000; imm = 32'd0; mem_kind = A_LOAD; size = SZ_4B;
        unsign = 1'b0; req_valid = 1'b1; #1;
        check_aligned("A1-lw", 32'h0000_2000, 2'b10); n_align = n_align + 1;

        // A-2：lb（有符号 1 B）—— 需 R
        rs1 = 32'h0000_2001; imm = 32'd0; size = SZ_1B; unsign = 1'b0; #1;
        check_aligned("A2-lb", 32'h0000_2001, 2'b10); n_align = n_align + 1;

        // A-3：lbu —— 需 R
        rs1 = 32'h0000_2002; size = SZ_1B; unsign = 1'b1; #1;
        check_aligned("A3-lbu", 32'h0000_2002, 2'b10); n_align = n_align + 1;

        // A-4：lh —— 2 B、需 R、2 B 对齐
        rs1 = 32'h0000_2002; size = SZ_2B; unsign = 1'b0; #1;
        check_aligned("A4-lh", 32'h0000_2002, 2'b10); n_align = n_align + 1;

        // A-5：lhu —— 需 R
        rs1 = 32'h0000_2004; size = SZ_2B; unsign = 1'b1; #1;
        check_aligned("A5-lhu", 32'h0000_2004, 2'b10); n_align = n_align + 1;

        // A-6：sb —— 需 W
        rs1 = 32'h0000_3000; imm = 32'd0; mem_kind = A_STORE; size = SZ_1B;
        store_data = 32'hA5A5_A5A5; #1;
        check_aligned("A6-sb", 32'h0000_3000, 2'b01); n_align = n_align + 1;

        // A-7：sh —— 2 B 对齐、需 W
        rs1 = 32'h0000_3002; size = SZ_2B; #1;
        check_aligned("A7-sh", 32'h0000_3002, 2'b01); n_align = n_align + 1;

        // A-8：sw —— 需 W
        rs1 = 32'h0000_3004; size = SZ_4B; #1;
        check_aligned("A8-sw", 32'h0000_3004, 2'b01); n_align = n_align + 1;

        // A-9：地址生成 rs1+imm（I 型正/负立即数）
        rs1 = 32'h0000_1000; imm = 32'h0000_0008; mem_kind = A_LOAD; size = SZ_4B; #1;
        check_aligned("A9-addr-pos", 32'h0000_1008, 2'b10); n_align = n_align + 1;
        rs1 = 32'h0000_1000; imm = 32'hFFFF_FFF8; #1;   // −8
        check_aligned("A10-addr-neg", 32'h0000_0FF8, 2'b10); n_align = n_align + 1;
        $display("  [ALIGN]  10 例通过（lb/lbu/lh/lhu/lw/sb/sh/sw 对齐 + 地址生成）");

        //======================================================================
        // 组 B：**非对齐优先于 PMP**（判据 ④ 第二项；抉择 1 / T3）
        //   构造「既非对齐、又 PMP 必拒」的双重违规：断言报 cause 4/6
        //======================================================================
        env_default;
        // PMP 配置：项 0 覆盖目标地址且**无权限**（L=1, R=W=0）⇒ 必被 PMP 拒
        set_entry(0, A_NA4, 1'b1, 1'b0, 1'b0, 1'b0);
        set_addr (0, 32'h0000_4000);             // 覆盖 0x4000..0x4003
        cur_priv = PRIV_S;                        // S 模式 ⇒ 受 PMP 约束
        ptw_pa = 32'h0000_4000;

        // B-1：**load 非对齐 + PMP 拒** ⇒ 必须报 cause 4（非对齐），不是 5
        rs1 = 32'h0000_4002; imm = 32'd0; mem_kind = A_LOAD; size = SZ_4B;
        req_valid = 1'b1; #1;
        if (misaligned !== 1'b1) begin
            $display("FAIL[B1]: 应判非对齐 (addr=0x4002, 4B)");
            $fatal(1, "TB_LSU FAIL");
        end
        check_cause("B1-load-mis-over-pmp", C_LOAD_MIS);   // 4，**不是** 5
        n_prio = n_prio + 1;

        // B-2：**store 非对齐 + PMP 拒** ⇒ 必须报 cause 6（非对齐），不是 7
        rs1 = 32'h0000_4002; mem_kind = A_STORE; size = SZ_4B; store_data = 32'hDEAD_BEEF; #1;
        check_cause("B2-store-mis-over-pmp", C_ST_MIS);    // 6，**不是** 7
        n_prio = n_prio + 1;

        // B-3：**lh 非对齐**（2 B 跨 2 B 边界）⇒ cause 4
        rs1 = 32'h0000_4001; mem_kind = A_LOAD; size = SZ_2B; #1;
        check_cause("B3-lh-mis", C_LOAD_MIS);
        n_prio = n_prio + 1;

        // B-4：**对照** —— 同样 PMP 配置下，**对齐**访问 ⇒ 报 cause 5（PMP），
        //       证明 B-1/B-2 的 cause 4/6 确实来自「非对齐优先」
        rs1 = 32'h0000_4000; mem_kind = A_LOAD; size = SZ_4B; #1;
        if (misaligned !== 1'b0) begin
            $display("FAIL[B4]: 对齐访问不应判非对齐"); $fatal(1, "TB_LSU FAIL");
        end
        check_cause("B4-aligned-pmp-deny", C_LOAD_ACC);    // 5 = PMP
        n_prio = n_prio + 1;

        // B-5：对齐 store 在 PMP 拒下 ⇒ cause 7
        rs1 = 32'h0000_4000; mem_kind = A_STORE; size = SZ_4B; #1;
        check_cause("B5-aligned-store-pmp", C_ST_ACC);     // 7 = PMP
        n_prio = n_prio + 1;

        // B-6：**AMO 被 PMP 拒 ⇒ 恒 cause 7**（T4 / 抉择 4）
        //      AMO 要求自然对齐 ⇒ 用对齐地址，避免被非对齐优先截走
        rs1 = 32'h0000_4000; mem_kind = A_AMO; amo_f5 = `RV32GC_AMO_ADD;
        size = SZ_4B; store_data = 32'd1; #1;
        check_cause("B6-amo-pmp-cause7", C_ST_ACC);        // 恒 7
        n_prio = n_prio + 1;

        // B-7：SC 被 PMP 拒 ⇒ 恒 cause 7
        mem_kind = A_SC; amo_f5 = `RV32GC_AMO_SC; #1;
        check_cause("B7-sc-pmp-cause7", C_ST_ACC);         // 恒 7
        n_prio = n_prio + 1;

        // B-8：AMO **非对齐 + PMP 拒** ⇒ 非对齐优先 ⇒ cause 6
        rs1 = 32'h0000_4002; mem_kind = A_AMO; amo_f5 = `RV32GC_AMO_ADD; #1;
        check_cause("B8-amo-mis-first", C_ST_MIS);         // 6 优先于 7
        n_prio = n_prio + 1;

        // B-9：**CMO 不产生非对齐异常**（T8）—— 非对齐地址的 cbo.clean 正常动作
        env_default;
        cur_priv = PRIV_M;                        // M 模式不受 menvcfg 门控
        rs1 = 32'h0000_5003; imm = 32'd0; mem_kind = A_CBO;
        cbo_rs2 = `RV32GC_CBO_CLEAN; req_valid = 1'b1; #1;
        if (exc !== 1'b0) begin
            $display("FAIL[B9]: CMO 不得产生非对齐异常，实际 cause=%0d", exc_cause);
            $fatal(1, "TB_LSU FAIL");
        end
        // block 向下对齐到 64 B 边界（CBOM_BLOCK_SIZE=64）
        if (cmo_blk_addr !== 32'h0000_5000) begin
            $display("FAIL[B9]: CMO block 基址期望 0x5000 实际 %08x", cmo_blk_addr);
            $fatal(1, "TB_LSU FAIL");
        end
        if (cmo_blk_size !== `RV32GC_CBOM_BLOCK_SIZE) begin
            $display("FAIL[B9]: CMO block size 期望 %0d 实际 %0d",
                     `RV32GC_CBOM_BLOCK_SIZE, cmo_blk_size);
            $fatal(1, "TB_LSU FAIL");
        end
        if (cmo_valid !== 1'b1) begin
            $display("FAIL[B9]: CMO 动作应有效"); $fatal(1, "TB_LSU FAIL");
        end
        n_checks = n_checks + 3; n_prio = n_prio + 1;
        $display("  [PRIO]   9 例通过（非对齐先于 PMP；AMO/SC 被拒恒 cause 7；CMO 免非对齐）");

        //======================================================================
        // 组 C：**MPRV=1 且 MPP=S ⇒ 按 S 权限**（判据 ④ 第三项；§6.4 / T7）
        //   构造：PMP 项对 S 模式拒绝、对 M 模式放行（L=1, R=1）
        //     · M 直访（mprv=0, priv=M）⇒ L=1 仍需 R ⇒ 给 R ⇒ 放行
        //     · MPRV=1 + MPP=S ⇒ eff_priv=S ⇒ 同样需 R（有）⇒ 放行
        //     · 换 L=1 只给 X（无 R）⇒ M 直访也要 R ⇒ S/U 路径拒
        //   为**区分** M 与 S 行为，用「无匹配」场景更干净：
        //     全部 PMP=OFF ⇒ 无匹配 ⇒ M 成功、S/U 失败（[norm:pmpnoentry_match]）
        //   ⇒ 同一地址：mprv=0&&priv=M 放行；mprv=1&&mpp=S 拒。
        //======================================================================
        env_default;                              // PMP 全 OFF
        rs1 = 32'h0000_6000; imm = 32'd0; mem_kind = A_LOAD; size = SZ_4B;
        ptw_pa = 32'h0000_6000; req_valid = 1'b1;

        // C-1：M 直访（mprv=0, cur_priv=M）⇒ eff_priv=M ⇒ 无匹配成功
        cur_priv = PRIV_M; mprv = 1'b0; mpp = PRIV_U; #1;
        check_no_exc("C1-M-direct-allow");
        if (eff_priv !== PRIV_M) begin
            $display("FAIL[C1]: eff_priv 期望 M(11) 实际 %b", eff_priv);
            $fatal(1, "TB_LSU FAIL");
        end
        n_checks = n_checks + 1; n_mprv = n_mprv + 1;

        // C-2：MPRV=1 且 MPP=S，cur_priv 仍为 M ⇒ eff_priv 必须是 S
        mprv = 1'b1; mpp = PRIV_S; cur_priv = PRIV_M; #1;
        if (eff_priv !== PRIV_S) begin
            $display("FAIL[C2]: MPRV=1/MPP=S 时 eff_priv 期望 S(01) 实际 %b", eff_priv);
            $fatal(1, "TB_LSU FAIL");
        end
        n_checks = n_checks + 1;
        // 无匹配 + eff_priv=S ⇒ **拒**（按 S 权限，不是 M 权限）
        check_cause("C2-MPRV-MPP-S-deny", C_LOAD_ACC);      // 5
        n_mprv = n_mprv + 1;

        // C-3：MPRV=1 且 MPP=M ⇒ eff_priv=M，等效 M 权限 ⇒ 无匹配成功
        mprv = 1'b1; mpp = PRIV_M; #1;
        check_no_exc("C3-MPRV-MPP-M-allow");
        if (eff_priv !== PRIV_M) begin
            $display("FAIL[C3]: eff_priv 期望 M(11) 实际 %b", eff_priv);
            $fatal(1, "TB_LSU FAIL");
        end
        n_checks = n_checks + 1; n_mprv = n_mprv + 1;

        // C-4：MPRV=0 且 cur_priv=S ⇒ eff_priv=S ⇒ 无匹配拒
        mprv = 1'b0; cur_priv = PRIV_S; #1;
        check_cause("C4-S-direct-deny", C_LOAD_ACC);
        n_mprv = n_mprv + 1;

        // C-5：**PMP 项对 M 放行、对 S 拒** 的 L 位验证
        //   项 0 = NA4 @0x6000, L=1, R=1（只有 R）
        //     · eff_priv=M 且 L=1 ⇒ 仍需 R（有）⇒ 放行
        //     · eff_priv=S ⇒ 需 R（有）⇒ 放行（同结果，用于确认 L=1 不豁免 M）
        //   反向：L=1 且 R=0 ⇒ M 与 S 都被拒（证明 L=1 对 M 不豁免）
        set_entry(0, A_NA4, 1'b1, 1'b0, 1'b0, 1'b0);   // L=1, 无任何权限
        set_addr (0, 32'h0000_6000);
        cur_priv = PRIV_M; mprv = 1'b0; #1;
        check_cause("C5-L1-no-perm-M-deny", C_LOAD_ACC);      // M 也被拒
        n_mprv = n_mprv + 1;
        // C-6：给 R ⇒ M 与 S 都放行
        set_entry(0, A_NA4, 1'b1, 1'b1, 1'b0, 1'b0);
        #1; check_no_exc("C6-L1-with-R-M-allow");
        mprv = 1'b1; mpp = PRIV_S; #1;
        check_no_exc("C7-MPRV-S-with-R-allow");
        n_mprv = n_mprv + 2;
        $display("  [MPRV]   7 例通过（MPRV=1 按 MPP；MPP=S 走 S 权限；MPP=M 等效 M）");

        //======================================================================
        // 组 D：**mtval 恒 VA**（判据 ④ 第四项；抉择 7 / T1）
        //   物理地址与虚拟地址取**不同值**，断言异常时 mtval == VA（不是 PA）
        //======================================================================
        env_default;
        // D-1：PMP 拒（物理 access fault）时 mtval 仍写 VA
        set_entry(0, A_NA4, 1'b1, 1'b0, 1'b0, 1'b0);    // L=1 无权限 ⇒ 必拒
        set_addr (0, 32'h0000_7000);
        cur_priv = PRIV_S;
        rs1 = 32'h0000_7000; imm = 32'd0; mem_kind = A_LOAD; size = SZ_4B;
        ptw_pa = 32'h0000_7000;                          // PA 与 VA 同（Bare）—— 见 D-2 的分离
        req_valid = 1'b1; #1;
        if (mtval !== 32'h0000_7000) begin
            $display("FAIL[D1]: mtval 期望 VA=0x7000 实际 %08x", mtval);
            $fatal(1, "TB_LSU FAIL");
        end
        n_checks = n_checks + 1; n_tval = n_tval + 1;

        // D-2：**VA ≠ PA** —— 有翻译时期望 mtval 写 **VA** 而非 PA
        rs1 = 32'h0000_7000; imm = 32'h0000_0004;        // VA = 0x7004
        ptw_pa = 32'h8000_1234;                          // PA 完全不同
        set_entry(0, A_NA4, 1'b1, 1'b0, 1'b0, 1'b0);
        set_addr (0, 32'h8000_1234);                     // PMP 按 PA 命中并拒
        #1;
        if (exc !== 1'b1) begin
            $display("FAIL[D2]: 期望访存异常"); $fatal(1, "TB_LSU FAIL");
        end
        if (mtval !== 32'h0000_7004) begin
            $display("FAIL[D2]: mtval 必须写 VA=0x7004，实际 %08x（PA=%08x）",
                     mtval, mem_pa);
            $fatal(1, "TB_LSU FAIL");
        end
        if (mem_pa !== 32'h8000_1234) begin
            $display("FAIL[D2]: mem_pa 期望 %08x 实际 %08x", 32'h8000_1234, mem_pa);
            $fatal(1, "TB_LSU FAIL");
        end
        n_checks = n_checks + 2; n_tval = n_tval + 1;

        // D-3：**非对齐**异常时 mtval 也写 VA
        env_default;
        cur_priv = PRIV_M;
        rs1 = 32'h0000_9100; imm = 32'h0000_0002;        // VA = 0x9102，非对齐
        ptw_pa = 32'h0000_9102;
        mem_kind = A_LOAD; size = SZ_4B; req_valid = 1'b1; #1;
        check_cause("D3-mis", C_LOAD_MIS);
        if (mtval !== 32'h0000_9102) begin
            $display("FAIL[D3]: 非对齐异常 mtval 期望 VA=0x9102 实际 %08x", mtval);
            $fatal(1, "TB_LSU FAIL");
        end
        n_checks = n_checks + 1; n_tval = n_tval + 1;

        // D-4：**页错误**（ptw 返回）时 mtval 也写 VA
        env_default;
        cur_priv = PRIV_M;                               // M 模式无 PMP 阻拦
        rs1 = 32'h0000_A000; imm = 32'd0;
        ptw_pa = 32'h0000_B000; ptw_fault = 1'b1;
        ptw_cause = `RV32GC_EXC_LOAD_PAGE_FAULT;         // 13
        mem_kind = A_LOAD; size = SZ_4B; req_valid = 1'b1; #1;
        check_cause("D4-page-fault", `RV32GC_EXC_LOAD_PAGE_FAULT);
        if (mtval !== 32'h0000_A000) begin
            $display("FAIL[D4]: 页错误 mtval 期望 VA=0xA000 实际 %08x", mtval);
            $fatal(1, "TB_LSU FAIL");
        end
        n_checks = n_checks + 1; n_tval = n_tval + 1;
        $display("  [MTVAL]  4 例通过（PMP/非对齐/页错误下 mtval 恒为 VA）");

        //======================================================================
        // 组 E：核内 MMIO 分流 —— CLINT/PLIC **绝不发 AXI**（§5.4 ⑦ / §6.6）
        //======================================================================
        env_default;
        cur_priv = PRIV_M; mem_kind = A_LOAD; size = SZ_4B;
        ptw_fault = 1'b0; req_valid = 1'b1;

        // E-1：CLINT 0x1F00_0000 ⇒ ROUTE_CLINT 且 no_axi=1
        rs1 = 32'h1F00_0000; imm = 32'd0; ptw_pa = 32'h1F00_0000; #1;
        if (route !== ROUTE_CLINT || no_axi !== 1'b1 || clint_plic !== 1'b1) begin
            $display("FAIL[E1]: CLINT 分流错 route=%0d no_axi=%b", route, no_axi);
            $fatal(1, "TB_LSU FAIL");
        end
        if (axi_cache !== `RV32GC_AXI_CACHE_UNCACHED) begin
            $display("FAIL[E1]: CLINT 应为非缓存"); $fatal(1, "TB_LSU FAIL");
        end
        n_checks = n_checks + 2; n_mmio = n_mmio + 1;

        // E-2：CLINT mtime 偏移 0x1F00_BFF8
        rs1 = 32'h1F00_BFF8; ptw_pa = 32'h1F00_BFF8; #1;
        if (route !== ROUTE_CLINT || no_axi !== 1'b1) begin
            $display("FAIL[E2]: CLINT mtime 分流错 route=%0d", route);
            $fatal(1, "TB_LSU FAIL");
        end
        n_checks = n_checks + 1; n_mmio = n_mmio + 1;

        // E-3：PLIC 0x1F10_0000 ⇒ ROUTE_PLIC 且 no_axi=1
        rs1 = 32'h1F10_0000; ptw_pa = 32'h1F10_0000; #1;
        if (route !== ROUTE_PLIC || no_axi !== 1'b1 || clint_plic !== 1'b1) begin
            $display("FAIL[E3]: PLIC 分流错 route=%0d no_axi=%b", route, no_axi);
            $fatal(1, "TB_LSU FAIL");
        end
        n_checks = n_checks + 2; n_mmio = n_mmio + 1;

        // E-4：XIP 主窗口 0x1C00_0000 ⇒ 直连（uncached），**不是**核内寄存器
        rs1 = 32'h1C00_0000; ptw_pa = 32'h1C00_0000; #1;
        if (route !== ROUTE_XIP || xip_direct !== 1'b1) begin
            $display("FAIL[E4]: XIP 主窗口分流错 route=%0d", route);
            $fatal(1, "TB_LSU FAIL");
        end
        if (axi_cache !== `RV32GC_AXI_CACHE_UNCACHED) begin
            $display("FAIL[E4]: XIP 应为非缓存"); $fatal(1, "TB_LSU FAIL");
        end
        n_checks = n_checks + 2; n_mmio = n_mmio + 1;

        // E-5：XIP 别名窗口 0x1FE8_0000 ⇒ 直连
        rs1 = 32'h1FE8_0000; ptw_pa = 32'h1FE8_0000; #1;
        if (route !== ROUTE_XIP || xip_direct !== 1'b1) begin
            $display("FAIL[E5]: XIP 别名分流错 route=%0d", route);
            $fatal(1, "TB_LSU FAIL");
        end
        n_checks = n_checks + 1; n_mmio = n_mmio + 1;

        // E-6：DDR3 0x0000_0000 ⇒ AXI 可缓存
        rs1 = 32'h0000_0000; ptw_pa = 32'h0000_0000; #1;
        if (route !== ROUTE_AXI || no_axi !== 1'b0 || axi_cac !== 1'b1) begin
            $display("FAIL[E6]: DDR3 分流错 route=%0d no_axi=%b cac=%b",
                     route, no_axi, axi_cac);
            $fatal(1, "TB_LSU FAIL");
        end
        if (axi_cache !== `RV32GC_AXI_CACHE_CACHED) begin
            $display("FAIL[E6]: DDR3 应为可缓存"); $fatal(1, "TB_LSU FAIL");
        end
        n_checks = n_checks + 2; n_mmio = n_mmio + 1;

        // E-7：平台外设 UART 0x1FE0_01E0 ⇒ AXI 非缓存
        rs1 = 32'h1FE0_01E0; ptw_pa = 32'h1FE0_01E0; #1;
        if (route !== ROUTE_AXI || axi_unc !== 1'b1) begin
            $display("FAIL[E7]: UART 应为 AXI 非缓存 route=%0d", route);
            $fatal(1, "TB_LSU FAIL");
        end
        n_checks = n_checks + 1; n_mmio = n_mmio + 1;

        // E-8：平台外设 NAND 0x1FE7_8000 ⇒ AXI 非缓存
        rs1 = 32'h1FE7_8000; ptw_pa = 32'h1FE7_8000; #1;
        if (route !== ROUTE_AXI || axi_unc !== 1'b1) begin
            $display("FAIL[E8]: NAND 应为 AXI 非缓存 route=%0d", route);
            $fatal(1, "TB_LSU FAIL");
        end
        n_checks = n_checks + 1; n_mmio = n_mmio + 1;
        $display("  [MMIO]   8 例通过（CLINT/PLIC 绝不发 AXI；XIP 直连；DDR3 可缓存）");

        //======================================================================
        // 组 F：拆笔接口（判据 ④ 的隐含要求：非对齐先于 PMP 的拆笔产物）
        //======================================================================
        env_default;
        cur_priv = PRIV_M; mem_kind = A_LOAD; size = SZ_4B;
        req_valid = 1'b1;
        // F-1：对齐 ⇒ 不拆
        rs1 = 32'h0000_C000; imm = 32'd0; ptw_pa = 32'h0000_C000; #1;
        if (split !== 1'b0 || num_beats !== 2'd1 || beat0_bytes !== 5'd4) begin
            $display("FAIL[F1]: 对齐不应拆笔 split=%b beats=%0d bytes=%0d",
                     split, num_beats, beat0_bytes);
            $fatal(1, "TB_LSU FAIL");
        end
        n_checks = n_checks + 1;
        // F-2：非对齐 4 B @0xC002 ⇒ 拆两笔 2B + 2B
        rs1 = 32'h0000_C002; #1;
        if (split !== 1'b1 || num_beats !== 2'd2) begin
            $display("FAIL[F2]: 非对齐应拆两笔 split=%b beats=%0d", split, num_beats);
            $fatal(1, "TB_LSU FAIL");
        end
        if (beat0_addr !== 32'h0000_C002 || beat0_bytes !== 5'd2 ||
            beat1_addr !== 32'h0000_C004 || beat1_bytes !== 5'd2) begin
            $display("FAIL[F2]: 拆笔地址/字节错 b0=%08x/%0d b1=%08x/%0d",
                     beat0_addr, beat0_bytes, beat1_addr, beat1_bytes);
            $fatal(1, "TB_LSU FAIL");
        end
        n_checks = n_checks + 2;
        // F-3：非对齐 lh（2 B @0xC003）⇒ 拆 1B + 1B
        rs1 = 32'h0000_C003; size = SZ_2B; #1;
        if (split !== 1'b1 || beat0_bytes !== 5'd1 || beat1_bytes !== 5'd1) begin
            $display("FAIL[F3]: lh 非对齐拆笔字节错 b0=%0d b1=%0d", beat0_bytes, beat1_bytes);
            $fatal(1, "TB_LSU FAIL");
        end
        n_checks = n_checks + 1;
        // F-4：非对齐 lb（1 B @0xC001）—— 1 B 恒对齐 ⇒ 不拆
        rs1 = 32'h0000_C001; size = SZ_1B; #1;
        if (split !== 1'b0 || misaligned !== 1'b0) begin
            $display("FAIL[F4]: 1 B 访问恒对齐，不应拆/不应判非对齐");
            $fatal(1, "TB_LSU FAIL");
        end
        n_checks = n_checks + 1;
        $display("  [SPLIT]  4 例通过（拆笔地址/字节数正确；1B 恒对齐）");

        //======================================================================
        // 组 G：AMO / LR-SC 数据通路（判据 ④ 的类型判定 + T4）
        //======================================================================
        env_default;
        cur_priv = PRIV_M; rs1 = 32'h0000_D000; imm = 32'd0;
        ptw_pa = 32'h0000_D000; req_valid = 1'b1;

        // G-1：AMOADD.W 的类型判定 ⇒ need_perm = W
        mem_kind = A_AMO; amo_f5 = `RV32GC_AMO_ADD; size = SZ_4B;
        store_data = 32'h0000_0005; #1;
        if (need_perm !== 2'b01) begin
            $display("FAIL[G1]: AMO need_perm 期望 W(01) 实际 %b", need_perm);
            $fatal(1, "TB_LSU FAIL");
        end
        n_checks = n_checks + 1;
        // G-2：LR.W 的类型判定 ⇒ need_perm = R（LR 是读）
        mem_kind = A_LR; amo_f5 = `RV32GC_AMO_LR; #1;
        if (need_perm !== 2'b10) begin
            $display("FAIL[G2]: LR need_perm 期望 R(10) 实际 %b", need_perm);
            $fatal(1, "TB_LSU FAIL");
        end
        n_checks = n_checks + 1;
        // G-3：SC.W 的类型判定 ⇒ need_perm = W
        mem_kind = A_SC; amo_f5 = `RV32GC_AMO_SC; #1;
        if (need_perm !== 2'b01) begin
            $display("FAIL[G3]: SC need_perm 期望 W(01) 实际 %b", need_perm);
            $fatal(1, "TB_LSU FAIL");
        end
        n_checks = n_checks + 1;
        // G-4：CMO 的类型判定 ⇒ need_perm = W（store/AMO 同族）
        mem_kind = A_CBO; cbo_rs2 = `RV32GC_CBO_INVAL; #1;
        if (need_perm !== 2'b01) begin
            $display("FAIL[G4]: CMO need_perm 期望 W(01) 实际 %b", need_perm);
            $fatal(1, "TB_LSU FAIL");
        end
        n_checks = n_checks + 1;

        // G-5：AMO 被 PMP 拒 ⇒ amo_unit 抛出恒 cause 7（T4）—— 用 AMO 且 PMP 拒
        set_entry(0, A_NA4, 1'b1, 1'b1, 1'b0, 1'b0);   // L=1 只有 R ⇒ AMO 需 W ⇒ 拒
        set_addr (0, 32'h0000_D000);
        cur_priv = PRIV_S;                              // S 模式受 PMP 约束
        mem_kind = A_AMO; amo_f5 = `RV32GC_AMO_ADD; #1;
        check_cause("G5-amo-pmp-cause7", C_ST_ACC);
        n_checks = n_checks;                            // 已计入

        $display("  [AMO]    5 例通过（AMO/LR/SC/CMO 类型判定；AMO 被拒恒 cause 7）");

        //======================================================================
        // 汇总
        //======================================================================
        $display("--------------------------------------------------------------");
        $display("  例数：ALIGN=%0d PRIO=%0d MPRV=%0d MTVAL=%0d MMIO=%0d",
                 n_align, n_prio, n_mprv, n_tval, n_mmio);
        $display("  总断言=%0d", n_checks);

        if (n_align < 8) begin
            $display("FAIL: 对齐访问例数不足（%0d < 8）", n_align);
            $fatal(1, "TB_LSU FAIL");
        end
        if (n_prio < 8) begin
            $display("FAIL: 优先级例数不足（%0d < 8）", n_prio);
            $fatal(1, "TB_LSU FAIL");
        end
        if (n_mprv < 6) begin
            $display("FAIL: MPRV 例数不足（%0d < 6）", n_mprv);
            $fatal(1, "TB_LSU FAIL");
        end
        if (n_tval < 4) begin
            $display("FAIL: mtval 例数不足（%0d < 4）", n_tval);
            $fatal(1, "TB_LSU FAIL");
        end
        if (n_mmio < 8) begin
            $display("FAIL: MMIO 例数不足（%0d < 8）", n_mmio);
            $fatal(1, "TB_LSU FAIL");
        end

        $display("TB_LSU: PASS");
        $finish;
    end

    // 超时保护
    initial begin
        #100000;
        $display("FAIL: 超时（TB 未在预期时间内完成）");
        $fatal(1, "TB_LSU FAIL");
    end

endmodule
