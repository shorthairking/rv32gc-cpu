# rv32gc-cpu — RV32-GC CPU 项目

> 项目入口：本文件只回答“项目是什么、目录在哪、从哪读起”。**当前阶段、最近提交、回归/综合证据与待办只在 [NEXT_SESSION.md](NEXT_SESSION.md) 维护**；工作规则见 [AGENT.md](AGENT.md)，用户用法见 [USAGE.md](USAGE.md)。

## 目标一句话

在 chiplab（龙芯 FPGA 实验箱，`xc7a200tfbg676-2`）上实现 **4 取指 / 4 派发发射、后端 ≥2 提交** 的 RV32-GC 乱序处理器，最终**从 NAND 启动 Linux**（U-Boot + 内核/驱动 + 根文件系统）。硬指标与可调参数见 AGENT §1。

## 现状入口

- 项目已完成 2A 上板验收；2B 目前完成既有功能仿真/回归、**尚未上板**；软件链在 QEMU chiplab 上通过，但**不等于 2B 上板启动**，NAND Linux 总目标未完成。
- 完成度、当前 HEAD、综合/回归数字、审计待办与多仓快照**一律以 [NEXT_SESSION.md](NEXT_SESSION.md) 为准**；本文件不复制这些数字，避免过期。

## 从哪读起

1. **用户**：README（本文件）→ [USAGE.md](USAGE.md)（启动会话、派发示例）。
2. **新母 Agent**：`read` [AGENT.md](AGENT.md) + [NEXT_SESSION.md](NEXT_SESSION.md)，按路径加载，不粘贴/复述全文。
3. **子 Agent**：只 `read` [prompts/common.md](prompts/common.md) + 选定角色文件，按任务块最小参考其他文档。
4. **查技术文档**：先看 [技术文档索引](docs/README.md)，区分现行接口、最终设计目标与历史实验。
5. **查历史**：先看 [archive/](archive/)，不要把旧报告当当前结论。

## 目录地图

```text
rv32gc-cpu/
├── AGENT.md / NEXT_SESSION.md / USAGE.md / README.md   # 规则 / 状态 / 用法 / 入口
├── archive/                                            # 历史快照（非当前指令）
│   ├── agent-pre-workflow-2026-10-18.md
│   └── next-session-pre-workflow-2026-10-18.md
├── prompts/
│   ├── common.md                                       # 子 Agent 共用约束
│   └── subagent-{coding,testing,info,audit}.md         # 四个角色差异
├── docs/
│   ├── design/        01–11：总览/流水/乱序/预测/Cache/CSR/验证/5 级基线/后端评审/动态数据
│   ├── kb/            platform-facts.md、isa-notes.md、tools-and-flow.md
│   └── porting/       01–05：总览、U-Boot、Linux+OpenSBI、NAND、rootfs
├── rtl/               top、front4、fetch、decode、exec、back2、mem、cache、csr、axi、plic、clint、pkg
├── sim/               tb、unit、lockstep、arch_test、audit
├── sw/                boot、m5_board、opensbi、linux；M5-board-runbook.md
├── fpga/              tcl、ip、out、scratch、fpga、soc_up.xdc、run_vivado_batch.sh、阶段报告
└── scripts/           env.sh（环境唯一真源）、regress.sh
```

## 关键真源

| 要查什么 | 真源 |
|---|---|
| 需求、硬指标、模型路由、流程红线 | [AGENT.md](AGENT.md) |
| 当前状态、待办、验证基线、多仓快照 | [NEXT_SESSION.md](NEXT_SESSION.md) |
| 平台事实、ISA 口径、工具链/流 | `docs/kb/platform-facts.md`、`isa-notes.md`、`tools-and-flow.md` |
| 后端实现参数 | `rtl/back2/back2_params.vh` |
| 回归入口 | `scripts/regress.sh`（先 `source scripts/env.sh`） |
| 综合入口 | `fpga/run_vivado_batch.sh` + `fpga/tcl/synth.tcl` |
| 历史材料 | `archive/`；`fpga/*report*`、`sim/audit/*`、`docs/design` 旧章节按原文追溯 |

## 快速开始

1. 读 [USAGE.md](USAGE.md)；
2. 在 dsh 为 `/home/shorthair/dsh/rv32-cpu` 开新会话，首条消息要求母 Agent **按路径 read** `AGENT.md` 与 `NEXT_SESSION.md`（不要粘贴全文）；
3. 母 Agent 给出本轮计划与待确认项后开工；阶段收口会停下等审阅。

## 历史与归档

- 入口文档重整前的全文：[archive/agent-pre-workflow-2026-10-18.md](archive/agent-pre-workflow-2026-10-18.md)、[archive/next-session-pre-workflow-2026-10-18.md](archive/next-session-pre-workflow-2026-10-18.md)。开头均标注“历史快照，非当前指令，仅追溯，旧规则已失效”。
- 上一代实现不得复制其 RTL/脚本/测试/文档实现；分支/tag/远端关系以 NEXT 与 git 为准。
- 历史报告只代表其写作时点，不是当前结论；与当前冲突时以用户最新指令 + NEXT 为准。
