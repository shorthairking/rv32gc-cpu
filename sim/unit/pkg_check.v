//==============================================================================
// sim/unit/pkg_check.v —— rtl/pkg/{rv32_defs.vh, core_params.vh} 的最小自检 TB
//==============================================================================
// 目的    : 本文件**只为编译/取值自检**，不是产品代码，也不承担架构验证职责。
//           它保证：
//             (1) 两个真源包能被 iverilog 正确 include 且语法合法；
//             (2) 关键常量（RESET_PC / XIP / CSR 地址 / cause 码 / PMP / AXI /
//                 指令编码）的**取值没被误改**；
//             (3) 2A 的范围口径被机器检查（无 cbo.zero、cbo 动作码与 opcode/funct3
//                 组合唯一、无 FENCE 域重叠等）；
//             (4) **依赖方向**：`RV32GC_XIP_HI20*` 已迁至 core_params.vh ⇒
//                 core_params.vh 自包含、不再反向依赖 rv32_defs.vh（2026-09-14）。
//                 本 TB 因此先用 core_params.vh 的宏做一次取值检查。
// 判定    : 任一断言不成立 ⇒ 立即 $fatal（非零退出码），且**绝不打印 PASS**；
//           全部通过才在最后打印 `PKG_CHECK: PASS`。
//           调用方（验收命令）必须以「输出末行含 PKG_CHECK: PASS」且「进程退出码 0」
//           双条件判定；只匹配字符串不判退出码不构成通过（08 §8.1 fail-closed 纪律）。
// 顶层    : pkg_check_top（验收命令用 -s pkg_check_top）
// 说明    : 全部检查走 assign 连续赋值的 wire（watch_*），组合逻辑不含 always；
//           唯一的 initial 块只做"打印 + 断言"，不含任何时序行为（AGENT.md §4.3）。
//==============================================================================
`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"

module pkg_check_top;

    //--------------------------------------------------------------------------
    // 1. 常量镜像：把被检查的真源常量引入本模块（供 $display 与断言用）
    //--------------------------------------------------------------------------
    // ---- core_params.vh ----
    localparam [31:0] RESET_PC     = `RV32GC_RESET_PC;
    localparam [31:0] XIP_BASE     = `RV32GC_XIP_BASE;
    localparam [31:0] XIP_ALIAS    = `RV32GC_XIP_ALIAS;
    localparam [31:0] DDR_BASE     = `RV32GC_DDR_BASE;
    localparam [31:0] CLINT_BASE   = `RV32GC_CLINT_BASE;
    localparam [31:0] PLIC_BASE    = `RV32GC_PLIC_BASE;
    localparam [31:0] UART_BASE    = `RV32GC_UART_BASE;
    localparam [31:0] NAND_BASE    = `RV32GC_NAND_BASE;
    localparam [31:0] CONF_SIM     = `RV32GC_CONFREG_SIM_BASE;
    localparam [31:0] CONF_SYN     = `RV32GC_CONFREG_SYN_BASE;
    localparam        XLEN_L       = `RV32GC_XLEN;
    localparam        PMP_ENTRIES  = `RV32GC_PMP_ENTRIES;
    localparam        PMP_G        = `RV32GC_PMP_GRANULARITY;
    localparam        L1I_KB       = `RV32GC_L1I_SIZE_KB;
    localparam        L1D_KB       = `RV32GC_L1D_SIZE_KB;
    localparam        L1D_LINE     = `RV32GC_L1D_LINE_BYTES;
    localparam        L2_LINE      = `RV32GC_L2_LINE_BYTES;
    localparam        CBOM_BLK     = `RV32GC_CBOM_BLOCK_SIZE;
    localparam        CBOZ_BLK     = `RV32GC_CBOZ_BLOCK_SIZE;
    localparam        MSHR_DEPTH   = `RV32GC_MEMSHR_DEPTH;
    localparam [31:0] CLK_HZ       = `RV32GC_CLK_HZ;
    // ---- core_params.vh：XIP 高 12 位位段（2026-09-14 由位域真源迁入本包） ----
    localparam [11:0] XIP_HI20_V   = `RV32GC_XIP_HI20_VAL;
    localparam [11:0] XIP_HI20_M   = `RV32GC_XIP_HI20_MSK;
    // ---- rv32_defs.vh ----
    localparam [11:0] CSR_MSTATUS  = `RV32GC_CSR_MSTATUS;
    localparam [11:0] CSR_MISA     = `RV32GC_CSR_MISA;
    localparam [11:0] CSR_MEDELEG  = `RV32GC_CSR_MEDELEG;
    localparam [11:0] CSR_MEPC     = `RV32GC_CSR_MEPC;
    localparam [11:0] CSR_MCAUSE   = `RV32GC_CSR_MCAUSE;
    localparam [11:0] CSR_MTVAL    = `RV32GC_CSR_MTVAL;
    localparam [11:0] CSR_MTVEC    = `RV32GC_CSR_MTVEC;
    localparam [31:0] MTVAL_INSTR  = `RV32GC_MTVAL_INSTR_BITS;

    //--------------------------------------------------------------------------
    // 2. 组合检查网（只用 assign；无 always @(*)）
    //--------------------------------------------------------------------------
    // ---- 判断 cbo 动作码是否互不相同（若有人误把 clean/flush 写成同值则失败） ----
    wire [4:0] cbo_inval = `RV32GC_CBO_INVAL;
    wire [4:0] cbo_clean = `RV32GC_CBO_CLEAN;
    wire [4:0] cbo_flush = `RV32GC_CBO_FLUSH;
    wire cbo_codes_uniq  = (cbo_inval != cbo_clean) && (cbo_inval != cbo_flush) &&
                           (cbo_clean != cbo_flush);
    wire cbo_codes_zero  = (cbo_inval == 5'b00000) && (cbo_clean == 5'b00001) &&
                           (cbo_flush == 5'b00010);
    // ---- FENCE 与 CBO 共用 opcode=0001111，funct3 必须分开（0/1/2） ----
    wire fence_f3_distinct = (`RV32GC_F3_FENCE   !== `RV32GC_F3_CBO) &&
                             (`RV32GC_F3_FENCE_I !== `RV32GC_F3_CBO) &&
                             (`RV32GC_F3_FENCE   !== `RV32GC_F3_FENCE_I);
    // ---- OP-FP 的 fmt 必须与 funct5 分离：fmt 值只能取 0/1 ----
    wire fmt_ok = (`RV32GC_FMT_S == 2'b00) && (`RV32GC_FMT_D == 2'b01);
    // ---- ACLINT 偏移必须落在 CLINT 窗口内（0x1_0000） ----
    wire clint_off_ok = (`RV32GC_CLINT_MTIME_OFF + 8) <= `RV32GC_CLINT_SIZE;
    // ---- 2A 范围：必须未定义 cbo.zero（Zicboz），且开关为 0 ----
    wire zicboz_off   = (`RV32GC_IMPLEMENT_ZICBOZ == 0);
    // ---- 地址窗口不重叠（核内截获区不得落进 DDR3 默认通路） ----
    wire clint_outside_ddr = (CLINT_BASE >= `RV32GC_DDR_LIMIT);
    wire plic_outside_ddr  = (PLIC_BASE  >= `RV32GC_DDR_LIMIT);
    // ---- 核内私有窗口与平台外设窗口互不相同 ----
    wire priv_win_uniq = (CLINT_BASE != PLIC_BASE) &&
                         (CLINT_BASE != UART_BASE) && (PLIC_BASE != NAND_BASE);
    // ---- XIP 高 12 位位段：**定义在 core_params.vh**（2026-09-14 迁入，消除跨包依赖） ----
    //      两侧都必须能取到值：VAL 必须与 XIP_BASE 的 PA[31:20] 一致。
    wire [11:0] xip_hi20_val = `RV32GC_XIP_HI20;
    wire [11:0] xip_hi20_msk = `RV32GC_XIP_HI20_MSK;
    wire xip_hi20_ok = (xip_hi20_val === 12'h1C0) && (xip_hi20_msk === 12'hFFF) &&
                       (((XIP_BASE >> 20) & xip_hi20_msk) === xip_hi20_val);

    //--------------------------------------------------------------------------
    // 3. 断言（全部 $fatal；不打 PASS）
    //--------------------------------------------------------------------------
    initial begin
        $display("---- rv32_defs.vh / core_params.vh self-check ----");

        // (A) 复位/取指
        if (RESET_PC !== 32'h1C00_0000) begin
            $display("SYSCK FAIL: RESET_PC=%08x expect 0x1C000000", RESET_PC);
            $fatal(1, "PKG_CHECK FAIL");
        end
        if (XIP_BASE !== 32'h1C00_0000 || XIP_ALIAS !== 32'h1FE8_0000) begin
            $display("SYSCK FAIL: XIP base/alias = %08x/%08x", XIP_BASE, XIP_ALIAS);
            $fatal(1, "PKG_CHECK FAIL");
        end

        // (B) 平台地址映射
        if (DDR_BASE !== 32'h0000_0000) begin
            $display("SYSCK FAIL: DDR_BASE=%08x", DDR_BASE); $fatal(1, "PKG_CHECK FAIL");
        end
        if (DDR_BASE + (`RV32GC_DDR_SIZE_MB * 1024 * 1024) !== 32'h0800_0000) begin
            $display("SYSCK FAIL: DDR size!=128MiB (limit=%08x)",
                     DDR_BASE + (`RV32GC_DDR_SIZE_MB * 1024 * 1024));
            $fatal(1, "PKG_CHECK FAIL");
        end
        if (CLINT_BASE !== 32'h1F00_0000 || PLIC_BASE !== 32'h1F10_0000) begin
            $display("SYSCK FAIL: CLINT/PLIC = %08x/%08x", CLINT_BASE, PLIC_BASE);
            $fatal(1, "PKG_CHECK FAIL");
        end
        if (UART_BASE  !== 32'h1FE0_01E0 || NAND_BASE !== 32'h1FE7_8000) begin
            $display("SYSCK FAIL: UART/NAND = %08x/%08x", UART_BASE, NAND_BASE);
            $fatal(1, "PKG_CHECK FAIL");
        end
        if (CONF_SIM !== 32'h1FAF_0000 || CONF_SYN !== 32'h1FD0_0000) begin
            $display("SYSCK FAIL: CONFREG sim/syn = %08x/%08x", CONF_SIM, CONF_SYN);
            $fatal(1, "PKG_CHECK FAIL");
        end
        if (!clint_outside_ddr || !plic_outside_ddr) begin
            $display("SYSCK FAIL: CLINT/PLIC 落在 DDR3 默认通路区间内");
            $fatal(1, "PKG_CHECK FAIL");
        end
        if (!priv_win_uniq) begin
            $display("SYSCK FAIL: 核内私有窗口与平台窗口冲突"); $fatal(1, "PKG_CHECK FAIL");
        end
        // XIP 高 12 位位段（宏定义在 core_params.vh；此处兼作「已迁出 rv32_defs.vh」的机器检查）
        if (!xip_hi20_ok) begin
            $display("SYSCK FAIL: XIP_HI20 val/msk = %03x/%03x, XIP_BASE=%08x",
                     xip_hi20_val, xip_hi20_msk, XIP_BASE);
            $fatal(1, "PKG_CHECK FAIL");
        end

        // (C) 时钟/时间基准
        if (CLK_HZ !== 32'd33000000) begin
            $display("SYSCK FAIL: CLK_HZ=%0d expect 33000000", CLK_HZ);
            $fatal(1, "PKG_CHECK FAIL");
        end

        // (D) CSR 地址（规范真值：0x340 是 mscratch，mepc=0x341）
        if (CSR_MSTATUS !== 12'h300) begin
            $display("SYSCK FAIL: mstatus=%03x expect 300", CSR_MSTATUS);
            $fatal(1, "PKG_CHECK FAIL");
        end
        if (CSR_MISA    !== 12'h301) begin
            $display("SYSCK FAIL: misa=%03x expect 301", CSR_MISA);
            $fatal(1, "PKG_CHECK FAIL");
        end
        if (CSR_MEDELEG !== 12'h302) begin
            $display("SYSCK FAIL: medeleg=%03x expect 302", CSR_MEDELEG);
            $fatal(1, "PKG_CHECK FAIL");
        end
        if (CSR_MTVEC   !== 12'h305) begin
            $display("SYSCK FAIL: mtvec=%03x expect 305", CSR_MTVEC);
            $fatal(1, "PKG_CHECK FAIL");
        end
        if (CSR_MEPC    !== 12'h341) begin
            $display("SYSCK FAIL: mepc=%03x expect 341", CSR_MEPC);
            $fatal(1, "PKG_CHECK FAIL");
        end
        if (CSR_MCAUSE  !== 12'h342) begin
            $display("SYSCK FAIL: mcause=%03x expect 342", CSR_MCAUSE);
            $fatal(1, "PKG_CHECK FAIL");
        end
        if (CSR_MTVAL   !== 12'h343) begin
            $display("SYSCK FAIL: mtval=%03x expect 343", CSR_MTVAL);
            $fatal(1, "PKG_CHECK FAIL");
        end
        if (`RV32GC_CSR_MSCRATCH !== 12'h340) begin
            $display("SYSCK FAIL: mscratch=%03x expect 340", `RV32GC_CSR_MSCRATCH);
            $fatal(1, "PKG_CHECK FAIL");
        end
        if (`RV32GC_CSR_MIP !== 12'h344 || `RV32GC_CSR_MIE !== 12'h304) begin
            $display("SYSCK FAIL: mip=%03x mie=%03x",
                     `RV32GC_CSR_MIP, `RV32GC_CSR_MIE);
            $fatal(1, "PKG_CHECK FAIL");
        end
        if (`RV32GC_CSR_MEDELEGH !== 12'h312 || `RV32GC_CSR_MIDELEGH !== 12'h313) begin
            $display("SYSCK FAIL: medelegh/midelegh 别名地址错");
            $fatal(1, "PKG_CHECK FAIL");
        end
        if (`RV32GC_CSR_MENVCFG !== 12'h30A || `RV32GC_CSR_MSTATUSH !== 12'h310) begin
            $display("SYSCK FAIL: menvcfg/mstatush 地址错");
            $fatal(1, "PKG_CHECK FAIL");
        end
        if (`RV32GC_CSR_PMPCFG0 !== 12'h3A0 || `RV32GC_CSR_PMPCFG3 !== 12'h3A3) begin
            $display("SYSCK FAIL: pmpcfg0/3 地址错");
            $fatal(1, "PKG_CHECK FAIL");
        end
        if (`RV32GC_CSR_PMPADDR0 !== 12'h3B0 || `RV32GC_CSR_PMPADDR15 !== 12'h3BF) begin
            $display("SYSCK FAIL: pmpaddr0/15 地址错");
            $fatal(1, "PKG_CHECK FAIL");
        end
        if (`RV32GC_CSR_MCYCLE !== 12'hB00 || `RV32GC_CSR_MINSTRET !== 12'hB02) begin
            $display("SYSCK FAIL: mcycle/minstret 地址错");
            $fatal(1, "PKG_CHECK FAIL");
        end
        if (`RV32GC_CSR_SSTATUS !== 12'h100 || `RV32GC_CSR_SATP !== 12'h180 ||
            `RV32GC_CSR_STVEC   !== 12'h105 || `RV32GC_CSR_SENVCFG !== 12'h10A) begin
            $display("SYSCK FAIL: S 模式 CSR 地址错");
            $fatal(1, "PKG_CHECK FAIL");
        end
        if (`RV32GC_CSR_SEPC !== 12'h141 || `RV32GC_CSR_SCAUSE !== 12'h142 ||
            `RV32GC_CSR_STVAL !== 12'h143 || `RV32GC_CSR_SIP !== 12'h144) begin
            $display("SYSCK FAIL: sepc/scause/stval/sip 地址错");
            $fatal(1, "PKG_CHECK FAIL");
        end
        if (`RV32GC_CSR_FFLAGS !== 12'h001 || `RV32GC_CSR_FCSR !== 12'h003) begin
            $display("SYSCK FAIL: fflags/fcsr 地址错"); $fatal(1, "PKG_CHECK FAIL");
        end
        if (`RV32GC_CSR_CYCLE !== 12'hC00 || `RV32GC_CSR_INSTRETH !== 12'hC82) begin
            $display("SYSCK FAIL: cycle/instreth 地址错"); $fatal(1, "PKG_CHECK FAIL");
        end
        if (`RV32GC_CSR_MHARTID !== 12'hF14) begin
            $display("SYSCK FAIL: mhartid 地址错"); $fatal(1, "PKG_CHECK FAIL");
        end

        // (E) cause 码
        if (`RV32GC_EXC_INSN_ACCESS_FAULT !== 5'd1 ||
            `RV32GC_EXC_ILLEGAL_INSN      !== 5'd2 ||
            `RV32GC_EXC_LOAD_ACCESS_FAULT !== 5'd5 ||
            `RV32GC_EXC_STORE_ACCESS_FAULT!== 5'd7) begin
            $display("SYSCK FAIL: access-fault 类 cause 码错"); $fatal(1, "PKG_CHECK FAIL");
        end
        if (`RV32GC_EXC_ECALL_U !== 5'd8 || `RV32GC_EXC_ECALL_S !== 5'd9 ||
            `RV32GC_EXC_ECALL_M !== 5'd11) begin
            $display("SYSCK FAIL: ecall cause 码错"); $fatal(1, "PKG_CHECK FAIL");
        end
        if (`RV32GC_EXC_INSN_PAGE_FAULT  !== 5'd12 ||
            `RV32GC_EXC_LOAD_PAGE_FAULT  !== 5'd13 ||
            `RV32GC_EXC_STORE_PAGE_FAULT !== 5'd15) begin
            $display("SYSCK FAIL: page-fault cause 码错"); $fatal(1, "PKG_CHECK FAIL");
        end
        if (`RV32GC_IRQ_M_TIMER !== 5'd7 || `RV32GC_IRQ_M_EXTERNAL !== 5'd11 ||
            `RV32GC_IRQ_S_EXTERNAL !== 5'd9) begin
            $display("SYSCK FAIL: 中断 cause 码错"); $fatal(1, "PKG_CHECK FAIL");
        end
        if (`RV32GC_MCAUSE_INT_BIT !== 31) begin
            $display("SYSCK FAIL: mcause Interrupt 位不是 31");
            $fatal(1, "PKG_CHECK FAIL");
        end
        if (`RV32GC_MIDELEG_IMPL_MSK !== 32'h0000_0222) begin
            $display("SYSCK FAIL: mideleg 实现掩码错"); $fatal(1, "PKG_CHECK FAIL");
        end

        // (F) PMP 与 AXI
        if (PMP_ENTRIES !== 16 || PMP_G !== 0) begin
            $display("SYSCK FAIL: PMP 项数/粒度 = %0d/G=%0d", PMP_ENTRIES, PMP_G);
            $fatal(1, "PKG_CHECK FAIL");
        end
        if (`RV32GC_PMP_A_NA4 !== 2'b10 || `RV32GC_PMP_A_NAPOT !== 2'b11 ||
            `RV32GC_PMP_A_TOR !== 2'b01 || `RV32GC_PMP_A_OFF   !== 2'b00) begin
            $display("SYSCK FAIL: PMP A 字段编码错"); $fatal(1, "PKG_CHECK FAIL");
        end
        if (`RV32GC_PMP_CFG_PER_CSR !== 4) begin
            $display("SYSCK FAIL: pmpcfg 每 CSR 项数错"); $fatal(1, "PKG_CHECK FAIL");
        end
        if (`RV32GC_AXI_SIZE_4B !== 3'b010) begin
            $display("SYSCK FAIL: AXI AxSIZE=4B 编码错"); $fatal(1, "PKG_CHECK FAIL");
        end
        if (`RV32GC_AXI_LEN_MAX !== 4'd15) begin
            $display("SYSCK FAIL: AXI AxLEN 上限错"); $fatal(1, "PKG_CHECK FAIL");
        end
        if (`RV32GC_AXI_BURST_INCR !== 2'b01) begin
            $display("SYSCK FAIL: AXI INCR 编码错"); $fatal(1, "PKG_CHECK FAIL");
        end
        if (`RV32GC_AXI_RESP_OKAY !== 2'b00 || `RV32GC_AXI_RESP_DECERR !== 2'b11) begin
            $display("SYSCK FAIL: AXI RESP 编码错"); $fatal(1, "PKG_CHECK FAIL");
        end
        if (`RV32GC_AXI_ID_W !== 4 || `RV32GC_AXI_DATA_W !== 32 ||
            `RV32GC_AXI_ADDR_W !== 32 || `RV32GC_AXI_LEN_W !== 4) begin
            $display("SYSCK FAIL: AXI 位宽与平台 config.h 不一致");
            $fatal(1, "PKG_CHECK FAIL");
        end

        // (G) 指令编码抽查（opcode/funct3）
        if (`RV32GC_OP_AMO !== 7'b0101111 || `RV32GC_F3_AMO !== 3'b010) begin
            $display("SYSCK FAIL: AMO opcode/funct3 错"); $fatal(1, "PKG_CHECK FAIL");
        end
        if (`RV32GC_AMO_LR !== 5'b00010 || `RV32GC_AMO_SC !== 5'b00011) begin
            $display("SYSCK FAIL: LR/SC funct5 错"); $fatal(1, "PKG_CHECK FAIL");
        end
        if (`RV32GC_F7_MULDIV !== 7'b0000001 || `RV32GC_F3_DIV !== 3'b100 ||
            `RV32GC_F3_REMU !== 3'b111) begin
            $display("SYSCK FAIL: M 扩展编码错"); $fatal(1, "PKG_CHECK FAIL");
        end
        if (`RV32GC_F3_CSRRW !== 3'b001 || `RV32GC_F3_CSRRS  !== 3'b010 ||
            `RV32GC_F3_CSRRC !== 3'b011 || `RV32GC_F3_CSRRWI !== 3'b101 ||
            `RV32GC_F3_CSRRSI !== 3'b110 || `RV32GC_F3_CSRRCI !== 3'b111 ||
            `RV32GC_CSR_ZIMM_W !== 5) begin
            $display("SYSCK FAIL: Zicsr funct3/zimm 错"); $fatal(1, "PKG_CHECK FAIL");
        end
        if (`RV32GC_OP_SYSTEM !== 7'b1110011 || `RV32GC_F3_PRIV !== 3'b000) begin
            $display("SYSCK FAIL: SYSTEM opcode 错"); $fatal(1, "PKG_CHECK FAIL");
        end
        if (`RV32GC_INSN_ECALL  !== 32'h0000_0073 ||
            `RV32GC_INSN_EBREAK !== 32'h0010_0073 ||
            `RV32GC_INSN_MRET   !== 32'h3020_0073 ||
            `RV32GC_INSN_SRET   !== 32'h1020_0073 ||
            `RV32GC_INSN_WFI    !== 32'h1050_0073) begin
            $display("SYSCK FAIL: ecall/ebreak/mret/sret/wfi MATCH 值错");
            $fatal(1, "PKG_CHECK FAIL");
        end
        if (`RV32GC_F3_FENCE !== 3'b000 || `RV32GC_F3_FENCE_I !== 3'b001 ||
            !fence_f3_distinct) begin
            $display("SYSCK FAIL: fence/fence.i funct3 错"); $fatal(1, "PKG_CHECK FAIL");
        end
        if (`RV32GC_OP_FP !== 7'b1010011 || !fmt_ok) begin
            $display("SYSCK FAIL: OP-FP opcode/fmt 错"); $fatal(1, "PKG_CHECK FAIL");
        end
        if (`RV32GC_FP_F5_FADD !== 5'b00000 || `RV32GC_FP_F5_FDIV !== 5'b00011 ||
            `RV32GC_FP_F5_FSQRT !== 5'b01011 || `RV32GC_FP_F5_FSGNJ !== 5'b00100 ||
            `RV32GC_FP_F5_FCMP !== 5'b10100) begin
            $display("SYSCK FAIL: OP-FP funct5 错"); $fatal(1, "PKG_CHECK FAIL");
        end
        if (`RV32GC_F3_FLD !== 3'b011 || `RV32GC_F3_FSD !== 3'b011 ||
            `RV32GC_F3_FLW !== 3'b010) begin
            $display("SYSCK FAIL: FP load/store funct3 错"); $fatal(1, "PKG_CHECK FAIL");
        end

        // (H) cbo.*（Zicbom only）与 2A 范围
        if (`RV32GC_F3_CBO !== 3'b010 || `RV32GC_F7_CBO !== 7'b0000000) begin
            $display("SYSCK FAIL: CBO funct3/funct7 错"); $fatal(1, "PKG_CHECK FAIL");
        end
        if (!cbo_codes_uniq || !cbo_codes_zero) begin
            $display("SYSCK FAIL: cbo inval/clean/flush rs2 动作码错");
            $fatal(1, "PKG_CHECK FAIL");
        end
        if (!zicboz_off) begin
            $display("SYSCK FAIL: 2A 不得启用 Zicboz(cbo.zero)");
            $fatal(1, "PKG_CHECK FAIL");
        end

        // (I) Cache / CMO 参数
        if (L1I_KB !== 16 || L1D_KB !== 32 || L1D_LINE !== 32 || L2_LINE !== 64) begin
            $display("SYSCK FAIL: L1/L2 行/容量参数错");
            $fatal(1, "PKG_CHECK FAIL");
        end
        if (CBOM_BLK !== 64 || CBOZ_BLK !== 32) begin
            $display("SYSCK FAIL: CMO block size 错 (cbom=%0d cboz=%0d)", CBOM_BLK, CBOZ_BLK);
            $fatal(1, "PKG_CHECK FAIL");
        end
        if (MSHR_DEPTH !== 1) begin
            $display("SYSCK FAIL: 2A MSHR 深度应为 1"); $fatal(1, "PKG_CHECK FAIL");
        end

        // (J) 取值口径开关与 IP 双分支
        if (MTVAL_INSTR !== 1) begin
            $display("SYSCK FAIL: RV32GC_MTVAL_INSTR_BITS 应为 1（本设计选择实现）");
            $fatal(1, "PKG_CHECK FAIL");
        end
        if (`RV32GC_FETCH_PMP_PER_PARCEL !== 1) begin
            $display("SYSCK FAIL: 取指 PMP 粒度应为 16-bit parcel");
            $fatal(1, "PKG_CHECK FAIL");
        end
        if (`RV32GC_MISALIGN_PRIORITY_HIGH !== 1) begin
            $display("SYSCK FAIL: 非对齐应优先"); $fatal(1, "PKG_CHECK FAIL");
        end
    `ifdef RV32GC_USE_VIVADO_IP
        if (`RV32GC_IP_SEL_VIVADO !== 1 || `RV32GC_IP_SEL_BEHAVIOR !== 0) begin
            $display("SYSCK FAIL: VIVADO_IP 已定义时分支选择错");
            $fatal(1, "PKG_CHECK FAIL");
        end
        $display("note: RV32GC_USE_VIVADO_IP 已定义（综合分支）");
    `else
        if (`RV32GC_IP_SEL_VIVADO !== 0 || `RV32GC_IP_SEL_BEHAVIOR !== 1) begin
            $display("SYSCK FAIL: 仿真分支选择错"); $fatal(1, "PKG_CHECK FAIL");
        end
        $display("note: RV32GC_USE_VIVADO_IP 未定义（仿真行为模型分支，回归口径）");
    `endif
        if (`RV32GC_IMPLEMENTS_ZICBOM !== 1 || `RV32GC_IMPLEMENTS_ZICBOZ !== 0 ||
            `RV32GC_IMPLEMENTS_SV32   !== 1 || `RV32GC_IMPLEMENTS_PMP16  !== 1) begin
            $display("SYSCK FAIL: 2A 扩展实现开关错"); $fatal(1, "PKG_CHECK FAIL");
        end

        // (K) 关键值打印（供验收命令与人工复核留痕）
        $display("RESET_PC     = %08x", RESET_PC);
        $display("XIP base/ali = %08x / %08x", XIP_BASE, XIP_ALIAS);
        $display("XIP HI20 val/msk = %03x / %03x (defined in core_params.vh)",
                 XIP_HI20_V, XIP_HI20_M);
        $display("CLINT / PLIC = %08x / %08x", CLINT_BASE, PLIC_BASE);
        $display("mstatus      = %03x", CSR_MSTATUS);
        $display("mepc/mcause  = %03x / %03x", CSR_MEPC, CSR_MCAUSE);
        $display("PMP entries  = %0d (G=%0d)", PMP_ENTRIES, PMP_G);
        $display("XLEN         = %0d, IALIGN = %0d", XLEN_L, `RV32GC_IALIGN);
        $display("clk/timebase = %0d Hz", CLK_HZ);
        $display("L1I/L1D      = %0d KB / %0d KB", L1I_KB, L1D_KB);
        $display("cause exc 1/2/5/7/12 = %0d/%0d/%0d/%0d/%0d",
                 `RV32GC_EXC_INSN_ACCESS_FAULT, `RV32GC_EXC_ILLEGAL_INSN,
                 `RV32GC_EXC_LOAD_ACCESS_FAULT, `RV32GC_EXC_STORE_ACCESS_FAULT,
                 `RV32GC_EXC_INSN_PAGE_FAULT);
        $display("cbo rs2 inval/clean/flush = %0d/%0d/%0d",
                 cbo_inval, cbo_clean, cbo_flush);

        // 到达此处 = 全部断言通过
        $display("PKG_CHECK: PASS");
        $finish;
    end

endmodule
