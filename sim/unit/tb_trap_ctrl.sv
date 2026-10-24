//==============================================================================
// tb_trap_ctrl.sv —— trap_ctrl + priv_ctrl 单元测试
//==============================================================================
// 测什么  : ① 同步异常 pc = BASE（Direct 与 Vectored 两种 MODE 下都是 BASE）；
//           ② **中断 pc = BASE + 4×cause**（Vectored；判据④核心）；
//              例：MTI cause=7 ⇒ BASE+0x1C；MEI cause=11 ⇒ BASE+0x2C；
//              Direct 下中断 pc = BASE；
//           ③ **xRET 到 S 清 MPRV / 回 M 不清**（T7；反证实验项，判据④）；
//           ④ **陷阱不从高特权级委托到低**（T5；判据④）：
//              (a) M 模式把 medeleg 全置 1 后，M 模式下发生非法指令 ⇒ 仍进 M；
//              (b) S 模式下发生被委托的异常 ⇒ 进 S（水平委托）；
//              (c) mideleg 置位时 M 模式不取该 S 级中断（norm:trap_del_intr_priv_lvl）；
//           ⑤ 中断只在已提交指令边界后取（**T6 本设计纪律**：commit_valid=0 时不取）；
//           ⑥ mepc/sepc 取值：同步异常 = 故障指令 PC；中断 = 下一未执行指令 PC；
//              epc bit0 恒 0；
//           ⑦ mtval：非法指令写**故障指令位**（T1）右对齐高位清零；其余写 VA；
//           ⑧ trap_target/epc 的 M/S 侧选择（E6：委托到 S 不写 M 侧）。
//           ⑨ **陷阱入口 xPP/xPIE/xIE 的置换语义**（R3 根因修复；§I）：
//              MPP ← 陷阱发生时的特权级 y（M→M ⇒ 3、S→M ⇒ 1）、SPP ← y（U→S ⇒ 0，
//              旧 SPP=1 不得残留）、MPIE ← MIE 取**陷阱前**值（同拍）。
// 怎么判  : 每条断言具体数值；失败即 $fatal（非零退出），兜底分支不含 PASS。
// 失败长什么样: `TB_TRAP FAIL: <项> got=... exp=...` 后 $fatal(1, "TB_TRAP_CTRL_UNIT: FAIL")。
// 顶层    : tb_trap_ctrl_top（验收命令用 -s tb_trap_ctrl_top）
//==============================================================================
`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"

module tb_trap_ctrl_top;

    //--------------------------------------------------------------------------
    // 时钟/复位
    //--------------------------------------------------------------------------
    reg clk = 0;
    reg rst_n = 0;
    always #5 clk = ~clk;

    //--------------------------------------------------------------------------
    // DUT 输入
    //--------------------------------------------------------------------------
    reg         commit_valid = 0;
    reg  [31:0] commit_pc = 32'h0;
    reg  [31:0] commit_pc_next = 32'h0;
    reg  [31:0] commit_insn = 32'h0;
    reg         exc_valid = 0;
    reg  [4:0]  exc_cause = 5'd0;
    reg  [31:0] exc_tval = 32'h0;
    reg         exc_is_fetch = 0;
    reg  [1:0]  priv = `RV32GC_PRIV_M;
    reg  [31:0] medeleg = 32'h0;
    reg  [31:0] mideleg = 32'h0;
    reg  [31:0] mip = 32'h0;
    reg  [31:0] mie = 32'h0;
    reg  [31:0] mstatus_i = 32'h0;
    reg  [31:0] mtvec = 32'h0;
    reg  [31:0] stvec = 32'h0;

    wire        trap_valid, trap_is_int;
    wire [1:0]  trap_target;
    wire [31:0] trap_cause, trap_tval, trap_epc, trap_pc, redirect_pc;
    wire [3:0]  trap_we;
    wire [31:0] trap_epc_i, trap_cause_i, trap_tval_i, trap_data_i;
    wire        trap_wr_m_epc, trap_wr_m_cause, trap_wr_m_tval;
    wire        trap_wr_s_epc, trap_wr_s_cause, trap_wr_s_tval;

    trap_ctrl dut (
        .commit_valid(commit_valid), .commit_pc(commit_pc),
        .commit_pc_next(commit_pc_next), .commit_insn(commit_insn),
        .exc_valid(exc_valid), .exc_cause(exc_cause), .exc_tval(exc_tval),
        .exc_is_fetch(exc_is_fetch),
        .priv(priv), .medeleg(medeleg), .mideleg(mideleg),
        .mip(mip), .mie(mie), .mstatus_i(mstatus_i),
        .mtvec(mtvec), .stvec(stvec),
        .trap_valid(trap_valid), .trap_is_int(trap_is_int),
        .trap_target(trap_target), .trap_cause(trap_cause),
        .trap_tval(trap_tval), .trap_epc(trap_epc), .trap_pc(trap_pc),
        .trap_we(trap_we), .trap_epc_i(trap_epc_i), .trap_cause_i(trap_cause_i),
        .trap_tval_i(trap_tval_i), .trap_data_i(trap_data_i),
        .trap_wr_m_epc(trap_wr_m_epc), .trap_wr_m_cause(trap_wr_m_cause),
        .trap_wr_m_tval(trap_wr_m_tval),
        .trap_wr_s_epc(trap_wr_s_epc), .trap_wr_s_cause(trap_wr_s_cause),
        .trap_wr_s_tval(trap_wr_s_tval),
        .redirect_pc(redirect_pc)
    );

    //--------------------------------------------------------------------------
    // priv_ctrl DUT（与 trap_ctrl 串接，验证 xRET/MPRV 组合）
    //--------------------------------------------------------------------------
    reg  [31:0] p_mstatus_i = 32'h0;
    reg         p_csr_wen = 0;
    reg  [11:0] p_csr_waddr = 12'h0;
    reg  [31:0] p_csr_wdata = 32'h0;
    reg         p_trap_valid = 0;
    reg  [1:0]  p_trap_target = `RV32GC_PRIV_M;
    reg         p_xret_valid = 0;
    reg  [1:0]  p_xret_kind = 2'b01;
    wire [31:0] p_mstatus_set, p_mstatus_clr;
    wire [1:0]  p_xret_target_priv;
    reg  [31:0] k_land;
    wire [1:0]  p_priv_o, p_eff_priv_o, p_priv_next_o;
    wire        p_mprv_o, p_sum_o, p_mxr_o, p_tvm_o, p_tw_o, p_tsr_o;
    wire [1:0]  p_mpp_o;
    wire        p_fetch_m, p_flush_req;

    priv_ctrl pdut (
        .clk(clk), .rst_n(rst_n),
        .trap_valid(p_trap_valid), .trap_target(p_trap_target),
        .xret_valid(p_xret_valid), .xret_kind(p_xret_kind),
        .mstatus_i(p_mstatus_i), .csr_wen(p_csr_wen),
        .csr_waddr(p_csr_waddr), .csr_wdata(p_csr_wdata),
        .mstatus_set(p_mstatus_set), .mstatus_clr(p_mstatus_clr),
        .xret_target_priv_o(p_xret_target_priv),
        .priv_o(p_priv_o), .eff_priv_o(p_eff_priv_o),
        .mprv_o(p_mprv_o), .sum_o(p_sum_o), .mxr_o(p_mxr_o),
        .mpp_o(p_mpp_o), .tvm_o(p_tvm_o), .tw_o(p_tw_o), .tsr_o(p_tsr_o),
        .fetch_priv_is_m_o(p_fetch_m), .flush_req(p_flush_req),
        .priv_next_o(p_priv_next_o)
    );

    //--------------------------------------------------------------------------
    // 记分板
    //--------------------------------------------------------------------------
    integer n_pass = 0, n_fail = 0;
    reg     sim_ok = 1'b0;   // 仅在全部检查通过后置 1

    task expect_eq32;
        input [8*256-1:0] name; input [31:0] got; input [31:0] exp;
        begin
            if (got !== exp) begin
                $display("TB_TRAP FAIL: %0s got=0x%08x exp=0x%08x", name, got, exp);
                n_fail = n_fail + 1;
            end else n_pass = n_pass + 1;
        end
    endtask

    task expect_eq1;
        input [8*256-1:0] name; input got; input exp;
        begin
            if (got !== exp) begin
                $display("TB_TRAP FAIL: %0s got=%0b exp=%0b", name, got, exp);
                n_fail = n_fail + 1;
            end else n_pass = n_pass + 1;
        end
    endtask

    // ---- mstatus 字段便捷构造 ----
    function [31:0] mk_mstatus;
        input mie_b, sie_b, mpie_b, spie_b, spp_b, mprv_b, sum_b, mxr_b;
        input [1:0] mpp;
        begin
            mk_mstatus = ({31'b0, mie_b}  << `RV32GC_MSTATUS_MIE_BIT)  |
                         ({31'b0, sie_b}  << `RV32GC_MSTATUS_SIE_BIT)  |
                         ({31'b0, mpie_b} << `RV32GC_MSTATUS_MPIE_BIT) |
                         ({31'b0, spie_b} << `RV32GC_MSTATUS_SPIE_BIT) |
                         ({31'b0, spp_b}  << `RV32GC_MSTATUS_SPP_BIT)  |
                         ({31'b0, mprv_b} << `RV32GC_MSTATUS_MPRV_BIT) |
                         ({31'b0, sum_b}  << `RV32GC_MSTATUS_SUM_BIT)  |
                         ({31'b0, mxr_b}  << `RV32GC_MSTATUS_MXR_BIT)  |
                         ({30'b0, mpp}    << `RV32GC_MSTATUS_MPP_LSB);
        end
    endfunction

    // ★ 落盘值 = csr_file 的 `(stored & ~clr) | set`（同拍 xret/trap 的独立 gold）
    function [31:0] land_mstat;
        input [31:0] pre;
        input [31:0] set;
        input [31:0] clr;
        begin
            land_mstat = (pre & ~clr) | set;
        end
    endfunction

    //--------------------------------------------------------------------------
    // 主测试
    //--------------------------------------------------------------------------
    initial begin
        $display("---- tb_trap_ctrl: trap_ctrl + priv_ctrl 单元测试 ----");

        //======================================================================
        // 前置：复位 priv_ctrl（复位进 M）
        //======================================================================
        rst_n = 0; repeat(4) @(posedge clk); #1;
        rst_n = 1; repeat(2) @(posedge clk); #1;
        expect_eq32("复位后特权级 = M(2'b11)", {30'b0, p_priv_o}, 32'h3);

        //======================================================================
        // A. 【判据④】同步异常 pc = BASE（Vectored 模式下同步异常也走 BASE）
        //======================================================================
        //   设 mtvec 为 Vectored，BASE = 0x1C00_0100（256 B 对齐）
        mtvec = 32'h1C00_0101;   // MODE=1 Vectored
        commit_valid = 1'b1;
        commit_pc = 32'h8000_1000; commit_pc_next = 32'h8000_1004;
        commit_insn = 32'h0000_0073;   // ecall
        priv = `RV32GC_PRIV_M;
        medeleg = 32'h0;
        exc_valid = 1'b1; exc_cause = `RV32GC_EXC_ECALL_M; exc_tval = 32'h0;
        #1;
        expect_eq1("同步异常 trap_valid=1", trap_valid, 1'b1);
        expect_eq1("同步异常 trap_is_int=0", trap_is_int, 1'b0);
        expect_eq32("同步异常 pc = BASE（Vectored 下亦然）",
                    trap_pc, 32'h1C00_0100);
        expect_eq32("同步异常 mepc = 故障指令 PC",
                    trap_epc, 32'h8000_1000);
        expect_eq32("同步异常 cause = 11（ecall from M）",
                    trap_cause, 32'h0000_000B);
        expect_eq1("同步异常目标 = M", trap_target == `RV32GC_PRIV_M, 1'b1);

        //   ---- Direct 模式下同步异常 pc 也 = BASE ----
        mtvec = 32'h1C00_0200;   // MODE=0 Direct
        #1;
        expect_eq32("Direct 下同步异常 pc = BASE", trap_pc, 32'h1C00_0200);

        //======================================================================
        // B. 【判据④核心】中断 pc = BASE + 4×cause（Vectored）
        //======================================================================
        //   mtvec BASE = 0x1C00_0000，MODE=1
        mtvec = 32'h1C00_0001;
        priv  = `RV32GC_PRIV_M;
        mstatus_i = mk_mstatus(1'b1, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, `RV32GC_PRIV_M);
        exc_valid = 1'b0;
        mideleg   = 32'h0;
        mie       = 32'h0000_0888;   // MSIE|MTIE|MEIE
        //   ---- MTI：cause=7 ⇒ BASE+0x1C ----
        mip = (32'h1 << `RV32GC_MIP_MTIP_BIT); #1;
        expect_eq1("MTI 中断被取", trap_valid, 1'b1);
        expect_eq1("MTI trap_is_int=1", trap_is_int, 1'b1);
        expect_eq32("MTI cause = 0x8000_0007", trap_cause, 32'h8000_0007);
        expect_eq32("MTI pc = BASE + 4×7 = BASE+0x1C",
                    trap_pc, 32'h1C00_0000 + 32'h1C);
        //   ---- MEI：cause=11 ⇒ BASE+0x2C ----
        mip = (32'h1 << `RV32GC_MIP_MEIP_BIT); #1;
        expect_eq32("MEI pc = BASE + 4×11 = BASE+0x2C",
                    trap_pc, 32'h1C00_0000 + 32'h2C);
        expect_eq32("MEI cause = 0x8000_000B", trap_cause, 32'h8000_000B);
        //   ---- MSI：cause=3 ⇒ BASE+0x0C ----
        mip = (32'h1 << `RV32GC_MIP_MSIP_BIT); #1;
        expect_eq32("MSI pc = BASE + 4×3 = BASE+0x0C",
                    trap_pc, 32'h1C00_0000 + 32'h0C);

        //   ---- ★ 反证：Direct 模式下中断 pc = BASE（无 +4×cause）----
        mtvec = 32'h1C00_0000;   // MODE=0 Direct
        mip = (32'h1 << `RV32GC_MIP_MTIP_BIT); #1;
        expect_eq32("Direct 下中断 pc = BASE（无向量偏移）",
                    trap_pc, 32'h1C00_0000);

        //   ---- ★ 中断 epc = 下一未执行指令 PC（T6）----
        mtvec = 32'h1C00_0001;   // 回到 Vectored
        commit_pc = 32'h8000_2000; commit_pc_next = 32'h8000_2004;
        #1;
        expect_eq32("中断 epc = 下一未执行指令（pc_next）",
                    trap_epc, 32'h8000_2004);
        //   ---- epc bit0 恒 0（IALIGN=16）----
        commit_pc_next = 32'h8000_2005; #1;
        expect_eq32("中断 epc bit0 恒 0", trap_epc, 32'h8000_2004);

        //======================================================================
        // C. 【T6 本设计纪律】中断只在已提交指令边界后取
        //======================================================================
        //   ★ 反证：commit_valid=0 ⇒ 中断**不得**被取（否则 mepc 指向的指令
        //     重执行会重复副作用）。
        commit_valid = 1'b0;
        mip = (32'h1 << `RV32GC_MIP_MTIP_BIT); #1;
        expect_eq1("commit_valid=0 时不取中断（T6 纪律）", trap_valid, 1'b0);
        commit_valid = 1'b1; #1;
        expect_eq1("commit_valid=1 时取中断", trap_valid, 1'b1);

        //======================================================================
        // D. 【判据④】陷阱不从高特权级委托到低（T5）
        //======================================================================
        //   ---- (a) M 模式下，medeleg 全置 1，非法指令仍进 M ----
        medeleg = 32'hFFFF_FFFF;
        mip = 32'h0; exc_valid = 1'b1;
        exc_cause = `RV32GC_EXC_ILLEGAL_INSN; commit_insn = 32'hDEAD_BEEF;
        priv = `RV32GC_PRIV_M; #1;
        expect_eq1("★ M 模式陷阱不委托（目标 = M）",
                   trap_target == `RV32GC_PRIV_M, 1'b1);
        expect_eq32("M 模式非法指令 cause=2", trap_cause, 32'h0000_0002);

        //   ---- (b) S 模式下，被委托的非法指令 ⇒ 进 S（水平委托）----
        priv = `RV32GC_PRIV_S; #1;
        expect_eq1("★ S 模式被委托异常 ⇒ 目标 = S",
                   trap_target == `RV32GC_PRIV_S, 1'b1);
        expect_eq1("S 目标时 trap_we[1]=1（写 S 侧组）", trap_we[1], 1'b1);
        expect_eq1("S 目标时 trap_we[0]=0（不写 M 侧组）", trap_we[0], 1'b0);
        expect_eq1("S 目标时 trap_wr_m_epc=0（不写 mepc）", trap_wr_m_epc, 1'b0);
        expect_eq1("S 目标时 trap_wr_s_epc=1（写 sepc）", trap_wr_s_epc, 1'b1);

        //   ---- (c) U 模式下，被委托的 ecall ⇒ 进 S ----
        priv = `RV32GC_PRIV_U; exc_cause = `RV32GC_EXC_ECALL_U; #1;
        expect_eq1("U 模式 ecall 被委托 ⇒ 目标 = S",
                   trap_target == `RV32GC_PRIV_S, 1'b1);
        expect_eq32("U 模式 ecall cause=8", trap_cause, 32'h0000_0008);

        //   ---- (d) S 模式下，**未**被委托的异常 ⇒ 进 M ----
        medeleg = 32'h0; #1;
        expect_eq1("S 模式未委托异常 ⇒ 目标 = M",
                   trap_target == `RV32GC_PRIV_M, 1'b1);

        //   ---- (e) mideleg 置位时，M 模式**不取**该 S 级中断（norm:trap_del_intr_priv_lvl）----
        exc_valid = 1'b0;
        mideleg = `RV32GC_MIDELEG_IMPL_MSK;   // 1|5|9 delegated
        mie     = 32'h0000_0222;              // SSIE|STIE|SEIE
        priv    = `RV32GC_PRIV_M;
        mstatus_i = mk_mstatus(1'b1, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, `RV32GC_PRIV_M);
        mip = (32'h1 << `RV32GC_MIP_STIP_BIT); #1;
        expect_eq1("★ M 模式不取已被委托的 STI", trap_valid, 1'b0);
        //   ---- S 模式下取该 STI，且进 S ----
        priv = `RV32GC_PRIV_S;
        mstatus_i = mk_mstatus(1'b0, 1'b1, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, `RV32GC_PRIV_S);
        stvec = 32'h1C00_1001;   // Vectored, BASE=0x1C00_1000
        #1;
        expect_eq1("S 模式取被委托的 STI", trap_valid, 1'b1);
        expect_eq1("STI 目标 = S", trap_target == `RV32GC_PRIV_S, 1'b1);
        expect_eq32("STI pc（stvec） = BASE + 4×5 = BASE+0x14",
                    trap_pc, 32'h1C00_1000 + 32'h14);

        //======================================================================
        // E. mtval 取值（T1）
        //======================================================================
        //   ---- 非法指令 ⇒ 写**故障指令位**（右对齐、高位清零）----
        priv = `RV32GC_PRIV_M; medeleg = 32'h0;
        exc_valid = 1'b1; exc_cause = `RV32GC_EXC_ILLEGAL_INSN;
        commit_insn = 32'hDEAD_BEEF; exc_tval = 32'h1234_5678; #1;
        expect_eq32("★ 非法指令 mtval = 故障指令位", trap_tval, 32'hDEAD_BEEF);
        //   ---- 非法指令为 16 bit 压缩指令 ⇒ 高位清零 ----
        commit_insn = 32'h0000_C001; #1;
        expect_eq32("压缩非法指令 mtval 高位清零", trap_tval, 32'h0000_C001);
        //   ---- 其它异常 ⇒ 写 VA（exc_tval）----
        exc_cause = `RV32GC_EXC_LOAD_PAGE_FAULT; exc_tval = 32'hBEEF_0000; #1;
        expect_eq32("缺页 mtval = 虚拟地址", trap_tval, 32'hBEEF_0000);
        exc_cause = `RV32GC_EXC_INSN_ACCESS_FAULT; exc_tval = 32'h1C00_0002; #1;
        expect_eq32("取指 PMP 故障 mtval = 故障 parcel 的 VA",
                    trap_tval, 32'h1C00_0002);
        //   ---- 中断 ⇒ mtval = 0 ----
        //   显式造一个"纯中断"场景：无异常 + MTIP 挂起 + MTIE 使能 + MIE=1 + M 模式。
        exc_valid = 1'b0; exc_tval = 32'h1C00_0002;   // 故意留旧值以证明被忽略
        priv      = `RV32GC_PRIV_M;
        medeleg   = 32'h0; mideleg = 32'h0;
        mie       = 32'h0000_0880;                    // MTIE
        mstatus_i = mk_mstatus(1'b1, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, `RV32GC_PRIV_M);
        mip       = (32'h1 << `RV32GC_MIP_MTIP_BIT);
        #1;
        expect_eq1("纯中断场景 trap_is_int=1", trap_is_int, 1'b1);
        expect_eq32("中断 mtval = 0（忽略残留 exc_tval）", trap_tval, 32'h0);

        //======================================================================
        // F. 中断优先级（M 级优先于 S 级；norm:intr_M_mode_highest_pri）
        //======================================================================
        mideleg = 32'h0;   // 全部不委托 ⇒ 都进 M
        mie = 32'h0000_0AAA;
        //   ★ 必须显式把模式与全局使能复位到基线，否则会带上上一节的残留状态
        priv = `RV32GC_PRIV_M;
        mstatus_i = mk_mstatus(1'b1, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, `RV32GC_PRIV_M);
        mip = (32'h1<<`RV32GC_MIP_MEIP_BIT)|(32'h1<<`RV32GC_MIP_MTIP_BIT)|
              (32'h1<<`RV32GC_MIP_MSIP_BIT)|(32'h1<<`RV32GC_MIP_SEIP_BIT)|
              (32'h1<<`RV32GC_MIP_STIP_BIT)|(32'h1<<`RV32GC_MIP_SSIP_BIT); #1;
        expect_eq32("多中断同挂起 ⇒ 取 MEI(11)（M 级最高优先）",
                    trap_cause, 32'h8000_000B);

        //   ---- 全局使能门控：M 模式 MIE=0 ⇒ 不取 ----
        mstatus_i = mk_mstatus(1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, `RV32GC_PRIV_M); #1;
        expect_eq1("M 模式 MIE=0 ⇒ 不取中断", trap_valid, 1'b0);
        //   ---- S 模式看 SIE ----
        priv = `RV32GC_PRIV_S;
        mstatus_i = mk_mstatus(1'b0, 1'b1, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, `RV32GC_PRIV_S); #1;
        expect_eq1("S 模式 SIE=1 ⇒ 取中断", trap_valid, 1'b1);

        //======================================================================
        // G. 【判据④】xRET：到 S 清 MPRV、回 M **不清**（T7；反证实验项）
        //======================================================================
        //   ---- G1：mret 回 M（MPP=M）⇒ MPRV **保持 1** ----
        p_mstatus_i = mk_mstatus(1'b0, 1'b0, 1'b1, 1'b0, 1'b0, 1'b1, 1'b0, 1'b0, `RV32GC_PRIV_M);
        p_csr_wen = 1'b0;
        p_xret_valid = 1'b1; p_xret_kind = 2'b01;   // mret
        #1;
        //   目标 = MPP = M ⇒ 不清 MPRV
        expect_eq32("xRET 目标特权级 = M", {30'b0, p_priv_next_o}, 32'h3);
        expect_eq1("★ mret 回 M **不清** MPRV（mstatus_clr 无 MPRV 位）",
                   p_mstatus_clr[`RV32GC_MSTATUS_MPRV_BIT], 1'b0);

        //   ---- G2：mret 回 S（MPP=S）⇒ MPRV **被清** ----
        p_mstatus_i = mk_mstatus(1'b0, 1'b0, 1'b1, 1'b0, 1'b0, 1'b1, 1'b0, 1'b0, `RV32GC_PRIV_S);
        #1;
        expect_eq32("xRET 目标特权级 = S", {30'b0, p_priv_next_o}, 32'h1);
        expect_eq1("★ mret 回 S **清** MPRV",
                   p_mstatus_clr[`RV32GC_MSTATUS_MPRV_BIT], 1'b1);

        //   ---- G3：sret 目标 U（SPP=0）⇒ 清 MPRV ----
        p_mstatus_i = mk_mstatus(1'b0, 1'b0, 1'b0, 1'b1, 1'b0, 1'b1, 1'b0, 1'b0, `RV32GC_PRIV_M);
        p_xret_kind = 2'b00;   // sret
        #1;
        expect_eq32("sret 目标 = U", {30'b0, p_priv_next_o}, 32'h0);
        expect_eq1("sret 到 U 清 MPRV",
                   p_mstatus_clr[`RV32GC_MSTATUS_MPRV_BIT], 1'b1);
        //   ---- sret 目标 S（SPP=1）⇒ 也清 MPRV ----
        p_mstatus_i = mk_mstatus(1'b0, 1'b0, 1'b0, 1'b1, 1'b1, 1'b1, 1'b0, 1'b0, `RV32GC_PRIV_M);
        #1;
        expect_eq32("sret 目标 = S", {30'b0, p_priv_next_o}, 32'h1);
        expect_eq1("sret 到 S 清 MPRV",
                   p_mstatus_clr[`RV32GC_MSTATUS_MPRV_BIT], 1'b1);

        //   ---- G4：MIE←MPIE、MPIE←1 的置位/清除向量 ----
        p_xret_kind = 2'b01;   // mret
        p_mstatus_i = mk_mstatus(1'b0, 1'b0, 1'b1, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, `RV32GC_PRIV_M);
        #1;
        expect_eq1("mret 置 MPIE=1", p_mstatus_set[`RV32GC_MSTATUS_MPIE_BIT], 1'b1);
        expect_eq1("mret 清 MIE",    p_mstatus_clr[`RV32GC_MSTATUS_MIE_BIT],  1'b1);
        expect_eq1("mret MPIE=1 ⇒ set 里有 MIE", p_mstatus_set[`RV32GC_MSTATUS_MIE_BIT], 1'b1);
        expect_eq1("mret 清 MPP（再置 U）",
                   p_mstatus_clr[`RV32GC_MSTATUS_MPP_LSB], 1'b1);

        //   ---- G5：MPRV=1 时的有效特权级 = MPP（T7「按 MPP 语义」）----
        p_xret_valid = 1'b0; p_csr_wen = 1'b0;
        p_mstatus_i = mk_mstatus(1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b1, 1'b0, 1'b0, `RV32GC_PRIV_S);
        #1;
        expect_eq32("MPRV=1 ⇒ eff_priv = MPP = S", {30'b0, p_eff_priv_o}, 32'h1);
        p_mstatus_i = mk_mstatus(1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b1, 1'b0, 1'b0, `RV32GC_PRIV_M);
        #1;
        expect_eq32("MPRV=1 且 MPP=M ⇒ eff_priv = M（等效 M 权限）",
                    {30'b0, p_eff_priv_o}, 32'h3);
        //   ---- MPRV=0 ⇒ eff_priv = 当前特权级 ----
        p_mstatus_i = mk_mstatus(1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, `RV32GC_PRIV_S);
        #1;
        expect_eq32("MPRV=0 ⇒ eff_priv = 当前特权级",
                    {30'b0, p_eff_priv_o}, {30'b0, p_priv_o});

        //   ---- G6：SUM 只在有效特权级 S 时生效（含 MPRV=1 && MPP=S）----
        p_mstatus_i = mk_mstatus(1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b1, 1'b1, 1'b0, `RV32GC_PRIV_S);
        #1;
        expect_eq1("★ SUM=1 且 (MPRV=1,MPP=S) ⇒ sum_o=1", p_sum_o, 1'b1);
        p_mstatus_i = mk_mstatus(1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b1, 1'b1, 1'b0, `RV32GC_PRIV_M);
        #1;
        expect_eq1("★ SUM=1 但有效特权级 = M ⇒ sum_o=0", p_sum_o, 1'b0);

        //   ---- G7：MXR 只影响有效特权级 < M ----
        //   注：priv_ctrl 的架构特权级此刻仍是 M（复位值，本轮未做陷阱切换），
        //   故用 MPRV=1 && MPP=S 构造"有效特权级 = S"。
        p_mstatus_i = mk_mstatus(1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b1, 1'b0, 1'b1, `RV32GC_PRIV_S);
        #1;
        expect_eq32("MXR 用例：有效特权级 = S", {30'b0, p_eff_priv_o}, 32'h1);
        expect_eq1("MXR=1 且有效特权级 S ⇒ mxr_o=1", p_mxr_o, 1'b1);
        p_mstatus_i = mk_mstatus(1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b1, 1'b0, 1'b1, `RV32GC_PRIV_M);
        #1;
        expect_eq1("MXR=1 但有效特权级 = M ⇒ mxr_o=0", p_mxr_o, 1'b0);

        //   ---- G8：取指不受 MPRV 影响（取指恒用**当前**特权级，非有效特权级）----
        //   构造：当前特权级 = M（复位值）、MPRV=1 && MPP=S ⇒ eff_priv=S 但取指口径仍为 M。
        p_mstatus_i = mk_mstatus(1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b1, 1'b0, 1'b0, `RV32GC_PRIV_S);
        #1;
        expect_eq32("MPRV=1 && MPP=S ⇒ eff_priv = S", {30'b0, p_eff_priv_o}, 32'h1);
        expect_eq1("★ 取指不随 MPRV 变（当前特权级 = M ⇒ fetch_priv_is_m=1）",
                   p_fetch_m, 1'b1);

        //   ---- G9：同拍 CSR 旁路（06 §4 实现口径 1）----
        //   ★ 构造：架构 mstatus 的 MPRV=0 → eff_priv = 当前特权级 = M（复位值）。
        //     为让 SUM 生效，必须让**有效特权级 = S**。做法：CSR 写同时给出
        //     MPRV=1 && MPP=S && SUM=1，而架构值 mstatus_i = 0（全 0）。
        //     ⇒ 若旁路正确，SUM 与 MPRV/MPP 都必须立刻看到新值（sum_o=1）；
        //       若旁路缺失，则看到架构旧值 0 ⇒ sum_o=0。这就是本用例的判据。
        p_mstatus_i = 32'h0;   // 架构值 = 旧值（无 MPRV / 无 SUM）
        p_csr_wen  = 1'b1;
        p_csr_waddr = `RV32GC_CSR_MSTATUS;
        p_csr_wdata = mk_mstatus(1'b0,1'b0,1'b0,1'b0,1'b0, 1'b1, 1'b1, 1'b0, `RV32GC_PRIV_S);
        #1;
        expect_eq32("★ 同拍旁路：eff_priv 立刻看到新 MPP=S",
                    {30'b0, p_eff_priv_o}, 32'h1);
        expect_eq1("★ 同拍旁路：CSR 写 mstatus.SUM 立即生效（无需等 1 拍）",
                   p_sum_o, 1'b1);
        //   ---- 反证：关掉旁路（csr_wen=0，架构值仍为 0）⇒ SUM 必须为 0 ----
        p_csr_wen = 1'b0; #1;
        expect_eq1("反证：无 CSR 写时 SUM 取架构值 0 ⇒ sum_o=0", p_sum_o, 1'b0);
        //   ---- 架构值真的写入后 ⇒ 再确认一次 ----
        p_mstatus_i = mk_mstatus(1'b0,1'b0,1'b0,1'b0,1'b0, 1'b1, 1'b1, 1'b0, `RV32GC_PRIV_S);
        #1;
        expect_eq1("架构值写入后 sum_o=1", p_sum_o, 1'b1);
        p_mstatus_i = 32'h0; #1;

        //======================================================================
        // G10. 【P1-06】同拍旁路必须为**替换**语义：1→0 可清（旧树 OR ⇒ 必 FAIL）
        //   旧式 `(old & ~new) | (new & csr_wdata)` 代数等于 `old | csr_wdata`
        //   ⇒ 只能同拍置位、不能同拍清位。本节全部"1→0"断言即反证实验：
        //   把 priv_ctrl 的旁路改回 OR 语义，本节的清位断言必须 FAIL。
        //   ★ 只用真实接口（csr_wen/waddr/wdata、mstatus_i、mprv_o/sum_o/mxr_o/tvm_o/
        //     tw_o/tsr_o/mpp_o/eff_priv_o、mstatus_set/clr），不 force 内部状态。
        //======================================================================
        p_xret_valid = 1'b0; p_trap_valid = 1'b0;
        //   ---- G10a：MPRV/SUM/MXR/TVM/TW/TSR 全 1，同拍 csrw mstatus,0 ⇒ 全清 ----
        //     置 MPRV=1 && MPP=S 使有效特权级 = S（此时 SUM/MXR 才可能为 1）。
        p_mstatus_i = mk_mstatus(1'b1, 1'b1, 1'b1, 1'b1, 1'b1,
                                 1'b1, 1'b1, 1'b1, `RV32GC_PRIV_S) |
                      (32'h1 << `RV32GC_MSTATUS_TVM_BIT) |
                      (32'h1 << `RV32GC_MSTATUS_TW_BIT)  |
                      (32'h1 << `RV32GC_MSTATUS_TSR_BIT);
        p_csr_wen = 1'b0; p_csr_waddr = `RV32GC_CSR_MSTATUS; p_csr_wdata = 32'h0; #1;
        expect_eq1("G10a 前置：MPRV=1 && MPP=S ⇒ eff_priv=S 时 sum_o=1", p_sum_o, 1'b1);
        expect_eq1("G10a 前置：MXR=1 且 eff_priv=S ⇒ mxr_o=1", p_mxr_o, 1'b1);
        //   ---- 同拍写 mstatus=0 ----
        p_csr_wen = 1'b1; p_csr_wdata = 32'h0; #1;
        expect_eq1("★ G10a 同拍清 MPRV（旧树 OR 残留 1 ⇒ FAIL）", p_mprv_o, 1'b0);
        expect_eq32("★ G10a MPRV 清后 eff_priv = 当前特权级 M",
                    {30'b0, p_eff_priv_o}, 32'h3);
        expect_eq1("★ G10a 同拍清 SUM（旧树 OR 残留 1 ⇒ FAIL）", p_sum_o, 1'b0);
        expect_eq1("★ G10a 同拍清 MXR", p_mxr_o, 1'b0);
        expect_eq1("★ G10a 同拍清 TVM", p_tvm_o, 1'b0);
        expect_eq1("★ G10a 同拍清 TW",  p_tw_o,  1'b0);
        expect_eq1("★ G10a 同拍清 TSR", p_tsr_o, 1'b0);
        expect_eq32("★ G10a 同拍清 MPP ⇒ mpp_o=U(0)", {30'b0, p_mpp_o}, 32'h0);
        //   ---- G10b：MPP 1→0（S→U）同拍生效（旧树 OR 把 MPP 留成 S ⇒ eff=S）----
        p_mstatus_i = mk_mstatus(1'b0, 1'b0, 1'b0, 1'b0, 1'b0,
                                 1'b1, 1'b0, 1'b0, `RV32GC_PRIV_S);   // MPRV=1, MPP=S
        p_csr_wdata = mk_mstatus(1'b0, 1'b0, 1'b0, 1'b0, 1'b0,
                                 1'b1, 1'b0, 1'b0, `RV32GC_PRIV_U);   // MPRV=1, MPP=U
        #1;
        expect_eq32("★ G10b 同拍把 MPP 由 S 改 U ⇒ eff_priv=U（旧树残留 S ⇒ FAIL）",
                    {30'b0, p_eff_priv_o}, 32'h0);
        //   ---- G10c：sstatus 写掩码不得越界清 MPRV/MPP/TVM（也不得漏清 SUM/MXR）----
        p_mstatus_i = mk_mstatus(1'b1, 1'b1, 1'b1, 1'b1, 1'b1,
                                 1'b1, 1'b1, 1'b1, `RV32GC_PRIV_S) |
                      (32'h1 << `RV32GC_MSTATUS_TVM_BIT);
        p_csr_waddr = `RV32GC_CSR_SSTATUS; p_csr_wdata = 32'h0; #1;
        expect_eq1("★ G10c sstatus 写清 SUM（旧树 OR 残留 ⇒ FAIL）", p_sum_o, 1'b0);
        expect_eq1("★ G10c sstatus 写清 MXR（掩码内含 MXR）", p_mxr_o, 1'b0);
        expect_eq1("G10c sstatus 写**不**清 MPRV（掩码外，保留 1）", p_mprv_o, 1'b1);
        expect_eq1("G10c sstatus 写**不**清 TVM（掩码外，保留 1）", p_tvm_o, 1'b1);
        expect_eq32("G10c sstatus 写**不**改 MPP（仍 S）", {30'b0, p_mpp_o}, 32'h1);
        expect_eq32("G10c MPRV=1 && MPP=S ⇒ eff_priv 仍 S", {30'b0, p_eff_priv_o}, 32'h1);
        //   ---- G10d：MPP 保留编码 WARL 合法性（写 2'b10 ⇒ 使用点合法化为 S）----
        p_csr_waddr = `RV32GC_CSR_MSTATUS;
        p_csr_wdata = mk_mstatus(1'b0, 1'b0, 1'b0, 1'b0, 1'b0,
                                 1'b1, 1'b0, 1'b0, 2'b10);   // MPRV=1, MPP=2'b10(保留)
        #1;
        expect_eq32("G10d MPP=2'b10(保留) ⇒ mpp_o 合法化为 S", {30'b0, p_mpp_o}, 32'h1);
        expect_eq32("G10d MPP 合法化后 eff_priv=S", {30'b0, p_eff_priv_o}, 32'h1);
        //   ---- G10e：MIE 1→0 同拍可见（用 trap 入口的 mstatus_set 真实输出观测）----
        //     同拍：csrw mstatus,0（清 MIE） + 陷阱进 M ⇒ MPIE ← f_mie 必须为 0。
        p_mstatus_i = mk_mstatus(1'b1, 1'b0, 1'b0, 1'b0, 1'b0,
                                 1'b0, 1'b0, 1'b0, `RV32GC_PRIV_M);   // 架构 MIE=1
        p_csr_wen = 1'b0; p_trap_valid = 1'b1; p_trap_target = `RV32GC_PRIV_M; #1;
        expect_eq1("G10e 前置（无 CSR 写）：陷阱进 M ⇒ MPIE ← MIE(1)",
                   p_mstatus_set[`RV32GC_MSTATUS_MPIE_BIT], 1'b1);
        //   同一组合拍内加入 CSR 写（无时钟沿）：MIE 必须立刻被清 ⇒ MPIE ← 0。
        p_csr_wen = 1'b1; p_csr_waddr = `RV32GC_CSR_MSTATUS; p_csr_wdata = 32'h0; #1;
        expect_eq1("★ G10e 同拍清 MIE ⇒ 陷阱 MPIE ← 0（旧树 OR 残留 MIE=1 ⇒ FAIL）",
                   p_mstatus_set[`RV32GC_MSTATUS_MPIE_BIT], 1'b0);
        //   ---- G10f：SIE 1→0 同拍可见（sstatus 写 + 陷阱进 S ⇒ SPIE ← f_sie = 0）----
        p_csr_wen = 1'b0; p_trap_valid = 1'b0; #1;
        p_mstatus_i = mk_mstatus(1'b0, 1'b1, 1'b0, 1'b0, 1'b0,
                                 1'b0, 1'b0, 1'b0, `RV32GC_PRIV_M);   // 架构 SIE=1
        p_csr_waddr = `RV32GC_CSR_SSTATUS; p_csr_wdata = 32'h0;
        p_csr_wen = 1'b1;
        p_trap_valid = 1'b1; p_trap_target = `RV32GC_PRIV_S; #1;
        expect_eq1("★ G10f 同拍清 SIE ⇒ S 陷阱 SPIE ← 0（旧树 OR 残留 SIE=1 ⇒ FAIL）",
                   p_mstatus_set[`RV32GC_MSTATUS_SPIE_BIT], 1'b0);
        p_csr_wen = 1'b0; p_trap_valid = 1'b0; #1;

        //======================================================================
        // H. 特权级状态机：陷阱改特权级 + flush_req
        //======================================================================
        //   ---- 先回到 M（复位），再委托一个陷阱到 S ⇒ 特权级变化 ⇒ flush_req=1 ----
        rst_n = 0; repeat(3) @(posedge clk); #1; rst_n = 1;
        repeat(2) @(posedge clk); #1;
        expect_eq32("复位后特权级 = M", {30'b0, p_priv_o}, 32'h3);
        //   ★ 目标 = S 与当前 M 不同 ⇒ flush_req=1
        p_trap_valid = 1'b1; p_trap_target = `RV32GC_PRIV_S;
        #1;
        expect_eq1("★ 特权级变化（M→S）⇒ flush_req=1", p_flush_req, 1'b1);
        @(posedge clk); #1;
        expect_eq32("陷阱后特权级 = S", {30'b0, p_priv_o}, 32'h1);
        p_trap_valid = 1'b0;
        //   ---- 目标与当前相同（S→S）⇒ flush_req=0 ----
        p_trap_valid = 1'b1; p_trap_target = `RV32GC_PRIV_S; #1;
        expect_eq1("目标特权级不变（S→S）⇒ flush_req=0", p_flush_req, 1'b0);
        p_trap_valid = 1'b0; #1;

        //======================================================================
        // I. 【R3 根因修复】陷阱入口 xPP ← y **替换**语义 + MPIE ← MIE 同拍取前值
        //    （ISA norm:mstatusxpiexiexpptrap_op：
        //      「xPIE is set to the value of xIE; xIE is set to 0; xPP is set to y」）
        //----------------------------------------------------------------------
        //   旧实现两处错（本轮已在 priv_ctrl.v §3.1 修复）：
        //     ① xPP 写的是**旧 xPP**（M 侧 `mpp_l` ← mstatus.MPP；S 侧 `f_spp`），
        //        而规范要求 xPP ← **陷阱发生时的特权级 y**；
        //     ② 只置位不替换：csr_file 落地是 `(stored & ~clr) | set`（OR 语义）
        //        ⇒ "置 0"（f_mie=0 / SPP=U）必须显式进 clr，否则旧值残留。
        //   ★ 本节即**反证实验**：把 priv_ctrl 的 `priv_r` 换回 `mpp_l`/`f_spp`，
        //     或从 clr 里去掉 MPIE/SPIE/SPP 位，本节断言必须 FAIL。
        //   （"xRET 后特权级与 MPP 读回"的端到端用例在 tb_csr_file.sv §S，
        //     那里 csr_file 的存储与 priv_ctrl 的判定接成真实闭环。）
        //======================================================================
        //   ---- I0：清起点（复位回 M；复位会清 priv_r 的既有状态）----
        rst_n = 0; repeat(3) @(posedge clk); #1; rst_n = 1; repeat(2) @(posedge clk); #1;
        expect_eq32("I0 复位后特权级 = M", {30'b0, p_priv_o}, 32'h3);

        //   ---- I1：M→M 陷阱 ⇒ MPP ← y = M(3)；旧 MPP=U 不得残留 ----
        p_csr_wen = 1'b0;
        p_mstatus_i = mk_mstatus(1'b1, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, `RV32GC_PRIV_U);
        p_trap_valid = 1'b1; p_trap_target = `RV32GC_PRIV_M; #1;
        expect_eq32("★ I1 M→M 陷阱：MPP ← y = M(3)（替换；旧 MPP=U 不残留）",
                    (p_mstatus_set >> `RV32GC_MSTATUS_MPP_LSB) & 32'h3, 32'h3);
        expect_eq1("★ I1 MPP 字段进 clr（先清后置 = 替换，非 OR）",
                   p_mstatus_clr[`RV32GC_MSTATUS_MPP_LSB], 1'b1);
        expect_eq1("I1 MPP 高位置位与低位一致（MPP[1]）",
                   p_mstatus_set[`RV32GC_MSTATUS_MPP_LSB + 1], 1'b1);
        @(posedge clk); #1; p_trap_valid = 1'b0; #1;

        //   ---- I2 前置：mret(MPP=S) ⇒ 特权级降为 S（合法路径，不依赖委托）----
        p_mstatus_i = mk_mstatus(1'b0, 1'b0, 1'b1, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, `RV32GC_PRIV_S);
        p_xret_valid = 1'b1; p_xret_kind = 2'b01; #1;
        expect_eq32("I2 前置：mret 目标 = MPP = S", {30'b0, p_priv_next_o}, 32'h1);
        @(posedge clk); #1; p_xret_valid = 1'b0; #1;
        expect_eq32("I2 前置：mret 后特权级 = S", {30'b0, p_priv_o}, 32'h1);

        //   ---- I2：从 S 陷入 M ⇒ MPP ← y = S(1)（旧实现写旧 MPP=0，必 FAIL）----
        p_mstatus_i = mk_mstatus(1'b1, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, `RV32GC_PRIV_U);
        p_trap_valid = 1'b1; p_trap_target = `RV32GC_PRIV_M; #1;
        expect_eq32("★ I2 S→M 陷阱：MPP ← y = S(1)",
                    (p_mstatus_set >> `RV32GC_MSTATUS_MPP_LSB) & 32'h3, 32'h1);
        @(posedge clk); #1; p_trap_valid = 1'b0; #1;
        expect_eq32("I2 后：特权级 = M（陷阱目标）", {30'b0, p_priv_o}, 32'h3);

        //   ---- I3 前置：sret(SPP=0) ⇒ 特权级降为 U ----
        //   先制造 "priv = S"：从 M 取一个委托到 S 的陷阱
        p_mstatus_i = mk_mstatus(1'b1, 1'b1, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, `RV32GC_PRIV_U);
        p_trap_valid = 1'b1; p_trap_target = `RV32GC_PRIV_S; #1;
        @(posedge clk); #1; p_trap_valid = 1'b0; #1;
        expect_eq32("I3 前置：M→S 陷阱后特权级 = S", {30'b0, p_priv_o}, 32'h1);
        p_mstatus_i = mk_mstatus(1'b0, 1'b0, 1'b0, 1'b1, 1'b0, 1'b0, 1'b0, 1'b0, `RV32GC_PRIV_S);
        p_xret_valid = 1'b1; p_xret_kind = 2'b00; #1;
        expect_eq32("I3 前置：sret(SPP=0) 目标 = U", {30'b0, p_priv_next_o}, 32'h0);
        @(posedge clk); #1; p_xret_valid = 1'b0; #1;
        expect_eq32("I3 前置：特权级 = U", {30'b0, p_priv_o}, 32'h0);

        //   ---- I3：U→S 陷阱，mstatus 里旧 SPP=1（S 陷阱残留）⇒ SPP 必须 ← y = U(0) ----
        p_mstatus_i = mk_mstatus(1'b0, 1'b1, 1'b0, 1'b0, 1'b1, 1'b0, 1'b0, 1'b0, `RV32GC_PRIV_M);
        p_trap_valid = 1'b1; p_trap_target = `RV32GC_PRIV_S; #1;
        expect_eq1("★ I3 U→S 陷阱：SPP 字段进 clr（替换语义）",
                   p_mstatus_clr[`RV32GC_MSTATUS_SPP_BIT], 1'b1);
        expect_eq1("★ I3 U→S 陷阱：SPP ← y = U(0)（旧实现只置位 ⇒ 残留 1，必 FAIL）",
                   p_mstatus_set[`RV32GC_MSTATUS_SPP_BIT], 1'b0);
        expect_eq1("I3 U→S 陷阱：SPIE ← 旧 SIE(1)",
                   p_mstatus_set[`RV32GC_MSTATUS_SPIE_BIT], 1'b1);
        expect_eq1("I3 U→S 陷阱：SIE ← 0",
                   p_mstatus_clr[`RV32GC_MSTATUS_SIE_BIT], 1'b1);
        @(posedge clk); #1; p_trap_valid = 1'b0; #1;
        expect_eq32("I3 后：特权级 = S（陷阱目标）", {30'b0, p_priv_o}, 32'h1);

        //   ---- I4：MPIE ← MIE 取**陷阱前**值（同拍）----
        //   4a：MIE=1、MPIE=0 ⇒ 陷阱后 MPIE 必须 = 1
        p_mstatus_i = mk_mstatus(1'b1, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, `RV32GC_PRIV_U);
        p_trap_valid = 1'b1; p_trap_target = `RV32GC_PRIV_M; #1;
        expect_eq1("★ I4a M 陷阱：MPIE ← MIE(1)（同拍取陷阱前值）",
                   p_mstatus_set[`RV32GC_MSTATUS_MPIE_BIT], 1'b1);
        expect_eq1("I4a M 陷阱：MIE ← 0",
                   p_mstatus_clr[`RV32GC_MSTATUS_MIE_BIT], 1'b1);
        @(posedge clk); #1; p_trap_valid = 1'b0; #1;
        //   4b：MIE=0、MPIE=1（旧值）⇒ MPIE 必须被**清**回 0（替换，不得残留 1）
        p_mstatus_i = mk_mstatus(1'b0, 1'b0, 1'b1, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, `RV32GC_PRIV_U);
        p_trap_valid = 1'b1; p_trap_target = `RV32GC_PRIV_M; #1;
        expect_eq1("★ I4b M 陷阱：MPIE ← MIE(0) ⇒ set 里无 MPIE",
                   p_mstatus_set[`RV32GC_MSTATUS_MPIE_BIT], 1'b0);
        expect_eq1("★ I4b MPIE 进 clr（替换；旧 MPIE=1 不得残留）",
                   p_mstatus_clr[`RV32GC_MSTATUS_MPIE_BIT], 1'b1);
        @(posedge clk); #1; p_trap_valid = 1'b0; #1;

        //======================================================================
        // J. 【P1-04】未委托的 SSI/STI/SEI 必须成为 **M 目标候选**
        //   规范：先按每 bit 实际委托定目标，再按目标与当前模式决定全局使能。
        //   旧实现：is_s_irq=1 恒要求 mideleg=1 ⇒ mideleg=0 时 1/5/9 永久屏蔽。
        //   ★ 本节的 M 目标非委托断言在旧树必 FAIL；cause 必须保持**原源号**
        //     （1/5/9），不得改写为机器源号 3/7/11。
        //   （trap_ctrl 的 `priv` 输入与 priv_ctrl 的架构级寄存器独立，此处直接驱动。）
        //======================================================================
        p_csr_wen = 1'b0; p_trap_valid = 1'b0;
        commit_valid = 1'b1;
        commit_pc = 32'h8000_3000; commit_pc_next = 32'h8000_3004;
        exc_valid = 1'b0;
        mtvec = 32'h1C00_5001;   // Vectored, BASE=0x1C00_5000
        stvec = 32'h1C00_6001;   // Vectored, BASE=0x1C00_6000

        //   ---- J1：M + mideleg=0 + STIE/STIP + MIE=1 ⇒ M 目标，cause=0x8000_0005 ----
        priv = `RV32GC_PRIV_M;
        mideleg = 32'h0;
        mie = (32'h1 << `RV32GC_MIP_STIP_BIT);
        mip = (32'h1 << `RV32GC_MIP_STIP_BIT);
        mstatus_i = mk_mstatus(1'b1, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, `RV32GC_PRIV_M);
        #1;
        expect_eq1("★ J1 M 模式未委托 STI 被取（旧树被永久屏蔽 ⇒ FAIL）", trap_valid, 1'b1);
        expect_eq1("J1 目标 = M", trap_target == `RV32GC_PRIV_M, 1'b1);
        expect_eq32("★ J1 cause 保持 S 源号 0x8000_0005", trap_cause, 32'h8000_0005);
        expect_eq1("J1 trap_we[0]=1（写 M 侧组）", trap_we[0], 1'b1);
        expect_eq32("J1 M 取向量的 pc = mtvec BASE + 4×5", trap_pc, 32'h1C00_5000 + 32'h14);
        //   ---- J2：M + mideleg=0 + MIE=0 ⇒ M 目标被全局门控（对照）----
        mstatus_i = mk_mstatus(1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, `RV32GC_PRIV_M);
        #1;
        expect_eq1("J2 M 模式 MIE=0 ⇒ M 目标中断不取（对照）", trap_valid, 1'b0);
        //   ---- J3：S + mideleg=0 + SIE=0 + MIE=0 ⇒ 仍进 M（< M 恒开放）----
        priv = `RV32GC_PRIV_S;
        mstatus_i = mk_mstatus(1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, `RV32GC_PRIV_M);
        #1;
        expect_eq1("★ J3 S 模式未委托 STI ⇒ 进 M（SIE/MIE 均不掩蔽）", trap_valid, 1'b1);
        expect_eq1("J3 目标 = M", trap_target == `RV32GC_PRIV_M, 1'b1);
        expect_eq32("J3 cause = 0x8000_0005", trap_cause, 32'h8000_0005);
        //   ---- J4：U + mideleg=0 + SSIE/SSIP ⇒ 进 M，cause=0x8000_0001 ----
        priv = `RV32GC_PRIV_U;
        mie = (32'h1 << `RV32GC_MIP_SSIP_BIT);
        mip = (32'h1 << `RV32GC_MIP_SSIP_BIT);
        #1;
        expect_eq1("★ J4 U 模式未委托 SSI ⇒ 进 M", trap_valid, 1'b1);
        expect_eq1("J4 目标 = M", trap_target == `RV32GC_PRIV_M, 1'b1);
        expect_eq32("★ J4 cause 保持源号 0x8000_0001", trap_cause, 32'h8000_0001);
        //   ---- J5：非委托 SEI ⇒ M 目标，cause=0x8000_0009 ----
        mie = (32'h1 << `RV32GC_MIP_SEIP_BIT);
        mip = (32'h1 << `RV32GC_MIP_SEIP_BIT);
        #1;
        expect_eq1("★ J5 非委托 SEI ⇒ 进 M", trap_valid, 1'b1);
        expect_eq32("★ J5 cause 保持源号 0x8000_0009", trap_cause, 32'h8000_0009);
        //   ---- J6：S + mideleg[5]=1 + SIE=1 ⇒ 目标 S（合法委托路径，两树一致）----
        priv = `RV32GC_PRIV_S;
        mideleg = (32'h1 << `RV32GC_MIP_STIP_BIT);
        mie = (32'h1 << `RV32GC_MIP_STIP_BIT);
        mip = (32'h1 << `RV32GC_MIP_STIP_BIT);
        mstatus_i = mk_mstatus(1'b0, 1'b1, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, `RV32GC_PRIV_S);
        #1;
        expect_eq1("J6 S + 已委托 STI + SIE=1 ⇒ 被取", trap_valid, 1'b1);
        expect_eq1("J6 目标 = S", trap_target == `RV32GC_PRIV_S, 1'b1);
        expect_eq1("J6 trap_we[1]=1（写 S 侧组）", trap_we[1], 1'b1);
        expect_eq32("J6 cause = 0x8000_0005（原源号）", trap_cause, 32'h8000_0005);
        expect_eq32("J6 S 取 stvec BASE + 4×5", trap_pc, 32'h1C00_6000 + 32'h14);
        //   ---- J7：S + 已委托 + SIE=0 ⇒ 不取 ----
        mstatus_i = mk_mstatus(1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, `RV32GC_PRIV_S);
        #1;
        expect_eq1("J7 已委托 S 源 + SIE=0 ⇒ 不取（SIE 门控委托目标）", trap_valid, 1'b0);
        //   ---- J8：M + 已委托 ⇒ 委托位在 M 屏蔽（两树一致）----
        priv = `RV32GC_PRIV_M;
        mstatus_i = mk_mstatus(1'b1, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, `RV32GC_PRIV_M);
        #1;
        expect_eq1("J8 M 模式不取已委托的 S 源中断", trap_valid, 1'b0);
        //   ---- J9：U + 已委托 + SIE=0 ⇒ < S 不受 SIE 掩蔽，目标 S ----
        priv = `RV32GC_PRIV_U;
        #1;
        expect_eq1("J9 U 模式已委托 STI ⇒ 被取（SIE 忽略）", trap_valid, 1'b1);
        expect_eq1("J9 目标 = S", trap_target == `RV32GC_PRIV_S, 1'b1);
        //   ---- J10：优先级未被破坏 —— 六源同挂起且全部未委托 ⇒ MEI(11) ----
        priv = `RV32GC_PRIV_M;
        mideleg = 32'h0;
        mie = 32'h0000_0AAA;
        mstatus_i = mk_mstatus(1'b1, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, `RV32GC_PRIV_M);
        mip = (32'h1<<`RV32GC_MIP_MEIP_BIT)|(32'h1<<`RV32GC_MIP_MTIP_BIT)|
              (32'h1<<`RV32GC_MIP_MSIP_BIT)|(32'h1<<`RV32GC_MIP_SEIP_BIT)|
              (32'h1<<`RV32GC_MIP_STIP_BIT)|(32'h1<<`RV32GC_MIP_SSIP_BIT);
        #1;
        expect_eq32("★ J10 六源同挂起 ⇒ 仍取 M 级最高优先 MEI(11)",
                    trap_cause, 32'h8000_000B);
        //   ---- J11：部分委托（仅 STI）时 MEI/SEI 优先级与目标不变 ----
        mideleg = (32'h1 << `RV32GC_MIP_STIP_BIT);
        mip = (32'h1<<`RV32GC_MIP_MEIP_BIT)|(32'h1<<`RV32GC_MIP_SEIP_BIT)|
              (32'h1<<`RV32GC_MIP_STIP_BIT);
        #1;
        expect_eq32("J11 部分委托下 MEI 仍最高优先", trap_cause, 32'h8000_000B);
        expect_eq1("J11 目标 = M", trap_target == `RV32GC_PRIV_M, 1'b1);
        //   ---- J12：已委托 SEI 在 M 屏蔽，但非委托 SSI 仍进 M（每 bit 独立定目标）----
        mideleg = (32'h1 << `RV32GC_MIP_SEIP_BIT);
        mie = (32'h1 << `RV32GC_MIP_SEIP_BIT) | (32'h1 << `RV32GC_MIP_SSIP_BIT);
        mip = (32'h1 << `RV32GC_MIP_SEIP_BIT) | (32'h1 << `RV32GC_MIP_SSIP_BIT);
        #1;
        expect_eq32("★ J12 已委托 SEI 屏蔽后取非委托 SSI（cause=0x8000_0001）",
                    trap_cause, 32'h8000_0001);
        expect_eq1("J12 目标 = M", trap_target == `RV32GC_PRIV_M, 1'b1);

        //   ---- J13..J18：【首轮独审 P1】选中优先级 = **目标特权级 M 优先，再组内源序** ----
        //     反证：只按固定源序（SEI 在 STI 之前）会把"已委托 SEI→S"压在
        //     "未委托 STI→M"之前；本节 IRQ_MFIRST_* 断言在旧树必 FAIL。
        //     控制项 CTRL_* 在两树都必须通过（组内源序、M 源优先、IE 门控口径不变）。
        //     J13：U + mideleg=0x200 + mie=mip=0x220 ⇒ M 目标 STI(5) 胜 S 目标 SEI(9)
        priv = `RV32GC_PRIV_U;
        mideleg = (32'h1 << `RV32GC_MIP_SEIP_BIT);            // 0x200：SEI 委托
        mie = (32'h1 << `RV32GC_MIP_SEIP_BIT) | (32'h1 << `RV32GC_MIP_STIP_BIT);
        mip = (32'h1 << `RV32GC_MIP_SEIP_BIT) | (32'h1 << `RV32GC_MIP_STIP_BIT);
        mstatus_i = 32'h0; #1;
        expect_eq1("★ J13 U 混合委托竞争：取 M 目标（不被 S 目标抢）", trap_valid, 1'b1);
        expect_eq1("★ J13 目标 = M（未委托 STI）", trap_target == `RV32GC_PRIV_M, 1'b1);
        expect_eq32("★ J13 cause = 0x8000_0005（源号 STI）", trap_cause, 32'h8000_0005);
        //     J14：S + 同配置 + SIE=1 ⇒ 仍 M 目标优先
        priv = `RV32GC_PRIV_S;
        mstatus_i = mk_mstatus(1'b0, 1'b1, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, `RV32GC_PRIV_S);
        #1;
        expect_eq1("★ J14 S 混合委托竞争：取 M 目标", trap_valid, 1'b1);
        expect_eq1("★ J14 目标 = M", trap_target == `RV32GC_PRIV_M, 1'b1);
        expect_eq32("★ J14 cause = 0x8000_0005", trap_cause, 32'h8000_0005);
        //     J15：M + mideleg=0x200 + MIE=1 ⇒ 委托 SEI 在 M 屏蔽，未委托 STI 进 M
        priv = `RV32GC_PRIV_M;
        mstatus_i = mk_mstatus(1'b1, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, `RV32GC_PRIV_M);
        #1;
        expect_eq1("★ J15 M 模式：已委托 SEI 屏蔽、未委托 STI 进 M", trap_valid, 1'b1);
        expect_eq32("★ J15 cause = 0x8000_0005", trap_cause, 32'h8000_0005);
        expect_eq1("J15 目标 = M", trap_target == `RV32GC_PRIV_M, 1'b1);
        //     J16（控制）：S + mideleg=0x202 + mie=mip=0x202 + SIE=1 ⇒ S 组内 SEI(9)>SSI(1)
        priv = `RV32GC_PRIV_S;
        mideleg = (32'h1 << `RV32GC_MIP_SEIP_BIT) | (32'h1 << `RV32GC_MIP_SSIP_BIT);
        mie = mideleg; mip = mideleg;
        mstatus_i = mk_mstatus(1'b0, 1'b1, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, `RV32GC_PRIV_S);
        #1;
        expect_eq1("CTRL J16 S 组内多源 ⇒ 取 SEI", trap_valid, 1'b1);
        expect_eq32("CTRL J16 cause = 0x8000_0009（SEI，组内源序）",
                    trap_cause, 32'h8000_0009);
        expect_eq1("CTRL J16 目标 = S", trap_target == `RV32GC_PRIV_S, 1'b1);
        //     J17（控制）：U + mideleg=0x200 + MEI 同时挂起 ⇒ M 源 MEI(11) 优先
        priv = `RV32GC_PRIV_U;
        mideleg = (32'h1 << `RV32GC_MIP_SEIP_BIT);
        mie = (32'h1 << `RV32GC_MIP_MEIP_BIT) | (32'h1 << `RV32GC_MIP_SEIP_BIT);
        mip = mie;
        mstatus_i = 32'h0; #1;
        expect_eq1("CTRL J17 M 源 MEI 压过 S 目标 SEI", trap_valid, 1'b1);
        expect_eq32("CTRL J17 cause = 0x8000_000B", trap_cause, 32'h8000_000B);
        expect_eq1("CTRL J17 目标 = M", trap_target == `RV32GC_PRIV_M, 1'b1);
        //     J18a（控制）：U + 已委托 SEI + SIE=0 ⇒ 取（< S 不受 SIE 掩蔽）
        mideleg = (32'h1 << `RV32GC_MIP_SEIP_BIT);
        mie = mideleg; mip = mideleg;
        mstatus_i = 32'h0; #1;
        expect_eq1("CTRL J18a U 已委托 SEI 且 SIE=0 ⇒ 取", trap_valid, 1'b1);
        expect_eq32("CTRL J18a cause = 0x8000_0009", trap_cause, 32'h8000_0009);
        expect_eq1("CTRL J18a 目标 = S", trap_target == `RV32GC_PRIV_S, 1'b1);
        //     J18b（控制）：S + 已委托 SEI + SIE=0 ⇒ 不取（IE 门控委托目标）
        priv = `RV32GC_PRIV_S;
        mstatus_i = mk_mstatus(1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, `RV32GC_PRIV_S);
        #1;
        expect_eq1("CTRL J18b S 已委托 + SIE=0 ⇒ 不取", trap_valid, 1'b0);

        //==========================================================================
        // K. 【同拍 xRET + trap】有序落地：先返回（MIE←MPIE/MPIE←1/MPP←U/按需清 MPRV），
        //    合法 trap 再按"返回后的状态/模式"落地。旧实现 OR 向量会让 MPIE=1 的 MRET
        //    把 MIE 重新置 1（入口 MIE=1，handler 再取一次），本段为独立 gold。
        //==========================================================================
        //   ---- K1：M + MIE=1/MPIE=1/MPP=M，MRET + M 目标 IRQ ⇒ 入口 MIE=0 ----
        p_mstatus_i = 32'h0000_1888;
        p_trap_target = `RV32GC_PRIV_M; p_xret_kind = 2'b01;
        @(negedge clk); p_trap_valid = 1'b1; p_xret_valid = 1'b1; #1;
        k_land = land_mstat(p_mstatus_i, p_mstatus_set, p_mstatus_clr);
        expect_eq32("★ K1 xret+trap 落盘 = 0x1880（MIE0/MPIE1/MPPM）", k_land, 32'h0000_1880);
        expect_eq1("★ K1 入口 MIE=0", k_land[`RV32GC_MSTATUS_MIE_BIT], 1'b0);
        expect_eq1("K1 入口 MPIE=1", k_land[`RV32GC_MSTATUS_MPIE_BIT], 1'b1);
        expect_eq32("K1 入口 MPP=M",
                    (k_land >> `RV32GC_MSTATUS_MPP_LSB) & 32'h3, 32'h3);
        expect_eq1("K1 priv_next=M", p_priv_next_o == `RV32GC_PRIV_M, 1'b1);
        expect_eq1("K1 xret_target_priv=M（纯组合，与 trap 无关）",
                   p_xret_target_priv == `RV32GC_PRIV_M, 1'b1);
        @(posedge clk); #1;
        @(negedge clk); p_trap_valid = 1'b0; p_xret_valid = 1'b0; #1;
        //   ---- K2：MPIE=0 的 MRET + IRQ ⇒ MPIE←MIE(after)=0，入口 MIE=0 ----
        p_mstatus_i = 32'h0000_1808;   // MIE=1, MPIE=0, MPP=M
        p_trap_target = `RV32GC_PRIV_M; p_xret_kind = 2'b01;
        @(negedge clk); p_trap_valid = 1'b1; p_xret_valid = 1'b1; #1;
        k_land = land_mstat(p_mstatus_i, p_mstatus_set, p_mstatus_clr);
        expect_eq32("★ K2 MPIE=0 时落盘 = 0x1800（MPIE←0/MPPM/MIE0）", k_land, 32'h0000_1800);
        expect_eq1("K2 入口 MPIE=0", k_land[`RV32GC_MSTATUS_MPIE_BIT], 1'b0);
        @(posedge clk); #1;
        @(negedge clk); p_trap_valid = 1'b0; p_xret_valid = 1'b0; #1;
        //   ---- K3：MRET 返 U（MPP=U）+ M 目标 IRQ ⇒ trap 的 MPP←U（返回后的模式）----
        p_mstatus_i = 32'h0000_0088;   // MIE=1, MPIE=1, MPP=U
        p_trap_target = `RV32GC_PRIV_M; p_xret_kind = 2'b01;
        @(negedge clk); p_trap_valid = 1'b1; p_xret_valid = 1'b1; #1;
        k_land = land_mstat(p_mstatus_i, p_mstatus_set, p_mstatus_clr);
        expect_eq32("★ K3 MRET→U + M trap：落盘 = 0x0080（MPP←U，非旧 M）", k_land, 32'h0000_0080);
        expect_eq32("★ K3 MPP=U（返回后的 y）",
                    (k_land >> `RV32GC_MSTATUS_MPP_LSB) & 32'h3, 32'h0);
        expect_eq1("K3 priv_next=M（trap 目标优先）",
                   p_priv_next_o == `RV32GC_PRIV_M, 1'b1);
        expect_eq1("K3 xret_target_priv=U（返回目标，与 trap 无关）",
                   p_xret_target_priv == `RV32GC_PRIV_U, 1'b1);
        @(posedge clk); #1;
        @(negedge clk); p_trap_valid = 1'b0; p_xret_valid = 1'b0; #1;
        //   ---- K4：SRET（SPP=U）+ S 目标 trap ⇒ SPP←U/SIE0/SPIE1 ----
        p_mstatus_i = 32'h0000_0022;   // SIE=1, SPIE=1, SPP=U
        p_trap_target = `RV32GC_PRIV_S; p_xret_kind = 2'b00;
        @(negedge clk); p_trap_valid = 1'b1; p_xret_valid = 1'b1; #1;
        k_land = land_mstat(p_mstatus_i, p_mstatus_set, p_mstatus_clr);
        expect_eq32("★ K4 SRET+trap 落盘 = 0x0020（SPIE1/SIE0/SPP←U）", k_land, 32'h0000_0020);
        expect_eq1("K4 入口 SIE=0", k_land[`RV32GC_MSTATUS_SIE_BIT], 1'b0);
        expect_eq1("K4 入口 SPIE=1", k_land[`RV32GC_MSTATUS_SPIE_BIT], 1'b1);
        expect_eq1("K4 priv_next=S（trap 目标优先）",
                   p_priv_next_o == `RV32GC_PRIV_S, 1'b1);
        expect_eq1("K4 xret_target_priv=U（SRET 返回目标）",
                   p_xret_target_priv == `RV32GC_PRIV_U, 1'b1);
        @(posedge clk); #1;
        @(negedge clk); p_trap_valid = 1'b0; p_xret_valid = 1'b0; #1;
        p_mstatus_i = 32'h0; #1;

        //   ---- 收尾：清中断请求，避免影响后续/收尾判定 ----
        mip = 32'h0; mideleg = 32'h0; #1;

        //======================================================================
        // 汇总
        //======================================================================
        $display("---- tb_trap_ctrl: pass=%0d fail=%0d ----", n_pass, n_fail);
        if (n_fail != 0) begin
            $display("TB_TRAP FAIL: %0d 项断言失败", n_fail);
            $fatal(1, "TB_TRAP_CTRL_UNIT: FAIL");
        end
        if (n_pass == 0) begin
            $display("TB_TRAP FAIL: 未捕获任何检查（fail-closed）");
            $fatal(1, "TB_TRAP_CTRL_UNIT: FAIL");
        end
        //   ★ PASS 标幅改到 final 块里打印：
        //   iverilog 会在 $finish 后输出 "x.sv:N: $finish called at ..."，
        //   若标幅在 initial 里打就不会是最后一行。
        //   final 块的输出恰好落在该回显之后 ⇒ 满足
        //   "末行 = <TB>_UNIT: PASS"的验收判据（且 PASS 唯一）。
        sim_ok = 1'b1;
        $finish;
    end

    initial begin
        #200000;
        $display("TB_TRAP FAIL: 超时（未走完检查）");
        $fatal(1, "TB_TRAP_CTRL_UNIT: FAIL");
    end


    //--------------------------------------------------------------------------
    // PASS 横幅（唯一 PASS 字样，且保证是输出的**最后一行**）
    //   iverilog 在 $finish 后会回显 "file:line: $finish called at ..."，
    //   故横幅放在 final 块里打印（其输出落于该回显之后）。
    //   ★ fail-closed：sim_ok 只有在走完全部检查且 n_fail==0 时才被置 1，
    //     任何提前 $fatal / 超时路径都不会打印 PASS。
    //--------------------------------------------------------------------------
    final begin
        if (sim_ok && (n_fail == 0) && (n_pass > 0))
            $display("TB_TRAP_CTRL_UNIT: PASS");
    end

endmodule
