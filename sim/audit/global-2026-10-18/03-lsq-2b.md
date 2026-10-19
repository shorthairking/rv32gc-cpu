# 03：LSQ / 2B 存储与提交集成静态审计

## 【结论】

基线：[BASELINE](<BASELINE.json#L1-L6>)，HEAD `b284df7`，源码树 SHA256 `7cb6b2aeeae1394a3db0575a3040fe71e6c2e20ba6fb22dac889a5924d74aaf4`。本域登记 **P0×2、P1×5，P2×0**；全为静态证据，未运行仿真、构建或219/33回归。既有D1高字掩码修复不重报。下列“最小验证”是后续执行方案，不是本次运行结果。

### 实际读取覆盖

|主责文件|状态|实际范围|
|---|---|---|
|[lsq_simple.v](<../../../rtl/back2/lsq_simple.v>)|读全|1–1524，分三段|
|[core_top_2b.v](<../../../rtl/top/core_top_2b.v>)|读全|1–1749，分三段|
|[tb_core_top_2b.sv](<../../unit/tb_core_top_2b.sv>)|读全|1–1108，分两段|
|[tb_back2_lsq_fwd.sv](<../../unit/tb_back2_lsq_fwd.sv>)|读全|1–390|
|[n12_memstress_lsq.sv](<../../unit/n12_memstress_lsq.sv>)|读全|1–777，分两段|
|[n12b_unalign_fwd.sv](<../../unit/n12b_unalign_fwd.sv>)|读全|1–680|

交叉抽查：[参数](<../../../rtl/back2/back2_params.vh#L23-L62>)23–67及114–123检索；[backend](<../../../rtl/back2/backend_top.v#L1215-L1259>)1215–1259、1670–1727；[2A](<../../../rtl/top/core_top.v#L2170-L2274>)2170–2274及`m_pa_eff`定位。其他RTL未完整读取；dyn_probe_n12/n29b未读，不拿历史探针计数作当前运行证据。

## 【变更】

仅新建本报告；产品、原测试及其他文档只读。

## 【证据】

### F1 / P0：ROB64仍使用模128年龄，跨环释放与保护失真

[参数29–30](<../../../rtl/back2/back2_params.vh#L29-L30>)已为64槽/6位；[LSQ264、277–282](<../../../rtl/back2/lsq_simple.v#L264-L282>)、[786–788](<../../../rtl/back2/lsq_simple.v#L786-L788>)、[1348](<../../../rtl/back2/lsq_simple.v#L1348>)、[1462–1467](<../../../rtl/back2/lsq_simple.v#L1462-L1467>)仍扩宽后`&7'h7F`。

确定静态反例：`head=63,cmt_n=2,ld_rob=0`，释放表达式为65而非1，该已提交LQ永不按本次窗口释放，槽泄漏；跨环候选/提交窗/分支年轻判定同受影响。影响不局限性能：跨环第二lane store可漏“翻译定妥”门，退到已提交CDQ故障静默丢弃路径。

测试漏测：直驱夹具逐条提交、未定向构造63/0同组；端到端黄金并不检查每次LQ占用归零。建议年龄先在ROB_IDX_W位取模，再零扩展；已提交未排空项必须另有提交状态，不能机械用模64年龄替换全部旧判断。最小验证：直驱分配并完成ROB63、0两load，head63提交2条，次拍断言两槽均空；再对store翻译门及squash63/0做正反例。泄漏因果确定，整核后续故障具体波形待验证。

### F2 / P1：32槽STQ扫描误用8槽LQ编码器

[LSQ740–746](<../../../rtl/back2/lsq_simple.v#L740-L746>)的`pri_enc`入参OUT_N=8、返回LQ_IW=3；[897–899](<../../../rtl/back2/lsq_simple.v#L897-L899>)却喂32位`stq_blk_w`。唯一待翻译项在STQ8..31时高位被截断，`stx_s_any=1`而索引成为0，重复翻译错误槽；真正候选的阻塞位不解除。

最小触发：占住低8槽，让槽8执行期预翻译未被受理或因上下文改变失效，再进入提交窗。静态截断确定；实际程序是否恰好让预翻译失效待验证。现有直驱测试不启用翻译，集成程序不覆盖32个槽逐个重译。建议独立STQ宽编码器；验证遍历槽0..31，断言请求idx/VA准确、完成后提交门解除。

### F3 / P0：flush期间受理store但CDQ不出队，可重复副作用或维护死锁

[LSQ952–958](<../../../rtl/back2/lsq_simple.v#L952-L958>)的dr_fire/请求未屏蔽flush；[1117–1190](<../../../rtl/back2/lsq_simple.v#L1117-L1190>)的flush分支只入队，不执行正常分支[1401–1407](<../../../rtl/back2/lsq_simple.v#L1401-L1407>)的出队。顶层[884–892](<../../../rtl/top/core_top_2b.v#L884-L892>)允许flush拍d_start接管store。

因此flush与dr_fire同拍，适配器接管且可以真正写设备，但CDQ仍持原项，随后再次发送。若进入[maint_wait_cdq](<../../../rtl/top/core_top_2b.v#L1655-L1687>)，持续flush使CDQ始终不减，等待队空永不结束。确定的是握手/记账不一致；集成中触发维护等待所需精确提交时序尚未模拟。

测试只断言flush同组store“入队”，[TB259–288](<../../unit/tb_core_top_2b.sv#L259-L288>)未核对出队唯一性；重复普通RAM写也可能被数据比对掩盖。建议CDQ更新独立于推测STQ/LQ冲刷，计数统一push-pop；验证CDQ非空时脉冲flush及持续maint_wait，给MMIO写计数器，断言每提交store恰一次写且有限拍排空。

### F4 / P1：低字fire即ret；高字可误标复用STQ槽

拆笔两条CDQ带同一idx：[1384–1396](<../../../rtl/back2/lsq_simple.v#L1384-L1396>)；每笔dr_fire都在[1411–1414](<../../../rtl/back2/lsq_simple.v#L1411-L1414>)置ret并允许回收。低笔后STQ即可释放，后续高笔仍持旧idx。若阻塞高笔足够久，让队头回收并把该槽分配给新store，高笔fire会给新占用者置ret，使其可能被提前回收。

静态生命周期缺口确定；整核需要低笔/高笔间较长延迟及槽复用，具体可达时序待验证，不能声称已复现数据丢失。现有夹具ready恒1、写入即生效，不制造中途长停顿。建议最后一笔才ret，或携带代际并用独立提交状态管理；验证拆笔低笔受理后停ready≥40拍，复用旧槽后再放行高笔，断言新项有效/ret不变。单请求适配器确实阻止load在低笔未完成时抢入，不能仅因“握手早于L1D写完成”判load读旧值。

### F5 / P1：跨4KB store高笔直接PA+4，缺第二页翻译/权限检查

[LSQ1387–1392](<../../../rtl/back2/lsq_simple.v#L1387-L1392>)及[1156–1161](<../../../rtl/back2/lsq_simple.v#L1156-L1161>)把高笔标PA有效，地址为低笔PA+4。`sw VA=页尾+0xfff`或`sh@0xfff`，下一虚拟页映射不连续/无W/未映射时仍写物理连续地址，无cause15。此为D1修复后的残余，不是已修的高掩码截断。

load在[963–964](<../../../rtl/back2/lsq_simple.v#L963-L964>)用VA+4再走适配器完整翻译，两者不一致。自然8B对齐FLD/FSD不会跨4KB，非对齐8B会报4/6，因此不能拿“对齐8B跨页”作反例。现有非对齐夹具翻译禁用；[TB993–994](<../../unit/tb_core_top_2b.sv#L993-L994>)的“跨页fld”文字不能证明此store路径。建议提交前分别检查两有效部分并保存PA/异常。验证两页映射至不连续PA，再改第二页只读，检查目标字节与cause/tval；ISA允许部分非对齐store在另一部分故障前可见，但不允许跳过后半权限/把整个store无错提交。

### F6 / P1：最终数据PMP与总线错误未接精确异常

顶层唯一PMP实例为[PTE检查633–642](<../../../rtl/top/core_top_2b.v#L633-L642>)；[数据接受/译后出口1093–1186](<../../../rtl/top/core_top_2b.v#L1093-L1186>)直接进入L1D/MMIO，无最终PA范围PMP检查。Bare下S/U及MPRV访问尤其可直接越过保护。[AXI1404](<../../../rtl/top/core_top_2b.v#L1404>)的resp_error/code悬空，[1328–1335](<../../../rtl/top/core_top_2b.v#L1328-L1335>)仍把错误R拍填缓存，[1372–1376](<../../../rtl/top/core_top_2b.v#L1372-L1376>)把响应当完成；load错误可能提交垃圾数据，store/写回错误静默成功。

本项为数据通道补充；取指priv硬接M问题归01/02，不重复计数。现有直驱无PMP/AXI，集成TB无错误注入及拒绝最终数据区域断言。建议最终数据PMP按字节范围/有效特权级检查，store检查在不可撤销提交前完成；错误响应禁止有效回填，保留cause5/7而非全部折成13/15。最小验证：Bare U访问禁止区，及注SLVERR/DECERR到load/uncached store/脏行写回，核对异常与无错误有效行。

### F7 / P1：MMIO副作用load可投机执行

[backend1244–1245](<../../../rtl/back2/backend_top.v#L1244-L1245>)仅阻塞older-store未知地址和older-CSR，没有设备load到ROB头门；[LSQ956](<../../../rtl/back2/lsq_simple.v#L956>)亦无提交授权。[顶层960–976](<../../../rtl/top/core_top_2b.v#L960-L976>)让PLIC claim读在AD_WAIT直接生效，分支squash不传入设备适配器；flush只改FSM也未屏蔽该拍设备req。

触发：older长延迟/未决分支之后的wrong-path claim先发请求，再被squash，pending已被claim清除而load不提交。结构性缺少非投机许可确定，最短指令排程待验证。正常p15只检查claim=5，不检查错误路径claim计数。建议译后路由判为强副作用设备时，等待该load为ROB头且获不可撤销许可，再访问。验证pending=1、老分支延迟、年轻claim错路径，断言设备读握手0次且pending保留。

## 【遗留/风险】

- LQ程序序分配、响应按槽tag匹配、提交释放：见[755–756](<../../../rtl/back2/lsq_simple.v#L755-L756>)和[1311–1314](<../../../rtl/back2/lsq_simple.v#L1311-L1314>)。tag无代际；直驱多在途+冲刷复用可受旧响应污染，但当前顶层单笔适配器限制旧响应先于下一请求受理，不将独立LSQ接口风险直接判为已证明整核缺陷。STQ纯翻译返回同样只检查槽有效，跨squash复用身份仍需定向验证。
- ≤4B跨字load首笔错误仍在[1330–1333](<../../../rtl/back2/lsq_simple.v#L1330-L1333>)推进第二笔，未锁存错误；第二笔故障tval在[1045–1047](<../../../rtl/back2/lsq_simple.v#L1045-L1047>)仍取首VA。需补首/次笔故障、禁止后续副作用访问及故障部分VA检查；本批未扩展可达性核对，不增加计数。
- N29B是纯等待，无转发；依赖快照按VA命中，虚拟别名依赖及乱序响应需额外覆盖。普通未提交store只驻STQ、CDQ由提交驱动，本次未发现正常单笔路径直接投机写RAM的证据，不能据此保证上述异常/复用路径安全。
- CMO只传kind到全阵列inval/clean，未传目标地址；地址翻译/PMP和非目标脏行保护应另做架构符合性验证。本批未完整读取缓存/CMO实现，不增列新结论。
- [N12压力703–708](<../../unit/n12_memstress_lsq.sv#L703-L708>)部分非对齐场景只打印数据差异；[非对齐夹具162–166](<../../unit/n12b_unalign_fwd.sv#L162-L166>)关闭翻译。三个直驱夹具响应固定次拍、无乱序/旧epoch注入、无未提交store冲刷副作用反证。TB名含fwd不代表当前有转发。
- KB通过已加载skill的同库CLI查询：`node /home/shorthair/dsh/rv32-cpu/dsh-extension/bin/riscv-kb.js search '<query>'`；查询含`PMP checks applied all accesses physical effective privilege`、`mtval portion access misaligned page fault`。来源：ISA machine.adoc 3307–3343、3613–3640（chunk10609/10617，PMP覆盖最终与隐式访问），1992–2099（chunk10566，非对齐故障部分VA）；supervisor.adoc1459–1722（chunk10790，允许部分非对齐store先可见）。以上为规范检索，不是硬件运行证据。
