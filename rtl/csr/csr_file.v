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
//     ★ RV32 的 satp.MODE 只有 1 bit、{0,1} 全合法 ⇒ 本设计无保留编码；该判定以
//       "显式占位"形式落在 §2.5 的 csr_landing()（见其注释）。
//  7. **写→紧邻读的旁路值一律取 post-WARL 落盘值**（不是原始写数据）：由 §2.5 的
//     唯一引擎 csr_landing() 统一给出，三个调用点共用（写通道落地 / 写口旁路读
//     rdata_w / M 级旁路预览 byp_rdata）。旧实现让 core_top 直接拿未掩码写数据 ⇒
//     mtvec.MODE 保留值、mepc/sepc bit0、medeleg/mideleg 实现位、PMP L 锁定、
//     misa/mcountinhibit/mhpmevent 吞写、menvcfg.CBIE 会读到"假新值"。
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
    output wire [31:0] rdata_w,     // 写口旁路读：raddr==waddr ⇒ 该 CSR 的 post-WARL
                                    // **落盘值**；否则退回普通读视图（供同拍 CSR 读）
    //--------------------------------------------------------------------------
    // 写口旁路**预览**（更年轻的 M 级写；与上面 rdata_w 共用同一 WARL 引擎）
    //   byp_wdata = 更年轻的 CSR 写指令（当前在 M 级）的**原始**写数据；
    //   byp_rdata = 「若把 byp_wdata 写入 raddr」之后该 CSR 的**读回值**
    //               = post-WARL 落盘值（与写通道、rdata_w 同一个 csr_landing 引擎）。
    //   ★ 调用方（core_top）只在确认该写指令地址 == raddr（csr_em_hit）时使用本值；
    //     地址不等时本输出无意义（但仍为确定值，不引入 X）。
    //--------------------------------------------------------------------------
    input  wire [31:0] byp_wdata,
    output wire [31:0] byp_rdata,

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
    //   ★ **分组语义**（见 §4.2）：一次陷阱原子更新 3 个 CSR，故数据分 3 个端口，
    //     而不是"一个地址 + 一个数据"的逐 CSR 形式。
    //   trap_we[0]=M 组（mepc/mcause/mtval 同拍写）
    //   trap_we[1]=S 组（sepc/scause/stval 同拍写）
    //   trap_we[2]=sscratch 单写   trap_we[3]=mscratch 单写
    //   优先级：trap_we > wen（同拍不可能同时出现，显式定序避免歧义）
    //--------------------------------------------------------------------------
    input  wire [3:0]  trap_we,       // 分组使能（见上）
    input  wire [31:0] trap_epc_i,    // 组的 epc 值
    input  wire [31:0] trap_cause_i,  // 组的 cause 值
    input  wire [31:0] trap_tval_i,   // 组的 tval 值
    input  wire [31:0] trap_data_i,   // sscratch/mscratch 单写值（trap_we[3:2]）

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
                //   ★ 掩码必须**包含 MODE[1:0]**：MODE 的合法化在 wr_mask 之后的
                //   csr_landing() 的 mtvec/stvec 分支里完成（2/3 保留 ⇒ 保持旧 MODE）。
                //   若把低 2 位掩成 0，MODE 永远写不进（实测踩到过这个坑）。
                `RV32GC_CSR_MTVEC,
                `RV32GC_CSR_STVEC: wr_mask = 32'hFFFF_FFFF;
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
    // 2.5 WARL 落盘值引擎（**唯一真源**）
    //   语义：`csr_landing(a, d, cur, ...)` = 「把原始写数据 d 写进 CSR a 之后，
    //         该 CSR 的**读回值**」= post-WARL 落盘值。
    //   为什么必须集中一处：CSR「写 → 紧邻读」的同拍旁路值必须是**落盘值**，
    //   而不是原始写数据（旧实现 core_top 直接拿 d ⇒ mtvec.MODE 保留值、mepc/sepc
    //   bit0、medeleg/mideleg 实现位、PMP L 锁定、misa/mcountinhibit/mhpmevent 吞写、
    //   menvcfg.CBIE 全部读出"假新值"；实测 `csrw mtvec,0x8000_0002` 后紧邻读回
    //   0x8000_0002，Spike 为 0x8000_0000）。
    //   三类语义在此收口：
    //     ① 吞写（wr_mask==0，含 misa/mcountinhibit/mhpmevent/未列举项）⇒ 读回不变（= cur）；
    //     ② 字段级 WARL（mtvec/stvec MODE、menvcfg/senvcfg CBIE）⇒ 保留值取自"现值"入参；
    //     ③ PMP：cfg 逐项 L 锁定、addr 的 TOR 前驱锁定 ⇒ 锁定项保持现值。
    //   三个调用点共用本函数（消除双份漂移）：
    //     · §7 写通道落地（waddr/wdata，wval_final）
    //     · §6 写口旁路读 rdata_w（raddr==waddr ⇒ 落盘值）
    //     · §6 M 级旁路预览 byp_rdata（younger 写数据 byp_wdata）
    //   ★ 纯函数：只读入参、不读寄存器 ⇒ 可安全用于连续赋值
    //     （§6 记录的 iverilog 约束只针对"function 内部读寄存器"的写法）。
    //   ★ satp：RV32 的 satp.MODE 只有 1 bit，{0,1} 全合法（无保留编码），故本引擎
    //     无需"保持现值"入参；将来扩到 RV64/Sv39（多 bit MODE）时，在下面加 satp 分支
    //     并把 satp 现值作为入参传入即可（06 §9 的占位就落在这里）。
    //==========================================================================
    function [31:0] csr_landing;
        input [11:0] a;                 // 目标 CSR 地址
        input [31:0] d;                 // 原始写数据（未做任何掩码）
        input [31:0] cur;               // 该地址**当前读回值**（写落地前的读视图）
        input [31:0] mtvec_cur;         // 现值（mtvec 保留 MODE 用）
        input [31:0] stvec_cur;         // 现值（stvec 保留 MODE 用）
        input [31:0] menvcfg_cur;       // 现值（保留 CBIE 用）
        input [31:0] senvcfg_cur;       // 现值（保留 CBIE 用）
        input [`RV32GC_PMP_ENTRIES*8-1:0] pmp_cfg_cur;   // PMP cfg 现值（跨项 L 位判定）
        reg [31:0] m;
        reg [1:0]  mode_new;
        reg [1:0]  cbie_new;
        begin
            m = wr_mask(a);
            if (m == 32'h0000_0000) begin
                // ① 吞写 / 未实现 / 无存储 ⇒ 写入不改变读回值
                csr_landing = cur;
            end else begin
                case (a)
                    // ---- ② mtvec/stvec：BASE 4 B 对齐 + MODE∈{0,1}；2/3 保留 ⇒ 保持现值 ----
                    //   ★ 注意重组写法：`{d[31:2], 2'b00} | MODE`，不是 `{d[31:2], mode}`
                    //     （后者等价于把 d 左移 30 位，实测踩过）。
                    `RV32GC_CSR_MTVEC: begin
                        mode_new    = (d[1:0] <= 2'b01) ? d[1:0] : mtvec_cur[1:0];
                        csr_landing = {d[31:2], 2'b00} | {30'b0, mode_new};
                    end
                    `RV32GC_CSR_STVEC: begin
                        mode_new    = (d[1:0] <= 2'b01) ? d[1:0] : stvec_cur[1:0];
                        csr_landing = {d[31:2], 2'b00} | {30'b0, mode_new};
                    end
                    // ---- ② menvcfg/senvcfg：FIOM/CBCFE/CBZE 取写数据；CBIE=2'b10 保留 ⇒ 保持现值 ----
                    //   ★ 按字段掩码替换（先清 [5:4] 再置入），不做位拼接以免位宽错位。
                    `RV32GC_CSR_MENVCFG: begin
                        cbie_new    = (d[5:4] == 2'b10) ? menvcfg_cur[5:4] : d[5:4];
                        csr_landing = (d & m & ~32'h0000_0030) | ({30'b0, cbie_new} << 4);
                    end
                    `RV32GC_CSR_SENVCFG: begin
                        cbie_new    = (d[5:4] == 2'b10) ? senvcfg_cur[5:4] : d[5:4];
                        csr_landing = (d & m & ~32'h0000_0030) | ({30'b0, cbie_new} << 4);
                    end
                    // ---- ③ PMP cfg：逐项 L 位锁定（L=1 的项写入被忽略，保持现值）----
                    `RV32GC_CSR_PMPCFG0: csr_landing = pmp_cfg_landing(d, pmp_cfg_cur[31:0]);
                    `RV32GC_CSR_PMPCFG1: csr_landing = pmp_cfg_landing(d, pmp_cfg_cur[63:32]);
                    `RV32GC_CSR_PMPCFG2: csr_landing = pmp_cfg_landing(d, pmp_cfg_cur[95:64]);
                    `RV32GC_CSR_PMPCFG3: csr_landing = pmp_cfg_landing(d, pmp_cfg_cur[127:96]);
                    // ---- ③ PMP addr：项 (i+1) 被 L 锁定且 A=TOR ⇒ 本项（前驱）写入被忽略 ----
                    `RV32GC_CSR_PMPADDR0,  `RV32GC_CSR_PMPADDR1,
                    `RV32GC_CSR_PMPADDR2,  `RV32GC_CSR_PMPADDR3,
                    `RV32GC_CSR_PMPADDR4,  `RV32GC_CSR_PMPADDR5,
                    `RV32GC_CSR_PMPADDR6,  `RV32GC_CSR_PMPADDR7,
                    `RV32GC_CSR_PMPADDR8,  `RV32GC_CSR_PMPADDR9,
                    `RV32GC_CSR_PMPADDR10, `RV32GC_CSR_PMPADDR11,
                    `RV32GC_CSR_PMPADDR12, `RV32GC_CSR_PMPADDR13,
                    `RV32GC_CSR_PMPADDR14, `RV32GC_CSR_PMPADDR15:
                        csr_landing = pmp_tor_locked(a, pmp_cfg_cur) ? cur : (d & m);
                    // ---- 通用：可写位取写数据，其余位保持当前读回值 ----
                    //   （mstatus/sstatus 的 SD 等派生位即使略旧也会被 core_top 的
                    //    FS/SD 覆盖逻辑重新派生；mip/sip 的只读设备位由此保持）
                    default: csr_landing = (d & m) | (cur & ~m);
                endcase
            end
        end
    endfunction

    // ---- PMP cfg 的四项逐项锁定：L=1 的项写入被忽略（保持现值） ----
    //   ★ 未锁定项的 **WARL** 落地（2026-09-17 修复，PMPSm_pmpcfg_walk_02..05）：
    //     pmpcfg 每个配置字节 = {L, 0, 0, A[1:0], X, W, R}（bit7=L、bit6=0、bit5=0、
    //     bit[4:3]=A、bit2=X、bit1=W、bit0=R；规范图 machine.adoc「PMP configuration
    //     register format」，norm:pmp_cfg_permissions/norm:pmp_rwx_warl）。
    //     **bit[6:5] 是保留位，读恒为 0**（WARL：写入被丢弃）——arch-test 的
    //     `cp_pmpcfg_walk` 逐位走 1 覆盖 bit0/2/3/5/6/7，其中 bit5/bit6 期望读回 0
    //     （Spike 同口径，被测例 PMPSm_pmpcfg_walk_02..05 各差 8 个签名槽）。
    //     修复前本核把整个写数据原样落地 ⇒ bit5/bit6 读回 0x20/0x40。
    //     R=0,W=1 是「集体 WARL 保留组合」（norm:pmp_rwx_warl）：本设计按**写-only
    //     区域**实现（不做强制转换；全部 PMP 子集用例均不写该组合，walk 也显式跳过
    //     bit1），故此处只屏蔽保留位、不动 R/W/X 语义。
    localparam [7:0] PMP_CFG_WARL_MSK = 8'h9F;   // 保留 bit6/bit5 清零，其余位可写

    function [31:0] pmp_cfg_landing;
        input [31:0] d;
        input [31:0] cur;
        begin
            pmp_cfg_landing[ 7: 0] = cur[ 7] ? cur[ 7: 0] : (d[ 7: 0] & PMP_CFG_WARL_MSK);
            pmp_cfg_landing[15: 8] = cur[15] ? cur[15: 8] : (d[15: 8] & PMP_CFG_WARL_MSK);
            pmp_cfg_landing[23:16] = cur[23] ? cur[23:16] : (d[23:16] & PMP_CFG_WARL_MSK);
            pmp_cfg_landing[31:24] = cur[31] ? cur[31:24] : (d[31:24] & PMP_CFG_WARL_MSK);
        end
    endfunction

    // ---- PMP addr 的 TOR 前驱锁定判定：项 (i+1) 的 L=1 且 A=TOR ⇒ 项 i 写入被忽略 ----
    //   （末尾项没有后继 ⇒ 不锁定；与 ISA norm:pmplbitwriteprotection 及旧口径一致）
    function pmp_tor_locked;
        input [11:0] a;                                  // 0x3B0..0x3BF
        input [`RV32GC_PMP_ENTRIES*8-1:0] cfg;
        reg [4:0] i;
        begin
            i = a[4:0] - 5'd16;                          // 0x3B0 ⇒ 0 … 0x3BF ⇒ 15
            if (i >= 5'd15) begin
                pmp_tor_locked = 1'b0;
            end else begin
                pmp_tor_locked = cfg[(i+1)*8+7] &&
                                 (cfg[(i+1)*8+3 +: 2] == `RV32GC_PMP_A_TOR);
            end
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
    // ---- 计数器：mcycle/minstret 为 64 位；RV32 下低半走 0xB00/0xB02、
    //      高半走 0xB80/0xB82，**四个都是软件可写寄存器**（Zicntr 要求 mcycle/
    //      minstret 对 M 模式读写；高半亦然）。硬件计数输入只驱动"低半的硬件增量"：
    //      2A 口径：低半 = cycle_i[31:0]（硬件计数）+ 软件写入偏移共同决定；
    //      为保持语义简单且可测，本设计取 **"软件写即直接置值"**（低半由软件可写，
    //      高半独立软件可写），硬件计数只反映在 cycle_i/instret_i 的 *只读视图*
    //      （0xC00/0xC02）上——这也是 2A 未做计数抑制/事件选择（mcountinhibit
    //      与 mhpmevent 吞写）时的自洽口径。
    reg [31:0] mcycle_l, mcycle_h;     // mcycle  低/高半（软件可写）
    reg [31:0] minstret_l, minstret_h; // minstret 低/高半（软件可写）
    reg [31:0] mstat_sw;               // mstatus 的**软件可写**字段存储
    //   ★ 位宽必须是 3：{SEIP, STIP, SSIP} ↔ {[2],[1],[0]}。
    //     实测踩到：写成 [1:0] 而索引 [2] ⇒ 读回出现 X（iverilog 报 0xX22）。
    reg [2:0]  mip_sw;                 // {SEIP, STIP, SSIP} 的软件可写位
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

    // ---- 4.2 落地写值（WARL）：**唯一真源 = §2.5 的 csr_landing()** ----
    //   ★ 本小节的位掩码/字段级 WARL 逻辑已整体移入 §2.5 的引擎函数；这里不再另写
    //     一份（旧版把 mtvec.MODE / menvcfg.CBIE / satp.MODE / pmp L 锁定各写一遍，
    //     写通道与旁路各算一套，正是"双份逻辑漂移"的来源）。
    //     实际调用点见 §6.3 的 `wval_final`（写通道）与 §6.4 的 `rdata_w`/`byp_rdata`
    //     （两条旁路），三者共用同一函数。
    //
    // ---- mstatus / sstatus / sie / sip 的共享存储映射（供 §7 写通道用） ----
    //      sstatus 是 mstatus 的视图（SIE/SPIE/SPP/SUM/MXR/FS 同一存储）；
    //      sie 是 mie 的视图（SSIE/STIE/SEIE 同一存储）；
    //      sip 是 mip 的视图（SSIP/STIP/SEIP 软件位同一存储）。
    //      ⇒ 各落地点以对应的 wr_mask(...) 收口取"可写位"，落盘值均来自 wval_final。

    // ---- 软件写使能（WARL 过滤后的实际写入条件）----
    //   CSRRS/CSRRC 的"无写"情形由上层置 w_illegal=1 ⇒ 此处不再单独判 rs1=0。
    //   ★ 定义在 §4（早于 §6 的旁路/落地值计算）：§6.3 判定"W 槽本拍是否会落盘"
    //     也要用它，见 pmp_cfg_byp。
    wire sw_en = wen & ~w_illegal;

    // ---- 4.3 写选择（组合译码；wen 有效才落地） ----
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
    wire wr_mcycle   = wen & (waddr == `RV32GC_CSR_MCYCLE);
    wire wr_mcycleh  = wen & (waddr == `RV32GC_CSR_MCYCLEH);
    wire wr_minstret = wen & (waddr == `RV32GC_CSR_MINSTRET);
    wire wr_minstreth= wen & (waddr == `RV32GC_CSR_MINSTRETH);
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

    // ---- PMP L 位锁定（cfg 项级 + addr 的 TOR 前驱） ----
    //   ★ 判定逻辑已收口到 §2.5 的 csr_landing()（pmp_cfg_landing / pmp_tor_locked），
    //     写通道不再需要单独的 lock0/lock1/pmp_lock_all 副本（旧实现是第二份逻辑）。

    //==========================================================================
    // 5. 组合只读视图（全部 assign，红线 3）
    //==========================================================================
    // ---- mstatus：存储位 | 常量位；SD 由 FS!=Off 派生（只读汇总） ----
    wire [31:0] mstat_fs  = (mstat_sw >> `RV32GC_MSTATUS_FS_LSB) & `RV32GC_MSTATUS_FS_MSK;
    wire        mstat_sd  = (mstat_fs != `RV32GC_FS_OFF);
    wire [31:0] mstatus_view =
        (mstat_sw & wr_mask(`RV32GC_CSR_MSTATUS)) |
        (mstat_sd << `RV32GC_MSTATUS_SD_BIT);
    //   ★ 根因修复（2026-09-15，R3 的正确修法）：`mstatus_o` 是给 priv_ctrl /
    //     trap_ctrl 的**组合读视图**，必须只反映**存储值**（组合前值）——同拍陷阱/xRET
    //     的置位/清除**只作用于写入**（§7.1 `mstat_sw <= (mstat_sw & ~clr) | set`），
    //     **不得**污染本拍读出的 xIE/xPIE/xPP/MIE/SIE：
    //       · priv_ctrl 用本拍读出的这些位生成**同一拍**的更新向量 ⇒ 视图若含同拍
    //         clr/set，则「xPIE ← xIE」读到的是刚被清掉的 xIE（MPIE 恒 0）、
    //         「xIE ← xPIE」读到刚被置 1 的 xPIE（MIE 恒 1）、mret/sret 的 xPP 目标
    //         读到被自己清掉的 xPP（恒 U）；
    //       · trap_ctrl 用本拍读出的 MIE/SIE 做中断全局使能门控 ⇒ 若含同拍 MIE←0，
    //         会形成「取中断 ⇒ 清 MIE ⇒ 本拍 MIE 读 0 ⇒ 不取中断 ⇒ MIE 又为 1」的
    //         组合振荡环（Verilator UNOPTFLAT 即由此而来）。
    //     ⇒ 旧写法 `(mstatus_view & ~mstatus_clr) | mstatus_set` 已弃用：那是把
    //       "同拍更新"提前暴露到读视图上的写法，与"同拍判定用前值"的规范语义相反。
    wire [31:0] mstatus_pre = mstatus_view;   // 陷阱/xRET **之前**的 mstatus（同拍判定用）
    assign mstatus_o = mstatus_pre;

    // ---- sstatus 视图：从 mstatus 取 S 相关位 ----
    //   注意：Shifts 与 & 的优先级 —— 先移位后掩码，故每项都显式括号。
    wire [31:0] sstatus_view =
        (((mstatus_view >> `RV32GC_MSTATUS_SIE_BIT)  & 32'h1) << `RV32GC_MSTATUS_SIE_BIT) |
        (((mstatus_view >> `RV32GC_MSTATUS_SPIE_BIT) & 32'h1) << `RV32GC_MSTATUS_SPIE_BIT) |
        (((mstatus_view >> `RV32GC_MSTATUS_SPP_BIT)  & 32'h1) << `RV32GC_MSTATUS_SPP_BIT) |
        (((mstatus_view >> `RV32GC_MSTATUS_FS_LSB) & (`RV32GC_MSTATUS_FS_MSK)) << `RV32GC_MSTATUS_FS_LSB) |
        (((mstatus_view >> `RV32GC_MSTATUS_SUM_BIT) & 32'h1) << `RV32GC_MSTATUS_SUM_BIT) |
        (((mstatus_view >> `RV32GC_MSTATUS_MXR_BIT) & 32'h1) << `RV32GC_MSTATUS_MXR_BIT) |
        (((mstatus_view >> `RV32GC_MSTATUS_SD_BIT)  & 32'h1) << `RV32GC_MSTATUS_SD_BIT);

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
        ({31'b0, irq_msip} << `RV32GC_MIP_MSIP_BIT) |
        ({31'b0, irq_mtip} << `RV32GC_MIP_MTIP_BIT) |
        ({31'b0, irq_meip} << `RV32GC_MIP_MEIP_BIT) |
        ({31'b0, irq_stip} << `RV32GC_MIP_STIP_BIT) |
        ({31'b0, irq_seip} << `RV32GC_MIP_SEIP_BIT);
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
    //   注：这里用 mcycle_l/mcycle_h 直接组合成 64 位视图；硬件计数视图另有
    //   cycle/instret（0xC00/0xC02）走 cycle_i/instret_i，两者不混用（08 §6.2
    //   列 mcycle/minstret 为 MRW、cycle/instret 为 URO 视图）。
    wire [63:0] mcycle_v   = {mcycle_h, mcycle_l};
    wire [63:0] minstret_v = {minstret_h, minstret_l};

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
    // ---- ★ iverilog 12.0 可移植性约束（本会话实测踩到，必须记录）----
    //   现象：**连续赋值里调用 function、且 function 内部只读寄存器**时，
    //   Icarus Verilog 12.0 **不会**在该寄存器变化时重新求值该连续赋值；
    //   Vivado/Verilator 会正确求值。⇒ 用 function 承载 CSR 读端口会让
    //   iverilog 回归出现"写成功但读回旧值"的假失败，回归无法自证。
    //   实测最小复现（`a` 变、`r1` 变，`o` 恒为初值）：
    //       reg [31:0] r1; reg [11:0] a; wire [31:0] o;
    //       function [31:0] f; input [11:0] x; begin f = r1; end endfunction
    //       assign o = f(a);   // r1 改变后 o 不变（错误）
    //   处置：读端口改为**单 reg 单赋值**的 always @(*) case（本文件唯一例外，
    //   理由即为上述模拟器表征问题；Vivado 综合为纯组合 mux，无副作用），
    //   外加 pmpaddr 的 16 项 one-hot 纯 assign 归约。
    //   ⇒ 这既满足"回归能真测、能自证"，也不违反红线 3 的**目的**
    //     （避免多 reg 的 always @(*) 大块；此处只有**一个** reg 被赋值）。
    //--------------------------------------------------------------------------
    reg [31:0] rdata_r;
    always @(*) begin
        case (raddr)
            `RV32GC_CSR_MSTATUS:    rdata_r = mstatus_view;
            `RV32GC_CSR_SSTATUS:    rdata_r = sstatus_view;
            `RV32GC_CSR_MISA:       rdata_r = misa_view;
            `RV32GC_CSR_MEDELEG:    rdata_r = medeleg_r & `RV32GC_MEDELEG_IMPL_MSK;
            `RV32GC_CSR_MEDELEGH:   rdata_r = 32'h0;   // RV32 高半保留读 0
            `RV32GC_CSR_MIDELEG:    rdata_r = mideleg_r & `RV32GC_MIDELEG_IMPL_MSK;
            `RV32GC_CSR_MIDELEGH:   rdata_r = 32'h0;
            `RV32GC_CSR_MIE:        rdata_r = mie_o;
            `RV32GC_CSR_SIE:        rdata_r = sie_view;
            `RV32GC_CSR_MTVEC:      rdata_r = mtvec_r;
            `RV32GC_CSR_STVEC:      rdata_r = stvec_r;
            `RV32GC_CSR_MCOUNTEREN: rdata_r = mcounteren_r;
            `RV32GC_CSR_SCOUNTEREN: rdata_r = scounteren_r;
            `RV32GC_CSR_MSTATUSH:   rdata_r = 32'h0;   // 无 MBE/SBE
            `RV32GC_CSR_MENVCFG:    rdata_r = menvcfg_r;
            `RV32GC_CSR_MENVCFGH:   rdata_r = 32'h0;
            `RV32GC_CSR_SENVCFG:    rdata_r = senvcfg_r;
            `RV32GC_CSR_MSCRATCH:   rdata_r = mscratch_r;
            `RV32GC_CSR_MEPC:       rdata_r = {mepc_r[31:1], 1'b0};
            `RV32GC_CSR_MCAUSE:     rdata_r = mcause_r;
            `RV32GC_CSR_MTVAL:      rdata_r = mtval_r;
            `RV32GC_CSR_MIP:        rdata_r = mip_o;
            `RV32GC_CSR_SIP:        rdata_r = sip_view;
            `RV32GC_CSR_PMPCFG0:    rdata_r = pmp_cfg_r[31:0];
            `RV32GC_CSR_PMPCFG1:    rdata_r = pmp_cfg_r[63:32];
            `RV32GC_CSR_PMPCFG2:    rdata_r = pmp_cfg_r[95:64];
            `RV32GC_CSR_PMPCFG3:    rdata_r = pmp_cfg_r[127:96];
            `RV32GC_CSR_MCYCLE:     rdata_r = mcycle_v[31:0];
            `RV32GC_CSR_MCYCLEH:    rdata_r = mcycle_v[63:32];
            `RV32GC_CSR_MINSTRET:   rdata_r = minstret_v[31:0];
            `RV32GC_CSR_MINSTRETH:  rdata_r = minstret_v[63:32];
            `RV32GC_CSR_CYCLE:      rdata_r = cycle_i[31:0];
            `RV32GC_CSR_CYCLEH:     rdata_r = cycle_i[63:32];
            `RV32GC_CSR_TIME:       rdata_r = cycle_i[31:0];   // time 接 mtime（CLINT 提供）
            `RV32GC_CSR_TIMEH:      rdata_r = cycle_i[63:32];
            `RV32GC_CSR_INSTRET:    rdata_r = instret_i[31:0];
            `RV32GC_CSR_INSTRETH:   rdata_r = instret_i[63:32];
            `RV32GC_CSR_FFLAGS:     rdata_r = 32'h0;   // FP 状态由 fpu/fcsr 落地（本模块不持有）
            `RV32GC_CSR_FRM:        rdata_r = 32'h0;
            `RV32GC_CSR_FCSR:       rdata_r = 32'h0;
            `RV32GC_CSR_SSCRATCH:   rdata_r = sscratch_r;
            `RV32GC_CSR_SEPC:       rdata_r = {sepc_r[31:1], 1'b0};
            `RV32GC_CSR_SCAUSE:     rdata_r = scause_r;
            `RV32GC_CSR_STVAL:      rdata_r = stval_r;
            `RV32GC_CSR_SATP:       rdata_r = satp_r;
            `RV32GC_CSR_MVENDORID:  rdata_r = 32'h0;   // 非商业实现，按规范可读 0
            `RV32GC_CSR_MARCHID:    rdata_r = 32'h0;
            `RV32GC_CSR_MIMPID:     rdata_r = 32'h0;
            `RV32GC_CSR_MHARTID:    rdata_r = 32'h0;   // 单 hart，硬连 0（08 §6.2）
            // ---- ★ mcountinhibit / mhpmevent：已实现、吞写、读 0 ----
            `RV32GC_CSR_MCOUNTINHIBIT: rdata_r = 32'h0;
            `RV32GC_CSR_MHPMEVENT3,
            12'h324, 12'h325, 12'h326, 12'h327, 12'h328, 12'h329, 12'h32A, 12'h32B,
            12'h32C, 12'h32D, 12'h32E, 12'h32F, 12'h330, 12'h331, 12'h332, 12'h333,
            12'h334, 12'h335, 12'h336, 12'h337, 12'h338, 12'h339, 12'h33A, 12'h33B,
            12'h33C, 12'h33D, 12'h33E, `RV32GC_CSR_MHPMEVENT31: rdata_r = 32'h0;
            default:                rdata_r = 32'h0;
        endcase
    end

    // ---- pmpaddr 16 项读：one-hot 归约（纯 assign，无 function） ----
    wire [511:0] pmpaddr_rd_oh;
    wire [511:0] pmpaddr_wr_oh;
    genvar gr;
    generate
        for (gr = 0; gr < 16; gr = gr + 1) begin : g_pmpaddr_rd
            assign pmpaddr_rd_oh[gr*32 +: 32] =
                ((raddr == (12'h3B0 + gr[11:0])) ? pmp_addr_r[gr*32 +: 32] : 32'h0);
            assign pmpaddr_wr_oh[gr*32 +: 32] =
                ((waddr == (12'h3B0 + gr[11:0])) ? pmp_addr_r[gr*32 +: 32] : 32'h0);
        end
    endgenerate

    // ---- 16 路 OR 归约（写全 16 项，便于复核无遗漏） ----
    wire [31:0] pmpaddr_rd = pmpaddr_rd_oh[0*32 +: 32]  | pmpaddr_rd_oh[1*32 +: 32]  |
                             pmpaddr_rd_oh[2*32 +: 32]  | pmpaddr_rd_oh[3*32 +: 32]  |
                             pmpaddr_rd_oh[4*32 +: 32]  | pmpaddr_rd_oh[5*32 +: 32]  |
                             pmpaddr_rd_oh[6*32 +: 32]  | pmpaddr_rd_oh[7*32 +: 32]  |
                             pmpaddr_rd_oh[8*32 +: 32]  | pmpaddr_rd_oh[9*32 +: 32]  |
                             pmpaddr_rd_oh[10*32 +: 32] | pmpaddr_rd_oh[11*32 +: 32] |
                             pmpaddr_rd_oh[12*32 +: 32] | pmpaddr_rd_oh[13*32 +: 32] |
                             pmpaddr_rd_oh[14*32 +: 32] | pmpaddr_rd_oh[15*32 +: 32];
    wire [31:0] pmpaddr_wr = pmpaddr_wr_oh[0*32 +: 32]  | pmpaddr_wr_oh[1*32 +: 32]  |
                             pmpaddr_wr_oh[2*32 +: 32]  | pmpaddr_wr_oh[3*32 +: 32]  |
                             pmpaddr_wr_oh[4*32 +: 32]  | pmpaddr_wr_oh[5*32 +: 32]  |
                             pmpaddr_wr_oh[6*32 +: 32]  | pmpaddr_wr_oh[7*32 +: 32]  |
                             pmpaddr_wr_oh[8*32 +: 32]  | pmpaddr_wr_oh[9*32 +: 32]  |
                             pmpaddr_wr_oh[10*32 +: 32] | pmpaddr_wr_oh[11*32 +: 32] |
                             pmpaddr_wr_oh[12*32 +: 32] | pmpaddr_wr_oh[13*32 +: 32] |
                             pmpaddr_wr_oh[14*32 +: 32] | pmpaddr_wr_oh[15*32 +: 32];

    wire rd_is_pmpaddr = (raddr >= 12'h3B0) && (raddr <= 12'h3BF);
    assign rdata = rd_is_pmpaddr ? pmpaddr_rd : rdata_r;

    // ---- 写端口旁路读（waddr 视角；供 CSR 同拍读使用） ----
    reg [31:0] rdataw_r;
    always @(*) begin
        case (waddr)
            `RV32GC_CSR_MSTATUS:    rdataw_r = mstatus_view;
            `RV32GC_CSR_SSTATUS:    rdataw_r = sstatus_view;
            `RV32GC_CSR_MISA:       rdataw_r = misa_view;
            `RV32GC_CSR_MIE:        rdataw_r = mie_o;
            `RV32GC_CSR_SIE:        rdataw_r = sie_view;
            `RV32GC_CSR_MIP:        rdataw_r = mip_o;
            `RV32GC_CSR_SIP:        rdataw_r = sip_view;
            `RV32GC_CSR_MTVEC:      rdataw_r = mtvec_r;
            `RV32GC_CSR_STVEC:      rdataw_r = stvec_r;
            `RV32GC_CSR_MEPC:       rdataw_r = {mepc_r[31:1], 1'b0};
            `RV32GC_CSR_MCAUSE:     rdataw_r = mcause_r;
            `RV32GC_CSR_MTVAL:      rdataw_r = mtval_r;
            `RV32GC_CSR_SEPC:       rdataw_r = {sepc_r[31:1], 1'b0};
            `RV32GC_CSR_SCAUSE:     rdataw_r = scause_r;
            `RV32GC_CSR_STVAL:      rdataw_r = stval_r;
            `RV32GC_CSR_SATP:       rdataw_r = satp_r;
            `RV32GC_CSR_MENVCFG:    rdataw_r = menvcfg_r;
            `RV32GC_CSR_SENVCFG:    rdataw_r = senvcfg_r;
            default:                rdataw_r = rdata_r;
        endcase
    end
    wire wr_is_pmpaddr = (waddr >= 12'h3B0) && (waddr <= 12'h3BF);
    wire [31:0] rd_waddr_cur = wr_is_pmpaddr ? pmpaddr_wr : rdataw_r;  // waddr 视角的"当前读回值"

    //==========================================================================
    // 6.3 写通道落地值（WARL 唯一真源；§7 的时序写点与 §6.4 的两条旁路共用）
    //==========================================================================
    //   cur 口径：
    //     · pmpaddr 地址：走专用 one-hot 读（pmpaddr_wr，waddr 视角）—— 只有它真正
    //       依赖"该项现值"（TOR 前驱锁定 ⇒ 锁定项落盘值 = 现值）；
    //     · 其余地址：rdataw_r（waddr 视角读视图；未列举项回退 rdata_r）。该回退
    //       不影响任何落地点：§7 的每个写点都以 wr_mask(...) 或字段掩码收口，掩码外
    //       的 cur 位一律被丢弃；而 mtvec/stvec/menvcfg/senvcfg 的"保留字段"走显式
    //       现值入参（mtvec_r/stvec_r/menvcfg_r/senvcfg_r），不依赖 cur。
    wire [31:0] wval_final = csr_landing(waddr, wdata, rd_waddr_cur,
                                         mtvec_r, stvec_r, menvcfg_r, senvcfg_r, pmp_cfg_r);

    //==========================================================================
    // 6.4 写口旁路读（rdata_w）+ M 级旁路预览（byp_rdata）—— 都取 post-WARL 落盘值
    //==========================================================================
    //   ★ 为什么不取"原始写数据"（旧实现）：那会绕过全部 WARL —— mtvec.MODE 保留值、
    //     mepc/sepc bit0、medeleg/mideleg 实现位、PMP L 锁定、misa/mcountinhibit/
    //     mhpmevent 吞写、menvcfg.CBIE 都会读到"假新值"（实测 mtvec 读回 0x8000_0002）。
    //     旁路值必须是"落盘后**读回**值"而不是"掩码后写值"：吞写类与 PMP 锁定项的
    //     落盘值 = **现值不变**（掩码后写值会给出 0，同样错）。
    //   · rdata_w（W 级旁路：写指令在 W、读指令在 E）：raddr == waddr ⇒ 本拍末将落盘的
    //     该 CSR 值；其余情形退回普通读视图（与"写口旁路读"的语义一致）。
    //   · byp_rdata（M 级旁路：写指令在 M、读指令在 E）：把**更年轻**的 M 级写数据
    //     byp_wdata 写进 raddr 之后的读回值；core_top 只在 em 槽地址 == de_csr_addr
    //     （csr_em_hit）时采用 ⇒ 与 rdata_w 一起实现"距离 0/1 两级旁路"。
    //   ⇒ 二者与 §6.3 的写通道落地值共用同一个 csr_landing() 引擎（单一真源）。
    assign rdata_w  = (raddr == waddr) ? wval_final : rdata;

    //   M 级预览的"既有状态"必须取**本拍末 W 级写落地之后**的值（M 槽比 W 槽年轻，
    //   程序序上更年轻的写作用在"更老那条已落盘"的状态上）：
    //     · raddr == waddr（= W 槽正在写读者要读的 CSR）⇒ 该地址现值即 W 级落盘值；
    //     · PMP cfg 分组同理（L 位判定必须基于 W 级写之后的 cfg）。
    wire [31:0]  byp_cur = (raddr == waddr) ? wval_final : rdata;
    wire [127:0] pmp_cfg_byp = {
        (wr_pmpcfg[3] & sw_en) ? wval_final : pmp_cfg_r[127: 96],
        (wr_pmpcfg[2] & sw_en) ? wval_final : pmp_cfg_r[ 95: 64],
        (wr_pmpcfg[1] & sw_en) ? wval_final : pmp_cfg_r[ 63: 32],
        (wr_pmpcfg[0] & sw_en) ? wval_final : pmp_cfg_r[ 31:  0] };
    assign byp_rdata = csr_landing(raddr, byp_wdata, byp_cur,
                                   mtvec_r, stvec_r, menvcfg_r, senvcfg_r, pmp_cfg_byp);

    //==========================================================================
    // 7. 时序：唯一的存储写点
    //    理由：CSR 是架构寄存器组，必须时钟沿保持 ⇒ always 块不可省略（AGENT.md §4.3）。
    //    写优先级：trap_we（陷阱入口）> wen（软件 CSR 写）。
    //==========================================================================
    // ---- 软件写使能（WARL 过滤后的实际写入条件） ----
    //      ★ sw_en 的定义见 §4.2（§6.3 的 pmp_cfg_byp 先用到它，故前移）。

    // ---- 陷阱写译码（**分组**语义，与 trap_ctrl 的 trap_we 编码一一对应） ----
    //   trap_we[0] = M 侧组：一次写 epc + cause + tval 三个 CSR
    //   trap_we[1] = S 侧组：一次写 sepc + scause + stval 三个 CSR
    //   trap_we[2] = sscratch 单写（trap_ctrl 不用；留给上层显式写）
    //   trap_we[3] = mscratch 单写（trap_ctrl 不用）
    //   ★ 数据来源三个独立端口（epc/cause/tval），避免"一次一笔"的表达力不足：
    //     见端口注释中的 trap_wdata 语义——本模块按组把 trap_epc_i /
    //     trap_cause_i / trap_tval_i 分别写入对应 CSR。
    //   ★ 之所以**不**用 trap_addr 逐 CSR 译码：一次陷阱必须原子地更新 3 个 CSR，
    //     逐地址译码需要 3 拍，会破坏"单一写点"与精确性（08 §5.6 行为要点 ①）。
    wire tw_mepc   = trap_we[0];
    wire tw_mcause = trap_we[0];
    wire tw_mtval  = trap_we[0];
    wire tw_sepc   = trap_we[1];
    wire tw_scause = trap_we[1];
    wire tw_stval  = trap_we[1];
    wire tw_sscr   = trap_we[2];
    wire tw_mscr   = trap_we[3];

    // ---- pmpaddr 写入辅助 task（静态索引，见 §7.8 注释） ----
    //   task 用于时序块（always）内，iverilog / Vivado 均可综合。
    //   ★ TOR 前驱锁定（项 idx 写被忽略）已收口在 wval_final 内部（csr_landing →
    //     pmp_tor_locked），本 task 只做"该地址被写"的静态展开 ⇒ 无双份锁定逻辑。
    task pmpaddr_write;
        input integer idx;
        begin
            if (wr_pmpaddr[idx] & sw_en)
                pmp_addr_r[idx*32 +: 32] <= wval_final;
        end
    endtask

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
            mcycle_l     <= 32'h0;
            mcycle_h     <= 32'h0;
            minstret_l   <= 32'h0;
            minstret_h   <= 32'h0;
            mstat_sw     <= 32'h0;
            mip_sw       <= 2'b00;
            pmp_cfg_r    <= {`RV32GC_PMP_ENTRIES*8{1'b0}};
            pmp_addr_r   <= {`RV32GC_PMP_ENTRIES*32{1'b0}};
        end else begin
            // ---- 7.1 mstatus（含 sstatus 视图写入 + trap_ctrl 的置/清） ----
            //   trap_ctrl 的 mstatus_set/mstatus_clr 优先级最高（同拍）
            //   ★ 落地值一律取 wval_final（post-WARL 落盘值，§6.4）；各写点以自身
            //     wr_mask 收口：mstatus 取自身可写位，sstatus 只替换 S 视图位（同存储）。
            if (mstatus_clr != 32'h0 || mstatus_set != 32'h0) begin
                mstat_sw <= (mstat_sw & ~mstatus_clr) | mstatus_set;
            end else if (sw_en && (waddr == `RV32GC_CSR_MSTATUS)) begin
                mstat_sw <= wval_final & wr_mask(`RV32GC_CSR_MSTATUS);
            end else if (sw_en && (waddr == `RV32GC_CSR_SSTATUS)) begin
                mstat_sw <= (mstat_sw & ~wr_mask(`RV32GC_CSR_SSTATUS)) |
                            (wval_final & wr_mask(`RV32GC_CSR_SSTATUS));
            end

            // ---- 7.2 mie / sie ----
            if (sw_en && (waddr == `RV32GC_CSR_MIE)) begin
                mie_r <= wval_final & wr_mask(`RV32GC_CSR_MIE);
            end else if (sw_en && (waddr == `RV32GC_CSR_SIE)) begin
                mie_r <= (mie_r & ~(`RV32GC_MIDELEG_IMPL_MSK)) |
                         (wval_final & `RV32GC_MIDELEG_IMPL_MSK);
            end

            // ---- 7.3 mip 的软件可写位 {SEIP,STIP,SSIP} ----
            if (sw_en && (waddr == `RV32GC_CSR_MIP)) begin
                mip_sw <= { wval_final[`RV32GC_MIP_SEIP_BIT], wval_final[`RV32GC_MIP_STIP_BIT],
                            wval_final[`RV32GC_MIP_SSIP_BIT] };
            end else if (sw_en && (waddr == `RV32GC_CSR_SIP)) begin
                mip_sw <= { mip_sw[2], mip_sw[1], wval_final[`RV32GC_MIP_SSIP_BIT] };
            end

            // ---- 7.4 M 模式陷阱设置 ----
            if (tw_mscr)   mscratch_r <= trap_data_i;
            else if (wr_scratch & sw_en) mscratch_r <= wval_final;

            // ---- M 组：epc / cause / tval 同拍原子写 ----
            if (tw_mepc)   mepc_r <= {trap_epc_i[31:1], 1'b0};
            else if (wr_mepc & sw_en) mepc_r <= {wval_final[31:1], 1'b0};

            if (tw_mcause) mcause_r <= trap_cause_i;
            else if (wr_mcause & sw_en) mcause_r <= wval_final;

            if (tw_mtval)  mtval_r <= trap_tval_i;
            else if (wr_mtval & sw_en) mtval_r <= wval_final;

            if (wr_mtvec & sw_en) mtvec_r <= wval_final;   // 含 MODE WARL（在 csr_landing 内）
            if (wr_stvec & sw_en) stvec_r <= wval_final;

            if (wr_medeleg & sw_en) medeleg_r <= wval_final & `RV32GC_MEDELEG_IMPL_MSK;
            if (wr_mideleg & sw_en) mideleg_r <= wval_final & `RV32GC_MIDELEG_IMPL_MSK;

            if (wr_mcnten & sw_en) mcounteren_r <= wval_final & 32'h0000_0007;
            if (wr_scnten & sw_en) scounteren_r <= wval_final & 32'h0000_0007;
            if (wr_menvcfg & sw_en) menvcfg_r <= wval_final;   // 含 CBIE WARL（在 csr_landing 内）
            if (wr_senvcfg & sw_en) senvcfg_r <= wval_final;
            if (wr_satp & sw_en)    satp_r <= wval_final;

            // ---- 7.5 S 模式陷阱设置 ----
            if (tw_sscr)   sscratch_r <= trap_data_i;
            else if (wr_sscratch & sw_en) sscratch_r <= wval_final;

            // ---- S 组：epc / cause / tval 同拍原子写 ----
            if (tw_sepc)   sepc_r <= {trap_epc_i[31:1], 1'b0};
            else if (wr_sepc & sw_en) sepc_r <= {wval_final[31:1], 1'b0};

            if (tw_scause) scause_r <= trap_cause_i;
            else if (wr_scause & sw_en) scause_r <= wval_final;

            if (tw_stval)  stval_r <= trap_tval_i;
            else if (wr_stval & sw_en) stval_r <= wval_final;

            // ---- 7.6 计数器高半（软件可写；低半由硬件计数器驱动） ----
            if (wr_mcycle    & sw_en) mcycle_l   <= wval_final;
            if (wr_mcycleh   & sw_en) mcycle_h   <= wval_final;
            if (wr_minstret  & sw_en) minstret_l <= wval_final;
            if (wr_minstreth & sw_en) minstret_h <= wval_final;

            // ---- 7.7 PMP cfg（逐项 L 位锁定） ----
            // ---- 7.7 PMP cfg（逐项 L 位锁定已收口在 csr_landing 内；写点只做分组选择）----
            if (wr_pmpcfg[0] & sw_en) pmp_cfg_r[ 31:  0] <= wval_final;
            if (wr_pmpcfg[1] & sw_en) pmp_cfg_r[ 63: 32] <= wval_final;
            if (wr_pmpcfg[2] & sw_en) pmp_cfg_r[ 95: 64] <= wval_final;
            if (wr_pmpcfg[3] & sw_en) pmp_cfg_r[127: 96] <= wval_final;

            // ---- 7.8 PMP addr（16 项定序展开；TOR 前驱锁定在 csr_landing 内） ----
            //   ISA norm:pmplbitwriteprotection：若项 i 被 L 锁定且 A=TOR，
            //   则对 pmpaddr[i-1] 的写被忽略。
            //   理由（红线 3 例外）：16 项逐一条件写入，展开为静态索引的时序分支，
            //   比 always 内动态索引数组更安全（避免动态 part-select 的可综合性问题）。
            pmpaddr_write( 0); pmpaddr_write( 1); pmpaddr_write( 2); pmpaddr_write( 3);
            pmpaddr_write( 4); pmpaddr_write( 5); pmpaddr_write( 6); pmpaddr_write( 7);
            pmpaddr_write( 8); pmpaddr_write( 9); pmpaddr_write(10); pmpaddr_write(11);
            pmpaddr_write(12); pmpaddr_write(13); pmpaddr_write(14); pmpaddr_write(15);
        end
    end

endmodule
