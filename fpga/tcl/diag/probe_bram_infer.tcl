# 探针：rv32_bram_dp 是否能被 Vivado 2023.2 推断成 Block RAM（12 个实例 ≈ 两个 Cache 的数据阵列规模）
set R   /home/shorthair/dsh/rv32-cpu/rv32gc-cpu
set OUT $R/fpga/out/bram_probe
file mkdir $OUT

set fh [open $OUT/bram_probe_top.v w]
puts $fh "module bram_probe_top ("
puts $fh "  input wire clk,"
puts $fh "  input wire [11:0] we,"
puts $fh "  input wire [11:0] re,"
puts $fh "  input wire [119:0] waddr_flat,"
puts $fh "  input wire [119:0] raddr_flat,"
puts $fh "  input wire [383:0] wdata_flat,"
puts $fh "  input wire [47:0]  wstrb_flat,"
puts $fh "  output wire [383:0] rdata_flat"
puts $fh ");"
puts $fh "  genvar g;"
puts $fh "  generate for (g = 0; g < 12; g = g + 1) begin : g_mem"
puts $fh "    rv32_bram_dp #(.DEPTH(1024), .DW(32), .AW(10)) u_mem ("
puts $fh "      .clk(clk), .we(we\[g\]), .waddr(waddr_flat\[g*10 +: 10\]), .wdata(wdata_flat\[g*32 +: 32\]),"
puts $fh "      .wstrb(wstrb_flat\[g*4 +: 4\]), .re(re\[g\]), .raddr(raddr_flat\[g*10 +: 10\]),"
puts $fh "      .rdata(rdata_flat\[g*32 +: 32\]));"
puts $fh "  end endgenerate"
puts $fh "endmodule"
close $fh

create_project -force bramp $OUT/proj -part xc7a200tfbg676-2
set_property source_mgmt_mode None [current_project]
add_files -norecurse [list $R/rtl/mem/rv32_bram_dp.v $OUT/bram_probe_top.v]
set_property top bram_probe_top [current_fileset]
if {[catch {launch_runs synth_1 -jobs 8} e]} { puts "BRAMP ERROR launch: $e"; exit 1 }
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} { puts "BRAMP: 综合失败"; exit 1 }
open_run synth_1
set b36 [llength [get_cells -quiet -hier -filter {PRIMITIVE_TYPE =~ BMEM.*.RAMB36*}]]
set b18 [llength [get_cells -quiet -hier -filter {PRIMITIVE_TYPE =~ BMEM.*.RAMB18*}]]
set lut [llength [get_cells -quiet -hier -filter {PRIMITIVE_TYPE =~ BMEM.*.LUTRAM*}]]
set reg [llength [get_cells -quiet -hier -filter {PRIMITIVE_TYPE =~ REGISTER.*}]]
puts "BRAMP: RAMB36=$b36 RAMB18=$b18 LUTRAM=$lut REGS=$reg（期望 RAMB36>0 且 LUTRAM=0、REGS 很小）"
exit
