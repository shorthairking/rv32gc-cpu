#==============================================================================
# fpga/tcl/impl.tcl —— 实现流程（Vivado 2023.2 batch，非工程模式）
#==============================================================================
# 项目 : rv32gc-cpu（阶段二 2A 单发射顺序 5 级基线核）
# 用法 : ./fpga/run_vivado_batch.sh fpga/tcl/impl.tcl [clk_period_ns] [part]
#        （★ 一律经三坑统一入口调用，禁止直接 `vivado -mode batch`，08 §7.1 第 7 条）
#        ★ T3（2026-09-19）起**周期优先**（argv0 = clk_period_ns，与 synth.tcl 同口径）；
#          argv0 是器件串时按旧位次解释为 part，向后兼容旧命令行。
#          默认 clk_period_ns = 16.667（60 MHz，M4 判据②）；100 MHz：`impl.tcl 10.0`
# 流程 : 读设计（优先复用 synth 检查点）→ opt_design → place_design → route_design → 报告
# 产物 : fpga/out/impl_utilization.rpt        —— 实现后资源占用（M4 判据③）
#        fpga/out/impl_utilization_hier.rpt   —— 层次化资源占用
#        fpga/out/impl_timing_summary.rpt     —— 实现后时序摘要（M4 判据②：WNS ≥ 0）
#        fpga/out/post_route.dcp              —— 布线后检查点（供上板/报告复现）
# 依据 : docs/design/08-baseline-5stage.md §M4（"测试入口 fpga/run_vivado_batch.sh
#        fpga/tcl/{synth,impl}.tcl"）、§7.1（红线 4 边界声明）、§7.2（AXI 端口常量）；
#        docs/kb/tools-and-flow.md §3（三坑）；AGENT.md §4 红线 1/2/4。
#
# ---------------------------------------------------------------------------
# ★ 与 08 §7.1 红线 4 的对应：与 synth.tcl 同一声明——本脚本只对**核内** rtl/** 做实现，
#   不引入任何"边界向外"的互连/协议转换 IP，也没有手写的边界外逻辑需要被 IP 替换；
#   2A 核直连平台（08 §1.1 无互连层）。实现所需的 IP（Block Memory Generator / Multiplier /
#   Divider Generator）由 fpga/tcl/create_ip.tcl 生成、在综合阶段 read_ip 并以
#   -verilog_define RV32GC_USE_VIVADO_IP 走 IP 分支（红线 1/2 的"综合侧"）。
#
# ★ 复用方式（避免"读设计"逻辑出现两份真源）：
#       set ::RV32_SYNTH_DEFS_ONLY 1
#       source .../synth.tcl        ⇒ 只加载 rv32_read_design / rv32_apply_constraints /
#                                     rv32_report 三个 proc 与路径常量，**不跑综合流程**
#   因此 impl.tcl 与 synth.tcl 的 include_dirs、IP 读入口径、宏名、时钟兜底口径**永远一致**。
#
# ★ 优先复用 synth 检查点：若 <repo>/fpga/out/post_synth.dcp 存在则 open_checkpoint（快、
#   与综合报告同源）；不存在则本脚本自读 RTL + synth_design 后继续（保证单独调用也能跑通）。
# ★ 实现阶段的 opt/place/route 用的是 Vivado **内建**布局布线引擎（不是 FPGA 原语），
#   与红线 1（禁止手写原语）无关。
#==============================================================================

#------------------------------------------------------------------------------
# 0. 载入 synth.tcl 的 proc 与参数（只加载定义，不跑综合流程）
#------------------------------------------------------------------------------
set SCRIPT_DIR [file normalize [file dirname [info script]]]
set ::RV32_SYNTH_DEFS_ONLY 1
# shellcheck disable=SC1090
source [file join $SCRIPT_DIR synth.tcl]
unset ::RV32_SYNTH_DEFS_ONLY

#------------------------------------------------------------------------------
# 0a. 参数解析（T3 2026-09-19：本脚本**自带**解析，位次与 synth.tcl 严格一致）
#     argv = [clk_period_ns] [part] [tag]
#       * argv0 是器件串（xc…/-…）时按旧位次解释为 part、argv1 为周期（向后兼容）
#       * tag 可选：报告文件名前缀（默认 impl_*，M4 判据②③ 的指定路径）
#     自行解析（而不是沿用 synth.tcl 的解析结果）的理由：两脚本的第二位含义不同
#     （synth 的 argv1 是 part，impl 的 argv1 也是 part，但 impl 多出 argv2=tag），
#     各写一遍可让"谁解释哪个位次"一眼可查，不留隐式耦合。
#------------------------------------------------------------------------------
if {[info exists argv] && [llength $argv] >= 1 && [lindex $argv 0] ne ""} {
    if {[string match "xc*" [lindex $argv 0]] || [string match "*-*" [lindex $argv 0]]} {
        set PART [lindex $argv 0]
        if {[llength $argv] >= 2 && [lindex $argv 1] ne ""} { set CLK_PERIOD_NS [lindex $argv 1] }
    } else {
        set CLK_PERIOD_NS [lindex $argv 0]
        if {[llength $argv] >= 2 && [lindex $argv 1] ne ""} { set PART [lindex $argv 1] }
    }
}
if {![string is double -strict $CLK_PERIOD_NS] || $CLK_PERIOD_NS <= 0} {
    error "clk_period_ns 非法：'$CLK_PERIOD_NS'（应为正数 ns，如 16.667 = 60 MHz / 10.0 = 100 MHz）"
}

puts "== impl.tcl: PROJ_ROOT=$PROJ_ROOT"
puts "== impl.tcl: TOP=$TOP  PART=$PART  CLK_PERIOD=${CLK_PERIOD_NS}ns（[format %.2f [expr {1000.0 / $CLK_PERIOD_NS}]] MHz）"

#------------------------------------------------------------------------------
# 0b. 检查点与本次请求周期的关系（T3：周期是**参数真源**，不容忍陈旧约束）
#     post_synth.dcp 内嵌 synth.tcl 读入时的时钟周期。若它 != 本次请求周期
#     （例如刚跑过 10.0 再跑 16.667），必须按本次周期**重下发** create_clock，
#     否则时序报告会用陈旧周期 ⇒ 结论失真（fail-loud，不是静默复用）。
#------------------------------------------------------------------------------
set CKPT_PERIOD ""
proc rv32_ckpt_period {} {
    if {[llength [get_clocks -quiet]] == 0} { return "" }
    return [get_property PERIOD [lindex [get_clocks -quiet] 0]]
}

# ---- 检查点选择（T3：周期标签优先，避免 60/100 MHz 两轮互相污染）----
#   优先 post_synth_<period>ns.dcp（synth.tcl 的周期副本，内嵌同周期约束）；
#   取不到才回退惯例名 post_synth.dcp（此时由 §0b 护栏校验/重下发周期）。
set POST_SYNTH_DCP [file join $OUT_DIR post_synth.dcp]
set _tagged_dcp [file join $OUT_DIR [format "post_synth_%sns.dcp" $CLK_PERIOD_NS]]
if {[file exists $_tagged_dcp]} { set POST_SYNTH_DCP $_tagged_dcp }
set POST_ROUTE_DCP [file join $OUT_DIR post_route.dcp]

#------------------------------------------------------------------------------
# 0c. 实现策略（T3 2026-09-19：可开关，默认走 T2 已实测收敛的加强档）
#     真源说明：T2 报告（fpga/T2-report.md §二.10、§五.5）在**非 FPU 归因核**上实测
#       * place_design -directive ExtraTimingOpt（时序优先布局）
#       * phys_opt_design -retime（布局后寄存器重定时，网表级**保序**变换）
#       * route_design -directive AggressiveExplore -tns_cleanup
#       * 收尾 phys_opt_design -directive Explore
#     把 WNS 由 −1.012 → **+0.010 ns**（60 MHz 达标）；而 post-route
#     `phys_opt -directive AggressiveExplore` 在本设计上会让 Vivado 2023.2
#     **段错误**（Abnormal termination 11，非 OOM）⇒ 收尾一律 Explore。
#     ★ 这些都是**纯流程/策略参数**：不改 RTL、不改约束、不放宽周期（T3 禁止事项）。
#     ★ 旁路：RV32_IMPL_PLAIN=1 可回到"opt/place/route 全默认"，仅用于对照实验。
#------------------------------------------------------------------------------
set IMPL_PLAIN 0
if {[info exists ::env(RV32_IMPL_PLAIN)] && $::env(RV32_IMPL_PLAIN) ni {"" "0" "false"}} { set IMPL_PLAIN 1 }
# 报告标签：默认 impl_*（M4 判据②③ 的指定文件名）；100 MHz 等对照跑用 argv2
# 或 RV32_IMPL_TAG 换成 impl_<tag>_*，避免覆盖 60 MHz 的交付证据。
set IMPL_TAG "impl"
if {[info exists argv] && [llength $argv] >= 3 && [lindex $argv 2] ne ""} { set IMPL_TAG [lindex $argv 2] }
if {[info exists ::env(RV32_IMPL_TAG)] && $::env(RV32_IMPL_TAG) ne ""} { set IMPL_TAG $::env(RV32_IMPL_TAG) }
puts "== impl.tcl: 策略档 = [expr {$IMPL_PLAIN ? {PLAIN（opt/place/route 全默认，对照用）} : {T2 加强档 ExtraTimingOpt+retime+AggressiveExplore/tns_cleanup+post-route Explore}}]；报告标签 = $IMPL_TAG"

#------------------------------------------------------------------------------
# 1. 读设计 → 2. opt/place/route → 3. 报告（任一步失败即 exit 1，fail-closed）
#------------------------------------------------------------------------------
if {[catch {
    if {[file exists $POST_SYNTH_DCP]} {
        puts "== impl.tcl: open_checkpoint $POST_SYNTH_DCP（复用 synth.tcl 产物）"
        open_checkpoint $POST_SYNTH_DCP
        # 检查点内已含 synth.tcl 读入的约束；仅在缺时钟时补兜底（幂等，见 synth.tcl §3）
        rv32_apply_constraints
    } else {
        puts "WARN: 未找到 $POST_SYNTH_DCP ⇒ 本脚本自行读设计 + synth_design（与 synth.tcl 同一逻辑）"
        rv32_read_design
        rv32_stage_xdc
        puts "== impl.tcl: synth_design -top $TOP -part $PART -verilog_define $IP_MACRO -include_dirs $::RV32_INC_DIRS"
        synth_design -top $TOP -part $PART -verilog_define $IP_MACRO -include_dirs $::RV32_INC_DIRS
        rv32_apply_constraints
    }

    # ---- 0b 续：陈旧约束护栏（周期是参数真源）----
    set _ck [get_clocks -quiet]
    if {[llength $_ck] > 0} {
        set ckpt_period [get_property PERIOD [lindex $_ck 0]]
        if {[expr {abs(double($ckpt_period) - double($CLK_PERIOD_NS))}] > 0.0005} {
            puts "WARN: 检查点内的时钟周期 ${ckpt_period}ns != 本次请求 ${CLK_PERIOD_NS}ns"
            puts "WARN:   ⇒ 按本次请求重下发 create_clock（T3：周期是参数真源，禁止用陈旧约束出报告）"
            create_clock -period $CLK_PERIOD_NS -name aclk [get_ports aclk]
        } else {
            puts "== impl.tcl: 检查点时钟周期 ${ckpt_period}ns 与本次请求一致 ✓"
        }
    }

    puts "== impl.tcl: opt_design"
    opt_design
    if {$IMPL_PLAIN} {
        puts "== impl.tcl: place_design（默认策略）"
        place_design
        puts "== impl.tcl: route_design（默认策略）"
        route_design
    } else {
        puts "== impl.tcl: place_design -directive ExtraTimingOpt"
        place_design -directive ExtraTimingOpt
        puts "== impl.tcl: phys_opt_design -directive AggressiveExplore"
        phys_opt_design -directive AggressiveExplore
        puts "== impl.tcl: phys_opt_design -retime（★ 不可与 -directive 同给，见 Vivado_Tcl 4-167 告警）"
        phys_opt_design -retime
        puts "== impl.tcl: route_design -directive AggressiveExplore -tns_cleanup"
        route_design -directive AggressiveExplore -tns_cleanup
        puts "== impl.tcl: phys_opt_design -directive Explore（收尾；**禁用** AggressiveExplore——T2 实测段错误 11）"
        phys_opt_design -directive Explore
    }

    # 报告落盘（<tag>_*.rpt；WNS 由 rv32_report 打印，M4 判据②）
    rv32_report $IMPL_TAG
    # 最差路径明细（T3 判据⑤：60 MHz 余量小 / 100 MHz 差距的"top 关键路径"证据）
    report_timing -delay_type max -sort_by slack -max_paths 20 -nworst 1 -path_type full -input_pins \
                  -file [file join $OUT_DIR "${IMPL_TAG}_timing_paths.rpt"]
    set _wns "n/a"; set _whs "n/a"
    catch {set _wns [get_property SLACK [get_timing_paths -delay_type max -max_paths 1]]}
    catch {set _whs [get_property SLACK [get_timing_paths -delay_type min -max_paths 1]]}
    set _fmax "n/a"
    if {[string is double -strict $_wns]} { set _fmax [format %.2f [expr {1000.0/($CLK_PERIOD_NS - $_wns)}]] }
    set _nfail "n/a"
    catch {set _nfail [llength [get_timing_paths -delay_type max -slack_lesser_than 0 -max_paths 100000 -quiet]]}
    puts "== impl.tcl: 布线后 WNS(setup) = $_wns ns @ ${CLK_PERIOD_NS}ns；WHS(hold) = $_whs ns；Fmax ≈ $_fmax MHz；失败端点(前 100000) = $_nfail"
    puts "RESULT_IMPL_${IMPL_TAG}: OK WNS=$_wns WHS=$_whs FMAX=$_fmax NFAIL=$_nfail"

    write_checkpoint -force $POST_ROUTE_DCP
    puts "== impl.tcl 完成：报告 $OUT_DIR/${IMPL_TAG}_*.rpt；检查点 $POST_ROUTE_DCP"
    puts "== impl.tcl 提示：M4 判据② 需 WNS >= 0；若 60 MHz 不收敛，先看 ${IMPL_TAG}_timing_summary.rpt"
    puts "== impl.tcl 提示：上板 bitstream 生成属 M5，本脚本不生成比特流"
} err]} {
    puts stderr "ERROR: impl.tcl 失败：$err"
    puts stderr $::errorInfo
    exit 1
}
