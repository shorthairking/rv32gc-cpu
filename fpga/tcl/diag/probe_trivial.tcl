# 对照探针：用平凡 Verilog 判断是环境问题还是本核 RTL 问题
set OUT /home/shorthair/dsh/rv32-cpu/rv32gc-cpu/fpga/out/probe3
file mkdir $OUT
set f $OUT/trivial.v
set fh [open $f w]
puts $fh "module foo(input a, output b);\n  assign b = ~a;\nendmodule\n"
close $fh

create_project -force p3 $OUT/proj -part xc7a200tfbg676-2
add_files -norecurse $f
if {[catch {update_compile_order -fileset sources_1} em]} { puts "T1 update ERROR: $em" } else { puts "T1 update OK" }
puts "T2 TOP=[get_property top [current_fileset]]"
puts "T3 files=[llength [get_files -of [get_filesets sources_1]]]"

# 再单独测我们核的一个文件（不带 .vh 依赖的模块）
set g /home/shorthair/dsh/rv32-cpu/rv32gc-cpu/rtl/exec/rv32_alu.v
add_files -norecurse $g
if {[catch {update_compile_order -fileset sources_1} em2]} { puts "T4 update2 ERROR: $em2" } else { puts "T4 update2 OK" }
puts "T5 TOP=[get_property top [current_fileset]]"

# 直接调综合器解析（绕过工程层次解析）
if {[catch {synth_design -rtl -name rtl_0 -top foo} em3]} { puts "T6 synth ERROR: $em3" } else { puts "T6 synth_design -rtl OK" }
exit
