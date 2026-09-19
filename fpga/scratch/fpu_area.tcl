#==============================================================================
# fpga/scratch/fpu_area.tcl —— 临时测量脚本（M4 面积风险量化，非交付物）
# 作用：只综合 fpu 子树，量出 FPU 行为模型的 LUT/FF/BRAM/DSP 占用，
#       判断 xc7a200t（134600 LUT / 269200 FF）能否容纳整核。
# 用法：./fpga/run_vivado_batch.sh fpga/scratch/fpu_area.tcl [top]
#==============================================================================
set SCRIPT_DIR [file normalize [file dirname [info script]]]
set PROJ_ROOT  [file normalize [file join $SCRIPT_DIR .. ..]]
set OUT_DIR    [file join $PROJ_ROOT fpga out]
file mkdir $OUT_DIR

set TOP "fpu"
if {[llength $argv] >= 1 && [lindex $argv 0] ne ""} { set TOP [lindex $argv 0] }
set PART "xc7a200tfbg676-2"

set pkg_files [lsort [glob -nocomplain [file join $PROJ_ROOT rtl pkg *.vh]]]
set rtl_files [lsort [glob -nocomplain [file join $PROJ_ROOT rtl * *.v]]]
set inc_dirs  [list [file join $PROJ_ROOT rtl pkg] [file join $PROJ_ROOT rtl] $PROJ_ROOT]

puts "== fpu_area.tcl: TOP=$TOP 读取 RTL ×[llength $rtl_files]"
read_verilog $pkg_files
read_verilog $rtl_files

set t0 [clock seconds]
synth_design -top $TOP -part $PART -verilog_define RV32GC_USE_VIVADO_IP -include_dirs $inc_dirs
puts "== fpu_area.tcl: synth_design 用时 [expr {[clock seconds] - $t0}] s"

report_utilization -file [file join $OUT_DIR "scratch_${TOP}_utilization.rpt"]
report_utilization -hierarchical -file [file join $OUT_DIR "scratch_${TOP}_utilization_hier.rpt"]
puts "== fpu_area.tcl 完成：报告 $OUT_DIR/scratch_${TOP}_utilization.rpt"
exit 0
