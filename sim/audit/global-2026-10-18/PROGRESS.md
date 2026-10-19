# 全局审计进度台账

> 2026-10-18 恢复：用户要求按小批次继续，避免审计模型 5 小时额度被并发耗尽。保留原模型路由；不降级、不修改产品代码、不提交 Git。

## 基线

- HEAD：`b284df704e4b0984cef8fa8062ada01656eca287`。
- [冻结清单](BASELINE.json)：245 个源码/测试/支持文件；63 个 RTL 文件，33,706 行；正式单元测试 33 个。
- 源文件集合 SHA256：`7cb6b2aeeae1394a3db0575a3040fe71e6c2e20ba6fb22dac889a5924d74aaf4`。
- 本次恢复已逐文件重新计算 SHA256：245/245 与冻结清单一致。此前未提交文档保留，不将文档 Git 树哈希与源码清单哈希混比。

## 批次与落盘状态

| 分域 | 状态 | 报告 |
|---|---|---|
| 01 特权、CSR、中断、PMP、CLINT、PLIC | 已保存并由母 Agent 读取；静态发现，未动态验收 | [01-privilege.md](01-privilege.md) |
| 02 乱序后端 | 第 1 恢复批已保存并由母 Agent 读取；除引用 f0 外仍为静态证据 | [02-backend.md](02-backend.md) |
| 03 LSQ / 2B 顶层 | 第 2 恢复批已保存并由母 Agent 读取；静态证据 | [03-lsq-2b.md](03-lsq-2b.md) |
| 04 存储层次 / MMU / AXI | 第 3 恢复批已保存并由母 Agent 读取；静态证据 | [04-memory-bus.md](04-memory-bus.md) |
| 05 前端 / 译码 | 第 4 恢复批已保存并由母 Agent 读取；部分发现有隔离动态验证 | [05-frontend-decode.md](05-frontend-decode.md) |
| 06 执行单元 | 第 5 恢复批已保存并由母 Agent 读取；参数/接口/测试风险与当前集成错误分层 | [06-execution.md](06-execution.md) |
| 07 测试基础设施 | 第 6 恢复批已保存并由母 Agent 读取；部分共享 TB/配置仍须补查 | [07-test-infrastructure.md](07-test-infrastructure.md) |
| 08 2A 集成 / 综合与仿真一致性 | 第 7 恢复批已保存并由母 Agent 读取；动态/时序验证边界保留 | [08-integration-synthesis.md](08-integration-synthesis.md) |
| 09 共享仿真平台 / 正式 TB 补段 | 第 8 小批完成 4,745 行指定逻辑；已补齐报告中明确的活动 TB 阅读缺口 | [09-verification-followup.md](09-verification-followup.md) |
| 10 活动配置 / 程序源 | 第 9 小批完成 39 文件、4,565 行；PLIC 宏地址已由母 Agent 对照现役译码补证 | [10-program-config.md](10-program-config.md) |
| 11 板级诊断 / 镜像与辅助验证 | 第 10 小批完成 24 文件、7,166 行；母 Agent 已读取报告 | [11-board-support.md](11-board-support.md) |
| 全局汇总 / 覆盖清单 | 已完成编写、独立复核和母机器验收；汇总登记两项 P2 已修正关闭，产品缺陷未修 | [REPORT.md](REPORT.md)、[COVERAGE.md](COVERAGE.md)、[COVERAGE.tsv](COVERAGE.tsv)、[关闭复核](SUMMARY_REVIEW.md) |

## 已保存验证

- [译码与 f0 验证](validation/decode-fp0/results.md)：子 Agent 已报告 24 例，含 12 个缺陷复现例和 12 个反向控制例；这不是 DUT 合规通过。
- 母 Agent 静态验收发现新增夹具未拒绝空清单/缺例、参考计算未校验退出码、反证副本版本漂移，均已交原作者在隔离目录修正。母 Agent 已亲自复跑并独立核计：24/24（12 个 `DEFECT_REPRODUCED`、12 个 `CONTROL_OK`）、夹具反证 5/5；记录见 [母复跑日志](validation/decode-fp0/mother-validation.log) 与 [反证复跑日志](validation/decode-fp0/mother-negative.log)。这些数字只证明预期缺陷与控制行为被观察到，不是 DUT 合规通过。
- [权限与内存边界验证](validation/privilege-memory/results.md)已由母 Agent 亲自复跑：11/11（5 个缺陷复现、6 个控制）、夹具反证 4/4；见[母复跑日志](validation/privilege-memory/mother-validation.log)与[反证复跑日志](validation/privilege-memory/mother-negative.log)。证实后端接受 U/S 机器 CSR 和 U 的 MRET、CLINT 相等时不挂起、受控提交窗口下 LSQ 跨 ROB 环绕不释放；分别为后端模块级、CLINT 模块级、LSQ 状态转移级，不声称整核提权或整核回绕程序已复现。
- 两批合计：35 个固定用例，其中 17 个缺陷复现、18 个控制；9 个夹具反证。此计数不是 17 个独立根因，也不是原正式回归/arch-test 的通过数。
- `f0` 用例从后端派发口注入，观测真实 PRF 写口和提交；不是整核取指级验证。

## 续办纪律

1. 同时最多恢复一个 GPT 审计分域；独立的 DeepSeek 测试夹具小修不占该审计路由额度。
2. 每个分域先保存已有发现和覆盖边界，再做必要补查；未验证、撤回和已知未修分开写。
3. 11 份分域/补审报告现已全部保存；母 Agent 核对其 578 个本地链接可达、代码围栏配对。01 报告只修正了相对引用路径，审计结论未改。
4. 冻结清单 245 个文件仍全部 SHA-256 一致；额外审阅的 [run_vivado_batch.sh](../../../fpga/run_vivado_batch.sh)、[soc_up.xdc](../../../fpga/soc_up.xdc) 也已逐字节对照冻结 HEAD 一致，但不虚称它们包含在原集合摘要中。
5. 全局审计任务已完成：247 条 TSV 无重复/缺漏，63 个 RTL（33,706 行）及 33 个正式 TB 表集合匹配，证据归属一致；母日志复核 35=17+18，另 9 个夹具反证。主报告/覆盖表的初稿登记错误经独立复核、作者修正和母机器验收关闭。
6. **审计完成不等于产品通过**：报告结论仍为不满足功能放行条件；未修 RTL/原测试，未跑原全量回归、arch-test、锁步、Vivado 或上板，未提交 Git。后续修复是等待用户指令的另一项任务。
