# 验证方案

> 上游文档：`00-overview.md`。验证对象：RV32GC 4 发射乱序核（含 Cache/MMU/CSR/总线）。
> 目标：在 FPGA 上板之前，通过"单元 → 集成 → 随机 → 系统"四级验证，使"启动 Linux"成为一次成功率较高的动作，而不是调试手段。

---

## 1. 验证工具与环境

| 工具 | 用途 | 状态 |
|---|---|---|
| **Icarus Verilog 12.0** | 单元测试、快速回归（编译快） | 由用户在沙箱外 `sudo apt install iverilog` 安装 |
| **Verilator 5.02** | 全核/全 SoC 仿真、Linux 启动（快 10~50 倍） | 同上（`sudo apt install verilator`） |
| **Vivado XSim** | 备选（无需额外安装），用于综合后时序仿真 | 已具备 |
| **Spike（riscv-isa-sim）** | 参考模型：生成 arch-test 参考签名、生成提交级黄金轨迹 | 需从源码编译（工作区有 `riscv-gnu-toolchain`，网络可用） |
| **riscv-arch-test（ACT4）** | ISA 一致性测试（RV32I/M/A/F/D/C/Zicsr/Zifencei/Sv32/PMP） | 工作区已有源码（`riscv-arch-test`） |
| `/opt/riscv` GCC 16.1.0 | 编译测试程序与裸机用例 | 已具备 |

### 1.1 测试平台（TB）结构

本项目的仿真环境**自建**（不复用平台 verilator testbench，原因是平台 difftest 依赖 LA32R NEMU）：

```
sim/tb/
├── soc_sim_top.v        # CPU + AXI 互连 + 内存模型 + CONFREG + UART + NAND 模型
├── axi_mem_model.v      # 行为级 DDR/SRAM 模型（支持突发、可 dump/load hex）
├── uart_model.v         # 打印到 stdout / 文件
├── confreg_sim.v        # 复用 chiplab/IP/CONFREG/confreg_sim.v
├── nand_model.v         # 行为级 NAND Flash（页 2048+64，含 DMA 引擎模型）
├── tb_iverilog.v        # iverilog 顶层：$readmemh 载入镜像、超时退出
└── tb_verilator.cpp     # Verilator C++ 顶层：ELF 载入、tohost 监视、轨迹输出
```

**地址映射与 FPGA 保持一致**（DDR 0x0、SRAM 0x1C00_0000、CONFREG 0x1FD0_0000、UART 0x1FE0_01E0、NAND 0x1FE7_8000），另在仿真中把 arch-test 的 `TEST_BASE = 0x8000_0000` 映射到一段行为级 RAM（便于直接运行标准测试 ELF）。

**通过/失败判据**（多路）：
1. **`tohost` 约定**：测试 ELF 向 `0x8000_1000` 写 1（通过）/3（失败）→ TB 立即结束仿真并按结果返回退出码（arch-test ACT4 标准约定）；
2. **CONFREG 约定**：裸机用例写 CONFREG `IO_SIMU`（仿真退出）/`VIRTUAL_UART`（打印），或写 LED_RG（1=绿/通过，2=红/失败）；
3. **串口输出**：识别 `RVCP-SUMMARY: TEST PASSED`（arch-test）与自定义 `PASS/FAIL` 行；
4. **超时**：仿真周期数超限判失败（NAND/中断等待类用例单独设置上限）。

---

## 2. 四级验证

### 2.1 第一级：单元测试（iverilog，分钟级）

| 模块 | 测试内容 | 参考 |
|---|---|---|
| ALU | 全 32 位随机 + 边界（溢出、比较、移位量 ≥32） | 直接比较期望值 |
| 乘法/除法 | 随机向量 + 边界（除零、`INT_MIN/-1`、符号扩展） | C 参考程序生成期望值 |
| FPU | 加/减/乘/除/平方根/FMA/比较/转换/分类，覆盖 5 种舍入模式、次正规、NaN/Inf、NaN boxing | 用 GCC 编译的参考程序（软浮点 or 主机浮点）生成向量；必要时用 Berkeley SoftFloat |
| 桶形移位器 | 全移位量 × 随机数据 | 直接比较 |
| BPU | 定向序列（循环、交替、相关分支、递归）验证预测方向与选择器收敛 | 逻辑断言 |
| I-Cache/L1D/L2 | 随机读写序列 × 非对齐/跨行/字节使能，与理想内存模型比对 | 行为模型 |
| MSHR/Store Buffer | 缺失合并、乱序返回、写回与填充竞争 | 断言 + 定向用例 |
| TLB/PTW/PMP | 4 KB/4 MB 页、ASID、G 位、A/D 更新、12 种非法 PTE、PMP 三种匹配模式 | 手工构造页表 |
| CSR | 每条 CSR 的读写、WARL 行为、非法访问异常 | 规格对照表 |
| AXI 主设备 | 协议检查（valid/ready 握手、`last`/`len` 一致、4 KB 边界、响应乱序） | SystemVerilog 断言 + 协议监视器 |

### 2.2 第二级：ISA 一致性（riscv-arch-test ACT4）

工作区 `riscv-arch-test` 为 **ACT4**（4.1.0）分支：测试为**自校验 ELF**（参考签名在构建时由 Sail/Spike 生成并编译进镜像），因此 TB 只需运行 ELF 并读 `tohost`。

- **相关测试组**（RV32）：`rv32i/I`(39) `M`(8) `F`(78) `D`(104) `Zaamo`(9) `Zalrsc`(2) `Zca`(26) `Zcd`(4) `Zcf`(4) `Zicsr`(6) `Zifencei`(1) `Misalign`(5) `MisalignF`(2) `MisalignD`(2) `MisalignZca`(4)；特权级：`priv/Sv*`（含 31 个 `sv32*`）、`PMPSm`(38)、`SvPMP`(16)、`SvZicbo`(24)、`PMPS/PMPU/PMPZca` 等，共约 450 个 RV32 相关用例。
- **构建方式**：需要参考模型（Sail 0.13.1 官方支持；Spike 亦可）生成参考签名；本项目的做法是**从源码编译 Spike**（`riscv-isa-sim`，网络可用），用其生成签名并驱动构建，避免 Sail/OCaml 工具链的重型依赖。
- **缺项**（该版本 `tests/priv` 中没有）：机器级 CSR/中断/Sm/Ss CSR 套件。**本项目自行编写**（见 §2.3）。
- **覆盖点**：`coverpoints/norm/*.yaml` 作为规范条款清单，逐条对照实现（用于评审与自查）。

### 2.3 第三级：自研定向与随机测试

| 类别 | 内容 |
|---|---|
| 特权级自研测试（补 arch-test 缺项） | 每个 CSR 的读写/WARL；每个异常码的正反例；7 种中断（MSI/MTI/MEI/SSI/STI/SEI + 委托）；`mret/sret/wfi/sfence.vma`；MPRV/SUM/MXR 组合；PMP 锁定 |
| `tohost` 框架 | 统一的裸机测试框架（`sw/tests/`），每个用例输出 `PASS/FAIL` 并写 `tohost` |
| 随机指令测试 | 自研随机生成器（受限随机 + 合法指令序列），**与 Spike 的提交级轨迹逐条比对**（见 §2.4）；重点覆盖：load/store 别名、非对齐、长延迟指令（除法）后的异常、分支密集 |
| 压力/边界 | ROB/IQ/LSQ 满、连续误预测、连续异常、中断风暴、原子指令竞争 |
| 自修改代码 | 写指令 → `fence.i` → 执行新指令（验证 I-Cache 一致性） |
| Cache 维护 | `cbo.clean/flush/inval` 后内存与 Cache 一致；DMA 读写与 CPU 读写交叉 |

### 2.4 参考模型与锁步比对（替代平台的 LA32R difftest）

```
  ┌────────────┐   ELF    ┌───────────────────────┐   提交轨迹   ┌──────────────┐
  │  测试程序  │ ───────► │  RTL（iverilog/verilator）│ ──────────► │ rtl_trace.log │
  └────────────┘          └───────────────────────┘  (pc,rd,data) └──────┬───────┘
  ┌────────────┐  同一ELF ┌───────────────────────┐   提交轨迹          │ diff
  │ Spike 参考 │ ───────► │ spike --log-commits   │ ──────────► spike.log ┘
  └────────────┘          └───────────────────────┘
```

- RTL 侧轨迹来自提交级（`debug0_wb_pc/rf_wen/rf_wnum/rf_wdata` 已由平台接口天然提供）；
- Spike 侧 `--log-commits` 输出相同格式；
- 逐条比对（PC、目标寄存器、写数据），第一个不一致点即为 bug 定位；
- **顺序核 vs 乱序核**：同一 ELF 在两个核上跑，提交轨迹必须完全一致（这是乱序恢复逻辑的最强检查）。

---

## 3. 系统级验证（软件栈联调）

| 阶段 | 验证内容 | 通过标准 |
|---|---|---|
| OpenSBI | `fw_jump`/`fw_dynamic` 启动 | 串口打印 OpenSBI banner，正确探测 CLINT/PLIC |
| U-Boot | 启动、`nand info`、`nand read/write/erase`、`mtd`、环境变量保存 | 命令全部可用，NAND 读写校验一致，重启后环境保留 |
| 从 NAND 启动内核 | `booti`/`bootelf` 从 NAND 读 Image + DTB 并启动 | 内核解压/启动日志正常 |
| Linux 用户态 | initramfs + busybox | 进入 shell，`ls/cat/echo` 正常 |
| 驱动 | 8250 串口、CLINT 定时器、PLIC 中断、NAND MTD/UBI | `cat /proc/interrupts`、`dmesg` 无异常；NAND 分区可挂载/读写 |
| 稳定性 | 内核编译（`make -j`）+ `md5sum` 校验 + 长时间运行 | 无随机崩溃（重点回归 Cache/DMA 一致性） |

---

## 4. 回归与 CI

- `scripts/regress.sh`：一键运行"单元测试 → arch-test 子集 → 自研测试 → 顺序/乱序锁步"并在失败时返回非零退出码；
- 每次 RTL 修改后必须全绿才能进入下一阶段（提交前检查）；
- 仿真时间预算：单元测试 < 2 min，arch-test 子集 < 20 min（verilator），锁步随机测试 < 30 min。

---

## 5. 覆盖率与质量指标

| 指标 | 目标 |
|---|---|
| 指令功能覆盖 | RV32IMAFDC 全部指令各至少 1 个定向用例 + arch-test 覆盖 |
| 特权级覆盖 | 每个 CSR 至少 1 读 1 写；每个异常/中断码至少 1 例；Sv32 权限矩阵全覆盖 |
| 微架构覆盖 | 每个满/空条件、每个清空/重放路径至少 1 次触发（用覆盖点计数器统计） |
| 分支预测准确率 | CoreMark ≥ 93%，Dhrystone ≥ 96% |
| Cache 命中率 | L1 ≥ 95%，L2 ≥ 80%（CoreMark/Dhrystone 平均） |
| 时序 | 100 MHz 下 WNS ≥ 0（否则按 `07-fpga-timing.md` §2 降级并记录） |

---

## 6. 阶段与验证的对应关系

| 阶段 | 验证重点 |
|---|---|
| 阶段二（顺序核） | 单元测试 + arch-test 非特权 + 基础特权 + 裸机用例 + 上板 B1~B3 |
| 阶段三（Cache/MMU/总线完善） | arch-test Sv32/PMP + Cache/MMU 单元 + Linux 启动（顺序核） |
| 阶段四（乱序核） | 顺序/乱序锁步 + 压力测试 + 性能计数 |
| 阶段五（上板与软硬件联调） | 系统级验证（OpenSBI/U-Boot/Linux/NAND/rootfs）+ 板级压力测试 |
