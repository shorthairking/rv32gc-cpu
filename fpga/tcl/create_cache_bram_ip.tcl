#==============================================================================
# create_cache_bram_ip.tcl —— 生成 Cache 数据阵列用的 Vivado **Block Memory Generator** IP
#
# 用户口径（第 25 轮）：Cache 数据阵列用板上的 BRAM 资源；**直接例化 Vivado 自带 IP 核**
#   `xilinx.com:ip:blk_mem_gen`（不用 ram_style 推断原语）。
#
# 生成物：模块名 `bmg_cache_1024x32`
#   · Interface Type      = Native
#   · Memory Type         = Simple Dual Port RAM（端口 A 只写 / 端口 B 只读）
#   · 1024 × 32 bit（= 128 组 × 8 字/行 ⇒ 每个 way 一个实例，正好 32 KB/8 路）
#   · Byte-Write Enable   = true（Byte_Size = 8 ⇒ wea[3:0]）
#   · 读延迟 = 1 拍（Port A/B 的额外输出寄存器全部关闭；BRAM 自带输出寄存器）
#   · Enable_B = Always_Enabled（读端口无 enb 引脚 ⇒ 每拍无条件读，与 rv32_cache_bram 的行为模型一致）
#   · 不加载初始化文件（Cache 上电不初始化，valid 位负责有效性）
#
# 用法（在已 open_project/create_project 的上下文里 source）：
#   set IP_DIR <放 IP 的目录>          ;# 例：工程内 $PROJDIR/ip 或仓库 fpga/out/<run>/ip
#   source fpga/tcl/create_cache_bram_ip.tcl
# 幂等：IP 已存在则跳过创建，只确认 verilog_define。
#==============================================================================
if { ![info exists IP_DIR] } {
    puts "ERROR: create_cache_bram_ip.tcl 需要先设置变量 IP_DIR"; exit 1
}
file mkdir $IP_DIR

set IP_NAME bmg_cache_1024x32
if { [llength [get_ips -quiet $IP_NAME]] == 0 } {
    puts "== 创建 IP $IP_NAME（blk_mem_gen 8.4，Simple Dual Port 1024x32，字节写使能，读延迟 1）=="
    create_ip -name blk_mem_gen -vendor xilinx.com -library ip -version 8.4 \
              -module_name $IP_NAME -dir $IP_DIR
    set_property -dict [list \
        CONFIG.Interface_Type        {Native} \
        CONFIG.Memory_Type           {Simple_Dual_Port_RAM} \
        CONFIG.Use_Byte_Write_Enable {true} \
        CONFIG.Byte_Size             {8} \
        CONFIG.Write_Width_A         {32} \
        CONFIG.Write_Depth_A         {1024} \
        CONFIG.Read_Width_B          {32} \
        CONFIG.Enable_A              {Use_ENA_Pin} \
        CONFIG.Enable_B              {Always_Enabled} \
        CONFIG.Register_PortA_Output_of_Memory_Primitives {false} \
        CONFIG.Register_PortB_Output_of_Memory_Primitives {false} \
        CONFIG.Register_PortB_Output_of_Memory_Core       {false} \
        CONFIG.Load_Init_File        {false} \
        CONFIG.Algorithm             {Minimum_Area} \
    ] [get_ips $IP_NAME]
    generate_target {instantiation_template synthesis} [get_ips $IP_NAME]
} else {
    puts "== IP $IP_NAME 已存在，跳过创建 =="
}
puts "== IP 就绪：$IP_NAME；属性核对 Memory_Type=[get_property CONFIG.Memory_Type [get_ips $IP_NAME]] WidthA=[get_property CONFIG.Write_Width_A [get_ips $IP_NAME]] DepthA=[get_property CONFIG.Write_Depth_A [get_ips $IP_NAME]] ByteWE=[get_property CONFIG.Use_Byte_Write_Enable [get_ips $IP_NAME]] =="

# RTL 里用 `ifdef RV32_BRAM_IP` 选择 IP 分支 ⇒ 综合时必须打开该宏（**追加**，不覆盖已有定义）
set _defs [get_property verilog_define [current_fileset]]
if { [lsearch -exact $_defs RV32_BRAM_IP] < 0 } { lappend _defs RV32_BRAM_IP }
set_property verilog_define $_defs [current_fileset]
puts "== verilog_define = [get_property verilog_define [current_fileset]] =="
