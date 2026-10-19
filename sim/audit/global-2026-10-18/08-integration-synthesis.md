# 08：2A集成、综合/IP与板级边界静态审计

【结论】基线 HEAD b284df704e4b0984cef8fa8062ada01656eca287；BASELINE 源树 SHA256=7cb6b2aeeae1394a3db0575a3040fe71e6c2e20ba6fb22dac889a5924d74aaf4。仅静态审计，未运行编译/lint/仿真/Vivado。当前确认 P1 四项（08-01/02/03/05），P2 一项（08-04）；不将历史综合告警或 d00eb03 的时序数字当成当前结果。下述前两项是源码可达条件下的周期推导，仍需定向动态反证。

【变更】仅新建本报告；产品、测试与既有dirty文档保持只读。

## 主责覆盖深度（实际读取，不等同验证通过）

|文件|实际覆盖|深度/边界|
|---|---|---|
|[core_top.v](../../../rtl/top/core_top.v)|1–4226全读|48端口、FD/DE/EM/MW、E派发、M路由/FSM、异常/中断、AXI登记与完成、FP CSR逐段；无动态验证|
|[core_params.vh](../../../rtl/pkg/core_params.vh)|1–260全读|复位PC、地址、时钟、cache几何、宏与ISA声明|
|[rv32_defs.vh](../../../rtl/pkg/rv32_defs.vh)|1–646全读|编码/位域/窗口/重复宏静态核对；未逐宏证明所有调用|
|[rob_wide_mem.v](../../../rtl/back2/rob_wide_mem.v)|1–162全读|SDP端口、read_first、同步输出复位、无存储初始化|
|[front4_mem.v](../../../rtl/front4/front4_mem.v)|1–289全读|TDP/SDP读写、INIT、复位、碰撞分支|
|[bpu_btb.v](../../../rtl/front4/bpu_btb.v)|1–213全读|条目valid/tag、LRU、复位与wrapper调用|
|[cache_array_bram.v](../../../rtl/cache/cache_array_bram.v)|1–179全读|固定IP规格/参数检查、字节写、B读、A输出无消费者说明|
|[mdu.v](../../../rtl/exec/mdu.v)|1–644全读|共享符号/特例、IP发射、商余数字段、done驱动与历史声明|
|[synth.tcl](../../../fpga/tcl/synth.tcl)|1–338全读|递归RTL source-set、top/tag、IP读取、宏、约束、报告|
|[create_ip.tcl](../../../fpga/tcl/create_ip.tcl)|1–339全读|mult signedness/延迟、div unsigned/握手、BMG read-first配置|
|[impl.tcl](../../../fpga/tcl/impl.tcl)|1–188全读|DCP选择、时钟覆盖、布局策略、报告成功语义|
|[report_timing_detail.tcl](../../../fpga/tcl/report_timing_detail.tcl)|1–76全读|检查点重分析范围；非当前时序证据|
|[soc_up.xdc](../../../fpga/soc_up.xdc)|1–31全读|仅aclk create_clock，无false_path，无I/O delay|
|[run_vivado_batch.sh](../../../fpga/run_vivado_batch.sh)|1–150全读|环境/参数/pipefail/退出码；未执行|

全RTL宏检索覆盖 RV32GC_USE_VIVADO_IP/SYNTHESIS/read_first/READ_FIRST；命中不代表每个非主责文件全读。辅助 [front4_table_2lu_1upd.v](../../../rtl/front4/front4_table_2lu_1upd.v) 全读1–87，确认A口训练读消费者。

## 实质问题

### 08-01 P1：整数load依赖的多拍执行器提前采旧操作数

证据：[core_top.v:1196–1206](../../../rtl/top/core_top.v#L1196-L1206)、[1231–1233](../../../rtl/top/core_top.v#L1231-L1233)、[3244–3245](../../../rtl/top/core_top.v#L3244-L3245)、[3338–3342](../../../rtl/top/core_top.v#L3338-L3342)、[3517–3534](../../../rtl/top/core_top.v#L3517-L3534)。

触发：让旧x5=3、内存=7，连续 `lw x5,0(a0); mul x6,x5,x7`（x7=2）；DIV/REM同类。当lw在EM、消费者在DE且访存尚未完成时，m_mem_done=0，M旁路无效，load_use_stall和m_busy虽挡pipe_adv，却未挡e_mdu_go。MDU在首次start采到旧3，issued锁住不再重发；load完成后只解除流水停顿，不重算已锁存的6（应14）。[mdu.v:579–587](../../../rtl/exec/mdu.v#L579-L587)直接证明start采样。`lw x5,...; fcvt.s.w f1,x5` / `fmv.w.x f1,x5`同理：FPU go只挡fp_load_use_stall，整数源e_rs1_byp仍可旧。

影响：合法依赖序列静默错误，IP与行为分支均受影响。测试遮蔽：单元执行器直接给稳定输入不含流水依赖；有间隔指令/取指气泡可让load先完成；FP load-use专项不是整数→FP专项。最小验证：缓存/快取指布置上述相邻指令，数据读施加背压，比较签名并断言 `load_use_stall && e_need_mdu -> !e_mdu_go`；整数源FP同样断言。修复：派发必须受真实源就绪门控（至少整数load-use），不能仅冻结流水；设置无依赖控制与注入去门控反证。

### 08-02 P1：BRU在M阻塞时重定向并清掉尚未推进的自身

证据：[core_top.v:1183–1185](../../../rtl/top/core_top.v#L1183-L1185)、[1663–1665](../../../rtl/top/core_top.v#L1663-L1665)、[3443–3445](../../../rtl/top/core_top.v#L3443-L3445)、[3461–3464](../../../rtl/top/core_top.v#L3461-L3464)、[3566–3575](../../../rtl/top/core_top.v#L3566-L3575)。

触发：`lw x5,0(a0); jal x1,target`，lw在M等待R，jal在E；bru_redirect与pipe_adv无关，可为1，而EM仅在em_go=pipe_adv时接收jal。该沿FD/DE无条件因bru_redirect清valid，jal却未进入EM，链接寄存器写回及该条提交丢失。`lw x5,...; beq x5,x0,target`若旧x5=0、载入非零，则还会用旧旁路值产生错误taken并丢分支；这是“暂停后重新比较”无法挽回的。

影响：丢JAL/JALR链接、丢提交或错误控制流。测试遮蔽：无M背压/取指足够慢时重定向恰与推进同拍；仅看最终顺序结果可能漏链接/计数。最小验证：连续片段+延迟数据读，记录每条提交和x1，断言 `bru_redirect -> em_go`（或实现等价的保留/一次性重定向协议）。修复：仅在分支源就绪且自身可推进时发送重定向/清年轻槽，或保留分支直到EM接收；加入不依赖load但M阻塞的JAL控制以区分两根因。

### 08-03 P1：实现入口忽略综合TOP_TAG，可能实现2A旧DCP却标为2B

证据：[synth.tcl:48–59](../../../fpga/tcl/synth.tcl#L48-L59)、[327–330](../../../fpga/tcl/synth.tcl#L327-L330)生成带TOP_TAG的DCP；[impl.tcl:87–90](../../../fpga/tcl/impl.tcl#L87-L90)、[118–122](../../../fpga/tcl/impl.tcl#L118-L122)却仅选择无tag的post_synth[_period]，不校验设计top/源hash。设置RV32_SYNTH_TOP=core_top_2b且已有2A默认DCP时，impl日志TOP可称2B，实际open 2A；rv32_report又加2B标签，形成误标资源/时序证据。即使不跨top，源码变化也不触发DCP新鲜性检查。

测试遮蔽：只检查时钟周期不能识别top/源；首次无DCP的自综合路径反而正常。最小反证：不运行Vivado亦可静态展开变量，2B综合输出名与impl选入名不相等；后续授权工具验证应检查checkpoint DESIGN/top及源摘要并故意放错DCP要求拒绝。修复：选择路径统一TOP_TAG、核对top/part/源码hash/宏/策略；显式选择旧checkpoint时标为历史，不归因当前源。

### 08-04 P2：front4 wrapper并非声明的逐拍等价模型

证据：[front4_mem.v:98–105](../../../rtl/front4/front4_mem.v#L98-L105)、[146–163](../../../rtl/front4/front4_mem.v#L146-L163)、[239–255](../../../rtl/front4/front4_mem.v#L239-L255)、[273–283](../../../rtl/front4/front4_mem.v#L273-L283)。TDP IP READ_FIRST在a_en&a_we时A输出读旧地址值；行为模型却只写、保持a_dout。两种行为模型均忽略rst_n，而IP配置同步输出复位到0。行为INIT填数组，IP USE_MEM_INIT=0且不传INIT，无法据源码证明非零INIT一致。

影响分层：wrapper接口差异确认；当前预测器功能影响/板上初值风险未动态证明，不升级为已证实架构错误。A训练读采用独立RMW调度，可能不消费写拍A输出；BTB在复位时清查询valid但不扫描表valid（[bpu_btb.v:179–191](../../../rtl/front4/bpu_btb.v#L179-L191)），冷启动/热复位状态仍需单独界定。最小验证：双分支同驱动，先预写非零、A写与读同拍、en保持/复位、非零INIT首次读，逐拍含X比较；再验证上层是否屏蔽差异。修复：行为读写用独立if并匹配同步输出复位；明确初始化/热复位契约，不能仅靠默认零值假定。

### 08-05 P1：taken控制转移提交边界的中断EPC为顺序地址

证据：[core_top.v:1187](../../../rtl/top/core_top.v#L1187)、[3178](../../../rtl/top/core_top.v#L3178)、[3571](../../../rtl/top/core_top.v#L3571)、[3636](../../../rtl/top/core_top.v#L3636)、[2569–2571](../../../rtl/top/core_top.v#L2569-L2571)；[trap_ctrl.v:253–260](../../../rtl/csr/trap_ctrl.v#L253-L260)。em_n_pcnext恒e_link（PC+2/4），未选taken目标；此值作为commit_pc_next进入trap_ctrl，中断EPC照单全收。触发：无M阻塞时让 `jal x1,target`（或taken branch/JALR）正常推进，于其W提交拍使已使能中断pending。该指令正常提交并清年轻槽，但mepc保存fallthrough；处理器mret执行错误路径，而非target。这与08-02的“未推进即丢分支”独立。

测试遮蔽：软件中断若只打在普通算术边界无法覆盖；下述正式DDR/boot TB关闭外部中断，不检此契约。最小验证：预热取指后精确在taken跳转W拍置pending，读取mepc并mret验证落点；not-taken控制、压缩跳转、间接跳转分别覆盖。修复：将实际架构下一PC随该控制指令传到W，区分链接值与中断next-PC，避免修next-PC破坏JAL链接旁路。

## 已核对、不重复报历史缺陷

- [mdu.v:527–528](../../../rtl/exec/mdu.v#L527-L528)当前商高32/余低32已修；有符号先取绝对值，无符号原值，共享除零/溢出/余数符号修正。乘法IP三种signedness与Tcl一致；除法等待tvalid，顶层等done/锁存，不按固定延迟推进。行为/IP除法完成拍并非严格同拍，源码已明确登记，不能再宣传全面逐拍一致。
- [front4_mem.v:241](../../../rtl/front4/front4_mem.v#L241)、[rob_wide_mem.v:85](../../../rtl/back2/rob_wide_mem.v#L85)均已显式read_first；未把旧漏传作为新缺陷。ROB行为同步输出复位与XPM配置一致，内容不清零，依赖上层valid；cache BMG配置read-first/无输出寄存器/字节写对齐，A输出差异已明确无消费者。
- 顶层48端口声明完整，LOCK高位置0、WID常0；单aclk，aresetn低有效但顶层多数异步、MDU同步、XPM输出同步复位，并非统一异步复位承诺。需要reset覆盖时钟沿且释放满足恢复/移除约束，未证明板级复位同步链。
- XDC只有时钟，没有核内false_path可遮组合错误；但也没有AXI/中断/调试I/O预算，核内WNS不等于整板边界闭合。脚本会打印OK而不以负WNS退出（impl:178），OK仅流程成功，不是时序达标；无当前综合不得称当前WNS。
- 参数头重复XLEN/PMP等目前值一致；AQ/RL位宏注释/值需跨域核查（defs:144–145为25/24，与同段指令说明26/25不一致），本域不重复计数为已证集成功能错误。

## 正式启动/DDR测试的判定与边界补查

实际重点读取：[tb_boot_stub.sv](../../../sim/unit/tb_boot_stub.sv) 1–100、280–604、760–902；[tb_m3_ddr3.sv](../../../sim/unit/tb_m3_ddr3.sv) 325–394、490–1000；其余段仅检索，不声称902/1000行全读。boot的MAGIC超时fatal（783–800）、签名等待有界、最终fails==0才PASS（893–898）；M3同样超时fatal（845–867）、case-inequality比计数与数据、fails==0才PASS（990–996）。已有XIP/MMIO/Flash错位反证入口，但本轮未执行，不能给其有效性动态结论。

两TB均常量OKAY应答（boot:415/422；M3:558/565），不注入SLVERR/DECERR；rdata由保持地址组合读（boot:414；M3:557），非RVALID拍仍是旧数据，因而能遮蔽“完成拍晚于握手却误取实时总线”的已修历史缺陷；不能据它们通过宣称非保持型MIG/互连读数据契约已验证。二者reset跨多个时钟沿、负沿释放（boot:289–293；M3:335–340），不覆盖短复位脉冲/停止时钟/任意相位释放。M3 intrpt=0且明确mie=0（386），boot intrpt=0（313），没有taken控制转移边界中断/EPC判据。boot payload是占位程序，不是实际OpenSBI/U-Boot执行验证；M3计数证明访存模式与截获，不是DDR PHY训练、板级CDC或整板时序闭合。建议将上述边界各立独立定向用例，保留当前测试的窄结论，不把测试未覆盖本身混计为硬件bug。

【遗留/风险】未运行综合/当前全量原回归，未使用历史未适配探针充当新缺陷证据。板级sw入口尚未逐文件全读，不作全覆盖结论；非主责FPU宏分支未全读；全RTL的未驱动网/组合环/latch无工具级证明，仅主责静态未见新增大组合always。额外候选（不计入确认数）：[core_top.v:3779](../../../rtl/top/core_top.v#L3779) IDLE无条件清m_exc_q，若M故障完成而E长延迟使pipe_adv=0，可能在入W前丢异常；应以故障load→不相关长除法并延迟E完成验证，检查fault状态是否保持到MW接收。此项已向母报告、集成动态反证待验证。
