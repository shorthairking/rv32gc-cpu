# 分层定位：非工程模式解析 vs 工程模式层次解析
set OUT /home/shorthair/dsh/rv32-cpu/rv32gc-cpu/fpga/out/probe4
file mkdir $OUT
set f $OUT/trivial.v
set fh [open $f w]; puts $fh "module foo(input a, output b);\n  assign b = ~a;\nendmodule\n"; close $fh

# ---------- A) 非工程模式（不走工程层次引擎）
if {[catch {read_verilog $f} e]} { puts "A1 read_verilog ERR: $e" } else { puts "A1 read_verilog OK" }
if {[catch {synth_design -rtl -name rtl_a -top foo} e2]} { puts "A2 synth -rtl ERR: $e2" } else { puts "A2 synth -rtl OK" }

# ---------- B) 工程模式
create_project -force p5 $OUT/proj5 -part xc7a200tfbg676-2
add_files -norecurse $f
foreach ff [get_files -of [get_filesets sources_1]] {
    puts "B1 $ff type=[get_property -quiet file_type $ff] used=[get_property -quiet used_in_synthesis $ff] enabled=[get_property -quiet is_enabled $ff]"
}
if {[catch {set_property top foo [current_fileset]} e3]} { puts "B2 set top ERR: $e3" } else { puts "B2 set top OK" }
update_compile_order -fileset sources_1
puts "B3 top=[get_property top [current_fileset]]"
if {[catch {launch_runs synth_1 -jobs 4} e4]} { puts "B4 launch ERR: $e4" } else {
    wait_on_run synth_1
    puts "B4 run progress=[get_property PROGRESS [get_runs synth_1]] status=[get_property STATUS [get_runs synth_1]]"
}
exit
