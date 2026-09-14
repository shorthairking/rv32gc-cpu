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
        input [8*40-1:0] name; input [31:0] got; input [31:0] exp;
        begin
            if (got !== exp) begin
                $display("TB_TRAP FAIL: %0s got=0x%08x exp=0x%08x", name, got, exp);
                n_fail = n_fail + 1;
            end else n_pass = n_pass + 1;
        end
    endtask

    task expect_eq1;
        input [8*40-1:0] name; input got; input exp;
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
