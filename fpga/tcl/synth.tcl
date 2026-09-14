#==============================================================================
# fpga/tcl/synth.tcl —— 非工程模式综合（M4：Vivado 2023.2 batch）
#==============================================================================
# 项目 : rv32gc-cpu（阶段二 2A 单发射顺序 5 级基线核）
# 用法 : ./fpga/run_vivado_batch.sh fpga/tcl/synth.tcl [part] [clk_period_ns]
#        （★ 一律经三坑统一入口调用，禁止直接 `vivado -mode batch`，08 §7.1 第 7 条）
#          默认 part = xc7a200tfbg676-2（AGENT.md §2 平台器件）
#          默认 clk_period_ns = 16.667（60 MHz，M4 判据② 的验收时钟；100 MHz 余量参考用 10.0）
# 产物 : fpga/out/synth_utilization.rpt        —— 资源占用（M4 判据③）
#        fpga/out/synth_utilization_hier.rpt   —— 层次化资源占用（按模块核对）
#        fpga/out/synth_timing_summary.rpt     —— 时序摘要（M4 判据②，看 WNS/TNS）
#        fpga/out/post_synth.dcp               —— 综合检查点（impl.tcl 可直接 open_checkpoint）
# 依据 : docs/design/08-baseline-5stage.md §M4（综合/时序判据）、§7.1（红线 4 边界）、
#        §7.3（IP 双分支）、§3.2（synth.tcl 职责）、§3.3（宏名 RV32GC_USE_VIVADO_IP）；
#        docs/kb/tools-and-flow.md §3（Vivado 三坑）；AGENT.md §4 红线 1/2/4。
#
# ---------------------------------------------------------------------------
# ★ 与 08 §7.1 红线 4 的对应（本脚本的合规声明）
#   红线 4 的边界是「Cache→AXI 转换」：**边界向外**（互连/协议转换/位宽转换/DMA/FIFO/
#   外设控制器）必须复用 Vivado IP 或平台已有模块；**边界向内**（核内 AXI 主端口控制器、
#   Cache 阵列控制、执行流水）允许手写（08 §7.1 表格 + 正式判断）。
#   本脚本只综合 rtl/**（核内、边界向内），**不引入任何互连/协议转换 IP**，也没有任何
#   手写的"边界向外"逻辑需要在这里被 IP 替换；2A 核直连平台（08 §1.1），M6 引入 L2 时
#   边界向外的部分才必须换成 Vivado AXI IP（届时在本脚本 read_ip 中追加）。
#   本脚本 read_ip 的 IP 全部是**红线 1 要求的 IP**（Block Memory Generator / Multiplier /
#   Divider Generator），由 fpga/tcl/create_ip.tcl 生成（红线 1 证据留档），**不是原语**。
#   配合 -verilog_define RV32GC_USE_VIVADO_IP ⇒ RTL 走 IP 分支（红线 1/2 双分支的"综合侧"）；
#   iverilog/Verilator 回归**从不**定义该宏 ⇒ 走逐拍等价行为模型，回归不依赖 Vivado。
#
# ★ 坑② 说明：本脚本走**非工程模式**（read_verilog + synth_design -top），非工程模式没有
#   source 管理，"自动层次引擎找不到 top"不适用 ⇒ 无需 `set_property source_mgmt_mode None`。
#   若将来改回工程模式，必须补 source_mgmt_mode None + 显式 top（docs/kb/tools-and-flow.md §3）。
# ★ impl.tcl 复用本脚本：`set ::RV32_SYNTH_DEFS_ONLY 1; source synth.tcl` 只加载 proc，
#   不跑综合流程（保证两脚本共用同一份"读设计"逻辑，避免真源分叉）。
#==============================================================================

#------------------------------------------------------------------------------
# 0. 路径与参数（全部绝对化，避免受调用者 cwd 影响；入口已 cd 到仓库根）
#------------------------------------------------------------------------------
set SCRIPT_DIR [file normalize [file dirname [info script]]]        ;# <repo>/fpga/tcl
set PROJ_ROOT  [file normalize [file join $SCRIPT_DIR .. ..]]        ;# <repo>
set RTL_DIR    [file join $PROJ_ROOT rtl]
set PKG_DIR    [file join $RTL_DIR pkg]
set OUT_DIR    [file join $PROJ_ROOT fpga out]
set TOP        "core_top"                 ;# 平台 soc_top.v 例化的核模块名（08 §4，48 端口契约）
set PART       "xc7a200tfbg676-2"         ;# AGENT.md §2 平台器件
set CLK_PERIOD_NS 16.667                  ;# 60 MHz（M4 判据②）；100 MHz 余量参考传 10.0
set IP_MACRO   "RV32GC_USE_VIVADO_IP"     ;# 宏名真源（08 §3.3 第 3 条）

if {[info exists argv] && [llength $argv] >= 1 && [lindex $argv 0] ne ""} { set PART [lindex $argv 0] }
if {[info exists argv] && [llength $argv] >= 2 && [lindex $argv 1] ne ""} { set CLK_PERIOD_NS [lindex $argv 1] }

puts "== synth.tcl: PROJ_ROOT=$PROJ_ROOT"
puts "== synth.tcl: TOP=$TOP  PART=$PART  CLK_PERIOD=${CLK_PERIOD_NS}ns（[format %.2f [expr {1000.0 / $CLK_PERIOD_NS}]] MHz）"

#------------------------------------------------------------------------------
# 1. 工具 proc
#------------------------------------------------------------------------------
# 递归收集某后缀的文件（按路径排序 ⇒ 读入顺序确定、可复现；不依赖 Tcl 8.6 的 `**` 语义）
proc rv32_glob_rec {dir pattern} {
    set out {}
    if {![file isdirectory $dir]} { return {} }
    foreach entry [lsort [glob -nocomplain -directory $dir *]] {
        if {[file isdirectory $entry]} {
            set out [concat $out [rv32_glob_rec $entry $pattern]]
        } elseif {[string match $pattern [file tail $entry]]} {
            lappend out $entry
        }
    }
    return $out
}

#------------------------------------------------------------------------------
# 2. 读入设计（RTL + IP；被 impl.tcl 复用）
#------------------------------------------------------------------------------
proc rv32_read_design {} {
    global RTL_DIR PKG_DIR PROJ_ROOT OUT_DIR IP_MACRO

    file mkdir $OUT_DIR

    # ---- 2.1 rtl/pkg/*.vh（唯一真源：位宽/参数/宏）----
    # 真源纪律（08 §3.3 第 1 条）：宏只在 rtl/pkg/*.vh 定义，改动先改真源再全量同步。
    set pkg_files [rv32_glob_rec $PKG_DIR *.vh]
    if {[llength $pkg_files] == 0} {
        error "rtl/pkg/*.vh 为空：宏/位宽真源缺失（应有 rv32_defs.vh 与 core_params.vh）"
    }
    # ---- 2.2 rtl/**/*.v（全部 RTL；只综合本项目，不读 chiplab 平台文件）----
    set rtl_files [rv32_glob_rec $RTL_DIR *.v]
    if {[llength $rtl_files] == 0} {
        error "rtl/**/*.v 为空：无可综合源码"
    }

    # ---- 2.3 include 顺序处理 ----
    # RTL 里两种写法混用：`` `include "rv32_defs.vh" ``（裸名）与
    # `` `include "rtl/pkg/rv32_defs.vh" ``（仓库根相对）。两条路径都要能解析：
    #   -include_dirs 同时给 rtl/pkg、rtl、仓库根 ⇒ 两种写法都能命中；
    #   再把 *.vh **先读**（宏真源在任何 RTL 之前进入定义表），两条机制互为兜底。
    #   （所有 .vh 都有 `ifndef 守卫 ⇒ 与文件内 `` `include `` 重复读入不会重定义。）
    set inc_dirs [list $PKG_DIR $RTL_DIR $PROJ_ROOT]
    puts "== synth.tcl: 读入 rtl/pkg/*.vh ×[llength $pkg_files]（宏真源，先读）"
    if {[catch { read_verilog -include_dirs $inc_dirs $pkg_files } err]} {
        # 头文件单独 read 失败不致命：文件内的 `` `include `` + -include_dirs 仍是有效路径
        puts "WARN: 单独 read_verilog rtl/pkg/*.vh 失败（$err）⇒ 依赖各 RTL 内的 \`include + -include_dirs"
    }
    puts "== synth.tcl: 读入 rtl/**/*.v ×[llength $rtl_files]"
    read_verilog -include_dirs $inc_dirs $rtl_files

    # ---- 2.4 综合侧 IP（红线 1：用 IP，不用原语）----
    # 约定：create_ip.tcl 把 IP 生成到 <repo>/fpga/ip/<module_name>/<module_name>.xci
    set xci_files [lsort [glob -nocomplain [file join $PROJ_ROOT fpga ip * *.xci]]]
    if {[llength $xci_files] == 0} {
        puts "WARN: 未找到 fpga/ip/*/*.xci ⇒ 跳过 read_ip。"
        puts "WARN:   综合分支（$IP_MACRO）会引用 Block Memory Generator / Multiplier / Divider"
        puts "WARN:   Generator 的例化，缺少 IP 会导致 synth_design 报 unknown module；"
        puts "WARN:   请先执行 ./fpga/run_vivado_batch.sh fpga/tcl/create_ip.tcl 生成 IP。"
    } else {
        foreach xci $xci_files { puts "== synth.tcl: read_ip $xci" }
        read_ip $xci_files
        # 备选（仅在 OOC 综合出问题时启用，保持默认流程不额外投机）：
        #   set_property GENERATE_SYNTH_CHECKPOINT true [get_files -quiet -filter {FILE_TYPE == IP}]
    }
    return [list $rtl_files $xci_files]
}

#------------------------------------------------------------------------------
# 3. 约束（可选 XDC + 时钟兜底）
#    fpga/soc_up.xdc 是 08 §3.2 约定的"平台约束本地只读拷贝"（尚未落盘；禁止改 chiplab）。
#    它在非工程模式下于 synth_design **之后**读入：引脚/时序约束在实现阶段生效，
#    而 create_clock 后 report_timing_summary 才能给出有意义的 WNS（M4 判据②）。
#------------------------------------------------------------------------------
proc rv32_apply_constraints {} {
    global PROJ_ROOT CLK_PERIOD_NS

    set xdc [file join $PROJ_ROOT fpga soc_up.xdc]
    if {[file exists $xdc]} {
        puts "== synth.tcl: read_xdc $xdc（平台约束只读拷贝，08 §3.2）"
        read_xdc $xdc
    } else {
        puts "WARN: 未找到 fpga/soc_up.xdc（08 §3.2 约定的平台约束只读拷贝尚未落盘）⇒ 跳过 read_xdc"
    }

    if {[llength [get_clocks -quiet]] == 0} {
        if {[llength [get_ports -quiet aclk]] > 0} {
            create_clock -period $CLK_PERIOD_NS -name aclk [get_ports aclk]
            puts "WARN: 约束中无时钟定义 ⇒ 临时 create_clock aclk -period ${CLK_PERIOD_NS}ns"
            puts "WARN:   （占位，仅让时序报告可判读；fpga/soc_up.xdc 到位后本条应由平台约束提供）"
        } else {
            puts "WARN: 既无时钟约束、顶层也没有 aclk 端口（core_top 尚未落盘？）⇒ 时序报告不含时钟"
        }
    } else {
        puts "== synth.tcl: 已有时钟约束：[get_clocks -quiet]"
    }
}

#------------------------------------------------------------------------------
# 4. 报告落盘（M4 判据②③）
#------------------------------------------------------------------------------
proc rv32_report {tag} {
    global OUT_DIR
    set util   [file join $OUT_DIR "${tag}_utilization.rpt"]
    set utilh  [file join $OUT_DIR "${tag}_utilization_hier.rpt"]
    set timing [file join $OUT_DIR "${tag}_timing_summary.rpt"]

    report_utilization -file $util
    report_utilization -hierarchical -file $utilh
    report_timing_summary -file $timing

    set wns "n/a"
    if {[catch {set wns [get_property SLACK [get_timing_paths -delay_type max -max_paths 1]]} err]} {
        set wns "n/a"
    }
    puts "== $tag: 报告 ⇒ $util | $utilh | $timing"
    puts "== $tag: WNS(max) = $wns ns（M4 判据②：60 MHz 约束下要求 WNS >= 0）"
}

#------------------------------------------------------------------------------
# 5. 综合主流程（被 impl.tcl 以 ::RV32_SYNTH_DEFS_ONLY 抑制）
#------------------------------------------------------------------------------
if {![info exists ::RV32_SYNTH_DEFS_ONLY]} {
    if {[catch {
        rv32_read_design
        # 综合：-top core_top（平台例化名，08 §4）。$IP_MACRO 的默认值就是宏名字面量
        # RV32GC_USE_VIVADO_IP（见 §0），故下面一行逐字等价于任务口径：
        #     synth_design -top core_top -part xc7a200tfbg676-2 -verilog_define RV32GC_USE_VIVADO_IP
        puts "== synth.tcl: synth_design -top $TOP -part $PART -verilog_define $IP_MACRO"
        synth_design -top $TOP -part $PART -verilog_define $IP_MACRO
        puts "== synth.tcl: 宏 $IP_MACRO 已定义（综合走 Vivado IP 分支；仿真回归从不定义该宏）"
        rv32_apply_constraints
        rv32_report synth
        set dcp [file join $OUT_DIR post_synth.dcp]
        write_checkpoint -force $dcp
        puts "== synth.tcl 完成：报告 $OUT_DIR/synth_*.rpt；检查点 $dcp"
        puts "== synth.tcl 提示：实现流程用 ./fpga/run_vivado_batch.sh fpga/tcl/impl.tcl"
    } err]} {
        puts stderr "ERROR: synth.tcl 失败：$err"
        puts stderr $::errorInfo
        exit 1
    }
}
