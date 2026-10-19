# 11 板级辅助验证链审计

【结论】限定24文件全部完整read，合计7166行。基线b284df7，源树SHA256 `7cb6b2aeeae1394a3db0575a3040fe71e6c2e20ba6fb22dac889a5924d74aaf4`。确认P1五项，均为验证链失效/证据误判，不新增当前CPU架构缺陷计数。仅静态审计，未执行构建、烧录、xsim、模型生成；历史MDU字段错误不重复报新缺陷。

【变更】仅新增/续写本报告；其他源及既有dirty保持只读。

## 逐文件覆盖（全部1至末行）

路径相对仓库根；完整读取不代表运行验证通过。

|文件|行段|核对重点|
|---|---|---|
|[boot_stub.S](../../../sw/boot/boot_stub.S)|1–184|段表、整字复制、入口/长度|
|[boot_stub.ld](../../../sw/boot/boot_stub.ld)|1–50|链接基址、16KiB ASSERT、丢弃节|
|[build_opensbi_rv32.sh](../../../sw/boot/build_opensbi_rv32.sh)|1–262|构建rc、ELF入口/符号与bin核对|
|[build_spi_image.sh](../../../sw/boot/build_spi_image.sh)|1–443|布局、padding、切片、检查失败|
|[check_stub_layout.sh](../../../sw/boot/check_stub_layout.sh)|1–417|独立解析、真实/仿真payload、update出口|
|[build.sh](../../../sw/m5_board/build.sh)|1–497|工具rc、静态护栏、bin/hex绑定|
|[m5_board.S](../../../sw/m5_board/m5_board.S)|1–1027|R2/MEXT/栈探针、打印、最终判据|
|[verify_m5.sh](../../../sw/m5_board/verify_m5.sh)|1–150|平台/bitstream历史证据与冻结指纹|
|[confreg_axi_filter.v](../../../sw/m5_board/tb/confreg_axi_filter.v)|1–608|五通道、常量模型、R保持/非保持|
|[tb_m5_board.sv](../../../sw/m5_board/tb/tb_m5_board.sv)|1–859|载入、C0–C6、超时、子串与收尾|
|[run_tb.sh](../../../sw/m5_board/tb/run_tb.sh)|1–128|源选择、编译/运行rc、锚点|
|[run_diag_matrix.sh](../../../sw/m5_board/tb/run_diag_matrix.sh)|1–172|三配置、旧RTL反证、A/B比较|
|[make_oldrtl_overlay.sh](../../../sw/m5_board/tb/make_oldrtl_overlay.sh)|1–75|混合快照来源与内容断言|
|[build_ctrl.sh](../../../sw/m5_board/tb/ctrl/build_ctrl.sh)|1–63|缩放构建和工具失败|
|[ct_delay_probe.S](../../../sw/m5_board/tb/ctrl/ct_delay_probe.S)|1–150|独立定量探针，非PASS目标|
|[ct_selftest.S](../../../sw/m5_board/tb/ctrl/ct_selftest.S)|1–202|最小程序/捕获通路自检边界|
|[diff_equiv.py](../../../sw/m5_board/tb/ctrl/diff_equiv.py)|1–86|比较字段与等价判定|
|[make_scaled.py](../../../sw/m5_board/tb/ctrl/make_scaled.py)|1–73|两处确定替换与命中次数|
|[run_ip_div_xsim.sh](../../../sw/m5_board/tb/ip/run_ip_div_xsim.sh)|1–93|IP模型来源、工具rc/锚点|
|[run_mdu_ip_xsim.sh](../../../sw/m5_board/tb/ip/run_mdu_ip_xsim.sh)|1–109|当前/参考源选择、正反例判定|
|[tb_ip_div.v](../../../sw/m5_board/tb/ip/tb_ip_div.v)|1–125|旧字段假设、有限等待|
|[tb_mdu_ip.v](../../../sw/m5_board/tb/ip/tb_mdu_ip.v)|1–123|25向量、done等待、超时|
|[mdu_ipfix.v](../../../sw/m5_board/tb/ip/mdu_ipfix.v)|1–644|修复后副本，与当前源比较|
|[mdu_prefix_ref.v](../../../sw/m5_board/tb/ip/mdu_prefix_ref.v)|1–626|修复前反证副本，非现役DUT|

## 实质问题（静态可推导；最小反证均为建议，未执行）

### 11-01 P1：差分“等价”只约束数量，不检查差异内容

[diff_equiv.py:59–82](../../../sw/m5_board/tb/ctrl/diff_equiv.py#L59-L82)仅拒绝差异为0或大于8；并未断言长度相等、差异地址属于两个delay常量、opcode/寄存器/非立即数字段保持。反汇编仅打印，失败也返回说明串，最终仍可称“全部落在li立即数字对”。触发：冻结hex或scaled任意一个判定分支改变一个字，差异总数仍1..8，即可rc0；甚至尾部相差少数字也可能接受。

影响：矩阵前置以此证明“只缩放挂钟等待”不成立，旧/手改hex可被当当前程序的等价镜像。正常机械生成恰有少量差异，故正常例无法反证判据。最小验证：在隔离副本翻转非delay位置一条branch，要求非零；缺objdump也须拒绝。修复：重建冻结源对应产物，长度相同，按符号/反汇编精确白名单验证允许的li立即数字段，所有其他位逐字相同；不把反汇编展示当机器断言。

### 11-02 P1：三配置矩阵的A/B一致性判据不参与结果

[run_diag_matrix.sh:140–154](../../../sw/m5_board/tb/run_diag_matrix.sh#L140-L154)提取不到捕获串直接exit0；不等只打印“不同”而无非零返回，外层也未更新VERDICT。脚本无`-e`，即便以后Python非零也需显式接入。触发：hold/nonhold各自出现C2/C3及R2FIX正确串，但其它UART字符不同，仍可最终DIAG_MATRIX: OK。与行11所承诺“逐字节相同”不符；UART_PRINT_MAX造成截断时最多比较打印前缀，不是完整队列。

遮蔽：两个正常输出相同只覆盖成功路径。最小反证：两份合法日志仅改非关键一个字符，或删捕获块/截断标记，必须拒绝。修复：必须成功提取完整未截断字节流，比较失败/日志缺失置VERDICT=1，保留原始字节输出而非仅转义显示。旧RTL分支行105还把空/缺失rc当“非0”，应要求数值rc及预期失败原因，而非任意失败即反证。

### 11-03 P1：转换/生成工具失败可被旧产物掩盖

[build_ctrl.sh:12、49–63](../../../sw/m5_board/tb/ctrl/build_ctrl.sh#L49-L63)无`-e`，只累计gcc失败；objdump/objcopy/Python转换rc均不累计，之后照印OK并exit已有rc。有旧bin时objcopy失败可让Python转换旧bin；Python失败可留旧hex并退出0。矩阵虽随后diff_equiv，却受11-01限制，并未重建其冻结输入。

[m5 build.sh:106–135](../../../sw/m5_board/build.sh#L106-L135)同类：objcopy、cp、hex生成失败未直接终止；仅检查大小、首字、诊断bin相等不能证明整个bin/hex来自新ELF。[333–369](../../../sw/m5_board/build.sh#L333-L369)的函数扫描还不检查目标函数是否全部找到、nm rc/解析条数；空syms即可输出“零访存”。不是声称当前工具已经失败，而是确定性失败分支漏捕获。

最小反证：隔离输出中预置旧bin/hex，让objcopy或Python返回非0，应立即非零且不打印最终OK；让nm空输出也应失败。修复：每步rc显式传播、临时目录构建后原子发布，记录ELF/bin/hex全量对应摘要；扫描器必须验证所有目标函数范围存在且非空。正常工具成功不能证明这条故障路径合规。

### 11-04 P1：IP运行错误/超时可误作成功或“缺陷复现”

[run_ip_div_xsim.sh:79–93](../../../sw/m5_board/tb/ip/run_ip_div_xsim.sh#L79-L93)、[run_mdu_ip_xsim.sh:87–109](../../../sw/m5_board/tb/ip/run_mdu_ip_xsim.sh#L87-L109)保存xsim rc，却最终只看日志锚点。正常MDU模式也未要求25个向量/唯一汇总完成；反证模式只要任意`TB_MDU_IP: FAIL `便exit0。[tb_mdu_ip.v:117–120](../../../sw/m5_board/tb/ip/tb_mdu_ip.v#L117-L120)全局超时恰满足该子串。因此IP模型不出结果/运行崩溃可被当商余数缺陷的成功复现；完整PASS日志后工具非0亦可能被认可。

最小反证：隔离工具桩分别输出完整PASS后exit7、只输出全局超时、少量向量后失败，正例/反证都必须拒绝基础设施错误。修复：检查xsim rc=0，唯一完成锚点、精确向量数、无工具ERROR/FATAL，反证要求指定语义错例而非超时。入口无墙钟timeout；TB的有限模拟时间/200拍等待不能兜底工具卡死或零时间循环，应外层加受控timeout。

### 11-05 P1：layout生成模式丢弃前序失败状态

[check_stub_layout.sh:163–220](../../../sw/boot/check_stub_layout.sh#L163-L220)缺payload/镜像或切片不等会设置FAILED；但[363–375](../../../sw/boot/check_stub_layout.sh#L363-L375) update模式在生成仿真字表后无条件STUB_LAYOUT: OK/exit0，跳过[411–417](../../../sw/boot/check_stub_layout.sh#L411-L417)总判定。默认verify分支不受此出口问题影响。

触发：工具链可用、桩/占位程序可汇编，但真实payload或spi镜像缺失，运行update，前面FAIL后仍最终成功；后续CI若只看rc会忽略真实布局验证缺口。遮蔽：只测正常update无法发现。最小反证：隔离副本缺DTB/镜像而其余完整，必须非零或明确“只更新、未验证真实布局”的不同结果类型。修复：更新前检查FAILED，或把生成与真实验证彻底分成两模式，不混用layout OK。

## 已核对的可靠部分与证据边界

- [make_scaled.py:39–55](../../../sw/m5_board/tb/ctrl/make_scaled.py#L39-L55)只有两条固定正则，各要求恰好命中1次；不是随机缩放。生成副本来自当前源文本，但冻结hex未因此自动更新；副本不等于当前发布固件。注释“四个常量”是历史漂移，实际两处。
- [run_tb.sh:93–118](../../../sw/m5_board/tb/run_tb.sh#L93-L118)确实检查编译rc、vvp rc、唯一整行PASS和无FAIL；[tb_m5_board.sv:688–810](../../../sw/m5_board/tb/tb_m5_board.sv#L688-L810)有载入/溢出/碰撞、C1–C6与周期上限。C4仅访问存在性，不比LED序列、开关值/频率精确值；未知地址计数及bad_strb只打印，不参与总判定。控制A无条件打印OK用于捕获通路自检，不是板程序功能反证。
- CONFREG自答是固定SWITCH/FREQ、单时钟每拍timer+1、常量OKAY；DDR_R_NONHOLD在[filter:273–276](../../../sw/m5_board/tb/confreg_axi_filter.v#L273-L276)仅握手拍给数据，适合针对旧“晚拍采样”敏感性实验，不是完整MIG/AXI任意背压证明（RVALID被背压时数据稳定性未覆盖）。板程序[621–637](../../../sw/m5_board/m5_board.S#L621-L637)仅以FREQ>>20==31入判定，div1e6只是打印；常量寄存器不是实际33MHz测量。窗口已明确是信息性，不把降级本身当新bug。
- 启动桩默认三段272080/419888/6192B（后两含补齐），偏移0x4000/0x80000/0xE8000，DDR目的0x01000000/0x02000000/0x03000000；打包检查独立布局常量、实际大小、槽位重叠/XIP 1MiB、编译段表字面值、payload切片。它能证明“这些字节放对位置”，不能证明任意同长度输入就是正确固件；没有全量ELF→payload及工具/源码manifest绑定。OpenSBI构建检查入口和_jump_addr及首字，但FDT常量只全反汇编找lui a0,0x3000，未限制fw_next_arg1范围；git status前后相同也不能证明同为dirty的文件内容未改变。
- 独立layout verify会重建小长度桩/占位字表，然而真实spi镜像只比三个payload，**不比真实桩区与当前源码重新构建结果**；当前源改复制逻辑、只更新仿真字表但保留旧spi桩时，此检查不能证明烧写镜像桩已刷新。建议增加真实桩切片/段表核对及镜像总长/补齐字节检查。此为绑定不足风险，不冒称已观察到旧镜像。
- 只读字节比较：当前[mdu.v](../../../rtl/exec/mdu.v)与[mdu_ipfix.v](../../../sw/m5_board/tb/ip/mdu_ipfix.v)完全相同，SHA256均`db407d152c3d1588788f64e4e77f2402c43fc0432bf93642f97b434822a67689`；prefix SHA256=`758047973d7dddb3964ea496c38a16cb9767515c17b76a0c24306fb976403f20`，保留旧高余低商；当前修复正确，见08，不能以历史副本再报一次。默认MDU入口选当前源，override才换副本；模型文件未绑定当前XCI/Tcl摘要，header latency=34不是本批实测。
- [tb_ip_div.v:86](../../../sw/m5_board/tb/ip/tb_ip_div.v#L86)仍按旧低商高余比对，是历史未适配探针，不应作为当前正向IP合规门禁；不是当前RTL字段又坏。MDU TB有25个固定算术向量，但flush恒0、顺序等待done，不能证明flush/背靠背/顶层流水已覆盖。
- [make_oldrtl_overlay.sh:44–63](../../../sw/m5_board/tb/make_oldrtl_overlay.sh#L44-L63)是当前全树+68ff5fd两个文件的**混合注入模型**，不是整个旧版本；字符串断言只确认旧采样特征。运行入口include仍指当前根/头文件、RTL指纹只记.v，不能将overlay标签当全旧版本绑定。应记录展开source/header列表及摘要，避免目录残留混入。
- [verify_m5.sh:67–83](../../../sw/m5_board/verify_m5.sh#L67-L83)读取外部既有bit/日志/时序文件而无同次构建manifest；DRC的`! grep`在文件不存在时也可成功，hold失败端点虽解析但未判。V5还锁死2026-09-21旧全树md5，所以它是旧交付自检，不能默认为当前2B发布门禁。源码无diff、QEMU通过或核级行为模型通过都不等于当前bitstream已烧录、更不等于真板通过。

【遗留/风险】本批未访问范围外平台/旧scratch大树、Linux/U-Boot/QEMU源码，未运行上述最小反证。2A的core_top核级/历史板级链不代表2B已上板；08/07既有硬件问题不重复计数。建议先收紧五项fail-closed缺口，再以源码+ELF/bin/hex+IP配置/网表+bitstream+板号/烧录记录的同次manifest重建证据链。没有当前WNS、全量原回归或硬件PASS声明。
