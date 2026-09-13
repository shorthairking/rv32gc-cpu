//=============================================================================
// cbo_directed.S —— CBO（Zicbom/Zicboz）定向自测，补 arch-test 覆盖不到的"真实副作用"
//
// 为什么需要它：arch-test 的 Zicboz/SvZicbo 用例都是**陷阱/许可**类（cbo.zero 在被许可
// 检查判非法时被跳过，或在 U/S 模式因 menvcfg/senvcfg 许可不足报非法指令），非特权
// rv32i/Zicboz 那例在 U 模式下也只会走非法指令路径 —— **没有任何用例检查 32 字节块真的被清零**。
// 本程序在 M 模式（CBO 恒可执行）直接验证：
//   ① 对齐地址 cbo.zero：整块 8 个 4 字节字 = 0，块外不动；
//   ② 操作数落在块内偏移 0x17：块基址 = addr & ~31，仍整块清零；块外哨兵不变；
//   ③ cbo.clean 不改内存；其后的 amoswap.w 只能改自己那 4 字节（回归"块内写循环标志残留"）。
// 通过 tohost(0x8000_1000)=1 / =3 报 PASS/FAIL。
//
// 运行方式（会话实测，RTL = 本仓库工作区）：
//   /opt/riscv/bin/riscv32-unknown-linux-gnu-gcc -march=rv32imac_zicsr_zifencei_zicbom_zicboz \
//       -mabi=ilp32 -nostdlib -nostartfiles -T<一个小 link.ld，. = 0x80000000> \
//       -Wl,--no-warn-rwx-segments sim/tests/cbo_directed.S -o /tmp/cbodir.elf
//   objcopy -O verilog --verilog-data-width=1 --change-addresses=-0x80000000 /tmp/cbodir.elf /tmp/hi.hex
//   # mem_lo 放 0x0 跳转桩：lui t0,0x80000 ; jr t0（字节 b7 02 00 80 67 80 02 00）
//   然后 vvp <tb_smoke 或任意 core_top+sim_axi_slave TB 的 vvp> \
//       +MEM_LO_INIT=/tmp/lo.hex +MEM_HI_INIT=/tmp/hi.hex +maxcyc=5000
//   实测输出：`[dump] TOHOST=1 @cyc=2263` 且 0x80008000/0x80008040 两块全 0、
//   0x80008060 哨兵 0x77777777 不变、0x80008088/0x8c 在 amoswap 后仍为 0x33333333。
//=============================================================================
// cbodir.S —— CBO 定向自测（M 模式；不经 arch-test 框架）
// 1) cbo.zero 在 **32B 对齐** 地址：整块 8 个字必须为 0，块外不得改动
// 2) cbo.zero 在 **块内偏移 0x17** 的地址：块基址 = addr & ~31，仍整块清零
// 3) cbo.clean 不得写内存；紧跟的 amoswap 必须只改自己那 4 字节（回归 m_cbo_zero_q 残留隐患）
// 4) 通过 tohost(0x80001000) = 1 表示 PASS、3 表示 FAIL
#define TOHOST 0x80001000
.section .text
.globl _start
_start:
  lui sp, 0x80008
  addi sp, sp, 0x100          # sp = 0x80008100（安全栈顶）

  # ---- 用已知模式填 96 字节（3 个块）----
  li t0, 0x80008000
  li t1, 0
1:
  slli t2, t1, 4
  ori  t2, t2, 0x5A5
  slli t3, t1, 1
  addi t3, t3, 1
  xor  t2, t2, t3
  sw   t2, 0(t0)
  addi t0, t0, 4
  addi t1, t1, 1
  li   t4, 24
  blt  t1, t4, 1b

  # ---- 1) 对齐 cbo.zero ----
  li a0, 0x80008000
  cbo.zero (a0)
  li t0, 0x80008000
  li t1, 8
2:
  lw t2, 0(t0)
  bnez t2, fail
  addi t0, t0, 4
  addi t1, t1, -1
  bnez t1, 2b
  # 块外（第二个块）必须保持非零
  li t0, 0x80008020
  lw t2, 0(t0)
  beqz t2, fail

  # ---- 2) 非对齐操作数（块内偏移 0x17）→ 清零整个 0x80008040 块 ----
  li t0, 0x80008040
  li t1, 0x11111111
  sw t1, 0(t0)
  sw t1, 4(t0)
  sw t1, 8(t0)
  sw t1, 12(t0)
  sw t1, 16(t0)
  sw t1, 20(t0)
  sw t1, 24(t0)
  sw t1, 28(t0)
  li t0, 0x80008060          # 块外哨兵（必须保持不变）
  li t1, 0x77777777
  sw t1, 0(t0)
  li a0, 0x80008057          # 块内偏移 0x17
  cbo.zero (a0)
  li t0, 0x80008040
  li t1, 8
3:
  lw t2, 0(t0)
  bnez t2, fail
  addi t0, t0, 4
  addi t1, t1, -1
  bnez t1, 3b
  # 该块后面一个字（0x80008060）必须还是哨兵值
  li t0, 0x80008060
  lw t2, 0(t0)
  li t3, 0x77777777
  bne t2, t3, fail

  # ---- 3) cbo.clean 无副作用 + 之后 amoswap 必须只改 4 字节 ----
  li t0, 0x80008080
  li t1, 0x22222222
  sw t1, 0(t0)
  li t1, 0x33333333
  sw t1, 4(t0)
  sw t1, 8(t0)
  sw t1, 12(t0)
  li a0, 0x80008082          # 非对齐操作数（clean 无对齐要求）
  cbo.clean (a0)
  li t0, 0x80008084
  lw t2, 0(t0)
  li t3, 0x33333333
  bne t2, t3, fail           # clean 不得改写内存
  li t0, 0x80008084
  li a1, 0xABCD1234
  amoswap.w a2, a1, (t0)     # 若 CBO 的写循环标志残留，这里会继续写 7 个字 0
  li t0, 0x80008084
  lw t2, 0(t0)
  li t3, 0xABCD1234
  bne t2, t3, fail
  li t0, 0x80008088
  lw t2, 0(t0)
  li t3, 0x33333333
  bne t2, t3, fail           # amoswap 后的下一个字不得被写成 0
  li t0, 0x8000808c
  lw t2, 0(t0)
  bne t2, t3, fail

  # ---- PASS ----
  li t3, TOHOST
  li t4, 1
  sw t4, 0(t3)
4: j 4b

fail:
  li t3, TOHOST
  li t4, 3
  sw t4, 0(t3)
5: j 5b
