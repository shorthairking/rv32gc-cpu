# rv32gc-cpu — RV32-GC CPU 项目（重启版）

本仓库的 **`dev` 分支**是"RV32-GC CPU 及其配套软硬件"项目的**重启版**。上一代实现（git 历史冻结在 `master` 分支）已验证为低质量，**整体弃用**：其代码、脚本、测试一律不复制，只保留"需求口径 + 经验教训"作为参考（已浓缩进 `AGENT.md` §1/§3）。本分支只存放**新项目启动所需的 Agent 生成物**；新的设计与代码将由新母 Agent 从零开始产出。

## 目标（一句话）

在 chiplab（龙芯 FPGA 实验箱，`xc7a200tfbg676-2`）上实现一颗 **4 发射乱序 RV32-GC 处理器**，并完成 **OpenSBI + U-Boot + Linux + 根文件系统** 移植，最终**从 NAND 自动启动 Linux**。（需求与参数与原任务一致，见 `AGENT.md` §1。）

## 目录内容

```
rv32gc-cpu/（dev 分支）
├── AGENT.md                    # 母 Agent 总纲与提示词（任务要求 + 前序精简记忆 + 新规则 + 阶段计划）
├── USAGE.md                    # 基于本生成物创建新 Agent 的用法（给用户）
├── README.md                   # 本文件
└── prompts/
    ├── subagent-coding.md      # 编码子 Agent 提示词模板（禁原语 / assign 优先 / AXI 用 IP）
    ├── subagent-testing.md     # 测试子 Agent 提示词模板（未捕获即失败 / 正反证 / 只读）
    └── subagent-info.md        # 信息获取子 Agent 提示词模板（只读 / 结论带引用）
```

后续阶段的新产物将按旧项目的目录约定重新建立：`docs/`（design/porting/kb）、`rtl/`、`sim/`、`sw/`、`fpga/`、`scripts/`。

## 本版新增规则

1. **母 Agent 只做调度**：禁止任何实质性工作，所有实质性工作派子 Agent；只负责拆分任务、给精确提示词、汇总证据、台账与 git。
2. **知识盲区解决路径**（母与子通用）：① 查知识库（kb / AGENT.md）→ ② 联网搜索 → ③ 自行尝试 ≤3 次 → ④ 仍失败则明确上报"无法解决 + 详细疑惑方向或问题"。
3. **WSL-only**：禁止修改或调用任何 Windows 环境下的命令或文件；环境缺失报告用户，由用户配置安装。
4. **子 Agent 模型**：母 Agent 用 dsh 的 `subagent`/`subagent_fork` 调用子 Agent，显式指定 `provider: "deepseek-official"`、`model: "deepseek-flash"`（DeepSeek 官方 API 的 ds v4.1）、`reasoning_effort: "max"`（2026-09-14 用户指令）。
5. **编码红线**：禁止使用原语（先检索 Vivado IP）；大量组合逻辑用 `assign`；避免重复造轮子（尤其 AXI，用 Vivado 成熟 IP/wrapper）。
6. **goal 纪律**：goal 仅母 Agent 多轮实质调度时使用；纯派发子 Agent 的工作不挂 goal、不轮询，子 Agent 完成时宿主自动通知；子 Agent 一次运行自驱做完（宿主 goal 工具禁止子 Agent 创建）。

## 快速开始

1. 读 `USAGE.md`（创建新 Agent 的完整步骤）；
2. 在 dsh 中为 `/home/shorthair/dsh/rv32-cpu` 开新会话，把 `AGENT.md` 全文作为首条消息交给新母 Agent；
3. 等待新母 Agent 复述规则并停下，审阅 `AGENT.md` §1 需求与 §6 阶段计划后发出"开始阶段一"指令。
