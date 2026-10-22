//==============================================================================
// tb_csr_file.sv —— csr_file 单元测试（CSR 读写 / 权限 / WARL / PMP / arch-test 硬要求）
//==============================================================================
// 测什么  : ① mstatus/mtvec/mepc/mcause/mtval/medeleg/mideleg/menvcfg/senvcfg/satp/
//             pmpcfg0-3/pmpaddr0-15 的读写（含 WARL 掩码）；
//           ② 写只读 CSR ⇒ illegal（chk_ro_write=1）；未实现地址 ⇒ illegal；
//             特权级不足 ⇒ illegal；
//           ③ **mcountinhibit(0x320) 与 mhpmevent3(0x323) 写不挂**（WARL 吞写、
//             不报非法、读 0）—— arch-test 启动硬要求（08 §8.2.1(b)）；
//           ④ medeleg 高半在 RV32 经 medelegh 别名（写被忽略、读 0）；
//           ⑤ mip 的 SEIP/STIP/SSIP 软件可写、MEIP/MTIP/MSIP 只读（设备驱动）。
//           ⑥ **陷阱/xRET 的 mstatus 语义闭环**（R3 根因修复；§S）：csr_file 与
//             priv_ctrl 接成与 core_top 相同的回路，验证「同拍读视图 = 陷阱前值」
//             （xIE/xPIE/xPP/MIE/SIE 不被同拍 clr/set 污染）、陷阱入口
//             xPP ← y / xPIE ← xIE 的**替换**语义、以及 xRET 后特权级与 MPP 读回。
// 怎么判  : 每条用 expect_eq32()/expect_eq1() 断言具体数值，失败即 $fatal（非零退出）。
//           **兜底分支绝不打印 PASS**；全部检查走完才打印末行 `TB_CSR_FILE_UNIT: PASS`。
// 失败长什么样: 打印 `TB_CSR_FILE FAIL: <项> got=... exp=...` 后 $fatal(1, "TB_CSR_FILE_UNIT: FAIL")，
//           退出码非 0，且输出中**不含** PASS 字样。
// 顶层    : tb_csr_file_top（验收命令用 -s tb_csr_file_top）
//==============================================================================
`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"

module tb_csr_file_top;

    //--------------------------------------------------------------------------
    // DUT 连接
    //--------------------------------------------------------------------------
    reg         clk = 0;
    reg         rst_n = 0;
    reg  [11:0] raddr = 12'h0;
    wire [31:0] rdata;
    reg         wen = 0;
    reg  [11:0] waddr = 12'h0;
    reg  [31:0] wdata = 32'h0;
    reg         w_illegal = 0;
    wire [31:0] rdata_w;
    //   ★ 首轮独审 P1：两路预览端口必须实际接出并对照（旧 TB 未接 byp_wdata/byp_rdata）
    reg  [31:0] byp_wdata = 32'h0;
    wire [31:0] byp_rdata;
    reg  [1:0]  priv = `RV32GC_PRIV_M;
    reg  [11:0] chk_addr = 12'h0;
    wire        chk_illegal, chk_ro_write;
    wire [31:0] mstatus_o;
    reg  [31:0] mstatus_set = 32'h0;
    reg  [31:0] mstatus_clr = 32'h0;
    reg  [3:0]  trap_we = 4'h0;
    reg  [31:0] trap_epc_i = 32'h0, trap_cause_i = 32'h0;
    reg  [31:0] trap_tval_i = 32'h0, trap_data_i = 32'h0;
    reg         irq_msip = 0, irq_mtip = 0, irq_meip = 0, irq_stip = 0, irq_seip = 0;
    reg  [63:0] cycle_i = 64'h0, instret_i = 64'h0;
    reg  [63:0] mtime_i = 64'h0000_00AA_BBCC_DDEE;
    wire        mcycle_we, mcycleh_we, minstret_we, minstreth_we;
    wire [31:0] cnt_wdata;
    wire [127:0] pmp_cfg_o;
    wire [511:0] pmp_addr_o;
    wire [31:0] satp_o, menvcfg_o, senvcfg_o, mcounteren_o, scounteren_o;
    wire [31:0] mtvec_o, stvec_o, medeleg_o, mideleg_o, mie_o, mip_o;

    //--------------------------------------------------------------------------
    // ★ R3 根因修复的闭环验证件（§S）：把 csr_file 的**读视图**与 priv_ctrl 的
    //   判定接成与 core_top §10 相同的回路：
    //       mstatus_o → priv_ctrl.mstatus_i → mstatus_set/clr → csr_file 落地
    //   注入点用 OR 合并：priv_ctrl 在无陷阱/xRET 时输出恒 0 ⇒ 既有用例
    //   （§A–§R）语义逐字不变（本 TB 其余部分仍按原样直接驱动 mstatus_set/clr）。
    //--------------------------------------------------------------------------
    wire [31:0] pc_set, pc_clr;
    reg         pc_trap_valid = 1'b0;
    reg  [1:0]  pc_trap_target = `RV32GC_PRIV_M;
    reg         pc_xret_valid = 1'b0;
    reg  [1:0]  pc_xret_kind = 2'b01;      // 01=mret 00=sret
    wire [1:0]  pc_priv_o, pc_eff_priv_o, pc_priv_next_o, pc_mpp_o;
    wire        pc_mprv_o, pc_sum_o, pc_mxr_o, pc_tvm_o, pc_tw_o, pc_tsr_o;
    wire        pc_fetch_m, pc_flush_req;

    csr_file dut (
        .clk(clk), .rst_n(rst_n),
        .raddr(raddr), .rdata(rdata),
        .wen(wen), .waddr(waddr), .wdata(wdata), .w_illegal(w_illegal),
        .rdata_w(rdata_w),
        .byp_wdata(byp_wdata), .byp_rdata(byp_rdata),
        .priv(priv),
        .chk_addr(chk_addr), .chk_illegal(chk_illegal), .chk_ro_write(chk_ro_write),
        .mstatus_o(mstatus_o),
        .mstatus_set(mstatus_set | pc_set), .mstatus_clr(mstatus_clr | pc_clr),
        .trap_we(trap_we), .trap_epc_i(trap_epc_i), .trap_cause_i(trap_cause_i),
        .trap_tval_i(trap_tval_i), .trap_data_i(trap_data_i),
        .irq_msip(irq_msip), .irq_mtip(irq_mtip), .irq_meip(irq_meip),
        .irq_stip(irq_stip), .irq_seip(irq_seip),
        .cycle_i(cycle_i), .instret_i(instret_i), .mtime_i(mtime_i),
        .mcycle_we_o(mcycle_we), .mcycleh_we_o(mcycleh_we),
        .minstret_we_o(minstret_we), .minstreth_we_o(minstreth_we),
        .cnt_wdata_o(cnt_wdata),
        .pmp_cfg_o(pmp_cfg_o), .pmp_addr_o(pmp_addr_o),
        .satp_o(satp_o), .menvcfg_o(menvcfg_o), .senvcfg_o(senvcfg_o),
        .mcounteren_o(mcounteren_o), .scounteren_o(scounteren_o),
        .mtvec_o(mtvec_o), .stvec_o(stvec_o),
        .medeleg_o(medeleg_o), .mideleg_o(mideleg_o),
        .mie_o(mie_o), .mip_o(mip_o)
    );

    // ---- 特权级/陷阱语义私有控制器（与 core_top 同口径；csr_wen 旁路一并接上）----
    priv_ctrl u_pc (
        .clk(clk), .rst_n(rst_n),
        .trap_valid(pc_trap_valid), .trap_target(pc_trap_target),
        .xret_valid(pc_xret_valid), .xret_kind(pc_xret_kind),
        .mstatus_i(mstatus_o), .csr_wen(wen), .csr_waddr(waddr), .csr_wdata(wdata),
        .mstatus_set(pc_set), .mstatus_clr(pc_clr),
        .priv_o(pc_priv_o), .eff_priv_o(pc_eff_priv_o), .mprv_o(pc_mprv_o),
        .sum_o(pc_sum_o), .mxr_o(pc_mxr_o), .mpp_o(pc_mpp_o),
        .tvm_o(pc_tvm_o), .tw_o(pc_tw_o), .tsr_o(pc_tsr_o),
        .fetch_priv_is_m_o(pc_fetch_m), .flush_req(pc_flush_req),
        .priv_next_o(pc_priv_next_o)
    );

    //--------------------------------------------------------------------------
    // 时钟
    //--------------------------------------------------------------------------
    localparam CLK_HALF = 5;
    always #CLK_HALF clk = ~clk;

    //--------------------------------------------------------------------------
    // 记分板
    //--------------------------------------------------------------------------
    integer n_pass = 0;
    integer n_fail = 0;
    reg     sim_ok = 1'b0;   // 仅在全部检查通过后置 1

    task expect_eq32;
        input [8*256-1:0] name;
        input [31:0]  got;
        input [31:0]  exp;
        begin
            if (got !== exp) begin
                $display("TB_CSR_FILE FAIL: %0s got=0x%08x exp=0x%08x", name, got, exp);
                n_fail = n_fail + 1;
            end else begin
                n_pass = n_pass + 1;
            end
        end
    endtask

    task expect_eq1;
        input [8*256-1:0] name;
        input         got;
        input         exp;
        begin
            if (got !== exp) begin
                $display("TB_CSR_FILE FAIL: %0s got=%0b exp=%0b", name, got, exp);
                n_fail = n_fail + 1;
            end else begin
                n_pass = n_pass + 1;
            end
        end
    endtask

    // ---- CSR 写一拍（含地址权限检查） ----
    task csr_write;
        input [11:0] addr;
        input [31:0] data;
        begin
            @(negedge clk);
            waddr = addr; wdata = data; wen = 1'b1; w_illegal = 1'b0;
            @(posedge clk); #1;
            @(negedge clk);
            wen = 1'b0;
            @(posedge clk); #1;
        end
    endtask

    // ---- 读 CSR（组合） ----
    task csr_read_chk;
        input [8*256-1:0] name;
        input [11:0]  addr;
        input [31:0]  exp;
        begin
            raddr = addr; #1;
            expect_eq32(name, rdata, exp);
        end
    endtask

    //--------------------------------------------------------------------------
    // 主测试
    //--------------------------------------------------------------------------
    initial begin
        $display("---- tb_csr_file: csr_file 单元测试 ----");

        // ---- 复位 ----
        rst_n = 0; repeat(4) @(posedge clk); #1;
        rst_n = 1; repeat(2) @(posedge clk); #1;

        //======================================================================
        // A. 复位值
        //======================================================================
        csr_read_chk("复位 mstatus=0",        `RV32GC_CSR_MSTATUS,  32'h0);
        csr_read_chk("复位 mtvec=0",          `RV32GC_CSR_MTVEC,    32'h0);
        csr_read_chk("复位 mepc=0",           `RV32GC_CSR_MEPC,     32'h0);
        csr_read_chk("复位 mcause=0",         `RV32GC_CSR_MCAUSE,   32'h0);
        csr_read_chk("复位 mtval=0",          `RV32GC_CSR_MTVAL,    32'h0);
        csr_read_chk("复位 medeleg=0",        `RV32GC_CSR_MEDELEG,  32'h0);
        csr_read_chk("复位 mideleg=0",        `RV32GC_CSR_MIDELEG,  32'h0);
        csr_read_chk("复位 menvcfg=0",        `RV32GC_CSR_MENVCFG,  32'h0);
        csr_read_chk("复位 senvcfg=0",        `RV32GC_CSR_SENVCFG,  32'h0);
        csr_read_chk("复位 satp=0(Bare)",     `RV32GC_CSR_SATP,     32'h0);
        csr_read_chk("复位 mstatush=0",       `RV32GC_CSR_MSTATUSH, 32'h0);
        csr_read_chk("复位 mhartid=0",        `RV32GC_CSR_MHARTID,  32'h0);
        csr_read_chk("复位 pmpcfg0=0",        `RV32GC_CSR_PMPCFG0,  32'h0);
        csr_read_chk("复位 pmpaddr0=0",       `RV32GC_CSR_PMPADDR0, 32'h0);

        //======================================================================
        // B. misa：MXL=1 + RV32IMAFDC + S/U
        //======================================================================
        //   MXL 字段 bit[31:30] = 2'b01 ⇒ MXLEN=32
        //   扩展位：A(0) C(2) D(3) F(5) I(8) M(12) S(18) U(20)
        csr_read_chk("misa 值",
                     `RV32GC_CSR_MISA,
                     (32'h1<<30) | (32'h1<<0) | (32'h1<<2) | (32'h1<<3) | (32'h1<<5) |
                     (32'h1<<8) | (32'h1<<12) | (32'h1<<18) | (32'h1<<20));
        //   misa 写无效（只读）—— 值保持不变
        csr_write(`RV32GC_CSR_MISA, 32'hDEAD_BEEF);
        csr_read_chk("misa 写后不变", `RV32GC_CSR_MISA,
                     (32'h1<<30) | (32'h1<<0) | (32'h1<<2) | (32'h1<<3) | (32'h1<<5) |
                     (32'h1<<8) | (32'h1<<12) | (32'h1<<18) | (32'h1<<20));

        //======================================================================
        // C. mstatus 读写（WARL：UIE/UBE/XS 只读 0）
        //======================================================================
        //   MPP=3(M) MIE=1 SIE=1 MPIE=1 SPIE=1 SPP=1 MPRV=1 SUM=1 MXR=1 FS=3(Dirty)
        csr_write(`RV32GC_CSR_MSTATUS,
                  (32'h1<<`RV32GC_MSTATUS_MIE_BIT)  | (32'h1<<`RV32GC_MSTATUS_SIE_BIT)  |
                  (32'h1<<`RV32GC_MSTATUS_MPIE_BIT) | (32'h1<<`RV32GC_MSTATUS_SPIE_BIT) |
                  (32'h1<<`RV32GC_MSTATUS_SPP_BIT)  |
                  (32'h3<<`RV32GC_MSTATUS_MPP_LSB)  |
                  (32'h3<<`RV32GC_MSTATUS_FS_LSB)   |
                  (32'h1<<`RV32GC_MSTATUS_MPRV_BIT) |
                  (32'h1<<`RV32GC_MSTATUS_SUM_BIT)  |
                  (32'h1<<`RV32GC_MSTATUS_MXR_BIT));
        csr_read_chk("mstatus 回读（含 SD=1，FS=Dirty）",
                     `RV32GC_CSR_MSTATUS,
                     (32'h1<<`RV32GC_MSTATUS_MIE_BIT)  | (32'h1<<`RV32GC_MSTATUS_SIE_BIT)  |
                     (32'h1<<`RV32GC_MSTATUS_MPIE_BIT) | (32'h1<<`RV32GC_MSTATUS_SPIE_BIT) |
                     (32'h1<<`RV32GC_MSTATUS_SPP_BIT)  |
                     (32'h3<<`RV32GC_MSTATUS_MPP_LSB)  |
                     (32'h3<<`RV32GC_MSTATUS_FS_LSB)   |
                     (32'h1<<`RV32GC_MSTATUS_MPRV_BIT) |
                     (32'h1<<`RV32GC_MSTATUS_SUM_BIT)  |
                     (32'h1<<`RV32GC_MSTATUS_MXR_BIT)  |
                     (32'h1<<`RV32GC_MSTATUS_SD_BIT));
        expect_eq1("mstatus.SD=1（FS=Dirty）",
                   mstatus_o[`RV32GC_MSTATUS_SD_BIT], 1'b1);

        //   ---- UIE/UBE/XS 只读 0：写 1 后读回 0 ----
        csr_write(`RV32GC_CSR_MSTATUS, (32'h1<<`RV32GC_MSTATUS_UIE_BIT) |
                                       (32'h1<<`RV32GC_MSTATUS_UBE_BIT) |
                                       (32'h3<<`RV32GC_MSTATUS_XS_LSB));
        expect_eq1("mstatus.UIE 只读 0", mstatus_o[`RV32GC_MSTATUS_UIE_BIT], 1'b0);
        expect_eq1("mstatus.UBE 只读 0", mstatus_o[`RV32GC_MSTATUS_UBE_BIT], 1'b0);
        expect_eq32("mstatus.XS 只读 0",
                    (mstatus_o >> `RV32GC_MSTATUS_XS_LSB) & 32'h3, 32'h0);

        //   ---- FS=Off ⇒ SD=0 ----
        csr_write(`RV32GC_CSR_MSTATUS, (32'h0<<`RV32GC_MSTATUS_FS_LSB));
        expect_eq1("FS=Off ⇒ SD=0", mstatus_o[`RV32GC_MSTATUS_SD_BIT], 1'b0);

        //======================================================================
        // D. mtvec / stvec：MODE WARL（0/1 合法，2/3 保留）
        //======================================================================
        csr_write(`RV32GC_CSR_MTVEC, 32'h1C00_0301);   // BASE 低 2 位由掩码清 0
        csr_read_chk("mtvec 回读（BASE|MODE=1 Vectored）",
                     `RV32GC_CSR_MTVEC, 32'h1C00_0301);
        csr_write(`RV32GC_CSR_MTVEC, 32'h1C00_0302);   // MODE=2 保留 ⇒ 保持旧 MODE=1
        csr_read_chk("mtvec MODE=2 保留 ⇒ 旧 MODE 保留",
                     `RV32GC_CSR_MTVEC, 32'h1C00_0301);
        csr_write(`RV32GC_CSR_MTVEC, 32'h1C00_0300);   // MODE=0 Direct
        csr_read_chk("mtvec MODE=0 Direct", `RV32GC_CSR_MTVEC, 32'h1C00_0300);

        csr_write(`RV32GC_CSR_STVEC, 32'h0000_2001);
        csr_read_chk("stvec 回读", `RV32GC_CSR_STVEC, 32'h0000_2001);

        //======================================================================
        // E. mepc：bit0 恒 0（IALIGN=16，EPC_LSB=1）
        //======================================================================
        csr_write(`RV32GC_CSR_MEPC, 32'h1C00_1237);   // 写奇数
        csr_read_chk("mepc bit0 读 0", `RV32GC_CSR_MEPC, 32'h1C00_1236);
        csr_write(`RV32GC_CSR_SEPC, 32'h8000_0003);
        csr_read_chk("sepc bit0 读 0", `RV32GC_CSR_SEPC, 32'h8000_0002);

        //======================================================================
        // F. mcause / mtval：全 32 位可写
        //======================================================================
        csr_write(`RV32GC_CSR_MCAUSE, 32'h8000_0007);   // 中断 7（MTI）
        csr_read_chk("mcause bit31=1 中断", `RV32GC_CSR_MCAUSE, 32'h8000_0007);
        csr_write(`RV32GC_CSR_MCAUSE, 32'h0000_000D);   // 异常 13
        csr_read_chk("mcause 异常 13", `RV32GC_CSR_MCAUSE, 32'h0000_000D);
        csr_write(`RV32GC_CSR_MTVAL, 32'hCAFE_F00D);
        csr_read_chk("mtval 回读", `RV32GC_CSR_MTVAL, 32'hCAFE_F00D);

        //======================================================================
        // G. medeleg / mideleg + **medelegh 别名**（判据③）
        //======================================================================
        //   写全 1 ⇒ 读回只能是实现掩码
        csr_write(`RV32GC_CSR_MEDELEG, 32'hFFFF_FFFF);
        csr_read_chk("medeleg 实现位掩码 0x0000_B3FF",
                     `RV32GC_CSR_MEDELEG, `RV32GC_MEDELEG_IMPL_MSK);
        csr_write(`RV32GC_CSR_MIDELEG, 32'hFFFF_FFFF);
        csr_read_chk("mideleg 实现位掩码 0x0000_0222",
                     `RV32GC_CSR_MIDELEG, `RV32GC_MIDELEG_IMPL_MSK);

        //   ---- medelegh（0x312）是 medeleg 高 32 位别名：RV32 下读 0、写被忽略 ----
        csr_write(`RV32GC_CSR_MEDELEGH, 32'hFFFF_FFFF);
        csr_read_chk("medelegh 读 0（RV32 高半保留）",
                     `RV32GC_CSR_MEDELEGH, 32'h0);
        csr_read_chk("medelegh 写后 medeleg 低半不受影响",
                     `RV32GC_CSR_MEDELEG, `RV32GC_MEDELEG_IMPL_MSK);
        csr_write(`RV32GC_CSR_MIDELEGH, 32'hFFFF_FFFF);
        csr_read_chk("midelegh 读 0",
                     `RV32GC_CSR_MIDELEGH, 32'h0);

        //======================================================================
        // H. menvcfg / senvcfg：FIOM/CBIE/CBCFE/CBZE + CBIE WARL(10 保留)
        //======================================================================
        //   ★ 2026-09-17 期望值修订（T-E 任务，依据 = 规范条文 + 参考模型，**不是**放水）：
        //     menvcfg.CBZE(bit7) / senvcfg.CBZE(bit7) 在本核**只读零** ——
        //     machine.adoc [norm:menvcfgcbzerdonly0]「When the Zicboz extension is
        //     not implemented, CBZE is read-only zero.」；senvcfg 同（supervisor.adoc
        //     senvcfg 段同句）。本核只实现 Zicbom、**不实现 Zicboz**（cbo.zero 无编码、
        //     08 §11 R1；spike_isa 串亦不含 zicboz），故写入的 CBZE=1 必须被丢弃、
        //     读回为 0（Spike：csr_init.cc:242-252/353-359 只在 EXT_ZICBOZ 使能时
        //     才把 CBZE 纳入写掩码；DUT：rtl/csr/csr_file.v 的 menvcfg/senvcfg
        //     wr_mask = 0x71）。
        //     本 TB 只改这两条**被该口径直接改变**的期望值，CBIE WARL(10 保留) 等
        //     其余断言与依据均未动。
        //   ---- CBIE WARL：先写 CBIE=11（执行且做 INVAL），再写保留值 10 ⇒ 保持 11 ----
        csr_write(`RV32GC_CSR_MENVCFG, 32'h0000_00F1);   // FIOM=1 CBIE=11 CBCFE=1（CBZE=1 被丢弃）
        csr_read_chk("menvcfg 全字段写入（CBIE=11，CBZE 只读零）",
                     `RV32GC_CSR_MENVCFG, 32'h0000_0071);
        csr_write(`RV32GC_CSR_MENVCFG, 32'h0000_0031);   // CBIE=2'b10 保留
        csr_read_chk("menvcfg.CBIE=10 保留 ⇒ 保持旧值 11",
                     `RV32GC_CSR_MENVCFG, 32'h0000_0031);
        csr_write(`RV32GC_CSR_MENVCFG, 32'h0000_0001);   // CBIE=00, 只 FIOM
        csr_read_chk("menvcfg.CBIE=00(FIOM=1)", `RV32GC_CSR_MENVCFG, 32'h0000_0001);

        csr_write(`RV32GC_CSR_SENVCFG, 32'h0000_00D1);   // CBIE=01 CBCFE=1 FIOM=1（CBZE=1 被丢弃）
        csr_read_chk("senvcfg 全字段写入（CBIE=01，CBZE 只读零）",
                     `RV32GC_CSR_SENVCFG, 32'h0000_0051);
        csr_write(`RV32GC_CSR_SENVCFG, 32'h0000_0071);   // 先置 CBIE=11
        csr_read_chk("senvcfg CBIE=11", `RV32GC_CSR_SENVCFG, 32'h0000_0071);
        csr_write(`RV32GC_CSR_SENVCFG, 32'h0000_0061);   // CBIE=10 保留 ⇒ 保持 11
        csr_read_chk("senvcfg.CBIE=10 保留 ⇒ 保持旧值 11",
                     `RV32GC_CSR_SENVCFG, 32'h0000_0071);

        //======================================================================
        // I. satp：MODE(31)/ASID(30:22)/PPN(21:0)
        //======================================================================
        csr_write(`RV32GC_CSR_SATP, 32'h8000_0000 | (9'h1AB << 22) | 22'h2BCDE);
        csr_read_chk("satp = Sv32|ASID|PPN",
                     `RV32GC_CSR_SATP, 32'h8000_0000 | (32'h1AB << 22) | 22'h2BCDE);
        expect_eq32("satp_o 端口一致", satp_o,
                    32'h8000_0000 | (32'h1AB << 22) | 22'h2BCDE);

        //======================================================================
        // J. PMP：pmpcfg0-3 与 pmpaddr0-15 读写
        //======================================================================
        csr_write(`RV32GC_CSR_PMPCFG0, 32'h1F0F_0F0F);
        csr_read_chk("pmpcfg0 读写", `RV32GC_CSR_PMPCFG0, 32'h1F0F_0F0F);
        csr_write(`RV32GC_CSR_PMPCFG1, 32'h1F0F_0F0F);
        csr_read_chk("pmpcfg1 读写", `RV32GC_CSR_PMPCFG1, 32'h1F0F_0F0F);
        csr_write(`RV32GC_CSR_PMPCFG2, 32'h1F0F_0F0F);
        csr_read_chk("pmpcfg2 读写", `RV32GC_CSR_PMPCFG2, 32'h1F0F_0F0F);
        csr_write(`RV32GC_CSR_PMPCFG3, 32'h1F0F_0F0F);
        csr_read_chk("pmpcfg3 读写", `RV32GC_CSR_PMPCFG3, 32'h1F0F_0F0F);
        //   pmp_cfg_o 打包核对：cfg0 低 8 位 = 0x0F
        expect_eq32("pmp_cfg_o[7:0]", pmp_cfg_o[7:0], 32'h0F);
        expect_eq32("pmp_cfg_o[127:120]", pmp_cfg_o[127:120], 32'h1F);

        //   ---- pmpaddr0..15 全部读写（重点：**全部** 16 项都可访问） ----
        csr_write(`RV32GC_CSR_PMPADDR0,  32'h0000_0001);
        csr_write(`RV32GC_CSR_PMPADDR1,  32'h0000_0002);
        csr_write(`RV32GC_CSR_PMPADDR3,  32'h0000_0004);
        csr_write(`RV32GC_CSR_PMPADDR7,  32'h0000_0008);
        csr_write(`RV32GC_CSR_PMPADDR15, 32'h0000_8000);
        csr_read_chk("pmpaddr0",  `RV32GC_CSR_PMPADDR0,  32'h0000_0001);
        csr_read_chk("pmpaddr1",  `RV32GC_CSR_PMPADDR1,  32'h0000_0002);
        csr_read_chk("pmpaddr3",  `RV32GC_CSR_PMPADDR3,  32'h0000_0004);
        csr_read_chk("pmpaddr7",  `RV32GC_CSR_PMPADDR7,  32'h0000_0008);
        csr_read_chk("pmpaddr15", `RV32GC_CSR_PMPADDR15, 32'h0000_8000);
        //   ★ G=0 ⇒ pmpaddr 不做低位掩码（写 1 读回 1）
        expect_eq32("pmp_addr_o[31:0]",  pmp_addr_o[31:0],  32'h0000_0001);
        expect_eq32("pmp_addr_o[511:480]", pmp_addr_o[511:480], 32'h0000_8000);

        //======================================================================
        // K. 【判据③核心】★ mcountinhibit / mhpmevent3..31 写不挂（WARL 吞写）
        //    arch-test rvtest_setup.h:1059-1129 无条件写这两组 ⇒ 必须"接受写入
        //    且不抛异常"，落入"未实现"分支会导致启动阶段挂死。
        //======================================================================
        //   ---- 地址权限检查：它们必须是"已实现"⇒ chk_illegal=0 ----
        chk_addr = `RV32GC_CSR_MCOUNTINHIBIT; #1;
        expect_eq1("mcountinhibit 0x320 已实现（chk_illegal=0）", chk_illegal, 1'b0);
        chk_addr = `RV32GC_CSR_MHPMEVENT3; #1;
        expect_eq1("mhpmevent3 0x323 已实现（chk_illegal=0）", chk_illegal, 1'b0);
        chk_addr = `RV32GC_CSR_MHPMEVENT31; #1;
        expect_eq1("mhpmevent31 0x33F 已实现（chk_illegal=0）", chk_illegal, 1'b0);
        chk_addr = 12'h324; #1;
        expect_eq1("mhpmevent4 0x324 已实现", chk_illegal, 1'b0);

        //   ---- 写入不挂：读回 0（WARL 吞写，不保留值，但**不抛异常**） ----
        csr_write(`RV32GC_CSR_MCOUNTINHIBIT, 32'hFFFF_FFFF);
        csr_read_chk("mcountinhibit 吞写读 0", `RV32GC_CSR_MCOUNTINHIBIT, 32'h0);
        csr_write(`RV32GC_CSR_MHPMEVENT3, 32'h0000_0001);
        csr_read_chk("mhpmevent3 吞写读 0", `RV32GC_CSR_MHPMEVENT3, 32'h0);
        csr_write(`RV32GC_CSR_MHPMEVENT31, 32'hDEAD_BEEF);
        csr_read_chk("mhpmevent31 吞写读 0", `RV32GC_CSR_MHPMEVENT31, 32'h0);
        csr_write(12'h324, 32'h1234_5678);
        csr_read_chk("mhpmevent4 吞写读 0", 12'h324, 32'h0);
        csr_write(12'h33E, 32'hFFFF_FFFF);
        csr_read_chk("mhpmevent30 吞写读 0", 12'h33E, 32'h0);
        //   ---- 写 0（arch-test 实际动作）也必须 OK ----
        csr_write(`RV32GC_CSR_MCOUNTINHIBIT, 32'h0);
        csr_write(`RV32GC_CSR_MHPMEVENT3, 32'h0);
        csr_read_chk("写 0 后仍读 0", `RV32GC_CSR_MHPMEVENT3, 32'h0);

        //======================================================================
        // L. 【判据②】写只读 CSR ⇒ 非法指令
        //======================================================================
        //   只读地址：csr[11:10]==2'b11 ⇒ 0xC00-0xC82 / 0xF11-0xF14
        chk_addr = `RV32GC_CSR_MVENDORID; #1;
        expect_eq1("mvendorid 写只读（chk_ro_write=1）", chk_ro_write, 1'b1);
        expect_eq1("mvendorid 已实现（chk_illegal=0）",   chk_illegal,  1'b0);
        chk_addr = `RV32GC_CSR_MHARTID; #1;
        expect_eq1("mhartid 写只读", chk_ro_write, 1'b1);
        chk_addr = `RV32GC_CSR_CYCLE; #1;
        expect_eq1("cycle 写只读", chk_ro_write, 1'b1);
        chk_addr = `RV32GC_CSR_INSTRETH; #1;
        expect_eq1("instreth 写只读", chk_ro_write, 1'b1);
        chk_addr = `RV32GC_CSR_MSTATUS; #1;
        expect_eq1("mstatus 不是只读（chk_ro_write=0）", chk_ro_write, 1'b0);

        //======================================================================
        // M. 【判据②】未实现地址 ⇒ 非法；特权级不足 ⇒ 非法
        //======================================================================
        chk_addr = 12'h5C0; #1;      // 未分配地址
        expect_eq1("未实现地址 0x5C0 ⇒ chk_illegal=1", chk_illegal, 1'b1);
        //   ---- U 模式 CSR 门控 = 0 ⇒ 按未实现处理（08 §6.2 裁决，判据：必非法）----
        chk_addr = `RV32GC_CSR_USTATUS; #1;
        expect_eq1("ustatus 0x000 未落地 ⇒ chk_illegal=1", chk_illegal, 1'b1);
        chk_addr = `RV32GC_CSR_UEPC; #1;
        expect_eq1("uepc 0x041 未落地 ⇒ chk_illegal=1", chk_illegal, 1'b1);
        chk_addr = `RV32GC_CSR_UTVEC; #1;
        expect_eq1("utvec 0x005 未落地 ⇒ chk_illegal=1", chk_illegal, 1'b1);

        //   ---- 特权级门控：M 专属 CSR 在 S/U 下非法 ----
        priv = `RV32GC_PRIV_S;
        chk_addr = `RV32GC_CSR_MSTATUS; #1;
        expect_eq1("S 访问 mstatus ⇒ chk_illegal=1", chk_illegal, 1'b1);
        chk_addr = `RV32GC_CSR_SSTATUS; #1;
        expect_eq1("S 访问 sstatus ⇒ chk_illegal=0", chk_illegal, 1'b0);
        priv = `RV32GC_PRIV_U;
        chk_addr = `RV32GC_CSR_SSTATUS; #1;
        expect_eq1("U 访问 sstatus ⇒ chk_illegal=1", chk_illegal, 1'b1);
        priv = `RV32GC_PRIV_M;
        chk_addr = `RV32GC_CSR_SATP; #1;
        expect_eq1("M 访问 satp ⇒ chk_illegal=0", chk_illegal, 1'b0);

        //======================================================================
        // M2. 【P1-01】counteren 动态门控（cycle/time/instret + 高半影子）
        //   规范：S 需 mcounteren[bit]；U 需 mcounteren[bit] && scounteren[bit]；
        //   M 不受限（machine.adoc/supervisor.adoc counteren 段）。
        //   ★ 旧实现无此门控（01-privilege.md P1-01）；本节的"未使能 ⇒ illegal"
        //     断言在旧树必须 FAIL，使能后的"合法对照"两树都应通过。
        //======================================================================
        priv = `RV32GC_PRIV_M;
        csr_write(`RV32GC_CSR_MCOUNTEREN, 32'h0);
        csr_write(`RV32GC_CSR_SCOUNTEREN, 32'h0);
        //   ---- M 模式不受 counteren 约束（合法对照）----
        chk_addr = `RV32GC_CSR_CYCLE;   #1;
        expect_eq1("M 访问 cycle 不受 counteren 门控 ⇒ chk_illegal=0", chk_illegal, 1'b0);
        chk_addr = `RV32GC_CSR_TIME;    #1;
        expect_eq1("M 访问 time 不受 counteren 门控 ⇒ chk_illegal=0", chk_illegal, 1'b0);
        chk_addr = `RV32GC_CSR_INSTRETH;#1;
        expect_eq1("M 访问 instreth 不受 counteren 门控 ⇒ chk_illegal=0", chk_illegal, 1'b0);
        //   ---- S 模式：mcounteren=0 ⇒ 三个计数器与高半全非法 ----
        priv = `RV32GC_PRIV_S;
        chk_addr = `RV32GC_CSR_CYCLE;   #1;
        expect_eq1("★ S 访问 cycle 且 mcounteren.CY=0 ⇒ chk_illegal=1", chk_illegal, 1'b1);
        chk_addr = `RV32GC_CSR_TIME;    #1;
        expect_eq1("S 访问 time 且 mcounteren.TM=0 ⇒ chk_illegal=1", chk_illegal, 1'b1);
        chk_addr = `RV32GC_CSR_INSTRET; #1;
        expect_eq1("S 访问 instret 且 mcounteren.IR=0 ⇒ chk_illegal=1", chk_illegal, 1'b1);
        chk_addr = `RV32GC_CSR_CYCLEH;  #1;
        expect_eq1("S 访问 cycleh 与 cycle 共用 CY 位 ⇒ chk_illegal=1", chk_illegal, 1'b1);
        //   ---- S 模式：mcounteren=7 ⇒ 六个计数器地址全合法（合法对照）----
        priv = `RV32GC_PRIV_M;
        csr_write(`RV32GC_CSR_MCOUNTEREN, 32'h0000_0007);
        priv = `RV32GC_PRIV_S;
        chk_addr = `RV32GC_CSR_CYCLE;   #1;
        expect_eq1("S 访问 cycle 且 mcounteren.CY=1 ⇒ chk_illegal=0", chk_illegal, 1'b0);
        chk_addr = `RV32GC_CSR_TIME;    #1;
        expect_eq1("S 访问 time 且 mcounteren.TM=1 ⇒ chk_illegal=0", chk_illegal, 1'b0);
        chk_addr = `RV32GC_CSR_INSTRET; #1;
        expect_eq1("S 访问 instret 且 mcounteren.IR=1 ⇒ chk_illegal=0", chk_illegal, 1'b0);
        chk_addr = `RV32GC_CSR_CYCLEH;  #1;
        expect_eq1("S 访问 cycleh 且 mcounteren.CY=1 ⇒ chk_illegal=0", chk_illegal, 1'b0);
        chk_addr = `RV32GC_CSR_TIMEH;   #1;
        expect_eq1("S 访问 timeh 且 mcounteren.TM=1 ⇒ chk_illegal=0", chk_illegal, 1'b0);
        chk_addr = `RV32GC_CSR_INSTRETH;#1;
        expect_eq1("S 访问 instreth 且 mcounteren.IR=1 ⇒ chk_illegal=0", chk_illegal, 1'b0);
        //   ---- U 模式：需两级 AND；scounteren=0 ⇒ 全部非法 ----
        priv = `RV32GC_PRIV_U;
        chk_addr = `RV32GC_CSR_CYCLE;   #1;
        expect_eq1("★ U 访问 cycle 且 scounteren.CY=0 ⇒ chk_illegal=1", chk_illegal, 1'b1);
        chk_addr = `RV32GC_CSR_TIME;    #1;
        expect_eq1("★ U 访问 time 且 scounteren.TM=0 ⇒ chk_illegal=1", chk_illegal, 1'b1);
        //   ---- U 模式：scounteren=1（仅 CY）⇒ cycle 合法、time 仍非法 ----
        priv = `RV32GC_PRIV_M;
        csr_write(`RV32GC_CSR_SCOUNTEREN, 32'h0000_0001);
        priv = `RV32GC_PRIV_U;
        chk_addr = `RV32GC_CSR_CYCLE;   #1;
        expect_eq1("U 访问 cycle 且两级 CY=1 ⇒ chk_illegal=0", chk_illegal, 1'b0);
        chk_addr = `RV32GC_CSR_CYCLEH;  #1;
        expect_eq1("U 访问 cycleh 且两级 CY=1 ⇒ chk_illegal=0", chk_illegal, 1'b0);
        chk_addr = `RV32GC_CSR_TIME;    #1;
        expect_eq1("U 访问 time 且 scounteren.TM=0 ⇒ chk_illegal=1（两级 AND）", chk_illegal, 1'b1);
        //   ---- U 模式：mcounteren 清 0 而 scounteren=7 ⇒ 仍非法（外层门控优先）----
        priv = `RV32GC_PRIV_M;
        csr_write(`RV32GC_CSR_SCOUNTEREN, 32'h0000_0007);
        csr_write(`RV32GC_CSR_MCOUNTEREN, 32'h0);
        priv = `RV32GC_PRIV_U;
        chk_addr = `RV32GC_CSR_CYCLE;   #1;
        expect_eq1("★ U 访问 cycle 且 mcounteren.CY=0（scounteren=1）⇒ chk_illegal=1",
                   chk_illegal, 1'b1);
        //   ---- 非计数器地址不受 counteren 影响（合法对照）----
        chk_addr = `RV32GC_CSR_SSTATUS; #1;
        expect_eq1("U 访问 sstatus 仍因特权级非法（非 counteren 门控）", chk_illegal, 1'b1);
        priv = `RV32GC_PRIV_S;
        chk_addr = `RV32GC_CSR_SSTATUS; #1;
        expect_eq1("counteren=0 不影响 sstatus ⇒ S 合法", chk_illegal, 1'b0);

        //======================================================================
        // M3. 【P1-02】TVM：S 访问 satp（读或写）在 TVM=1 时非法；M 不受限
        //   ★ 旧实现无该判定（01-privilege.md P1-02）；本节的 S+TVM=1 非法断言
        //     在旧树必须 FAIL。"SFENCE.VMA 拦截/整核权限"不在本包（消费者/顶层另包接）。
        //======================================================================
        //   ---- 基线：TVM=0，S 访问 satp 合法（合法对照）----
        priv = `RV32GC_PRIV_M;
        csr_write(`RV32GC_CSR_MSTATUS, 32'h0);      // TVM=0
        priv = `RV32GC_PRIV_S;
        chk_addr = `RV32GC_CSR_SATP; #1;
        expect_eq1("TVM=0 时 S 访问 satp ⇒ chk_illegal=0", chk_illegal, 1'b0);
        //   ---- TVM=1：S 非法，M 合法 ----
        priv = `RV32GC_PRIV_M;
        csr_write(`RV32GC_CSR_MSTATUS, (32'h1 << `RV32GC_MSTATUS_TVM_BIT));
        priv = `RV32GC_PRIV_S;
        chk_addr = `RV32GC_CSR_SATP; #1;
        expect_eq1("★ TVM=1 时 S 访问 satp ⇒ chk_illegal=1", chk_illegal, 1'b1);
        //   ---- TVM 只拦 satp：同拍 S 访问 stvec/sstatus 仍合法 ----
        chk_addr = `RV32GC_CSR_STVEC; #1;
        expect_eq1("TVM=1 不影响 S 访问 stvec ⇒ chk_illegal=0", chk_illegal, 1'b0);
        chk_addr = `RV32GC_CSR_SSTATUS; #1;
        expect_eq1("TVM=1 不影响 S 访问 sstatus ⇒ chk_illegal=0", chk_illegal, 1'b0);
        priv = `RV32GC_PRIV_M;
        chk_addr = `RV32GC_CSR_SATP; #1;
        expect_eq1("TVM=1 时 M 访问 satp ⇒ chk_illegal=0（不拦 M）", chk_illegal, 1'b0);
        //   ---- U 访问 satp 恒非法（特权级门控，与 TVM 无关）----
        priv = `RV32GC_PRIV_U;
        chk_addr = `RV32GC_CSR_SATP; #1;
        expect_eq1("U 访问 satp ⇒ chk_illegal=1", chk_illegal, 1'b1);
        //   ---- 收尾：清 TVM、清 counteren，恢复 priv=M 供后续小节使用 ----
        priv = `RV32GC_PRIV_M;
        csr_write(`RV32GC_CSR_MSTATUS, 32'h0);
        csr_write(`RV32GC_CSR_MCOUNTEREN, 32'h0);
        csr_write(`RV32GC_CSR_SCOUNTEREN, 32'h0);
        chk_addr = `RV32GC_CSR_MSTATUS; #1;
        expect_eq1("M3 收尾：TVM 已清 ⇒ S 访问 satp 恢复合法", chk_illegal, 1'b0);

        //======================================================================
        // M4. 【F1-B】mstatus.MPP 的 WARL 落地：非法编码写后读回必须合法
        //   norm:mstatusxppwarl：MPP 只能持有 M 及以下已实现模式；本核实现 U/S/M
        //   ⇒ 合法 {00,01,11}，保留 2'b10 ⇒ 落地/读回 S。★ 反证：只在 priv_ctrl
        //   使用点合法化（csr_file 原样存 2'b10）时，本节读回/预览断言必 FAIL。
        //======================================================================
        priv = `RV32GC_PRIV_M;
        csr_write(`RV32GC_CSR_MSTATUS, (32'h2 << `RV32GC_MSTATUS_MPP_LSB)); #1;
        csr_read_chk("★ M4 写 MPP=2'b10 ⇒ 读回合法化 S（bits12:11=01）",
                     `RV32GC_CSR_MSTATUS, 32'h0000_0800);
        csr_write(`RV32GC_CSR_MSTATUS, (32'h3 << `RV32GC_MSTATUS_MPP_LSB)); #1;
        csr_read_chk("M4 合法 MPP=M 原样保留", `RV32GC_CSR_MSTATUS, 32'h0000_1800);
        //   ---- 写口预览（RMW 读改写路径）：W 级 rdata_w 与 M 级 byp_rdata 同口径 ----
        @(negedge clk);
        raddr = `RV32GC_CSR_MSTATUS; waddr = `RV32GC_CSR_MSTATUS;
        wdata = (32'h2 << `RV32GC_MSTATUS_MPP_LSB) | 32'h0000_0008;  // MPP=10 + MIE
        wen = 1'b1; byp_wdata = (32'h2 << `RV32GC_MSTATUS_MPP_LSB); #1;
        expect_eq32("★ M4 W 级 rdata_w：MPP=2'b10 预览已合法化且含 MIE",
                    rdata_w, 32'h0000_0808);
        expect_eq32("★ M4 M 级 byp_rdata：MPP=2'b10 预览已合法化",
                    byp_rdata, 32'h0000_0800);
        @(negedge clk); wen = 1'b0; byp_wdata = 32'h0;
        //   ---- 收尾：清 mstatus ----
        csr_write(`RV32GC_CSR_MSTATUS, 32'h0);

        //======================================================================
        // N. mie / mip 与中断请求
        //======================================================================
        csr_write(`RV32GC_CSR_MIE, 32'h0000_0AAA);   // bit1|3|5|7|9|11 = 0xAAA
        csr_read_chk("mie 全部 6 个位可写", `RV32GC_CSR_MIE, 32'h0000_0AAA);
        //   ---- mip：MEIP/MTIP/MSIP 由设备驱动；SEIP/STIP/SSIP 软件可写 ----
        csr_write(`RV32GC_CSR_MIP, 32'h0000_0AAA);
        csr_read_chk("mip 软件位 SSIP/STIP/SEIP 可写（设备位为 0）",
                     `RV32GC_CSR_MIP, 32'h0000_0222);
        //   ---- 设备位拉高 ⇒ 只读，且软件写不影响 ----
        irq_msip = 1; irq_mtip = 1; irq_meip = 1; #1;
        csr_read_chk("mip 设备位 MSIP/MTIP/MEIP 只读可见（+已写软件位）",
                     `RV32GC_CSR_MIP, 32'h0000_0AAA);
        irq_msip = 0; irq_mtip = 0; irq_meip = 0; #1;

        //======================================================================
        // O. sstatus / sie / sip 的 S 视图（与 mstatus/mie/mip 共享存储）
        //======================================================================
        csr_write(`RV32GC_CSR_SSTATUS, (32'h1<<`RV32GC_MSTATUS_SIE_BIT) |
                                       (32'h1<<`RV32GC_MSTATUS_SUM_BIT) |
                                       (32'h1<<`RV32GC_MSTATUS_MXR_BIT));
        csr_read_chk("sstatus 回读 SIE/SUM/MXR",
                     `RV32GC_CSR_SSTATUS,
                     (32'h1<<`RV32GC_MSTATUS_SIE_BIT) |
                     (32'h1<<`RV32GC_MSTATUS_SUM_BIT) |
                     (32'h1<<`RV32GC_MSTATUS_MXR_BIT));
        expect_eq1("sstatus 写同时反映到 mstatus.SIE",
                   mstatus_o[`RV32GC_MSTATUS_SIE_BIT], 1'b1);
        expect_eq1("sstatus 不影响 mstatus.MIE",
                   mstatus_o[`RV32GC_MSTATUS_MIE_BIT], 1'b0);

        //   ★ sie 是 mie 的 S 视图：先给 mie 的 M 专属位置 1，再写 sie，
        //     M 专属位必须**保持不变**（sie 的写掩码只含 SSIE/STIE/SEIE）。
        csr_write(`RV32GC_CSR_MIE, 32'h0000_0888);   // MSIE|MTIE|MEIE
        csr_write(`RV32GC_CSR_SIE, 32'h0000_0222);   // SSIE|STIE|SEIE
        csr_read_chk("sie 回读（S 视图 3 位）", `RV32GC_CSR_SIE, 32'h0000_0222);
        expect_eq32("sie 写不改 mie 的 M 专属位",
                    mie_o & 32'h0000_0888, 32'h0000_0888);
        csr_read_chk("mie 合并视图 = M 位 | S 位",
                     `RV32GC_CSR_MIE, 32'h0000_0AAA);

        //   ★ P1-05：sie/sip 是按 mideleg 受限的别名 —— 未委托位 read-only zero，
        //     写只能触及已委托位，不得清改未委托的底层 mie/mip 位。
        //     ISA machine.adoc（KB chunk 10554）："If an interrupt is delegated to
        //     S-mode by setting a bit in mideleg, it becomes visible in sip and is
        //     maskable using sie. Otherwise, the corresponding bits ... are read-only zero."
        //     ★ 旧树（201acf61）sie/sip 只按固定 1/5/9 掩码，与 mideleg 无关 ⇒ 本段 FAIL。
        priv = `RV32GC_PRIV_M;
        //   ---- A. mideleg=0：sie/sip 读 0；对 sie/sip 的写不得改底层 ----
        csr_write(`RV32GC_CSR_MIE,    32'h0000_0222);
        csr_write(`RV32GC_CSR_MIDELEG,32'h0000_0000);
        csr_read_chk("★ A mideleg=0 ⇒ sie 读 0", `RV32GC_CSR_SIE, 32'h0);
        csr_write(`RV32GC_CSR_MIP,    32'h0000_0222);
        csr_read_chk("★ A mideleg=0 ⇒ sip 读 0", `RV32GC_CSR_SIP, 32'h0);
        csr_write(`RV32GC_CSR_SIE,    32'h0000_0000);   // 清委托位 ⇒ 全忽略
        csr_read_chk("★ A 未委托时写 sie 不得清底层 mie", `RV32GC_CSR_MIE, 32'h0000_0222);
        csr_write(`RV32GC_CSR_SIP,    32'h0000_0000);   // 清 SSIP ⇒ 未委托 ⇒ 忽略
        csr_read_chk("★ A 未委托时写 sip 不得清底层 mip", `RV32GC_CSR_MIP, 32'h0000_0222);
        //   ---- B. 部分委托（仅 STI=mideleg[5]）：只有该位可见/可写 ----
        csr_write(`RV32GC_CSR_MIDELEG, 32'h0000_0020);
        csr_read_chk("★ B 部分委托 ⇒ sie 只显示 STIE", `RV32GC_CSR_SIE, 32'h0000_0020);
        csr_write(`RV32GC_CSR_SIE,    32'h0000_0000);   // 只清已委托的 bit5
        csr_read_chk("★ B sie 写只清已委托位 ⇒ 未委托位保留", `RV32GC_CSR_MIE, 32'h0000_0202);
        csr_read_chk("B sie 读回 = 0（已委托位已清）", `RV32GC_CSR_SIE, 32'h0);
        //   ---- C. 委托 SSIP：sip 显示且可写 SSIP；写 0 只清该位 ----
        csr_write(`RV32GC_CSR_MIDELEG, 32'h0000_0002);
        csr_write(`RV32GC_CSR_MIP,     32'h0000_0222);
        csr_read_chk("★ C 委托 SSIP ⇒ sip 只显示 SSIP", `RV32GC_CSR_SIP, 32'h0000_0002);
        csr_write(`RV32GC_CSR_SIP,     32'h0000_0000);
        csr_read_chk("★ C sip 写 0 只清已委托的 SSIP", `RV32GC_CSR_MIP, 32'h0000_0220);
        //   ---- 收尾：恢复全委托并按 M 写恢复 mie/mip 基线 ----
        csr_write(`RV32GC_CSR_MIDELEG, `RV32GC_MIDELEG_IMPL_MSK);
        csr_write(`RV32GC_CSR_MIE,     32'h0000_0222);
        csr_write(`RV32GC_CSR_MIP,     32'h0000_0222);
        csr_read_chk("O 收尾 mie 恢复 0x222", `RV32GC_CSR_MIE, 32'h0000_0222);
        csr_read_chk("O 收尾 mip 恢复 0x222", `RV32GC_CSR_MIP, 32'h0000_0222);

        //======================================================================
        // O2. 【首轮独审 P1】SIE/SIP 两路预览（rdata_w / byp_rdata）与落盘一致
        //   根因：csr_landing 的 SIE/SIP 分支原先只按固定 wr_mask，落了 W 级
        //   预览 0x222，但实际写通道按 mideleg 过滤后读回 0 ⇒ 预览 ≠ 实际读取。
        //   ★ 反证：把 csr_landing 的 SIE/SIP 分支改回固定掩码，本节断言必 FAIL。
        //   覆盖：未委托(0) / 部分(0x020) / 全(0x222) 三档；含"写 mideleg 同拍
        //   改变委托"时 SIE 读视图与 M 级预览的合同；底层未委托位不得被误清。
        //======================================================================
        //   ---- 预置：mie 全 S 位 + M 位；mip 软件 S 位 ----
        csr_write(`RV32GC_CSR_MIE, 32'h0000_0AAA);
        csr_write(`RV32GC_CSR_MIP, 32'h0000_0222);
        //   ---- A. 未委托（mideleg=0）：SIE 写 0x222 预览=0，落盘读=0 ----
        csr_write(`RV32GC_CSR_MIDELEG, 32'h0000_0000);
        @(negedge clk);
        raddr = `RV32GC_CSR_SIE; waddr = `RV32GC_CSR_SIE; wdata = 32'h0000_0222;
        wen = 1'b1; w_illegal = 1'b0; byp_wdata = 32'h0000_0222; #1;
        expect_eq32("★ O2-A SIE 写 0x222 且 mideleg=0：rdata_w 预览 = 0",
                    rdata_w, 32'h0);
        expect_eq32("★ O2-A M 级 byp_rdata 预览 = 0", byp_rdata, 32'h0);
        @(posedge clk); #1;
        @(negedge clk); wen = 1'b0; byp_wdata = 32'h0;
        @(posedge clk); #1;
        csr_read_chk("★ O2-A 落盘实际读 SIE = 0（与预览一致）", `RV32GC_CSR_SIE, 32'h0);
        expect_eq32("O2-A 未委托写不清底层 mie（S 位仍在）", mie_o & 32'h0000_0222, 32'h0000_0222);
        //   ---- B. 部分委托（仅 STI=0x020）：写 0x222 预览/落盘 = 0x020；
        //        再写 0 只清已委托位，未委托底层位保留 ----
        csr_write(`RV32GC_CSR_MIDELEG, 32'h0000_0020);
        @(negedge clk);
        raddr = `RV32GC_CSR_SIE; waddr = `RV32GC_CSR_SIE; wdata = 32'h0000_0222;
        wen = 1'b1; byp_wdata = 32'h0000_0000; #1;
        expect_eq32("★ O2-B 部分委托：SIE 写 0x222 的 rdata_w 预览 = 0x020",
                    rdata_w, 32'h0000_0020);
        expect_eq32("★ O2-B M 级预览（清 0x222）= 0", byp_rdata, 32'h0);
        @(posedge clk); #1;
        @(negedge clk); wen = 1'b0; byp_wdata = 32'h0;
        @(posedge clk); #1;
        csr_read_chk("★ O2-B 落盘实际读 SIE = 0x020", `RV32GC_CSR_SIE, 32'h0000_0020);
        expect_eq32("O2-B 未委托底层 S 位未被误清（SIE 显示层只看委托位）",
                    mie_o & 32'h0000_0222, 32'h0000_0222);
        @(negedge clk);
        raddr = `RV32GC_CSR_SIE; waddr = `RV32GC_CSR_SIE; wdata = 32'h0000_0000;
        wen = 1'b1; byp_wdata = 32'h0000_0222; #1;
        expect_eq32("O2-B2 写 0：rdata_w 预览 = 0（只清委托位后读回）", rdata_w, 32'h0);
        expect_eq32("O2-B2 M 级预览（置 0x222）= 0x020", byp_rdata, 32'h0000_0020);
        @(posedge clk); #1;
        @(negedge clk); wen = 1'b0; byp_wdata = 32'h0;
        @(posedge clk); #1;
        csr_read_chk("O2-B2 落盘 SIE = 0", `RV32GC_CSR_SIE, 32'h0);
        expect_eq32("★ O2-B2 未委托底层位保留（仅 bit5 被清）",
                    mie_o & 32'h0000_0222, 32'h0000_0202);
        //   ---- C. 全委托（0x222）：写 0x202 ⇒ 预览/落盘 = 0x202 ----
        csr_write(`RV32GC_CSR_MIDELEG, 32'h0000_0222);
        @(negedge clk);
        raddr = `RV32GC_CSR_SIE; waddr = `RV32GC_CSR_SIE; wdata = 32'h0000_0202;
        wen = 1'b1; byp_wdata = 32'h0000_0002; #1;
        expect_eq32("O2-C 全委托：rdata_w 预览 = 0x202", rdata_w, 32'h0000_0202);
        expect_eq32("O2-C M 级预览（写 0x002）= 0x002", byp_rdata, 32'h0000_0002);
        @(posedge clk); #1;
        @(negedge clk); wen = 1'b0; byp_wdata = 32'h0;
        @(posedge clk); #1;
        csr_read_chk("O2-C 落盘实际读 SIE = 0x202", `RV32GC_CSR_SIE, 32'h0000_0202);
        //   ---- D. 委托同拍变化：W 写 mideleg=0（撤委托），读 SIE 的预览必须按新值 ----
        csr_write(`RV32GC_CSR_MIDELEG, 32'h0000_0222);   // 先全委托
        @(negedge clk);
        raddr = `RV32GC_CSR_SIE; waddr = `RV32GC_CSR_MIDELEG; wdata = 32'h0000_0000;
        wen = 1'b1; byp_wdata = 32'h0000_0222; #1;
        expect_eq32("★ O2-D 同拍撤委托：SIE 读视图 rdata_w = mie & 新 mideleg = 0",
                    rdata_w, 32'h0);
        expect_eq32("★ O2-D 同拍撤委托：M 级 SIE 预览 = 写数据 & 新 mideleg = 0",
                    byp_rdata, 32'h0);
        @(posedge clk); #1;
        @(negedge clk); wen = 1'b0; byp_wdata = 32'h0;
        @(posedge clk); #1;
        csr_read_chk("O2-D 落盘：mideleg=0 ⇒ SIE 读 0", `RV32GC_CSR_SIE, 32'h0);
        expect_eq32("O2-D 撤委托不清底层 mie", mie_o & 32'h0000_0222, 32'h0000_0202);
        //   ---- E. SIP 未委托：写 0 被忽略；预览/落盘 = 0，不清底层 mip ----
        csr_write(`RV32GC_CSR_MIP, 32'h0000_0222);
        @(negedge clk);
        raddr = `RV32GC_CSR_SIP; waddr = `RV32GC_CSR_SIP; wdata = 32'h0000_0000;
        wen = 1'b1; byp_wdata = 32'h0000_0000; #1;
        expect_eq32("★ O2-E SIP 未委托：rdata_w 预览 = 0", rdata_w, 32'h0);
        expect_eq32("★ O2-E SIP 未委托：M 级预览 = 0", byp_rdata, 32'h0);
        @(posedge clk); #1;
        @(negedge clk); wen = 1'b0;
        @(posedge clk); #1;
        csr_read_chk("★ O2-E 落盘实际读 SIP = 0", `RV32GC_CSR_SIP, 32'h0);
        expect_eq32("★ O2-E 未委托写不清底层 mip（SSIP/STIP/SEIP 仍在）",
                    mip_o & 32'h0000_0222, 32'h0000_0222);
        //   ---- F. SIP 部分委托（仅 SSIP）：写 0 清 SSIP；STIP/SEIP 底层位保留 ----
        csr_write(`RV32GC_CSR_MIDELEG, 32'h0000_0002);
        @(negedge clk);
        raddr = `RV32GC_CSR_SIP; waddr = `RV32GC_CSR_SIP; wdata = 32'h0000_0000;
        wen = 1'b1; byp_wdata = 32'h0000_0002; #1;
        expect_eq32("O2-F SIP 部分委托：rdata_w 预览 = 0", rdata_w, 32'h0);
        expect_eq32("O2-F SIP 部分委托：M 级预览（置 SSIP）= 0x002", byp_rdata, 32'h0000_0002);
        @(posedge clk); #1;
        @(negedge clk); wen = 1'b0;
        @(posedge clk); #1;
        csr_read_chk("O2-F 落盘实际读 SIP = 0", `RV32GC_CSR_SIP, 32'h0);
        expect_eq32("O2-F 只清已委托 SSIP，STIP/SEIP 保留",
                    mip_o & 32'h0000_0222, 32'h0000_0220);
        //   ---- 收尾：恢复 mideleg=0x222、mie/mip 基线 ----
        csr_write(`RV32GC_CSR_MIDELEG, 32'h0000_0222);
        csr_write(`RV32GC_CSR_MIP, 32'h0000_0222);

        //======================================================================
        // P. 计数器（★ F1-B 新语义）：单一 64 位本体在顶层，本模块只做视图/写请求
        //   · mcycle/cycle 读同一 cycle_i；minstret/instret 读同一 instret_i；
        //   · time/timeh 读 mtime_i（不再等于 cycle）；
        //   · 写地址产生对应半字 we + cnt_wdata；写后同拍预览（rdata_w/byp_rdata）
        //     对"同计数器同半"的别名（mcycle↔cycle 等）给出写后值。
        //======================================================================
        cycle_i  = 64'h0000_0001_CAFE_0000;
        instret_i= 64'h0000_0002_1234_0000;
        mtime_i  = 64'h0000_00AA_BBCC_DDEE; #1;
        csr_read_chk("P cycle 低半 = 本体",    `RV32GC_CSR_CYCLE,    32'hCAFE_0000);
        csr_read_chk("P cycleh 高半 = 本体",   `RV32GC_CSR_CYCLEH,   32'h0000_0001);
        csr_read_chk("P mcycle 低半 = 同一本体", `RV32GC_CSR_MCYCLE, 32'hCAFE_0000);
        csr_read_chk("P mcycleh 高半 = 同一本体",`RV32GC_CSR_MCYCLEH,32'h0000_0001);
        csr_read_chk("P instret 低半 = 本体",  `RV32GC_CSR_INSTRET,  32'h1234_0000);
        csr_read_chk("P instreth 高半 = 本体", `RV32GC_CSR_INSTRETH, 32'h0000_0002);
        csr_read_chk("P minstret 低半 = 同一本体", `RV32GC_CSR_MINSTRET, 32'h1234_0000);
        csr_read_chk("★ P time 低半 = mtime 低 32", `RV32GC_CSR_TIME,  32'hBBCC_DDEE);
        csr_read_chk("★ P timeh 高半 = mtime 高 32",`RV32GC_CSR_TIMEH, 32'h0000_00AA);
        //   ---- 写请求：we/cnt_wdata 只在对应地址断言，同拍至多一个 ----
        @(negedge clk);
        waddr = `RV32GC_CSR_MCYCLE; wdata = 32'h1111_2222; wen = 1'b1;
        raddr = `RV32GC_CSR_MCYCLE; #1;
        expect_eq1("★ P 写 mcycle ⇒ mcycle_we=1", mcycle_we, 1'b1);
        expect_eq1("P 写 mcycle 不影响其它 we",
                   mcycleh_we | minstret_we | minstreth_we, 1'b0);
        expect_eq32("P cnt_wdata = 写数据", cnt_wdata, 32'h1111_2222);
        expect_eq32("★ P 写后 rdata_w（raddr=mcycle）= 写值", rdata_w, 32'h1111_2222);
        raddr = `RV32GC_CSR_CYCLE; byp_wdata = 32'h3333_4444; #1;
        expect_eq32("★ P 别名预览：读 cycle 同拍写 mcycle ⇒ rdata_w = 写值",
                    rdata_w, 32'h1111_2222);
        expect_eq32("★★ P 别名 M 级预览：读 cycle + byp(mcycle 写) = byp_wdata",
                    byp_rdata, 32'h3333_4444);
        @(negedge clk); wen = 1'b0; byp_wdata = 32'h0;
        //   ---- 高半写：只产生 mcycleh we ----
        @(negedge clk);
        waddr = `RV32GC_CSR_MCYCLEH; wdata = 32'h5555_6666; wen = 1'b1;
        raddr = `RV32GC_CSR_MCYCLEH; #1;
        expect_eq1("P 写 mcycleh ⇒ mcycleh_we=1", mcycleh_we, 1'b1);
        expect_eq1("P 写 mcycleh 不动低半 we", mcycle_we, 1'b0);
        expect_eq32("P 写后 rdata_w（mcycleh）= 写值", rdata_w, 32'h5555_6666);
        @(negedge clk); wen = 1'b0;
        //   ---- minstret 半写：对应 we ----
        @(negedge clk);
        waddr = `RV32GC_CSR_MINSTRET; wdata = 32'h7777_8888; wen = 1'b1; #1;
        expect_eq1("P 写 minstret ⇒ minstret_we=1", minstret_we, 1'b1);
        expect_eq1("P 写 minstret 不动高半 we", minstreth_we, 1'b0);
        @(negedge clk); wen = 1'b0;
        @(negedge clk);
        waddr = `RV32GC_CSR_MINSTRETH; wdata = 32'h9999_AAAA; wen = 1'b1; #1;
        expect_eq1("P 写 minstreth ⇒ minstreth_we=1", minstreth_we, 1'b1);
        @(negedge clk); wen = 1'b0;
        //   ---- 只读影子（cycle/time/instret）不得产生写请求 ----
        @(negedge clk);
        waddr = `RV32GC_CSR_CYCLE; wdata = 32'hFFFF_FFFF; wen = 1'b1; #1;
        expect_eq1("★ P 写 cycle（只读影子）不得产生任何计数器 we",
                   mcycle_we | mcycleh_we | minstret_we | minstreth_we, 1'b0);
        @(negedge clk); wen = 1'b0;
        //   ---- 本体更新后视图随之变化（本体由顶层维护，TB 直接改输入模拟）----
        cycle_i  = 64'hFFFF_FFFF_FFFF_FFFF;
        instret_i= 64'h0000_0000_FFFF_FFFF; #1;
        csr_read_chk("P 本体更新后 cycle 低",  `RV32GC_CSR_CYCLE,   32'hFFFF_FFFF);
        csr_read_chk("P 本体更新后 cycleh 高", `RV32GC_CSR_CYCLEH,  32'hFFFF_FFFF);

        //======================================================================
        // Q. trap 端口写（trap_ctrl 的入口：**一次原子写 epc/cause/tval 三个**）
        //    ★ 分组语义：trap_we[0]=M 组、[1]=S 组（见 csr_file 端口注释）
        //======================================================================
        //   ---- M 组：mepc + mcause + mtval 同拍写 ----
        @(negedge clk);
        trap_we = 4'h1; trap_epc_i = 32'h1C00_2000;
        trap_cause_i = 32'h8000_0007; trap_tval_i = 32'hDEAD_0000;
        @(posedge clk); #1;
        @(negedge clk); trap_we = 4'h0;
        @(posedge clk); #1;
        csr_read_chk("trap_we[0] 原子写 mepc",   `RV32GC_CSR_MEPC,   32'h1C00_2000);
        csr_read_chk("trap_we[0] 原子写 mcause", `RV32GC_CSR_MCAUSE, 32'h8000_0007);
        csr_read_chk("trap_we[0] 原子写 mtval",  `RV32GC_CSR_MTVAL,  32'hDEAD_0000);

        //   ---- S 组：sepc + scause + stval 同拍写 ----
        @(negedge clk);
        trap_we = 4'h2; trap_epc_i = 32'h1C00_4000;
        trap_cause_i = 32'h0000_000D; trap_tval_i = 32'hBEEF_0000;
        @(posedge clk); #1;
        @(negedge clk); trap_we = 4'h0;
        @(posedge clk); #1;
        csr_read_chk("trap_we[1] 原子写 sepc",   `RV32GC_CSR_SEPC,   32'h1C00_4000);
        csr_read_chk("trap_we[1] 原子写 scause", `RV32GC_CSR_SCAUSE, 32'h0000_000D);
        csr_read_chk("trap_we[1] 原子写 stval",  `RV32GC_CSR_STVAL,  32'hBEEF_0000);
        //   ---- 委托到 S 时**不得**写 M 侧（E6；norm:trapdelSmodenoMmode）----
        csr_read_chk("S 组写不影响 mcause", `RV32GC_CSR_MCAUSE, 32'h8000_0007);
        csr_read_chk("S 组写不影响 mepc",   `RV32GC_CSR_MEPC,   32'h1C00_2000);

        //   ---- mstatus_set/mstatus_clr 端口（trap_ctrl/priv_ctrl 用）----
        mstatus_set = (32'h1 << `RV32GC_MSTATUS_MPIE_BIT) |
                      (32'h3   << `RV32GC_MSTATUS_MPP_LSB);
        mstatus_clr = (32'h1 << `RV32GC_MSTATUS_MIE_BIT);
        @(posedge clk); #1; mstatus_set = 32'h0; mstatus_clr = 32'h0; @(posedge clk); #1;
        expect_eq1("mstatus_set 置 MPIE", mstatus_o[`RV32GC_MSTATUS_MPIE_BIT], 1'b1);
        expect_eq32("mstatus_set 置 MPP=M", (mstatus_o >> `RV32GC_MSTATUS_MPP_LSB) & 32'h3, 32'h3);

        //======================================================================
        // R. PMP L 位写锁（P0-02 修复）：本项 L **或** 后项 (L && A=TOR)
        //   ISA norm:pmplbitwriteprotection：
        //     「若项 i 被锁，写 pmpcfg[i]/pmpaddr[i] 被忽略；若项 i 被锁且 A=TOR，
        //       写 pmpaddr[i-1] 也被忽略」；NOTE：A=OFF 时 L 仍锁本项。
        //   ★ 旧树（201acf61）只看后项 L&&TOR 且 i=15 恒不锁 ⇒ R1/R4 必 FAIL。
        //   ★ 锁定写是**静默忽略**（不抛异常）：同时断言 chk_illegal/chk_ro_write=0。
        //   ★ 本 TB 原先把"L 项自身 pmpaddr 仍可写"当正确口径（错误 oracle）；
        //     现按规范修正，并保留未锁项的合法读写对照（R2a/R3/R4 的前驱项）。
        //======================================================================
        //   ---- R1：item0 本项 L（A=TOR）⇒ pmpcfg0/pmpaddr0 写均被忽略 ----
        csr_write(`RV32GC_CSR_PMPCFG0, 32'h0000_008F);   // 项0: L=1 A=TOR RWX=7
        csr_read_chk("R1 pmpcfg0 项0 L=1", `RV32GC_CSR_PMPCFG0, 32'h0000_008F);
        csr_write(`RV32GC_CSR_PMPCFG0, 32'h0000_000F);   // 撤 L ⇒ 写被忽略
        csr_read_chk("R1 L=1 时 pmpcfg0 写入被忽略", `RV32GC_CSR_PMPCFG0, 32'h0000_008F);
        csr_write(`RV32GC_CSR_PMPADDR0, 32'h0000_1234);  // 本项 L ⇒ 写被忽略
        csr_read_chk("★ R1 本项 L 锁定 pmpaddr0（旧树可写，必 FAIL）",
                     `RV32GC_CSR_PMPADDR0, 32'h0000_0001);
        expect_eq32("R1 pmp_addr_o[31:0] 未被改动", pmp_addr_o[31:0], 32'h0000_0001);
        chk_addr = `RV32GC_CSR_PMPADDR0; priv = `RV32GC_PRIV_M; #1;
        expect_eq1("R1 锁定写不抛非法（chk_illegal=0）", chk_illegal, 1'b0);
        expect_eq1("R1 锁定写不判只读写（chk_ro_write=0）", chk_ro_write, 1'b0);

        //   ---- R2a：未锁项合法写（合法覆盖保留）----
        csr_write(`RV32GC_CSR_PMPADDR2, 32'h0000_00A5);
        csr_read_chk("R2a 未锁项 pmpaddr2 合法可写", `RV32GC_CSR_PMPADDR2, 32'h0000_00A5);

        //   ---- R2b：item1 本项 L、item3 本项 L（均 A=TOR）----
        csr_write(`RV32GC_CSR_PMPCFG0, 32'h8800_888F);
        csr_read_chk("R2b pmpcfg0 = item0(L,TOR)+item1(L,TOR)+item3(L,TOR)",
                     `RV32GC_CSR_PMPCFG0, 32'h8800_888F);
        //   ---- R2c：pmpaddr2 本项 L=0，但**后项 item3 L&&TOR** ⇒ 写被忽略 ----
        csr_write(`RV32GC_CSR_PMPADDR2, 32'h0000_00FF);
        csr_read_chk("★ R2c 后项 (L&&TOR) 锁定前驱 pmpaddr2（合法覆盖保留）",
                     `RV32GC_CSR_PMPADDR2, 32'h0000_00A5);
        //   ---- R2d：pmpaddr1 本项 L=1 ⇒ 写被忽略 ----
        csr_write(`RV32GC_CSR_PMPADDR1, 32'h0000_00FF);
        csr_read_chk("R2d 中间项本项 L 锁定 pmpaddr1", `RV32GC_CSR_PMPADDR1, 32'h0000_0002);
        //   ---- R2e：pmpaddr0 同时被本项 L 与后项 TOR 锁 ⇒ 仍不可写 ----
        csr_write(`RV32GC_CSR_PMPADDR0, 32'h0000_00FF);
        csr_read_chk("R2e pmpaddr0 仍被锁（本项+后项双重）", `RV32GC_CSR_PMPADDR0, 32'h0000_0001);

        //   ---- R3：后项 L 但 A≠TOR ⇒ **不**锁前驱（合法覆盖保留）----
        csr_write(`RV32GC_CSR_PMPCFG1, 32'h1F0F_9F0F);   // item5: L=1 A=NAPOT
        csr_read_chk("R3 pmpcfg1 item5 L=1 A=NAPOT", `RV32GC_CSR_PMPCFG1, 32'h1F0F_9F0F);
        csr_write(`RV32GC_CSR_PMPADDR4, 32'h0000_0BAD);
        csr_read_chk("★ R3 后项 L 但 A=NAPOT ⇒ 前驱 pmpaddr4 仍可写",
                     `RV32GC_CSR_PMPADDR4, 32'h0000_0BAD);
        csr_write(`RV32GC_CSR_PMPADDR5, 32'h0000_DEAD);  // 本项 L=1 ⇒ 忽略
        csr_read_chk("R3 本项 L 锁定 pmpaddr5", `RV32GC_CSR_PMPADDR5, 32'h0000_0000);

        //   ---- R4：i=15 边界 —— 本项 L（A=OFF）仍锁 pmpaddr15；前驱不受影响 ----
        csr_write(`RV32GC_CSR_PMPCFG3, 32'h8000_0000);   // item15: L=1 A=OFF
        csr_read_chk("R4 pmpcfg3 item15 L=1 A=OFF", `RV32GC_CSR_PMPCFG3, 32'h8000_0000);
        csr_write(`RV32GC_CSR_PMPADDR15, 32'h0000_DEAD);
        csr_read_chk("★ R4 i=15 本项 L（A=OFF）锁定 pmpaddr15（旧树 i=15 恒不锁，必 FAIL）",
                     `RV32GC_CSR_PMPADDR15, 32'h0000_8000);
        csr_write(`RV32GC_CSR_PMPADDR14, 32'h0000_0BAD);
        csr_read_chk("R4 i=15 的 A=OFF ⇒ 前驱 pmpaddr14 仍可写",
                     `RV32GC_CSR_PMPADDR14, 32'h0000_0BAD);

        //======================================================================
        // S. 【R3 根因修复】陷阱/xRET 的 mstatus 语义 —— csr_file×priv_ctrl 闭环
        //    ISA norm:mstatusxpiexiexpptrap_op：
        //      「When a trap is taken from privilege mode y into privilege mode x,
        //        xPIE is set to the value of xIE; xIE is set to 0; xPP is set to y」
        //    ISA norm:mstatusxretop：
        //      「xIE ← xPIE; privilege ← xPP; xPIE ← 1; xPP ← U」
        //    ★ 本节的"同拍读视图"用例是**反证实验**：若 csr_file 的 `mstatus_o` 含
        //      同拍的 clr/set，则本拍读到的 MIE/MPP/SIE/SPP 已是"更新后"的值，
        //      本节断言必须 FAIL（且 §S3 的 mret 目标会错成 U）。
        //======================================================================
        priv = `RV32GC_PRIV_M;
        //   ---- S0：csr_file + priv_ctrl 同步复位 ----
        rst_n = 0; repeat(4) @(posedge clk); #1;
        rst_n = 1; repeat(2) @(posedge clk); #1;
        csr_read_chk("S0 复位 mstatus=0", `RV32GC_CSR_MSTATUS, 32'h0);
        expect_eq32("S0 priv_ctrl 复位后特权级 = M", {30'b0, pc_priv_o}, 32'h3);

        //   ---- S1：mstatus 基线：MIE=1、SIE=1（MPIE/MPP/SPP 复位为 0）----
        csr_write(`RV32GC_CSR_MSTATUS,
                  (32'h1 << `RV32GC_MSTATUS_MIE_BIT) | (32'h1 << `RV32GC_MSTATUS_SIE_BIT));
        csr_read_chk("S1 mstatus 基线 MIE=1/SIE=1",
                     `RV32GC_CSR_MSTATUS,
                     (32'h1 << `RV32GC_MSTATUS_MIE_BIT) | (32'h1 << `RV32GC_MSTATUS_SIE_BIT));

        //   ---- S2：陷阱进入 M（读视图必须是**陷阱前**值；落地是替换语义）----
        @(negedge clk); pc_trap_valid = 1'b1; pc_trap_target = `RV32GC_PRIV_M; #1;
        expect_eq1("★ S2 同拍读视图：MIE 仍为陷阱前值 1（未被同拍 clr 污染）",
                   mstatus_o[`RV32GC_MSTATUS_MIE_BIT], 1'b1);
        expect_eq32("★ S2 同拍读视图：MPP 仍为陷阱前值 U(0)（未被同拍 set 污染）",
                    (mstatus_o >> `RV32GC_MSTATUS_MPP_LSB) & 32'h3, 32'h0);
        expect_eq1("★ S2 同拍读视图：MPIE 仍为陷阱前值 0（未被同拍 set 污染）",
                   mstatus_o[`RV32GC_MSTATUS_MPIE_BIT], 1'b0);
        @(posedge clk); #1;
        @(negedge clk); pc_trap_valid = 1'b0; @(posedge clk); #1;
        expect_eq32("★ S2 陷阱后 MPP ← y = M(3)（陷阱前 MPP=0 不得残留）",
                    (mstatus_o >> `RV32GC_MSTATUS_MPP_LSB) & 32'h3, 32'h3);
        expect_eq1("★ S2 陷阱后 MPIE ← MIE(1)（同拍取陷阱前值；旧实现恒 0）",
                   mstatus_o[`RV32GC_MSTATUS_MPIE_BIT], 1'b1);
        expect_eq1("S2 陷阱后 MIE ← 0",
                   mstatus_o[`RV32GC_MSTATUS_MIE_BIT], 1'b0);
        expect_eq32("S2 陷阱后 priv_ctrl 特权级 = M（陷阱目标）",
                    {30'b0, pc_priv_o}, 32'h3);
        csr_read_chk("S2 CSR 读 mstatus：MPP=3/MPIE=1/MIE=0/SIE=1",
                     `RV32GC_CSR_MSTATUS,
                     (32'h3 << `RV32GC_MSTATUS_MPP_LSB) |
                     (32'h1 << `RV32GC_MSTATUS_MPIE_BIT) |
                     (32'h1 << `RV32GC_MSTATUS_SIE_BIT));

        //   ---- S3：mret ⇒ 特权级 = MPP(前值 = M)、MPP ← U、MPIE ← 1、MIE ← MPIE ----
        @(negedge clk); pc_xret_valid = 1'b1; pc_xret_kind = 2'b01; #1;
        expect_eq32("★ S3 同拍读视图：MPP 仍为 3（mret 的 clr 不得污染本拍目标）",
                    (mstatus_o >> `RV32GC_MSTATUS_MPP_LSB) & 32'h3, 32'h3);
        expect_eq32("★ S3 同拍：priv_next = MPP = M",
                    {30'b0, pc_priv_next_o}, 32'h3);
        @(posedge clk); #1;
        @(negedge clk); pc_xret_valid = 1'b0; @(posedge clk); #1;
        expect_eq32("★ S3 mret 后特权级 = M（旧实现读被清掉的 MPP ⇒ 落到 U，必 FAIL）",
                    {30'b0, pc_priv_o}, 32'h3);
        expect_eq32("★ S3 mret 后 MPP 读回 = U(0)",
                    (mstatus_o >> `RV32GC_MSTATUS_MPP_LSB) & 32'h3, 32'h0);
        expect_eq1("S3 mret 后 MPIE = 1",
                   mstatus_o[`RV32GC_MSTATUS_MPIE_BIT], 1'b1);
        expect_eq1("S3 mret 后 MIE ← MPIE(1) = 1",
                   mstatus_o[`RV32GC_MSTATUS_MIE_BIT], 1'b1);

        //   ---- S4：S 侧 —— mret(MPP=S) 降到 S；sret(SPP=0) 再降到 U ----
        csr_write(`RV32GC_CSR_MSTATUS,
                  (32'h1 << `RV32GC_MSTATUS_MPP_LSB)   |
                  (32'h1 << `RV32GC_MSTATUS_MPIE_BIT)  |
                  (32'h1 << `RV32GC_MSTATUS_SIE_BIT)   |
                  (32'h1 << `RV32GC_MSTATUS_SPP_BIT));      // SPP=1（故意留残留）
        @(negedge clk); pc_xret_valid = 1'b1; pc_xret_kind = 2'b01;
        @(posedge clk); #1;
        @(negedge clk); pc_xret_valid = 1'b0; @(posedge clk); #1;
        expect_eq32("★ S4 mret(MPP=S) 后特权级 = S", {30'b0, pc_priv_o}, 32'h1);
        expect_eq32("S4 mret 后 MPP 读回 = U(0)",
                    (mstatus_o >> `RV32GC_MSTATUS_MPP_LSB) & 32'h3, 32'h0);
        //   sstatus 写：SIE=1、SPP=0、SPIE=0
        csr_write(`RV32GC_CSR_SSTATUS, (32'h1 << `RV32GC_MSTATUS_SIE_BIT));
        @(negedge clk); pc_xret_valid = 1'b1; pc_xret_kind = 2'b00;
        @(posedge clk); #1;
        @(negedge clk); pc_xret_valid = 1'b0; @(posedge clk); #1;
        expect_eq32("★ S4 sret(SPP=0) 后特权级 = U", {30'b0, pc_priv_o}, 32'h0);
        expect_eq1("S4 sret 后 SPIE = 1",
                   mstatus_o[`RV32GC_MSTATUS_SPIE_BIT], 1'b1);
        expect_eq1("S4 sret 后 SIE ← 旧 SPIE(0) = 0",
                   mstatus_o[`RV32GC_MSTATUS_SIE_BIT], 1'b0);
        expect_eq1("S4 sret 后 SPP ← U(0)",
                   mstatus_o[`RV32GC_MSTATUS_SPP_BIT], 1'b0);

        //   ---- S5：U→S 委托陷阱 ⇒ SPP ← y = U(0)（旧 SPP=1 不得残留）----
        csr_write(`RV32GC_CSR_SSTATUS,
                  (32'h1 << `RV32GC_MSTATUS_SIE_BIT) |
                  (32'h1 << `RV32GC_MSTATUS_SPP_BIT));      // 残留 SPP=1、SIE=1
        @(negedge clk); pc_trap_valid = 1'b1; pc_trap_target = `RV32GC_PRIV_S; #1;
        expect_eq1("★ S5 同拍读视图：SIE 仍为陷阱前值 1",
                   mstatus_o[`RV32GC_MSTATUS_SIE_BIT], 1'b1);
        expect_eq1("★ S5 同拍读视图：SPP 仍为陷阱前值 1（未被同拍 clr 污染）",
                   mstatus_o[`RV32GC_MSTATUS_SPP_BIT], 1'b1);
        @(posedge clk); #1;
        @(negedge clk); pc_trap_valid = 1'b0; @(posedge clk); #1;
        expect_eq1("★ S5 陷阱后 SPP ← y = U(0)（旧实现只置位 ⇒ 残留 1，必 FAIL）",
                   mstatus_o[`RV32GC_MSTATUS_SPP_BIT], 1'b0);
        expect_eq1("★ S5 陷阱后 SPIE ← 旧 SIE(1)",
                   mstatus_o[`RV32GC_MSTATUS_SPIE_BIT], 1'b1);
        expect_eq1("S5 陷阱后 SIE ← 0",
                   mstatus_o[`RV32GC_MSTATUS_SIE_BIT], 1'b0);
        expect_eq32("S5 陷阱后 priv_ctrl 特权级 = S（委托目标）",
                    {30'b0, pc_priv_o}, 32'h1);
        csr_read_chk("S5 sstatus 视图：SPIE=1/SIE=0/SPP=0",
                     `RV32GC_CSR_SSTATUS,
                     (32'h1 << `RV32GC_MSTATUS_SPIE_BIT));

        //   ---- S6：S→S（水平委托）陷阱 ⇒ SPP ← y = S(1) ----
        csr_write(`RV32GC_CSR_SSTATUS,
                  (32'h1 << `RV32GC_MSTATUS_SIE_BIT));      // SIE=1、SPP=0、SPIE=0
        @(negedge clk); pc_trap_valid = 1'b1; pc_trap_target = `RV32GC_PRIV_S; #1;
        @(posedge clk); #1;
        @(negedge clk); pc_trap_valid = 1'b0; @(posedge clk); #1;
        expect_eq1("★ S6 S→S 陷阱：SPP ← y = S(1)",
                   mstatus_o[`RV32GC_MSTATUS_SPP_BIT], 1'b1);
        expect_eq32("S6 陷阱后特权级仍 = S", {30'b0, pc_priv_o}, 32'h1);

        //======================================================================
        // 汇总
        //======================================================================
        $display("---- tb_csr_file: pass=%0d fail=%0d ----", n_pass, n_fail);
        if (n_fail != 0) begin
            $display("TB_CSR_FILE FAIL: %0d 项断言失败", n_fail);
            $fatal(1, "TB_CSR_FILE_UNIT: FAIL");
        end
        if (n_pass == 0) begin
            $display("TB_CSR_FILE FAIL: 未捕获任何检查（fail-closed）");
            $fatal(1, "TB_CSR_FILE_UNIT: FAIL");
        end
        //   ★ PASS 标幅改到 final 块里打印：
        //   iverilog 会在 $finish 后输出 "x.sv:N: $finish called at ..."，
        //   若标幅在 initial 里打就不会是最后一行。
        //   final 块的输出恰好落在该回显之后 ⇒ 满足
        //   "末行 = <TB>_UNIT: PASS"的验收判据（且 PASS 唯一）。
        sim_ok = 1'b1;
        $finish;
    end

    //--------------------------------------------------------------------------
    // 全局超时（fail-closed：超时 ⇒ 非零退出，绝不打印 PASS）
    //--------------------------------------------------------------------------
    initial begin
        #200000;
        $display("TB_CSR_FILE FAIL: 超时（未走完检查）");
        $fatal(1, "TB_CSR_FILE_UNIT: FAIL");
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
            $display("TB_CSR_FILE_UNIT: PASS");
    end

endmodule
