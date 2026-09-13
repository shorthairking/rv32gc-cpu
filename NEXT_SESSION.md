# NEXT_SESSION.md —— 下一会话的启动提示词（复制下面整段发给 AI）

> 用途：本会话（阶段 2A 执行到第 4 个 goal round）结束后，用户切换会话时把下面 `====` 之间的内容整段发给新会话的 AI。
> 维护规则：每轮结束时更新"当前卡点"与"下一步"，并保持自包含（新会话没有本会话的上下文）。

================================================================================

# 任务：继续 RV32-GC CPU 项目的阶段 2A（顺序 5 级基线核验证）

## 0. 第一步必做（按顺序）

1. `read` 项目根目录的 `AGENT.md`：§2 关键决策、**§6 阶段总结（含"阶段 2A 进展"全部小节）**、§7 当前状态；
2. `read` 本文件 `NEXT_SESSION.md`（即你正在读的提示词）；
3. 用 `kb_search` 检索本工作区常驻知识库（ISA 手册/arch-test/工具链）与项目知识库（`rv32gc-cpu/docs/kb/`），**不要直接读大文件**；
4. `read` 实现级规格：`docs/design/spec/00-conventions.md`、`02-uop-and-decode.md`、`03-pipeline-regs.md`（写/改 RTL 前必须遵守；位域唯一真源是 `rtl/pkg/rv32gc_defs.vh`）；
5. 检查 git 状态与最近提交（`git -C rv32gc-cpu log --oneline | head`），确认工作区干净。

## 1. 项目背景（自包含摘要）

- 工作区 `/home/shorthair/dsh/rv32-cpu`，项目仓库在 `rv32gc-cpu/`（独立 git）。
- 总目标：RV32-GC（RV32IMAFDC + Zicsr/Zifencei）**4 发射乱序** CPU，接入 chiplab（龙芯 FPGA 实验箱，`xc7a200tfbg676-2`），最终从 NAND 启动 Linux。全部设计方案、移植方案、知识库、规格书都已在仓库中。
- 当前处于**阶段 2A**：先用**顺序 5 级基线核**打通"ISA + 特权级 + 总线 + 工具链 + 仿真"，再升级为乱序核。
- 环境：`/opt/riscv/bin/riscv32-unknown-linux-gnu-gcc`（GCC 16.1.0）；Verilator 5.020、Icarus Verilog 12.0 已装；**Spike 1.1.1-dev 已编译在 `rv32gc-cpu/tools/spike-install/bin/spike`**；Vivado 2025.2（在 PATH，沙箱内跑 vivado 必须 `HOME=/home/shorthair/dsh/rv32-cpu/rv32gc-cpu/.vivado_home`）；网络可用；`sudo` 不可用。
- 与用户交流、提问一律用**中文**。

## 2. 当前代码与验证资产（都已提交）

| 类别 | 位置 | 说明 |
|---|---|---|
| RTL（约 3.3k 行） | `rtl/top/core_top.v`（平台端口契约）、`rtl/top/rv32gc_core.v`（5 级流水）、`rtl/bus/rv32_axi_master.v`、`rtl/frontend/rv32_ifetch.v`、`rtl/top/rv32_regfile.v`、`rtl/csr/rv32_csr.v`、`rtl/decode/rv32_decoder.v`+`rv32_imm_gen.v`、`rtl/exec/rv32_alu.v`+`rv32_bru.v`+`rv32_mul_div.v`、`rtl/pkg/rv32gc_defs.vh` | 已支持 RV32IM + A（译码）+ Zicsr + SYS（ecall/ebreak/mret/sret/wfi/fence/fence.i/sfence.vma）+ Zicbom + 全部 Zca；**F/D 未实现（译码报非法）**；**无 MMU/PMP/CLINT/PLIC/Cache** |
| 仿真 TB | `sim/tb/sim_axi_slave.v`（单从设备模型）、`tb_smoke.v`（主 TB，支持 `+MEM_LO_INIT/+MEM_HI_INIT/+sig_dump/+timeout/+wave`）、`tb_debug_min.v`（调试 TB：提交轨迹 + `CSRID/CSRW` + 每 500 拍 STATE） | |
| 裸机测试 | `sim/tests/{hello.c,memtest.c,crt0.S,link.ld,link_hi.ld,arch_stub.S,build.sh}` | `link.ld`=0x0 布局；`link_hi.ld`=0x8000_0000（锁步/arch-test） |
| arch-test 配置 | `sim/arch_test/config/{link.ld,rvmodel_macros.h,rvtest_config.h}` | tohost 固定在 `0x8000_1000`；UART=`0x1FE001E0`；**CLINT 暂指向 scratch `0x800F0000`**（本核未实现 CLINT） |
| 脚本 | `scripts/run_sim.sh`、`run_unit_axi.sh`、`run_unit_exec.sh`、`run_unit_decoder.sh`、`arch_test_build.sh`、`run_arch_test.sh`、`lockstep.sh`、`lockstep_diff.py` | 见第 3 节命令 |

## 3. 常用命令（都已实测可用）

```bash
cd /home/shorthair/dsh/rv32-cpu/rv32gc-cpu
bash scripts/run_sim.sh hello                 # 端到端 C 程序 → 期望 SIM: PASS hello
bash scripts/run_sim.sh memtest               # 64KiB 字节/半字/字/走位/非对齐 → 期望 PASS
bash scripts/run_unit_exec.sh                 # EXEC_UNIT_TESTS: PASS (2461)
bash scripts/run_unit_axi.sh                  # AXI_SLAVE_UNIT: PASS (79)
bash scripts/run_unit_decoder.sh              # DECODER_UNIT_TESTS: PASS (257 vectors)
RV32GC_TIMEOUT=30000000 bash scripts/run_arch_test.sh I/I-add-00   # arch-test（见第 4 节卡点）
# 锁步（Spike 提交轨迹 vs 本核轨迹，自动报首个分歧）
bash scripts/lockstep.sh <0x80000000布局的.elf> 3000    # 或直接跑 tb_debug_min + lockstep_diff.py
python3 scripts/lockstep_diff.py <spike.log> <rtl.log> [--pc-only]
```
注意：Spike 的 `--log-commits` 输出在 **stderr**（用 `2>&1 1>/dev/null`）；Spike 的内存映射用 `-m0x80000000:0x10000000,...`（0x0 布局会与设备区冲突）；本核复位 PC=0，跑 0x8000_0000 布局的镜像需要 **`-DRESET_PC=32'h8000_0000`** 重编或用 `arch_stub.S` 跳转桩。

## 4. 当前卡点（第 4 轮结束时的事实，请从这里接手）

1. **`hello`、`memtest` 全绿**；单元测试全绿。
2. **arch-test `I-add-00` 未跑完**：
   - 与 Spike 的提交级锁步：**前 378 条（≥0x8000_0000 的提交，PC/rd/wdata）完全一致**；
   - 用 `RV32GC_TIMEOUT=30000000` 仍 `TB: TIMEOUT`（30M 拍未完成）；
   - 增强调试 TB 观测：`cyc≈1000~1500` 时 PC 在 `0x8000_65xx`（**rvtest 陷阱处理程序**）、`front_hold=1`、MEM 处于 `M_WAIT`（等 AXI）；`cyc≈2000` 回到 `0x80046840`（测试主体）→ 陷阱能返回；
   - **挂钟 240 秒只推进约 2000 拍（≈20 拍/秒）**，远慢于 `hello`/`memtest`（数千~数万拍/秒）→ 强烈怀疑**组合环/零时间振荡**（在 `front_hold` 或 `M_WAIT` 期间），或某访问路径反复重试；
   - 提交轨迹最后停在 `pc≈0x8004_682x` 的签名计算循环。
3. **下一步建议顺序**：
   a. 用 `verilator --lint-only` 全 RTL 扫组合环告警；把调试 TB 的 STATE 打印改为每 1 拍，看 `cyc` 是否推进（判断是否零时间振荡）；必要时 dump `cyc=1985~2010` 的 VCD；
   b. 若确认振荡/死锁 → 定位到具体信号组合并修复（重点看 `front_hold`（CSR 顺序化停顿）、`mem_stall`、`advance_all`、`wb_retire` 的相互依赖）；
   c. 修好后把锁步轨迹拉长到 ≥5000 条提交，确保与 Spike 一致，再跑 arch-test 全量；
   d. 跑通后按 `I → M → Zicsr → Zifencei → Zca → Zaamo/Zalrsc` 顺序批量跑 arch-test 子集（`scripts/run_arch_test.sh <组>/<用例>`）。
4. **阶段 2A 剩余**（在 arch-test 之后）：CSR/异常/PMP 完善 → Sv32 MMU → L1I/L1D/L2 Cache → FPGA tcl（`fpga/tcl/build_chiplab.tcl`，时钟 IP 已备好 `fpga/tcl/create_clk_wiz_cpu.tcl`）与上板 B1~B3。

## 5. 工作方式要求（必须遵守）

1. **建议用 goal 工具**建立长任务目标："完成阶段 2A：…（见 AGENT.md §3）"，并用 goal round 持续推进；
2. 每完成一个里程碑：更新 `AGENT.md` §6（阶段总结/进展）与 §7（当前状态）→ `git commit`（信息格式 `<阶段>: <摘要>`）；
3. 修改 RTL 后必须跑回归：`run_unit_*` + `run_sim.sh hello` + `run_sim.sh memtest`；
4. 改位域/接口必须先改 `rtl/pkg/rv32gc_defs.vh` 并同步 `docs/design/spec/02-*`、`03-*`；
5. 复杂缺陷优先用**锁步**（Spike 提交轨迹 vs 本核轨迹）定位，而不是猜测；
6. 需要权限或发现需求冲突时用中文向用户提问，并给出选项与推荐项。

================================================================================

（提示词结束）
