# 05：取指／四宽前端／预测／压缩与译码审计

## 【结论】

基线 HEAD `b284df704e4b0984cef8fa8062ada01656eca287`，树摘要 `7cb6b2aeeae1394a3db0575a3040fe71e6c2e20ba6fb22dac889a5924d74aaf4`。本域18个RTL文件逐项SHA-256与[BASELINE](<BASELINE.json>)一致；母代理另核245/245一致。**不通过：P0×2、P1×6、P2×1**（其中checkpoint为接口风险，尚未证明整核可达）。本代理仅静态阅读、未仿真／构建；动态结果明确引用独立验证，不冒称本代理运行。

## 【变更】

仅新建本报告；源码、既有测试及金标均未修改。未例化金标、待审LOCAL删除不按死代码报错。权限硬接M等问题由其他域负责，不重复计数。

## 【证据】

### 逐文件实际覆盖

“读全”仅表示实际完整读取，不表示证明全部行为正确。

| 文件 | 实际读取 | 检查重点 |
|---|---|---|
| [fetch_unit](<../../../rtl/fetch/fetch_unit.v>) | 读全1–489 | 半字起点、accept、翻译及异常 |
| [pc_gen](<../../../rtl/fetch/pc_gen.v>) | 读全1–180 | 优先级、+2/+4 |
| [parcel_align](<../../../rtl/fetch/parcel_align.v>) | 读全1–113 | caller契约、carry有效 |
| [ifetch4](<../../../rtl/front4/ifetch4.v>) | 读全1–900 | 跨界、mask、流水、epoch、PMP |
| [pc_gen4](<../../../rtl/front4/pc_gen4.v>) | 读全1–134 | restart、页界、epoch |
| [front4_top](<../../../rtl/front4/front4_top.v>) | 读全1–361 | repair与消费者连线 |
| [predictor_top](<../../../rtl/front4/predictor_top.v>) | 读全1–564 | FIFO、checkpoint、训练 |
| [bpu_btb](<../../../rtl/front4/bpu_btb.v>) | 读全1–213 | tag、携带way、替换、碰撞 |
| [bpu_ras](<../../../rtl/front4/bpu_ras.v>) | 读全1–174 | 修复、深度／内容恢复 |
| [bpu_gshare](<../../../rtl/front4/bpu_gshare.v>) | 读全1–191 | 提交索引、GHR |
| [bpu_local_hist](<../../../rtl/front4/bpu_local_hist.v>) | 读全1–205 | LHT旧值、LPHT定序 |
| [bpu_selector](<../../../rtl/front4/bpu_selector.v>) | 读全1–158 | 四转移、预测时记录 |
| [front4_mem](<../../../rtl/front4/front4_mem.v>) | 读全1–289 | 双分支初值、同址读写 |
| [front4_table_2lu_1upd](<../../../rtl/front4/front4_table_2lu_1upd.v>) | 读全1–87 | 镜像写、更新口 |
| [front4_params](<../../../rtl/front4/front4_params.vh>) | 读全1–127 | 32parcel／索引宽度 |
| [compressed_expand](<../../../rtl/decode/compressed_expand.v>) | 读全1–469 | C寄存器、立即数、合法性 |
| [dec_imm](<../../../rtl/decode/dec_imm.v>) | 读全1–250 | I/S/B/U/J及C函数 |
| [decoder](<../../../rtl/decode/decoder.v>) | 读全1–799 | F/D/AMO/CSR控制字段 |
| [tb_fetch_unit](<../../unit/tb_fetch_unit.sv>) | 读全1–549 | C5人工响应地址，非真实跨字通路 |
| [tb_pc_gen](<../../unit/tb_pc_gen.sv>) | 读全1–332 | 来源优先级及推进 |
| [tb_parcel_align](<../../unit/tb_parcel_align.sv>) | 读全1–225 | carry人工注入，非系统跨界 |
| [tb_decoder](<../../unit/tb_decoder.sv>) | 读全1–655 | 抽样覆盖、保留编码盲区 |
| [tb_front4_predictor](<../../unit/tb_front4_predictor.sv>) | 读全1–951 | 每事件排空、恢复仅深度 |
| [tb_front4_frontend](<../../unit/tb_front4_frontend.sv>) | 读全1–763 | Bare、跨行PMP、反压 |
| [tb_front4_integration](<../../unit/tb_front4_integration.sv>) | 读全1–680 | 黄金PC纠偏及真正断言 |
| [front4_int.S](<../../unit/prog/front4_int.S>) | 读全1–82 | 混合流、调用返回 |
| [front4_int.ld](<../../unit/prog/front4_int.ld>) | 读全1–12 | 地址布局 |
| [front4_int_data](<../../unit/prog/front4_int_data.svh>) | 抽查1–70／286 | 映像、黄金轨迹头；未逐项核248PC |
| [n25_btb_collide_tb](<../../unit/n25_btb_collide_tb.sv>) | 读全1–222 | 历史诊断，非本轮运行 |
| [n25_btb_probe](<../../unit/n25_btb_probe.sv>) | 读全1–84 | 历史只读探针 |
| [n25_collision_probe](<../../unit/n25_collision_probe.sv>)、[n25_bp_probe](<../../unit/n25_bp_probe.sv>) | 未读 | 不据其历史数字下结论 |

配套跨域仅抽查：[core_top_2b:650–724](<../../../rtl/top/core_top_2b.v#L650-L724>)及信号搜索；[backend_top:2600–2649](<../../../rtl/back2/backend_top.v#L2600-L2649>)及checkpoint释放搜索。未审`dec_csr`内部。

### F05-01　P0：C MISC-ALU更新错误寄存器（动态已复现）

[compressed_expand:70–76、294–314](<../../../rtl/decode/compressed_expand.v#L294-L314>)：`rd_p`来自`c[4:2]`，但CB/CA的rd′／rs1′应为`c[9:7]`。`0x8c05`（c.sub x8,x9）展开为`sub x9,x9,x9`而非`sub x8,x8,x9`；`0x8015`／`0x8815`把x8的srli／andi改为x13。因果：共用CL/CIW目的域→MISC-ALU同时误接rd和rs1→静默破坏架构状态。现有译码TB不覆盖这些不等寄存器样例。最小验证：三指令加rd′=rs2′控制；修复只将该组目的／源接`rs1_p`，不要改变CL目的域。规范KB：`zca.adoc:485–588`（chunk11670），SRLI/ANDI均操作rd′。独立[动态报告:73–95](<validation/decode-fp0/results.md#L73-L95>)已复现，不重跑。

### F05-02　P0：真实Sv32 fault被前端忽略（静态）

[ifetch4:362–364、392–418、855–864](<../../../rtl/front4/ifetch4.v#L362-L418>)：`sv32_translate_fault`仅端口声明，`done=1,fault=1`仍使F3移到F4，使用fault时的paddr发取指；parcel没有页错元数据，lane fault仅由PMP生成。当前[顶层:702–704](<../../../rtl/top/core_top_2b.v#L702-L704>)实际接TLB/PTW fault，并非未启用hook。最小事务：在VA页尾`...ffe`放32位指令低parcel；下一页翻译done+fault，保持任意旧PA。应交付起始PC=`...ffe`、cause12、tval=下一页首地址；当前无该故障生成路径，可能错取或挂住。影响：页异常丢失，跨页第二parcel尤其严重。两份front4 TB均硬接Bare，不能发现。建议在翻译失败时不访问cache，以故障parcel入队，保留VA及指令起点；第二parcel PMP地址还须改用`e_pa(e?h)`，不能使用[597–603](<../../../rtl/front4/ifetch4.v#L597-L603>)的起始PA+2（跨页PA未必连续）。规范KB `machine.adoc:1992–2099` chunk10566：mepc指令起点，非零mtval为故障部分VA。

### F05-03　P1：C.EBREAK拒绝／C.JR x0放行（动态已复现）

[compressed_expand:395–421](<../../../rtl/decode/compressed_expand.v#L395-L421>)：`q2_special_ok`只在`c[12]=1,rs2=0`检查非零rs1，误拒`0x9002`，而`0x8002`绕过检查变成jalr x0,0(x0)。前者使合法断点变非法指令异常；后者违反项目“保留即ill”的严格规则（不把所有保留空间泛称ISA强制trap）。现有TB只测32位ebreak。最小验证／修复：分别测9002、8002、8282、9282；独立区分JR、JALR、EBREAK。规范KB `zca.adoc:388–453` chunk11665及696–704 chunk11675。[动态报告:97–111](<validation/decode-fp0/results.md#L97-L111>)已有正反控。

### F05-04　P1：OP-FP未支持／保留字段被认作正常指令（动态已复现）

[decoder:430–490](<../../../rtl/decode/decoder.v#L430-L490>)：FSQRT缺rs2=0；FCVT只检查rs2[4:2]，RV32的L/LU编码亦接受；FMV/FCLASS缺rs2=0，FMV.W.X还缺funct3／S精度限定，F↔D转换未限制源／目标合法配对。最小例`58100053,c0200053,d0200053,e0100053,f0100053`均ill=0；项目严格译码规则下应拒绝，不以汇编器拒绝单独推出ISA保留空间必须trap。因果：只匹配funct5→保留／不支持编码执行且产生写回。既有TB仅正常族样例。建议按完整mask/match分别限定，使用合法对照逐字段翻转验证；舍入模式保留编码另审，不能仅凭rm=5/6宣称规范必trap。KB `rv-32-64g.adoc:3–463` chunks11189/11190/11192给固定字段；`d-st-ext.adoc:131–214` chunk11001规定L转换RV64-only。[动态报告:113–135](<validation/decode-fp0/results.md#L113-L135>)复现其中5例；其他组合仅静态，未验证。

### F05-05　P1：checkpoint一个块多lane共用且可提前释放（待整核可达性）

[ifetch4:768–772](<../../../rtl/front4/ifetch4.v#L768-L772>)给grp_taken块的所有有效lane相同id与valid，而[分配:702](<../../../rtl/front4/ifetch4.v#L702>)只分配一次；后端按提交lane标记释放（[backend_top:2785–2786](<../../../rtl/back2/backend_top.v#L2785-L2786>)）。最小序列：lane0普通指令，lane1较慢，末lane预测分支；lane0先提交释放id，后续块复用；原分支误判才恢复该id。风险为错误RAS/GHR快照，并非本轮已证明整核错误。测试未断言“只有末尾分支持有id”，集成TB也逐lane释放。建议仅真正分配的分支置valid，或显式块级引用计数；加入不同延迟、id复用、恢复快照一致性检查。

### F05-06　P1：F2预测结果可能错位一拍（静态）

[ifetch4:367、383–386、845–849](<../../../rtl/front4/ifetch4.v#L845-L849>)在F2首次持有A后的同一个沿，既让同步预测表读取A，又令F3采样沿前的`lu_pack`（前一个请求）；顶层[257](<../../../rtl/front4/front4_top.v#L257>)未消费lu_valid。最小事务：预训练A/B不同方向与BTB目标，连续接受A、B且F3空闲，对比每word携带记录；插入F3停顿作控制。影响是错误预测、训练记录归属，不自动等同架构错误。预测器单元TB独立等待读沿后采样，前端TB未对记录PC逐项对拍。建议提前在F1接受时发查询，或增加响应valid及地址配对级。

### F05-07　P1：反压时块载荷不锁存，RAS又是实时输入（静态）

[ifetch4:511–545、675–692](<../../../rtl/front4/ifetch4.v#L675-L692>)的mask／目标为组合输出，`blk_valid=1,ready=0`时仍会压parcel、增加lane；返回目标又随实时RAS变化。最小事务：先呈现不足4lane块并反压，随后数据到达或D2压弹RAS，观察mask／next_pc变化；freeze输入还能直接撤valid。影响：不能向消费者保证常规ready/valid稳定契约；须结合消费者采样约定验证，未运行。现有反压用例等待200拍蓄满后才检查，无`valid&&!ready |=> stable(payload)`。建议输出寄存并持有至握手／明确flush取消；返回预测快照应随parcel携带，而非实时重算。

### F05-08　P1：黄金集成TB没有执行其声称的指令位／长度核对

[tb_front4_integration:505–524](<../../unit/tb_front4_integration.sv#L505-L524>)只比较lane PC即计成功；`img_insn/img_len32`存在，但未比较`lane_insn/lane_len32`。PC不同无条件归为误预测并从黄金地址纠正，故不能独立证明“分歧都可解释”。最小反证：只翻转交付指令非控制位或lane_len32而保持PC；该主核对不能捕获。影响是译码／拼接损坏被黄金PC结果掩盖；前端独立TB局部补到但不能替代此判据。建议逐lane比较位和长度，对错误路径须验证确有更老控制流误判来源；负控必须失败。

### F05-09　P2：ras_repair_addr对外未驱动，当前内部重定向不受影响

[front4_top:140、218、224–225、266](<../../../rtl/front4/front4_top.v#L218-L225>)输出未assign，内部`ras_repair_addr_w`接预测器并用于redir，因此不能报“当前修复跳未知地址”。当前顶层只接同名wire无消费者。最小验证：D2传入不匹配返回地址，分别检查内部redirect目标和对外端口；修复为输出assign或删除接口（须授权）。TB未核该输出。

## 【遗留／风险与排除项】

- **撤回**ADDI4SPN／CB立即数“颠倒”线索：实际拼接正确，注释位序有误导，不列功能缺陷；未重复计数。I/S/B/U/J、C.J立即数未发现确定缺陷；AMO funct5／aq/rl分域及LR rs2=0检查存在；CSR主译码分族正常，权限细则交其他域。
- [fetch_unit:174、290–295、447–448](<../../../rtl/fetch/fetch_unit.v#L290-L295>)高半起始永不交付：首个C指令后PC+2即停；insn_accept未参与推进。属保留基线模块功能局限，当前整核是否实例化未完整追踪，**不宣称当前四宽核同样停摆、不报死代码**。其TB C5人工改response VA，不能证明真实跨字请求／拼接。
- RAS仅恢复深度，错误路径pop后push可能覆盖旧内容；当前A5只测push后恢复深度，未测内容回滚。SPEC_GHR=1仅有恢复写口，未见预测方向推进；本轮默认SPEC_GHR=0，不扩大为当前默认架构错误。均待定向验证。
- LHT同拍写／查读由NBA给沿前值，LPHT／selector使用独立读写副本及busy定序，未发现确定丢更新；双分支同址语义及初值仍需综合侧验证。[front4_mem:83–84、147](<../../../rtl/front4/front4_mem.v#L83-L84>)的XPM禁初始化与行为INIT不同，不引用旧N34B-2结论冒充当前运行。
- 训练FIFO吞吐低于1事件/拍，但有ready；当前[backend_top:2604](<../../../rtl/back2/backend_top.v#L2604>)遵守ready，**不报丢训练**。错误epoch外部响应归属、BTB陈旧way覆盖／重复tag、mask外fault对顶层`|lane_fault`的影响均未完成消费者可达性验证。
- N25只作历史诊断：[当前SDP:241](<../../../rtl/front4/front4_mem.v#L241>)已显式read_first，不能复报旧NO_CHANGE为现存缺陷；历史定向TB失败分支仅打印FAIL后正常finish，须外层日志门禁。本轮未运行它。
- 动态证据来源[decode-fp0结果](<validation/decode-fp0/results.md>)：母代理复跑24/24验证脚本、12缺陷+12控制与5反证；“脚本通过”表示缺陷按机理复现，**不是DUT通过**。其中backend f0问题由其他域计数，本报告不重复。未做整核／arch-test及全量回归。
