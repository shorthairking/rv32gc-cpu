# USAGE.md — 基于本生成物创建新 Agent 的用法

> 本文件写给**用户**。生成物中的全部规则只约束**新建的母/子 Agent**，对撰写这些文件的会话不生效。

## 1. 生成物清单

| 文件 | 用途 |
|---|---|
| `AGENT.md` | **母 Agent 的总纲与提示词**：任务要求（需求不变）+ 前序精简记忆 + 新规则（母 Agent 只调度、知识盲区路径、WSL-only、禁原语/assign 优先/不造轮子）+ 阶段计划 |
| `prompts/subagent-coding.md` | 编码子 Agent 提示词模板 |
| `prompts/subagent-testing.md` | 测试子 Agent 提示词模板 |
| `prompts/subagent-info.md` | 信息获取子 Agent 提示词模板 |
| `README.md` | 项目与目录说明 |

三个子 Agent 模板都自带通用硬约束（知识盲区解决路径、WSL-only、交付纪律）与本角色专属纪律；母 Agent 调用时**微调只改填空，不改模板条文**（见 `AGENT.md` §5.1）。

## 2. 关键事实：子 Agent 模型路由（本机已就绪，无需安装任何东西）

用户要求"母 Agent 调用子 Agent 时使用 DeepSeek 官方 API 的 ds v4.1 模型"。在本 dsh 环境中该模型的准确路由是：

- `provider: "deepseek-official"` —— dsh 的 DeepSeek 官方 LLM 提供商（api.deepseek.com）
- `model: "deepseek-flash"` —— 即 "ds v4.1"（官方目录 id `deepseek-flash` = DeepSeek-V41-Flash）

本机 `~/.dsh/settings.yaml` 已开启子 Agent 模型选择（`subagent-model-selection: enabled: true`），且 `allowedModels` 中**已包含该路由**。因此：

- **不需要在 WSL 里安装 opencode 本体**；模型由 DeepSeek 官方 API 提供。
- 母 Agent 每次调用 `subagent`/`subagent_fork` 时，在参数里**显式携带 `provider`/`model`/`reasoning_effort`** 即可（`AGENT.md` §0.2 已写死：`provider: "deepseek-official"`、`model: "deepseek-flash"`、`reasoning_effort: "max"`）。

验证方法（新会话里让母 Agent 执行）：

- 调用 `list_subagent_models`（无参数 → 列出可用 provider；`provider=deepseek-official` → 列出该 provider 的模型）。
- 若 `subagent`/`subagent_fork` 工具参数里**没有** `provider`/`model` 字段、且 `list_subagent_models` 也未注册 → 说明宿主未启用 tool-subagent 的模型选择能力，**报告用户**处理（这是环境缺失，按红线不能自行绕过或退化成用母 Agent 模型跑子 Agent）。

## 3. 创建新母 Agent（dsh 会话）

1. 在 dsh 中为工作区 `/home/shorthair/dsh/rv32-cpu` 新建一个会话；
2. 把 `rv32gc-cpu/AGENT.md` 的**全文**作为该会话的首条消息发给它，例如：

   > 以下是你的总纲与硬性纪律，请完整阅读并在此后项目全程严格遵守。先复述你对"母 Agent 只做调度、禁止实质性工作、知识盲区路径、WSL-only、子 Agent 模型路由"的理解，然后停下来等待我的指令。

3. 项目开发目录 = `rv32gc-cpu/`（本仓库 **`dev` 分支**，已就绪）；旧项目历史冻结在 `master` 分支，其实现文件已从磁盘移除，需求口径与教训已浓缩进 `AGENT.md` §1/§3。
4. 母 Agent 每轮开工清单已写在 `AGENT.md` §7/§9：读 AGENT.md → `git status` → `NEXT_SESSION.md`（如有）→ `list_subagent_models` 确认路由。

## 4. 母 Agent 派活示例（dsh 工具调用形态）

```text
subagent(
  description: "实现 rv32_decoder 模块",
  prompt: "<prompts/subagent-coding.md 全文>

【任务目标】按规格实现 rv32_decoder（RV32IMAFDC+Zicsr 译码），输出 uop 控制位与立即数
【涉及文件/范围】只许新建/修改 rtl/decode/rv32_decoder.v、rv32_imm_gen.v 与对应单元 TB；其余文件禁止修改
【验收判据】bash scripts/run_unit_decoder.sh → 输出 DECODER_UNIT_TESTS: PASS；iverilog 编译零告警
【禁止事项】禁止使用原语；禁止自写 AXI 相关逻辑；禁止修改 rtl/pkg/*.vh 之外的定义
【参考】AGENT.md §4 红线；docs/design/spec/02-uop-and-decode.md（如已存在）",
  provider: "deepseek-official",
  model: "deepseek-flash",
  reasoning_effort: "max",
  run_in_background: true
)
```

- 新任务用 `subagent`；需要延续母 Agent 会话上下文的任务用 `subagent_fork`。
- `reasoning_effort` 固定 `"max"`（用户指令 2026-09-14）；官方适配器支持 off/low/high/max 四档；若核实发现不支持 max，报告用户，不得擅自降档。
- 三个子 Agent 的职责/写权限边界见 `AGENT.md` §5：testing 与 info 默认只读；coding 只动指派范围。

## 5. 常见问题

| 问题 | 处置 |
|---|---|
| 子 Agent 工具没有 `provider`/`model` 参数 | 见 §2：先 `list_subagent_models` 核实；仍无 → 报告用户（宿主能力未开启），不得绕过 |
| `list_subagent_models` 列出的 provider 不含 deepseek-official | 报告用户：dsh 提供商配置缺失，由用户配置 |
| 子 Agent 报环境缺失（工具未装/版本不符） | 按红线报告用户，由用户在 WSL 中配置安装 |
| 子 Agent 声称通过 | 母 Agent 必须复跑判定命令后才算验收（AGENT.md §0.6） |
| 母 Agent 想自己写代码 | 违反 AGENT.md §0.1，属于红线；用户可在首条消息中再次强调 |
| 母 Agent 挂 goal 后空转轮询子 Agent（烧 token） | 违反 `AGENT.md` §0.7：纯派发不挂 goal；等结果靠宿主完成通知，禁止 `list_agents`/催促；goal 轮无实质工作就用最短消息结束本轮 |
| 子 Agent 3 次尝试仍失败 | 必须给出"无法解决 + 详细疑惑方向/问题"并上报，禁止编造或无限重试（AGENT.md §0.3） |

## 6. 与旧项目的关系

- 旧项目实现（上一代 Agent 的完整产物，git 历史冻结在 `master` 分支）**已整体废弃**，实现文件已从磁盘移除，未做任何引用或复制；
- 新项目就地在 **`dev` 分支**从零重新实现：需求参数不变（AGENT.md §1），平台口径与教训吸收为"前序精简记忆"（AGENT.md §3），旧代码一律不复制。
