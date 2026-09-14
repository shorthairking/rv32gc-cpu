# 探针：确认 Vivado 2023.2 在本沙箱下能否读取/解析 workspace 里的 RTL
set R /home/shorthair/dsh/rv32-cpu/rv32gc-cpu
set OUT $R/fpga/out/probe2
file mkdir $OUT

# ① 纯 Tcl 读文件（排除权限问题）
set f $R/rtl/top/core_top.v
puts "PROBE1 exists=[file exists $f] size=[file size $f]"
if {[catch {set fh [open $f r]; set d [read $fh]; close $fh; puts "PROBE2 readlen=[string length $d]"} em]} {
    puts "PROBE2 FAILED: $em"
}

# ② 建最小工程 + 加一个文件，看属性
create_project -force p2 $OUT/proj -part xc7a200tfbg676-2
puts "PROBE3 source_mgmt_mode=[get_property source_mgmt_mode [current_project]]"
add_files -norecurse $f
puts "PROBE4 nfiles=[llength [get_files -of [get_filesets sources_1]]]"
if {[catch {update_compile_order -fileset sources_1} em]} { puts "PROBE5 update_compile_order ERROR: $em" } else { puts "PROBE5 update_compile_order OK" }
puts "PROBE6 top=[get_property top [current_fileset]]"
foreach ff [get_files -of [get_filesets sources_1]] {
    puts "PROBE7 file=$ff exists=[file exists $ff] used=[get_property is_used_in_synthesis $ff] enabled=[get_property is_enabled $ff] type=[get_property file_type $ff]"
}
exit
