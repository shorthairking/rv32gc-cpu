#==============================================================================
# fpga/scratch/nofpu_analyze.tcl —— 对既有 post-route 检查点做**失败端点分布**归因
#==============================================================================
# 用法：./fpga/run_vivado_batch.sh fpga/scratch/nofpu_analyze.tcl [dcp] [max_paths]
# 目的（T2 前置归因，只读不改）：搞清 2115 个失败端点到底集中在哪些寄存器/锥体，
#       以及 slack 分布（-0.1..-1 / -1..-2 / ... / < -5），据此决定在哪一级插寄存器。
# 产物：fpga/out/scratch_nofpu_analyze.rpt（stdout 同时落 vivado.log）
# ★ 只读；不写任何 RTL/DCP。
#==============================================================================
set SCRIPT_DIR [file normalize [file dirname [info script]]]
set PROJ_ROOT  [file normalize [file join $SCRIPT_DIR .. ..]]
set OUT_DIR    [file join $PROJ_ROOT fpga out]
set DCP [file join $OUT_DIR scratch_nofpu_post_route.dcp]
if {[llength $argv] >= 1 && [lindex $argv 0] ne ""} { set DCP [lindex $argv 0] }
set MAXP 4000
if {[llength $argv] >= 2 && [lindex $argv 1] ne ""} { set MAXP [lindex $argv 1] }

if {![file exists $DCP]} { puts stderr "ERROR: 缺 $DCP"; exit 2 }
open_checkpoint $DCP

set fh [open [file join $OUT_DIR scratch_nofpu_analyze.rpt] w]
proc P {fh args} { puts $fh [join $args " "]; puts [join $args " "] }

P $fh "== nofpu_analyze: dcp = $DCP"
P $fh "== nofpu_analyze: get_timing_paths -max_paths $MAXP -nworst 1"
set paths [get_timing_paths -delay_type max -max_paths $MAXP -nworst 1 -sort_by slack]
P $fh "== nofpu_analyze: 返回路径数 = [llength $paths]"

# ---- 1. slack 直方图 ----
array set hist {}
set worst 0.0; set tns 0.0; set nfail 0
foreach p $paths {
    set s [get_property SLACK $p]
    if {$s >= 0} continue
    incr nfail
    set tns [expr {$tns + $s}]
    if {$s < $worst} { set worst $s }
    set b [expr {int(ceil(-$s))}]
    if {$b > 8} { set b 9 }
    if {![info exists hist($b)]} { set hist($b) 0 }
    incr hist($b)
}
P $fh "== nofpu_analyze: 失败端点(本报告内) = $nfail ; TNS = [format %.3f $tns] ; WNS = [format %.3f $worst]"
foreach b [lsort -integer [array names hist]] {
    if {$b == 9} { P $fh [format "   slack  < -8ns : %6d" $hist($b)] } else {
        P $fh [format "   slack -%d..-%d ns : %6d" [expr {$b-1}] $b $hist($b)] }
}

# ---- 2. 按「终点寄存器所属层次前缀」聚集 ----
proc prefix_of {pin} {
    # 去掉最后一段 /PIN，再去掉末尾的寄存器位选 [n]，保留层次前缀
    set s $pin
    set i [string last "/" $s]
    if {$i > 0} { set s [string range $s 0 [expr {$i-1}]] }
    regsub {\[[0-9]+\]$} $s "" s
    regsub {_reg$} $s "" s
    return $s
}
array set dcnt {}
array set dworst {}
foreach p $paths {
    set s [get_property SLACK $p]
    if {$s >= 0} continue
    set e [get_property ENDPOINT_PIN $p]
    set k [prefix_of $e]
    if {![info exists dcnt($k)]} { set dcnt($k) 0; set dworst($k) 0.0 }
    incr dcnt($k)
    if {$s < $dworst($k)} { set dworst($k) $s }
}
P $fh ""
P $fh "== nofpu_analyze: 终点聚集 TOP40（按失败端点数）"
set pairs {}
foreach k [array names dcnt] { lappend pairs [list $dcnt($k) $k] }
set n 0
foreach e [lsort -integer -decreasing -index 0 $pairs] {
    set k [lindex $e 1]
    P $fh [format "   %6d  worst=%8.3f  %s" $dcnt($k) $dworst($k) $k]
    incr n; if {$n >= 40} break
}

# ---- 3. 按「起点寄存器所属层次前缀」聚集 ----
array set scnt {}
array set sworst {}
foreach p $paths {
    set s [get_property SLACK $p]
    if {$s >= 0} continue
    set e [get_property STARTPOINT_PIN $p]
    set k [prefix_of $e]
    if {![info exists scnt($k)]} { set scnt($k) 0; set sworst($k) 0.0 }
    incr scnt($k)
    if {$s < $sworst($k)} { set sworst($k) $s }
}
P $fh ""
P $fh "== nofpu_analyze: 起点聚集 TOP40（按失败端点数）"
set pairs {}
foreach k [array names scnt] { lappend pairs [list $scnt($k) $k] }
set n 0
foreach e [lsort -integer -decreasing -index 0 $pairs] {
    set k [lindex $e 1]
    P $fh [format "   %6d  worst=%8.3f  %s" $scnt($k) $sworst($k) $k]
    incr n; if {$n >= 40} break
}

# ---- 4. 前 60 条最差路径的 源→汇 + 延迟构成 ----
P $fh ""
P $fh "== nofpu_analyze: 最差 60 条路径（slack / logic / route / levels / 源 → 汇）"
set n 0
foreach p $paths {
    set s [get_property SLACK $p]
    if {$s >= 0} continue
    set dd [get_property DATAPATH_DELAY $p]
    set ll [get_property LOGIC_LEVELS $p]
    set sp [get_property STARTPOINT_PIN $p]
    set ep [get_property ENDPOINT_PIN $p]
    P $fh [format "   %8.3f  dp=%7.3f lv=%2d  %s  ->  %s" $s $dd $ll $sp $ep]
    incr n; if {$n >= 60} break
}

close $fh
puts "RESULT_NOFPU_ANALYZE: OK"
exit 0
