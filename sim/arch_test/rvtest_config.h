/*==============================================================================
 * sim/arch_test/rvtest_config.h —— ACT4 的「DUT 配置头」（**手工维护版**）
 *------------------------------------------------------------------------------
 * 项目 : rv32gc-cpu（阶段二 2A 基线核；docs/design/08-baseline-5stage.md §8.2）
 * 角色 : riscv-arch-test 中本文件**正常由 UDB 生成**（`udb cfg-c-header`，
 *        输入 = test_config.yaml 的 udb_config: rv32gc-2a.yaml）。
 *
 * ★ 为什么是手工维护：本机**没有** uv / ruby / bundler（AGENT.md §2 环境事实，
 *   且用户红线禁止自行安装系统包），`make` / `udb` / `bundle` 均不可用 ⇒ 本文件
 *   按 `sim/arch_test/rv32gc-2a.yaml` 的声明**手工翻译**而成。口径纪律：
 *     · 只写 DUT **确实实现**的能力，不写"为了跑过而放宽"的宏；
 *     · 每条宏后注明依据（RTL 真源 / 取值推导），便于复核；
 *     · 若将来 UDB 可用，本文件应改为 UDB 产物（把 rv32gc-2a.yaml 喂给它即可）。
 *
 * 覆盖的 UDB_* 宏 = tests/env/** 实际引用的全集（已用 grep 核算，见 run.sh 头注）。
 *============================================================================*/
#ifndef RVTEST_CONFIG_H
#define RVTEST_CONFIG_H

/*------------------------------------------------------------------------------
 * 1. 基本位宽
 *----------------------------------------------------------------------------*/
#define UDB_MXLEN 32                      /* RV32（core_params.vh §4 RV32GC_XLEN=32）*/

/*------------------------------------------------------------------------------
 * 2. PMP（16 项，粒度 G=0 ⇒ 最小 TOR 区域 4 B、最小 NAPOT 区域 8 B）
 *    · UDB_PMP_GRANULARITY 的单位 = log2(最小 TOR 区域字节数)：
 *      G=0 ⇒ 最小 4 B ⇒ log2(4) = 2（推导依据：env 侧
 *      PMP_TOR_REGION_BYTES = 1 << UDB_PMP_GRANULARITY、
 *      g_napot = 2^(GRAN+1) = 8 B）。
 *    · 依据：core_params.vh §6（16 项、G=0、NA4 可用）；pmp_check.v 实现 NA4/NAPOT/TOR。
 *----------------------------------------------------------------------------*/
#define UDB_NUM_PMP_ENTRIES 16
#define UDB_NUM_USABLE_PMP_ENTRIES 16
#define UDB_PMP_GRANULARITY 2
#define UDB_PMP_NAPOT_SUPPORTED
#define UDB_PMP_TOR_SUPPORTED

/*------------------------------------------------------------------------------
 * 3. mtvec/stvec：BASE 4 B 对齐；MODE 0(Direct)/1(Vectored) 均实现
 *    依据：csr_file.v:431-436（MODE ∈ {0,1} 的 WARL）、:291-295（BASE 4 B 对齐）。
 *    env 侧遇"两者都支持"时优先 MODE=0（rvtest_trap_handler.h:1124）。
 *----------------------------------------------------------------------------*/
#define UDB_MTVEC_BASE_ALIGNMENT_DIRECT   4
#define UDB_MTVEC_BASE_ALIGNMENT_VECTORED 4
#define UDB_MTVEC_MODES_0
#define UDB_MTVEC_MODES_1

/*------------------------------------------------------------------------------
 * 4. 计数器与 CSR 能力
 *    · Zicntr：mcycle/minstret(+*h) 为软件可写 MRW，cycle/instret 为 URO 视图
 *      （csr_file.v:387-395、:592-599）；
 *    · time CSR 由核内实现（同处）⇒ 不需要 RVTEST_EMULATE_TIME_CSR 模拟路径
 *      （derived_config.h:14 由 ZICNTR_SUPPORTED + UDB_TIME_CSR_IMPLEMENTED 决定）。
 *----------------------------------------------------------------------------*/
#define ZICNTR_SUPPORTED
#define UDB_TIME_CSR_IMPLEMENTED

/*------------------------------------------------------------------------------
 * 5. ISA 扩展 / 特权模式（本核 2A 的真实能力，core_params.vh §1/§10）
 *    · I/M/A/F/D/C + Zicsr/Zifencei/Zicntr/Zicbom；
 *    · M/S/U 特权级；Sv32（satp.MODE=1 / 两级页表 / 4 MiB 超级页 / ASID 9 bit）。
 *    · **Sv32 已声明**（2026-09 恢复）—— 声明前提已全部达成：
 *        ① `sfence.vma` 已译码（decoder.v §4.9；rs1=VA、rs2=ASID，rd≠0 ⇒ 非法）；
 *        ② W 级提交拍执行冲刷：TLB 粒度失效（tlb.v L3）+ L1D 全阵列失效
 *           + L1I 全阵列失效 + 年轻指令作废与取指重定向（core_top.v §9.3/§12.3.1）；
 *        ③ 取指侧 Sv32 翻译已接通（tlb.v 第二查询口；PTW 由 M 级引擎串行复用，
 *           见 core_top.v §9.4.1）；
 *        ④ PTE A/D 位 = **Svade 口径**（软件管理，硬件不置位）——与参考模型 Spike
 *           在 menvcfg.ADUE=0（本核 spike_isa 串未含 svadu）下的行为一致。
 *    · 声明后的影响（务必整组重跑，不可只跑增量）：
 *        tests/env/utils.h:64-69 的 `RVTEST_SFENCE_VMA_IF_SUPPORTED` 会在**每个**用例
 *        的启动码里插入 `sfence.vma`（rvtest_setup.h:1181 的 `csrw satp,zero; sfence.vma`
 *        与 rvtest_pmp_macros.h:68 的 PMP 背景区 sfence.vma）⇒ 所有用例的二进制都变。
 *    · F/D 相关宏（F_SUPPORTED）按任务书要求写在 rvmodel_macros.h 里。
 *----------------------------------------------------------------------------*/
#define ZICSR_SUPPORTED
#define ZIFENCEI_SUPPORTED
#define ZICBOM_SUPPORTED
#define S_SUPPORTED
#define U_SUPPORTED
#define SV32_SUPPORTED

/*------------------------------------------------------------------------------
 * 6. 明确**不**支持（保持未定义即可；在此登记以免后人"顺手加宏"）
 *    · Zicboz（cbo.zero）/ Zicbop（预取提示）/ Zihintpause / Zba..Zbs / 向量 等；
 *    · Sv39/Sv48/Sv57（RV32 无这些分页模式）；
 *    · Smstateen / Sstc / Smepmp / Ssdbltrp / Sscofpmf / Smrnmi 等 1P12+/1P13 特性；
 *    · Zfinx / Zca / Zcd / Zcf / Zcmop（2A 不声明）。
 *    ⇒ 对应测试必须进 sim/arch_test/exclude.list（run.sh 会强制排除清单生效）。
 *----------------------------------------------------------------------------*/
#endif /* RVTEST_CONFIG_H */
