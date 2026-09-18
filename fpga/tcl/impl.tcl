#==============================================================================
# fpga/tcl/impl.tcl —— 实现流程（Vivado 2023.2 batch，非工程模式）
#==============================================================================
# 项目 : rv32gc-cpu（阶段二 2A 单发射顺序 5 级基线核）
# 用法 : ./fpga/run_vivado_batch.sh fpga/tcl/impl.tcl [part] [clk_period_ns]
#        （★ 一律经三坑统一入口调用，禁止直接 `vivado -mode batch`，08 §7.1 第 7 条）
#          默认 part = xc7a200tfbg676-2；默认 clk_period_ns = 16.667（60 MHz，M4 判据②）
#          100 MHz 余量参考：./fpga/run_vivado_batch.sh fpga/tcl/impl.tcl xc7a200tfbg676-2 10.0
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

puts "== impl.tcl: PROJ_ROOT=$PROJ_ROOT"
puts "== impl.tcl: TOP=$TOP  PART=$PART  CLK_PERIOD=${CLK_PERIOD_NS}ns（[format %.2f [expr {1000.0 / $CLK_PERIOD_NS}]] MHz）"

set POST_SYNTH_DCP [file join $OUT_DIR post_synth.dcp]
set POST_ROUTE_DCP [file join $OUT_DIR post_route.dcp]

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

    puts "== impl.tcl: opt_design"
    opt_design
    puts "== impl.tcl: place_design"
    place_design
    puts "== impl.tcl: route_design"
    route_design

    # 报告落盘（impl_*.rpt；WNS 由 rv32_report 打印，M4 判据②）
    rv32_report impl

    write_checkpoint -force $POST_ROUTE_DCP
    puts "== impl.tcl 完成：报告 $OUT_DIR/impl_*.rpt；检查点 $POST_ROUTE_DCP"
    puts "== impl.tcl 提示：M4 判据② 需 WNS >= 0；若 60 MHz 不收敛，先看 impl_timing_summary.rpt"
    puts "== impl.tcl 提示：上板 bitstream 生成属 M5，本脚本不生成比特流"
} err]} {
    puts stderr "ERROR: impl.tcl 失败：$err"
    puts stderr $::errorInfo
    exit 1
}
