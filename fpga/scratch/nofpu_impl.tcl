#==============================================================================
# fpga/scratch/nofpu_impl.tcl —— 「除 FPU 之外」整核的布局布线（临时，非交付物）
#==============================================================================
# 用法：./fpga/run_vivado_batch.sh fpga/scratch/nofpu_impl.tcl [period_ns]
# 做法：open_checkpoint fpga/out/scratch_nofpu_post_synth.dcp → opt/place/route → 报告
# 目的：给出**布局布线后**的真实时序（综合后 WNS 是未布局的估算，路由占 72%，
#       偏悲观）；同时验证 impl 流程（opt/place/route）本身可跑通。
# 产物：fpga/out/scratch_nofpu_impl_{utilization,timing_summary,timing_paths}.rpt
#       fpga/out/scratch_nofpu_post_route.dcp
#==============================================================================
set SCRIPT_DIR [file normalize [file dirname [info script]]]
set PROJ_ROOT  [file normalize [file join $SCRIPT_DIR .. ..]]
set OUT_DIR    [file join $PROJ_ROOT fpga out]
set DCP        [file join $OUT_DIR scratch_nofpu_post_synth.dcp]
set CLK_NS 16.667
if {[llength $argv] >= 1 && [lindex $argv 0] ne ""} { set CLK_NS [lindex $argv 0] }

if {![file exists $DCP]} {
    puts stderr "ERROR: 缺检查点 $DCP（先跑 fpga/scratch/nofpu_synth.tcl）"
    exit 2
}

if {[catch {
    open_checkpoint $DCP
    # 收紧/替换时钟（诊断用：既看 60 MHz，也可传 10.0 看 100 MHz 差距）
    create_clock -period $CLK_NS -name aclk [get_ports aclk]
    puts "== nofpu_impl: 时钟按 ${CLK_NS}ns 重下发；[get_clocks -quiet]"

    opt_design
    # ---- 物理优化 + 时序优先布线（纯流程/约束层调整，不改 RTL、不改语义）----
    #   依据：默认流程布线后关键路径 route 占 77 %（17.6 ns / 22.8 ns）、37 级逻辑，
    #   属"长控制链 + 高扇出"型 ⇒ 先用 ExtraTimingOpt 布局，再跑两轮 phys_opt。
    place_design -directive ExtraTimingOpt
    phys_opt_design -directive AggressiveExplore
    # ---- T2（2026-09-19）加强时序收敛（**纯策略参数，不改 RTL/不改约束**）----
    #   依据：T2 后布线后最差一族 slack ≈ -1.0 ns，且 route 占 72~78%（属"逻辑被
    #   摆得太散"型）⇒ 在布局后增加一轮**寄存器重定时**（-retime，保序变换：
    #   只沿组合路径移动寄存器位置、不改变任何时序行为），并把布线换成
    #   AggressiveExplore + TNS 清理（同时压最差路径与总违例）。
    #   ★ 用法坑：`-retime` **不能**与 `-directive` 同时给（Vivado 报
    #     [Vivado_Tcl 4-167]），故重定时单独一次调用。
    phys_opt_design -retime
    route_design -directive AggressiveExplore -tns_cleanup
    #   ★ 2026-09-19：**去掉布线后的第二次 phys_opt** —— Vivado 2023.2 在本设计
    #     （含 -retime 后的网表）上于 post-route phys_opt 的 "Phase 2 Critical Path
    #     Optimization" 段**段错误**（Abnormal program termination (11)，非 OOM：
    #     崩溃时机器完全空闲）。崩溃发生在布线**之后**，会连带丢掉全部报告与
    #     RESULT 行 ⇒ 为保证流程可复现、结果可交付，改为"布线后直接出报告"。
    #     代价：少了基线流程里那一次 post-route phys_opt（基线它带来 +0.84 ns），
    #     由 -retime 与 AggressiveExplore/tns_cleanup 补偿（见交付说明的对比表）。
    #   ★ 2026-09-19 补充：改用 **-directive Explore** 的 post-route phys_opt ——
    #     在已布线检查点上单跑实验（fpga/scratch/nofpu_postroute_opt.tcl）实测
    #     WNS 由 -0.279 → +0.010 ns（不再触发 AggressiveExplore 的那次段错误）。
    #     故把它作为收尾一步加回主流程（仍在报告之前）。
    phys_opt_design -directive Explore

    report_utilization -file [file join $OUT_DIR scratch_nofpu_impl_utilization.rpt]
    report_timing_summary -file [file join $OUT_DIR scratch_nofpu_impl_timing_summary.rpt]
    report_timing -delay_type max -sort_by slack -max_paths 20 -nworst 1 -path_type full -input_pins \
                  -file [file join $OUT_DIR scratch_nofpu_impl_timing_paths.rpt]

    set wns "n/a"; set whs "n/a"
    catch {set wns [get_property SLACK [get_timing_paths -delay_type max -max_paths 1]]}
    catch {set whs [get_property SLACK [get_timing_paths -delay_type min -max_paths 1]]}
    set fmax "n/a"
    if {[string is double -strict $wns]} { set fmax [format %.2f [expr {1000.0/($CLK_NS - $wns)}]] }
    puts "== nofpu_impl: 布线后 WNS(setup) = $wns ns @ ${CLK_NS}ns；WHS(hold) = $whs ns"
    puts "== nofpu_impl: 布线后可达最高频率 Fmax ≈ $fmax MHz"
    puts "RESULT_NOFPU_IMPL: OK WNS=$wns WHS=$whs FMAX=$fmax"
    write_checkpoint -force [file join $OUT_DIR scratch_nofpu_post_route.dcp]
} err]} {
    puts stderr "ERROR: nofpu_impl.tcl 失败：$err"
    puts stderr $::errorInfo
    exit 1
}
exit 0
