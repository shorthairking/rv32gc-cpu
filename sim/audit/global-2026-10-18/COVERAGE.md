# 全局审计覆盖清单（冻结 b284df7）

> 配套 [REPORT.md](REPORT.md) 与 [COVERAGE.tsv](COVERAGE.tsv)。本清单只登记**实际阅读深度与证据来源**，不把“出现在 BASELINE”或“文件名像测试”推断为已读，也不把行数当功能覆盖率。`BASELINE.json` 冻结 245 个文件；另有 2 个不在 245 清单内的支持文件仅按 HEAD blob 只读核对。TSV 共 **247** 条 = 245 + 2。

## 1. 口径

- **全文**：报告声明读至文件末行（含分段续读）；**联合全文**：同一文件由两份报告的分段合起来覆盖到末行。
- **部分**：只读报告明确列出的行段；**抽查/检索**：只读接口、关键判定或关键词命中；**未逐行**：仅按清单/命名/引用关系分类登记。
- **主责报告**指实际给出该文件结论或覆盖声明的分域报告；“—”表示该文件只在基线清单/目录结构中出现，本次没有独立深读证据。
- 63 个 RTL、33 个正式 TB、09/10/11 补批的行数闭合见下；所有“完整读取”均不等于功能正确或仿真通过。

## 2. 63 个 RTL 文件：读取深度与主责报告

| 文件 | 行 | 实际深度 | 主责报告 | 边界/备注 |
|---|---:|---|---|---|
| [rtl/axi/axi_master_ctrl.v](../../../rtl/axi/axi_master_ctrl.v) | 508 | 全文 1–508 | [04](04-memory-bus.md) | split/错误路径静态；未动态 |
| [rtl/axi/axi_req_desc.v](../../../rtl/axi/axi_req_desc.v) | 193 | 全文 1–193 | [04](04-memory-bus.md) | 描述符字段静态 |
| [rtl/back2/b2_csr.v](../../../rtl/back2/b2_csr.v) | 177 | 全文 1–177 | [02](02-backend.md) | 后端直驱测试桩，非现役 core CSR |
| [rtl/back2/back2_params.vh](../../../rtl/back2/back2_params.vh) | 627 | 全文 1–627 | [02](02-backend.md) | 参数一致性静态 |
| [rtl/back2/backend_top.v](../../../rtl/back2/backend_top.v) | 2818 | 全文 1–2818 | [02](02-backend.md) | 01/03 接口段另读；无动态整核 |
| [rtl/back2/iq.v](../../../rtl/back2/iq.v) | 516 | 全文 1–516 | [02](02-backend.md) | ROB64 窗口/4 路写入的 IQ 集成未做动态反证 |
| [rtl/back2/lsq_simple.v](../../../rtl/back2/lsq_simple.v) | 1524 | 全文 1–1524（分三段） | [03](03-lsq-2b.md) | 动态仅 LQ 释放状态转移 |
| [rtl/back2/prf.v](../../../rtl/back2/prf.v) | 99 | 全文 1–99 | [02](02-backend.md) | deferred 并发/冲刷未测 |
| [rtl/back2/rename.v](../../../rtl/back2/rename.v) | 1029 | 全文 1–1029 | [02](02-backend.md) | 回滚/快照问题静态 |
| [rtl/back2/rob.v](../../../rtl/back2/rob.v) | 918 | 全文 1–918 | [02](02-backend.md) | 精确异常未全覆盖 |
| [rtl/back2/rob_wide_mem.v](../../../rtl/back2/rob_wide_mem.v) | 162 | 全文 1–162 | [02](02-backend.md)；[08](08-integration-synthesis.md) | read_first 已修，不重报 |
| [rtl/cache/cache_array_bram.v](../../../rtl/cache/cache_array_bram.v) | 179 | 全文 1–179 | [04](04-memory-bus.md)；[08](08-integration-synthesis.md) | IP 参数/字节写静态 |
| [rtl/cache/cache_tag_array.v](../../../rtl/cache/cache_tag_array.v) | 190 | 全文 1–190 | [04](04-memory-bus.md) | tag/替换静态 |
| [rtl/cache/l1d.v](../../../rtl/cache/l1d.v) | 697 | 全文 1–697 | [04](04-memory-bus.md) | 写回/错误路径静态 |
| [rtl/cache/l1i.v](../../../rtl/cache/l1i.v) | 351 | 全文 1–351 | [04](04-memory-bus.md) | refill 错误路径静态 |
| [rtl/cache/mshr_simple.v](../../../rtl/cache/mshr_simple.v) | 140 | 全文 1–140 | [04](04-memory-bus.md) | MSHR 契约静态 |
| [rtl/clint/clint.v](../../../rtl/clint/clint.v) | 164 | 全文 1–164 | [01](01-privilege.md) | 动态仅 MTIP 相等边界（模块级） |
| [rtl/csr/csr_file.v](../../../rtl/csr/csr_file.v) | 1127 | 全文 1–1127 | [01](01-privilege.md) | PMP 自锁/TVM/time 等静态 |
| [rtl/csr/priv_ctrl.v](../../../rtl/csr/priv_ctrl.v) | 259 | 全文 1–259 | [01](01-privilege.md) | 旁路/特权静态 |
| [rtl/csr/ptw.v](../../../rtl/csr/ptw.v) | 595 | 全文 1–595 | [04](04-memory-bus.md) | D/PA 高位静态 |
| [rtl/csr/tlb.v](../../../rtl/csr/tlb.v) | 449 | 全文 1–449 | [04](04-memory-bus.md) | D/SFENCE 静态 |
| [rtl/csr/trap_ctrl.v](../../../rtl/csr/trap_ctrl.v) | 328 | 全文 1–328 | [01](01-privilege.md) | 委托/EPC 静态 |
| [rtl/decode/compressed_expand.v](../../../rtl/decode/compressed_expand.v) | 469 | 全文 1–469 | [05](05-frontend-decode.md) | 动态 5 例（C MISC-ALU/EBREAK） |
| [rtl/decode/dec_csr.v](../../../rtl/decode/dec_csr.v) | 243 | 全文 1–243 | [01](01-privilege.md) | 05 未审内部 |
| [rtl/decode/dec_imm.v](../../../rtl/decode/dec_imm.v) | 250 | 全文 1–250 | [05](05-frontend-decode.md) | 立即数静态 |
| [rtl/decode/decoder.v](../../../rtl/decode/decoder.v) | 799 | 全文 1–799 | [05](05-frontend-decode.md) | 01 仅 700–799；动态 5 例 FP |
| [rtl/exec/alu.v](../../../rtl/exec/alu.v) | 143 | 全文 1–143 | [06](06-execution.md) | 局部算术静态 |
| [rtl/exec/bru.v](../../../rtl/exec/bru.v) | 144 | 全文 1–144 | [06](06-execution.md) | 局部比较/目标静态 |
| [rtl/exec/exe_ctrl.v](../../../rtl/exec/exe_ctrl.v) | 167 | 全文 1–167 | [06](06-execution.md) | 旁路优先级静态 |
| [rtl/exec/fpu.v](../../../rtl/exec/fpu.v) | 572 | 全文 1–572 | [06](06-execution.md) | SC→DS 仅接口风险 |
| [rtl/exec/fpu_add.v](../../../rtl/exec/fpu_add.v) | 1697 | **部分**：214–860、1491–1590 | [06](06-execution.md) | 当前活跃 delay/round/align helper 全读；保留 add/FMA 金标主体未读 |
| [rtl/exec/fpu_cmp.v](../../../rtl/exec/fpu_cmp.v) | 275 | 全文 1–275 | [06](06-execution.md) | NaN/分类静态 |
| [rtl/exec/fpu_cvt.v](../../../rtl/exec/fpu_cvt.v) | 595 | 全文 1–595 | [06](06-execution.md) | 转换范围静态 |
| [rtl/exec/fpu_div_sqrt.v](../../../rtl/exec/fpu_div_sqrt.v) | 597 | 全文 1–597 | [06](06-execution.md) | 拍数参数问题静态 |
| [rtl/exec/fpu_fma_shared.v](../../../rtl/exec/fpu_fma_shared.v) | 625 | 全文 1–625 | [06](06-execution.md) | 共享 round/对阶静态 |
| [rtl/exec/fpu_mul.v](../../../rtl/exec/fpu_mul.v) | 258 | 全文 1–258 | [06](06-execution.md) | 保留金标，非当前 FMUL 路径 |
| [rtl/exec/fregfile.v](../../../rtl/exec/fregfile.v) | 86 | 全文 1–86 | [06](06-execution.md) | f0 可写；后端 f0 归 02 |
| [rtl/exec/mdu.v](../../../rtl/exec/mdu.v) | 644 | 全文 1–644 | [06](06-execution.md)；[08](08-integration-synthesis.md)；[11](11-board-support.md) | 商余已修；行为模型非 Vivado IP；历史副本已比对 |
| [rtl/fetch/fetch_unit.v](../../../rtl/fetch/fetch_unit.v) | 489 | 全文 1–489 | [05](05-frontend-decode.md) | 高半起始为历史模块局限，不报当前四宽停摆 |
| [rtl/fetch/parcel_align.v](../../../rtl/fetch/parcel_align.v) | 113 | 全文 1–113 | [05](05-frontend-decode.md) | carry 契约静态 |
| [rtl/fetch/pc_gen.v](../../../rtl/fetch/pc_gen.v) | 180 | 全文 1–180 | [05](05-frontend-decode.md) | 优先级静态 |
| [rtl/front4/bpu_btb.v](../../../rtl/front4/bpu_btb.v) | 213 | 全文 1–213 | [05](05-frontend-decode.md)；[08](08-integration-synthesis.md) | tag/替换静态 |
| [rtl/front4/bpu_gshare.v](../../../rtl/front4/bpu_gshare.v) | 191 | 全文 1–191 | [05](05-frontend-decode.md) | GHR 静态 |
| [rtl/front4/bpu_local_hist.v](../../../rtl/front4/bpu_local_hist.v) | 205 | 全文 1–205 | [05](05-frontend-decode.md) | LHT/LPHT 静态 |
| [rtl/front4/bpu_ras.v](../../../rtl/front4/bpu_ras.v) | 174 | 全文 1–174 | [05](05-frontend-decode.md) | 仅恢复深度，内容回滚未测 |
| [rtl/front4/bpu_selector.v](../../../rtl/front4/bpu_selector.v) | 158 | 全文 1–158 | [05](05-frontend-decode.md) | 四转移静态 |
| [rtl/front4/front4_mem.v](../../../rtl/front4/front4_mem.v) | 289 | 全文 1–289 | [05](05-frontend-decode.md)；[08](08-integration-synthesis.md) | wrapper 与 IP 行为差异（接口） |
| [rtl/front4/front4_params.vh](../../../rtl/front4/front4_params.vh) | 127 | 全文 1–127 | [05](05-frontend-decode.md) | 32 parcel/索引静态 |
| [rtl/front4/front4_table_2lu_1upd.v](../../../rtl/front4/front4_table_2lu_1upd.v) | 87 | 全文 1–87 | [05](05-frontend-decode.md)；[08](08-integration-synthesis.md) | 镜像写/训练读静态 |
| [rtl/front4/front4_top.v](../../../rtl/front4/front4_top.v) | 361 | 全文 1–361 | [05](05-frontend-decode.md) | repair 消费方静态 |
| [rtl/front4/ifetch4.v](../../../rtl/front4/ifetch4.v) | 900 | 全文 1–900 | [05](05-frontend-decode.md) | fault/checkpoint/F2/反压静态 |
| [rtl/front4/pc_gen4.v](../../../rtl/front4/pc_gen4.v) | 134 | 全文 1–134 | [05](05-frontend-decode.md) | restart/epoch 静态 |
| [rtl/front4/predictor_top.v](../../../rtl/front4/predictor_top.v) | 564 | 全文 1–564 | [05](05-frontend-decode.md) | FIFO/checkpoint 静态 |
| [rtl/mem/amo_unit.v](../../../rtl/mem/amo_unit.v) | 233 | 全文 1–233 | [04](04-memory-bus.md) | 原子性/取消未动态 |
| [rtl/mem/cmo_unit.v](../../../rtl/mem/cmo_unit.v) | 128 | 全文 1–128 | [04](04-memory-bus.md) | CBO kind/地址语义静态 |
| [rtl/mem/lsu.v](../../../rtl/mem/lsu.v) | 572 | 全文 1–572 | [04](04-memory-bus.md) | CBM 权限静态 |
| [rtl/mem/mmio_route.v](../../../rtl/mem/mmio_route.v) | 174 | 全文 1–174 | [01](01-privilege.md)；[04](04-memory-bus.md) | 窗口截获静态，最终 top 门控未读全 |
| [rtl/mem/pmp_check.v](../../../rtl/mem/pmp_check.v) | 476 | 全文 1–476 | [01](01-privilege.md) | 04 仅检索权限段 |
| [rtl/pkg/core_params.vh](../../../rtl/pkg/core_params.vh) | 260 | 全文 1–260 | [08](08-integration-synthesis.md) | 地址/几何/ISA 声明静态 |
| [rtl/pkg/rv32_defs.vh](../../../rtl/pkg/rv32_defs.vh) | 646 | 全文 1–646 | [08](08-integration-synthesis.md) | 编码/位域静态 |
| [rtl/plic/plic.v](../../../rtl/plic/plic.v) | 443 | 全文 1–443 | [01](01-privilege.md) | gateway/threshold 静态 |
| [rtl/top/core_top.v](../../../rtl/top/core_top.v) | 4226 | 全文 1–4226 | [08](08-integration-synthesis.md) | 01 接口抽查；08 全文；无动态 |
| [rtl/top/core_top_2b.v](../../../rtl/top/core_top_2b.v) | 1749 | 全文 1–1749 | [03](03-lsq-2b.md) | 01/04 接口抽查 |

63 个文件、33,706 行均在上表有唯一主责报告；`fpu_add.v` 是唯一未声称整文件全读的 RTL。

## 3. 33 个正式 TB：01–10 联合覆盖

正式入口只匹配 `sim/unit/tb_*.sv`（[scripts/regress.sh](<../../../scripts/regress.sh#L109-L112>)）。下表“联合全文”表示由所列报告的分段/全文合起来覆盖到末行；仍不等于断言充分或功能覆盖 100%。

| 正式 TB | 联合报告 | 深度 | 主要边界 |
|---|---|---|---|
| [tb_alu](../../unit/tb_alu.sv) | [06](06-execution.md) | 全文 | 非端到端依赖流 |
| [tb_axi_master_ctrl](../../unit/tb_axi_master_ctrl.sv) | [04](04-memory-bus.md) | 全文 | 不代替核级 access fault |
| [tb_back2_ipc](../../unit/tb_back2_ipc.sv) | [02](02-backend.md) | 全文 | 理想 ALU 流，未证派发全部提交 |
| [tb_back2_iq](../../unit/tb_back2_iq.sv) | [02](02-backend.md) | 全文 | 7 位 ROB 配置≠集成配置 |
| [tb_back2_lockstep](../../unit/tb_back2_lockstep.sv) | [02](02-backend.md)；[09](09-verification-followup.md) | 联合全文 | 理想环境前 5 程序；共模数据错误不查 |
| [tb_back2_lsq_fwd](../../unit/tb_back2_lsq_fwd.sv) | [03](03-lsq-2b.md) | 全文 | 非历史全部转发压力档 |
| [tb_back2_rob_wide_mem](../../unit/tb_back2_rob_wide_mem.sv) | [02](02-backend.md)；[07](07-test-infrastructure.md) | 联合全文 | 冲突首拍/独立随机读地址偏弱 |
| [tb_boot_stub](../../unit/tb_boot_stub.sv) | [08](08-integration-synthesis.md)；[09](09-verification-followup.md) | 联合全文 | 占位 payload；常量 OKAY，无错误注入 |
| [tb_bru](../../unit/tb_bru.sv) | [06](06-execution.md) | 全文 | 无流水误预测恢复 |
| [tb_clint](../../unit/tb_clint.sv) | [01](01-privilege.md) | 全文 | 恒零 AXI 证明无效；相等 oracle 反向 |
| [tb_core_top_2b](../../unit/tb_core_top_2b.sv) | [03](03-lsq-2b.md) | 全文 | 硬编码 oracle；gold+delta；无独立黄金 |
| [tb_csr_file](../../unit/tb_csr_file.sv) | [01](01-privilege.md) | 全文 | 不代表串行化/同拍竞争；PMP 锁期望反向 |
| [tb_decoder](../../unit/tb_decoder.sv) | [05](05-frontend-decode.md) | 全文 | 抽样非编码穷举 |
| [tb_exe_ctrl](../../unit/tb_exe_ctrl.sv) | [06](06-execution.md) | 全文 | 无整流水依赖交互 |
| [tb_fetch_unit](../../unit/tb_fetch_unit.sv) | [05](05-frontend-decode.md) | 全文 | 翻译/存储由夹具驱动 |
| [tb_fp_load_use](../../unit/tb_fp_load_use.sv) | [06](06-execution.md)；[09](09-verification-followup.md) | 联合全文 | 默认档不保证关键重叠场景 |
| [tb_fpu](../../unit/tb_fpu.sv) | [06](06-execution.md) | 全文 | 固化向量；done 拍/动态 frm 断言弱 |
| [tb_fpu_cmp_cvt](../../unit/tb_fpu_cmp_cvt.sv) | [06](06-execution.md)；[09](09-verification-followup.md) | 联合全文 | 有限固化 oracle，非全部输入 |
| [tb_fregfile](../../unit/tb_fregfile.sv) | [06](06-execution.md) | 全文 | 非多提交口 FP 通路 |
| [tb_front4_frontend](../../unit/tb_front4_frontend.sv) | [05](05-frontend-decode.md) | 全文 | 不证明持续 4 宽吞吐 |
| [tb_front4_integration](../../unit/tb_front4_integration.sv) | [05](05-frontend-decode.md)；[07](07-test-infrastructure.md) | 联合全文 | 只比 lane PC，不比指令位/长度 |
| [tb_front4_predictor](../../unit/tb_front4_predictor.sv) | [05](05-frontend-decode.md) | 全文 | 固定种子，非随机穷举 |
| [tb_l1d](../../unit/tb_l1d.sv) | [04](04-memory-bus.md) | 全文 | fill 模型不证核级错误响应 |
| [tb_l1i](../../unit/tb_l1i.sv) | [04](04-memory-bus.md) | 全文 | 不代替翻译取指整链 |
| [tb_lsu](../../unit/tb_lsu.sv) | [04](04-memory-bus.md) | 全文 | 组合接口≠2B LSQ 异常链 |
| [tb_m3_ddr3](../../unit/tb_m3_ddr3.sv) | [08](08-integration-synthesis.md)；[09](09-verification-followup.md) | 联合全文 | 缩小窗口；常量 OKAY；无中断边界 |
| [tb_mdu](../../unit/tb_mdu.sv) | [06](06-execution.md) | 全文 | 行为模型；done 拍/flush 断言弱 |
| [tb_parcel_align](../../unit/tb_parcel_align.sv) | [05](05-frontend-decode.md) | 全文 | 独立组合单元，非完整取指流 |
| [tb_pc_gen](../../unit/tb_pc_gen.sv) | [05](05-frontend-decode.md) | 全文 | 不证明整个前后端恢复 |
| [tb_plic](../../unit/tb_plic.sv) | [01](01-privilege.md) | 全文 | 恒零 AXI；threshold oracle 反向 |
| [tb_pmp_check](../../unit/tb_pmp_check.sv) | [01](01-privilege.md) | 全文 | 不等于 PTW/LSQ 集成全组合 |
| [tb_ptw](../../unit/tb_ptw.sv) | [04](04-memory-bus.md) | 全文 | 显式 SVADE=0；无 PTW→TLB→store 连测 |
| [tb_trap_ctrl](../../unit/tb_trap_ctrl.sv) | [01](01-privilege.md) | 全文 | 输入直驱，非 ROB 精确陷阱全链 |

## 4. 其余基线产物：分类与深度

245 文件构成：63 RTL + 33 正式 TB + 95 `sim/unit` 其他（该目录共 128，含 33 正式 TB）+ 13 `sim/arch_test` + 6 `sim/lockstep` + 5 `sim/tb` + 24 `sw` + 4 `fpga/tcl` + 2 `scripts`。

- **共享/定向 TB 与模型（`sim/tb` 5 文件）**：09 全文 `sim_mem_model.sv`、`tb_arch_test.sv`、`tb_core_top.sv`、`uart_ser_decoder.sv`（1–530/860/498/228）；stub/HTIF 边界见 09。
- **锁步（`sim/lockstep` 6 文件）**：07 全文 `cmp_commit.py`、`run.sh`；09 全文 `tb_lockstep.sv`；10 全文 `csr_hazard.S`/`link.ld`/`lock_hello.S`。
- **架构测试入口/配置（`sim/arch_test` 13 文件）**：07 全文 `run.sh`、`exclude.list`；10 全文其余 11 文件（`boot_stub.S`、`dm_*.S`、`link.ld`、yaml、`rvmodel_macros.h`、`rvtest_config.h`、`sail.json`、`test_config.yaml`）。arch-test 明确例化 2A，不是 2B 认证。
- **单元程序/链接（`sim/unit/prog` 29 文件）**：10 全文 24 个程序/链接（含 p1–p17、boot/FP/DDR；其中 `front4_int.S`/`.ld` 05 亦全文、`fp_load_use.S` 06 亦全文）；生成器 `gen_back2_lockstep_data.py`、`gen_front4_int_data.py` 由 07 全文。
- **生成数据（3 个 `.svh`）**：`back2_lockstep_data.svh`(87,071 行)、`front4_int_data.svh`(286 行)、`boot_stub_words.svh`(72 行) 只做**生成链/抽样/文件身份**登记；05 对 front4 数据仅抽查 1–70/286，未逐项核 248 PC；boot 字表只做内部 sum/首尾一致，不是源码再生等价；未逐向量独立重算 oracle。
- **历史探针/压力/诊断（`sim/unit` 66 文件）**：56 个 `dyn_probe*` 均不匹配正式 glob，07 只做分类与少量命中检索，**未逐行读取**；`n12_memstress_lsq.sv`、`n12b_unalign_fwd.sv` 由 03 全文（777/680 行），`n15s_fpstress_core.sv` 由 06 部分阅读（1–180、410–584），`n25_btb_collide_tb.sv`/`n25_btb_probe.sv` 由 05 全文，`n25_collision_probe.sv`/`n25_bp_probe.sv` 未读，`n4_defer_stress.sv`、`b29_wire_probe.sv`、`sim/unit/pkg_check.v` 未单独审计。它们不是当前 formal/DUT；**不能因名字断言已失配，也不能据历史 CSV/诊断补当前覆盖**。
- **脚本/综合（`scripts` 2 + `fpga/tcl` 4）**：07 全文 `env.sh`/`regress.sh`；08 全文 4 个 tcl（`synth.tcl`/`create_ip.tcl`/`impl.tcl`/`report_timing_detail.tcl`）。
- **板级（`sw` 24 文件）**：11 全文 5 个 `sw/boot` + 19 个 `sw/m5_board`，合计 **7,166 行**（逐文件行数相加一致），仅静态；未执行 xsim/烧录/真板。
- **额外 2 文件**：`fpga/run_vivado_batch.sh` 150 行、`fpga/soc_up.xdc` 31 行，母 Agent 已按 HEAD blob 只读比对、08 全文审阅；**不在 245 清单/哈希内**，TSV 单列。

## 5. 09/10/11 补批闭合

| 补批 | 声明量 | 闭合内容 | 仍不宣称 |
|---|---|---|---|
| 09 | 4,745 行 = 共享 5 文件 2,961 + 正式 unit 补段 1,784 | `sim_mem_model`、`tb_arch_test`、`tb_core_top`、`uart_ser_decoder`、`tb_lockstep` 全文；`tb_back2_lockstep`、`fpu_cmp_cvt`、`fp_load_use`、`boot_stub`、`m3_ddr3` 补齐指定段 | 仿真通过、黄金独立验算、协议 VIP |
| 10 | 39 文件、4,565 行 | arch_test 程序/配置、unit 程序/链接、`m1_uart.S` 等逐文件实际 read（清单见 10 报告） | 生成器重跑、源码→机器码一致、全部配置字段生效 |
| 11 | 24 文件、7,166 行 | `sw/boot` 5 + `sw/m5_board` 19 全文 | 构建/烧录/真板、当前 bitstream/时序 |

三个补批闭合的是**指定活动逻辑的静态阅读范围**，不是功能覆盖率；也不改变“本次未全量重跑”的边界。

## 6. 明确不能宣称的事项

1. 不能说 33/33 正式 TB 全绿等于功能正确，也不能说 245/245 哈希一致等于整个工作区被审计。
2. 不能说 `dyn_probe*`/`n*stress`/scratch/oldrtl 已被逐一核过；未逐行者按“分类登记、非当前 DUT”处理。
3. 不能说生成 `.svh` 的每个向量都经独立 oracle 重算；只登记生成链/抽样/文件身份。
4. 不能说 17 个缺陷复现是 17 个独立根因，或 7 个主题覆盖了全部 ISA 行为。
5. 不能说 Linux/U-Boot/QEMU 完整源或真实板级已被本次覆盖；它们不在范围。
6. 不能把 01 P2-01 的恒真 AXI 断言、06 SC→DS、02-5、05-05/06/07、08-04 等接口风险写成当前集成已复现缺陷。

## 7. COVERAGE.tsv 字段

`path`：仓库根相对路径；`category`：RTL/正式 TB/程序/生成数据/历史探针/脚本/板级等；`depth`：实际读取深度；`evidence`：给出该深度的报告编号；`limitation`：该文件结论的边界。247 条无重复，路径集合 = BASELINE 245 ∪ {`fpga/run_vivado_batch.sh`,`fpga/soc_up.xdc`}。
