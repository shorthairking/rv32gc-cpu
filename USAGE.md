# USAGE.md — 使用说明（给用户）

> 本文件写给用户；规则只约束新建的母/子 Agent。本文件不是状态来源：当前阶段、证据、待办只看 [NEXT_SESSION.md](NEXT_SESSION.md)。
> 入口关系：README（是什么/目录）→ USAGE（怎么用）→ AGENT（规则）→ NEXT（现在做什么）。

## 1. 入口清单

| 文件 | 用途 |
|---|---|
| [AGENT.md](AGENT.md) | 稳定工作契约：角色、唯一模型路由表、已裁决硬指标、流程与红线 |
| [NEXT_SESSION.md](NEXT_SESSION.md) | 唯一当前状态、待办、验证基线与多仓快照 |
| [README.md](README.md) | 项目入口与真实目录地图 |
| [prompts/common.md](prompts/common.md) | 子 Agent 共用约束（所有角色必读） |
| [prompts/subagent-coding.md](prompts/subagent-coding.md) | coding 角色差异（RTL/TB/脚本/文档正文） |
| [prompts/subagent-testing.md](prompts/subagent-testing.md) | testing 角色差异（测试/回归/锁步/定位） |
| [prompts/subagent-info.md](prompts/subagent-info.md) | info 角色差异（只读检索、带引用） |
| [prompts/subagent-audit.md](prompts/subagent-audit.md) | audit 角色差异（独立只读审计、不代修） |
| [archive/](archive/) | 历史快照：开头均标“历史快照，非当前指令，仅追溯，旧规则已失效” |

## 2. 启动一个会话

1. 在 dsh 中为工作区 `/home/shorthair/dsh/rv32-cpu` 新建会话；
2. 首条消息**按路径加载**，不要粘贴全文：

   ```text
   请先 read /home/shorthair/dsh/rv32-cpu/rv32gc-cpu/AGENT.md 与
   /home/shorthair/dsh/rv32-cpu/rv32gc-cpu/NEXT_SESSION.md，按契约开工；
   不要粘贴或复述全文，先给本轮计划、拟改文件和待确认项。
   ```

3. 母 Agent 读 AGENT + NEXT；只有在怀疑路由/档位时才跑一次 `list_subagent_models`，不必每次重查；
4. 每个阶段目标或计划完成后，母 Agent 直接在对话中给出简报：完成内容、验证及未做项、遗留风险、下一步；不为简报新建文件或自动改写报告。正式阶段按授权处理 git 提交并停下等审阅；不要自动进下一阶段。

## 3. 派发子 Agent（现行契约）

- **路由只认 [AGENT.md §2](AGENT.md) 的唯一表**：coding / testing / info 用 `openai-codex` / `gpt-6-luna` / `high`；audit 用 `openai-codex` / `gpt-6.1-sol` / `low`。本文件不另立第二张表，也不得静默替代；路由变更时从该表派生，并同步角色模板与本文件示例。
- **prompt 只要求路径加载**：子 Agent 实际 `read prompts/common.md` + 选定角色文件；同一子 Agent 后续消息若已完整读过且确认文件未变，可复用不重读；文件变更只补读受影响文件。**不要粘贴模板正文**，也不要要求子 Agent 总重读 AGENT/NEXT。
- **角色标签可见**：选定角色模板第一行的 `[xxx子agent]` 同时放在任务 `description` 和派发 prompt 首行；子 Agent 首次响应、关键进度、最终交付也保留该前缀。标签从角色模板读取，不用另抄一张映射表；已有任务的旧显示名不会因改模板自动变更。
- 标签与路径加载指令之后，任务块只附 **【目标】【范围】【验收】**，可选 **【约束】【参考】**。【范围】必须写可写白名单和产物/日志目录，未列默认只读。
- `subagent` 调用**没有 `run_in_background` 参数**：调用本身立即返回 id、在后台运行。等宿主完成通知，**不要轮询、不要催促**。
- `subagent_fork` **没有 `provider`/`model`/`reasoning_effort` 字段**（设计如此），不能用于本项目要求精确模型的任务；延续同一子 Agent 用 `send_message`。
- audit 默认只读、不代修；执行测试或把报告落盘必须在【范围】明确授权。
- 每次子 Agent 任务回报后按 [AGENT.md §2](AGENT.md#2-子-agent-模型路由唯一表) 执行额度护栏；插件命令为 `/codex-quota` / `/codex-quota fresh`。查询通道未就绪时不得宣称自动检查可用，停止新派发；当前就绪/暂停状态只看 [NEXT_SESSION.md](NEXT_SESSION.md)。

## 4. 调用例（真实工具 schema）

> 示例任务按实际待办替换；路由值照抄 AGENT §2，不要自造 provider/model。

### 4.1 coding

```text
subagent(
  description: "[编码子agent] 修复 D3 PMP L 位锁定",
  prompt: "[编码子agent]
先实际 read prompts/common.md 与 prompts/subagent-coding.md。

【目标】按审计项 D3 修正 pmpcfg.L=1 时 pmpaddr 仍可写的路径，并补定向用例。
【范围】可写：rtl/csr/csr_file.v、sim/unit/d3_pmp_lock_tb.sv；产物目录：/tmp/d3_pmp/；其他只读。
【验收】bash 运行定向 TB 输出 D3_PMP_LOCK: PASS；并给出修复前同等命令 FAIL 的反证输出。
【约束】不改 PMP 粒度 G=0 裁决；不跑全量回归。
【参考】sim/audit/audit2_report.md D3 条目。",
  provider: "openai-codex",
  model: "gpt-6-luna",
  reasoning_effort: "high",
  cwd: "/home/shorthair/dsh/rv32-cpu/rv32gc-cpu"
)
```

### 4.2 audit（独立复核，不代修）

```text
subagent(
  description: "[审计子agent] 独立审计 D3 修复",
  prompt: "[审计子agent]
先实际 read prompts/common.md 与 prompts/subagent-audit.md。

【目标】独立审查 D3 修复的正确性、边界与测试盲区。
【范围】只读：本次 diff 涉及文件、对应 TB 与 baseline；报告只在回复中，不落盘；其他只读。
【验收】按 P0/P1/P2 给问题（文件:行号 + 触发条件 + 影响 + 最小验证建议）；无问题也要说明未覆盖项。
【参考】baseline=<修复前 commit>；diff=<修复 commit 或 git diff 范围>。",
  provider: "openai-codex",
  model: "gpt-6.1-sol",
  reasoning_effort: "low",
  cwd: "/home/shorthair/dsh/rv32-cpu/rv32gc-cpu"
)
```

### 4.3 testing / info

- testing：同 `subagent` 三字段（`openai-codex` / `gpt-6-luna` / `high`），角色文件换 `prompts/subagent-testing.md`，description/prompt/响应用其首行 `[测试子agent]`；默认产品只读，TB/日志只写【范围】列出的目录。
- info：同 `subagent` 三字段，角色文件换 `prompts/subagent-info.md`，description/prompt/响应用其首行 `[信息子agent]`；纯只读，结论必须带 `文件:行号` 或 URL。

### 4.4 延续同一子 Agent

```text
send_message(agent_id="<上一步返回的 id>", message="<补充要求/复审结论>")
```

只有原实例路由仍符合当前表时才这样延续；改模板或 `send_message` 不会把旧实例迁移到新 provider/model。路由不符时按当前三字段新建对应角色，不复用旧路由执行新任务。不要为了“保持模型”再开 `subagent_fork`；fork 只适合不要求精确模型、需要继承上下文的场景。

## 5. 常见问题

| 现象 | 处置 |
|---|---|
| `subagent` 参数里没有 `provider`/`model` | 停止并报告用户；不得退化成母 Agent 自身模型。`subagent_fork` 没有这些字段属正常设计 |
| 路由报不允许/模型不存在 | 先按 AGENT §2 核对；必要时用 `list_subagent_models` 查一次。仍不可用就报告用户，**不得静默替代** |
| 子 Agent 没按要求读模板 | 重派时明确写“先实际 read common + 角色文件”；不要改回粘贴模板全文 |
| 子 Agent 声称通过 | 母 Agent 必须复跑关键判据后才算验收；audit 也不能替代测试验收 |
| 文档-only 改动 | 只做文档一致性检查（链接/口径/日期/路由表唯一），不无谓跑 CPU 回归；未跑就写“未运行” |
| 主 Agent 使用 goal | **硬性禁止任何情况下创建、恢复或维持 goal**，不得借子 Agent 代挂；只用 task/todo 清单（当前工具 `todo_write`），等子 Agent 靠完成通知，不轮询 |
| 旧项目/master 关系 | 不要断言 `master`=旧项目冻结；旧一代实现不得复制，分支事实以 NEXT 与 git 为准 |

## 6. 维护规则

- **AGENT** 只放稳定规则、唯一路由表和已裁决硬指标；**NEXT** 只放当前状态/待办/验证基线；**USAGE** 面向用户；**README** 只做入口与目录地图。
- 状态数字、最近提交、综合/回归证据只写 NEXT；路由表只写 AGENT；SPI/DDR/33 MHz 等平台原文只放 `docs/kb/` 与 `docs/porting/`，四入口只给指针。
- 历史内容进 `archive/` 并标注“历史快照，非当前指令”；用户最新指令优先于仓库旧条款，冲突时先按用户指令再更新文档。
