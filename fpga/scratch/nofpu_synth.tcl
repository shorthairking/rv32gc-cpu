#==============================================================================
# fpga/scratch/nofpu_synth.tcl —— 「核内除 FPU 之外」面积/时序归因实验（临时，非交付物）
#==============================================================================
# 用法：./fpga/run_vivado_batch.sh fpga/scratch/nofpu_synth.tcl [period_ns]
# 做法：读 rtl/**/*.v，但**排除 rtl/exec/fpu*.v**，改读 fpga/scratch/nofpu/fpu_stub.v
#       （同端口空实现）⇒ 综合整核，量出非 FPU 部分的 LUT/FF/BRAM/DSP 与 WNS。
# 用途（M4 阻塞项归因）：证明/否证"FPU 行为模型（8192 bit 精确对阶域）是唯一阻塞项"。
# ★ 只读 rtl/**，不修改任何 RTL；产物落 fpga/out/scratch_nofpu_*。
#==============================================================================
set SCRIPT_DIR [file normalize [file dirname [info script]]]
set PROJ_ROOT  [file normalize [file join $SCRIPT_DIR .. ..]]
set OUT_DIR    [file join $PROJ_ROOT fpga out]
set PART       "xc7a200tfbg676-2"
set CLK_NS 16.667
if {[llength $argv] >= 1 && [lindex $argv 0] ne ""} { set CLK_NS [lindex $argv 0] }
file mkdir $OUT_DIR

# ---- 工程（坑⑧：part 必须与 IP 定制 part 一致）----
create_project -in_memory -part $PART
set_property target_language Verilog [current_project]

# ---- RTL（排除 FPU 全部实现文件）----
set rtl_files {}
foreach f [lsort [glob -nocomplain [file join $PROJ_ROOT rtl * *.v]]] {
    if {[string match "*exec/fpu*" $f]} { puts "== 跳过（FPU 实现）：[file tail $f]"; continue }
    lappend rtl_files $f
}
read_verilog [list [file join $PROJ_ROOT rtl pkg rv32_defs.vh] [file join $PROJ_ROOT rtl pkg core_params.vh]]
read_verilog $rtl_files
read_verilog [file join $SCRIPT_DIR nofpu fpu_stub.v]
puts "== nofpu_synth: RTL ×[llength $rtl_files] + fpu_stub"

# ---- IP 流程（坑⑥：read_ip + generate_target + synth_ip）----
read_ip [lsort [glob -nocomplain [file join $PROJ_ROOT fpga ip * *.xci]]]
generate_target {synthesis} [get_ips]
synth_ip [get_ips]

# ---- 约束（坑⑦：XDC 先于 synth_design）----
set src [file join $PROJ_ROOT fpga soc_up.xdc]
set fh [open $src r]; set txt [read $fh]; close $fh
set txt [string map [list "__CLK_PERIOD_NS__" $CLK_NS] $txt]
set dst [file join $OUT_DIR [format "soc_up_%sns.xdc" $CLK_NS]]
set fh [open $dst w]; puts $fh $txt; close $fh
read_xdc $dst
puts "== nofpu_synth: read_xdc $dst"

set inc_dirs [list [file join $PROJ_ROOT rtl pkg] [file join $PROJ_ROOT rtl] $PROJ_ROOT]
set t0 [clock seconds]
if {[catch {
    synth_design -top core_top -part $PART -verilog_define RV32GC_USE_VIVADO_IP -include_dirs $inc_dirs
} err]} {
    puts "RESULT_NOFPU: SYNTH_FAIL —— $err"
    exit 1
}
puts "== nofpu_synth: synth_design 用时 [expr {[clock seconds] - $t0}] s"

report_utilization -file [file join $OUT_DIR "scratch_nofpu_utilization.rpt"]
report_utilization -hierarchical -file [file join $OUT_DIR "scratch_nofpu_utilization_hier.rpt"]
report_timing_summary -file [file join $OUT_DIR "scratch_nofpu_timing_summary.rpt"]
report_timing -delay_type max -sort_by slack -max_paths 20 -nworst 1 -path_type full -input_pins \
              -file [file join $OUT_DIR "scratch_nofpu_timing_paths.rpt"]
set wns "n/a"
catch {set wns [get_property SLACK [get_timing_paths -delay_type max -max_paths 1]]}
set fmax "n/a"
if {[string is double -strict $wns]} { set fmax [format %.2f [expr {1000.0/($CLK_NS - $wns)}]] }
puts "== nofpu_synth: WNS(setup) = $wns ns @ ${CLK_NS}ns ⇒ Fmax ≈ $fmax MHz"
puts "RESULT_NOFPU: SYNTH_OK WNS=$wns FMAX=$fmax"
write_checkpoint -force [file join $OUT_DIR scratch_nofpu_post_synth.dcp]
exit 0
