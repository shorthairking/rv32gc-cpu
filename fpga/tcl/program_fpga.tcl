#==============================================================================
# program_fpga.tcl —— 下载 bitstream 到 FPGA（Vivado Hardware Manager，批量模式）
#
# 用法：
#   vivado -mode batch -notrace -source fpga/tcl/program_fpga.tcl \
#          -tclargs <bit文件> [<hw_target_filter>]
#   例：-tclargs /home/.../fpga/out/system_run.bit
#
# 说明：下载线接通、板子上电后运行；脚本只做 open_hw_manager → 连目标 → 选器件 → 下载。
#       SPI flash 的烧写（programmer_by_uart.bit + 串口 xmodem）见 docs/porting/07-board-bringup-plan.md §1 与 §2.4。
#==============================================================================
if { $argc < 1 } { puts "用法: -tclargs <bit文件> \[hw_target\]"; exit 1 }
set BIT [lindex $argv 0]
set TGT [expr {$argc >= 2 ? [lindex $argv 1] : ""}]

if { ![file exists $BIT] } { puts "ERROR: 找不到 bit 文件: $BIT"; exit 1 }

open_hw_manager
connect_hw_server -allow_non_jtag
if { $TGT ne "" } {
    open_hw_target $TGT
} else {
    set targets [get_hw_targets]
    puts "== 可用下载目标: $targets =="
    if { [llength $targets] == 0 } { puts "ERROR: 没有检测到下载目标（检查线缆/上电）"; exit 1 }
    open_hw_target [lindex $targets 0]
}
set dev [lindex [get_hw_devices] 0]
puts "== 器件: $dev =="
current_hw_device $dev
refresh_hw_device -update_hw_probes false $dev

set_property PROGRAM.FILE $BIT $dev
program_hw_devices $dev
refresh_hw_device $dev
puts "== PROGRAM_FPGA: DONE（$BIT 已下载）=="
close_hw_manager
