#==============================================================================
# fpga/scratch/t3_instmap.tcl —— 导出"实例名 → 模块名"映射（临时，非交付物）
#==============================================================================
# 用法：./fpga/run_vivado_batch.sh fpga/scratch/t3_instmap.tcl
# 产物：fpga/out/t3_instmap.tsv   （每行：实例层次名 <TAB> 模块名）
# 目的：T3 判据⑤ 需要把布线后最差路径的网表资源名（em_imm_val_reg[0]/C 等）
#       归因到 **RTL 模块/文件**（如 lsu.v / amo_unit.v / pmp_check.v）。
#       时序报告只给实例名不给模块名 ⇒ 用 get_cells -hier 导出映射，离线查表。
# ★ 只读 rtl/**，不修改任何 RTL；不跑综合（elaborate 后即导出）。
#==============================================================================
set SCRIPT_DIR [file normalize [file dirname [info script]]]
set PROJ_ROOT  [file normalize [file join $SCRIPT_DIR .. ..]]
set OUT_DIR    [file join $PROJ_ROOT fpga out]
set PART       "xc7a200tfbg676-2"
set TOP        "core_top"
file mkdir $OUT_DIR

set pkg_files [lsort [glob -nocomplain [file join $PROJ_ROOT rtl pkg *.vh]]]
set rtl_files [lsort [glob -nocomplain [file join $PROJ_ROOT rtl * *.v]]]
set inc_dirs  [list [file join $PROJ_ROOT rtl pkg] [file join $PROJ_ROOT rtl] $PROJ_ROOT]

puts "== t3_instmap.tcl: 读入 RTL ×[llength $rtl_files]（只读，不改）"
if {[catch {current_project -quiet} _cp] || $_cp eq ""} { create_project -in_memory -part $PART }
read_verilog $pkg_files
read_verilog $rtl_files
read_ip [lsort [glob -nocomplain [file join $PROJ_ROOT fpga ip * *.xci]]]
generate_target {synthesis} [get_ips -quiet]
synth_ip [get_ips -quiet]

puts "== t3_instmap.tcl: synth_design -rtl（只到 RTL 级，导出实例映射）"
synth_design -top $TOP -part $PART -rtl -verilog_define RV32GC_USE_VIVADO_IP -include_dirs $inc_dirs

set fh [open [file join $OUT_DIR t3_instmap.tsv] w]
puts $fh "# 实例层次名\t模块名\t（T3 归因用；由 fpga/scratch/t3_instmap.tcl 生成）"
set n 0
foreach c [get_cells -hier -filter {IS_PRIMITIVE == 0}] {
    set ref [get_property REF_NAME $c]
    # 只记录"用户模块"（排除 IP/黑盒的 *_stub / 原语包装）
    puts $fh "$c\t$ref"
    incr n
}
close $fh
puts "== t3_instmap.tcl 完成：实例 ×$n ⇒ $OUT_DIR/t3_instmap.tsv"
exit 0
