# 07 配套测试可信度与覆盖审计

## 【结论】

基线 HEAD `b284df704e4b0984cef8fa8062ada01656eca287`，源码树摘要 `7cb6b2aeeae1394a3db0575a3040fe71e6c2e20ba6fb22dac889a5924d74aaf4`；见 [BASELINE](BASELINE.json)。本域只做静态阅读、路径枚举、内容检索与 KB CLI 查询，**未运行仿真、构建、生成器或变异实验**。以下是可达的判定漏洞/覆盖缺口，不是“假 PASS 已复现”，也不是 RTL 缺陷定论。P0=0，P1=6，P2=3。

原正式入口实际发现 33 个 TB；33/33 的锚点/终止路径已作全树检索，表内模块头和关键判定抽查，不声称全量逐行复审。arch-test 明确例化 2A，不是 2B 架构认证；历史报告门禁不提供当前 RTL 正确性证据。

## 【变更】

仅新建本报告；产品、测试和已有文档均未改动。

## 【证据】

### 实质发现（全部为静态证据）

1. **P1 — 编译失败降级条件比注释宽。** [regress:221–242](../../../scripts/regress.sh#L221-L242)只抽取 `Unknown module type`，若抽出的名称全在 pending 表即 SKIP，没有验证日志中的其他错误均为缺件。触发：一次编译同时含 pending unknown module 和其他 elaboration 错误。影响：真实编译故障降级为未覆盖；默认还返回 0。最小反证：用假编译器输出一个允许的 unknown module 和一个独立错误并 rc1，要求 runner 硬失败而不是 SKIP；无需运行 RTL。建议仅允许已明确分类的诊断，其他错误 fail-closed。

2. **P1 — 默认 SKIP 可 rc0，且成功清理会删去跳过证据。** [regress:95–104](../../../scripts/regress.sh#L95-L104)、[118–127](../../../scripts/regress.sh#L118-L127)、[307–318](../../../scripts/regress.sh#L307-L318)。触发：显式缺依赖或上述 pending 编译降级，未设置 strict。影响：只看退出码的 CI 误认为覆盖完成；注释承诺“失败/跳过保留日志”，实现却按 rc0 删除。没有全绿 PASS 汇总这一点是正确的，但不能抵销 rc0 风险。最小反证：缺依赖夹具分别在默认/strict 下观察 rc0/3，并检查前者日志目录消失。建议正式入口固定 strict，并对 n_skip 保留日志。

3. **P1 — 2B 黄金写回允许任意值加重定位偏移。** [tb_core_top_2b:620–633](../../unit/tb_core_top_2b.sv#L620-L633)对所有写回接受 `gold` 或 `gold+delta`，没有按指令/值来源限制为 PC 相对结果。触发：非零装载偏移程序中，普通 ALU/load/CSR 写回错误恰为 `gold+delta`。影响：该逐条比较器本身漏报，虽然后续依赖可能另行暴露，不保证总会暴露。最小反证：在不再被使用的普通写回记录上注入 delta，要求检查器拒绝。建议按解码或生成器标记区分可重定位项，普通值只接受一个期望。

4. **P1 — 前端集成比较把任意 PC 分歧修正为黄金 PC，缺少错误路径归因。** [tb_front4_integration:505–565](../../unit/tb_front4_integration.sv#L505-L565)中任意不匹配都触发黄金重定向，未核验此前确有可解释的控制转移；重新对齐后清计时。最终 [656–664](../../unit/tb_front4_integration.sv#L656-L664)只要求轨迹消费完及超时分歧数为零。触发：顺序流偶发漏交/重复/跳条，但响应重定向仍正常。影响：这些非预测错误也可能被当成可恢复“错误路径”，不能由 C1 文案推出无跳条无重复。最小反证：在非分支位置扰动一次 lane PC 后恢复，检查是否仍能完整消费黄金；应当立即失败。建议记录控制转移、预测目标和允许错误路径窗口，并对重定向后的首 lane 单独硬断言。

5. **P1 — 正式默认 FP load-use 回归不强制命中关键重叠场景。** [tb_fp_load_use:47–88](../../unit/tb_fp_load_use.sv#L47-L88)明确说明正常模式 C6 可为零，注入会被重复执行修正，关键互锁需缓冲仿真模式及 C7/C8 才敏感；[regress:221](../../../scripts/regress.sh#L221)不添加该参数或变异档。影响：33TB 通过不等于该互锁已被有效验证。最小反证：关互锁分别跑默认档和缓冲档，要求正式覆盖的敏感档必须红；本审计未执行。建议把场景命中数与正反证档纳入独立正式入口。此为覆盖问题，不重复其他域的 RTL 根因。

6. **P1 — 外部锁步缺少 DUT store/CSR/FP 状态比较，结束证据部分取自参考侧。** [cmp_commit:271–325](../../lockstep/cmp_commit.py#L271-L325)逐条只比 PC 和整数写回；魔数/末条门铃的地址和值来自 Spike，DUT magic 计数仅诊断（[233–235](../../lockstep/cmp_commit.py#L233-L235)）。触发：不再读取的 store 值/地址错误，或未读回 CSR 副作用错误，且整数流与终止铃仍正常。影响：这些错误不属于该锁步 oracle 的直接可观测范围；不能把同 PC 的 store 当已验证落地。最小反证：仅扰动一个不回读 store 或未读取 CSR 的 DUT 副作用，要求扩展后的比较器红。建议增加提交 store 地址/数据/掩码、CSR 修改及 64 位 FP 探针；现有头注已承认部分限制。

7. **P2 — 产物隔离只保护批内，不能保护两个独立运行。** [arch run:402–407](../../arch_test/run.sh#L402-L407)、[653–680](../../arch_test/run.sh#L653-L680)以 basename 为键，批内并行有重名硬检查，但无跨运行锁；[lockstep run:106–116](../../lockstep/run.sh#L106-L116)全部程序共用 trace/vvp/cmp；[regress:190](../../../scripts/regress.sh#L190)也把 vvp 写到固定源目录。触发：两次同入口并发。影响：日志、ELF、结果或仿真文件互覆，判定可能串用另一运行证据。最小反证：两个带不同标识的假 worker 同时写同键，检查结果归属。建议每次运行独立目录、原子发布与元数据关联。

8. **P2 — 黄金生成可信边界不完整。** [back2 generator:154–211](../../unit/prog/gen_back2_lockstep_data.py#L154-L211)将连续相同 PC 当结束，无终止符号/成功标志核验；寄存器只留编号和低32位，丢失 x/f 类型与 D 高32位。[front4 generator:32–87](../../unit/prog/gen_front4_int_data.py#L32-L87)接受空 PC 日志，无映像/日志同 ELF 绑定与黄金非空检查。两者固定 `/tmp` 文件名，subprocess 使用 check=True（异常不会被吞为 rc0），但没有墙钟 timeout；back2 有指令上限而无墙钟兜底。影响：过期/错误来源黄金及早期自旋可能被固化，不能把“可再次运行生成命令”视为已验证重现。最小反证：空日志、无关 ELF 日志、入口后提前自旋、同时两次生成；应分别拒绝或隔离。建议输出输入哈希/工具版本、终止 PC、类型/64位数据，原子生成。当前回归直接 include 已固化数据，不自动复核源码一致性。

9. **P2 — 部分“覆盖证明”实际为常量或取样范围偏弱。** [tb_clint:14–28](../../unit/tb_clint.sv#L14-L28)与 [tb_plic:18–30](../../unit/tb_plic.sv#L18-L30)把 AXI 活动接常零，不能证明顶层路由绝不发 AXI；命名端口例化也不保证新增未连接输出一定编译失败。[rob_wide_mem:39–50](../../unit/tb_back2_rob_wide_mem.sv#L39-L50)在第二读沿后才检查新值，不能据此证明同址冲突首拍 read_first；[108–115](../../unit/tb_back2_rob_wide_mem.sv#L108-L115)读地址总等于本轮写地址，随机并非独立读写历史空间。最小反证：顶层错误旁发 AXI、RAM 冲突模式改 write_first、只破坏旧地址读；分别要求对应测试红。建议顶层 monitor 和冲突首拍/独立随机读地址检查。不能据此否定这两个设备 TB 的寄存器检查。

### 33TB 分类矩阵

全部入口为 [regress](../../../scripts/regress.sh#L109-L112)，仅匹配根目录 `tb_*.sv`；统一首 module 编译、rc0、整行唯一锚点、全文唯一 PASS、零 FAIL，timeout 兜底见 [251–274](../../../scripts/regress.sh#L251-L274)。下表“抽”指已实际 read 模块头/契约，并通过全树 grep 查终止/计数；“重点”还 read 关键判定实现；不是全文件逐行覆盖。单元向量的穷举性、随机分布和全部 X 路径未完成复核。

|TB（均在正式入口）|DUT / 关键可观测内容|漏测或结论边界|深度|
|---|---|---|---|
|[alu](../../unit/tb_alu.sv)|ALU；12运算/边界/结果|非端到端依赖流|抽|
|[axi_master_ctrl](../../unit/tb_axi_master_ctrl.sv)|AXI控制；握手/4K拆笔/错误响应|不能代替核级 access fault 交付|抽|
|[back2_ipc](../../unit/tb_back2_ipc.sv)|backend；PC/影子值/IPC>1|理想ALU流；未排空证明派发全部提交，C1只单向计数容差|重点|
|[back2_iq](../../unit/tb_back2_iq.sv)|6队列；年龄/唤醒/冲刷/排空|显式7位ROB配置不等于集成配置；随机名称不证明分布|抽|
|[back2_lockstep](../../unit/tb_back2_lockstep.sv)|front+backend 对2A；前5程序PC/互比写回/全内存|Spike仅PC；共模数据错误不必被黄金发现|重点|
|[back2_lsq_fwd](../../unit/tb_back2_lsq_fwd.sv)|LSQ等待/落地/读回/LQ释放|不是历史全部转发压力档|检索，头未完整read|
|[back2_rob_wide_mem](../../unit/tb_back2_rob_wide_mem.sv)|4bank RAM，200轮随机|见发现9；错误路径仅display，靠runner拒绝FAIL|全文|
|[boot_stub](../../unit/tb_boot_stub.sv)|2A复制/邮箱/逐字节计数|小占位payload，不是完整固件启动|抽|
|[bru](../../unit/tb_bru.sv)|真假分支/目标/JALR|无流水误预测恢复|抽|
|[clint](../../unit/tb_clint.sv)|寄存器/mtime/MTIP|常零AXI证明无效，见9|抽|
|[core_top_2b](../../unit/tb_core_top_2b.sv)|14程序映射，PC/写回/陷阱/维护|见3/8；无黄金程序为独立硬编码oracle|重点|
|[csr_file](../../unit/tb_csr_file.sv)|CSR/WARL/PMP/priv_ctrl回路|不代表指令串行化/所有同拍竞争|抽|
|[decoder](../../unit/tb_decoder.sv)|译码/立即数/C展开/权限|明确为抽样非编码穷举|抽|
|[exe_ctrl](../../unit/tb_exe_ctrl.sv)|M/W旁路优先级|无整个流水依赖交互|抽|
|[fetch_unit](../../unit/tb_fetch_unit.sv)|首取/XIP/PMP/parcel|翻译及存储由夹具驱动|抽|
|[fp_load_use](../../unit/tb_fp_load_use.sv)|2A FP结果/协议|默认不保证关键场景，见5|重点|
|[fpu](../../unit/tb_fpu.sv)|64位结果/flags/时序/flush|固化向量，原临时生成器非回归依赖|重点|
|[fpu_cmp_cvt](../../unit/tb_fpu_cmp_cvt.sv)|S/D结果/flags/NaN/舍入|有限固化oracle非全部输入空间|抽|
|[fregfile](../../unit/tb_fregfile.sv)|三读/写旁路/f0/64位|不是多提交口FP通路|抽|
|[front4_frontend](../../unit/tb_front4_frontend.sv)|分组/跨行/反压/XIP/PMP|明确不证明持续4宽吞吐|抽|
|[front4_integration](../../unit/tb_front4_integration.sv)|黄金PC/指令位/训练|见4；blk_ready恒1|重点|
|[front4_predictor](../../unit/tb_front4_predictor.sv)|预测器事件轨迹/性能统计|LCG取bit30避免低位短周期；固定种子非随机穷举|片段|
|[l1d](../../unit/tb_l1d.sv)|命中/替换/dirty/clean|fill模型不证明核级错误响应|抽|
|[l1i](../../unit/tb_l1i.sv)|8beat/替换/失效/XIP|不代替翻译取指整链|抽|
|[lsu](../../unit/tb_lsu.sv)|对齐/PMP/MPRV/VA/AMO|组合接口不等于2B LSQ异常链|抽|
|[m3_ddr3](../../unit/tb_m3_ddr3.sv)|2A七模式/总线计数/XIP/设备截获|仿真缩小窗口，不是128MiB全遍历|抽|
|[mdu](../../unit/tb_mdu.sv)|M八指令/边界/busy/flush|行为模型非Vivado IP|抽|
|[parcel_align](../../unit/tb_parcel_align.sv)|长度/拼接/carry|独立组合单元非完整取指流|抽|
|[pc_gen](../../unit/tb_pc_gen.sv)|重定向优先级/冻结/+2/+4|不证明整个前后端恢复|抽|
|[plic](../../unit/tb_plic.sv)|优先级/claim/complete/上下文|常零AXI证明无效，见9|抽|
|[pmp_check](../../unit/tb_pmp_check.sv)|16项/TOR/NA4/NAPOT/优先级|不等于PTW/LSQ集成全组合|抽|
|[ptw](../../unit/tb_ptw.sv)|Sv32/PMP/大页/A-D|显式SVADE=0；不代表集成默认Svade|抽|
|[trap_ctrl](../../unit/tb_trap_ctrl.sv)|委托/向量/xRET/priv|输入由TB直驱，非ROB精确陷阱全链|抽|

### 主责文件覆盖清单与可信边界

- 完整 read：[env](../../../scripts/env.sh)、[regress](../../../scripts/regress.sh)、[arch runner](../../arch_test/run.sh)、[lockstep runner](../../lockstep/run.sh)、[比较器](../../lockstep/cmp_commit.py)、[两个生成器之back2](../../unit/prog/gen_back2_lockstep_data.py)、[front4](../../unit/prog/gen_front4_int_data.py)、[exclude](../../arch_test/exclude.list)。配置/yaml/json/headers、定向S、全部链接脚本及生成svh只由基线清单/引用关系定位，**未逐文件read完，不计已完成深审**。
- [sim_mem_model:210–270](../../tb/sim_mem_model.sv#L210-L270)抽查确认未知字节转0、未登记读0、rresp/bresp恒OKAY；字索引丢低2位。这种stub不能单独证明总线错误/未对齐/未知值传播正确。相对地 [arch TB](../../tb/tb_arch_test.sv)检索显示 mem_resp 有 DECERR 路径，不能笼统说全部stub吞错误。其完整判定、[tb_core_top](../../tb/tb_core_top.sv)、[UART decoder](../../tb/uart_ser_decoder.sv)、[lockstep TB](../../lockstep/tb_lockstep.sv)及配套S未逐行read，列为剩余工作。
- arch runner 的长度非零、Spike/DUT超时退出码、整行锚点及签名逐行差异检查是有效正面约束（[468–569](../../arch_test/run.sh#L468-L569)）。但 DUT 日志没有与 regress 同强度的全文 FAIL/PASS 唯一过滤；混合通过+skip最终分母只含通过/失败（[862–864](../../arch_test/run.sh#L862-L864)）。排除清单明确排除 Misalign 与 ExceptionsSv 族，不得将筛选后全绿扩展为这些族已覆盖。`--check-exclude`只证明规则有命中。
- 锁步自测仅篡改一个整数rd值；其 PASS 整行正则有锚定，但所谓“端到端唯一PASS”实际只再数 cmp日志（[254–262](../../lockstep/run.sh#L254-L262)），不是全stdout。未知Spike非匹配行被跳过；字段解析后才是fail-closed。未构造异常格式日志实验，不判已复现逃逸。
- 历史分类：所有 `dyn_probe*`、`n*stress`、其他 `n*probe` 均不匹配正式 glob，**没有一个仅因存在于目录就进入33TB**。[n12探针](../../unit/dyn_probe_n12_stress.sv#L21-L27)与 [n28探针](../../unit/dyn_probe_n28_stress.sv#L9-L19)自身明确不进回归；[n29b包装](../../unit/dyn_probe_n29b_stress.sv)需另编入压力TB与探针依赖。历史层次引用、旧宏/端口是否全部适配当前RTL未验证，不能拿历史CSV/诊断PASS补本轮覆盖；也不能未经编译就断言它们全已失配。
- [audit3 checker](../audit3_check.py#L17-L64)只读报告、检查章节/条数/文本哈希/报告内PASS锚点，**不是功能验证**；audit1/2 checker本轮未完整read，不能声称逐项核验。`audit3_rtl`仅历史冻结材料，不作为DUT。

## 【遗留/风险】

本交付以中断前既有证据落盘，尚未满足“范围内每一S/头文件/配置/全部TB判定逐行审完”的完整目标；矩阵已区分全文/重点/抽查/检索。未补跑黄金再生、异常subprocess、并发、随机分布及变异反证；上述最小反证均是建议方案而不是执行记录。新验证夹具修复和母代理另行完成的功能回归不混入本报告原入口结论。
