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
#define RVMODEL_ACCESS_FAULT_ADDRESS 0x00000000
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
