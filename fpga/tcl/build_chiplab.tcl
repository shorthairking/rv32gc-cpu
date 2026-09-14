#==============================================================================
# build_chiplab.tcl —— 把 RV32-GC 核加进 chiplab 平台工程并跑综合/实现/bitstream
#
# 关键事实（本项目实测，见 ../README.md §2）：
#   · 平台顶层 `chip/soc_demo/loongson/soc_top.v:723` 例化的模块名就是 **`core_top`**，
#     其 48 个端口（aclk/aresetn/intrpt + AXI4 + debug 组）与我们的 `rtl/top/core_top.v` **逐字一致**
#     ⇒ 不需要任何 soc_top 副本或端口适配，工程里解析到我们的 core_top 即可。
#   · chiplab 仓库**不含参考核**（文档明说"添加处理器核代码后可直接综合"）⇒ 不存在"同名模块冲突"。
#   · 平台用了 Vivado IP（MIG DDR3 / clk_pll_33 / axi_interconnect / confreg …），因此**必须复用现成 .xpr**，
#     不要从零 create_project（否则要重建全部 IP）。
#
# 用法：
#   vivado -mode batch -notrace -source fpga/tcl/build_chiplab.tcl \
#          -tclargs <chiplab根> <本仓库根> <工程xpr> <输出目录> [jobs]
#   例：
#   vivado -mode batch -notrace -source fpga/tcl/build_chiplab.tcl \
#          -tclargs /home/shorthair/dsh/rv32-cpu/chiplab /home/shorthair/dsh/rv32-cpu/rv32gc-cpu \
#                   /home/shorthair/dsh/rv32-cpu/chiplab/fpga/loongson/2023.2/system_run.xpr \
#                   /home/shorthair/dsh/rv32-cpu/rv32gc-cpu/fpga/out 8
#
# 注意：33 MHz 时钟接线需先打平台补丁（fpga/patch_platform_33mhz.sh --apply），否则核会跑 50 MHz
#       （功能上仍能跑，但与我们验收口径的 33 MHz 不一致）。
#==============================================================================

if { $argc < 4 } {
    puts "用法: -tclargs <chiplab根> <本仓库根> <工程xpr> <输出目录> \[jobs\]"
    exit 1
}
set CHIPLAB  [lindex $argv 0]
set OURREPO  [lindex $argv 1]
set XPR      [lindex $argv 2]
set OUTDIR   [lindex $argv 3]
set JOBS     [expr {$argc >= 5 ? [lindex $argv 4] : 8}]

file mkdir $OUTDIR
puts "== build_chiplab: CHIPLAB=$CHIPLAB OURREPO=$OURREPO JOBS=$JOBS =="

#--------------------------------------------------------------- 打开现成工程
if { ![file exists $XPR] } { puts "ERROR: 工程不存在: $XPR"; exit 1 }
open_project $XPR
puts "== 工程已打开: [current_project] =="
puts "== part = [get_property PART [current_project]] =="

#--------------------------------------------------------------- 【本机实测必做】切 Manual Compile Order
# 现象（Vivado 2023.2 @ Ubuntu 24.04，本机实测）：工程模式的**自动层次引擎失效** ——
#   CRITICAL WARNING [filemgmt 20-730] Could not find a top module in the fileset sources_1
#   ERROR [Common 17-53] Unable to launch Synthesis run. No Verilog or VHDL sources found in project
# 即使显式 set_property top 也会被判 "can not be validated"。同一台机上**非工程模式**
# （read_verilog + synth_design）完全正常，说明是工程层次引擎（子进程）本身的问题。
# 绕过：按 Vivado 自己给的提示切到 Manual Compile Order（source_mgmt_mode None），
# 之后显式 set_property top 生效，synth/impl 均实测可跑（见 fpga/README §2.7）。
set_property source_mgmt_mode None [current_project]
puts "== source_mgmt_mode = [get_property source_mgmt_mode [current_project]]（应为 None=Manual）=="

#--------------------------------------------------------------- 加入本核 RTL
# 头文件（`include "rv32gc_defs.vh"）：必须放进 verilog_header 文件集
set HDL_DIRS [list "$OURREPO/rtl/pkg" "$OURREPO/rtl/decode" "$OURREPO/rtl/exec" "$OURREPO/rtl/frontend" \
                   "$OURREPO/rtl/mem" "$OURREPO/rtl/csr" "$OURREPO/rtl/mmu" "$OURREPO/rtl/bus" \
                   "$OURREPO/rtl/top"]
set VH [glob -nocomplain "$OURREPO/rtl/pkg/*.vh"]
if { [llength $VH] > 0 } {
    add_files -norecurse -fileset sources_1 $VH
    set_property file_type {Verilog Header} [get_files -of [get_filesets sources_1] *.vh]
    set_property is_global_include true [get_files -of [get_filesets sources_1] *.vh]
}
set VFILES {}
foreach d $HDL_DIRS { foreach f [glob -nocomplain "$d/*.v"] { lappend VFILES $f } }
puts "== 待加入本核 RTL: [llength $VFILES] 个 .v =="
add_files -norecurse -fileset sources_1 $VFILES
catch { update_compile_order -fileset sources_1 }

# 顶层：平台自己的 soc_top；Manual 模式下必须**显式**再设一次（自动引擎不再接管）
set_property top soc_top [current_fileset]
set TOP [get_property top [current_fileset]]
puts "== 顶层模块 = $TOP（应为 soc_top）="
if { $TOP ne "soc_top" } { puts "ERROR: 顶层不是 soc_top（Manual 模式下 top 未生效）"; exit 1 }

#--------------------------------------------------------------- IP 版本升级（工程由旧版 Vivado 建立时必须）
# 现象：不升级时 OOC run 会被标 locked、`module 'clk_pll_33' not found`（本项目实测：2023.2 建的工程
# 用 2025.2 打开会这样）。upgrade_ip 会按当前 Vivado 版本重新生成 IP 产物。
set locked [get_ips -quiet]
if { [llength $locked] > 0 } {
    puts "== 升级 [llength $locked] 个 IP 到当前 Vivado 版本 =="
    upgrade_ip $locked
    generate_target all $locked
}

#--------------------------------------------------------------- 综合
# 先重置**所有** run（含 IP 的 OOC run）：上一轮失败的 run 不重置会直接拒绝再次 launch
foreach r [get_runs -quiet] { catch { reset_run $r } }
reset_run synth_1
launch_runs synth_1 -jobs $JOBS
wait_on_run synth_1
if { [get_property PROGRESS [get_runs synth_1]] ne "100%" } { puts "ERROR: 综合失败，见 $OUTDIR/synth.log"; exit 1 }
open_run synth_1
report_utilization        -hierarchical -file $OUTDIR/util_synth.rpt
report_utilization        -file $OUTDIR/util_synth_flat.rpt
report_timing_summary     -delay_type max -file $OUTDIR/timing_synth.rpt
# BRAM 推断判据（见 ../README.md §2.3）：数据阵列应为 RAMB36/RAMB18，不应落在 LUTRAM
set bram [llength [get_cells -hier -filter {PRIMITIVE_TYPE =~ BMEM.*.*}]]
puts "== SYNTH: 存储单元原语数（应含 L1I/L1D 阵列的 RAMB*）= $bram =="

#--------------------------------------------------------------- 实现 + bitstream
launch_runs impl_1 -to_step write_bitstream -jobs $JOBS
wait_on_run impl_1
if { [get_property PROGRESS [get_runs impl_1]] ne "100%" } { puts "ERROR: 实现失败，见 $OUTDIR/impl.log"; exit 1 }
open_run impl_1
report_timing_summary          -file $OUTDIR/timing_impl.rpt
report_utilization             -file $OUTDIR/util_impl.rpt
report_cdc                     -file $OUTDIR/cdc.rpt
set wns [get_property SLACK [get_timing_paths -delay_type max]]
puts "== IMPL: WNS = $wns ns（33 MHz 周期 30.303 ns ⇒ 要求 ≥ 0）="
set bit [glob -nocomplain "[get_property DIRECTORY [get_runs impl_1]]/*.bit"]
puts "== bitstream: $bit =="
puts "== BUILD_CHIPLAB: DONE =="
