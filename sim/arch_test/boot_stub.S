/*==============================================================================
 * sim/arch_test/boot_stub.S —— ACT4 用例的复位跳转桩（.boot @ 0x1C00_0000）
 *------------------------------------------------------------------------------
 * 项目 : rv32gc-cpu（阶段二 2A；docs/design/08-baseline-5stage.md §8.2）
 *
 * 为什么存在：
 *   本核复位取指 = `RV32GC_RESET_PC = 0x1C00_0000（平台无 boot ROM，SPI XIP 主窗口），
 *   而 arch-test 镜像链接在仿真布局 0x8000_0000。二者之间必须有一条显式跳转。
 *   该桩**链接进 ELF 本体**（而不是由 TB 注入内存），保证 DUT 仿真与 Spike 参考模型
 *   跑的是逐字节相同的镜像、同样的入口 —— 这是两侧签名可比性的前提。
 *
 * 口径：
 *   · 只依赖 lui + jalr 两条 RV32I 指令（无压缩、无 PC 相对重定位问题）；
 *   · x5 是 rvtest 保留寄存器之外的安全暂存（rvtest_entry_point 会自行初始化状态）；
 *   · 目标 = rvtest_entry_point = TEST_BASE = 0x8000_0000（link.ld 的 .text.init 首址）。
 *============================================================================*/
    .section .boot, "ax", @progbits
    .globl _boot
    .type  _boot, @function
_boot:
    lui     x5, 0x80000          /* x5 = 0x8000_0000（TEST_BASE）*/
    jalr    x0, 0(x5)            /* 跳到 rvtest_entry_point */
    .size   _boot, . - _boot
