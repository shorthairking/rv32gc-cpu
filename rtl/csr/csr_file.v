//==============================================================================
// csr_file.v —— RV32-GC 2A CSR 寄存器组（M/S 全套地址 + WARL + 访问权限）
//==============================================================================
// 依据    : docs/design/08-baseline-5stage.md §6.2（CSR 全集清单）、§6.5（envcfg）、
//           §8.2.1(b)（arch-test 硬要求：mcountinhibit/mhpmevent3..31 必须可写）
//           docs/design/06-csr-privilege.md §2/§3/§7/§9
//           docs/kb/isa-notes.md §4 T1–T8、§6
// 真源    : rtl/pkg/rv32_defs.vh（CSR 地址/cause/位域）、rtl/pkg/core_params.vh
// 红线    : ① 无任何 FPGA 原语；② 组合逻辑用 assign/function，不用 always @(*) 大块；
//           ③ **不实现 U 模式 CSR 逻辑**（RV32GC_IMPLEMENT_U_MODE_CSRS=0 门控保持 0）。
//------------------------------------------------------------------------------
// 【设计口径摘要】（每条给出 08/06 的出处，便于复核）
//  1. WARL 框架：所有可写 CSR 先算 wdata_masked（位域掩码），写通道统一为
//     「写读属性判定 → 未实现地址 ⇒ 非法 → 只读 CSR 写 ⇒ 非法 → 落地 WARL 子集」。
//  2. 写只读 CSR（csr[11:10]==2'b11）⇒ 非法指令异常（cause 2，tval=指令位）。
//  3. **mcountinhibit(0x320) 与 mhpmevent3..31(0x323..0x33F) 必须"已实现且吞写"**，
//     绝不可落入"未实现地址"分支：否则 arch-test 在 RVTEST_BOOT_TO_MMODE 挂死
//     （riscv-arch-test/tests/env/rvtest_setup.h:1059-1129；08 §8.2.1(b)）。
//  4. U 模式 CSR（ustatus/uie/utvec/uscratch/uepc/ucause/utval/uip）在门控 = 0 时
//     按**未实现**处理 ⇒ U/S 访问报非法（08 §6.2 "U 模式 CSR 不落地"裁决）。
//  5. pmpcfg/pmpaddr 的 L 位锁定：L=1 的项及其 TOR 前驱地址寄存器写入被忽略
//     （06 §6.2 norm:pmplbitwriteprotection）。
//  6. satp.MODE 写保留值 ⇒ WARL 写入被忽略（不改值）（06 §9）。
//==============================================================================
`timescale 1ns / 1ps

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"

module csr_file (
    input  wire        clk,
    input  wire        rst_n,

    //--------------------------------------------------------------------------
    // 读端口（组合读；两级译码）
    //--------------------------------------------------------------------------
    input  wire [11:0] raddr,
    output wire [31:0] rdata,

    //--------------------------------------------------------------------------
    // 写端口（W 级提交；1 拍脉冲 wen）
    //--------------------------------------------------------------------------
    input  wire        wen,
    input  wire [11:0] waddr,
    input  wire [31:0] wdata,
    input  wire        w_illegal,   // 02 口径：源操作数为 0 的 CSRRS/CSRRC 是"无写"
    output wire [31:0] rdata_w,     // 写端口旁路读值（供同拍 CSR 读）

    //--------------------------------------------------------------------------
    // 当前特权级（来自 priv_ctrl；用于访问权限判定）
    //--------------------------------------------------------------------------
    input  wire [1:0]  priv,

    //--------------------------------------------------------------------------
    // CSR 地址权限判定结果（给 dec_csr / trap_ctrl 用）
    //--------------------------------------------------------------------------
    input  wire [11:0] chk_addr,
    output wire        chk_illegal,   // 访问非法（未实现 / 特权级不足）⇒ cause 2
    output wire        chk_ro_write,  // 写只读 CSR ⇒ cause 2

    //--------------------------------------------------------------------------
    // mstatus 视图（priv_ctrl 用）
    //--------------------------------------------------------------------------
    output wire [31:0] mstatus_o,
    input  wire [31:0] mstatus_set,   // trap_ctrl 置位（xPIE/xIE/xPP），优先于 wen
    input  wire [31:0] mstatus_clr,

    //--------------------------------------------------------------------------
    // 陷阱目标 CSR 写口（trap_ctrl 在陷阱入口写 *epc/*cause/*tval）
    // 优先级：trap_we > wen（同一拍不可能同时出现，但显式定序避免锁存歧义）
    //--------------------------------------------------------------------------
    input  wire [3:0]  trap_we,       // {sepc,stval,scause,mepc+mtval+mcause} 分组使能
    input  wire [11:0] trap_addr,
    input  wire [31:0] trap_wdata,

    //--------------------------------------------------------------------------
    // 中断请求（核内 CLINT/PLIC 汇入）+ 软件可写 pending 位
    //--------------------------------------------------------------------------
    input  wire        irq_msip,      // CLINT msip      ⇒ mip[3]
    input  wire        irq_mtip,      // CLINT mtimecmp  ⇒ mip[7]
    input  wire        irq_meip,      // PLIC ctx0       ⇒ mip[11]
    input  wire        irq_stip,      // 核内 STIP 源     ⇒ mip[5]
    input  wire        irq_seip,      // PLIC ctx1       ⇒ mip[9]

    //--------------------------------------------------------------------------
    // 计数器（Zicntr）
    //--------------------------------------------------------------------------
    input  wire [63:0] cycle_i,
    input  wire [63:0] instret_i,

    //--------------------------------------------------------------------------
    // PMP（给 pmp_check 用）
    //--------------------------------------------------------------------------
    output wire [127:0] pmp_cfg_o,    // 16 项 × 8 bit = 128 bit
    output wire [511:0] pmp_addr_o,   // 16 项 × 32 bit = 512 bit

    //--------------------------------------------------------------------------
    // 配置字段（给 lsu / mmu / cmo_unit / mcounteren 门控用）
    //--------------------------------------------------------------------------
    output wire [31:0] satp_o,
    output wire [31:0] menvcfg_o,
    output wire [31:0] senvcfg_o,
    output wire [31:0] mcounteren_o,
    output wire [31:0] scounteren_o,
    output wire [31:0] mtvec_o,
    output wire [31:0] stvec_o,
    output wire [31:0] medeleg_o,
    output wire [31:0] mideleg_o,
    output wire [31:0] mie_o,
    output wire [31:0] mip_o
);

    //==========================================================================
    // 1. 地址分类（function 表达，禁止 always @(*) 大块）
    //    地址高 4 位编码访问属性：csr[11:10] = 读写属性、csr[9:8] = 最低特权级
    //    [ISA:csrs.adoc:25-49]
    //==========================================================================
    localparam [1:0] PRIV_U = `RV32GC_PRIV_U;   // 2'b00
    localparam [1:0] PRIV_S = `RV32GC_PRIV_S;   // 2'b01
    localparam [1:0] PRIV_M = `RV32GC_PRIV_M;   // 2'b11

    // ---- 地址的"最低可访问特权级"（由 csr[9:8] 给出） ----
    function [1:0] csr_min_priv;
        input [11:0] a;
        begin
            // csr[9:8]: 00=U, 01=S, 10=H(本设计未实现), 11=M
            case (a[9:8])
                2'b00:   csr_min_priv = PRIV_U;
                2'b01:   csr_min_priv = PRIV_S;
                2'b11:   csr_min_priv = PRIV_M;
                default: csr_min_priv = PRIV_M;  // 2'b10 = H：本设计无 H 扩展 ⇒ 按 M 专属
            endcase
        end
    endfunction

    // ---- 地址是否只读（csr[11:10]==2'b11） ----
    function csr_is_ro;
        input [11:0] a;
        begin
            csr_is_ro = (a[11:10] == 2'b11);
        end
    endfunction

    // ---- 特权级编码的"高低"比较（U<S<M；H 不实现） ----
    function priv_ge;
        input [1:0] cur;
        input [1:0] need;
        begin
            // 编码 U=00 < S=01 < (H=10) < M=11 ⇒ 直接数值比较即可
            priv_ge = (cur >= need);
        end
    endfunction

    //==========================================================================
    // 2. 本设计中"已实现"的 CSR 地址判定
    //    注意：未实现在此**没有**列举的地址（含 U 模式 CSR）⇒ 非法
    //==========================================================================
    function is_impl;
        input [11:0] a;
        begin
            case (a)
                // ---- M 模式：信息寄存器（只读） ----
                `RV32GC_CSR_MVENDORID,
                `RV32GC_CSR_MARCHID,
                `RV32GC_CSR_MIMPID,
                `RV32GC_CSR_MHARTID:   is_impl = 1'b1;
                // ---- M 模式：陷阱设置 ----
                `RV32GC_CSR_MSTATUS,
                `RV32GC_CSR_MISA,
                `RV32GC_CSR_MEDELEG,
                `RV32GC_CSR_MIDELEG,
                `RV32GC_CSR_MIE,
                `RV32GC_CSR_MTVEC,
                `RV32GC_CSR_MCOUNTEREN,
                `RV32GC_CSR_MSTATUSH,   // RV32 必需；无 MBE/SBE ⇒ 读 0
                `RV32GC_CSR_MEDELEGH,   // RV32 高半别名
                `RV32GC_CSR_MIDELEGH:   is_impl = 1'b1;
                // ---- M 模式：环境配置 ----
                `RV32GC_CSR_MENVCFG,
                `RV32GC_CSR_MENVCFGH:   is_impl = 1'b1;   // RV32 高半，读 0
                // ---- M 模式：陷阱处理 ----
                `RV32GC_CSR_MSCRATCH,
                `RV32GC_CSR_MEPC,
                `RV32GC_CSR_MCAUSE,
                `RV32GC_CSR_MTVAL,
                `RV32GC_CSR_MIP:        is_impl = 1'b1;
                // ---- M 模式：PMP ----
                `RV32GC_CSR_PMPCFG0, `RV32GC_CSR_PMPCFG1,
                `RV32GC_CSR_PMPCFG2, `RV32GC_CSR_PMPCFG3: is_impl = 1'b1;
                `RV32GC_CSR_PMPADDR0, `RV32GC_CSR_PMPADDR1,
                `RV32GC_CSR_PMPADDR2, `RV32GC_CSR_PMPADDR3,
                `RV32GC_CSR_PMPADDR4, `RV32GC_CSR_PMPADDR5,
                `RV32GC_CSR_PMPADDR6, `RV32GC_CSR_PMPADDR7,
                `RV32GC_CSR_PMPADDR8, `RV32GC_CSR_PMPADDR9,
                `RV32GC_CSR_PMPADDR10,`RV32GC_CSR_PMPADDR11,
                `RV32GC_CSR_PMPADDR12,`RV32GC_CSR_PMPADDR13,
                `RV32GC_CSR_PMPADDR14,`RV32GC_CSR_PMPADDR15: is_impl = 1'b1;
                // ---- M 模式：计数器 ----
                `RV32GC_CSR_MCYCLE,
                `RV32GC_CSR_MINSTRET,
                `RV32GC_CSR_MCOUNTINHIBIT:  is_impl = 1'b1;   // ★ 08 §8.2.1(b) 硬要求
                `RV32GC_CSR_MCYCLEH,
                `RV32GC_CSR_MINSTRETH:      is_impl = 1'b1;   // RV32 高半
                // ---- ★ mhpmevent3..31（0x323..0x33F）：必须"已实现且吞写" ----
                //   08 §8.2.1(b)：riscv-arch-test/tests/env/rvtest_setup.h:1066-1095
                //   无条件 `csrw mhpmevent3..31, zero`（29 条，注释 "They must be implemented."）。
                //   落入"未实现"分支 ⇒ 启动阶段挂死 ⇒ 全部用例全挂。
                //   本项目 2A 不实现计数器事件选择逻辑 ⇒ WARL：吞写、读 0。
                `RV32GC_CSR_MHPMEVENT3,
                12'h324, 12'h325, 12'h326, 12'h327, 12'h328, 12'h329, 12'h32A, 12'h32B,
                12'h32C, 12'h32D, 12'h32E, 12'h32F, 12'h330, 12'h331, 12'h332, 12'h333,
                12'h334, 12'h335, 12'h336, 12'h337, 12'h338, 12'h339, 12'h33A, 12'h33B,
                12'h33C, 12'h33D, 12'h33E,
                `RV32GC_CSR_MHPMEVENT31:    is_impl = 1'b1;
                // ---- 非特权：FP ----
                `RV32GC_CSR_FFLAGS,
                `RV32GC_CSR_FRM,
                `RV32GC_CSR_FCSR:    is_impl = 1'b1;
                // ---- 非特权：计数器（只读视图） ----
                `RV32GC_CSR_CYCLE,
                `RV32GC_CSR_TIME,
                `RV32GC_CSR_INSTRET,
                `RV32GC_CSR_CYCLEH,
                `RV32GC_CSR_TIMEH,
                `RV32GC_CSR_INSTRETH: is_impl = 1'b1;
                // ---- S 模式 ----
                `RV32GC_CSR_SSTATUS,
                `RV32GC_CSR_SIE,
                `RV32GC_CSR_STVEC,
                `RV32GC_CSR_SCOUNTEREN,
                `RV32GC_CSR_SENVCFG,
                `RV32GC_CSR_SSCRATCH,
                `RV32GC_CSR_SEPC,
                `RV32GC_CSR_SCAUSE,
                `RV32GC_CSR_STVAL,
                `RV32GC_CSR_SIP,
                `RV32GC_CSR_SATP:    is_impl = 1'b1;
                // ---- U 模式 CSR：门控 = 0 ⇒ 一律未实现（08 §6.2 裁决） ----
                //     门控保持 0，本设计**不实现 U 模式 CSR 逻辑**：此处刻意不列举。
                //     若将来要落地，把下面常量加进本 case 并把 RV32GC_IMPLEMENT_U_MODE_CSRS
                //     置 1；其余 WARL 逻辑需同步补齐（见报告「遗留/风险」）。
                default:             is_impl = 1'b0;
            endcase
        end
    endfunction

    // ---- 写掩码（WARL 落地子集；1 = 该位可写） ----
    //      未列出的地址走 default ⇒ 全 0（吞写）
    function [31:0] wr_mask;
        input [11:0] a;
        begin
            case (a)
                // ---- mstatus：实现 MIE/SIE/MPIE/SPIE/MPP/SPP/MPRV/SUM/MXR/TVM/TW/TSR/FS ----
                //   UIE/UBE/XS 只读 0；SD 只读汇总（由 FS 驱动）
                `RV32GC_CSR_MSTATUS: wr_mask =
                    (32'h1 << `RV32GC_MSTATUS_SIE_BIT)  |   // [1]  SIE
                    (32'h1 << `RV32GC_MSTATUS_MIE_BIT)  |   // [3]  MIE
                    (32'h1 << `RV32GC_MSTATUS_SPIE_BIT) |   // [5]  SPIE
                    (32'h1 << `RV32GC_MSTATUS_MPIE_BIT) |   // [7]  MPIE
                    (32'h1 << `RV32GC_MSTATUS_SPP_BIT)  |   // [8]  SPP
                    (`RV32GC_MSTATUS_FS_MSK  << `RV32GC_MSTATUS_FS_LSB)  |  // [14:13] FS
                    (`RV32GC_MSTATUS_MPP_MSK << `RV32GC_MSTATUS_MPP_LSB) |  // [12:11] MPP
                    (32'h1 << `RV32GC_MSTATUS_MPRV_BIT) |   // [17] MPRV
                    (32'h1 << `RV32GC_MSTATUS_SUM_BIT)  |   // [18] SUM
                    (32'h1 << `RV32GC_MSTATUS_MXR_BIT)  |   // [19] MXR
                    (32'h1 << `RV32GC_MSTATUS_TVM_BIT)  |   // [20] TVM
                    (32'h1 << `RV32GC_MSTATUS_TW_BIT)   |   // [21] TW
                    (32'h1 << `RV32GC_MSTATUS_TSR_BIT);     // [22] TSR
                // ---- misa：WARL，MXL + 扩展位。**写 MXL 为只读**（保持 1） ----
                //   扩展位固定（本核不支持动态改变），故整寄存器视为只读（见 rd 逻辑）。
                `RV32GC_CSR_MISA:     wr_mask = 32'h0000_0000;
                // ---- medeleg：实现 bit 0-9|12|13|15（08 §6.2；M 专属 10/11/14 不实现） ----
                `RV32GC_CSR_MEDELEG:  wr_mask = `RV32GC_MEDELEG_IMPL_MSK;
                // ---- medelegh：RV32 高半别名；RV32 相关位均不在此半 ⇒ 吞写读 0 ----
                `RV32GC_CSR_MEDELEGH: wr_mask = 32'h0000_0000;
                // ---- mideleg：实现 bit 1(SSI)/5(STI)/9(SEI)；M 专属 3/7/11 硬连 0 ----
                `RV32GC_CSR_MIDELEG:  wr_mask = `RV32GC_MIDELEG_IMPL_MSK;
                `RV32GC_CSR_MIDELEGH: wr_mask = 32'h0000_0000;
                // ---- mie：MSIE/MTIE/MEIE + SSIE/STIE/SEIE ----
                `RV32GC_CSR_MIE: wr_mask =
                    (32'h1 << `RV32GC_MIP_SSIP_BIT) | (32'h1 << `RV32GC_MIP_MSIP_BIT) |
                    (32'h1 << `RV32GC_MIP_STIP_BIT) | (32'h1 << `RV32GC_MIP_MTIP_BIT) |
                    (32'h1 << `RV32GC_MIP_SEIP_BIT) | (32'h1 << `RV32GC_MIP_MEIP_BIT);
                // ---- mtvec/stvec：BASE(4 B 对齐) + MODE(0/1) ----
                `RV32GC_CSR_MTVEC,
                `RV32GC_CSR_STVEC: wr_mask = 32'hFFFF_FFFC;   // bit[1:0]=MODE 见写逻辑
                `RV32GC_CSR_MCOUNTEREN,
                `RV32GC_CSR_SCOUNTEREN: wr_mask = 32'h0000_0007;  // CY/TM/IR
                // ---- menvcfg/senvcfg：FIOM(0)/CBIE(5:4)/CBCFE(6)/CBZE(7) ----
                `RV32GC_CSR_MENVCFG,
                `RV32GC_CSR_SENVCFG: wr_mask = 32'h0000_00F1;
                `RV32GC_CSR_MENVCFGH: wr_mask = 32'h0000_0000;   // RV32 高半，读 0
                `RV32GC_CSR_MSTATUSH: wr_mask = 32'h0000_0000;   // 无 MBE/SBE
                // ---- 陷阱设置（全 32 bit 可写） ----
                `RV32GC_CSR_MSCRATCH: wr_mask = 32'hFFFF_FFFF;
                `RV32GC_CSR_MEPC:     wr_mask = 32'hFFFF_FFFE;   // bit0 恒 0（IALIGN=16）
                `RV32GC_CSR_MCAUSE:   wr_mask = 32'hFFFF_FFFF;   // bit31=中断标志
                `RV32GC_CSR_MTVAL:    wr_mask = 32'hFFFF_FFFF;
                // ---- mip：仅软件可写位（SEIP/STIP/SSIP）；M 级 pending 由核内设备驱动 ----
                `RV32GC_CSR_MIP: wr_mask =
                    (32'h1 << `RV32GC_MIP_SSIP_BIT) |   // SSIP：核内软件可写
                    (32'h1 << `RV32GC_MIP_STIP_BIT) |   // STIP：无 stimecmp ⇒ 可写（ISA 条文）
                    (32'h1 << `RV32GC_MIP_SEIP_BIT);    // SEIP：软件可写；MEIP/MTIP/MSIP 只读
                // ---- PMP ----
                `RV32GC_CSR_PMPCFG0, `RV32GC_CSR_PMPCFG1,
                `RV32GC_CSR_PMPCFG2, `RV32GC_CSR_PMPCFG3: wr_mask = 32'hFFFF_FFFF;
                `RV32GC_CSR_PMPADDR0, `RV32GC_CSR_PMPADDR1,
                `RV32GC_CSR_PMPADDR2, `RV32GC_CSR_PMPADDR3,
                `RV32GC_CSR_PMPADDR4, `RV32GC_CSR_PMPADDR5,
                `RV32GC_CSR_PMPADDR6, `RV32GC_CSR_PMPADDR7,
                `RV32GC_CSR_PMPADDR8, `RV32GC_CSR_PMPADDR9,
                `RV32GC_CSR_PMPADDR10,`RV32GC_CSR_PMPADDR11,
                `RV32GC_CSR_PMPADDR12,`RV32GC_CSR_PMPADDR13,
                `RV32GC_CSR_PMPADDR14,`RV32GC_CSR_PMPADDR15: wr_mask = 32'hFFFF_FFFF;
                // ---- 计数器 ----
                `RV32GC_CSR_MCYCLE, `RV32GC_CSR_MCYCLEH,
                `RV32GC_CSR_MINSTRET, `RV32GC_CSR_MINSTRETH: wr_mask = 32'hFFFF_FFFF;
                // ---- mcountinhibit：WARL，吞写读 0（本设计不实现计数抑制逻辑） ----
                //   ★ 必须"接受写入且不抛异常"（08 §8.2.1(b)）
                `RV32GC_CSR_MCOUNTINHIBIT: wr_mask = 32'h0000_0000;
                // ---- mhpmevent3..31：WARL 吞写读 0（同上） ----
                `RV32GC_CSR_MHPMEVENT3,
                12'h324, 12'h325, 12'h326, 12'h327, 12'h328, 12'h329, 12'h32A, 12'h32B,
                12'h32C, 12'h32D, 12'h32E, 12'h32F, 12'h330, 12'h331, 12'h332, 12'h333,
                12'h334, 12'h335, 12'h336, 12'h337, 12'h338, 12'h339, 12'h33A, 12'h33B,
                12'h33C, 12'h33D, 12'h33E,
                `RV32GC_CSR_MHPMEVENT31:  wr_mask = 32'h0000_0000;
                // ---- FP ----
                `RV32GC_CSR_FFLAGS: wr_mask = 32'h0000_001F;
                `RV32GC_CSR_FRM:    wr_mask = 32'h0000_0007;
                `RV32GC_CSR_FCSR:   wr_mask = 32'h0000_00FF;
                // ---- S 模式 ----
                //   sstatus 是 mstatus 的 S 视图：SIE/SPIE/SPP/SUM/MXR（+FS 由 mstatus 持有）
                `RV32GC_CSR_SSTATUS: wr_mask =
                    (32'h1 << `RV32GC_MSTATUS_SIE_BIT)  |
                    (32'h1 << `RV32GC_MSTATUS_SPIE_BIT) |
                    (32'h1 << `RV32GC_MSTATUS_SPP_BIT)  |
                    (`RV32GC_MSTATUS_FS_MSK << `RV32GC_MSTATUS_FS_LSB) |
                    (32'h1 << `RV32GC_MSTATUS_SUM_BIT)  |
                    (32'h1 << `RV32GC_MSTATUS_MXR_BIT);
                `RV32GC_CSR_SIE: wr_mask =
                    (32'h1 << `RV32GC_MIP_SSIP_BIT) |
                    (32'h1 << `RV32GC_MIP_STIP_BIT) |
                    (32'h1 << `RV32GC_MIP_SEIP_BIT);
                `RV32GC_CSR_SIP: wr_mask = (32'h1 << `RV32GC_MIP_SSIP_BIT);  // 仅 SSIP 可写
                `RV32GC_CSR_SSCRATCH: wr_mask = 32'hFFFF_FFFF;
                `RV32GC_CSR_SEPC:     wr_mask = 32'hFFFF_FFFE;
                `RV32GC_CSR_SCAUSE:   wr_mask = 32'hFFFF_FFFF;
                `RV32GC_CSR_STVAL:    wr_mask = 32'hFFFF_FFFF;
                //   satp：MODE 仅 0/1 合法（见写逻辑）；ASID[30:22]+PPN[21:0] 全可写
                `RV32GC_CSR_SATP:     wr_mask = 32'hFFFF_FFFF;
                // ---- 只读视图（写被忽略，但**不**抛异常：它们是"已实现"的） ----
                //   注意：C00-C82/F11-F14 由地址高 2 位编码为只读 ⇒ 写它们必抛非法
                //   （csr[11:10]==2'b11），这条判定在 chk_ro_write 里统一处理，
                //   因此这里的 wr_mask 仅作占位。
                `RV32GC_CSR_CYCLE, `RV32GC_CSR_TIME, `RV32GC_CSR_INSTRET,
                `RV32GC_CSR_CYCLEH, `RV32GC_CSR_TIMEH, `RV32GC_CSR_INSTRETH,
                `RV32GC_CSR_MVENDORID, `RV32GC_CSR_MARCHID,
                `RV32GC_CSR_MIMPID, `RV32GC_CSR_MHARTID: wr_mask = 32'h0000_0000;
                default: wr_mask = 32'h0000_0000;   // 吞写（含 mhpmevent 之外的未列举项）
            endcase
        end
    endfunction

    //==========================================================================
    // 3. 建筑状态寄存器（只对确实需要"存储"的字段落地）
    //    组合只读视图（mstatus/mip 等）在 §5 的 assign 里合成，不占存储。
    //==========================================================================
    reg [31:0] mscratch_r, mepc_r, mcause_r, mtval_r;
    reg [31:0] mtvec_r, stvec_r;
    reg [31:0] medeleg_r, mideleg_r;
    reg [31:0] mie_r;
    reg [31:0] mcounteren_r, scounteren_r;
    reg [31:0] menvcfg_r, senvcfg_r;
    reg [31:0] satp_r;
    reg [31:0] sscratch_r, sepc_r, scause_r, stval_r;
    reg [31:0] mcycle_r, minstret_r;   // RV32 低半（高半见 §5 派生）
    reg [31:0] mstat_sw;               // mstatus 的**软件可写**字段存储
    reg [1:0]  mip_sw;                 // {SEIP, STIP, SSIP} 的软件可写位 {9,5,1}
    reg [`RV32GC_PMP_ENTRIES*8-1:0]      pmp_cfg_r;
    reg [`RV32GC_PMP_ENTRIES*32-1:0]     pmp_addr_r;

    // ---- mstatus 的只读汇总位（SD）与只读 0 字段由视图逻辑合成 ----
    //      mstat_sw 中只保存可写位，读回时 | 上常量位。

    //==========================================================================
    // 4. 写通道（唯一的时序写点；组合部分用 wire，不用 always @(*) 大块）
    //==========================================================================
    // ---- 4.1 访问权限判定（组合） ----
    wire        impl_hit     = is_impl(chk_addr);
    wire        addr_ro      = csr_is_ro(chk_addr);
    wire [1:0]  need_priv    = csr_min_priv(chk_addr);
    wire        priv_ok      = priv_ge(priv, need_priv);
    // 未实现地址 ⇒ 非法；特权级不足 ⇒ 非法（08 §6.2「访问权限」）
    assign chk_illegal  = ~impl_hit | ~priv_ok;
    // 写只读 CSR ⇒ 非法（08 §6.2；06 §9）
    assign chk_ro_write = addr_ro;

    // ---- 4.2 落地写值（WARL） ----
    wire [31:0] wmask   = wr_mask(waddr);
    wire [31:0] wval    = wdata & wmask;

    // ---- satp.MODE WARL：写入保留值(2'b1x 以外的非法编码)时保持旧值 ----
    //      RV32 satp 只有 1 bit MODE，值域 {0,1} 全合法 ⇒ 无保留编码。
    //      06 §9 的"sapt.MODE 写保留值"针对 RV64/Sv39 等多 bit MODE；
    //      RV32 此处保留该判定为**显式占位**，便于将来扩展时一处修改。
    wire       satp_mode_ok   = 1'b1;
    wire [31:0] satp_wval     = satp_mode_ok ? wval : satp_r;

    // ---- mtvec/stvec MODE WARL：MODE ∈ {0(Direct), 1(Vectored)}；2/3 保留 ⇒ 保持旧 MODE ----
    wire [1:0] mtvec_mode_old = mtvec_r[1:0];
    wire [1:0] mtvec_mode_new = (wval[1:0] <= 2'b01) ? wval[1:0] : mtvec_mode_old;
    wire [31:0] mtvec_wval    = {wval[31:2], mtvec_mode_new};
    wire [1:0] stvec_mode_old = stvec_r[1:0];
    wire [1:0] stvec_mode_new = (wval[1:0] <= 2'b01) ? wval[1:0] : stvec_mode_old;
    wire [31:0] stvec_wval    = {wval[31:2], stvec_mode_new};

    // ---- menvcfg/senvcfg CBIE WARL：2'b10 保留 ⇒ 保持旧值（06 §7.1/§9） ----
    wire [1:0] mcf_cbie_old = menvcfg_r[5:4];
    wire [1:0] mcf_cbie_new = (wval[5:4] == 2'b10) ? mcf_cbie_old : wval[5:4];
    wire [31:0] menvcfg_wval = {wval[31:8], wval[7:6], mcf_cbie_new, wval[3:0]};
    wire [1:0] scf_cbie_old = senvcfg_r[5:4];
    wire [1:0] scf_cbie_new = (wval[5:4] == 2'b10) ? scf_cbie_old : wval[5:4];
    wire [31:0] senvcfg_wval = {wval[31:8], wval[7:6], scf_cbie_new, wval[3:0]};

    // ---- mstatus / sstatus / sie / sip 的共享存储映射 ----
    //      sstatus 是 mstatus 的视图（SIE/SPIE/SPP/SUM/MXR/FS 同一存储）；
    //      sie 是 mie 的视图（SSIE/STIE/SEIE 同一存储）；
    //      sip 是 mip 的视图（SSIP/STIP/SEIP 软件位同一存储）。
    wire [31:0] sstatus_wval = wval;
    wire [31:0] sie_wval     = wval & ((32'h1<<`RV32GC_MIP_SSIP_BIT) |
                                       (32'h1<<`RV32GC_MIP_STIP_BIT) |
                                       (32'h1<<`RV32GC_MIP_SEIP_BIT));
    wire [31:0] sip_wval     = wval;

    // ---- 写选择（组合译码；wen 有效才落地） ----
    //      ★ 采用「每组一个使能 + 一个数据」的形式，避免 always @(*) 多 reg 赋值。
    wire wr_mstatus = wen & (waddr == `RV32GC_CSR_MSTATUS);
    wire wr_sstatus = wen & (waddr == `RV32GC_CSR_SSTATUS);
    wire wr_mie     = wen & (waddr == `RV32GC_CSR_MIE);
    wire wr_sie     = wen & (waddr == `RV32GC_CSR_SIE);
    wire wr_mip     = wen & (waddr == `RV32GC_CSR_MIP);
    wire wr_sip     = wen & (waddr == `RV32GC_CSR_SIP);
    wire wr_scratch = wen & (waddr == `RV32GC_CSR_MSCRATCH);
    wire wr_mepc    = wen & (waddr == `RV32GC_CSR_MEPC);
    wire wr_mcause  = wen & (waddr == `RV32GC_CSR_MCAUSE);
    wire wr_mtval   = wen & (waddr == `RV32GC_CSR_MTVAL);
    wire wr_mtvec   = wen & (waddr == `RV32GC_CSR_MTVEC);
    wire wr_stvec   = wen & (waddr == `RV32GC_CSR_STVEC);
    wire wr_medeleg = wen & (waddr == `RV32GC_CSR_MEDELEG);
    wire wr_mideleg = wen & (waddr == `RV32GC_CSR_MIDELEG);
    wire wr_mcnten  = wen & (waddr == `RV32GC_CSR_MCOUNTEREN);
    wire wr_scnten  = wen & (waddr == `RV32GC_CSR_SCOUNTEREN);
    wire wr_menvcfg = wen & (waddr == `RV32GC_CSR_MENVCFG);
    wire wr_senvcfg = wen & (waddr == `RV32GC_CSR_SENVCFG);
    wire wr_satp    = wen & (waddr == `RV32GC_CSR_SATP);
    wire wr_sscratch= wen & (waddr == `RV32GC_CSR_SSCRATCH);
    wire wr_sepc    = wen & (waddr == `RV32GC_CSR_SEPC);
    wire wr_scause  = wen & (waddr == `RV32GC_CSR_SCAUSE);
    wire wr_stval   = wen & (waddr == `RV32GC_CSR_STVAL);
    wire wr_mcycle  = wen & (waddr == `RV32GC_CSR_MCYCLE);
    wire wr_minstret= wen & (waddr == `RV32GC_CSR_MINSTRET);
    // ---- PMP：16 项地址寄存器 + 4 个 cfg ----
    wire [3:0] wr_pmpcfg =
        { (wen & (waddr == `RV32GC_CSR_PMPCFG3)),
          (wen & (waddr == `RV32GC_CSR_PMPCFG2)),
          (wen & (waddr == `RV32GC_CSR_PMPCFG1)),
          (wen & (waddr == `RV32GC_CSR_PMPCFG0)) };
    wire [15:0] wr_pmpaddr;
    genvar gi;
    generate
        for (gi = 0; gi < 16; gi = gi + 1) begin : g_pmpaddr_we
            assign wr_pmpaddr[gi] = wen & (waddr == (12'h3B0 + gi[11:0]));
        end
    endgenerate

    // ---- PMP L 位锁定：L=1 的项其 cfg 写入被忽略；其 TOR 前驱地址寄存器写入被忽略 ----
    function [3:0] pmp_locked;
        input [63:0] cfg;
        begin
            pmp_locked = { cfg[7+8*3], cfg[7+8*2], cfg[7+8*1], cfg[7+8*0] };
        end
    endfunction
    wire [3:0] lock0 = pmp_locked(pmp_cfg_r[63:0]);
    wire [3:0] lock1 = pmp_locked(pmp_cfg_r[127:64]);
    wire [15:0] pmp_lock_all = {lock1, lock0};

    //==========================================================================
    // 5. 组合只读视图（全部 assign，红线 3）
    //==========================================================================
    // ---- mstatus：存储位 | 常量位；SD 由 FS!=Off 派生（只读汇总） ----
    wire [31:0] mstat_fs  = (mstat_sw >> `RV32GC_MSTATUS_FS_LSB) & `RV32GC_MSTATUS_FS_MSK;
    wire        mstat_sd  = (mstat_fs != `RV32GC_FS_OFF);
    wire [31:0] mstatus_view =
        (mstat_sw & wr_mask(`RV32GC_CSR_MSTATUS)) |
        (mstat_sd << `RV32GC_MSTATUS_SD_BIT);
    assign mstatus_o = mstatus_view & ~(mstatus_clr) | (mstatus_set);

    // ---- sstatus 视图：从 mstatus 取 S 相关位 ----
    wire [31:0] sstatus_view =
        ((mstatus_view >> `RV32GC_MSTATUS_SIE_BIT)  & 32'h1) << 1 |
        ((mstatus_view >> `RV32GC_MSTATUS_SPIE_BIT) & 32'h1) << `RV32GC_MSTATUS_SPIE_BIT |
        ((mstatus_view >> `RV32GC_MSTATUS_SPP_BIT)  & 32'h1) << `RV32GC_MSTATUS_SPP_BIT |
        ((mstatus_view >> `RV32GC_MSTATUS_FS_LSB) & `RV32GC_MSTATUS_FS_MSK) << `RV32GC_MSTATUS_FS_LSB |
        ((mstatus_view >> `RV32GC_MSTATUS_SUM_BIT) & 32'h1) << `RV32GC_MSTATUS_SUM_BIT |
        ((mstatus_view >> `RV32GC_MSTATUS_MXR_BIT) & 32'h1) << `RV32GC_MSTATUS_MXR_BIT |
        ((mstatus_view >> `RV32GC_MSTATUS_SD_BIT)  & 32'h1) << `RV32GC_MSTATUS_SD_BIT;

    // ---- mie 视图：M 专属 + S 视图中已实现的位 ----
    assign mie_o = mie_r & ((32'h1<<`RV32GC_MIP_SSIP_BIT) | (32'h1<<`RV32GC_MIP_MSIP_BIT) |
                            (32'h1<<`RV32GC_MIP_STIP_BIT) | (32'h1<<`RV32GC_MIP_MTIP_BIT) |
                            (32'h1<<`RV32GC_MIP_SEIP_BIT) | (32'h1<<`RV32GC_MIP_MEIP_BIT));
    wire [31:0] sie_view = mie_o & ((32'h1<<`RV32GC_MIP_SSIP_BIT) |
                                    (32'h1<<`RV32GC_MIP_STIP_BIT) |
                                    (32'h1<<`RV32GC_MIP_SEIP_BIT));

    // ---- mip 视图：软件位（SSIP/STIP/SEIP）+ 核内设备驱动位 ----
    //      MEIP/MTIP/MSIP 只读，由 CLINT/PLIC 驱动（08 §6.6）
    wire [31:0] mip_dev =
        (irq_msip << `RV32GC_MIP_MSIP_BIT) | (irq_mtip << `RV32GC_MIP_MTIP_BIT) |
        (irq_meip << `RV32GC_MIP_MEIP_BIT) | (irq_stip << `RV32GC_MIP_STIP_BIT) |
        (irq_seip << `RV32GC_MIP_SEIP_BIT);
    wire [31:0] mip_sw_all =
        (mip_sw[0] << `RV32GC_MIP_SSIP_BIT) |
        (mip_sw[1] << `RV32GC_MIP_STIP_BIT) |
        (mip_sw[2] << `RV32GC_MIP_SEIP_BIT);
    assign mip_o   = mip_sw_all | mip_dev;
    wire [31:0] sip_view = mip_o & ((32'h1<<`RV32GC_MIP_SSIP_BIT) |
                                    (32'h1<<`RV32GC_MIP_STIP_BIT) |
                                    (32'h1<<`RV32GC_MIP_SEIP_BIT));

    // ---- misa：RV32IMAFDC + Zicsr/Zifencei/Zicntr/Zicbom 的 A 扩展位 ----
    //      [ISA:misa 扩展位 = A(0)B(1)C(2)D(3)E(4)F(5)G(6)H(7)I(8)J(9)K(10)L(11)
    //            M(12)N(13)O(14)P(15)Q(16)R(17)S(18)T(19)U(20)V(21)W(22)X(23)Y(24)Z(25)]
    //      MXL=1 ⇒ MXLEN=32（[31:30]=2'b01）
    //      C 扩展 ⇒ bit2；F ⇒ bit5；D ⇒ bit3；M ⇒ bit12；A ⇒ bit0；I ⇒ bit8；S ⇒ bit18；U ⇒ bit20
    localparam [31:0] MISA_EXT_BITS = (32'h1 << 0)  |   // A
                                      (32'h1 << 2)  |   // C
                                      (32'h1 << 3)  |   // D
                                      (32'h1 << 5)  |   // F
                                      (32'h1 << 8)  |   // I
                                      (32'h1 << 12) |   // M
                                      (32'h1 << 18) |   // S
                                      (32'h1 << 20);    // U
    wire [31:0] misa_view = (32'h1 << 30) | MISA_EXT_BITS;   // MXL=2'b01 ⇒ bit30

    // ---- 计数器视图（Zicntr；高半由 64 位计数器派生） ----
    //      mcycle/minstret 为 64 位；RV32 低半走 CSR，高半走 *H 别名。
    //      Zicntr 的 cycle/time/instret 是"只读视图"，mcounteren/scounteren 门控在
    //      访问权限判定里由 dec_csr 处理（本模块只给值）。
    wire [63:0] mcycle_v   = {mcycle_r, cycle_i[31:0]};    // 软件可写高半 + 硬件低半
    wire [63:0] minstret_v = {minstret_r, instret_i[31:0]};

    // ---- satp 视图 ----
    assign satp_o = satp_r;

    // ---- PMP 视图 ----
    assign pmp_cfg_o  = pmp_cfg_r;
    assign pmp_addr_o = pmp_addr_r;

    // ---- 配置字段视图 ----
    assign mtvec_o     = mtvec_r;
    assign stvec_o     = stvec_r;
    assign medeleg_o   = medeleg_r;
    assign mideleg_o   = mideleg_r;
    assign menvcfg_o   = menvcfg_r;
    assign senvcfg_o   = senvcfg_r;
    assign mcounteren_o= mcounteren_r;
    assign scounteren_o= scounteren_r;

    //==========================================================================
    // 6. 读数据（组合两级译码；写端口旁路）
    //==========================================================================
    function [31:0] csr_rdata;
        input [11:0] a;
        begin
            case (a)
                `RV32GC_CSR_MSTATUS:    csr_rdata = mstatus_view;
                `RV32GC_CSR_SSTATUS:    csr_rdata = sstatus_view;
                `RV32GC_CSR_MISA:       csr_rdata = misa_view;
                `RV32GC_CSR_MEDELEG:    csr_rdata = medeleg_r & `RV32GC_MEDELEG_IMPL_MSK;
                `RV32GC_CSR_MEDELEGH:   csr_rdata = 32'h0;      // RV32 高半保留读 0
                `RV32GC_CSR_MIDELEG:    csr_rdata = mideleg_r & `RV32GC_MIDELEG_IMPL_MSK;
                `RV32GC_CSR_MIDELEGH:   csr_rdata = 32'h0;
                `RV32GC_CSR_MIE:        csr_rdata = mie_o;
                `RV32GC_CSR_SIE:        csr_rdata = sie_view;
                `RV32GC_CSR_MTVEC:      csr_rdata = mtvec_r;
                `RV32GC_CSR_STVEC:      csr_rdata = stvec_r;
                `RV32GC_CSR_MCOUNTEREN: csr_rdata = mcounteren_r;
                `RV32GC_CSR_SCOUNTEREN: csr_rdata = scounteren_r;
                `RV32GC_CSR_MSTATUSH:   csr_rdata = 32'h0;      // 无 MBE/SBE
                `RV32GC_CSR_MENVCFG:    csr_rdata = menvcfg_r;
                `RV32GC_CSR_MENVCFGH:   csr_rdata = 32'h0;
                `RV32GC_CSR_SENVCFG:    csr_rdata = senvcfg_r;
                `RV32GC_CSR_MSCRATCH:   csr_rdata = mscratch_r;
                `RV32GC_CSR_MEPC:       csr_rdata = {mepc_r[31:1], 1'b0};
                `RV32GC_CSR_MCAUSE:     csr_rdata = mcause_r;
                `RV32GC_CSR_MTVAL:      csr_rdata = mtval_r;
                `RV32GC_CSR_MIP:        csr_rdata = mip_o;
                `RV32GC_CSR_SIP:        csr_rdata = sip_view;
                // ---- PMP cfg：4 项打包 ----
                `RV32GC_CSR_PMPCFG0:    csr_rdata = pmp_cfg_r[31:0];
                `RV32GC_CSR_PMPCFG1:    csr_rdata = pmp_cfg_r[63:32];
                `RV32GC_CSR_PMPCFG2:    csr_rdata = pmp_cfg_r[95:64];
                `RV32GC_CSR_PMPCFG3:    csr_rdata = pmp_cfg_r[127:96];
                `RV32GC_CSR_MCYCLE:     csr_rdata = mcycle_v[31:0];
                `RV32GC_CSR_MCYCLEH:    csr_rdata = mcycle_v[63:32];
                `RV32GC_CSR_MINSTRET:   csr_rdata = minstret_v[31:0];
                `RV32GC_CSR_MINSTRETH:  csr_rdata = minstret_v[63:32];
                `RV32GC_CSR_CYCLE:      csr_rdata = cycle_i[31:0];
                `RV32GC_CSR_CYCLEH:     csr_rdata = cycle_i[63:32];
                `RV32GC_CSR_TIME:       csr_rdata = cycle_i[31:0];   // time 接 mtime（CLINT 提供）
                `RV32GC_CSR_TIMEH:      csr_rdata = cycle_i[63:32];
                `RV32GC_CSR_INSTRET:    csr_rdata = instret_i[31:0];
                `RV32GC_CSR_INSTRETH:   csr_rdata = instret_i[63:32];
                `RV32GC_CSR_FFLAGS:     csr_rdata = 32'h0;   // FP 状态由 fpu/fcsr 落地（本模块不持有）
                `RV32GC_CSR_FRM:        csr_rdata = 32'h0;
                `RV32GC_CSR_FCSR:       csr_rdata = 32'h0;
                // ---- S 模式陷阱处理 ----
                `RV32GC_CSR_SSCRATCH:   csr_rdata = sscratch_r;
                `RV32GC_CSR_SEPC:       csr_rdata = {sepc_r[31:1], 1'b0};
                `RV32GC_CSR_SCAUSE:     csr_rdata = scause_r;
                `RV32GC_CSR_STVAL:      csr_rdata = stval_r;
                `RV32GC_CSR_SATP:       csr_rdata = satp_r;
                // ---- M 模式信息寄存器（MRO） ----
                `RV32GC_CSR_MVENDORID:  csr_rdata = 32'h0;    // 非商业实现，按规范可读 0
                `RV32GC_CSR_MARCHID:    csr_rdata = 32'h0;
                `RV32GC_CSR_MIMPID:     csr_rdata = 32'h0;
                `RV32GC_CSR_MHARTID:    csr_rdata = 32'h0;    // 单 hart，硬连 0（08 §6.2）
                // ---- ★ mcountinhibit / mhpmevent：已实现、吞写、读 0 ----
                `RV32GC_CSR_MCOUNTINHIBIT: csr_rdata = 32'h0;
                `RV32GC_CSR_MHPMEVENT3,
                12'h324, 12'h325, 12'h326, 12'h327, 12'h328, 12'h329, 12'h32A, 12'h32B,
                12'h32C, 12'h32D, 12'h32E, 12'h32F, 12'h330, 12'h331, 12'h332, 12'h333,
                12'h334, 12'h335, 12'h336, 12'h337, 12'h338, 12'h339, 12'h33A, 12'h33B,
                12'h33C, 12'h33D, 12'h33E,
                `RV32GC_CSR_MHARTID_PLACEHOLDER_UNUSED,
                `RV32GC_CSR_MHPMEVENT31:   csr_rdata = 32'h0;
                default:                csr_rdata = 32'h0;
            endcase
        end
    endfunction

    // ---- pmpaddr 读：单独展开（16 项，避免 case 里写 16 行长表达式） ----
    function [31:0] pmpaddr_rdata;
        input [3:0] idx;
        begin
            pmpaddr_rdata = pmp_addr_r[idx*32 +: 32];
        end
    endfunction

    wire [31:0] rdata_comb = csr_rdata(raddr);
    wire        rd_is_pmpaddr = (raddr >= 12'h3B0) && (raddr <= 12'h3BF);
    assign rdata = rd_is_pmpaddr ? pmpaddr_rdata(raddr[3:0]) : rdata_comb;

    wire [31:0] rdataw_comb = csr_rdata(waddr);
    wire        wr_is_pmpaddr = (waddr >= 12'h3B0) && (waddr <= 12'h3BF);
    assign rdata_w = wr_is_pmpaddr ? pmpaddr_rdata(waddr[3:0]) : rdataw_comb;

    //==========================================================================
    // 7. 时序：唯一的存储写点
    //    理由：CSR 是架构寄存器组，必须时钟沿保持 ⇒ always 块不可省略（AGENT.md §4.3）。
    //    写优先级：trap_we（陷阱入口）> wen（软件 CSR 写）。
    //==========================================================================
    // ---- 软件写使能（WARL 过滤后的实际写入条件） ----
    //      CSRRS/CSRRC 的"无写"情形由上层置 w_illegal=1 ⇒ 此处不再单独判 rs1=0。
    wire sw_en = wen & ~w_illegal;

    // ---- 陷阱写译码（trap_addr 指定目标 CSR） ----
    wire tw_mepc   = trap_we[0] & (trap_addr == `RV32GC_CSR_MEPC);
    wire tw_mcause = trap_we[0] & (trap_addr == `RV32GC_CSR_MCAUSE);
    wire tw_mtval  = trap_we[0] & (trap_addr == `RV32GC_CSR_MTVAL);
    wire tw_sepc   = trap_we[1] & (trap_addr == `RV32GC_CSR_SEPC);
    wire tw_scause = trap_we[1] & (trap_addr == `RV32GC_CSR_SCAUSE);
    wire tw_stval  = trap_we[1] & (trap_addr == `RV32GC_CSR_STVAL);
    wire tw_sscr   = trap_we[2] & (trap_addr == `RV32GC_CSR_SSCRATCH);
    wire tw_mscr   = trap_we[3] & (trap_addr == `RV32GC_CSR_MSCRATCH);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // ---- 复位值（08 §6.5 复位默认：menvcfg/senvcfg 门控全 0） ----
            mscratch_r   <= 32'h0;
            mepc_r       <= 32'h0;
            mcause_r     <= 32'h0;
            mtval_r      <= 32'h0;
            mtvec_r      <= 32'h0;              // Direct, BASE=0
            stvec_r      <= 32'h0;
            medeleg_r    <= 32'h0;
            mideleg_r    <= 32'h0;
            mie_r        <= 32'h0;
            mcounteren_r <= 32'h0;
            scounteren_r <= 32'h0;
            menvcfg_r    <= 32'h0;              // CBIE=00/CBCFE=0/CBZE=0
            senvcfg_r    <= 32'h0;
            satp_r       <= 32'h0;              // Bare
            sscratch_r   <= 32'h0;
            sepc_r       <= 32'h0;
            scause_r     <= 32'h0;
            stval_r      <= 32'h0;
            mcycle_r     <= 32'h0;
            minstret_r   <= 32'h0;
            mstat_sw     <= 32'h0;
            mip_sw       <= 2'b00;
            pmp_cfg_r    <= {`RV32GC_PMP_ENTRIES*8{1'b0}};
            pmp_addr_r   <= {`RV32GC_PMP_ENTRIES*32{1'b0}};
        end else begin
            // ---- 7.1 mstatus（含 sstatus 视图写入 + trap_ctrl 的置/清） ----
            //   trap_ctrl 的 mstatus_set/mstatus_clr 优先级最高（同拍）
            if (mstatus_clr != 32'h0 || mstatus_set != 32'h0) begin
                mstat_sw <= (mstat_sw & ~mstatus_clr) | mstatus_set;
            end else if (sw_en && (waddr == `RV32GC_CSR_MSTATUS)) begin
                mstat_sw <= wval;
            end else if (sw_en && (waddr == `RV32GC_CSR_SSTATUS)) begin
                mstat_sw <= (mstat_sw & ~wr_mask(`RV32GC_CSR_SSTATUS)) |
                            (sstatus_wval & wr_mask(`RV32GC_CSR_SSTATUS));
            end

            // ---- 7.2 mie / sie ----
            if (sw_en && (waddr == `RV32GC_CSR_MIE)) begin
                mie_r <= wval;
            end else if (sw_en && (waddr == `RV32GC_CSR_SIE)) begin
                mie_r <= (mie_r & ~(`RV32GC_MIDELEG_IMPL_MSK)) |
                         (sie_wval & `RV32GC_MIDELEG_IMPL_MSK);
            end

            // ---- 7.3 mip 的软件可写位 {SEIP,STIP,SSIP} ----
            if (sw_en && (waddr == `RV32GC_CSR_MIP)) begin
                mip_sw <= { wval[`RV32GC_MIP_SEIP_BIT], wval[`RV32GC_MIP_STIP_BIT],
                            wval[`RV32GC_MIP_SSIP_BIT] };
            end else if (sw_en && (waddr == `RV32GC_CSR_SIP)) begin
                mip_sw <= { mip_sw[2], mip_sw[1], wval[`RV32GC_MIP_SSIP_BIT] };
            end

            // ---- 7.4 M 模式陷阱设置 ----
            if (tw_mscr)   mscratch_r <= trap_wdata;
            else if (wr_scratch & sw_en) mscratch_r <= wval;

            if (tw_mepc)   mepc_r <= {trap_wdata[31:1], 1'b0};
            else if (wr_mepc & sw_en) mepc_r <= {wval[31:1], 1'b0};

            if (tw_mcause) mcause_r <= trap_wdata;
            else if (wr_mcause & sw_en) mcause_r <= wval;

            if (tw_mtval)  mtval_r <= trap_wdata;
            else if (wr_mtval & sw_en) mtval_r <= wval;

            if (wr_mtvec & sw_en) mtvec_r <= mtvec_wval;
            if (wr_stvec & sw_en) stvec_r <= stvec_wval;

            if (wr_medeleg & sw_en) medeleg_r <= wval;   // wr_mask 已限制为实现位
            if (wr_mideleg & sw_en) mideleg_r <= wval;

            if (wr_mcnten & sw_en) mcounteren_r <= wval;
            if (wr_scnten & sw_en) scounteren_r <= wval;
            if (wr_menvcfg & sw_en) menvcfg_r <= menvcfg_wval;
            if (wr_senvcfg & sw_en) senvcfg_r <= senvcfg_wval;
            if (wr_satp & sw_en)    satp_r <= satp_wval;

            // ---- 7.5 S 模式陷阱设置 ----
            if (tw_sscr)   sscratch_r <= trap_wdata;
            else if (wr_sscratch & sw_en) sscratch_r <= wval;

            if (tw_sepc)   sepc_r <= {trap_wdata[31:1], 1'b0};
            else if (wr_sepc & sw_en) sepc_r <= {wval[31:1], 1'b0};

            if (tw_scause) scause_r <= trap_wdata;
            else if (wr_scause & sw_en) scause_r <= wval;

            if (tw_stval)  stval_r <= trap_wdata;
            else if (wr_stval & sw_en) stval_r <= wval;

            // ---- 7.6 计数器高半（软件可写；低半由硬件计数器驱动） ----
            if (wr_mcycle & sw_en)   mcycle_r   <= wval;
            if (wr_minstret & sw_en) minstret_r <= wval;

            // ---- 7.7 PMP cfg（逐项 L 位锁定） ----
            if (wr_pmpcfg[0] & sw_en) begin
                pmp_cfg_r[7:0]   <= lock0[0] ? pmp_cfg_r[7:0]   : wval[7:0];
                pmp_cfg_r[15:8]  <= lock0[1] ? pmp_cfg_r[15:8]  : wval[15:8];
                pmp_cfg_r[23:16] <= lock0[2] ? pmp_cfg_r[23:16] : wval[23:16];
                pmp_cfg_r[31:24] <= lock0[3] ? pmp_cfg_r[31:24] : wval[31:24];
            end
            if (wr_pmpcfg[1] & sw_en) begin
                pmp_cfg_r[39:32] <= lock1[0] ? pmp_cfg_r[39:32] : wval[7:0];
                pmp_cfg_r[47:40] <= lock1[1] ? pmp_cfg_r[47:40] : wval[15:8];
                pmp_cfg_r[55:48] <= lock1[2] ? pmp_cfg_r[55:48] : wval[23:16];
                pmp_cfg_r[63:56] <= lock1[3] ? pmp_cfg_r[63:56] : wval[31:24];
            end
            if (wr_pmpcfg[2] & sw_en) begin
                pmp_cfg_r[71:64]  <= wval[7:0];
                pmp_cfg_r[79:72]  <= wval[15:8];
                pmp_cfg_r[87:80]  <= wval[23:16];
                pmp_cfg_r[95:88]  <= wval[31:24];
            end
            if (wr_pmpcfg[3] & sw_en) begin
                pmp_cfg_r[103:96]  <= wval[7:0];
                pmp_cfg_r[111:104] <= wval[15:8];
                pmp_cfg_r[119:112] <= wval[23:16];
                pmp_cfg_r[127:120] <= wval[31:24];
            end

            // ---- 7.8 PMP addr（含 TOR 前驱锁定） ----
            //   ISA norm:pmplbitwriteprotection：若项 i 被 L 锁定且 A=TOR，
            //   则对 pmpaddr[i-1] 的写被忽略。
            for (gi = 0; gi < 16; gi = gi + 1) begin : g_pmp_addr_wr
                if (wr_pmpaddr[gi] & sw_en) begin
                    // 项 (gi+1) 锁定且为 TOR ⇒ 本项不可写
                    if (gi < 15) begin
                        if (!(pmp_lock_all[gi+1] && (pmp_cfg_r[(gi+1)*8+3 +: 2] == `RV32GC_PMP_A_TOR)))
                            pmp_addr_r[gi*32 +: 32] <= wval;
                    end else begin
                        pmp_addr_r[gi*32 +: 32] <= wval;
                    end
                end
            end
        end
    end

endmodule
