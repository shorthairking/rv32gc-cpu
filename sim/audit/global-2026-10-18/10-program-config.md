# 10 程序与配置绑定补审

## 【结论】

基线 `b284df7`，源码树摘要 `7cb6b2aeeae1394a3db0575a3040fe71e6c2e20ba6fb22dac889a5924d74aaf4`，见[BASELINE](<BASELINE.json>)。本批 **39文件4565行全部实际read**，无未补截断。新增静态 **P0=0/P1=1/P2=2**；另对03/05/07/09问题补充源程序证据，不重复计数。未仿真、编译、运行生成器或重算黄金；不能据本次阅读宣布源码与固化机器码一致。

## 【变更】

仅新建/续写本报告；原报告、活动程序、配置、RTL均未改动。

## 【证据】

### 新增问题

**P1-10-C1：前端“交替数据相关分支”激励退化，黄金PC亦无法区分该分支方向。**

[front4_int:35–48](<../../unit/prog/front4_int.S#L35-L48>)将x5初值置0，每次循环在beq前后各加1，因此beq处x5恒为奇数，`x8=x5&1`恒1，`beq x8,x0`恒不跳。并且跳转目标`inner_even`正是下一条指令，taken/not-taken的架构下一PC完全相同。触发：按当前源生成并运行前端集成用例。影响：注释宣称的交替方向并未构造；单靠提交PC推导实际方向的后端参照模型也无法区分这个退化分支，不能作为方向恢复双向覆盖证据。其他循环分支仍有真假，故不是“整份程序没有分支”。最小反证：记录该PC的实际分支条件，计taken/NT，应发现taken=0；将该PC方向判定固定后检查黄金PC测试是否仍可接受。建议只在一处递增，taken目标与fall-through分离，独立断言两向命中计数。此项不同于[05](<05-frontend-decode.md#L83>)及[07问题4](<07-test-infrastructure.md>)的无条件黄金纠偏根因。

**P2-10-C2：配置声明并非runner真实单一真源，改字段可能静默不生效。**

[test_config:17–34、43–54](<../../arch_test/test_config.yaml#L17-L54>)宣称工具和相对路径配置、整体挪内存布局；但[runner:125–138](<../../arch_test/run.sh#L125-L138>)仅读出`CFG_CC/CFG_REF/CFG_LD`，实际编译/参考仍用环境工具与固定`LINK_LD`（[89–93](<../../arch_test/run.sh#L89-L93>)、[444–452](<../../arch_test/run.sh#L444-L452>)、[482](<../../arch_test/run.sh#L482>)）。`udb_config`及架构yaml不参与筛选/生成；header为人工独立维护。RAM_BASE/SIZE/BOOT_BASE只用于Spike `-m`，[TB参数:505–512](<../../arch_test/run.sh#L505-L512>)没有覆盖TB的RAM/BOOT窗口；boot_size、clint_base/size也未读取，CLINT固定拼接。触发：按配置文案切换模型、链接器或地址布局。影响：产生“声明已更改，实际仍旧工具/旧DUT模型”的错误归因，部分不一致会报错但并非每项都必然报错。最小反证：只把上述配置字段换成明显不存在路径或改变RAM基址，核对实际命令/参数必须同步变化或入口明确拒绝。建议真正使用并归一化配置路径，或删除伪可配字段并逐项硬校验默认契约；能力选择基于真实header与exclude，不能只看yaml名称。

**P2-10-C3：arch PLIC宏的M基址偏移和S上下文步长均与现役译码不符。**

[rvmodel_macros:141–147](<../../arch_test/rvmodel_macros.h#L141-L147>)给M threshold/claim为`0x1F200000/004`，S enable=`0x1F102004`、threshold=`0x1F200004`、claim=`0x1F200008`。母代理已实际read并确认现役[PLIC:178–181](<../../../rtl/plic/plic.v#L178-L181>)的S enable偏移为0x2080，[195–209](<../../../rtl/plic/plic.v#L195-L209>)的context步长为0x1000、threshold偏移为0x200000；[参数:59](<../../../rtl/pkg/core_params.vh#L59>)基址为0x1F100000，[148–149](<../../../rtl/pkg/core_params.vh#L148-L149>)规定threshold/claim偏移0x00200000/4。两top实际传PA减基址（[2A:2425](<../../../rtl/top/core_top.v#L2425>)、[2B:962](<../../../rtl/top/core_top_2b.v#L962>)）。故正确绝对地址为：M threshold/claim=`0x1F300000/004`；S enable=`0x1F102080`、threshold/claim=`0x1F301000/004`。活动[p15](<../../unit/prog/back2_p15_priv.S#L113-L117>)的M claim也与此一致。

SET/CLR宏在[151–182](<../../arch_test/rvmodel_macros.h#L151-L182>)实际使用错误常量。触发：启用依赖这些宏的外部中断ACT用例；影响：S使能未配置目标上下文，M/S阈值及claim/complete也未访问目标寄存器，测试无法验证预期中断链。宏的S threshold虽在文本上等于其错误M claim常量，**不表示实际会命中现役M claim寄存器**。当前arch外部引脚恒0且[130–131](<../../arch_test/rvmodel_macros.h#L130-L131>)声明不跑外部中断用例，故属于潜伏配置风险，不称默认动态失败。最小反证：授权后分别用宏地址/正确地址访问M/S阈值、使能和claim，要求地址错误被检查器拒绝、合法控制访问目标上下文。建议宏绑定统一映射并加入上下文地址断言。本项01未计此根因，仅计测试宏P2，不新增RTL缺陷；RTL行号证据由母代理实读提供，本子代理未扩大重审算法。

### 绑定与去重结论

- arch入口实质为手工GCC/Spike流水线，不是完整ACT4元数据约束执行器：MARCH来自测试头，筛选来自exclude和include_priv，yaml“fully configured”不证明经过UDB校验。[架构声明:7–12](<../../arch_test/rv32gc-2a.yaml#L7-L12>)已明确人工维护；[配置头](<../../arch_test/rvtest_config.h>)才进入实际编译。其time/计数器、PMP锁、TVM、向量对齐等与RTL差异归[01](<01-privilege.md>)，不重复报硬件问题。
- [sail:23–31](<../../arch_test/sail.json#L23-L31>)把中断发生器标supported=true，但注释明确未建模；runner只取两个base生成编译宏，参考实际为Spike，CLINT窗口作为普通RAM。故中断相关常量“能编译”不等于设备端到端模型存在。
- [arch链接:68–106](<../../arch_test/link.ld#L68-L106>)固定boot/TEST_BASE、数据/栈/rvmodel/tohost并有RAM范围与tohost断言；默认数据、栈与tohost地址未见源级必然重叠。两个back2链接脚本活动SECTIONS同址同偏移，旧注释还说不同基址，但生成器只在前0x1000逐字节检查，不能据此称全部段独立验证。lockstep链接脚本无MEMORY范围约束，当前两程序无栈且只有两代码段，不报告当前必然越界。
- [dm_csr_raw:40–83](<../../arch_test/dm_csr_raw.S#L40-L83>)测距离2/3前未重新换值，第二次mscratch写同值可能被前一组正确值遮蔽；但距离1、旧值及完整签名仍有独立检查，不把“所有RAW距离都已严格区分”当结论。[lock_hello:143–158](<../../lockstep/prog/lock_hello.S#L143-L158>)主动保留CSR间隔，紧邻例在单独csr_hazard而非默认入口；压缩、计数器、浮点也明确排除。这些是窄覆盖，不是缺陷自动消失。
- [p4:13–17、40–77](<../../unit/prog/back2_p4_fpu.S#L13-L77>)主动绕过f0、动态rm和flags；[p10:67–89](<../../unit/prog/back2_p10_csr.S#L67-L89>)排除mip/计数值；p8/p12/p13/p15无Spike黄金而走硬编码TB oracle；p16/p17补FP及flags但无f0。f0及frm根因归[02](<02-backend.md>)、执行断言缺口归[06](<06-execution.md>)，FP-use默认不可达归[07](<07-test-infrastructure.md>)。FP-use源码头称div足以强制C6，实际TB需参数注入，不能用头注代替命中证据。
- [p13:120–123](<../../unit/prog/back2_p13_sv32.S#L120-L123>)明确再补一次sfence以规避在途旧遍历回填，因此它不能证明单次sfence足够。另[p17:63–78](<../../unit/prog/back2_p17_fld_fsd.S#L63-L78>)所谓“跨4K”实际是`0xFF8+4=0xFFC`，8字节全部留在原页，并未设置satp；对齐8B本就不会跨4K。故C18文字不构成第二页翻译证据；与[03 F5](<03-lsq-2b.md#L54-L58>)已指出边界合并，不新增计数。
- boot_probe无栈/CSR，仅写5字邮箱；M1无load/压缩/CSR，只证首取及14字符；DDR程序的7模式与软计数逐项存在，结果清零后最终写MAGIC，首错记录与总错/分模式错均被保留。它们仍是缩减/占位场景，不能外推真实固件或全DDR空间。内嵌首末字/非零字数不会检测任意中间源码改动，未执行生成链不能认定映像已同步。

### 逐文件实际读取清单

下列均为完整read（非只看头）；范围为1至表列末行。

|arch_test文件|末行|lockstep/prog文件|末行|
|---|---:|---|---:|
|[boot_stub.S](<../../arch_test/boot_stub.S>)|23|[csr_hazard.S](<../../lockstep/prog/csr_hazard.S>)|87|
|[dm_csr_raw.S](<../../arch_test/dm_csr_raw.S>)|115|[link.ld](<../../lockstep/prog/link.ld>)|40|
|[dm_htif.S](<../../arch_test/dm_htif.S>)|71|[lock_hello.S](<../../lockstep/prog/lock_hello.S>)|171|
|[dm_smoke.S](<../../arch_test/dm_smoke.S>)|92|||
|[dm_sv32_fetch.S](<../../arch_test/dm_sv32_fetch.S>)|144|||
|[link.ld](<../../arch_test/link.ld>)|109|||
|[rv32gc-2a.yaml](<../../arch_test/rv32gc-2a.yaml>)|90|||
|[rvmodel_macros.h](<../../arch_test/rvmodel_macros.h>)|184|||
|[rvtest_config.h](<../../arch_test/rvtest_config.h>)|92|||
|[sail.json](<../../arch_test/sail.json>)|53|||
|[test_config.yaml](<../../arch_test/test_config.yaml>)|63|||

|unit/prog文件|末行|unit/prog文件|末行|
|---|---:|---|---:|
|[back2_lockstep.ld](<../../unit/prog/back2_lockstep.ld>)|27|[back2_lockstep_spike.ld](<../../unit/prog/back2_lockstep_spike.ld>)|22|
|[front4_int.ld](<../../unit/prog/front4_int.ld>)|12|[front4_int.S](<../../unit/prog/front4_int.S>)|82|
|[back2_p1_int.S](<../../unit/prog/back2_p1_int.S>)|62|[back2_p2_branch.S](<../../unit/prog/back2_p2_branch.S>)|70|
|[back2_p3_memcsr.S](<../../unit/prog/back2_p3_memcsr.S>)|53|[back2_p4_fpu.S](<../../unit/prog/back2_p4_fpu.S>)|127|
|[back2_p5_mdu.S](<../../unit/prog/back2_p5_mdu.S>)|90|[back2_p6_l1d.S](<../../unit/prog/back2_p6_l1d.S>)|71|
|[back2_p7_trap.S](<../../unit/prog/back2_p7_trap.S>)|107|[back2_p8_int.S](<../../unit/prog/back2_p8_int.S>)|134|
|[back2_p9_trapvec.S](<../../unit/prog/back2_p9_trapvec.S>)|124|[back2_p10_csr.S](<../../unit/prog/back2_p10_csr.S>)|106|
|[back2_p11_maint.S](<../../unit/prog/back2_p11_maint.S>)|86|[back2_p12_cbo.S](<../../unit/prog/back2_p12_cbo.S>)|61|
|[back2_p13_sv32.S](<../../unit/prog/back2_p13_sv32.S>)|172|[back2_p14_storepf.S](<../../unit/prog/back2_p14_storepf.S>)|152|
|[back2_p15_priv.S](<../../unit/prog/back2_p15_priv.S>)|141|[back2_p16_fcsr.S](<../../unit/prog/back2_p16_fcsr.S>)|121|
|[back2_p17_fld_fsd.S](<../../unit/prog/back2_p17_fld_fsd.S>)|145|[boot_stub_probe.S](<../../unit/prog/boot_stub_probe.S>)|48|
|[fp_load_use.S](<../../unit/prog/fp_load_use.S>)|116|[ddr3_memtest.S](<../../unit/prog/ddr3_memtest.S>)|1022|

另完整read [m1_uart.S](<../../tb/prog/m1_uart.S>)1–80。DDR源分1–350/351–700/701–1022读取，包含反汇编注释但未把注释当重新汇编结果。

## 【遗留/风险】

本批指定范围无未读文件；board24文件留母代理下一独立批。未逐项人工验算generated svh；已有BASELINE哈希绑定的是冻结文件身份，不证明黄金语义独立或源码再生等价。上述反证均未执行；PLIC宏与现役译码已依据母代理实际读取证据完成交叉核对，但不把静态配置错误升级成已复现设备故障。
