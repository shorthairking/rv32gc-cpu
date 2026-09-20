#==============================================================================
# fpga/scratch/t3_paths.tcl —— 从检查点导出**全部失败端点**的归因明细（临时）
#==============================================================================
# 用法：./fpga/run_vivado_batch.sh fpga/scratch/t3_paths.tcl <dcp> <period_ns> <tag> [max_paths]
# 产物：fpga/out/t3_<tag>_paths.tsv       —— 每条路径：slack 源 汇 延时 级数（制表符分隔）
#       fpga/out/t3_<tag>_paths_summary.txt —— 按模块聚集的统计 + 前 N 条明细摘要
# 目的：T3 判据⑤ 需要"最差路径中段落在哪个 RTL 文件"的可复现证据；report_timing
#       不落盘时无法离线归因 ⇒ 本脚本把原始字段导出成 TSV，再由
#       fpga/scratch/t3_analyze.py 做归一/聚集（工具只读检查点，不改设计）。
# ★ 只读：open_checkpoint + report/get 查询，无任何设计改动。
#==============================================================================
set SCRIPT_DIR [file normalize [file dirname [info script]]]
set PROJ_ROOT  [file normalize [file join $SCRIPT_DIR .. ..]]
set OUT_DIR    [file join $PROJ_ROOT fpga out]
file mkdir $OUT_DIR

if {[llength $argv] < 3} {
    puts stderr "用法: t3_paths.tcl <dcp> <period_ns> <tag> \[max_paths\]"
    exit 2
}
set DCP        [lindex $argv 0]
set PERIOD_NS  [lindex $argv 1]
set TAG        [lindex $argv 2]
set MAXP       500
if {[llength $argv] >= 4 && [lindex $argv 3] ne ""} { set MAXP [lindex $argv 3] }

if {![file exists $DCP]} { puts stderr "ERROR: 无检查点 $DCP"; exit 2 }

if {[catch {
    open_checkpoint $DCP
    set _ck [get_clocks -quiet]
    if {[llength $_ck] > 0} {
        set cur [get_property PERIOD [lindex $_ck 0]]
        if {[expr {abs(double($cur) - double($PERIOD_NS))}] > 0.0005} {
            puts "WARN: 检查点周期 ${cur}ns != 请求 ${PERIOD_NS}ns ⇒ 重下发 create_clock"
            create_clock -period $PERIOD_NS -name aclk [get_ports aclk]
        }
    }

    set tsv [file join $OUT_DIR "t3_${TAG}_paths.tsv"]
    set fh [open $tsv w]
    puts $fh "slack\tlogic_levels\tdatapath_ns\tlogic_ns\troute_ns\tsource\tdestination"

    # 全量失败路径（slack < 0）：先按 slack 升序取前 MAXP 条
    set paths [get_timing_paths -delay_type max -slack_lesser_than 0 -max_paths $MAXP -sort_by slack -quiet]
    puts "== t3_paths: 失败路径（前 $MAXP 条）= [llength $paths]"
    set n 0
    foreach p $paths {
        set slack [get_property SLACK $p]
        set ll    [get_property LOGIC_LEVELS $p]
        set dp    [get_property DATAPATH_DELAY $p]
        set lp    [get_property DATAPATH_LOGIC_DELAY $p]
        set rp    [get_property DATAPATH_NET_DELAY $p]
        set src   [get_property STARTPOINT_PIN $p]
        set dst   [get_property ENDPOINT_PIN $p]
        puts $fh "$slack\t$ll\t$dp\t$lp\t$rp\t$src\t$dst"
        incr n
    }
    close $fh
    puts "== t3_paths: 已导出 $n 条 ⇒ $tsv"

    # 人读摘要：前 30 条（★ report_timing 无 -slack_lesser_than 选项，
    #   该过滤只属于 get_timing_paths；这里靠 -sort_by slack 取最差 30 条）
    set rpt [file join $OUT_DIR "t3_${TAG}_paths_top.rpt"]
    report_timing -delay_type max -max_paths 30 -nworst 1 \
                  -path_type summary -sort_by slack -file $rpt
    puts "== t3_paths: 摘要 ⇒ $rpt"

    set brpt [file join $OUT_DIR "t3_${TAG}_paths_full.rpt"]
    report_timing -delay_type max -max_paths 5 -nworst 1 \
                  -path_type full -input_pins -sort_by slack -file $brpt
    puts "== t3_paths: 前 5 条全路径 ⇒ $brpt"
    puts "RESULT_T3_PATHS: OK TAG=$TAG NFAIL=$n PERIOD=$PERIOD_NS"
} err]} {
    puts stderr "ERROR: t3_paths.tcl 失败：$err"
    puts stderr $::errorInfo
    exit 1
}
exit 0
