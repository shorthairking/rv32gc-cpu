# AGENT.md — RV32-GC CPU 及其配套软硬件项目：流程、计划与阶段交接

> 本文件是**整个项目的总纲与进度台账**。每一阶段结束时必须：① 追加"阶段总结"；② 更新"当前状态与下一阶段计划"；③ 停下等待用户审阅与明确指令。
> 最后更新：阶段一结束（方案与知识库交付）。

---

## 0. 项目目标与硬性指标

**总目标**：设计基于 RV32-GC 指令集的 CPU，在 chiplab（龙芯 FPGA 实验箱，`xc7a200tfbg676-2`）平台上完成软硬件协同，最终从 NAND 启动 Linux 内核、驱动与根文件系统。

| 硬性指标 | 设计要求 | 验收方式 |
|---|---|---|
| 指令集 | RV32IMAFDC + Zicsr/Zifencei/Zicntr/Zicbom | arch-test + Linux 启动 |
| 特权级 | M/S/U + Sv32 MMU + PMP 16 项 | OpenSBI + S 模式 Linux |
| 发射宽度 | **4 发射超标量**（用户确认的"4 个标量及以上"含义） | 流水线提交宽度 = 4 |
| 执行部件 | ≥4 个标量部件（实际 6 个：ALU×2、BRU、MDU、LSU、FPU） | RTL 结构 |
| 分支预测 | **锦标赛预测器**（全局 Gshare + 局部历史 + 选择器） | 结构 + 准确率统计 |
| 流水级 | ≥5 级（实际 11 级） | 结构 |
| 乱序执行 | ROB 128 项 + 物理寄存器重命名 + 分布式发射队列 + LSQ | 结构 + 锁步验证 |
| Cache | L1I 16 KB / L1D 32 KB / L2 256 KB | 结构 + 命中率 |
| 主频 | ≥60 MHz，目标 100 MHz | Vivado 时序报告 |
| 软件 | U-Boot（可读写 NAND、从 NAND 自动启动）、Linux 内核+驱动、根文件系统 | 上板实测 |

**交付物**：CPU RTL 与测试平台、U-Boot 移植、Linux 内核与驱动移植、可执行镜像（uboot/内核/根文件系统）、综合脚本与约束（复用平台约束）。

---

## 1. 工作区资源地图

| 路径 | 内容 | 本项目如何使用 |
|---|---|---|
| `chiplab/` | 平台 RTL（IP/SoC/仿真/FPGA 工程）、文档 | **只读复用**：CPU 接入 `IP/myCPU`，AXI/DDR/UART/NAND/CONFREG IP 与工程约束直接用 |
| `la32r-uboot/` | U-Boot（LA32R 板 + 完整 `arch/riscv` RV32 支持） | **移植基线**：新增 board/defconfig/DTS/NAND 驱动 |
| `la32r-Linux/` | Linux 5.14.0-rc2（`arch/loongarch` LA32R 板 + **上游 `arch/riscv` RV32 支持**） | **移植基线**：新增 `SOC_CHIPLAB`/DTS/defconfig/NAND 驱动 |
| `riscv-isa-manual/` | ISA 规范 | 通过常驻知识库 `kb_search` 检索，不直接读大文件 |
| `riscv-arch-test/` | ACT4 架构测试套件 | 验证（需参考模型生成签名） |
| `riscv-gnu-toolchain/` | 工具链源码 | 需要 bare-metal 工具链时自行编译 |
| `docs-dev-guide/` | 文档工程指南 | 知识库来源 |
| `/opt/riscv/` | `riscv32-unknown-linux-gnu-` GCC 16.1.0 | 全项目编译 |
| `~/.dsh-kb`, `dsh-extension/` | 常驻知识库与 skill | 领域知识检索（阶段 0 成果） |
| **`rv32gc-cpu/`（本项目）** | 设计文档、RTL、仿真、软件移植、脚本 | 全部交付物，独立 git 仓库 |

**外部资源**：Vivado 2025.2（`vivado` 在 PATH）；网络可用（可 clone OpenSBI/Spike/busybox）；`sudo` 不可用（系统包安装需用户在沙箱外执行）。

---

## 2. 关键决策记录（ADR 摘要）

| # | 决策 | 理由 | 备选与否决原因 |
|---|---|---|---|
| D1 | 采用 **4 发射超标量 + ROB 乱序** | 用户明确"4 个标量及以上"= 4 发射 | 记分牌/顺序多发射无法同时满足 4 发射与精确异常 |
| D2 | 分阶段实现：**先顺序 5 级基线，再升级乱序** | 降低"新 CPU + 新平台 + 新工具链"同时调试的风险；顺序核可作乱序核的黄金模型 | 直接上乱序：一旦 Linux 启动失败难以定位 |
| D3 | 分支预测器：**Gshare + 局部 + 选择器**（4096 项级） | 任务明确要求锦标赛 | 单一 TAGE：复杂度高、验证成本大 |
| D4 | Cache：L1I 16 KB/4 路、L1D 32 KB/8 路、L2 256 KB/8 路，行 32 B，VIPT 别名安全 | VIPT 满足"组数×行 ≤ 4 KB"即无别名；L2 吸收 33 MHz uncore 的低带宽 | 全 PIPT：取指路径多一级；无 L2：DDR 带宽不足 |
| D5 | **CLINT + PLIC 放在核内**（地址 `0x1F00_0000`/`0x1F10_0000`，核内截获，不下 AXI） | 不改 SoC 顶层；FPGA 与仿真行为一致；可直接用内核标准驱动 | 新增 SoC 从设备：需改平台 RTL 与工程 |
| D6 | 软件栈：**OpenSBI(M) + U-Boot(S) + Linux(S, Sv32)** | 内核 `RISCV_M_MODE` 隐藏且 `default !MMU`，RV32+MMU 必须走 SBI | M 模式 Linux：该内核树不支持 |
| D7 | 内核基线用 **`la32r-Linux` 中现成的 `arch/riscv`**（不改造 `arch/loongarch`） | 该 `arch/riscv` 已支持 RV32/Sv32；`arch/loongarch` 的 CSR/异常/MMU 模型完全不同 | 改造 `arch/loongarch`：工作量与风险都高一个量级 |
| D8 | U-Boot 基线用 **`la32r-uboot` 中现成的 `arch/riscv`**，新增 board | 同上；原生 RV32 板（`qemu-riscv32_smode`）可直接作种子 | 自建新树：失去平台参考 |
| D9 | NAND 驱动**新写**（内核 + U-Boot 两份），DMA 走平台引擎 | U-Boot 完全没有 NAND；内核驱动硬编码 KSEG 别名、ECC 关闭、分区冲突 | 直接搬内核驱动：在 RISC-V 上不可用 |
| D10 | 上游源码树**不复制**，用"补丁序列 + 新增文件 + 构建脚本"管理 | 上游树体量大且已有独立 git；本项目保持独立可复现 | 复制整树：仓库膨胀、难以追踪差异 |
| D11 | 仿真环境**自建**（iverilog + verilator），不复用平台 difftest | 平台 difftest 依赖 LA32R NEMU，且退出机制为 LA32R 专有 | 复用平台流程：无法用于 RV32 |
| D12 | 参考模型用 **Spike**（自行编译） | arch-test 需要参考签名；Spike 可输出提交级轨迹用于锁步比对 | Sail：OCaml 依赖重；NEMU：仅 LA32R |
| D13 | 乘法器用 DSP48E1（`*` 推断），除法器/浮点自研 | 避免 `div_gen`/`floating_point` IP 的仿真依赖（Verilator 无法编译 .xci）；面积与延迟可控 | 直接例化 IP：仿真环境受限 |
| D14 | 分区统一定义为 `256K(env),50M(kernel)ro,1M(dtb),-(rootfs)` | 解决参考实现/DTS/文档三处冲突，且避免环境变量与内核镜像冲突 | 沿用 50M@0：env 无处安放 |

---

## 3. 阶段划分与计划

### 阶段一：设计方案 + 移植方案 + 知识库 + 本文件 + 指导 Prompt ✅（本次完成）

**目标**：完成全部设计决策，形成可执行的分阶段计划，建立知识库，明确移植工作量与风险。

**交付物**：
- `docs/design/00~08*.md`（总体架构、流水线、分支预测、Cache、CSR/MMU、乱序、总线、FPGA 时序、验证）+ `docs/design/diagrams/*.dot|svg`（结构图与数据通路图）
- `docs/porting/00~05*.md`（总览、U-Boot、Linux、驱动、NAND、根文件系统）
- `docs/kb/01~07*.md`（移植知识库，并已注册进常驻知识库供 `kb_search` 检索）
- `AGENT.md`（本文件）、`PROMPT.md`（指导 AI 完成整个项目的提示词）、`README.md`
- git 仓库初始化与首次提交

**验收标准**：用户审阅通过，明确认可设计参数（发射宽度、Cache 容量、乱序结构、软件栈）与阶段计划。

**状态**：已完成文档，等待用户审阅。

---

### 阶段二：CPU 设计与实现（分三个子阶段）

#### 阶段 2A：顺序 5 级基线核（RV32GC + CSR/特权 + 基础 Cache + AXI）

**目标**：先把"指令集 + 特权级 + 总线 + 工具链 + 仿真环境 + 上板流程"全部打通，得到一个能跑裸机测试与 arch-test 的单发射核。

**任务清单**
1. 环境准备：安装/编译 verilator+iverilog；编译 Spike；建立 `sim/tb` 仿真环境与回归脚本。
2. RTL：`core_top` 平台壳（AXI 主设备 + 调试端口）→ 5 级流水（IF/ID/EX/MEM/WB）→ RV32IMAFDC 译码与执行（含 RVC）→ CSR/PMP/异常中断 → Sv32 MMU（TLB+PTW）→ L1I/L1D → L2 → AXI 桥。
3. 单元测试：ALU/MDU/FPU/Cache/TLB/CSR/AXI。
4. 集成测试：arch-test 非特权子集（I/M/A/F/D/C/Zicsr/Zifencei）+ 基础特权测试 + 自研裸机用例。
5. FPGA：`fpga/build_chiplab.tcl`（生成工程/综合/实现/bitstream），上板 B1~B3。

**验收标准**：arch-test 非特权子集全绿；裸机内存测试（128 MiB，含非对齐）通过；上板串口有输出、数码管显示正确；60 MHz 时序收敛。

**预计工作量**：8~12 人日（其中仿真环境 2 日、RTL 5~8 日、上板 1~2 日）。

#### 阶段 2B：4 发射乱序后端

**目标**：把 2A 的顺序后端替换为"重命名 + ROB + 发射队列 + LSQ"，实现 4 发射乱序执行；与 2A 的顺序核做锁步比对。

**任务清单**
1. 重命名级（RAT/空闲表/checkpoint）、ROB 128 项、提交逻辑。
2. 三类发射队列（整型 32/访存 24/浮点 16）+ 唤醒选择 + PRF（128×32 + 128×64）+ 旁路网络。
3. LSU/LSQ（32+32）、store 提交、store→load 转发、违例重放、原子指令。
4. 锦标赛分支预测器 + BTB + RAS（`02-branch-predictor.md`）。
5. 顺序/乱序锁步测试、压力测试、性能计数。

**验收标准**：锁步比对在随机指令流上连续 ≥10^8 条指令无差异；CoreMark/Dhrystone 正确；100 MHz（或降级档）时序收敛。

**预计工作量**：15~25 人日。

#### 阶段 2C：存储与特权完善 + Linux 启动

**目标**：完善 L2/预取/Zicbom/CLINT/PLIC，跑通 OpenSBI + Linux 到 shell。

**验收标准**：OpenSBI banner、U-Boot（先用 QEMU/临时方案）或直接 `fw_payload` 启动 Linux 内核到 initramfs shell。

**预计工作量**：8~12 人日。

---

### 阶段三：U-Boot 移植

**目标**：U-Boot 在 RV32-GC 上启动，支持 NAND 读写与环境变量保存，并能从 NAND 自动启动内核。

**任务清单**
1. 新增 `board/loongson/chiplab/`、`configs/chiplab_rv32_defconfig`、`include/configs/chiplab_rv32.h`、`arch/riscv/dts/chiplab_rv32.dts`（见 `docs/porting/01-uboot.md`）。
2. NAND 驱动（`drivers/mtd/nand/raw/chiplab_nand.c`）+ DMA + cache 维护（Zicbom）。
3. `CONFIG_ENV_IS_IN_NAND` + `bootcmd` + MTD 分区。
4. 先在 QEMU 验证框架，再上板；完成 `docs/porting/04-nand.md` §9 的 N1~N7。

**验收标准**：串口命令行可用；`mtd list` 显示 4 个分区；`mtd write/read` + `cmp` 通过；`saveenv` 掉电保留；`bootcmd` 自动从 NAND 加载内核。

**预计工作量**：5~8 人日（NAND 驱动 3 日）。

---

### 阶段四：Linux 内核与驱动移植

**目标**：内核从 NAND 启动到用户态 shell；串口/定时器/中断/NAND 驱动工作正常。

**任务清单**
1. 新增 `arch/riscv` 的 `SOC_CHIPLAB`、DTS、`rv32_chiplab_defconfig`（见 `docs/porting/02-linux.md`）。
2. NAND MTD 驱动（`chiplab_nand.c`）+ 分区 + 软件 BCH ECC。
3. OpenSBI 集成（`fw_dynamic` 或 `fw_payload`）与启动参数。
4. 内核调试（earlycon → shell → 驱动探测 → 稳定性）。

**验收标准**：`dmesg` 无异常；`/proc/interrupts` 显示 PLIC 中断；NAND 分区可读写且校验一致；内核 `make -j` 编译不崩（稳定性）。

**预计工作量**：5~8 人日。

---

### 阶段五：根文件系统与系统联调验收

**目标**：可用的根文件系统（initramfs → UBIFS），完成全部上板验收与性能测试。

**任务清单**
1. busybox + initramfs；UBIFS on NAND（第二阶段）。
2. 掉电恢复测试、长时间压力测试。
3. 性能测试（CoreMark/Dhrystone/unixbench）与优化（如需）。
4. 交付物整理：RTL、测试、补丁、镜像、bit、文档、复现脚本。

**验收标准**：见 `docs/porting/05-rootfs.md` §6；`README.md` 中的"一键复现"脚本可用。

**预计工作量**：4~6 人日。

---

## 4. 总体时间安排（滚动更新）

| 阶段 | 主要产出 | 预计工作量 | 关键依赖 |
|---|---|---|---|
| 一 | 方案 + 知识库 + AGENT/PROMPT | 1~2 人日 | 用户审阅 |
| 2A | 顺序基线核（上板） | 8~12 人日 | verilator/iverilog 安装、Spike 编译 |
| 2B | 4 发射乱序核 | 15~25 人日 | 2A 完成、锁步环境 |
| 2C | 存储/特权完善 + Linux 启动 | 8~12 人日 | 2B（或 2A）完成 |
| 三 | U-Boot + NAND | 5~8 人日 | 2C 通过、NAND 硬件可用 |
| 四 | Linux 内核 + 驱动 | 5~8 人日 | 阶段三完成 |
| 五 | 根文件系统 + 验收 | 4~6 人日 | 阶段四完成 |
| **合计** | | **46~73 人日** | |

**并行机会**：阶段三的 U-Boot 板级/DTS/驱动框架可先在 QEMU 上开发，与阶段 2B 并行；阶段四的内核配置/DTS/驱动同样可先在 QEMU/Spike 上验证。

---

## 5. 阶段交接规则（强制）

1. **每阶段结束**：必须在本文件 §6（阶段总结）追加该阶段总结，并在 §7 更新"下一阶段任务与计划"，然后**停止执行**，等待用户明确指令（例如"开始阶段 2A"）后再继续。
2. **每阶段开始**：先读本文件 §2（决策）、§6/§7（上一阶段总结与计划），并按需用 `kb_search` 检索 `docs/kb/` 与 ISA 手册，避免重复推导。
3. **长上下文管理**：
   - 设计细节写进 `docs/design/`，移植细节写进 `docs/porting/`，新知识写进 `docs/kb/`（并 `kb_manage action=reindex`）；
   - 每阶段结束提交 git（提交信息格式：`<阶段>: <摘要>`）；
   - 关键决策写入 `memory_write`，便于跨会话恢复。
4. **问题上报**：需要权限、需要外部操作（如安装软件包）、或发现需求冲突时，用中文向用户提问，并给出可选方案与推荐项。

---

## 6. 阶段总结（按时间追加）

### 阶段一总结（方案与知识库）

**完成内容**
1. **平台调研**：通过三个并行子代理完成 chiplab 集成契约、`la32r-uboot` 移植面、`la32r-Linux` 移植面的详查，产出三份报告（工作区根目录 `chiplab-integration-report.md`、`uboot-porting-report.md`、`linux-porting-report.md`）与 arch-test 调研报告。
2. **关键发现**：
   - `IP/myCPU` 为空子模块，CPU 契约（`core_top` 端口）与地址映射已明确；
   - 仿真与 FPGA 的 CONFREG 地址/偏移**不同**；CPU 时钟 50 MHz（`FREQ` 宏却是 33 MHz）；平台 AXI 32 位、4 bit len；
   - `la32r-Linux`（5.14-rc2）与 `la32r-uboot` **都自带可用的 `arch/riscv` RV32 支持** → 软件移植工作量大幅降低；
   - NAND 控制器寄存器映射完整（可直接写驱动），但**数据必须走平台 DMA 引擎**且无 Cache 一致性；参考驱动 ECC 全关、硬编码 KSEG 别名、分区三处冲突；
   - 平台 difftest 依赖 LA32R NEMU → RV32 需自建验证环境。
3. **设计交付**：9 份设计文档 + 4 张结构图/数据通路图（Graphviz → SVG），覆盖流水线、锦标赛分支预测、三级 Cache、CSR/MMU/CLINT/PLIC、乱序微架构、AXI 总线、FPGA 时序与验证方案。
4. **移植交付**：6 份移植方案文档（总览、U-Boot、Linux、驱动、NAND、根文件系统），含文件级工作清单、配置项、命令与验收判据。
5. **知识库**：7 份知识点文档（平台硬事实、RISC-V 启动链、NAND 速查、U-Boot/Linux 移植知识、工具链构建、仿真调试），已注册进常驻知识库（`rv32gc-project` 源）供 `kb_search` 检索。
6. **项目骨架**：`rv32gc-cpu/` 独立 git 仓库，含 `docs/`、`rtl/`、`sim/`、`sw/`、`fpga/`、`scripts/` 目录规划与本文件。

**已确认的需求澄清**
- "4 个标量及以上" → **4 发射超标量**（用户确认）；
- 仿真工具 → **用户在沙箱外 `apt install verilator iverilog`**（用户确认，**已安装完成**：Verilator 5.020 + Icarus Verilog 12.0 已验证可用）；
- 设计方案参数 → **用户已审阅通过**（4 发射、Cache 容量、乱序结构、软件栈）。

**阶段一补充更新（2026-09-13，依据 `实验箱A7-原理图.pdf`）**
- **NAND 芯片确认**：位号 U8 = **K9F1G08U0C-PCB0**（Samsung 1 Gbit SLC，3.3 V，x8）——容量 **128 MiB**，页 **2048 + 64 B**，块 **128 KiB（64 页）**，共 1024 块，**ECC 要求 1 bit / 512 Byte**（片内 Copy-Back EDC 1 bit/528 B），tR 25 µs(max)、tPROG 200 µs(typ)、tBERS 1.5 ms(typ)，器件 ID `0xEC`/`0xF1`（与 Linux `nand_ids.c:107` 的 "NAND 128MiB 3,3V 8-bit" 一致）。
  → **与平台 RTL `nand_type=2'h2`、参考驱动几何 gate（128 KiB/2048/64）完全吻合，无需放宽**；ECC 用软件 BCH-4（或 Hamming）即可满足器件规范。
- **其他板级确认**：DDR3 = K4B1G1646G-BCK0（1 Gbit = **128 MiB**，与内核 DTS `/memory` 一致）；SPI NOR = S25FL128SAGMFI001（128 Mbit = 16 MiB，DIP 插座，存放 PMON/u-boot）；板级输入时钟 100 MHz。
- 已更新文档：`docs/kb/01-chiplab-platform.md`（新增板级硬件清单）、`docs/kb/03-nand-controller.md`（新增芯片身份与 ECC 结论）、`docs/porting/04-nand.md`（ECC 策略与几何校验落定）、`docs/porting/00-overview.md` 与 `03-drivers.md`。

**未决/待验证事项（带入阶段二）**
- CONFREG 仿真/FPGA 两套地址的最终取舍（仿真 TB 采用 FPGA 地址 + 仿真便捷寄存器）；
- NAND 控制器 `PARAM` 寄存器语义、硬件 ECC 寄存器语义、坏块标记位置、`TIMING=0x205` 取值依据（均已降级为"实测确认"项，不再阻塞设计）；
- FPGA 工程 tcl 生成与 Vivado 2025.2 许可/工程升级；
- 100 MHz 时序收敛风险（保留 4 项降级措施，其中降为双发射需用户批准）。

---

## 7. 当前状态与下一阶段计划

**当前状态**：阶段一已完成，**等待用户审阅与"开始阶段二"的明确指令**。

**下一阶段（阶段 2A）任务与计划**

| 步骤 | 任务 | 产出 | 完成判据 |
|---|---|---|---|
| 2A-1 | 仿真工具链落地：确认 verilator/iverilog 可用；编译 Spike；建立 `sim/` 目录与回归脚本 | `sim/tb/*`、`scripts/regress.sh` | 一个 LED 闪烁/计数器 RTL 能在 iverilog 与 verilator 下跑通 |
| 2A-2 | 平台壳与总线：`core_top`（AXI4 主设备 + 调试端口 + 时钟复位同步）、`axi_mem_model`、`soc_sim_top` | `rtl/top/`、`rtl/bus/`、`sim/tb/soc_sim_top.v` | 裸机程序能通过 AXI 读写内存与 CONFREG |
| 2A-3 | 5 级顺序流水：RV32IMAFDC 译码/执行（含 RVC）、冒险处理、CSR/异常、PMP | `rtl/frontend|decode|exec|csr/` | 通过自研指令级单元测试 |
| 2A-4 | MMU（Sv32 TLB+PTW）与 L1I/L1D、L2 | `rtl/mmu/`、`rtl/mem/` | Cache/TLB 单元测试通过 |
| 2A-5 | arch-test 接入（Spike 生成签名）+ 自研裸机测试框架 | `sw/tests/`、`sim/log` | I/M/A/F/D/C/Zicsr/Zifencei 子集全绿 |
| 2A-6 | FPGA 工程脚本与上板 | `fpga/build_chiplab.tcl`、bit 流 | 串口输出 + 数码管正确 + 60 MHz 收敛 |

**阶段二开工前需要用户确认/配合的事项**
1. ~~在沙箱外执行 `sudo apt install verilator iverilog gtkwave`~~ → **已完成**（Verilator 5.020 / Icarus Verilog 12.0 已就绪，`xvlog/xelab/xsim` 亦可用）；
2. ~~确认阶段一设计参数~~ → **已审阅通过**；
3. ~~提供实验箱 NAND 芯片型号/丝印~~ → **已由原理图确认**（K9F1G08U0C-PCB0，见阶段一补充更新）；
4. 仅剩一项待用户指令：**"开始阶段 2A"**。收到后按 §7 的 2A-1 → 2A-6 顺序执行。
