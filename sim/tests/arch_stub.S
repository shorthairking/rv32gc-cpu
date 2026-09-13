/* arch_stub.S —— 0x0 处跳转桩：把控制权交给 arch-test 入口 rvtest_entry_point(0x8000_2000)
 *
 * 注意：桩必须铺满至少一整条 32 B 取指行。本核在 JALR 于 EX 解析之前会顺序预取
 * 0x8.. 的取指行；若镜像到 0x8 就没有数据（mem 模型返回 x），取指行的后续字节是 x，
 * 会经 ilen 传播把 PC 污染成 x。真实硬件内存不会返回 x，但仿真里必须显式补齐。
 * 末尾的 nop 不会被提交（JALR 重定向后即被清空），仅用于把整行填成确定值。
 */
    .section .text
    .globl _start
_start:
    lui  t0, 0x80002          /* t0 = 0x8000_2000 */
    jr   t0
    .rept 16
    nop
    .endr
