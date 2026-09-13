# NEXT_SESSION.md —— 下一会话的启动提示词（复制下面整段发给 AI）

> 用途：本会话（阶段 2A 执行到第 7 个 goal round）结束后，用户切换会话时把下面 `====` 之间的内容整段发给新会话的 AI。
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
bash scripts/run_unit_decoder.sh              # DECODER_UNIT_TESTS: PASS (254 vectors)
bash scripts/run_arch_test_suite.sh I         # 整组批量（默认超时 300000 拍，JOBS=4 并行）
bash scripts/run_arch_test.sh I/I-add-00      # 单个用例
bash scripts/run_lrsc_test.sh                 # A 扩展定向自测 → LRSC_DIRECTED: PASS
# 锁步（Spike 提交轨迹 vs 本核轨迹，自动报首个分歧）
bash scripts/lockstep.sh <0x80000000布局的.elf> 3000    # 或直接跑 tb_debug_min + lockstep_diff.py
python3 scripts/lockstep_diff.py <spike.log> <rtl.log> [--pc-only]
```
注意：Spike 的 `--log-commits` 输出在 **stderr**（用 `2>&1 1>/dev/null`）；Spike 的内存映射用 `-m0x80000000:0x10000000,...`（0x0 布局会与设备区冲突）；本核复位 PC=0，跑 0x8000_0000 布局的镜像需要 **`-DRESET_PC=32'h8000_0000`** 重编或用 `arch_stub.S` 跳转桩。

## 4. 当前状态与卡点（第 8 轮结束时的事实，请从这里接手）

1. **端到端**：`SIM: PASS hello`、`SIM: PASS memtest`；单元测试全绿（AXI 79 / EXEC 2461 / DECODER 254）。
2. **arch-test 17 组全绿（123 例 0 失败）**：`I` 39、`M` 8、`Zicsr` 6、`Zifencei` 1、`Zca` 26、
   `Zaamo` 9、`Zalrsc` 2、`Misalign` 5、`MisalignZca` 4、`Zicntr` 2、`Zicbom` 3、`Zicboz` 1、
   `Zicbop` 3、`Zihintpause` 1、`Zihintntl` 4、`ZihintntlZca` 4、`Zmmul` 4、`Zicond` 2。
   批量：`bash scripts/run_arch_test_suite.sh <组名>`（JOBS=4 更快）。
   **注意**：`run_arch_test.sh` 默认加 `-DMISALIGNED_TRAP`；**MARCH 已自动合成**（基座
   rv32imac_zicsr_zifencei_zicntr ∪ 用例头部扩展，含 `c`→`zca` 别名归一与去重），不要写死 MARCH。
3. **A 扩展定向自测全绿**：`bash scripts/run_lrsc_test.sh` → `LRSC_DIRECTED: PASS`（28 项检查）。
4. **本轮（第 7~8 轮）修复与新增**（完整证据见 `AGENT.md` §6「第 7 轮」，含逐项必要性验证表）：
   * **3 个真实 RTL 缺陷**：① MEM 级转发漏掉访存结果（LL/SC/LOAD 结果只能等 WB → Zalrsc/Zaamo
     组失败的真正原因）；② 保留集不清（普通 store、SC 成功/失败、AMO 写完成都要清）；
     ③ `M_DONE` 无条件回 `M_IDLE` 会在前端停顿时重放同一条指令（对 SC 致命）→ 改为 linger。
   * **测试模型加固**：`sim/tb/sim_axi_slave.v` 读数据改为寄存一拍，消除"写后读同一地址返回
     上一版数据"的仿真竞态（不是 Zalrsc 通过的原因，但 `lrsc.S` 需要它）。
   * **Zicbom/Zicboz**：新增 menvcfg(0x30A)/senvcfg(0x10A) 的 CBCFE/CBZE/CBIE 位 + ID 级
     CBO 低特权级许可检查；`uop_ctrl_t` 73→74 bit 新增 `is_cbo`（`cbo_op` 的 0 值与 ECALL 冲突）；
     RTL 中硬编码的 `[72:0]`/`73'd0` 全部改用 `` `UOP_CTRL_W ``（否则 `dec_ctrl[73]` 读出 X，
     仿真卡死在取指 X 地址 —— 这个坑踩过一次）。
   * **Zicond**：`czero.eqz`(funct3=101，与 SRL 共用)/`czero.nez`(funct3=111，与 AND 共用)，
     必须先判 funct7=0000111；ALU 新增 `ALU_CZERO_EQZ/NEZ`。
   * **用例 ISA 串自动合成**：`scripts/arch_test_build.sh` 取"基座 ∪ 头部扩展"并做别名归一/
     去重（写死基座会让 Zicbom/Zihintpause 整组失败；直接用头部串会缺 `_zicntr`）。
5. **⚠️ 上一轮的一个错误结论已更正**：`Zalrsc-sc.w-00` 的失败**不是** upstream ACT4 生成器缺陷，
   而是本核的 MEM 转发缺陷（#4 之①）。`scripts/tests/arch_sigreg_clobber_report.md` 顶部有更正
   横幅；`arch_scan_sigreg_clobber.py` 的值模型作废，**不要据此判定生成器缺陷**。
6. **下一步（阶段 2A 剩余，按 `AGENT.md` §7 任务表）**：
   a. **PMP**（`UDB_NUM_PMP_ENTRIES` 仍为 0；内核/SBI 需要）—— 实现 pmpcfg0-3/pmpaddr0-15 +
      S/U 访问检查（L/X/W/R + TOR/NA4/NAPOT），再跑 `tests/priv/PMPS|PMPSm|PMPU|PMPZaamo|PMPZalrsc|
      PMPZca|PMPF` 组（注意框架的 -T 顺序约定）；
   b. **Sv32 MMU（TLB+PTW）+ L1I/L1D/L2 Cache**（2A-4）—— 有 Cache 后 CBO 才需要真正实现
      clean/flush/inval/zero 语义（目前是"走 LSU 的空操作"，只实现了许可与陷阱）；
   c. 继续试跑未接入组（`Zimop` 0/40、`Zcmop` 0/8 —— 都是 MOP 类预留编码，按规范"未实现的
      MOP 应执行而不产生副作用"，需要给译码加 MOP 处理；`Zicsr` 已过）；
   d. FPGA tcl 与上板 B1~B3。
7. **本轮新增工具/资产**：`sim/tb/tb_trace_mem.v`（提交轨迹 + D 侧请求/响应 + AXI 通道追踪，
   定位本轮三个缺陷的关键工具）、`sim/tb/tb_axi_slave_rw.v`（从设备写后读可见性独立复现台）、
   `sim/tests/lrsc.S` + `scripts/run_lrsc_test.sh`（A 扩展定向自测）、`scripts/tests/`
   （生成器缺陷扫描脚本与报告，含更正）。

## 5. 工作方式要求（必须遵守）

1. **建议用 goal 工具**建立长任务目标："完成阶段 2A：…（见 AGENT.md §3）"，并用 goal round 持续推进；
2. 每完成一个里程碑：更新 `AGENT.md` §6（阶段总结/进展）与 §7（当前状态）→ `git commit`（信息格式 `<阶段>: <摘要>`）；
3. 修改 RTL 后必须跑回归：`run_unit_*` + `run_sim.sh hello` + `run_sim.sh memtest`；
4. 改位域/接口必须先改 `rtl/pkg/rv32gc_defs.vh` 并同步 `docs/design/spec/02-*`、`03-*`；
5. 复杂缺陷优先用**锁步**（Spike 提交轨迹 vs 本核轨迹）定位，而不是猜测；
6. 需要权限或发现需求冲突时用中文向用户提问，并给出选项与推荐项。

================================================================================

（提示词结束）
