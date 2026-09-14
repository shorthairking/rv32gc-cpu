#==============================================================================
# fpga/tcl/create_ip.tcl —— Vivado IP 生成脚本（AGENT.md §4 红线 1 证据留档）
#==============================================================================
# 项目 : rv32gc-cpu（阶段二 2A：单发射顺序 5 级基线核）
# 依据 : AGENT.md §4 红线 1（禁止原语，先用 Vivado IP）；
#        红线 2（IP 必须配仿真行为模型双分支）；
#        docs/design/08-baseline-5stage.md §5.3（E 级执行部件）与 §3.2/§7.3
#        （IP 双分支范式）；用户指令 2026-09-14（MDU 用 mult_gen/div_gen 实现）。
#
# ★ 红线 1 证据留档（本脚本即证据本体）：
#     * 乘法器 = **Multiplier IP**（`mult_gen`，PG108），
#       `Multiplier_Construction=Use_Mults` ⇒ 走 DSP48 硬件乘法器（非 LUT 拼接）；
#       输出 64 位完整积（PortAWidth=PortBWidth=32 ⇒ P[63:0]）。
#     * 除法器 = **Divider Generator IP**（`div_gen`，PG151），
#       `algorithm_type=Radix2`（逐位恢复余数，省 DSP）。
#     * 二者都是 **IP**（IP Catalog 例化），**不是 FPGA 原语**
#       （本脚本与 RTL 均只做 IP 例化，不例化任何 FPGA 原语（Primitive））。
#     * 备选已排除：DSP Macro（原语级界面，红线 1 明确不选）、
#       Complex Multiplier（复数语义不符）。
#
# ★ 后续追加约定（本文件按分节组织，集成阶段直接在对应分节后追加即可）：
#     ## mult_gen / ## div_gen / ## blk_mem_gen（Cache 阵列，08 §7.3）/
#     ## fpu（浮点 IP，如后续需要）/ ## 其他
#
# 用法 :
#     ① 独立运行（推荐，IP 落到 <repo>/fpga/ip）：
#          vivado -mode batch -notrace -source fpga/tcl/create_ip.tcl
#        或显式给目录/器件：
#          vivado -mode batch -notrace -source fpga/tcl/create_ip.tcl \
#                 -tclargs <ip_out_dir> <part>
#     ② 集成阶段复用：synth.tcl 里在已打开工程上下文中 `source` 本文件
#        （脚本检测到已存在的 IP 时只刷新配置 + 重新 generate_target，幂等）。
#
# 版本口径（实测）：本机现用 Vivado 2023.2 随附 `mult_gen 12.0` / `div_gen 5.1`
#     （2026-09-14 用 create_ip + generate_target 实测通过，端口/延迟见下）。
#     脚本按「优先用下面钉住的版本；若该版本在当机 Vivado 中不存在，则自动取
#     该 IP 的最新可用版本并打印 WARN」处理 —— 换 Vivado 版本（如 2025.2）时
#     无需改脚本，只会打印一条 WARN。
#
# ★ 与 RTL 的接口契约（`rtl/exec/mdu.v` 综合分支逐字对应，改此处必须同步改 RTL）：
#     rv32_mult_signed   : .A(a[31:0]) .B(b[31:0]) → .P[63:0]   （纯组合，无 CLK）
#     rv32_mult_su       : 同上（A 有符号 / B 无符号）
#     rv32_mult_unsigned : 同上（A/B 均无符号）
#     rv32_div           : aclk/aclken/aresetn + s_axis_{divisor,dividend}_t{valid,data}
#                          → m_axis_dout_t{valid,data[63:0]}，tdata = {余数[63:32], 商[31:0]}
#     乘法器 `PipeStages=0` ⇒ C_LATENCY=0（纯组合输出，与仿真分支的 2 拍时序一致）；
#     除法器 radix-2 32/32 的握手延迟由 IP 给出（`latency`），RTL 以 `m_axis_dout_tvalid`
#     为完成标志，不假设固定拍数（见 mdu.v 头注「两分支时序口径」）。
#==============================================================================

#------------------------------------------------------------------------------
# 0. 运行参数
#------------------------------------------------------------------------------
set SCRIPT_DIR [file normalize [file dirname [info script]]]              ;# .../fpga/tcl
set PROJ_ROOT  [file normalize [file join $SCRIPT_DIR .. ..]]             ;# .../rv32gc-cpu
set IP_DIR_DEF [file normalize [file join $PROJ_ROOT fpga ip]]            ;# .../fpga/ip
set PART_DEF   "xc7a200tfbg676-2"                                         ;# AGENT.md §2 平台器件

set IP_DIR $IP_DIR_DEF
set PART   $PART_DEF
if {[llength $argv] >= 1 && [lindex $argv 0] ne ""} { set IP_DIR [lindex $argv 0] }
if {[llength $argv] >= 2 && [lindex $argv 1] ne ""} { set PART   [lindex $argv 1] }

puts "== create_ip.tcl：IP_DIR = $IP_DIR"
puts "== create_ip.tcl：PART   = $PART"

# ---- 工程上下文：没有打开的工程时用 in-memory 工程（够 create_ip/generate_target） ----
if {[catch {current_project -quiet} cur] || $cur eq ""} {
    create_project -in_memory -part $PART
    puts "== create_ip.tcl：无打开工程 ⇒ 已创建 in-memory 工程（part=$PART）"
}
set_property target_language Verilog [current_project]
set_property ip_output_repo [file join $IP_DIR ".." "ip_cache"] [current_project]
file mkdir $IP_DIR

#------------------------------------------------------------------------------
# 1. 工具 proc：IP 版本解析 / 创建或刷新 / 配置自检
#------------------------------------------------------------------------------
# 列出当机 Vivado IP Catalog 中该 IP 的所有版本（如 {12.0} / {5.1}）
# 注意（实测 2026-09-14，Vivado 2023.2）：`get_ipdefs` **不接受** -vendor/-library/-version，
#   只支持 VLNV 通配或 `-filter`；返回形如 "xilinx.com:ip:mult_gen:12.0"（第 4 段 = 版本）。
proc ip_catalog_versions {ipname} {
    set defs [get_ipdefs -quiet -filter "NAME==$ipname"]
    if {[llength $defs] == 0} {
        set defs [get_ipdefs -quiet *${ipname}*]      ;# 退化路径：通配匹配
    }
    set vers {}
    foreach d $defs {
        set parts [split $d ":"]
        if {[llength $parts] >= 4} { lappend vers [lindex $parts 3] }
    }
    return $vers
}

# 解析实际使用的版本：钉住版本优先；不存在则取最新可用版本并 WARN（不静默降级）
proc resolve_ip_version {ipname pinned} {
    set vers [ip_catalog_versions $ipname]
    if {[llength $vers] == 0} {
        error "IP Catalog 中没有 '$ipname'（检查 Vivado 安装与器件族许可）"
    }
    if {[lsearch -exact $vers $pinned] >= 0} { return $pinned }
    set newest [lindex [lsort -decreasing -real $vers] 0]
    puts "WARN: '$ipname' 版本 $pinned 不在当机 IP Catalog（可用：$vers）⇒ 改用最新版 $newest"
    return $newest
}

# 创建 IP（幂等：已存在则跳过创建，只保留后续 set_property / generate_target 刷新）
# ★ 各 IP 的 `create_ip` 调用**逐个写在本文件里、IP 名与行内**（不封装成通用 proc），
#   目的是让"用了哪个 IP"在脚本里可直接 grep 审查（红线 1 证据可检索）：
#     grep -n "create_ip -name" fpga/tcl/create_ip.tcl
# 配置断言：不满足即 error（fail-closed；防止脚本"看起来跑完了"却配错）
proc assert_cfg {modname prop expect} {
    set got [get_property CONFIG.$prop [get_ips $modname]]
    if {"$got" ne "$expect"} {
        error "配置自检失败：$modname 的 CONFIG.$prop 期望 '$expect'，实测 '$got'"
    }
    puts "   自检 OK：$modname.$prop = $got"
}

#==============================================================================
## mult_gen —— 乘法器 IP（Multiplier, PG108；Use_Mults ⇒ DSP48）
#==============================================================================
# 三条乘法语义各一个实例（**不做符号修正拼接**，改正性最直接）：
#   rv32_mult_signed   : A=signed  B=signed    → mulh 取 P[63:32]
#   rv32_mult_su       : A=signed  B=unsigned  → mulhsu 取 P[63:32]
#   rv32_mult_unsigned : A=unsigned B=unsigned → mulhu 取 P[63:32]
#   mul（低 32 位）在三种实例下**同值**（模 2^32），取 rv32_mult_unsigned 的低半部即可。
# ★ 为什么不按"2 个实例 + 修正项"（任务书建议的方案）：任务书建议的
#   「signed×unsigned 实例同时覆盖 mulhsu 与 mulhu」**不成立** —— 反例：
#   a=0x8000_0000、b=0x8000_0000 时，signed×unsigned 高半部 = 0xFFFF_FFFF（-2^62），
#   而 mulhu 要求 0x4000_0000（+2^62，见 sim/unit/tb_mdu.sv 的 mulhu_2p31 向量）。
#   为覆盖全部 4 条指令，要么 3 个实例（本方案，零修正逻辑），要么 2 个实例 + 一个
#   64 位修正加法器。x7a200t 有 740 个 DSP 硬核乘法器，多一个 32×32 乘法的面积代价可忽略，
#   而"每条指令对应一个 signedness 精确匹配的 IP"可审查性最好 ⇒ 采用 3 实例。
set V_MULT [resolve_ip_version mult_gen 12.0]

if {[llength [get_ips -quiet rv32_mult_signed]] == 0} {
    create_ip -name mult_gen -vendor xilinx.com -library ip \
              -version $V_MULT -module_name rv32_mult_signed -dir $IP_DIR
} else { puts "== 已存在，刷新配置：rv32_mult_signed" }
set_property -dict [list \
    CONFIG.MultType                 {Parallel_Multiplier} \
    CONFIG.PortAType                {Signed}   \
    CONFIG.PortBType                {Signed}   \
    CONFIG.PortAWidth               {32}       \
    CONFIG.PortBWidth               {32}       \
    CONFIG.Multiplier_Construction  {Use_Mults} \
    CONFIG.OptGoal                  {Speed}    \
    CONFIG.Use_Custom_Output_Width  {false}    \
    CONFIG.PipeStages               {0}        \
] [get_ips rv32_mult_signed]

if {[llength [get_ips -quiet rv32_mult_su]] == 0} {
    create_ip -name mult_gen -vendor xilinx.com -library ip \
              -version $V_MULT -module_name rv32_mult_su -dir $IP_DIR
} else { puts "== 已存在，刷新配置：rv32_mult_su" }
set_property -dict [list \
    CONFIG.MultType                 {Parallel_Multiplier} \
    CONFIG.PortAType                {Signed}   \
    CONFIG.PortBType                {Unsigned} \
    CONFIG.PortAWidth               {32}       \
    CONFIG.PortBWidth               {32}       \
    CONFIG.Multiplier_Construction  {Use_Mults} \
    CONFIG.OptGoal                  {Speed}    \
    CONFIG.Use_Custom_Output_Width  {false}    \
    CONFIG.PipeStages               {0}        \
] [get_ips rv32_mult_su]

if {[llength [get_ips -quiet rv32_mult_unsigned]] == 0} {
    create_ip -name mult_gen -vendor xilinx.com -library ip \
              -version $V_MULT -module_name rv32_mult_unsigned -dir $IP_DIR
} else { puts "== 已存在，刷新配置：rv32_mult_unsigned" }
set_property -dict [list \
    CONFIG.MultType                 {Parallel_Multiplier} \
    CONFIG.PortAType                {Unsigned} \
    CONFIG.PortBType                {Unsigned} \
    CONFIG.PortAWidth               {32}       \
    CONFIG.PortBWidth               {32}       \
    CONFIG.Multiplier_Construction  {Use_Mults} \
    CONFIG.OptGoal                  {Speed}    \
    CONFIG.Use_Custom_Output_Width  {false}    \
    CONFIG.PipeStages               {0}        \
] [get_ips rv32_mult_unsigned]

# ---- 配置自检（fail-closed） ----
assert_cfg rv32_mult_signed   PortAType              Signed
assert_cfg rv32_mult_signed   PortBType              Signed
assert_cfg rv32_mult_su       PortAType              Signed
assert_cfg rv32_mult_su       PortBType              Unsigned
assert_cfg rv32_mult_unsigned PortAType              Unsigned
assert_cfg rv32_mult_unsigned PortBType              Unsigned
foreach m {rv32_mult_signed rv32_mult_su rv32_mult_unsigned} {
    assert_cfg $m PortAWidth              32
    assert_cfg $m PortBWidth              32
    assert_cfg $m Multiplier_Construction Use_Mults
    assert_cfg $m PipeStages              0
    assert_cfg $m OutputWidthHigh         63      ;# ⇒ P[63:0] 完整积
}

generate_target all [get_ips rv32_mult_signed]
generate_target all [get_ips rv32_mult_su]
generate_target all [get_ips rv32_mult_unsigned]

#==============================================================================
## div_gen —— 除法器 IP（Divider Generator, PG151；Radix2）
#==============================================================================
# 只需**一个** 32/32 无符号实例就能覆盖 div/divu/rem/remu 全部四条指令：
#     * 无符号指令：直接被除数/除数送 IP；
#     * 有符号指令：**先取 |a|、|b| 送 IP，再按 ISA 做符号修正**
#       （商符号 = a^b；余数符号 = 被除数 a —— 与仿真行为模型
#         `div_result()` 的修正口径完全一致，两分支逐位等价）。
# ★ 为什么不用「有符号实例」：PG151 的 Radix2 实现输出的是**幅值商/余数**，
#   符号修正必须由用户在 IP 外做（本设计即如此，见 rtl/exec/mdu.v §7.2）；
#   也就是说再挂一个 signed 实例**并不能省掉任何外部逻辑**，只会让面积翻倍
#   （实测延迟也更长：同一配置 signed=36 拍 vs unsigned=34 拍）。
#   除零 / -2^31÷-1 溢出两条 ISA 特例在 IP 外旁路（与行为模型逐位一致），
#   且除数为 0 时不把 0 送进 IP（改送 1），避免依赖 IP 对 0 除数的未定义行为。
# ★ clk_en(ACLKEN)=1：按任务书要求使能时钟使能端口（RTL 侧恒接 1）；
#   ARESETN=1：供 `flush` 冲刷时清空在途除法（RTL 侧接 aresetn & ~flush）。
set V_DIV [resolve_ip_version div_gen 5.1]

if {[llength [get_ips -quiet rv32_div]] == 0} {
    create_ip -name div_gen -vendor xilinx.com -library ip \
              -version $V_DIV -module_name rv32_div -dir $IP_DIR
} else { puts "== 已存在，刷新配置：rv32_div" }
set_property -dict [list \
    CONFIG.algorithm_type                {Radix2} \
    CONFIG.dividend_and_quotient_width   {32}      \
    CONFIG.divisor_width                 {32}      \
    CONFIG.remainder_type                {Remainder} \
    CONFIG.operand_sign                  {Unsigned} \
    CONFIG.clocks_per_division           {1}       \
    CONFIG.ACLKEN                        {true}    \
    CONFIG.ARESETN                       {true}    \
    CONFIG.FlowControl                   {NonBlocking} \
    CONFIG.latency_configuration         {Automatic} \
] [get_ips rv32_div]

assert_cfg rv32_div algorithm_type              Radix2
assert_cfg rv32_div dividend_and_quotient_width 32
assert_cfg rv32_div divisor_width               32
assert_cfg rv32_div remainder_type              Remainder
assert_cfg rv32_div operand_sign                Unsigned
assert_cfg rv32_div ACLKEN                      true
assert_cfg rv32_div ARESETN                     true

generate_target all [get_ips rv32_div]

puts "== div_gen 实测延迟（latency 参数，输入握手→输出握手）：[get_property CONFIG.latency [get_ips rv32_div]]"
puts "== div_gen 输出 tdata 位宽：[expr {[get_property CONFIG.dividend_and_quotient_width [get_ips rv32_div]] + [get_property CONFIG.fractional_width [get_ips rv32_div]]}]（高半部=余数，低半部=商）"

#==============================================================================
## blk_mem_gen —— Cache 数据/标签阵列（08 §7.3；集成阶段追加）
#==============================================================================
#   预留分节：L1I/L1D/L2 的存储阵列 IP（True Dual Port RAM，勿开 Output Register）
#   由集成阶段按 rtl/cache/cache_array_bram.v / cache_tag_array.v 的例化模板追加。
#   —— 截至本任务（2026-09-14）尚未追加。

#==============================================================================
## 其他 IP（FPU 等；集成阶段追加）
#==============================================================================
#   预留分节：后续若引入浮点 IP / FIFO / Clocking Wizard 等，同样追加在此。

#------------------------------------------------------------------------------
# 9. 结束小结（列出本次生成/刷新的 IP 与关键属性，便于日志审查）
#------------------------------------------------------------------------------
puts "== create_ip.tcl 完成：IP_DIR = $IP_DIR"
foreach m {rv32_mult_signed rv32_mult_su rv32_mult_unsigned rv32_div} {
    puts "   * [format %-20s $m] VLNV=[get_property IPDEF [get_ips $m]]  dir=[get_property IP_DIR [get_ips $m]]"
}
puts "== 提醒：综合脚本（synth.tcl）需 read_ip/read_xci 上述 .xci 并定义 RV32GC_USE_VIVADO_IP"
puts "== 提醒：iverilog/Verilator 回归**不得**定义 RV32GC_USE_VIVADO_IP（红线 2）"
