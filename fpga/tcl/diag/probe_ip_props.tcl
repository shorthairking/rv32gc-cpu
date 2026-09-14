# 摸清 blk_mem_gen IP 的可配置属性（只为拿到正确的 tcl 参数名/取值，不保留工程）
set OUT /home/shorthair/dsh/rv32-cpu/rv32gc-cpu/fpga/out/ip_probe
file mkdir $OUT
file mkdir $OUT/proj
file mkdir $OUT/ip
create_project -force ipp $OUT/proj -part xc7a200tfbg676-2
set_property source_mgmt_mode None [current_project]
create_ip -name blk_mem_gen -vendor xilinx.com -library ip -version 8.4 -module_name blk_mem_gen_cache -dir $OUT/ip
puts "IPPROBE: created = [get_ips blk_mem_gen_cache]"
set all [list_property [get_ips blk_mem_gen_cache]]
foreach p $all {
    if {[string match "CONFIG.*" $p]} {
        set v [get_property $p [get_ips blk_mem_gen_cache]]
        if {[string match -nocase "*Write_Mode*" $p] || [string match -nocase "*Memory_Type*" $p] ||
            [string match -nocase "*Width*" $p] || [string match -nocase "*Depth*" $p] ||
            [string match -nocase "*Byte*" $p] || [string match -nocase "*Register*" $p] ||
            [string match -nocase "*Algorithm*" $p] || [string match -nocase "*Interface*" $p]} {
            puts "IPPROBE: $p = $v"
        }
    }
}
exit
