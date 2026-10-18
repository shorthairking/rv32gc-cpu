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

用户裁决口径（**2026-10-18 最新**）：**DeepSeek 官方路由、档位 `high`**（旧 opencode-go 两路由 `deepseek-v4.1-flash` 口径、xhigh 口径全部作废）。在本 dsh 环境中该模型的准确路由是：

- `provider: "deepseek-official"` —— DeepSeek 官方路由（**精确 provider 名以新会话 `list_subagent_models` 实查为准**）
- `model: "deepseek-flash"` —— 官方模型 id（**旧记录里的 `ds-flash` 是无效 id**：2026-10-18 实测官方接口只接受 `deepseek-flash` / `deepseek-v4-pro`，传 `ds-flash` 返回 400 `invalid_request_error`）
- `reasoning_effort: "high"` —— 思考强度 high 档

**宿主开通状态（2026-10-18 已修复）**：原先 `allowedModels` 只有 `opencode-go` / `opencode-go-chat` / `openai-codex`，`deepseek-official` 报 "not allowed for this Session"；现已在该文件中加入 `{provider: deepseek-official, model: deepseek-flash}`。**路由是会话首次组装时快照 ⇒ 改完必须新开会话**；新会话里先复验再派活。旧路由仍留在 `allowedModels`（未强制移除），但按 `AGENT.md` §0.2 口径一律不用于派活。

**配置落在哪里（2026-10-01 起，重要）**：新版 dsh **已移除 `~/.dsh/settings.yaml`**，设置统一写进 profile patch `~/.dsh/profiles/web/cordis.patch.yml`。本机已在该文件的 `subagent-model-selection-settings` entry 里写入 `enabled: true` 与 `allowedModels`（含 `deepseek-official/deepseek-flash`）。因此：

- **不需要在 WSL 里安装 opencode 本体**；模型路由由宿主 dsh 配置提供。
- 母 Agent 每次调用 `subagent` 时，在参数里**显式携带 `provider`/`model`/`reasoning_effort`**（`AGENT.md` §0.2：`provider: "deepseek-official"`、`model: "deepseek-flash"`、`reasoning_effort: "high"`）。
- **`subagent_fork` 不带这三个字段是设计如此**（standard preset 未开 `modelSelectionSettings`，以保持与父 Agent 同路由、复用 KV cache）；只有 `subagent`（spawn）会暴露它们。
- **改配置后必须新开会话**：子 Agent 模型选择是会话首次组装时快照，已存在的会话不会重算。

验证方法（新会话里让母 Agent 执行）：

- 调用 `list_subagent_models`（无参数 → 列出可用 provider；`provider=deepseek-official` → 列出该 provider 的模型与档位，应见 `deepseek-flash`）。
- 若 `list_subagent_models` 未列出 `deepseek-official`（或对其查询报 not allowed）→ 说明宿主还未放行该路由，**报告用户**在 `cordis.patch.yml` 的 `allowedModels` 确认后新开会话（这是环境缺失，按红线不能自行绕过或退化成用母 Agent 模型跑子 Agent）。

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
  reasoning_effort: "high",
  run_in_background: true
)
```

- 新任务用 `subagent`；需要延续母 Agent 会话上下文的任务用 `subagent_fork`（**fork 无路由字段，路由随父 Agent——设计如此**）。
- `reasoning_effort` 固定 `"high"`（用户 2026-10-18 裁决）；`provider: "deepseek-official"` / `model: "deepseek-flash"`（宿主已放行，见 §2；**新会话才生效**）。
- 三个子 Agent 的职责/写权限边界见 `AGENT.md` §5：testing 与 info 默认只读；coding 只动指派范围。

## 5. 常见问题

| 问题 | 处置 |
|---|---|
| 子 Agent 工具没有 `provider`/`model` 参数 | 见 §2：先 `list_subagent_models` 核实；仍无 → 报告用户（宿主能力未开启），不得绕过。注意 **`subagent_fork` 本来就没有，属设计如此** |
| `list_subagent_models` 列出的 provider 不含 `deepseek-official`（或查询报 not allowed） | 确认处于**新开会话**（路由是首组装快照）；仍缺 → 报告用户核查 `~/.dsh/profiles/web/cordis.patch.yml` 的 `allowedModels` |
| 子 Agent 报模型不存在（400 `invalid_request_error`） | 检查 `model` 是否写成 `ds-flash` —— 有效 id 只有 `deepseek-flash` / `deepseek-v4-pro`（§2） |
| 子 Agent 报环境缺失（工具未装/版本不符） | 按红线报告用户，由用户在 WSL 中配置安装 |
| 子 Agent 声称通过 | 母 Agent 必须复跑判定命令后才算验收（AGENT.md §0.6） |
| 母 Agent 想自己写代码 | 违反 AGENT.md §0.1，属于红线；用户可在首条消息中再次强调 |
| 母 Agent 挂 goal 后空转轮询子 Agent（烧 token） | 违反 `AGENT.md` §0.7（2026-09-17 收紧）：母 Agent 未在自己 session 运行实质性任务（bash 验证/文件读写）时**禁止** create_goal/update_goal resume；派发子 Agent 后结束回合等宿主完成通知，禁止 `list_agents`/催促 |
| 子 Agent 3 次尝试仍失败 | 必须给出"无法解决 + 详细疑惑方向/问题"并上报，禁止编造或无限重试（AGENT.md §0.3） |

## 6. 与旧项目的关系

- 旧项目实现（上一代 Agent 的完整产物，git 历史冻结在 `master` 分支）**已整体废弃**，实现文件已从磁盘移除，未做任何引用或复制；
- 新项目就地在 **`dev` 分支**从零重新实现：需求参数不变（AGENT.md §1），平台口径与教训吸收为"前序精简记忆"（AGENT.md §3），旧代码一律不复制。
