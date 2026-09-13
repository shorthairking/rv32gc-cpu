#=============================================================================
# create_clk_wiz_cpu.tcl —— 创建 CPU 时钟 Clocking Wizard IP（MMCM）
#
# 设计依据：docs/design/07-fpga-timing.md §1.1
#   · 输入：板级 clk = 100 MHz（soc_up.xdc 已 create_clock -period 10.000）
#   · 由 Wizard 自动求解 MMCM 参数（VCO 落在 Artix-7 -2 允许的 600~1440 MHz 内）
#   · 输出 CLKOUT0 = cpu_clk；locked 输出用于复位门控
#
# 已在本机 Vivado 2025.2 + xc7a200tfbg676-2 上实测（见 docs/design/07-fpga-timing.md §1.1）：
#   请求 100 MHz → VCO 1000.0 MHz, DIVCLK=1, MULT=10.000, CLKOUT0=10.000 → 100.0000 MHz
#   请求  75 MHz → VCO 1003.1 MHz, DIVCLK=4, MULT=40.125, CLKOUT0=13.375 →  75.0000 MHz
#   请求  60 MHz → VCO  997.5 MHz, DIVCLK=5, MULT=49.875, CLKOUT0=16.625 →  60.0000 MHz
#   请求  50 MHz → VCO 1000.0 MHz, DIVCLK=1, MULT=10.000, CLKOUT0=20.000 →  50.0000 MHz
#
# 用法（在 Vivado 工程上下文内 source，或由 fpga/tcl/build_chiplab.tcl 调用）：
#   vivado -mode batch -source create_clk_wiz_cpu.tcl -tclargs <cpu_mhz>
#   默认 cpu_mhz = 100；支持 100/75/60/50
#
# 注意：
#   1) 不要显式设置 MMCM_CLKFBOUT_MULT_F / MMCM_CLKOUT0_DIVIDE_F ——Wizard 自行求解时
#      这些参数处于 disabled 状态，写入会被忽略（IP_Flow 19-3374 警告）；
#      只需给出 PRIM_IN_FREQ 与 CLKOUT1_REQUESTED_OUT_FREQ，然后读回实际解核对。
#   2) 属性逐条 set 并捕获错误，以兼容不同 clk_wiz 版本的可选属性差异。
#   3) 本沙箱内 Vivado 无法写 $HOME/.Xilinx，运行时需把 HOME 指向工作区内目录
#      （见 docs/kb/06-toolchain-build.md §8）。
#=============================================================================

set cpu_mhz 100
if {[llength $argv] > 0} { set cpu_mhz [lindex $argv 0] }

if {[lsearch -exact {100 75 60 50} $cpu_mhz] < 0} {
    puts "ERROR: 不支持的 CPU_CLK_MHZ=$cpu_mhz（支持 100/75/60/50）"
    exit 1
}

# 关键属性（必须成功）
set critical [list \
    PRIMITIVE                    MMCM \
    PRIM_IN_FREQ                 100.000 \
    PRIM_SOURCE                  Global_buffer \
    CLKOUT1_REQUESTED_OUT_FREQ   $cpu_mhz \
    CLKOUT1_USED                 true \
    USE_LOCKED                   true \
    USE_RESET                    true \
    RESET_TYPE                   ACTIVE_LOW \
]

# 可选项（失败仅告警）
set optional [list \
    RESET_PORT                   resetn \
    MMCM_CLKIN1_PERIOD           10.000 \
    MMCM_CLKIN2_PERIOD           10.000 \
    MMCM_COMPENSATION            ZHOLD \
    MMCM_BANDWIDTH               OPTIMIZED \
    CLKOUT2_USED                 false \
    CLKOUT3_USED                 false \
    CLKOUT4_USED                 false \
    CLKOUT5_USED                 false \
    CLKOUT6_USED                 false \
    CLKOUT7_USED                 false \
]

if {[llength [get_ips -quiet clk_wiz_cpu]] > 0} {
    puts "INFO: 已存在 clk_wiz_cpu，先删除其 IP run 与源文件"
    set old [get_ips clk_wiz_cpu]
    catch {delete_ip_run $old}
    catch {remove_files [get_files -quiet -of_objects $old]}
    catch {export_ip_user_files -no_script -reset}
    if {[llength [get_ips -quiet clk_wiz_cpu]] > 0} {
        puts "ERROR: 无法移除已存在的 clk_wiz_cpu，请删除工程中该 IP 后重试"
        exit 1
    }
}

create_ip -name clk_wiz -vendor xilinx.com -library ip -version 6.0 -module_name clk_wiz_cpu
set ip [get_ips clk_wiz_cpu]

set failed {}
foreach {k v} $critical {
    if {[catch {set_property CONFIG.$k $v $ip} err]} {
        puts "ERROR: 关键属性 CONFIG.$k=$v 设置失败: $err"
        lappend failed $k
    }
}
foreach {k v} $optional {
    if {[catch {set_property CONFIG.$k $v $ip} err]} {
        puts "WARN: 可选属性 CONFIG.$k 不可用（忽略）"
    }
}
if {[llength $failed] > 0} {
    puts "ERROR: 关键属性设置失败，IP 配置无效: $failed"
    exit 1
}

generate_target {instantiation_template synthesis simulation} $ip

# ---- 打印实际解（综合前核对 VCO 与输出频率） ----
set dc [get_property CONFIG.MMCM_DIVCLK_DIVIDE $ip]
set mu [get_property CONFIG.MMCM_CLKFBOUT_MULT_F $ip]
set d0 [get_property CONFIG.MMCM_CLKOUT0_DIVIDE_F $ip]
set vco [expr {100.0 / $dc * $mu}]
set fout [expr {$vco / $d0}]
puts "================ clk_wiz_cpu 实际解 ================"
puts [format "  请求频率            = %s MHz" $cpu_mhz]
puts [format "  VCO                 = %.1f MHz  (DIVCLK=%s, MULT=%s)" $vco $dc $mu]
puts [format "  CLKOUT0_DIVIDE_F    = %s" $d0]
puts [format "  cpu_clk（实际）      = %.4f MHz" $fout]
if {$vco < 600.0 || $vco > 1440.0} {
    puts "  ERROR: VCO 超出 Artix-7 -2 的 MMCM 允许范围 600~1440 MHz！"
    exit 1
} else {
    puts "  VCO 在 Artix-7 -2 允许范围内（600~1440 MHz）✅"
}
puts "==================================================="
