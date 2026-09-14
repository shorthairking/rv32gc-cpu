#==============================================================================
# synth_core_only.tcl —— **本核独立**综合/实现（不需要平台的缺失 IP）
#
# 目的：整板综合被平台缺件挡住（chiplab 的 axi_2x1_mux 自定义 IP 源缺失）期间，
#       先把计划 §11.2 的两个未知回答掉：
#         ① 33 MHz（周期 30.303 ns）下本核 WNS 是否 ≥ 0；
#         ② L1I/L1D 的 32 B 阵列是否被推断成 Block RAM（而非分布式 RAM）。
# ⚠ 口径：核级数据，**不含**平台互连/DDR/UART/NAND，不能替代整板时序判据。
#
# 用法：
#   vivado -mode batch -notrace -source fpga/tcl/synth_core_only.tcl \
#          -tclargs <本仓库根> <输出目录> [part] [period_ns]
#   例：-tclargs /home/shorthair/dsh/rv32-cpu/rv32gc-cpu /home/shorthair/dsh/rv32-cpu/rv32gc-cpu/fpga/out xc7a200tfbg676-2 30.303
#==============================================================================
if { $argc < 2 } { puts "用法: -tclargs <本仓库根> <输出目录> \[part\] \[period_ns\]"; exit 1 }
set OURREPO [lindex $argv 0]
set OUTDIR  [lindex $argv 1]
set PART    [expr {$argc >= 3 ? [lindex $argv 2] : "xc7a200tfbg676-2"}]
set PERIOD  [expr {$argc >= 4 ? [lindex $argv 3] : "30.303"}]

file mkdir $OUTDIR
set PROJDIR "$OUTDIR/proj_core_only"
create_project -force core_only $PROJDIR -part $PART
# 【本机实测必做】Vivado 2023.2 @ Ubuntu 24.04 的工程模式自动层次引擎失效（详见 build_chiplab.tcl 顶部注释），
# 必须切 Manual Compile Order 并显式设 top，否则报 "No Verilog or VHDL sources found in project"。
set_property source_mgmt_mode None [current_project]

# 头文件 + 本核 RTL + 综合包装
set VH [glob -nocomplain "$OURREPO/rtl/pkg/*.vh"]
if { [llength $VH] > 0 } {
    add_files -norecurse $VH
    set_property file_type {Verilog Header} [get_files *.vh]
    set_property is_global_include true [get_files *.vh]
}
set VFILES {}
foreach d {pkg decode exec frontend mem csr mmu bus top} {
    foreach f [glob -nocomplain "$OURREPO/rtl/$d/*.v"] { lappend VFILES $f }
}
lappend VFILES "$OURREPO/fpga/rtl/core_top_synth_wrap.v"
puts "== 核级综合：RTL=[llength $VFILES] 个 .v，part=$PART，周期=$PERIOD ns =="
add_files -norecurse $VFILES
set_property top core_top_synth_wrap [current_fileset]
catch { update_compile_order -fileset sources_1 }
puts "== top = [get_property top [current_fileset]]，nverilog = [llength [get_files -of [get_filesets sources_1] *.v]] =="

# 33 MHz 主时钟约束（含 I/O 延迟的简化模型）
set xdc "$OUTDIR/core_only.xdc"
set fh [open $xdc w]
puts $fh "create_clock -period $PERIOD -name aclk \[get_ports aclk\]"
puts $fh "set_input_delay  -clock aclk 2.0 \[get_ports {aresetn intrpt}\\]"
puts $fh "set_false_path -from \[get_ports aresetn\]"
close $fh
add_files -fileset constrs_1 -norecurse $xdc

# 综合
launch_runs synth_1 -jobs 8
wait_on_run synth_1
if { [get_property PROGRESS [get_runs synth_1]] ne "100%" } { puts "ERROR: 核级综合失败（看 $OUTDIR/../proj_core_only/*.runs/synth_1/runme.log）"; exit 1 }
open_run synth_1
report_utilization -file "$OUTDIR/util_core_synth.rpt"
# BRAM 推断判据：打印存储原语分布（RAMB36/RAMB18 应为 L1I/L1D 阵列；U/RAM 表示分布式 RAM）
set bram36 [llength [get_cells -quiet -hier -filter {PRIMITIVE_TYPE =~ BMEM.*.RAMB36*}]]
set bram18 [llength [get_cells -quiet -hier -filter {PRIMITIVE_TYPE =~ BMEM.*.RAMB18*}]]
set lutram [llength [get_cells -quiet -hier -filter {PRIMITIVE_TYPE =~ BMEM.*.LUTRAM*}]]
puts "== CORE_SYNTH: RAMB36=$bram36 RAMB18=$bram18 LUTRAM=$lutram =="

# 实现
launch_runs impl_1 -jobs 8
wait_on_run impl_1
if { [get_property PROGRESS [get_runs impl_1]] ne "100%" } { puts "ERROR: 核级实现失败"; exit 1 }
open_run impl_1
report_timing_summary -file "$OUTDIR/timing_core_impl.rpt"
set wns [get_property SLACK [get_timing_paths -delay_type max]]
set whs [get_property SLACK [get_timing_paths -delay_type min]]
puts "== CORE_IMPL: WNS=$wns ns  WHS=$whs ns（周期 $PERIOD ns ⇒ WNS ≥ 0 为过）=="
puts "== SYNTH_CORE_ONLY: DONE（报告在 $OUTDIR）=="
