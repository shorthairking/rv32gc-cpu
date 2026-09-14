# 验证：切到 Manual Compile Order（source_mgmt_mode None）能否绕过失效的自动层次引擎
set R   /home/shorthair/dsh/rv32-cpu/rv32gc-cpu
set OUT $R/fpga/out/probe5
file mkdir $OUT

# ---------- A) 平凡文件 + manual mode ----------
set f $OUT/trivial.v
set fh [open $f w]; puts $fh "module foo(input a, output b);\n  assign b = ~a;\nendmodule\n"; close $fh
create_project -force pA $OUT/pA -part xc7a200tfbg676-2
set_property source_mgmt_mode None [current_project]
add_files -norecurse $f
set_property top foo [current_fileset]
update_compile_order -fileset sources_1
puts "A1 top=[get_property top [current_fileset]]"
if {[catch {launch_runs synth_1 -jobs 4} e1]} { puts "A2 launch ERR: $e1" } else {
    wait_on_run synth_1
    puts "A2 run status=[get_property STATUS [get_runs synth_1]] progress=[get_property PROGRESS [get_runs synth_1]]"
}

# ---------- B) 本核 RTL + manual mode（顺带回答 BRAM 推断）----------
create_project -force pB $OUT/pB -part xc7a200tfbg676-2
set_property source_mgmt_mode None [current_project]
set VH [glob -nocomplain "$R/rtl/pkg/*.vh"]
add_files -norecurse $VH
set_property file_type {Verilog Header} [get_files *.vh]
set_property is_global_include true [get_files *.vh]
set VFILES {}
foreach d {pkg decode exec frontend mem csr mmu bus top} { foreach g [glob -nocomplain "$R/rtl/$d/*.v"] { lappend VFILES $g } }
lappend VFILES "$R/fpga/rtl/core_top_synth_wrap.v"
add_files -norecurse $VFILES
set_property top core_top_synth_wrap [current_fileset]
puts "B1 nverilog=[llength [get_files -of [get_filesets sources_1] *.v]] top=[get_property top [current_fileset]]"
set xdc "$OUT/core.xdc"
set fh2 [open $xdc w]
puts $fh2 "create_clock -period 30.303 -name aclk \[get_ports aclk\]"
close $fh2
add_files -fileset constrs_1 -norecurse $xdc
if {[catch {launch_runs synth_1 -jobs 8} e2]} { puts "B2 launch ERR: $e2" } else {
    wait_on_run synth_1
    puts "B2 run status=[get_property STATUS [get_runs synth_1]] progress=[get_property PROGRESS [get_runs synth_1]]"
    if {[get_property PROGRESS [get_runs synth_1]] eq "100%"} {
        open_run synth_1
        set b36 [llength [get_cells -quiet -hier -filter {PRIMITIVE_TYPE =~ BMEM.*.RAMB36*}]]
        set b18 [llength [get_cells -quiet -hier -filter {PRIMITIVE_TYPE =~ BMEM.*.RAMB18*}]]
        set lr  [llength [get_cells -quiet -hier -filter {PRIMITIVE_TYPE =~ BMEM.*.LUTRAM*}]]
        puts "B3 RAMB36=$b36 RAMB18=$b18 LUTRAM=$lr"
    }
}
exit
