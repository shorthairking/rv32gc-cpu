#==============================================================================
# fpga/scratch/t3_logicdepth.tcl —— 组合深度测量（临时，非交付物）
#==============================================================================
# 用法：./fpga/run_vivado_batch.sh fpga/scratch/t3_logicdepth.tcl <dcp> <tag> [num_paths]
# 目的：T3 判据⑤ 要"余量任务清单：建议在哪切级、预期每级深度"。
#       综合时序是**未布局估算**（route 占 36.5/69.4 ns = 52.6%，含"unplaced"网的
#       零延时项与统计线载模型），不能直接当"组合深度"。为给出**与布线无关**的
#       纯逻辑深度上界，本脚本：
#         open_checkpoint → create_clock 周期设成 **10 ns**（收紧到不可能满足）
#         → report_timing -max_paths N -path_type full
#       在 10 ns 约束下 Vivado 报的 slack 仍是"延时 − 10"，故从
#       `Data Path Delay` 直接读出该路径的**组合延时**（与 16.667 ns 约束下同一网表
#       的延时一致——约束只影响报告里的 slack，不改变网表）。
#       ⇒ 报告里的 Data Path Delay = "每拍必须容纳的延时" ⇒ 除以目标周期即得级数下界。
# ★ 只读检查点；不改设计、不写回检查点。
#==============================================================================
set SCRIPT_DIR [file normalize [file dirname [info script]]]
set PROJ_ROOT  [file normalize [file join $SCRIPT_DIR .. ..]]
set OUT_DIR    [file join $PROJ_ROOT fpga out]
file mkdir $OUT_DIR

if {[llength $argv] < 2} { puts stderr "用法: t3_logicdepth.tcl <dcp> <tag> \[num_paths\]"; exit 2 }
set DCP   [lindex $argv 0]
set TAG   [lindex $argv 1]
set NPATH 20
if {[llength $argv] >= 3 && [lindex $argv 2] ne ""} { set NPATH [lindex $argv 2] }
if {![file exists $DCP]} { puts stderr "ERROR: 无检查点 $DCP"; exit 2 }

if {[catch {
    open_checkpoint $DCP
    set rpt [file join $OUT_DIR "t3_${TAG}_logicdepth.rpt"]
    # 周期收紧到 10 ns（100 MHz 目标）：让报告里"每条路径都违例"⇒ 一眼看出
    # 该路径需要几个 10 ns 周期才能装下（slack = delay − 10 ⇒ 级数下界 = ceil(delay/10)）。
    create_clock -period 10.0 -name aclk [get_ports aclk]
    report_timing -delay_type max -max_paths $NPATH -nworst 1 -path_type full -input_pins \
                  -sort_by slack -file $rpt
    puts "== t3_logicdepth: 前 $NPATH 条组合路径（周期按 10 ns 报告）⇒ $rpt"

    # 逐条打印 Data Path Delay / Logic Levels 摘要（便于直接抄进报告）
    set i 0
    foreach p [get_timing_paths -delay_type max -max_paths $NPATH -sort_by slack -quiet] {
        incr i
        set dp [get_property DATAPATH_DELAY $p]
        set ll [get_property LOGIC_LEVELS $p]
        set lp [get_property DATAPATH_LOGIC_DELAY $p]
        set rp [get_property DATAPATH_NET_DELAY $p]
        set src [get_property STARTPOINT_PIN $p]
        set dst [get_property ENDPOINT_PIN $p]
        puts "DEPTH#$i delay=$dp logic=$lp route=$rp levels=$ll  $src -> $dst"
    }
    puts "RESULT_T3_LOGICDEPTH: OK TAG=$TAG NPATH=$NPATH"
} err]} {
    puts stderr "ERROR: t3_logicdepth.tcl 失败：$err"
    puts stderr $::errorInfo
    exit 1
}
exit 0
