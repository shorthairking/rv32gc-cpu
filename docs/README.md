# docs/ 索引 —— Agent 读取地图

> **本文只做地图，不是状态真源。** 现行状态/待办以 [`../NEXT_SESSION.md`](../NEXT_SESSION.md) 为唯一入口（已压缩为当前状态，不再按"最新交接点"翻找）；
> 现行契约只认 [`../AGENT.md`](../AGENT.md)；2B 参数唯一真源是
> [`../rtl/back2/back2_params.vh`](../rtl/back2/back2_params.vh)（2A 为
> [`../rtl/pkg/core_params.vh`](../rtl/pkg/core_params.vh)），RTL 真实连接优先于任何文档。
> 本页中的参数是 **2026-10-18 快照**，会随 RTL 演进；引用具体数字前先回读真源。
> **版本快照（2026-10-18）**：文档 HEAD `b284df7`；RTL 最新提交 `7e2e730`（D2/D6/D8；D1 非对齐 store 修复在 `bd622ee` 已入库）；综合记录截止 `d00eb03`。
> **历史报告/原始设计方案不是现行指令**：它们保留当时的测量与目标，不得据此声称"当前已实现/已验收"。

---

## 0. 推荐读取顺序

1. [`../AGENT.md`](../AGENT.md)（只读契约）：需求/硬指标、子 Agent 路由与分工、派发纪律、流程/验收、环境事实、台账规则——按章节名称定位，不复写编号。
2. [`../NEXT_SESSION.md`](../NEXT_SESSION.md)——唯一现行状态/待办入口（已压缩；**不要假定某项已完成**）。
3. 参数真源 + RTL：`rtl/back2/back2_params.vh`、`rtl/front4/front4_params.vh`、`rtl/pkg/core_params.vh`。
4. 按本页分类只读**需要的那一篇**，不要逐篇吞历史长文。
5. ISA 事实用 `kb_search`/`kb_get`（常驻知识库）或 CLI，不要直接读 `riscv-isa-manual/` 大文件。

---

## 1. 当前接口 / 现行参数（as-built）

| 入口 | 性质 | 说明 |
|---|---|---|
| [`design/01-overview-datapath.md`](design/01-overview-datapath.md) §5 | **现行顶层端口契约** | `core_top` 48 端口逐字表、AXI/调试组/复位口径；本文其余章节是阶段一设计目标。 |
| [`design/08-baseline-5stage.md`](design/08-baseline-5stage.md) | **2A 已验收核的实施规格** | 2A M1–M5 的 `core_top`、五级流水、CSR/PMP/Sv32、Cache/AXI 口径；2B 不另立端口。 |
| [`design/06-csr-privilege.md`](design/06-csr-privilege.md) | **CSR/特权规格** | ISA 语义与设计口径；但 D3/D4/D5/D7/D9 等实现差异**未关闭**，见 §3。 |
| [`design/05-cache-memory.md`](design/05-cache-memory.md) | **L1 现行参数 + L2 设计目标** | L1I 16 KB / L1D 32 KB 已实现；L2 256 KB 未实现（`RV32GC_L2_IMPLEMENTED=0`）。 |
| [`kb/platform-facts.md`](kb/platform-facts.md) | **平台硬事实台账** | chiplab 地址/端口/时钟/NAND 只读事实；U6/U7 已按当前环境更新。 |
| [`kb/isa-notes.md`](kb/isa-notes.md) | **ISA 定版口径** | T1–T8 条目与 `path:line`；ISA 事实优先用 `kb_search`，此页作项目口径索引。 |
| [`kb/tools-and-flow.md`](kb/tools-and-flow.md) | **工具链/环境/流程台账** | Spike 已就绪、Vivado 三坑/统一入口、回归纪律、KB 操作；旧"Spike 缺失/待建"已更新。 |
| [`porting/01-overview.md`](porting/01-overview.md) | **软件栈总纲** | 软件状态与"QEMU 已通 / 真板未验"边界见 §5。 |
| [`../sw/linux/UPSTREAM.md`](../sw/linux/UPSTREAM.md)、[`../sw/opensbi/UPSTREAM.md`](../sw/opensbi/UPSTREAM.md) | **软件基线台账** | 基线版本、构建命令、FW_JUMP 参数；运行期证据来自 QEMU。 |

**2B 当前参数快照（2026-10-18，以 `back2_params.vh` 为准）**：

- 前端 4 取指 / 4 宽重命名与派发 / 4 宽发射；**提交 2 宽**（分配 4 宽，`BACK2_ALLOC_W=4`、`BACK2_COMMIT_W=2`）。
- ROB **64** 项；整数/浮点物理寄存器各 **64**；SQ **32**、LQ **8**；IQ **12/12/6/6/8/6 = 50**。
- PRF 读口 **11/5**（整数/浮点），写口按 N15/N4 合并后的实现；FMA 共享 53-bit 核。
- **store→load 转发已移除（N29B）**；依赖 load 等 older store 排空后访存。
- 锦标赛预测器当前仍为 **Gshare + 局部 + 选择器**；N34B-2 "删除 LOCAL"仅为**送审 patch，未采纳**，RTL 仍例化 `bpu_local_hist`。
- D1/D2/D6/D8 已修（D1 `bd622ee`；D2/D6/D8 `7e2e730`）；D3/D4/D5/D7/D9 仍待确认/裁决。

> ⚠ 现行技术文档不得再把 "4-commit / ROB128 / NREG96" 当作**当前参数**：那是阶段一设计目标或旧评审时点；
> 4 取指/4 发射 + chiplab/xc7a200t 是底线，后端只要求 ≥2 提交/拍（2026-10-04 用户裁决）。
> FU 数量/资源占用/频率可调，但属**事前审批**事项：先报用户审阅，不得先改后报备。

---

## 2. 设计目标（最终目标 vs 当前 2B）

| 文档 | 是什么 | 与当前 2B 的差异（只列关键项） |
|---|---|---|
| [`design/01-overview-datapath.md`](design/01-overview-datapath.md) | 阶段一总体/数据通路目标 | 目标表含 ROB128/4 提交；当前 2B 为 ROB64/2 提交。端口 §5 仍现行。 |
| [`design/02-pipeline.md`](design/02-pipeline.md) | 11 级流水线目标 | 4 取指/4 派发/4 发射仍保留；**提交宽度目标 4→当前 2**。 |
| [`design/03-out-of-order.md`](design/03-out-of-order.md) | 乱序后端目标（ROB/重命名/IQ/LSQ） | 目标 ROB128、NREG96、IQ 16/16/8/8/12/8、LQ32、store→load 转发；当前为 64/64、50、LQ8、转发已移除。 |
| [`design/04-predictor.md`](design/04-predictor.md) | 锦标赛预测器设计 | 三分量当前仍实现；BTB 索引文档自相矛盾，RTL 取 10 bit（1024 组×2 路）；N34B-2 未采纳。 |
| [`design/05-cache-memory.md`](design/05-cache-memory.md) | Cache/存储层次设计 | L1 参数已实现；**L2 未实现**；XIP 旁路、CMO、AXI 边界口径现行。 |
| [`design/06-csr-privilege.md`](design/06-csr-privilege.md) | CSR 与 M/S/U 特权规格 | 规格本身是目标；PMP L 锁定、counteren、TVM 等实现差异未关闭。 |
| [`design/07-verification.md`](design/07-verification.md) | 验证金字塔/环境设计 | 环境"待建"条款已按 2026-10-18 现状更新；2B arch-test 仍未接入。 |
| [`design/08-baseline-5stage.md`](design/08-baseline-5stage.md) | 2A 实施规格 + 2B 归属说明 | 2A 部分已验收；§1.2 的 "2B ROB128" 是原目标，已被 2026-10-04 裁决取代。 |

> 这些文档的**原目标值保留**（历史出处），阅读时按"设计目标 vs 当前 2B"区分；能确认的当前值已在各文档头部或条目旁标注。

---

## 3. 2A 已验收 / 2B 未验收

### 3.1 2A（已验收，但注意时点）

- 2A M1–M5 收官：arch-test 特权/非特权子集全绿（2026-09-17 收口记录；历史追溯见 [`../archive/agent-pre-workflow-2026-10-18.md`](../archive/agent-pre-workflow-2026-10-18.md) 的阶段总结"2A M2 收口"条，现行状态见 [`../NEXT_SESSION.md`](../NEXT_SESSION.md)）；
  2026-09-21 上板 `RESULT: RV32GC-M5-OK`（33 MHz 同域）。
- 入口：[`sim/arch_test/README.md`](../sim/arch_test/README.md)、[`sim/lockstep/README.md`](../sim/lockstep/README.md)、
  [`design/08-baseline-5stage.md`](design/08-baseline-5stage.md)。
- **时点边界**：2A arch-test 全绿是 2026-09-17 的记录；之后 2A/2B 共享的 `trap_ctrl`/`csr_file` 等
  在 D2/D6 修复中改过（2026-10-18），**没有重跑 arch-test/上板** ⇒ 不能把旧"全绿/上板"直接当作
  `7e2e730` 的验收结论。arch-test/上板与 2B 是两件事。

### 3.2 2B（功能仿真有记录，未完成验收）

- 2B 功能仿真既有记录：`tb_core_top_2b` 219/219、`tb_back2_iq` 151/151、
  `tb_back2_lockstep` 57 项/821 提交、`regress.sh` 33/33；这些是**既有记录**，本次文档任务未重跑。
- **未完成**：arch-test 接入 2B（`sim/arch_test/run.sh` 与 `sim/tb/tb_arch_test.sv` 仍例化 2A `core_top`）；
  post-route 时序签署（WNS ≈ −52 ns 深度不收敛）；2B 上板；软件全链在 2B 上跑通。
- 面积：最新综合记录仍是 `d00eb03` 的 **126,699 LUT（94.13%）/ 49,597 FF / WNS ≈ −52 ns**；
  RTL 已到 `7e2e730`（D2/D6/D8 功能修复；D1 在 `bd622ee`），**未重综合**，不得当作最新 RTL 实测。
- 入口：[`design/09-backend-architecture-review.md`](design/09-backend-architecture-review.md)（历史评审）、
  [`design/10-dynamic-behavior.md`](design/10-dynamic-behavior.md)、
  [`design/11-dynamic-behavior-r.md`](design/11-dynamic-behavior-r.md)、
  [`../rtl/front4/README.md`](../rtl/front4/README.md)、
  [`../sim/unit/back2_report.md`](../sim/unit/back2_report.md)。

---

## 4. 历史实验 / 快照（保留原数据，不当现行指令）

| 文档 | 时点/性质 | 读取注意 |
|---|---|---|
| [`design/09-backend-architecture-review.md`](design/09-backend-architecture-review.md) | 2026-10-01 评审快照（`408e5da`，230,998 LUT） | 文中"当前"均指该时点；当前 NREG/commit/面积已变。 |
| [`design/10-dynamic-behavior.md`](design/10-dynamic-behavior.md) | 2026-10-01 动态行为数据（20 基准/49,116 拍） | 数据保留；决策（IQ 6→3 / collector）已被后续实验否决，不是现行方案。 |
| [`design/11-dynamic-behavior-r.md`](design/11-dynamic-behavior-r.md) | 2026-10-04 容量数据（冻结树 `cfc0af9`） | 结论（NREG64 可行、SQ 不可砍等）已用于后续决策；数据本身不重造。 |
| [`../rtl/front4/README.md`](../rtl/front4/README.md) | 2B-1 前端交付说明 | 结构/端口/预测器参数仍多可参考；测试数字是当时记录，当前以 regress/锁步为准。 |
| [`../sim/unit/back2_report.md`](../sim/unit/back2_report.md) | 2B-2 起缺陷台账（B1–B29） | 历史缺陷与修法；其中 ROB128/PRF96 等是当时参数，不是当前参数。 |
| [`../sim/unit/back2_shadow_handoff.md`](../sim/unit/back2_shadow_handoff.md) | 2B-2 并发写者交接快照 | 历史交接；含未采纳的影子树方案，不是现行实现。 |
| [`../fpga/area-optimization-report.md`](../fpga/area-optimization-report.md) | **唯一总结性报告** | 固定四部分；面积数据截止 `d00eb03`，N34B-2 仅送审未采纳；不新建总结 report。 |

**冻结/不维护**（只读，不随当前 RTL 更新，原因：审计/历史证据或已交付快照）：

- `../sim/audit/` 全部审计报告与 `audit3_rtl` 快照——冻结证据，不对应最新 RTL 行号。
- `../fpga/` 历史 T 报告、`fpga/out/` 综合输出——按 tag 命名的历史测量，不伪造新数据。
- `../sw/` 上板旧报告 / 历史运行日志——保留当时结论，不代表当前 2B 或最新软件树。
- `../sim/unit/` 的 `dyn_probe_*` 历史探针——部分已因宏/接口变化不可编译，不属红线命令。

---

## 5. 软件：QEMU vs 真板

| 文档 | 覆盖 | 当前证据边界 |
|---|---|---|
| [`porting/01-overview.md`](porting/01-overview.md) | 软件栈/启动流程/镜像布局/NAND 分区 | 总纲；状态见本表。 |
| [`porting/02-uboot.md`](porting/02-uboot.md) | U-Boot 移植（board/defconfig/DTS/NAND/saveenv/bootcmd） | 构建/QEMU 证据；真板未验。 |
| [`porting/03-linux-opensbi.md`](porting/03-linux-opensbi.md) | Linux S 模式 + SBI + OpenSBI FW_JUMP | QEMU 全链；真板未验。 |
| [`porting/04-nand-driver.md`](porting/04-nand-driver.md) | NAND 芯片/控制器/DMA/MTD/ECC | 明确标注 [QEMU 运行期实测]；真板未验。 |
| [`porting/05-rootfs.md`](porting/05-rootfs.md) | busybox/initramfs → UBIFS | QEMU 冷启/持久化证据；真板未验。 |
| [`../sw/linux/UPSTREAM.md`](../sw/linux/UPSTREAM.md) | Linux 基线与构建口径 | 运行期证据来自 QEMU `-M chiplab`。 |
| [`../sw/opensbi/UPSTREAM.md`](../sw/opensbi/UPSTREAM.md) | OpenSBI 基线与 FW_JUMP | 运行期证据来自 QEMU。 |

**事实边界（2026-10-18）**：

- U-Boot（B-1…B-5/E6–E8）、Linux（L-m1…L-m3）、UBIFS 纯 NAND 冷启、MAC/TFTP 链在
  **QEMU chiplab machine** 上全 PASS；这是软件验证，不是 2B 硬件验收。
- **真板**目前只完成 2A M5 诊断（`RV32GC-M5-OK`）；Linux/UBIFS/MAC 未在真板作为最终判据。
  `axi_mux_sim` 不译码 MAC ⇒ 真板 MAC 仍需实测；U-Boot 段余量仅 6096 B。
- 更细的运行日志/报告在工作区级 `../../docs/linux-port/`、`../../docs/chiplab-qemu/`（只读，不在本索引修改范围）。

---

## 6. 本文维护规则

1. 新增/移动 docs 时更新本页；**不复制** [`../AGENT.md`](../AGENT.md) 的完整模型路由表，只给入口；引用 AGENT 时用**文件链接+规则名称**，不写会随重整变化的章节号。
2. 本页与重点技术文档已改用“文件链接+规则名”；历史正文若仍见旧章节号，按规则名理解，不作为定位依据。
3. 不把历史测量改写成"最新测量"；需要最新数据时重跑并标 tag/日期。
4. 当前参数与设计目标分开写；无法确认的写"未核实"，不机械全局替换 128/4/96 等常量。
5. 修改 `docs/kb/` 后由母 Agent 统一重建知识库索引；子代理不重索引。
