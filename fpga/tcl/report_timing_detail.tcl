#==============================================================================
# fpga/tcl/report_timing_detail.tcl —— 检查点详细时序报告（M4 判据②⑤ 证据）
#==============================================================================
# 用法：
#   ./fpga/run_vivado_batch.sh fpga/tcl/report_timing_detail.tcl <dcp> <period_ns> [tag]
# 例：
#   ./fpga/run_vivado_batch.sh fpga/tcl/report_timing_detail.tcl fpga/out/post_synth.dcp 16.667 synth
#   ./fpga/run_vivado_batch.sh fpga/tcl/report_timing_detail.tcl fpga/out/post_route.dcp 10.0    route_100m
#
# 作用（不改设计、只读检查点后重新分析）：
#   1) 打开检查点（综合后 post_synth.dcp / 布线后 post_route.dcp）；
#   2) 用**本次给定周期**重下发 aclk 时钟（同名 create_clock 覆盖，即"收紧约束重分析"），
#      用于回答"60 MHz 收敛的网表在 100 MHz 下差多少"（M4 判据② 的余量参考）；
#   3) 落盘：<tag>_timing_summary.rpt（含 WNS/TNS/WHS/THS）
#            <tag>_timing_paths.rpt  （关键路径 top 20，含 startpoint/endpoint/slack）
#   4) 控制台打印 WNS/TNS 与推算的**可达最高频率** Fmax = 1000/(period - WNS) MHz。
#
# ★ 注意：<period> 与检查点内既有约束同名时以本次为准（Vivado 会用新定义替换旧定义），
#   因此本脚本既能"原样复核"也能"收紧重分析"；报告文件名带周期避免覆盖混淆。
#==============================================================================
set SCRIPT_DIR [file normalize [file dirname [info script]]]
set PROJ_ROOT  [file normalize [file join $SCRIPT_DIR .. ..]]
set OUT_DIR    [file join $PROJ_ROOT fpga out]
file mkdir $OUT_DIR

if {[llength $argv] < 2} {
    puts stderr "用法: report_timing_detail.tcl <dcp> <period_ns> \[tag\]"
    exit 2
}
set DCP        [lindex $argv 0]
set PERIOD_NS  [lindex $argv 1]
set TAG        [expr {[llength $argv] >= 3 ? [lindex $argv 2] : "timing"}]

if {![file exists $DCP]} {
    puts stderr "ERROR: 检查点不存在：$DCP（先跑 synth.tcl / impl.tcl 生成）"
    exit 2
}

puts "== report_timing_detail: DCP=$DCP  PERIOD=${PERIOD_NS}ns（[format %.2f [expr {1000.0/$PERIOD_NS}]] MHz）TAG=$TAG"
if {[catch {
    open_checkpoint $DCP

    # ---- 收紧/替换时钟（同名覆盖）----
    if {[llength [get_ports -quiet aclk]] > 0} {
        create_clock -period $PERIOD_NS -name aclk [get_ports aclk]
        puts "== 已按 ${PERIOD_NS}ns 重下发 aclk"
    } else {
        puts "WARN: 检查点里没有 aclk 端口 ⇒ 沿用检查点内既有约束"
    }
    puts "== 当前时钟：[get_clocks -quiet]"

    set tsum [file join $OUT_DIR "${TAG}_timing_summary.rpt"]
    set tpath [file join $OUT_DIR "${TAG}_timing_paths.rpt"]
    report_timing_summary -file $tsum
    # 关键路径 top 20（按 slack 升序 ⇒ 最差路径在前；含 startpoint/endpoint/slack）
    report_timing -delay_type max -sort_by slack -max_paths 20 -nworst 1 -path_type full \
                  -input_pins -file $tpath

    set wns "n/a"; set tns "n/a"; set whs "n/a"; set ths "n/a"
    catch {set wns [get_property SLACK [get_timing_paths -delay_type max -max_paths 1]]}
    catch {set tns [get_property SLACK [get_timing_paths -delay_type max -max_paths 1000 -nworst 1000]]}
    catch {set whs [get_property SLACK [get_timing_paths -delay_type min -max_paths 1]]}
    set fmax "n/a"
    if {[string is double -strict $wns]} {
        set fmax [format %.2f [expr {1000.0 / ($PERIOD_NS - $wns)}]]
    }
    puts "== $TAG: WNS(setup) = $wns ns  @ ${PERIOD_NS}ns"
    puts "== $TAG: WHS(hold)  = $whs ns"
    puts "== $TAG: 可达最高频率 Fmax ≈ $fmax MHz（= 1000/(period - WNS)，仅 setup 口径）"
    puts "== $TAG: 报告 ⇒ $tsum | $tpath"
} err]} {
    puts stderr "ERROR: report_timing_detail.tcl 失败：$err"
    puts stderr $::errorInfo
    exit 1
}
exit 0
