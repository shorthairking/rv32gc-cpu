# sim/arch_test/ —— 2A 基线核的 arch-test（ACT4）底座

> 项目：rv32gc-cpu（阶段二 2A）；规格依据：`docs/design/08-baseline-5stage.md` §8.2/§8.2.1、
> `docs/design/07-verification.md` V-3/V-4/V-5。

## 1. 用法

```bash
./sim/arch_test/run.sh I-nop-00          # 跑 1 个 rv32i 用例（端到端：编译→Spike 参考→DUT 仿真→签名逐行比对）
./sim/arch_test/run.sh I-add-00 M-add-00 # 跑多个
./sim/arch_test/run.sh --list            # 列出用例与是否被 exclude.list 排除
./sim/arch_test/run.sh --check-exclude   # 校验 exclude.list 每条规则都命中真实用例
./sim/arch_test/run.sh --directed dm_smoke       # 定向程序：底座 PASS 通道自证（无 CSR 访问）
./sim/arch_test/run.sh --directed dm_csr_raw     # 定向程序：CSR 写后读（RAW）缺陷复现
```

判定纪律（AGENT.md §0.6「未捕获即失败」）：
- 唯一成功文案 = `RV32_ARCH_TEST: <用例> PASS (compared=<n> lines, first_diff=none)` 与
  `RV32_ARCH_TEST_RUN: PASS (<n>/<n>)`；兜底/失败路径**不含 PASS 字样**；
- 任一步失败（编译/参考/DUT 仿真/签名行数/逐行比对/超时）⇒ 该用例 FAIL 且脚本 rc≠0。

## 2. 文件

| 文件 | 作用 |
|---|---|
| `run.sh` | 入口：编译 → Spike 参考签名 → DUT 仿真 → 签名逐行比对 → 汇总（fail-closed） |
| `test_config.yaml` | ACT4 DUT 配置：编译器/参考模型路径、`linker_script`、`include_priv_tests: False`、内存布局 |
| `link.ld` | 链接脚本：`.boot`@0x1C00_0000（复位桩）、用例镜像@0x8000_0000（1 MiB）、`.tohost`@0x800F_F000 |
| `boot_stub.S` | 复位跳转桩（`lui x5,0x80000; jalr`），链接进 ELF，DUT 与 Spike 入口对称 |
| `rvmodel_macros.h` | DUT 宏：**`STANDARD_SM_SUPPORTED` + `F_SUPPORTED`**（08 §8.2.1(a) 硬要求）、UART/CLINT/PLIC 地址、tohost 终止 |
| `rvtest_config.h` | DUT 配置头（**手工维护**：本机无 uv/ruby/UDB，`udb cfg-c-header` 不可用） |
| `rv32gc-2a.yaml` | UDB 配置声明（同上：登记用途） |
| `sail.json` | 参考模型平台描述；run.sh 从中取 `SAIL_*` 编译宏（sig 版 ELF 必需） |
| `exclude.list` | 排除清单（逐条带理由；`--check-exclude` 防漂移） |
| `dm_smoke.S` / `dm_csr_raw.S` / `dm_htif.S` | 定向程序：底座 PASS 通道自证 / CSR 写后读回归 / HTIF 控制台写最小复现 |
| `../tb/tb_arch_test.sv` | DUT TB：core_top + 自洽 AXI 从设备 + hex 预载 + HTIF(tohost) 终止 + 签名导出 + 超时守卫 |

## 3. 当前状态（2026-09-15）

**底座本身已自证可用**（三条定向程序在 DUT 与 Spike 上跑出逐行一致的签名）：
```bash
./sim/arch_test/run.sh --directed dm_smoke     # PASS（纯整数：编译/参考/DUT/导出/比对全链路）
./sim/arch_test/run.sh --directed dm_csr_raw   # PASS（CSR 写后读距离 1 = 0x800006C0 ⇒ 96207a9 修复已生效）
./sim/arch_test/run.sh --directed dm_htif      # PASS（HTIF 控制台写 tohost 窗口无副作用）
```

**arch-test 用例（I-nop-00 / I-add-00）当前仍 FAIL，阻塞在 DUT（非底座）**，已定位/已排除的链条：
| # | 现象 | 结论 |
|---|---|---|
| 1 | ACT 启动码 mtvec 自检失败（`csrw mtvec; csrr 读回旧值`） | **RTL 缺陷**：CSR 写后读距离 1 缺旁路 ⇒ 已由 `96207a9` 修复，`dm_csr_raw` 复验 PASS |
| 2 | ACT 用例跑到末尾（签名区已按参考写入 `final_sig_offset=4` / `final_trap_sig_offset=0`；控制台仅出 1 个字符）后 DUT 掉进 **PC=0 的非法指令陷阱环** | **RTL 侧待定位**（本底座给出末态证据）：`fetch_pc=0x0 pipe_adv=1 m_busy=0`、`mcause=0x2`(illegal instruction)、`mepc=0x0`；AXI 五通道全空闲（AR v/r=0/1、AW v/r=0/1、W/R/B=0）⇒ 核在某处跳到/返回到地址 0（0x0 属核 PMA 的可缓存 DDR 窗口，命中缓存后不再发 AXI，故表现为"无总线活动 + 死循环"）。已排除：HTIF 控制台写本身（`dm_htif` PASS）与底座/TB 因素（`dm_smoke`/`dm_csr_raw` PASS） |
| 3 | 配置面 | `sfence.vma` 未译码（core_top.v 已知遗留 L2）⇒ `rvtest_config.h` **暂不声明 `SV32_SUPPORTED`**（否则 ACT 启动码无条件插入 `sfence.vma`，一执行即非法指令）。恢复条件：RTL 译码 `sfence.vma` |

复现（每条都在 10 分钟内给出精确 FAIL 证据，绝不假 PASS）：
```bash
./sim/arch_test/run.sh --cycles 6000 I-nop-00      # 观察：拍数=6000 提交数≈822；
                                                   #   AXI 末态=全空闲；核内末态: fetch_pc=0x0 mcause=0x2 mepc=0x0
```
证据文件：`work/I-nop-00/I-nop-00.dut.log`（DUT 侧末态 + 摘要）、`work/I-nop-00/I-nop-00.spike.sig`
（参考签名）、`work/evidence/*.log`（历史定位过程：CSR RAW / 提交分歧比对 / 停摆态）。

## 4. 修复后的验收动作（无需改底座）

```bash
./sim/arch_test/run.sh I-nop-00            # 期望：RV32_ARCH_TEST: I-nop-00 PASS (compared=15020 lines, first_diff=none)
./sim/arch_test/run.sh I-add-00            # 期望：RV32_ARCH_TEST: I-add-00 PASS (compared=15412 lines, first_diff=none)
./sim/arch_test/run.sh --directed dm_csr_raw   # 期望：PASS（CSR 写后读回归）
```

## 5. 备注

- 中间产物在 `sim/arch_test/work/<用例>/`（`.elf/.hex/.spike.sig/.dut.signature/两侧 dump/日志/tb.vvp`）；
  该目录属构建产物，提交前建议忽略（`.gitignore` 是否登记由母 Agent 决定）。
- 本底座**不含** uv/ruby 依赖：UDB 生成物（`rvtest_config.h`/`extensions.txt`）由手工维护，
  口径与 `rv32gc-2a.yaml`/`test_config.yaml` 声明一致；将来 UDB 可用时应改为其产物。
