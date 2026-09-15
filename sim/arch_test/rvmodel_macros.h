/*==============================================================================
 * sim/arch_test/rvmodel_macros.h —— ACT4 的「DUT 宏」文件（rv32gc-2a）
 *------------------------------------------------------------------------------
 * 项目 : rv32gc-cpu（阶段二 2A 基线核；docs/design/08-baseline-5stage.md §8.2/§8.2.1）
 * 作用 : riscv-arch-test 的 tests/env/** 通过 `#include "rvmodel_macros.h"` 取得
 *        平台相关的：启动/终止（tohost）、控制台 IO、定时器/中断地址、访问故障地址。
 *        文件由 test_config.yaml 的 `dut_include_dir: .` 引入（本目录）。
 *
 * ★ 硬要求（08 §8.2.1(a)，缺一即"全部用例挂死/全挂"，与 DUT 指令功能无关）：
 *   · `STANDARD_SM_SUPPORTED`：不定义 ⇒ tests/env/rvtest_setup.h:935 起整段
 *     M/S 模式初始化（清 mie/mip、关委托、清 pmpcfg/pmpaddr…）被跳过；
 *   · `F_SUPPORTED`：不定义 ⇒ rvtest_setup.h:1331 的 `mstatus.FS = 2'b11`
 *     （MSTATUS_FS=0x6000）被跳过 ⇒ 复位后 FS=Off，rv32if/d 用例在第一条
 *     FP 指令上挂死。
 *   本核确实实现 F/D（core_params.vh §4 RV32GC_FLEN=64）⇒ 两个宏都必须定义。
 *   （`mstatus.FS=Dirty` 由用例自身启动代码写；TB 只载入程序，不代写 CSR。）
 *
 * 其余宏的口径来源：
 *   · 平台 UART/CLINT/PLIC 地址：rtl/pkg/core_params.vh §2/§5（核内 CLINT/PLIC）
 *     与 docs/kb/platform-facts.md §2；UART 用 0x1000_0000 的 NS16550 风格寄存器，
 *     与 Spike 参考模型内建 UART 同址同语义（DUT 仿真侧由
 *     sim/tb/tb_arch_test.sv 的从设备存储体等价实现）——两侧 IO 行为一致，
 *     才保证"签名比对"不被 IO 差异污染。
 *   · 中断时延类常量（RVMODEL_INTERRUPT_LATENCY 等）沿用官方 spike DUT 配置取值，
 *     它们只影响中断用例的时序容忍度；本底座当前范围（rv32i 非特权子集）不涉及，
 *     登记在此以便后续特权用例复用时不至于缺失（未做端到端验证，见交付说明）。
 *============================================================================*/
#ifndef _RVMODEL_MACROS_H
#define _RVMODEL_MACROS_H

/*------------------------------------------------------------------------------
 * 0. DUT 能力声明（08 §8.2.1(a) 硬要求；见文件头说明）
 *----------------------------------------------------------------------------*/
#define STANDARD_SM_SUPPORTED
#define F_SUPPORTED
#define D_SUPPORTED

/*------------------------------------------------------------------------------
 * 1. 数据段：tohost / fromhost（终止握手的唯一载体）
 *    地址由 sim/arch_test/link.ld 固定到 TOHOST_BASE = RAM_ORIGIN+0x000F_F000。
 *    约定（HTIF / Spike 兼容）：
 *      · tohost  写 1 ⇒ PASS（Spike 退出码 0；TB 判定"到达终止点"）
 *      · tohost  写 3 ⇒ FAIL（Spike 退出码非 0；TB 判定"程序自报失败"）
 *    TB 只看这一处信号，不做"猜程序是否跑完"的兜底。
 *----------------------------------------------------------------------------*/
#define RVMODEL_DATA_SECTION \
        .pushsection .tohost,"aw",@progbits;                \
        .balign 8; .global tohost;   tohost:   .dword 0;     \
        .balign 8; .global fromhost; fromhost: .dword 0;     \
        .popsection

/*------------------------------------------------------------------------------
 * 2. 启动
 *    · 本核复位后即处于 M 模式、satp.MODE=Bare、mstatus.FS=Off ⇒ 默认
 *      RVTEST_BOOT_TO_MMODE 路径即可（STANDARD_SM_SUPPORTED 已定义）；
 *    · 不需要 DUT 专属开机动作（无 DDR 控制器初始化、无 PMA 需要软件配置），
 *      故 RVMODEL_BOOT / RVMODEL_BOOT_TO_MMODE 均不定义（保持 env 默认实现）。
 *----------------------------------------------------------------------------*/

/*------------------------------------------------------------------------------
 * 3. 终止（HTIF tohost 写 + 自旋；仿真器/TB 观察到写即停机）
 *----------------------------------------------------------------------------*/
#define RVMODEL_HALT_PASS           \
  li x1, 1                          ;\
  la t0, tohost                     ;\
  write_tohost_pass:                ;\
    sw x1, 0(t0)                    ;\
    sw x0, 4(t0)                    ;\
    j write_tohost_pass             ;

#define RVMODEL_HALT_FAIL           \
  li x1, 3                          ;\
  la t0, tohost                     ;\
  write_tohost_fail:                ;\
    sw x1, 0(t0)                    ;\
    sw x0, 4(t0)                    ;\
    j write_tohost_fail             ;

/*------------------------------------------------------------------------------
 * 4. 控制台 IO：NS16550 风格 UART @ 0x1000_0000（THR=+0、LCR=+3、LSR=+5）
 *    · DUT 仿真侧：sim/tb/tb_arch_test.sv 捕获 THR 写、LSR 恒读 0x20（THRE=1）；
 *    · Spike 侧：内建 NS16550 同址，行为一致；
 *    · 用途 = 打印 RVCP-SUMMARY / 失败诊断串（**不参与**签名比对）。
 *----------------------------------------------------------------------------*/
.EQU UART_BASE_ADDR, 0x10000000
.EQU UART_THR,       (UART_BASE_ADDR + 0)
.EQU UART_LCR,       (UART_BASE_ADDR + 3)
.EQU UART_LSR,       (UART_BASE_ADDR + 5)

/* 控制台初始化：8 bit、1 停止位、无校验 */
#define RVMODEL_IO_INIT(_R1, _R2, _R3)   \
  uart_init:                             ;\
    li _R1, UART_LCR                     ;\
    li _R2, 3                            ;\
    sb _R2, 0(_R1)                       ;

/* 打印以 NUL 结尾的字符串（_STR_PTR 指向该串） */
#define RVMODEL_IO_WRITE_STR(_R1, _R2, _R3, _STR_PTR)                \
1:                                   ;                               \
  lbu _R1, 0(_STR_PTR)               ;/* 取字符 */                   \
  beqz _R1, 3f                       ;/* NUL ⇒ 结束 */               \
2:                                   ;                               \
  li _R2, UART_LSR                   ;                               \
4:                                   ;                               \
    lbu _R3, 0(_R2)                  ;                               \
    andi _R3, _R3, 0x20              ;/* LSR.THRE（bit5）*/           \
    beqz _R3, 4b                     ;/* 等待发送保持寄存器空 */       \
  li _R2, UART_THR                   ;                               \
  sb _R1, 0(_R2)                     ;/* 发送 */                      \
  addi _STR_PTR, _STR_PTR, 1         ;/* 下一字符 */                  \
  j 1b                               ;                               \
3:

/*------------------------------------------------------------------------------
 * 5. 访问故障地址（用于 load/store access fault 类用例；本核无 MMU 映射时
 *    由总线错误响应产生）。0x5000_0000 是 TB 从设备**显式返回 DECERR** 的窗口，
 *    其余未登记地址 TB 返回 0（不产生故障）——避免"未预期地址静默变故障"。
 *----------------------------------------------------------------------------*/
#define RVMODEL_ACCESS_FAULT_ADDRESS 0x50000000

/*------------------------------------------------------------------------------
 * 6. 定时器（核内 CLINT @ 0x1F00_0000，core_params.vh §5；64 bit 低字在低地址）
 *----------------------------------------------------------------------------*/
#define RVMODEL_MTIME_ADDRESS    0x1F00BFF8
#define RVMODEL_MTIMECMP_ADDRESS 0x1F004000

/*------------------------------------------------------------------------------
 * 7. 中断控制器：核内 PLIC @ 0x1F10_0000（core_params.vh §5）
 *    · 源号 1..5 来自平台 intrpt[4:0]（外设引脚），**核内无软件触发源**；
 *      故 SET_*_INT 只能配置优先级/使能/阈值，真正的置位由平台引脚完成。
 *      （当前底座范围不跑中断用例；此处如实登记，避免伪装成"已可用"。）
 *    · MSIP：核内 CLINT 的 msip @ 0x1F00_0000（软件可写 ⇒ 软件中断可用）。
 *----------------------------------------------------------------------------*/
#define RVMODEL_INTERRUPT_LATENCY          4096
#define RVMODEL_TIMER_INT_SOON_DELAY       100
#define RVMODEL_MAX_CYCLES_PER_TIMER_TICK  5000

#define CLINT_BASE_ADDRESS   0x1F000000
#define RVMODEL_MSIP_ADDRESS (CLINT_BASE_ADDRESS + 0x0)

#define PLIC_BASE_ADDRESS    0x1F100000
#define PLIC_ENABLE_ADDRESS  0x1F102000   /* + 4*context：context0=M，context1=S */
#define PLIC_THRESH_ADDRESS  0x1F200000   /* + 4*context */
#define PLIC_CLAIM_ADDRESS   0x1F200004   /* + 4*context（claim/complete 同址）*/
#define PLIC_SENABLE_ADDRESS 0x1F102004   /* S 模式 context = 1 */
#define PLIC_STHRESH_ADDRESS 0x1F200004
#define PLIC_SCLAIM_ADDRESS  0x1F200008

/* M 模式外部中断：置 PLIC 源 1 优先级=7、使能 context0、阈值=0。
 * ★ 真正的中断置位需要平台把 intrpt[1] 拉高（UART 源）；本核内无软件触发源。 */
#define RVMODEL_SET_MEXT_INT(_R1, _R2)   \
  li _R1, 7                              ;\
  li _R2, PLIC_BASE_ADDRESS              ;\
  sw _R1, (4*1)(_R2)                     ;/* 源 1（UART）优先级 */  \
  li _R1, (1 << 1)                       ;\
  li _R2, PLIC_ENABLE_ADDRESS            ;\
  sw _R1, 0(_R2)                         ;/* context0 使能源 1 */    \
  li _R2, PLIC_THRESH_ADDRESS            ;\
  sw zero, 0(_R2)                        ;/* 阈值 0 */

#define RVMODEL_CLR_MEXT_INT(_R1, _R2)   \
  li _R2, PLIC_CLAIM_ADDRESS             ;\
  lw _R1, 0(_R2)                         ;\
  sw _R1, 0(_R2)                         ;/* claim/complete 回写 */  \
  li _R2, PLIC_ENABLE_ADDRESS            ;\
  sw zero, 0(_R2)                        ;/* 关使能 */

/* S 模式外部中断（context 1） */
#define RVMODEL_SET_SEXT_INT(_R1, _R2)   \
  li _R1, 7                              ;\
  li _R2, PLIC_BASE_ADDRESS              ;\
  sw _R1, (4*1)(_R2)                     ;\
  li _R1, (1 << 1)                       ;\
  li _R2, PLIC_SENABLE_ADDRESS           ;\
  sw _R1, 0(_R2)                         ;\
  li _R2, PLIC_STHRESH_ADDRESS           ;\
  sw zero, 0(_R2)                        ;

#define RVMODEL_CLR_SEXT_INT(_R1, _R2)   \
  li _R2, PLIC_SCLAIM_ADDRESS            ;\
  lw _R1, 0(_R2)                         ;\
  sw _R1, 0(_R2)                         ;

#endif /* _RVMODEL_MACROS_H */
