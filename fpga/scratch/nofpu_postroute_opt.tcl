#==============================================================================
# fpga/scratch/nofpu_postroute_opt.tcl —— T2 收尾：对已布线结果再跑一轮 phys_opt
#==============================================================================
# 用法：./fpga/run_vivado_batch.sh fpga/scratch/nofpu_postroute_opt.tcl
# 目的：T2 主流程（nofpu_impl.tcl）布线后 WNS = -0.279 ns，距达标仅差 0.28 ns；
#       本脚本在**已布线检查点**上单独试 post-route phys_opt（不同 directive），
#       成功即把该步骤写回 nofpu_impl.tcl 并重跑主流程取正式数字。
# 产物：fpga/out/scratch_nofpu_postroute_opt_{timing_summary,timing_paths,utilization}.rpt
#       fpga/out/scratch_nofpu_post_route_opt.dcp
# ★ 只读主流程产物；不改 RTL/约束。
#==============================================================================
set SCRIPT_DIR [file normalize [file dirname [info script]]]
set PROJ_ROOT  [file normalize [file join $SCRIPT_DIR .. ..]]
set OUT_DIR    [file join $PROJ_ROOT fpga out]
set DCP        [file join $OUT_DIR scratch_nofpu_post_route.dcp]
set DIRECTIVE  "Explore"
if {[llength $argv] >= 1} {
    set DIRECTIVE [lindex $argv 0]
    if {$DIRECTIVE eq ""} { set DIRECTIVE "Explore" }
}
if {![file exists $DCP]} { puts stderr "ERROR: 缺 $DCP"; exit 2 }
open_checkpoint $DCP
set wns0 "n/a"
catch {set wns0 [get_property SLACK [get_timing_paths -delay_type max -max_paths 1]]}
puts "== postroute_opt: phys_opt 前 WNS = $wns0（directive=$DIRECTIVE）"
phys_opt_design -directive $DIRECTIVE
report_utilization -file [file join $OUT_DIR scratch_nofpu_postroute_opt_utilization.rpt]
report_timing_summary -file [file join $OUT_DIR scratch_nofpu_postroute_opt_timing_summary.rpt]
report_timing -delay_type max -sort_by slack -max_paths 20 -nworst 1 -path_type full -input_pins \
              -file [file join $OUT_DIR scratch_nofpu_postroute_opt_timing_paths.rpt]
set wns "n/a"; set whs "n/a"
catch {set wns [get_property SLACK [get_timing_paths -delay_type max -max_paths 1]]}
catch {set whs [get_property SLACK [get_timing_paths -delay_type min -max_paths 1]]}
set fmax "n/a"
if {[string is double -strict $wns]} { set fmax [format %.2f [expr {1000.0/(16.667 - $wns)}]] }
puts "== postroute_opt: phys_opt($DIRECTIVE) 后 WNS = $wns ns；WHS = $whs；Fmax ≈ $fmax MHz"
puts "RESULT_NOFPU_POSTROUTE_OPT: OK WNS=$wns WHS=$whs FMAX=$fmax DIRECTIVE=$DIRECTIVE"
write_checkpoint -force [file join $OUT_DIR scratch_nofpu_post_route_opt.dcp]
exit 0
