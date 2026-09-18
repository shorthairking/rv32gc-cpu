#==============================================================================
# fpga/soc_up.xdc —— core_top 综合/实现约束（平台口径的本地只读拷贝，08 §3.2）
#==============================================================================
# 来源：chiplab/fpga/loongson/soc_up.xdc（平台整板约束；**只读引用，不修改平台仓库**）
#
# 平台口径（AGENT.md §3.1、docs/design/08 §3）：
#   * 板级时钟 100 MHz（平台 XDC：create_clock -period 10.000 -name clk [get_ports clk]）；
#   * 上板 cpu_clk = uncore_clk = clk_pll_33 的 clk_out2 = **33 MHz**（同域、无 CDC）；
#   * core_top 是平台 soc_top 内部例化的核（48 端口契约）⇒ **只有一个时钟域 aclk**。
#
# 本文件只保留对 core_top 有意义的部分：
#   * 平台 XDC 里的 PACKAGE_PIN / IOSTANDARD / CLOCK_DEDICATED_ROUTE 全部是 soc_top
#     **引脚级**约束；core_top 是内部模块、其端口不落引脚 ⇒ 拷贝过来会因端口不存在
#     而报错（`get_ports` 空对象）⇒ 只保留时钟口径（本条即"复用平台口径"的落地方式）。
#   * 单时钟域无 CDC ⇒ 平台 XDC 的跨时钟 set_false_path 段在核内不适用（无对象）。
#   * I/O 延迟（set_input_delay/set_output_delay）不设：core_top 的 AXI/中断端口接平台
#     内部逻辑（非引脚），M4 只验收核内逻辑时序；M5 上板由平台整板约束负责 I/O。
#
# ★ 时钟周期由 fpga/tcl/synth.tcl 传入（占位符 __CLK_PERIOD_NS__）：
#     默认 16.667 ns = **60 MHz**（08 §M4 判据② 的验收时钟）；
#     余量参考跑 10.0（100 MHz，见任务书"目标 100 MHz"）。
#   M5 上板口径 33 MHz（30.303 ns）只需 ≤ 已收敛频率，不必单独重综合。
#
# ★ 为什么必须写在 synth_design **之前**读入（M4 实测坑⑦）：
#   非工程模式下若 create_clock 在 synth_design **之后**下发，综合阶段"无时钟"⇒
#   Vivado 不做时序驱动优化（不按路径延时重构/复制/平衡），WNS 会显著偏差。
#   ⇒ synth.tcl 先把本文件（替换周期占位符）落到 fpga/out/ 再 read_xdc，然后才
#     synth_design。实现阶段（impl.tcl）从 post_synth.dcp 继承同一份约束。
#==============================================================================

create_clock -period __CLK_PERIOD_NS__ -name aclk [get_ports aclk]
