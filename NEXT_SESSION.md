# NEXT_SESSION.md — 当前状态、待办与验证基线（唯一真源）

> 更新时间：2026-10-20。本文是唯一当前状态/待办/日期来源；规则见 [AGENT.md](AGENT.md)，用法见 [USAGE.md](USAGE.md)，项目入口/目录见 [README.md](README.md)。修改前历史见 [archive/next-session-pre-workflow-2026-10-18.md](archive/next-session-pre-workflow-2026-10-18.md)（历史快照，非当前指令）。
> **2026-10-20 用户明确继续，恢复功能修复与验收**：起点为未验收检查点 `153b63d`，恢复时工作树干净、`dev` 与 `origin/dev` 一致（不据此声称由本代理推送）。已重新派发rename退修、MMU独审、LSQ独立动态检查及F4-0顶层基础收线；继续至既定功能阶段目标，重大架构裁决才询问。用户10-20明确将“已退休store外部总线错误的精确归属/上报”保留到本阶段结束后统一审阅，本阶段不改该提交协议或新增异步错误机制；其余修复/验收继续，阶段汇报须明确这一例外，不能宣称全功能无已知缺口。昨日暂停归档并非功能放行，既有未闭问题仍需处理。主 Agent **硬性禁用 goal**，仅用 task/todo 与完成通知。此前基线已提交推送，部分局部修复已入库；当前完整新树尚未功能放行。阶段简报只在对话给出，不新建报告。最近全局 RTL 与测试审计见[主报告](sim/audit/global-2026-10-18/REPORT.md)、[覆盖清单](sim/audit/global-2026-10-18/COVERAGE.md)与[审计台账](sim/audit/global-2026-10-18/PROGRESS.md)。下文原“最近记录”仍为历史基线，不代表本轮已全量复跑。

## 1. 当前状态

- 审计/功能修复起点：`dev` 的冻结代码点为 `b284df704e4b0984cef8fa8062ada01656eca287`；后续整理基线与修复提交以 git 记录为准，不把此 SHA 当永远的当前 HEAD。2026-10-18 实测 `master` = `b13e4cc`（2B 综合点，**不是旧项目冻结**）。旧一代实现只作反面教训，禁止复制；远端/tag 以 git 为准。
- 本轮之前的 RTL 修复：`7e2e730`（D2/D6/D8）、`bd622ee`（D1）已入库；本轮已验证修复及实际提交以 §2.1 和 git 为准，不再将该旧 SHA 当最新修复。
- **2A**：M1–M5 已上板验收（tag `2A-M5`，`RESULT: RV32GC-M5-OK` @33 MHz 同域）；arch-test 全绿。当前 **arch-test DUT = 2A `core_top`，不是 2B**。
- **2B**：既有功能仿真/回归已完成，**未上板**；4 取指/4 派发发射、后端 2 提交。ROB 64/NREG 64/LQ 8/SQ 32 等是当前实现参数，不是不可变硬指标。
- **2B ISA 未闭环**：`misa.A=1`，但 AMO/LR/SC 与 WFI 仍走 cause 2（D7 待裁决）；不得宣称 2B 的 A 已实现，也不得把 2A arch-test 全绿当作 2B ISA 全绿。
- **软件链**：QEMU chiplab 上 U-Boot/Linux/UBIFS/TFTP 链已通过；这不等于 2B 上板启动。总目标仍是 NAND 启动 Linux。
- **修复前残留（D1，历史）**：2A/2B 非对齐处理分叉，旧锁步未含跨界store，旧LSQ跨页第二笔PA+4及低字fire过早置ret。当前LSQ候选已修改拆笔/独立翻译/退休身份，但尚未复审及整核验收，实际待办见§2.1；不再把旧描述当当前实现结论。原证据见 `sim/audit/audit2_lsq_mis_report.md`。
- **上一轮文档改动**：重整四个入口 + 两个 `archive/` 历史快照，并含 `prompts/*`（common/四个角色）与 `docs/*`（技术正文/索引）改动；整体不涉及 RTL，不算新的 RTL 回归或综合证据。
- **最近全局审计冻结结论（修复前历史）**：冻结上述 HEAD；63 个 RTL、33 个正式 TB 及活动共享/程序/板级验证逻辑已按[覆盖清单](sim/audit/global-2026-10-18/COVERAGE.md)登记实际深度。母复跑 35 个隔离用例：17 个缺陷复现、18 个控制，另 9 个夹具反证；均为模块/接口/状态转移级，**不是整核合规或原全量回归通过**。源码清单 245/245 SHA 一致，额外两个综合支持文件与 HEAD 一致；审计当时未改原 RTL/测试/脚本/配置、未提交 Git；审计材料现已随 `201acf6` 入库，当前功能修复以 §2.1 为准，不再把冻结 SHA/旧验证结果当当前树。主报告在该冻结点的结论为不满足功能放行条件；汇总登记问题已[关闭复核](sim/audit/global-2026-10-18/SUMMARY_REVIEW.md)，不代表 CPU 缺陷已修。

## 2. 待办（按优先级）

### 2.1 当前功能修复阶段（用户已授权，自主推进）

当前目标不是让旧的宽松判据继续全绿，而是保留原功能覆盖、修复确定错误并用正确期望验收。主要发现来源为[主报告 §4](sim/audit/global-2026-10-18/REPORT.md#L93-L182)，不机械累计跨域重复条目。

| 批次 | 范围与完成判据 | 当前状态 |
|---|---|---|
| G0 Git 基线 | 生成物忽略、复现源码/夹具保留、精选冻结证据保留；文档与审计成果分清提交并推送 `dev`，不夹带功能 RTL 修复 | 已完成：`8556b6b` + `201acf6` 已推送且当时工作树干净；97 个临时生成物忽略，源码与 41 份精选冻结日志保留 |
| F0 测试基础设施 | fail-closed、输出隔离/留档、正确行为回归及旧基线反证；原 33 个正式 TB 不删除，新增清单不可为空/缺例，跳过算失败 | 第一包已通过：独审先后7项问题均关闭；母最终复跑237项隔离断言、执行输入哈希和旧共享证据内容/mtime/inode均不变；独立探针确认旧误绿路径拒绝及合法正控通过。其余oracle随对应功能包修；9个真实功能包尚未齐全，非阶段完成。旧基线33/33仅作对照 |
| F1 基础语义与特权 | C 译码、f0、CSR 权限/锁/计数/TVM、中断和 CLINT/PLIC；测试 oracle 同步修正 | 译码/设备已含DUT_ROOT编译隔离并独审0，母最终同源重验：译码80向量/260检查、旧61检查红，正式driver异地+fresh各5正控/19反证；设备55检查、旧8标签且CTRL0、25自证，原3个unit均通过。后端基础包（含最后poison恢复）静态复审0，10-20母已复跑默认18/18、19/19反证、旧7触发红/11控制绿/新18绿，主10输入前后SHA不变，实际编译闭包在各包快照记录；不是整树回归。CSR整包已复审0并母复跑41/101、旧51失败且CTRL0、47自证及2原unit，本地已提交1220b7f；译码/设备已提交05a4f77，框架7967a30。均非整核放行 |
| F2 重命名与 LSQ | 回滚 mask/快照、ROB 环绕年龄、STQ 编码、CDQ flush/拆笔身份/跨页 store；不靠缩窗口/单发射隐藏缺陷 | LSQ叶包已静态复审0，母默认18/285及20自证driver/旧87失败12签名控制绿，父PKGOUT下通过且6输入不变；原独立跨页/合法flush附加验证仍有，但LQ取消/PMP/MMIO最终门禁未闭。rename RTL0a978两环绕根有独立旧红新绿，最终pkg10124/driver24a721已独审0且母默认25、旧11红14控、父PKGOUT下driver27通过，6输入不变；不复用旧24数据。历史自环日志当前cohort不复现，preg<32不可分配的旧推断已撤回，未放宽诊断。ROB b227局部审发现squash后同拍提交/同槽复用仍可贴旧PC的P1，已退修；原8例/私有219不当静态放行，产品safehead透传在做 |
| F3 MMU/Cache/总线 | D 位/SFENCE/高 PA/CMO 权限、写回地址/错误回填、拆分 done；最终 PMP/异常通路与设备副作用 | MMU叶包已独审0并母验：新32/225全绿、旧32/243完整40失败/13标签且CTRL0、自证50+18，15主输入不变；原PTW/LSU/PMP3unit也母跑通过。Cache/AXI最终补齐维护两路各8词与目标set无幽灵valid，独审0；母新28/448、27自证driver、memory真实2/2及8反证、原I/D/AXI3unit全部过，24输入不变。旧331检查/81失配24向量签名是反证而非根因数。Icache原失败行cs_err_paddr已接，整核消费者与取消归属仍须F4验证 |
| F4 集成 | 前端取指 fault/跨页 parcel、后端权限/CSR/副作用门控、2A load-use/重定向/EPC，端口/位域变更单点串行合并 | 两top已基础接Cache真实beat错误/B终结、front4 AF及响应错误/原PA；仍未验收，原5测试曾4/5。C8已独立实证是ROB预取未分配槽旧载荷+RAW危险拍中断取旧PC，非mepc未reset；ROB根修及safehead端口在做，不放宽断言。原Top实例预算耗尽已换新同路由，Top与backend权限分独占；计数真实64本体/mtime与位次写序合线、CSR程序序权限/pending/TVM/TSR正做。前端175检查稿含故障/反压/指令位，预测器查表配对另修。数据PMP/MMIO非投机/uncached取消、2A控制仍待；仅已退休store外部错误按用户决定延后阶段末审，不假精确上报 |
| F5 阶段验收 | 独立审计、严格完整正式回归、新正确行为回归及受影响集成/锁步；每个确认修复根因至少触发例旧基线红/修复树绿，控制例也须正确；证据绑定版本/配置/同次运行 | 用户已恢复验收授权；须叶模块修复、复审及顶层接线齐备后冻结新树运行，当前未完成 |

不可变旧基线回归已采收：提交 `201acf61e118a3fb533e1a96768687a35efa1751`，源码快照在 `build/functional/baseline-201acf6/src/`，与原冻结清单 245/245 SHA 相同；[回归日志](build/functional/baseline-201acf6/regress.log)记载 33/33、skip=0、fail=0，[退出码](build/functional/baseline-201acf6/exit_code.txt)为0。此为未修复旧树对照，不能作为修复树验收；后台任务已结束并采收。

已验收的局部证据（生成物不代表 Git 已追踪）：F0 [母最终237项自证与输入/旧证据保护记录](build/functional/runner/mother-final-CxIEVQ7h/)，[独立入口反证前后表](build/functional/runner-review-tests/results/candidate.tsv)；译码包[母正向/旧树/19反证/正式unit及输入哈希](build/functional/mother-decode-2cbWh3kD/)。两包均有独立静态复审0剩余；编译隔离最后稿的[母最终同源复测](build/functional/mother-basic-final-oVSA4E5x/)覆盖译码80/260、旧61失败、真实树与fresh各5+19、设备55/旧8标签控制0/25自证/原3unit通过，17输入前后哈希一致。提交前仅修设备脚本一处注释尾空格，[母按最新字节重验设备55/旧8标签/25自证](build/functional/mother-basic-release-yoYSdLqt/)并确认其余16输入未变；未借旧脚本SHA冒充新结果。[CSR母复测](build/functional/mother-privilege-tmhESGLz/)记录41/101、旧51检查失败/CTRL0、47自证与原CSR/trap两个unit通过及输入前后SHA一致，整包独立复审剩余0。[10-20后端母复测](build/functional/mother-backend-hioXGAfh/)为18正确向量/19反证及旧7触发红11控制绿、新18绿，10主输入前后SHA一致、每次编译的26依赖见包内快照；未跑两top相关正式unit或全树回归。[MMU母最终32向量/225检查及50+18自证](build/functional/mother-mmu-3V9j9gb3/)和[原3unit母复跑](build/functional/mother-mmu-units-SfVfQIbP/)绑定15主输入/12实际unit输入前后不变；该叶独审0，不含未完成的Top集成。已过包的[严格CUSTOM四包入口](build/functional/mother-entry-accepted-F09mbxxf/)仅为当时译码/后端/CSR/设备输入，后续F1-B已改CSR相关源，不能复用该结果声称当前四包全绿。[LSQ母最终默认与20自证/旧树完整矩阵](build/functional/mother-lsq-final-d69p1xfh/)绑定6输入不变，叶包独审0；[Cache母28/436与24自证](build/functional/mother-cache-final-jay06n7v/)绑定12输入，但静态仍需补维护8词/目标组检查，不作放行。[三包混跑在rename-driver失败](build/functional/mother-leaf-final-g7rqex06/rename-driver.out)属于已发现的父PKGOUT隔离问题，后续LSQ/Cache当时未执行，不把该轮写成全过。[rename母最终25向量/旧11触发14控制/父PKGOUT下27自证](build/functional/mother-rename-release-xni8km19/)绑定6输入不变，当前该叶静态0；历史失败保留，不将父环境隔离问题归硬件。[Cache/Memory母最终448检查、27自证、2包聚合、8反证及原3unit](build/functional/mother-memory-release-9t0ro0qb/)绑定24输入不变，维护两路8词与正确目标组有效性探针已独审0；该叶可归档，非Top放行。当前树完整CPU/9包验收未完成。

不得放宽断言、保留反向 oracle、删减硬指标来换取成功；冻结审计目录的 `DEFECT_REPRODUCED` 是旧错误复现证据，不能直接当修复树的正确行为门禁。新验证源码与生成输出分开，生成输出放已忽略的 `build/` 下。A 能力声明等既有重大裁决项不得擅自降档，L2 未实现不扩成此次新架构任务；未完成的 ISA/综合/板级能力须明示。以下 D3–D9 保留追溯，**不是本次全部发现清单**。

| 编号 | 事项 | 当前动作 |
|---|---|---|
| D3 | `pmpcfg[i].L=1` 时 `pmpaddr[i]` 仍可写（`rtl/csr/csr_file.v`） | 修锁定逻辑 + 定向 TB；不改 PMP 粒度 G=0 裁决 |
| D4 | `mcounteren/scounteren` 门控缺失（`dec_csr.v`/`csr_file.v`） | 实现门控 + ZicntrU/反证用例 |
| D5 | `mstatus.TVM` 未强制（`priv_ctrl.v` 有 `tvm_o` 无消费者） | 实现 + S 模式非法用例 |
| D9 | 非委托 S 中断可见性：`mideleg[i]=0` 时 S 中断被屏蔽（[trap_ctrl](rtl/csr/trap_ctrl.v)） | 已由[01 分域](sim/audit/global-2026-10-18/01-privilege.md)静态复核；仍需动态矩阵验证，修复时补 U/S 非委托中断用例 |
| D7 | 2B `misa.A=1` 与 AMO/LR/SC/WFI cause 2 冲突 | **需用户架构裁决**（按核分档 misa / 明确 2B 里程碑不含 A、WFI）；未裁决不改 |

### 2.2 清理与送审（均未实施）

- **AUDIT3 §6-1 零影响批**（28 条）：删无消费网/未用参数/死寄存器等；含 `front4_top.v:140 ras_repair_addr` 悬空输出（当前无消费者，仍应修），删改前同步 TB。见 `sim/audit/audit3_report.md`。
- **送审池（须用户裁决）**：
  - `N34B-2` 删除 LOCAL 预测器（−915 LUT）：与 AGENT §1“锦标赛预测器”硬指标冲突，须改需求 + 修订 `docs/design/04-predictor.md`；patch 在 `fpga/scratch/n34b2_rtl_and_tb.patch`。
  - `AreaOptimized_medium` 配方：Gate C 实测 −13,959 LUT，代价 WNS −5.936 ns。
  - `K1` 读口折叠（−1,249）：patch `fpga/scratch/n21b_k1_rtl.patch`。

### 2.3 其他未完成/未启动

- arch-test 接入 2B（当前 `sim/arch_test/run.sh` 硬编码 2A，`sim/tb/tb_arch_test.sv` 例化 `core_top`），估 2–3.5 人日。
- 文档口径已同步：`docs/README.md` 提供现行/目标/历史分类；设计、平台/工具、移植与相关 README 已标注当前参数和验证边界。残余 RTL 注释（如 `rtl/back2/back2_params.vh`、`lsq_simple.v` 的旧提交宽度说明）留待后续代码批次；本轮未修改 RTL。
- post-route 时序签署、46 处位宽不匹配逐条核实等审计遗留项。

### 2.4 归档保留的未启动候选（不得静默过滤）

- **`win_idx` 加 epoch**：影子自检 300k 拍 3 次报“提交 lane 窗口载荷 ≠ 派发载荷”（cyc 94,486/123,246/254,759），是正确性信任缺口，优先级高于继续删 nq；见 [archive 历史快照](archive/next-session-pre-workflow-2026-10-18.md) §1.5.6 待办 4①。
- N29B 精确阻塞掩码（长尾治理，面积中性）；CDQ/StQDH 9 写口串行化（26 条 `8-4767` multiple-writes）；NREG↔ROB 深度解耦（N28A 建议独立）；CVT 四 rounder OOC 校准（N32A 上端距门槛 42 LUT/2.8%）。
- **AUDIT1 约束**：`p_*` 函数签名被 `tb_back2_lockstep` 层次名冻结（`backend_top.v:277-278`）；F1–F8 拆分不为面积（预估净 −0~−350 LUT）。
- **AUDIT3 高风险分类**（`sim/audit/audit3_report.md` §6-2/§6-3）：`rename.v:422` 两个 latch；17 处时序环/10 处推断 false path；17 文件 41 处裸 `Verilator` 注释致 lint 指令失效；`core_top_2b.v:71` aresetn 同步/异步混用；80 处 Set/Reset 同优先级。

## 3. 验证基线（可执行）

```bash
source scripts/env.sh
RV32_REGRESS_STRICT_SKIP=1 ./scripts/regress.sh   # 有跳过即失败(rc=3)；验收核对 33/33 锚点
# 将 2b_expname 换成本次 tag
RV32_SYNTH_TOP=core_top_2b RV32_SYNTH_TAG=2b_expname RV32_SYNTH_DIRECTIVE=RuntimeOptimized \
  ./fpga/run_vivado_batch.sh fpga/tcl/synth.tcl 16.667
```

判据入口：TB 在 `sim/tb`、`sim/unit`、`sim/lockstep`；复跑前读脚本与 `docs/kb/tools-and-flow.md`，不以旧日志代替。默认 SKIP 的回归 rc=0 **不算验收**。

| 证据 | 最近记录 | 说明 |
|---|---|---|
| `tb_core_top_2b` | 219/219 | 2B 集成 |
| `tb_back2_iq` | 151/151 | IQ |
| `tb_back2_lockstep` | 57 项 / 821 提交 / FAIL 0 | 2A/2B 锁步 |
| `./scripts/regress.sh` | 33/33 | 历史执行选项未记录 |
| `tb_back2_ipc` | IPC=2.0000（6000 条/3000 拍） | 性能 |
| 综合 | `d00eb03`：126,699 LUT（94.13%）/ 49,597 FF / RAMB36 40 / RAMB18 6 / DSP 21 / WNS≈−52 ns | **历史 RTL 点，不是 `7e2e730` 重综合**；时序未收敛，距旧 ≤80% 面积门槛约 −19k LUT |

- 性能验收：IPC=2.0000；C5 五档下限 **0.30 / 0.19 / 0.1094 / 0.0625 / 0.0469**，逐档不得低于。
- 回归验收：`RV32_REGRESS_STRICT_SKIP=1` + 核对 33/33 锚点；默认 SKIP 的 rc=0 不算通过。
- 上表是历史“最近已记录”，本轮没有复跑这些原入口；新隔离验证另见[审计报告](sim/audit/global-2026-10-18/REPORT.md)，不能替代原基线。综合历史证据：`fpga/out/synth_2b_n35b_16.667ns_utilization.rpt`；`d00eb03` 不是 `7e2e730` 的重综合。新 RTL 改动后旧证据不得复用；按影响范围重跑定向 + 集成 + 必要全量/性能/综合。
- 同一棵树、同一配置、同一次 run 已证明的证据不机械重复四套；没有实际跑的就写“未运行”。
- fail-closed / 正反证 / 母复核 / 输出隔离照旧；文档-only 只做一致性检查，不跑 CPU 回归。

## 4. 多仓快照（只读，不清理、不 fetch）

| 仓库 | 分支/HEAD | 注意 |
|---|---|---|
| chiplab | `chiplab_diff` / `602c8d2`，ahead 1 | `system_run.xpr` 已改 + 大量未跟踪 IP 产物；禁止顺手清理/提交 |
| u-boot | `dev` / `e14e7f924b7` | 软件链基线 |
| linux | `dev` / `a73502e13f05` | 软件链基线 |
| qemu | `chiplab-qemu-dev` / `ff45aed9cf` | QEMU chiplab machine |
| opensbi | `master` / `3593a5f`，behind 26 | **不 fetch**，滞后已知 |

这些是只读事实快照；是否合并/升级由用户裁决。

## 5. 平台/环境指针

- SPI XIP `0x1C00_0000`/`RESET_PC`、DDR3 `0x0`、33 MHz 同域、NAND 几何等：原文见 `docs/kb/platform-facts.md` 与 `docs/porting/*`；四入口不复述。
- 环境快照（2026-10-18）：`python3`、`node`、`iverilog`、`vvp`、`verilator` 命令存在，`/opt/riscv/bin/spike` 可执行；本轮未跑版本/CPU 测试。
- KB 复验：默认 LSA 检索存在误命中，`kb_manage reindex` 的 `lsaDims: 0` 本会话未生效；已用 `node ../dsh-extension/bin/riscv-kb.js build --no-lsa` 重建磁盘索引，并实测 CLI 搜索可返回规范与新文档。当前会话常驻工具仍缓存旧表，暂用 CLI search/get 或 `kb_get` 精确范围；新会话/重载后另验，不擅自重启服务。操作见 `docs/kb/tools-and-flow.md` 的知识库章节。
- WSL-only、禁系统安装、Vivado 2023.2 用法见 AGENT §6 与 `docs/kb/tools-and-flow.md`；子 Agent 路由唯一表见 AGENT §2。

## 6. 交接规则

- 本文只写当前状态/待办/基线；已完成流水、旧 checkpoint、agent ids、旧 goal ids 写入 `archive/`，不叠加。
- 用户最新指令优先；与本文/AGENT 冲突时先按用户指令，再更新文档。阶段收口停下等用户。
