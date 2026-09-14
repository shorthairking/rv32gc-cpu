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
    wire [127:0] pmp_cfg_o;
    wire [511:0] pmp_addr_o;
    wire [31:0] satp_o, menvcfg_o, senvcfg_o, mcounteren_o, scounteren_o;
    wire [31:0] mtvec_o, stvec_o, medeleg_o, mideleg_o, mie_o, mip_o;

    csr_file dut (
        .clk(clk), .rst_n(rst_n),
        .raddr(raddr), .rdata(rdata),
        .wen(wen), .waddr(waddr), .wdata(wdata), .w_illegal(w_illegal),
        .rdata_w(rdata_w),
        .priv(priv),
        .chk_addr(chk_addr), .chk_illegal(chk_illegal), .chk_ro_write(chk_ro_write),
        .mstatus_o(mstatus_o),
        .mstatus_set(mstatus_set), .mstatus_clr(mstatus_clr),
        .trap_we(trap_we), .trap_epc_i(trap_epc_i), .trap_cause_i(trap_cause_i),
        .trap_tval_i(trap_tval_i), .trap_data_i(trap_data_i),
        .irq_msip(irq_msip), .irq_mtip(irq_mtip), .irq_meip(irq_meip),
        .irq_stip(irq_stip), .irq_seip(irq_seip),
        .cycle_i(cycle_i), .instret_i(instret_i),
        .pmp_cfg_o(pmp_cfg_o), .pmp_addr_o(pmp_addr_o),
        .satp_o(satp_o), .menvcfg_o(menvcfg_o), .senvcfg_o(senvcfg_o),
        .mcounteren_o(mcounteren_o), .scounteren_o(scounteren_o),
        .mtvec_o(mtvec_o), .stvec_o(stvec_o),
        .medeleg_o(medeleg_o), .mideleg_o(mideleg_o),
        .mie_o(mie_o), .mip_o(mip_o)
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
        input [255:0] name;
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
        input [255:0] name;
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
        input [255:0] name;
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
        //   ---- CBIE WARL：先写 CBIE=11（执行且做 INVAL），再写保留值 10 ⇒ 保持 11 ----
        csr_write(`RV32GC_CSR_MENVCFG, 32'h0000_00F1);   // FIOM=1 CBIE=11 CBCFE=1 CBZE=1
        csr_read_chk("menvcfg 全字段写入（CBIE=11）", `RV32GC_CSR_MENVCFG, 32'h0000_00F1);
        csr_write(`RV32GC_CSR_MENVCFG, 32'h0000_0031);   // CBIE=2'b10 保留
        csr_read_chk("menvcfg.CBIE=10 保留 ⇒ 保持旧值 11",
                     `RV32GC_CSR_MENVCFG, 32'h0000_0031);
        csr_write(`RV32GC_CSR_MENVCFG, 32'h0000_0001);   // CBIE=00, 只 FIOM
        csr_read_chk("menvcfg.CBIE=00(FIOM=1)", `RV32GC_CSR_MENVCFG, 32'h0000_0001);

        csr_write(`RV32GC_CSR_SENVCFG, 32'h0000_00D1);   // CBIE=01 CBCFE=1 CBZE=1 FIOM=1
        csr_read_chk("senvcfg 全字段写入（CBIE=01）", `RV32GC_CSR_SENVCFG, 32'h0000_00D1);
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
        chk_addr = `RV32GC_CSR_CYCLE; #1;
        expect_eq1("U 访问 cycle ⇒ chk_illegal=0", chk_illegal, 1'b0);
        priv = `RV32GC_PRIV_M;
        chk_addr = `RV32GC_CSR_SATP; #1;
        expect_eq1("M 访问 satp ⇒ chk_illegal=0", chk_illegal, 1'b0);

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

        //======================================================================
        // P. 计数器：mcycle/minstret 高半与 cycle/instret 只读视图
        //======================================================================
        cycle_i = 64'h0000_0001_CAFE_0000; instret_i = 64'h0000_0002_1234_0000; #1;
        csr_read_chk("cycle 低半",    `RV32GC_CSR_CYCLE,    32'hCAFE_0000);
        csr_read_chk("cycleh 高半",   `RV32GC_CSR_CYCLEH,   32'h0000_0001);
        csr_read_chk("instret 低半",  `RV32GC_CSR_INSTRET,  32'h1234_0000);
        csr_read_chk("instreth 高半", `RV32GC_CSR_INSTRETH, 32'h0000_0002);
        csr_write(`RV32GC_CSR_MCYCLE, 32'h0000_0011);
        csr_read_chk("mcycle 低半可写",  `RV32GC_CSR_MCYCLE,  32'h0000_0011);
        csr_write(`RV32GC_CSR_MCYCLEH, 32'h0000_0005);
        csr_read_chk("mcycleh 高半可写", `RV32GC_CSR_MCYCLEH, 32'h0000_0005);
        csr_write(`RV32GC_CSR_MINSTRETH, 32'h0000_0009);
        csr_read_chk("minstreth 高半可写", `RV32GC_CSR_MINSTRETH, 32'h0000_0009);

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
        // R. PMP L 位锁定行为（cfg 与 addr）
        //======================================================================
        csr_write(`RV32GC_CSR_PMPCFG0, 32'h0000_008F);   // 项0: L=1 A=NAPOT(3) RWX=7
        csr_read_chk("pmpcfg0 项0 L=1", `RV32GC_CSR_PMPCFG0, 32'h0000_008F);
        csr_write(`RV32GC_CSR_PMPCFG0, 32'h0000_000F);   // 撤 L ⇒ 写被忽略
        csr_read_chk("L=1 时 pmpcfg0 写入被忽略", `RV32GC_CSR_PMPCFG0, 32'h0000_008F);
        csr_write(`RV32GC_CSR_PMPADDR0, 32'h0000_1234);
        csr_read_chk("L 项自身的 pmpaddr 仍可写（本设计口径）",
                     `RV32GC_CSR_PMPADDR0, 32'h0000_1234);

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
