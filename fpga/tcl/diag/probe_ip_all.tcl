# 转储 blk_mem_gen 的全部 CONFIG.* 属性（一次看清可配置项）
set OUT /home/shorthair/dsh/rv32-cpu/rv32gc-cpu/fpga/out/ip_probe2
file mkdir $OUT/proj
file mkdir $OUT/ip
create_project -force ipp2 $OUT/proj -part xc7a200tfbg676-2
set_property source_mgmt_mode None [current_project]
create_ip -name blk_mem_gen -vendor xilinx.com -library ip -version 8.4 -module_name bmg_cache -dir $OUT/ip
foreach p [lsort [list_property [get_ips bmg_cache]]] {
    if {[string match "CONFIG.*" $p]} {
        puts "IPALL: $p = [get_property $p [get_ips bmg_cache]]"
    }
}
exit
