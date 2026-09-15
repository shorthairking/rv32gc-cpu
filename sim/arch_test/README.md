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
| `dm_smoke.S` / `dm_csr_raw.S` | 定向程序：底座 PASS 通道自证 / CSR 写后读缺陷复现 |
| `../tb/tb_arch_test.sv` | DUT TB：core_top + 自洽 AXI 从设备 + hex 预载 + HTIF(tohost) 终止 + 签名导出 + 超时守卫 |

## 3. 当前状态（2026-09-15）

- **底座全链路可用**：`--directed dm_smoke` 在 DUT 与 Spike 上跑出逐行一致的签名 ⇒
  `RV32_ARCH_TEST_RUN: PASS (1/1)`（编译/参考/DUT 仿真/导出/比对五步均被独立执行）。
- **arch-test 用例当前 FAIL（阻塞在 RTL，不在底座）**：任何 ACT4 用例的启动码
  `RVTEST_TRAP_PROLOG` 都会做 `csrw mtvec,t2; csrr a4,mtvec; beq` 自检，而本核
  **CSR 写后读（指令距离 1）读到旧值** ⇒ 自检失败 ⇒ 走 abort ⇒ `mtvec=0` ⇒ 取指跑到 0 并空转。
  复现：`./sim/arch_test/run.sh --directed dm_csr_raw`（结果区 [0]/[4] 期望 0x800006C0，实测 0x00000000）。
  证据与分歧上下文见 `work/I-nop-00/`、`work/I-add-00/`（DUT 与 Spike 两侧 dump + 日志）。
- **RTL 修复方向**（`rtl/` 不在本底座的可写范围内，需另行派活）：
  `rtl/top/core_top.v:1104` 的旁路 `(csr_wen_w & (mw_csr_addr==de_csr_addr))` 只覆盖
  "W 写 / E 读同拍"（指令距离 2）；距离 1 的真实冒险是"**M 写 / E 读**"（CSR 读值在
  `core_top.v:2396` 的 E 级锁存）⇒ 需补 M 级前递（`em_csr_wdata`，注意 WARL 读视图）
  或在该条件上停顿一拍，交给既有 W→E 旁路兜住。

## 4. 修复后的验收动作（无需改底座）

```bash
./sim/arch_test/run.sh I-nop-00            # 期望：RV32_ARCH_TEST: I-nop-00 PASS (compared=15020 lines, first_diff=none)
./sim/arch_test/run.sh I-add-00            # 期望：RV32_ARCH_TEST: I-add-00 PASS (compared=15412 lines, first_diff=none)
./sim/arch_test/run.sh --directed dm_csr_raw   # 期望：PASS（距离 1 的 CSR 写后读回读 0x800006C0）
```

## 5. 备注

- 中间产物在 `sim/arch_test/work/<用例>/`（`.elf/.hex/.spike.sig/.dut.signature/两侧 dump/日志/tb.vvp`）；
  该目录属构建产物，提交前建议忽略（`.gitignore` 是否登记由母 Agent 决定）。
- 本底座**不含** uv/ruby 依赖：UDB 生成物（`rvtest_config.h`/`extensions.txt`）由手工维护，
  口径与 `rv32gc-2a.yaml`/`test_config.yaml` 声明一致；将来 UDB 可用时应改为其产物。
