# RV32GC 全局 RTL/测试审计主报告（冻结 b284df7）

> 本报告只汇总 `sim/audit/global-2026-10-18/` 下已保存的分域审计、定向验证与母复跑日志，不新增代码审计、不重跑仿真、不修 RTL/原测试。分域报告 01 的原根相对链接已由母 Agent 仅修 href，结论未改；原未提交 Markdown 保留。
>
> 基线：`HEAD=b284df704e4b0984cef8fa8062ada01656eca287`。[BASELINE.json](BASELINE.json) 冻结 **245** 个源码/测试/支持文件，其中 **63** 个 `rtl/*` 文件 **33,706** 行，正式单元测试 **33** 个。源文件集合 SHA256 `7cb6b2aeeae1394a3db0575a3040fe71e6c2e20ba6fb22dac889a5924d74aaf4`；母 Agent 已逐文件多次核对 245/245 一致。该值是**所列文件集合的哈希**，不是 git tree hash，也不自动覆盖整个工作区。额外支持范围：`fpga/run_vivado_batch.sh`（150 行）与 `fpga/soc_up.xdc`（31 行）不在 245 清单内；母 Agent 已按 HEAD blob 只读比对，08 报告纳入审阅，本报告仅据此列入，**不计入 245 哈希**。
>
> 证据分层：①“动态（模块级）”= 母 Agent 亲自复跑过的固定清单；②“静态”= 源码/表达式代入；③“接口待验证”= 模块契约风险，当前集成有门控或未接真实消费方；④“测试风险”= oracle/门禁/覆盖缺口，不是 RTL 定论。历史 formal 33/33、tb_core_top_2b 集成判据、旧综合/时序数字**均只作历史**；本次未全量重跑回归，未跑 arch-test、锁步、Vivado、真板、SoftFloat 或形式验证。

## 1. 结论与放行判定

**不满足功能正确性放行条件。** 七个验证主题的定向验证仅证明 17 个**指定缺陷行为**在模块/接口边界按预期出现，不是 17 个独立根因，也不是整核合规；其余核心问题绝大多数仍为静态推导。冻结版本上还有已知未修的 P0 级特权隔离、PMP 自锁、f0 写抑制、LSQ 释放/副作用与 MMU 正确性问题。

- 允许的结论：冻结版本存在一组可复现的模块级错误行为；测试基础设施存在可静态确认的 fail-open/oracle 反向风险；覆盖清单可核。
- 不允许的结论：整核提权/整核数据破坏已复现；33 个正式 TB 全绿等于功能正确；245 文件哈希等于整个工作区已被审计；领域条目可直接相加为“总 bug 数”。
- 本报告不给出单一“总 bug 数”。各域给出的 P0/P1/P2 是**源报告条目计数**，存在同根跨域重复（01/02 权限、02/05/06/10 的 f0 与测试缺口、05/07 的前端黄金纠偏），去重后也不是可发布的功能缺陷总数。

## 2. 范围、方法与不可外推边界

| 项 | 本次实际做的 | 明确未做 |
|---|---|---|
| 代码 | 11 份分域报告覆盖 RTL、正式/共享 TB、程序、配置、综合与板级脚本 | 未重新逐行审计；未读 Linux/U-Boot/QEMU 完整源 |
| 动态 | 母复跑 decode-fp0 24 例、privilege-memory 11 例，共 35 例；反证 9 例 | 未跑原 33 项回归、tb_core_top_2b 集成判据、arch-test、锁步、Vivado、真板 |
| 判定 | 脚本 rc + 唯一 `RESULT=` 行 + 参考锚点；母日志留档 | 未做整核程序级缺陷复现，未做独立 SoftFloat/Spike 差分 |
| 产物 | 本次汇编只新建 [REPORT.md](REPORT.md)、[COVERAGE.md](COVERAGE.md)、[COVERAGE.tsv](COVERAGE.tsv)；全局审计此前已在同目录新增 11 份分域报告、BASELINE/PROGRESS 台账、隔离验证 TB/脚本/日志 | 不改 RTL、原测试/金标/配置/其他文档，不提交、不转包 |

覆盖边界见 [COVERAGE.md](COVERAGE.md)：63 个 RTL 文件的读取深度逐项登记；33 个正式 TB 为 01–10 联合阅读，不等于逐行功能覆盖；`fpu_add.v` 只全读当前活跃 helper 与指定段，保留金标主体未全读。

## 3. 七项动态验证主题

两批固定清单共 **35 = 17 缺陷复现 + 18 控制**，夹具反证 **9**（5+4）。母日志中的 `PASS` 是用例脚本通过；缺陷/控制分类见各 `results.md` 表。**同名日志按目录区分**：两目录都有 `log_b1.log`，下文按主题给出带目录的链接；母复跑/反证日志分别为 [decode-fp0 复跑](validation/decode-fp0/mother-validation.log)、[decode-fp0 反证](validation/decode-fp0/mother-negative.log)、[privilege-memory 复跑](validation/privilege-memory/mother-validation.log)、[privilege-memory 反证](validation/privilege-memory/mother-negative.log)。复现入口：

```sh
cd sim/audit/global-2026-10-18/validation/decode-fp0
./run_all.sh            # VALIDATION: 24/24（all_run_all.out / mother-validation.log）
./negative/run_negative.sh   # NEGATIVE: 5/5（mother-negative.log）
cd ../privilege-memory
./run_all.sh            # VALIDATION: 11/11（mother-validation.log）
./negative/run_negative.sh   # NEGATIVE: 4/4（mother-negative.log）
```

### 3.1 C MISC-ALU 取错 rd′（05 F05-01）

- 输入：真实 16 位压缩指令经 `compressed_expand` 模块注入；`0x8c05` c.sub x8,x9、`0x8015` c.srli x8,5、`0x8815` c.andi x8,5。
- 观察：分别展开为 `0x409484b3`（sub x9,x9,x9）、`0x0056d693`（srli x13,x13,5）、`0x0056f693`（andi x13,x13,5）。
- 期望：`0x40940433`、`0x00545413`、`0x00547413`（rd′=c[9:7]）；控制 c2（rd′=rs2′）与 c0/c7/c8 均 `CONTROL_OK`。
- 等级：**动态-模块级译码**；未从 core_top 取指复现。独立 oracle 为 objdump 与 `as -march=rv32imafdc`。
- 日志：[log_c1.log](validation/decode-fp0/log_c1.log)、[log_c3.log](validation/decode-fp0/log_c3.log)、[log_c4.log](validation/decode-fp0/log_c4.log)；说明 [results.md](validation/decode-fp0/results.md)。

### 3.2 C.EBREAK 误拒 / C.JR x0 放行（05 F05-03）

- 输入：`0x9002` c.ebreak、`0x8002` c.jr x0；控制 c7/c8 为合法 c.jr/c.jalr x5。
- 观察：`0x9002` 得 `insn32=0x00100073` 但 `ill16=1`；`0x8002` 得 `ill16=0`，展开 `0x00000067`。
- 期望：前者 `ill16=0`；后者按本项目“保留编码即非法”的严格译码规则应 `ill16=1`。**这是项目规则，不泛化为 ISA 对所有保留空间强制 trap**；`as` 拒绝 `c.jr zero` 只作旁证。
- 等级：**动态-模块级译码**。日志 [log_c5.log](validation/decode-fp0/log_c5.log)、[log_c6.log](validation/decode-fp0/log_c6.log)。

### 3.3 OP-FP 保留/不支持字段被接受（05 F05-04）

- 输入：`0x58100053` fsqrt.s（rs2=1）、`0xc0200053` fcvt.l.s、`0xd0200053` fcvt.s.l、`0xe0100053` fmv.x.w（rs2=1）、`0xf0100053` fmv.w.x（rs2=1）。
- 观察：5 例 `ill_instr=0`；控制 f0/f6–f10（rs2=0 的同类与 fadd.s）均为 0，`CONTROL_OK`。
- 期望：项目严格规则下均应拒绝。RV32 的 `fcvt.l/lu.s`、`fcvt.s.l/lu` 另有 ISA 手册 `norm:fcvtlongfloatrv64only` 支撑；其它 rs2≠0 组合属 reserved，**不能只凭汇编器拒绝宣称架构强制 trap**。binutils 反汇编器不按 XLEN 过滤，不能当作 fcvt RV32-only 的 oracle。
- 等级：**动态-模块级译码，5 例**；报告中其余 FP 字段组合仍为静态，未扩大为已复现。日志 [log_f1.log](validation/decode-fp0/log_f1.log)、[log_f2.log](validation/decode-fp0/log_f2.log)、[log_f3.log](validation/decode-fp0/log_f3.log)、[log_f4.log](validation/decode-fp0/log_f4.log)、[log_f5.log](validation/decode-fp0/log_f5.log)。

### 3.4 后端抑制 f0 目的写（02-1）

- 输入：真实指令位从 `backend_top` 派发口 `lane_insn_i` 注入：b1 fadd.s f0,f1,f2（`0x00208053`）、b3 flw f0,0(ra)（`0x00002007`）；b2/b4 改 f1 为控制。
- 观察：b1/b3 的 D1 `dst_fp=0`（`is_fp/is_fpls=1`、`illegal=0`），指令提交但 `commit_arch_we=0`、真实 `u_prf_f.we` **0 次**；b2/b4 同链路写 1 次。
- 期望：FP f0 是普通可写寄存器，应分配物理目的并写 PRF、提交 arch_we=1。
- 等级：**动态-后端模块级**：注入点在派发口，观测点已到真实 FP PRF 写口与提交，但**不是 core_top 取指→前端的整核级**，也未跑 arch-test。
- 日志：[log_b1.log](validation/decode-fp0/log_b1.log)（`E2E commit_seen=1 commit_arch_we=0 commit_rd=0 fp_prf_we_seen=0`）、[log_b2.log](validation/decode-fp0/log_b2.log)、[log_b3.log](validation/decode-fp0/log_b3.log)、[log_b4.log](validation/decode-fp0/log_b4.log)。

### 3.5 后端按 M 权限接受 U/S 机器 CSR 与 U 的 MRET（01 P0-01 = 02-4，同根）

- 输入：真实指令位从 `backend_top` 派发口注入，端口 `priv_i` 给 U(00)/S(01)/M(11)：p1/p2 `csrrw x1,mstatus,x0`（`0x300010f3`）、p4 U `mret`（`0x30200073`）；p0/p3/p5 为控制。
- 观察：p1/p2/p4 均 `illegal=0, commit=1, trap2=0`；p1/p2 `csr_we_seen=1`，p4 `xret=1`。p0 非法指令 cause2，p3/p5 M 下合法。
- 期望：U/S 访问 M CSR、U 执行 MRET 均应 cause 2 且无 CSR/xRET 提交副作用。
- 等级：**动态-后端模块级**。只证明后端发出 CSR 写使能/xRET 口事件；夹具**未实例化 csr_file/priv_ctrl/trap_ctrl**，不声称 mstatus 值被改写、MRET 完成特权切换或整核提权。
- 日志：[log_p1.log](validation/privilege-memory/log_p1.log)、[log_p2.log](validation/privilege-memory/log_p2.log)、[log_p4.log](validation/privilege-memory/log_p4.log)；说明 [results.md](validation/privilege-memory/results.md)。

### 3.6 CLINT 在 mtime==mtimecmp 时不置 MTIP（01 P1-09）

- 输入：经真实 MMIO 写口写 `mtimecmp=T`，并把 `mtime` 连续 16 拍保持 T−1/T/T+1，每拍读回校验（`readback_ok=1`）。
- 观察：b2 在 16 拍持续相等时 MTIP 恒 0；b1(T−1)=0、b3(T+1)=16/16 为控制。
- 期望：`mtime ≥ mtimecmp` 时 pending（16 拍应置起），排除“一拍传播延迟”解释。
- 等级：**动态-CLINT 模块级**（真实 req/resp）；未接 mmio_route/top，不声称整核定时器中断路径已端到端复现。日志 [log_b1.log](validation/privilege-memory/log_b1.log)、[log_b2.log](validation/privilege-memory/log_b2.log)、[log_b3.log](validation/privilege-memory/log_b3.log)。

### 3.7 LSQ 已提交 LQ 在 ROB 63→0 环绕时不释放（03 F1）

- 输入：经真实 D3 分配口分配槽 0/1，ROB 索引 (63,0)；随后把 `rob_head=63, cmt_n=2` 作为提交窗口，观测一个沿后 `ld_v`。
- 观察：l1 `v0=0, v1=1`（槽 1 泄漏）；l2（head=0，分配 (0,1)）`v0=0,v1=0` 为控制；两例分配回读 `pre_alloc v0=1` 排除未真正分配。
- 期望：年龄应为 1，两槽均释放。根因是 `lsq_simple.v:1348` 用 7 bit 模 128 年龄而 ROB 深度 64。
- 等级：**动态-LSQ 状态转移级**：真实分配+真实 LQ 阵列+受控提交窗口输入；未构造整核程序证明可达，分支年轻判定同源风险未单独测。日志 [log_l1.log](validation/privilege-memory/log_l1.log)、[log_l2.log](validation/privilege-memory/log_l2.log)。

## 4. 按处置主题归并的核心问题

> 归并规则：同一根因跨域只列一行并保留源映射；“接口待验证”“测试风险”不升级为已确认集成缺陷。P 级沿用源报告，仅用于排序，**不相加**。

### 4.1 特权、机器状态与中断

| 条目 | 源报告 | P | 证据等级 | 处置要点 |
|---|---|---|---|---|
| 2B 译码权限硬接 M，S/U 可提交 M CSR/xRET；2B CSR 检查悬空、xRET 直接接受 | 01 P0-01；02-4 | P0 | 动态模块级（3.5） | 同根合并；在提交可信边界按实际 priv 复查 CSR/MRET/SRET/SFENCE/TVM/TSR，并处理在飞指令 |
| PMP 本项 L 不锁自身 `pmpaddr`（i+1 TOR 才锁，i=15 不锁） | 01 P0-02 | P0 | 静态；TB 反向固化 | 地址锁 = own.L OR successor(L&&TOR)；修正 TB oracle |
| counteren 不参与 S/U 计数器访问；mcycle/minstret 不自增/不与影子同体；time 影子接 cycle 而非 CLINT mtime | 01 P1-01/07/08 | P1 | 静态 | 统一 64 位可写本体与只读影子；两级 counteren；time 影射 mtime 或规范 trap |
| TVM 可写但不约束 S 的 satp/SFENCE.VMA；2A M SRET 被 TSR 误禁 | 01 P1-02/12 | P1 | 静态 | 权限判据按“S&&TVM”“U 或 (S&&TSR)”限定 |
| 未委托 SSI/STI/SEI 被永久屏蔽而非送 M；sie/sip 未按 mideleg 受限别名 | 01 P1-04/05 | P1 | 静态 | 先按每 bit 委托定目标，再做全局使能；sie/sip 读写视图与掩码用实际 mideleg |
| mstatus/sstatus 提交旁路实为 old OR new，同拍无法清位 | 01 P1-06 | P1 | 静态；接口待验证 | 用字段写掩码替换，覆盖 1→0 与 MPP 降级；需与 CSR 同拍时序反证 |
| 2B 宣告 misa.A 却拒全部 A 指令；M 模式 WFI 无条件非法 | 01 P1-03 | P1 | 静态（仅 2B） | 补 A 或分核声明；WFI 至少合法 NOP |
| CLINT MTIP 用 `>`，相等不挂起；TB 固化错误 | 01 P1-09 | P1 | 动态模块级（3.6） | 改 `>=`，同步注释与 TB |
| PLIC gateway 可撤回已挂起请求、completion 前可再投递、未使能 context completion 未忽略；claim 错受 threshold 过滤 | 01 P1-10/11 | P1 | 静态；PLIC 规范对照 | 每源 outstanding/busy 到有效 completion；claim 与 notification 候选分离 |
| taken 控制转移提交边界的中断 EPC 取顺序地址 | 08-05 | P1 | 静态；2A 时序推导 | 实际下一 PC 随控制指令传到 W，链接值与 EPC 分离 |

### 4.2 前端、译码与预测

| 条目 | 源报告 | P | 证据等级 | 处置要点 |
|---|---|---|---|---|
| C MISC-ALU rd′ 取错（同时误作 rd/rs1） | 05 F05-01 | P0 | 动态模块级（3.1） | 只把该组目的/源接 `rs1_p`，勿改 CL 目的域 |
| 真实 Sv32 取指 fault 被忽略，`done=1,fault=1` 仍取指；跨页第二 parcel 用起始 PA+2 | 05 F05-02 | P0 | 静态 | fault 不访问 cache，以故障 parcel 入队，保留 VA/指令起点与故障部分 VA |
| C.EBREAK 误拒、C.JR x0 放行 | 05 F05-03 | P1 | 动态模块级（3.2） | 分开 JR/JALR/EBREAK 合法性；保留按项目规则判 ill |
| OP-FP 保留/不支持字段被认作正常指令 | 05 F05-04 | P1 | 动态 5 例（3.3）+静态 | 完整 mask/match，逐字段翻转正反控；rm 保留另审 |
| checkpoint 一块多 lane 共用 id 且可提前释放 | 05 F05-05 | P1 | 接口待验证 | 仅真正分配的分支持有 valid 或块级引用计数；需错路径恢复快照反证 |
| F2 预测结果可能错位一拍；反压时块载荷不锁存、RAS 实时输入 | 05 F05-06/07 | P1 | 接口待验证 | 查询响应带 valid/PC 配对；输出寄存并持稳到握手 |
| `ras_repair_addr` 对外未驱动（内部重定向不受影响） | 05 F05-09 | P2 | 静态 | 端口 assign 或删除接口（须授权），不报“修复跳未知地址” |
| 前端黄金集成 TB 只比 PC，不比指令位/长度；任意 PC 分歧都被黄金重定向吸收 | 05 F05-08；07-4（同根） | P1 | 测试风险 | 逐 lane 比 insn/len；重定向前须证明确有更老控制流误判 |
| “交替数据相关分支”激励退化，taken/NT 下一 PC 相同 | 10 P1-10-C1 | P1 | 测试风险 | 只在一处递增，taken 目标与 fall-through 分离并计数 |

### 4.3 后端、回滚与精确提交

| 条目 | 源报告 | P | 证据等级 | 处置要点 |
|---|---|---|---|---|
| f0 目的被 `drd!=0` 抑制，rename/PRF/提交全链不写 | 02-1 | P0 | 动态后端模块级（3.4） | FP 目的不得套 x0 硬连零规则；补 f0 写后读与 f1 对照 |
| 回滚后同组 dst mask 残留；环绕后组快照覆盖仍存活老分支 | 02-2/02-3 | P0 | 静态 | 组初始化/恢复带代际或逐项清理；需两次 squash/跨 63→0 反证 |
| 多 CSR 同块时 pending 过早清除，年轻 load 可用旧翻译上下文 | 02-5 | P1 | 接口待验证 | 跟踪最年轻未提交 CSR 并仅按匹配 idx 清除，或显式维护未提交 CSR 集合/计数；同块 CSR+load 定向验证 |
| `b2_csr` 桩写 frm 取 `wdata[7:5]`（写 1 得 0） | 02-6 | P1 | 测试桩（非现役 core） | 修桩；不得外推 csr_file 同错 |
| 整数 load 依赖的多拍执行器提前采旧操作数（MDU/FPU go 未受 load-use 门控） | 08-01 | P1 | 静态；2A 时序推导 | 派发受真实源就绪门控；`load_use_stall && e_need_mdu -> !e_mdu_go` |
| BRU 在 M 阻塞时重定向并清掉尚未推进的自身 | 08-02 | P1 | 静态；2A 时序推导 | 仅在分支可推进时重定向，或保留到 EM 接收 |

### 4.4 LSQ、MMU、Cache 与总线

| 条目 | 源报告 | P | 证据等级 | 处置要点 |
|---|---|---|---|---|
| ROB64 仍用模 128 年龄：跨环 LQ 不释放，store 翻译门/分支年轻判定同源 | 03 F1 | P0 | 动态状态转移级（3.7） | 先在 ROB_IDX_W 取模；已提交未排空项另设提交状态 |
| flush 期间受理 store 但 CDQ 不出队，可重复副作用或维护死锁 | 03 F3 | P0 | 静态 | CDQ 更新独立于推测冲刷，push/pop 统一计数；MMIO 写计数反证 |
| TLB 丢 D，load 填表后 store 绕过 Svade；按 VA、全 ASID 的 SFENCE 错误保留 global；Sv32 高两位 PA 被折叠 | 04-01/02/03 | P0 | 静态 | TLB 保存/检查 D；仅 `rs2!=x0` 排除 global；保留 34 位到 PMP/PMA 判定，非零高位报 access fault |
| L1D 写回 valid 早于描述符锁存，可能把脏数据写到旧地址 | 04-04 | P0 | 静态 | 描述符锁存后再拉 valid，或同拍组合输出并记握手 |
| STQ 32 槽扫描误用 8 槽编码器；拆笔低字 fire 即 ret、高字可误标复用槽；跨 4KB store 高笔直接 PA+4 | 03 F2/F4/F5 | P1 | 静态 | 独立宽编码器；最后一笔才 ret/带代际；两半分别翻译与权限检查 |
| 最终数据 PMP 与 AXI 错误未接精确异常（2B resp_error 悬空、错误 R 拍仍填缓存） | 03 F6；04 跨域 | P1 | 静态 | 最终字节范围 PMP；错误响应禁止有效回填，保留 cause 5/7 |
| MMIO 副作用 load 可投机执行（claim 在 AD_WAIT 生效，squash 不入适配器） | 03 F7 | P1 | 静态；接口待验证 | 强副作用设备 load 等 ROB 头且获不可撤销许可 |
| AXI split 首笔就 done；错误 refill 仍置 valid、单槽 poison 不护多行；Zicbom 被当需 D 的 store | 04-05/06/07 | P1 | 静态 | done 覆盖整个逻辑请求；事务级 error/逐行 poison；CBM 独立权限（load OR store，不查 D） |
| CLINT/PLIC TB 的“不发 AXI”断言恒真，不能证明 top 无并行 AXI 访问 | 01 P2-01；07-9 | P2 | 测试风险 | 顶层/AXI monitor 计数，门控变异反证 |

### 4.5 执行单元与 FPU

| 条目 | 源报告 | P | 证据等级 | 处置要点 |
|---|---|---|---|---|
| 除法/开方“拍数参数”失效：每拍重复同一步，`SPC_SQRT` 未用于循环 | 06 P1-06-01 | P1 | 静态 | 删除虚假可配置承诺或真正推进多步；修活前重审共享 round 仲裁窗口 |
| SC 后接 DS 时较早 SC 的 done 可能配到 DS 结果 | 06 P1-06-02 | P1 | **接口待验证** | 当前 2A/2B 由在飞位限制单条 E 指令，**不能冒充当前集成 bug**；加 ready/排空或结果仲裁 |
| MDU/FPU/FP load-use 测试断言空洞（done 拍、动态 frm 结果、FMA rs1 依赖、默认档不命中关键互锁） | 06 P1-06-03；07-5 | P1 | 测试风险 | 逐沿断言、单拍请求、全值/逐源注错；正式入口纳入敏感档 |
| IP 分支注释与当前实现不一致 | 06 P2-06-04 | P2 | 静态 | 同步注释/实现事实，由 IP 域核综合层次 |
| **已修不重报**：MDU 商高 32/余低 32；`read_first` 显式传递 | 08；02/03 | — | 只读核对 | 不列为现存缺陷；历史副本不得再报 |

### 4.6 测试基础设施与 fail-closed

| 条目 | 源报告 | P | 证据等级 | 处置要点 |
|---|---|---|---|---|
| 编译失败降级条件过宽；默认 SKIP 可 rc0 且成功清理删跳过日志 | 07-1/2 | P1 | 测试风险 | 只允许已分类诊断；正式入口固定 strict，保留 skip 日志 |
| 2B 黄金写回接受 `gold+delta`；前端任意 PC 分歧被黄金纠偏 | 07-3/4；05-08 | P1 | 测试风险 | 按可重定位项区分期望；逐 lane 比指令位，重定向需归因 |
| 默认 FP load-use 回归不强制关键重叠；外部锁步缺 store/CSR/FP 状态比较 | 07-5/6 | P1 | 测试风险 | 场景命中数与正反证档入正式入口；扩展 store/CSR/64 位 FP 探针 |
| tohost 成功/终止不看 WSTRB；UART 零 strb 也计数；串行 UART 不查停止位 | 09 P1-09-V1/P2-09-V2 | P1/P2 | 测试风险 | 按 strb 合并后再判终止；零 strb 硬违规；停止位错误入判据 |
| 最小 AXI stub 不验证 LEN/SIZE/BURST/WLAST 一致性 | 09 P2-09-V3 | P2 | 测试风险 | 地址/beat scoreboard 与末拍校验，范围外事务失败 |
| 产物隔离只保护批内；黄金生成无终止符号/类型/64 位绑定 | 07-7/8 | P2 | 测试风险 | 每次运行独立目录、原子发布、输入哈希与类型/64 位输出 |
| 常量/取样“覆盖证明”偏弱（CLINT/PLIC 常零 AXI、宽 RAM 第二读后才查） | 07-9 | P2 | 测试风险 | 顶层 monitor；冲突首拍/独立随机读地址 |
| 配置声明非 runner 单一真源；arch PLIC 宏 M/S 偏移与现役译码不符 | 10 P2-10-C2/C3 | P2 | 测试风险（潜伏） | 真正使用并归一化配置，或删伪可配字段；宏绑定统一映射 |
| 差分“等价”只约束数量不查内容；三配置 A/B 一致性不参与结果 | 11-01/02 | P1 | 测试风险 | 精确白名单字段+逐字节；比较失败置 VERDICT=1 |
| 转换/生成工具失败被旧产物掩盖；IP xsim rc/锚点可把超时当“缺陷复现”；layout update 丢弃 FAILED | 11-03/04/05 | P1 | 测试风险 | 每步 rc 传播、临时目录原子发布、唯一完成锚点+向量数、update 前检查 FAILED |

### 4.7 集成、综合与板级

| 条目 | 源报告 | P | 证据等级 | 处置要点 |
|---|---|---|---|---|
| 实现入口忽略 `TOP_TAG`，可能实现 2A 旧 DCP 却标为 2B | 08-03 | P1 | 静态（脚本变量展开） | impl 选择统一 TOP_TAG，核 top/part/源 hash/宏；旧 checkpoint 显式标历史 |
| front4 wrapper 行为模型与 IP READ_FIRST/同步输出复位不一致 | 08-04 | P2 | 接口待验证 | 读写独立分支、匹配输出复位、明确 INIT/热复位契约；不升级为已证架构错 |
| 板级证据链为旧交付自检（bit/日志/时序无同次 manifest；DRC 缺文件可成功） | 11；08 边界 | P1 | 测试/板级风险 | 源码+ELF/bin/hex+IP 配置+网表+bitstream+板号/烧录记录同次 manifest；当前无 WNS/真板结论 |

## 5. 源域条目计数（非去重总计）

| 域 | 报告条目计数 | 其中本次动态 | 说明 |
|---|---:|---:|---|
| 01 特权/CSR/中断/PMP/CLINT/PLIC | P0 2 / P1 12 / P2 1 = 15 | 2 条（P0-01、P1-09） | P0-01 与 02-4 同根 |
| 02 乱序后端 | P0 4 / P1 2 = 6 | 1 条（f0） | 02-4 与 01 P0-01 同根，动态证据归 01 |
| 03 LSQ/2B | P0 2 / P1 5 = 7 | 1 条（F1） | F3/F5/F6 与 04 交界 |
| 04 Cache/MMU/PTW/TLB/AXI | P0 4 / P1 3 = 7 | 0 | 04 错误响应与 03 F6 合并 |
| 05 前端/译码 | P0 2 / P1 6 / P2 1 = 9 | 3 条（05-01/03/04） | 05-08 与 07-4 同根 |
| 06 执行 | P1 3 / P2 1 = 4 | 0 | MDU 已修项不重报 |
| 07 测试基础设施 | P1 6 / P2 3 = 9 | 0 | 05-08/07-4、06 断言缺口交叉 |
| 08 2A 集成/综合 | P1 4 / P2 1 = 5 | 0 | 08-01/02/05 为时序推导 |
| 09 共享验证补审 | P1 1 / P2 2 = 3 | 0 | 与 07 共享 stub 边界 |
| 10 程序/配置 | P1 1 / P2 2 = 3 | 0 | P1 为激励退化 |
| 11 板级辅助链 | P1 5 = 5 | 0 | 全为验证链失效，不新增 CPU 缺陷 |
| **合计（条目相加）** | **P0 14 / P1 48 / P2 11 = 73** | **7 主题** | **非去重、非根因数、不得当总 bug 数** |

## 6. 修复建议顺序（建议，不自动执行）

1. **安全与不可逆副作用**：01 P0-01（权限/CSR/xRET）、01 P0-02（PMP 自锁）、02-1（f0）、03 F3（flush store/CDQ）、03 F6+04（最终数据 PMP/AXI 错误精确异常）、03 F7（MMIO 投机 load）、04-01/02/03（D/SFENCE/PA 折叠）、04-04（L1D 写回地址）。先保证“拒绝/异常/不重复写”正确，再谈性能。
2. **回滚与数据正确性**：02-2/02-3（rename mask/快照）、03 F1/F2/F4/F5（年龄、STQ 宽度、拆笔 ret、跨页 store）、05-01（C MISC-ALU）、08-01/08-02（load-use/BRU 重定向）、08-05（EPC）、04-05（split done）、04-07（error refill）。
3. **测试 oracle 与 fail-closed**：CLINT/PLIC 错误期望、前端黄金 PC-only、2B `gold+delta`、regress 默认 SKIP rc0、tohost/UART strb、差分/矩阵/xsim/layout 的 rc 与判据。所有修复以“旧版本/变异必须红”为正反证；不得为脚本 PASS 保留错误期望。
4. **ISA/时序/板级**：counteren/TVM/WFI/time、PLIC gateway/threshold、checkpoint/F2/反压契约、TOP_TAG 与 DCP 新鲜性、板级同次 manifest。FPU SC→DS 只在单在飞门控变化后再评估，当前不按集成 bug 修。

## 7. 已知未修、待可达性、撤回与不报

- **撤回**：05 的 ADDI4SPN/CB 立即数“颠倒”线索撤回——实际拼接正确，仅注释位序误导，不列功能缺陷。曾提议删除 LOCAL 历史预测器/表项，**未采纳、未执行**，不按死代码报错。
- **不重报（已修/核对）**：MDU 商高 32/余低 32 与 `read_first` 已修；01 的 D2（U 被 SIE 掩蔽）、D6（Vectored WARL）已修；D1/D8 非本域主责未独立复核。08 的顶层 48 端口静态核对不重复计。
- **保留金标非缺失**：06 的保留 add/mul/FMA 金标未例化不等于功能缺失；`fpu_add.v` 当前活跃 delay/round/align helper 仍是活跃依赖，不能整体称死代码。
- **待可达性/未定根**：02 的 `win_idx` 无 epoch、typed 更新口/epoch 回卷、checkpoint 共享释放等旧候选未动态定根；08 的 IDLE 无条件清 `m_exc_q`、组合环/latch 仅有静态候选，未做工具级证明；05 F05-05/06/07、06 P1-06-02、02-5 均为接口待验证。它们不计入“已确认集成缺陷”。
- **未做**：整核取指级复现；未重跑原 33 项回归与 tb_core_top_2b 集成判据；未跑 arch-test、锁步差分、Vivado 综合/时序、真板、SoftFloat/形式验证；历史 formal 33/33、旧综合/时序只作历史。Linux/U-Boot/QEMU 完整源不在本次范围。
- **覆盖诚实边界**：生成的 `.svh` 只做生成链/抽样/文件身份登记，未逐向量独立重算 oracle；历史 `dyn_probe*`/`n*stress`/scratch/oldrtl 不是当前 formal/DUT，未逐行者不因名称断言已失配。详见 [COVERAGE.md](COVERAGE.md)。

## 8. 缺陷 runner 语义与夹具修复说明

当前定向验证的 runner 以“**缺陷已复现**”为成功标志：缺陷例返回 `DEFECT_REPRODUCED` 时脚本 exit 0，控制例返回 `CONTROL_OK`。这只表示“按预测机理观察到错误行为”，**不代表 DUT 正常**。RTL 修复后这些用例应不再满足该标志；未来必须把它们转成“正确值/正确副作用”的回归，并用**旧版本或变异体**作反证（修复前应红、修复后应绿），不能为了脚本 PASS 而保留错误期望。CLINT/PLIC 的单元 TB 反向期望就是反面教材。

本轮加固已修正三处**夹具自身**问题并完成反证：空清单/缺例预检（硬编码 24/11 清单，`manifest preflight failed` + exit 1）、参考计算未校验退出码/锚点（要求 rc=0 且精确 `REF_CHECK`）、反证副本 runner 漂移（`cmp` 前置检查，漂移即 `FIXTURE DRIFT`）。此外参考模型 `c.nop` 重建常量笔误 `0x2001→0x0001` 仅影响夹具，不影响 DUT 观测量与任何缺陷结论。这些是**验证夹具修复**，不得混同为原产品的新发现，也不计入 17 个缺陷复现。

## 9. 交付物与复核入口

- [COVERAGE.md](COVERAGE.md)：63 RTL 读取深度、33 正式 TB 联合覆盖、09/10/11 补批闭合与边界。
- [COVERAGE.tsv](COVERAGE.tsv)：BASELINE 245 路径 + 2 个额外支持文件 = 247 条，逐项登记 role/category、实际深度、证据报告、限制。
- 分域原文：[01](01-privilege.md)、[02](02-backend.md)、[03](03-lsq-2b.md)、[04](04-memory-bus.md)、[05](05-frontend-decode.md)、[06](06-execution.md)、[07](07-test-infrastructure.md)、[08](08-integration-synthesis.md)、[09](09-verification-followup.md)、[10](10-program-config.md)、[11](11-board-support.md)；台账 [PROGRESS.md](PROGRESS.md)。
- 动态证据：[decode-fp0 results](validation/decode-fp0/results.md)（[母复跑](validation/decode-fp0/mother-validation.log)、[反证](validation/decode-fp0/mother-negative.log)）；[privilege-memory results](validation/privilege-memory/results.md)（[母复跑](validation/privilege-memory/mother-validation.log)、[反证](validation/privilege-memory/mother-negative.log)）。
- 本报告为专项审计报告，不改 area 总结报告，不代表完整功能覆盖或发布放行。
