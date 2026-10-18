//==============================================================================
// rtl/decode/dec_csr.v —— D 级 CSR 译码与权限预判（含 cbo.* 门控预判）
//==============================================================================
// 项目    : rv32gc-cpu（阶段二 2A：单发射顺序 5 级基线核）
// 规格    : docs/design/08-baseline-5stage.md §5.2 行为要点③④
//           —— 「CSR 译码：地址 + 权限（M/S/U 可访问性矩阵，见 §6.2）+ WARL 字段；
//               写只读 CSR ⇒ 非法指令」
//              「cbo.* 门控预判：按 priv + menvcfg/senvcfg 的 CBIE/CBCFE 判定是否
//               执行/降级/抛非法指令（06-csr-privilege.md §7.3）；D 级判定，
//               M 级二次校验（防同拍旁路漏洞）」
//           docs/design/06-csr-privilege.md §7.3（判定顺序）、§9（异常口径汇总）
// 作用    : 纯组合。做三件事——
//             (1) **CSR 地址 → 是否存在 / 最低可访问特权级 / 是否只读**；
//                 U/S 访问越权 或 未实现地址 ⇒ csr_ill。
//             (2) **写只读 CSR ⇒ 非法指令**（Zicsr：csr[11:10]==2'b11 为只读）。
//             (3) **cbo.* 门控预判**：按有效特权级与 menvcfg/senvcfg 的
//                 CBIE/CBCFE 判定 execute / 降级 / 非法指令；输出 cbo_gate_ill
//                 与 cbo_kind_o（2A 只含 clean/flush/inval）。
//
// 关键口径：
//   * **CSR 地址权限编码**（rv32_defs.vh §4.1）：
//       csr[11:10] = 00/01/10 ⇒ 读写；11 ⇒ 只读（写 ⇒ 非法指令）
//       csr[9:8]   = 00=U, 01=S, 10=H, 11=M（最低可访问特权级）
//     因此「权限矩阵」可用**位段比较**表达，无需逐条列举——但**未实现地址**
//     必须逐条白名单判定（08 §6.2 的全集清单）。
//   * **2A 不落地 U 模式 CSR**（08 §6.2 母 Agent 裁决 2026-09-14）：
//     `RV32GC_IMPLEMENT_U_MODE_CSRS=0` ⇒ 该组地址按**未实现**处理。
//   * **CBO 门控表**（06 §7.3）：
//       M 模式            ：不受 envcfg 门控
//       S 模式            ：menvcfg 对应位
//       U 模式            ：menvcfg 位 **AND** senvcfg 位（叠加）
//       CBIE=00(<M) ⇒ 非法；CBIE=01 ⇒ 执行但 INVAL 降级 FLUSH；
//       CBIE=11 ⇒ 按 INVAL 执行；CBIE=10 为保留（WARL 已保证不会出现）
//       CBCFE=1 才允许 <M 执行 clean/flush
//     ★ 门控位取值应传**旁路后值**（同拍旁路，06 §4）；本模块只做判定。
//
// 风格纪律: AGENT.md §4 红线 3 + 08 §7.4 —— 纯 assign/function，本文件**无 always 块**。
// 引用    : [ISA] riscv-isa-manual/src/priv/csrs.adoc:25-49（csr[11:10]/[9:8] 编码）、
//                  machine.adoc（menvcfg CBIE/CBCFE 条文）、supervisor.adoc（senvcfg）、
//                  cmo.adoc（Sail 伪码判定顺序）
//            [DOC] docs/design/08-baseline-5stage.md §6.2、docs/design/06-csr-privilege.md §7
//            [ENC] csr 地址常量取自 rtl/pkg/rv32_defs.vh §4（唯一真源）
//==============================================================================
`ifndef RV32GC_DEC_CSR_V
`define RV32GC_DEC_CSR_V

`include "rtl/pkg/rv32_defs.vh"
`include "rtl/pkg/core_params.vh"

module dec_csr (
    // ---- 输入：CSR 指令字段与当前特权级 ----
    input  wire [11:0] csr_addr,      // insn[31:20]
    input  wire [1:0]  priv,          // 当前特权级（**旁路后**有效值）
    input  wire        is_csr_wr,     // 该 CSR 指令**会写**目标 CSR（CSRRW/CSRRWI，
                                      //   或 CSRRS/CSRRC 且 rs1!=x0 —— 由 decoder 判定后传入）
    // ---- envcfg 门控位（旁路后值）----
    input  wire [1:0]  menvcfg_cbie,
    input  wire        menvcfg_cbcfe,
    input  wire [1:0]  senvcfg_cbie,
    input  wire        senvcfg_cbcfe,
    // ---- cbo.* 译码结果（来自 decoder；2A 只含 clean/flush/inval）----
    input  wire        cbo_valid,     // 这是一条 cbo.* 指令
    input  wire [4:0]  cbo_rs2,       // 动作码（rs2 域）
    // ---- 输出 ----
    output wire        csr_exists_o,  // 该地址在 2A 已实现集合内
    output wire        csr_ill_o,     // 地址/权限/只读写 违规 ⇒ 非法指令
    output wire        cbo_gate_ill_o,// cbo.* 门控不满足 ⇒ 非法指令
    output wire        cbo_downgrade_o,// INVAL 因 CBIE=01 降级为 FLUSH
    output wire [4:0]  cbo_kind_o     // 门控后的**实际动作码**（降级后为 FLUSH）
);

    //==========================================================================
    // 1. CSR 权限位段（csr[11:10]=读写属性，csr[9:8]=最低可访问特权级）
    //    [ISA:csrs.adoc:25-49]
    //==========================================================================
    wire [1:0] csr_rw   = csr_addr[11:10];
    wire [1:0] csr_plvl = csr_addr[9:8];

    // ---- 只读 CSR（rw==2'b11）----
    wire csr_is_ro = (csr_rw == 2'b11);
    // ---- 该 CSR 的**最低可访问特权级**（数值越大越高：U=0 < S=1 < H=2 < M=3）----
    wire [1:0] csr_minplvl = csr_plvl;

    // ---- 特权级编码换算成同一「数值越大越高」口径 ----
    //      rv32_defs.vh §5.2：PRIV_U=2'b00(0)、PRIV_S=2'b01(1)、PRIV_M=2'b11(3)
    //      ⇒ 与 csr_plvl 的 0/1/3 编码**天然一致**（H=2 本设计不实现）。
    wire priv_ok = (priv >= csr_minplvl);

    //==========================================================================
    // 2. 未实现地址白名单（08 §6.2 的 2A 全集）
    //    逐条列出，**不依赖**权限位段的"看起来合法"——未实现地址一律非法。
    //    地址常量全部取自 rv32_defs.vh §4（唯一真源）。
    //==========================================================================
    // ---- 非特权：FP 与 Zicntr 计数器（U 可访问，受 mcounteren/scounteren 门控）----
    wire is_csr_fp = (csr_addr == `RV32GC_CSR_FFLAGS) ||
                     (csr_addr == `RV32GC_CSR_FRM)    ||
                     (csr_addr == `RV32GC_CSR_FCSR);
    wire is_csr_ucntr = (csr_addr == `RV32GC_CSR_CYCLE)   ||
                        (csr_addr == `RV32GC_CSR_TIME)    ||
                        (csr_addr == `RV32GC_CSR_INSTRET) ||
                        (csr_addr == `RV32GC_CSR_CYCLEH)  ||
                        (csr_addr == `RV32GC_CSR_TIMEH)   ||
                        (csr_addr == `RV32GC_CSR_INSTRETH);
    // ---- S 模式（08 §6.2 S 模式清单）----
    wire is_csr_s = (csr_addr == `RV32GC_CSR_SSTATUS)    ||
                    (csr_addr == `RV32GC_CSR_SIE)        ||
                    (csr_addr == `RV32GC_CSR_STVEC)      ||
                    (csr_addr == `RV32GC_CSR_SCOUNTEREN) ||
                    (csr_addr == `RV32GC_CSR_SENVCFG)    ||
                    (csr_addr == `RV32GC_CSR_SSCRATCH)   ||
                    (csr_addr == `RV32GC_CSR_SEPC)       ||
                    (csr_addr == `RV32GC_CSR_SCAUSE)     ||
                    (csr_addr == `RV32GC_CSR_STVAL)      ||
                    (csr_addr == `RV32GC_CSR_SIP)        ||
                    (csr_addr == `RV32GC_CSR_SATP);
    // ---- M 模式：信息寄存器（MRO）----
    wire is_csr_m_info = (csr_addr == `RV32GC_CSR_MVENDORID) ||
                         (csr_addr == `RV32GC_CSR_MARCHID)   ||
                         (csr_addr == `RV32GC_CSR_MIMPID)    ||
                         (csr_addr == `RV32GC_CSR_MHARTID);
    // ---- M 模式：陷阱设置 ----
    wire is_csr_m_trap = (csr_addr == `RV32GC_CSR_MSTATUS)   ||
                         (csr_addr == `RV32GC_CSR_MISA)      ||
                         (csr_addr == `RV32GC_CSR_MEDELEG)   ||
                         (csr_addr == `RV32GC_CSR_MIDELEG)   ||
                         (csr_addr == `RV32GC_CSR_MIE)       ||
                         (csr_addr == `RV32GC_CSR_MTVEC)     ||
                         (csr_addr == `RV32GC_CSR_MCOUNTEREN)||
                         (csr_addr == `RV32GC_CSR_MSTATUSH)  ||
                         (csr_addr == `RV32GC_CSR_MEDELEGH)  ||
                         (csr_addr == `RV32GC_CSR_MIDELEGH);
    // ---- M 模式：环境配置 ----
    wire is_csr_m_env = (csr_addr == `RV32GC_CSR_MENVCFG) ||
                        (csr_addr == `RV32GC_CSR_MENVCFGH);
    // ---- M 模式：陷阱处理 ----
    wire is_csr_m_phdl = (csr_addr == `RV32GC_CSR_MSCRATCH) ||
                         (csr_addr == `RV32GC_CSR_MEPC)     ||
                         (csr_addr == `RV32GC_CSR_MCAUSE)   ||
                         (csr_addr == `RV32GC_CSR_MTVAL)    ||
                         (csr_addr == `RV32GC_CSR_MIP);
    // ---- M 模式：PMP（4 个 cfg + 16 个 addr）----
    wire is_csr_pmpcfg = (csr_addr == `RV32GC_CSR_PMPCFG0) ||
                         (csr_addr == `RV32GC_CSR_PMPCFG1) ||
                         (csr_addr == `RV32GC_CSR_PMPCFG2) ||
                         (csr_addr == `RV32GC_CSR_PMPCFG3);
    //   pmpaddr0..15 = 0x3B0..0x3BF：用位段判定（等距，无空洞）
    wire is_csr_pmpaddr = (csr_addr[11:4] == 8'h3B);
    // ---- M 模式：计数器 ----
    wire is_csr_m_cntr = (csr_addr == `RV32GC_CSR_MCYCLE)     ||
                         (csr_addr == `RV32GC_CSR_MINSTRET)   ||
                         (csr_addr == `RV32GC_CSR_MCOUNTINHIBIT) ||
                         (csr_addr == `RV32GC_CSR_MCYCLEH)    ||
                         (csr_addr == `RV32GC_CSR_MINSTRETH);
    //   mhpmevent3..31（0x323..0x33F）：arch-test 启动代码会**无条件**写
    //   （rv32_defs.vh §4.9 ★ 注：riscv-arch-test/tests/env/rvtest_setup.h:1059-1129）
    //   ⇒ 2A 必须让其可写（WARL 吞写），否则回归在启动阶段挂死。
    //   判定：0x320 已由 mcountinhibit 覆盖；此处取 0x323..0x33F。
    wire is_csr_mhpmevent = (csr_addr[11:6] == 6'b001100) && (csr_addr[5:0] >= 6'h23);
    // ---- M 模式：高半部陷阱别名 medelegh/midelegh 已在 m_trap 内 ----

    // ---- 2A 不落地的 U 模式 CSR（RV32GC_IMPLEMENT_U_MODE_CSRS=0 ⇒ 按未实现）----
    //      08 §6.2 裁决：门控为 0 时该组地址一律按**未实现**处理 ⇒ U/S 访问报 cause 2。
    wire is_csr_u_legacy = (csr_addr == `RV32GC_CSR_USTATUS)  ||
                           (csr_addr == `RV32GC_CSR_UIE)      ||
                           (csr_addr == `RV32GC_CSR_UTVEC)    ||
                           (csr_addr == `RV32GC_CSR_USCRATCH) ||
                           (csr_addr == `RV32GC_CSR_UEPC)     ||
                           (csr_addr == `RV32GC_CSR_UCAUSE)   ||
                           (csr_addr == `RV32GC_CSR_UTVAL)    ||
                           (csr_addr == `RV32GC_CSR_UIP);
    wire u_csr_implemented = (`RV32GC_IMPLEMENT_U_MODE_CSRS != 0);

    // ---- 未实现集合：fp/ucntr/s/m_* 之外的一切，以及门控为 0 的 U 组 ----
    wire is_csr_implemented =
        is_csr_fp | is_csr_ucntr | is_csr_s |
        is_csr_m_info | is_csr_m_trap | is_csr_m_env |
        is_csr_m_phdl | is_csr_pmpcfg | is_csr_pmpaddr |
        is_csr_m_cntr | is_csr_mhpmevent |
        (is_csr_u_legacy & u_csr_implemented);

    //==========================================================================
    // 3. 「S 访问 M 专属」「U 访问 S 专属」判定
    //    —— 由上述「最低可访问特权级」位段比较统一覆盖（priv < csr_minplvl ⇒ 非法）。
    //       ★ 但位段比较把「H=2」也当作合法门槛；本设计不实现 H，故对 csr_plvl==2
    //         的地址一律按未实现处理（不在白名单 ⇒ 已被 is_csr_implemented 排除）。
    //==========================================================================
    assign csr_exists_o = is_csr_implemented;

    // ---- 非法判定 ----
    //   (a) 地址未实现                     ⇒ 非法
    //   (b) 当前特权级低于该 CSR 的最低级    ⇒ 非法
    //   (c) 写只读 CSR（rw==2'b11 且本次会写）⇒ 非法（Zicsr 强制）
    wire csr_ro_write_ill = csr_is_ro & is_csr_wr;
    assign csr_ill_o = ~is_csr_implemented | ~priv_ok | csr_ro_write_ill;

    //==========================================================================
    // 4. cbo.* 门控预判（06-csr-privilege.md §7.3 的判定顺序）
    //    ★ 动作码来自 **rs2 字段**（cbo_rs2），不是 funct7——见 rv32_defs.vh §3.11 的
    //      「★ 关键」注释：clean/flush 的 funct7 相同，只靠 rs2 区分。
    //==========================================================================
    wire c_is_inval = (cbo_rs2 == `RV32GC_CBO_INVAL);
    wire c_is_clean = (cbo_rs2 == `RV32GC_CBO_CLEAN);
    wire c_is_flush = (cbo_rs2 == `RV32GC_CBO_FLUSH);
    //   2A 范围：只含 clean/flush/inval；其它 rs2 值 ⇒ 未知动作（由 decoder 报非法）
    wire c_known    = c_is_inval | c_is_clean | c_is_flush;

    // ---- 有效门控位（按特权级选取；M 模式不受门控）----
    //   S 模式：用 menvcfg；U 模式：menvcfg AND senvcfg（叠加，06 §7.2 的 supervisor.adoc 条文）
    wire sel_s = (priv == `RV32GC_PRIV_S);
    wire sel_u = (priv == `RV32GC_PRIV_U);

    // CBIE 的有效值：M ⇒ 视作 11（不门控，等效执行 INVAL）
    wire [1:0] eff_cbie = (priv == `RV32GC_PRIV_M) ? 2'b11 :
                          sel_u ? (menvcfg_cbie & senvcfg_cbie) : menvcfg_cbie;
    // CBCFE 的有效值：M ⇒ 视作 1（不门控）；U ⇒ 叠加
    wire eff_cbcfe = (priv == `RV32GC_PRIV_M) ? 1'b1 :
                     sel_u ? (menvcfg_cbcfe & senvcfg_cbcfe) : menvcfg_cbcfe;

    // ---- INVAL 门控：CBIE=00 ⇒ 非法（<M）；01 ⇒ 降级 FLUSH；11 ⇒ 按 INVAL ----
    wire inval_ill       = (eff_cbie == 2'b00);
    wire inval_downgrade = (eff_cbie == 2'b01);
    // ---- CLEAN/FLUSH 门控：CBCFE=0 ⇒ 非法（<M）----
    wire clean_flush_ill = ~eff_cbcfe;

    // ---- 汇总门控结果（只在 cbo_valid 时有意义）----
    wire cbo_ill_now =
        c_is_inval ? inval_ill :
        (c_is_clean | c_is_flush) ? clean_flush_ill :
        1'b0;
    wire cbo_dg_now = c_is_inval & inval_downgrade;

    assign cbo_gate_ill_o  = cbo_valid & ~c_known ? 1'b1 :          // 未知动作码 ⇒ 非法
                             cbo_valid           ? cbo_ill_now :
                                                   1'b0;
    assign cbo_downgrade_o = cbo_valid & cbo_dg_now;
    // ---- 门控后的实际动作码（降级 INVAL⇒FLUSH）----
    assign cbo_kind_o = (~cbo_valid)         ? 5'b0 :
                        cbo_dg_now           ? `RV32GC_CBO_FLUSH :
                                               cbo_rs2;

endmodule

`endif // RV32GC_DEC_CSR_V
