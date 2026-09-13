// Minimal rvmodel_macros.h for a custom RV32GC RTL DUT.
// Replace HALT/IO with your testbench's mechanism (e.g. a custom tohost MMIO
// register, a magic address, or a simulator $finish hook).
#ifndef _RVMODEL_MACROS_H
#define _RVMODEL_MACROS_H

#define STANDARD_SM_SUPPORTED

// Data section the framework expects the DUT to provide (tohost/fromhost are
// the conventional HTIF-style termination channel; keep them even if unused).
#define RVMODEL_DATA_SECTION      \
  .pushsection .tohost,"aw",@progbits; \
  .balign 8; .global tohost; tohost: .dword 0; \
  .balign 8; .global fromhost; fromhost: .dword 0; \
  .popsection;

// ---- Termination: write 1 (pass) / 3 (fail) to tohost then spin ----
#define RVMODEL_HALT_PASS   \
  li x1, 1                 ;\
  la t0, tohost            ;\
  write_tohost_pass:       ;\
    sw x1, 0(t0)           ;\
    sw x0, 4(t0)           ;\
  self_loop_pass:          ;\
    j self_loop_pass       ;

#define RVMODEL_HALT_FAIL   \
  li x1, 3                 ;\
  la t0, tohost            ;\
  write_tohost_fail:       ;\
    sw x1, 0(t0)           ;\
    sw x0, 4(t0)           ;\
  self_loop_fail:          ;\
    j self_loop_fail       ;

// ---- Console IO: PC16550-compatible UART at 0x10000000 ----
.EQU UART_BASE_ADDR, 0x1FE001E0   /* chiplab 16550，1 字节寄存器间距 */
.EQU UART_THR, (UART_BASE_ADDR + 0)
.EQU UART_LCR, (UART_BASE_ADDR + 3)
.EQU UART_LSR, (UART_BASE_ADDR + 5)

#define RVMODEL_IO_INIT(_R1, _R2, _R3) \
  uart_init:            ;\
    li _R1, UART_LCR    ;\
    li _R2, 3           ;\
    sb _R2, 0(_R1)      ;

#define RVMODEL_IO_WRITE_STR(_R1, _R2, _R3, _STR_PTR) \
1:                          ;\
  lbu _R1, 0(_STR_PTR)      ;\
  beqz _R1, 3f              ;\
2:                          ;\
  li _R2, UART_LSR          ;\
4:                          ;\
    lbu _R3, 0(_R2)         ;\
    andi _R3, _R3, 0x20     ;\
    beqz _R3, 4b            ;\
  li _R2, UART_THR          ;\
  sb _R1, 0(_R2)            ;\
  addi _STR_PTR, _STR_PTR, 1;\
  j 1b                      ;\
3:

// ---- Misc required macros ----
// RVMODEL_ACCESS_FAULT_ADDRESS 必须选"本平台一定报访问错误"的 PA（ACT4 用它构造
// store/load/fetch access fault 用例；见 riscv-arch-test/tests/env/check_defines.h:53）。
// ⚠ 不能再用 0x0：本平台 `0x0000_0000–0x07FF_FFFF` 是 DDR/主存（docs/kb/01-chiplab-platform.md:45），
//    仿真里 mem_lo 覆盖 0x0–0x00FF_FFFF，且 0x0 还铺着复位跳转桩（sim/tests/arch_stub.S，
//    0x0–0x4B 全是 nop）——对 0x0+16 的 store/load/fetch 全部会"成功"（实测：sv32_exceptions_Smode
//    的 Case 3 直接执行了桩代码并跳回 0x80002000，整条陷阱序错位）。
// 选 0x4000_0000：落在低端主存窗口与 0x8000_0000 RAM 之间的空洞，仿真从设备 region_of()=R_NONE
//    → SLVERR（sim/tb/sim_axi_slave.v:179,307,463），Spike 默认 `-m 2048`（0x8000_0000 起）同样未映射
//    ⇒ 两侧都必然报 access fault（参考签名与 DUT 期望一致，不是"放宽"用例）。
#define RVMODEL_ACCESS_FAULT_ADDRESS 0x40000000
#define RVMODEL_INTERRUPT_LATENCY 10
#define RVMODEL_TIMER_INT_SOON_DELAY 1000
#define RVMODEL_MAX_CYCLES_PER_TIMER_TICK 1

// CLINT (mtime/mtimecmp/msip) - required if any interrupt/mtime test is built
#define CLINT_BASE_ADDRESS 0x800F0000   /* 阶段 2A：CLINT 未实现，指向已映射 scratch（Linux 阶段改回 0x1F000000） */
#define RVMODEL_MSIP_ADDRESS (CLINT_BASE_ADDRESS + 0x0)
#define RVMODEL_MTIMECMP_ADDRESS 0x800F4000
#define RVMODEL_MTIME_ADDRESS 0x800FBFF8

// External interrupts: required by check_defines.h when S_SUPPORTED is set.
// Point these at your interrupt controller if you have one.
#define RVMODEL_SET_MEXT_INT(_R1, _R2)  \
  li _R1, 7                            ;\
  li _R2, 0x0c000000                   ;\
  sw _R1, (4*10)(_R2)                  ;
#define RVMODEL_CLR_MEXT_INT(_R1, _R2)  \
  li _R2, 0x0c200004                   ;\
  lw _R1, 0(_R2)                       ;\
  sw _R1, 0(_R2)                       ;
#define RVMODEL_SET_SEXT_INT(_R1, _R2)  \
  li _R1, 7                            ;\
  li _R2, 0x0c000000                   ;\
  sw _R1, (4*10)(_R2)                  ;
#define RVMODEL_CLR_SEXT_INT(_R1, _R2)  \
  li _R2, 0x0c201004                   ;\
  lw _R1, 0(_R2)                       ;\
  sw _R1, 0(_R2)                       ;

#endif // _RVMODEL_MACROS_H
