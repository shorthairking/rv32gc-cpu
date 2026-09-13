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
| D15 | **平台适配（不做 AXI 编址改造）**：核**不改**平台 AXI 地址映射；RISC-V 侧靠"三处约定"适配：① 上板复位向量取平台启动窗口 `0x1C00_0000`（SPI-XIP/SRAM，`RESET_PC` 为编译期宏）；② 镜像/软件按平台 DDR `0x0000_0000` 链接加载（RISC-V 习惯的 `0x8000_0000` 不适用；`0x8000_0000` 仅仿真里给 arch-test 用）；③ RISC-V 期望的 CLINT/PLIC `0x0200_0000/0x0C00_0000` 平台没有 → 用 D5 的**核内 CLINT/PLIC（`0x1F00_0000/0x1F10_0000`）**，并在 DTS/OpenSBI 参数与文档中显式声明 | 依据平台硬事实：DDR3 是 **AXI 默认从设备，位于 `0x0–0x07FF_FFFF`**；`0x1C00_0000` 只是 1 MiB 启动窗口；CONFREG/UART/NAND 是 SoC 设备窗口（`docs/kb/01-chiplab-platform.md` §3、`docs/design/00-overview.md` §2.2）。**AXI 编址与指令集无关**，ISA 也不规定物理地址映射，故"为符合 RV32 而改 AXI 编址"既不必要也不正确 | 直接改平台 RTL/约束：改 SoC 顶层与工程、失去平台复用，且与 LA32R 参考实现冲突 |

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

### 阶段一补充之二：设计细化（微架构规格书，2026-09-13）

用户选择"先细化设计再开工"，因此把方案级设计细化为**可直接照着写 RTL 的规格书**。

**交付物（`docs/design/spec/`，共 10 篇，约 4700 行）**

| 文件 | 内容 | 规模 |
|---|---|---|
| `spec/README.md` | 阅读顺序、唯一真源、一致性规则、RTL 开发顺序 | 39 行 |
| `spec/00-conventions.md` | 编码风格、时钟复位、握手/清空协议、参数、目录规划、调试接口 | 244 行 |
| `spec/02-uop-and-decode.md` | **uop 控制位 73 位定义**、RV32IMAFDC+Zicsr/Zicbom 译码表、RVC 展开、立即数、译码期异常 | ~200 行 |
| `spec/03-pipeline-regs.md` | 流水级寄存器、跨模块 bundle、IQ/ROB/LSQ 表项、重命名结构、`core_top` 端口 | 250 行 |
| `spec/04-frontend.md` | PC 生成、锦标赛 BPU（表项/更新伪码/恢复）、I-Cache（MSHR/FSM）、取指队列、RVC 对齐 | 570 行 |
| `spec/05-ooo-core.md` | 重命名/ROB/IQ/唤醒选择/PRF/旁路、4 宽提交、精确异常与恢复（含 ROB 反走伪码） | 561 行 |
| `spec/06-lsu-mem.md` | AGU/LSU/LSQ/转发/重放/D-Cache（8 MSHR）/L2/预取/原子/`cbo.*` | 577 行 |
| `spec/07-priv-csr-mmu.md` | 逐 CSR 字段表、异常优先级、trap/`mret`/`sret`、TLB/PTW/PMP、CLINT/PLIC（179 处规范原文引用） | 500 行 |
| `spec/08-bus-axi.md` | AXI 读/写引擎 FSM、非缓存通道、地址解码、错误处理、平台集成清单 | 572 行 |
| `spec/09-verification-interface.md` | 仿真环境、**提交级 trace 格式（与 Spike 对齐）**、81 条断言、41 项单元测试、覆盖点 | 698 行 |

**配套实现产物**：`rtl/pkg/rv32gc_defs.vh`（宏与位域的唯一真源，已通过 `iverilog -g2005` 编译与 `verilator --lint-only` 检查，并用测试程序验证 `CTRL_GET`/`IS_YOUNGER`/`AXI_BEATS_PER_LINE` 展开正确）。

**本轮裁定并已同步到各文档的跨文档冲突（4 条）**

1. **BPU 读延迟**：BTB/PHT/LHT 用 BRAM 同步读（IF0 送址、IF1 出结果），预测在 **IF2 用于取指块截断**，稳态无气泡 → 不需要把 BTB 改成分布式 RAM（已改 `01-pipeline.md` §7 并加结论说明）。
2. **LSU 违例 replay 语义**：清空范围 = **该 load 自身及其全部更年轻指令**（`flush_rob_idx = load.rob_idx - 1`），复用分支误预测的恢复硬件，不保留 load（已改 `05-ooo.md` §6，与 `spec/06` 一致）。
3. **PRF 写口冲突**：改为"压制重试 + 唤醒照常广播"，不插入流水线停顿（已改 `01-pipeline.md` §2.4）。
4. **FMA 第三源**：`uop_ctrl_t` 由 72 位扩为 **73 位**，新增 `use_rs3`，并补 `rs3_arch[4:0]`/`ps3[6:0]`（已同步 `rv32gc_defs.vh`、`spec/02`、`spec/03`）。

5. **非缓存（设备）访问时机**：采用 **ROB 头部门控**——非缓存 load/store 只在 `rob_idx == rob_head` 时发往 `uncached_unit`，发出后不重放；**不是**"提交后才发"（会死锁）。理由：平台设备有读副作用（UART RBR/IIR 读清、NAND 数据口、仿真 VIRTUAL_UART），头部门控既杜绝投机副作用，又保证该访问不会被更年轻指令的清空干掉（`spec/08-bus-axi.md` §9.4b D-1）。
6. **AXI 端口归属**：`l2_cache.v` **不**直接暴露 AXI；L2 经 refill/victim 队列连 `axi_bridge`，**非缓存单元直接连桥**（不分配 L2 行）；设备访问 `awcache/arcache = 4'b0000`（D-2/D-3）。
7. **RV32 的 Zcd**：RV32 下 Zcd 提供的是**压缩浮点双精度访存**（`c.fld/c.fsd/c.fldsp/c.fsdsp`），整数 `c.ld/c.sd` 属 RV64 专有（已修正 `spec/02` §4.6）。
8. **性能计数器**：`mhpmcounter3..7` 实现为真实计数器（分支数/误预测/L1D 缺失/L1I 缺失/L2 缺失，事件硬连线，`mhpmevent3..7` 只读 0），`mhpmcounter8..31` 读 0（已更新 `04-csr-mmu.md`）。
9. **`cbo.clean/flush` 语义**：必须把数据**推过 L2 直达 DDR** 并在完成前阻塞提交，否则非一致性 DMA 会读到旧数据（已写入 `03-cache.md`）；同时记录"平台无 snoop"的已知限制（DMA 对 LR/SC 保留集不可观测、AMO 与 DMA 无原子性保证，需软件回避）。

**FPGA 时钟方案（2026-09-13 依用户要求定稿）**

- **实测平台时钟**：`clk_pll_33` 为 **PLLE2_ADV**（`PRIM_IN_FREQ=100 MHz`、`DIVCLK_DIVIDE=2`、`CLKFBOUT_MULT_F=33` → **VCO=1650 MHz**；`CLKOUT0_DIVIDE_F=33` → `cpu_clk`=50 MHz；`CLKOUT1_DIVIDE=50` → `uncore_clk`=33 MHz）。原文档"CLKOUT2..7 已是 100 MHz"的说法**不成立**（那是未用输出的默认请求值）。VCO=1650 MHz 可能超过 Artix-7 **-2** 的 PLLE2 上限（约 1600 MHz），属**平台既有疑点**，阶段五首次综合时用 DRC/`report_clocks` 核实。
- **用户要求**：`cpu_clk` **不得**直接使用晶振输入，必须经 Vivado **Clocking Wizard（MMCM/PLL）**产生，以获得稳定、可控、带锁定指示的时钟。
- **采用方案**：新增 Clocking Wizard IP **`clk_wiz_cpu`（MMCM）**，输入板级 100 MHz，`DIVCLK_DIVIDE=1` + `CLKFBOUT_MULT_F=12.0` → **VCO=1200 MHz**（-2 器件 MMCM 范围 600~1440 MHz，余量充足），`CLKOUT0_DIVIDE_F=12.0` → **100 MHz**；`locked` 与外部 `resetn` 相与做复位门控；频率可用 `CPU_CLK_MHZ` 配为 **50/60/75/100** 以支持降级。平台 `clk_pll_33` **不改动**（仅继续用其 `clk_out2` 提供 uncore 33 MHz，`clk_out1` 弃用）。
- **SoC 顶层**：平台 `soc_top.v` 把 `cpu_clk` 硬连到 `clk_pll_33/clk_out1`，故本项目保留**最小差异副本** `fpga/rtl/soc_top_rv32gc.v`（仅时钟块 + CPU 例化不同，其余逐行一致），并在 `fpga/README.md` 给出与平台文件的 diff 说明以便复核/同步。
- **零 RTL 改动备选**：把平台 `clk_pll_33.xci` 复制到本项目并改为 MMCM 同时输出 100 MHz 与 uncore 时钟，模块名/端口名不变 → `soc_top.v` 无需修改；代价是 33 MHz 只能取 `1200/36.375 = 32.99 MHz`（偏差 0.03%，无功能影响）。

**同时修正的 ISA 准确性问题**（由 `spec/07` 的规范比对发现，已改 `04-csr-mmu.md`）：`pmpcfg` 在 RV32 只有 `0x3A0–0x3A3`（4 个寄存器 / 16 项）；`mstatus` 位图按规范补全（含 `TVM/TW/TSR`、`XS/VS`、`SD`）；`mret/sret` 的 `MPRV` **仅在返回目标 ≠ M 时清 0**；A/D 位更新必须对 PTE **原子 CAS 且不得使用翻译缓存**，写回违例报**访问错误**。

**未决/待验证事项（带入阶段二，均不阻塞开工）**：`PARAM`/硬件 ECC/坏址标记/`TIMING` 取值（上板实测）；FPGA 工程 tcl 与 Vivado 2025.2 许可；100 MHz 时序收敛（4 项降级措施，降为双发射需用户批准）。

### 阶段 2A 进展（2026-09-13，进行中）

**已完成**
| 项 | 内容 | 证据 |
|---|---|---|
| 仿真环境 | `sim/tb/sim_axi_slave.v`（单从设备 AXI 模型：mem_lo/mem_hi/CONFREG 双窗口/UART/tohost）+ `tb_smoke.v` + `run_sim.sh` | `AXI_SLAVE_UNIT: PASS (79 checks)`；`RV32GC_NO_CORE=1` 通路自测 PASS |
| 参考模型 | Spike 1.1.1-dev 源码编译（`tools/spike-install`） | `spike --isa=rv32imac` 可运行 RV32 ELF |
| 译码器 | `rtl/decode/rv32_decoder.v` + `rv32_imm_gen.v`（RV32IM+A+Zicsr+SYS+Zicbom+全部 Zca） | `DECODER_UNIT_TESTS: PASS (257 vectors)` |
| 执行单元 | `rtl/exec/rv32_alu.v`、`rv32_bru.v`、`rv32_mul_div.v` | `EXEC_UNIT_TESTS: PASS (2461 checks)`（含 26 个注入缺陷全部被捕获） |
| 核骨架 | `rtl/top/core_top.v`（平台端口契约）+ `rv32gc_core.v`（IF/ID/EX/MEM/WB）+ `rv32_axi_master.v` + `rv32_ifetch.v` + `rv32_regfile.v` + `rv32_csr.v` | **`SIM: PASS hello`**：真实编译的 C 程序经完整 AXI 通路打印 `Hello RV32GC` 并正常退出（353 拍） |
| arch-test 通路 | `scripts/arch_test_build.sh` + `sim/arch_test/config/*`（link.ld 固定 tohost@0x8000_1000、UART/CLINT 地址改本平台） | 真实参考签名由 Spike 生成并编译进自校验 ELF：`I-add-00.elf` 构建成功 |
| 非对齐访存 | MEM FSM 两次单拍拆分（跨 4B 边界自动拆分 + 字节级合并） | hello 仍 PASS；memtest 已能跑过打印阶段 |

**本阶段修复的关键缺陷（均经仿真定位）**：I-Cache 行内半字位偏移错（idx*2 当成位索引）、行标签比较用完整地址比行号、flush 与 AXI 响应同拍导致 busy 永久卡死、JAL 在 EX 被误清导致 ra 未写、ecall/ebreak 未按 op_class 门控、AXI 读响应握手自取消（d_rsp_valid 永不为 1）、load-use 停顿冻结整条流水导致死锁（改为只冻结前端 + EX 插气泡）、mstatus/sstatus 拼接位宽错（41/33 位截断）。

**已解决（锁步定位 → 修复）**：`memtest` 通过。用 `scripts/lockstep.sh` + `lockstep_diff.py` 比对 Spike 提交轨迹，首个分歧定位到 `crt0` 的 `bgeu t0,t1` 方向错误，根因是 **WB→ID 旁路缺失**——寄存器堆在 posedge 写入、ID 为组合读，当生产者处于 WB 而消费者同拍处于 ID 时会读到旧值（经典"写优先寄存器堆"漏洞；长停顿场景必现）。修复：在 ID 读端口显式旁路 WB 写数据（`id_byp_a/b`），此后**前 287 条提交与 Spike 完全一致**，`memtest` 由 FAIL 转 PASS。

**当前状态**：`SIM: PASS hello` / `SIM: PASS memtest` / `AXI_SLAVE_UNIT: PASS (79)` / `EXEC_UNIT_TESTS: PASS (2461)` / `DECODER_UNIT_TESTS: PASS (257)`。

**arch-test 接入进展（本轮用锁步连续定位并修复 3 个缺陷）**：
- `sim/tests/arch_stub.S`（0x0 → `lui t0,0x80002; jr t0`）+ 镜像重定位已完成；arch-test 的 CLINT/UART 地址在阶段 2A 指向已映射 scratch（避免引入未实现的 CLINT）。
- 锁步发现并修复：① **CSR 写地址错位**（`wb_csr_addr_q` 误接 MEM 级信号 → CSR 写落到错误地址）；② **CSR RAW 冒险**（`csrr` 在 ID 组合读，早于前一条 `csrw` 的 WB 写 → 读到旧值；已按 `ctrl.is_serial` 对 CSR/系统指令做"等流水线排空"的顺序化停顿）；③ **转发网络遗漏 CSR 写回**（MEM 级转发用 `mem_alu_q` 而非 `mem_csr_rdata_q`，导致 `csrr` 的消费者拿到垃圾值）。
- 修复后：`I-add-00` 的**前 378 条提交（≥0x8000_0000，PC/rd/wdata）与 Spike 完全一致**。

**第 4 轮（goal round 4）结论 —— I-add-00 仍未跑完，已定位到两个具体现象（下一步的入口）**：

1. **周期数远超预期**：把 TB 超时提到 **3000 万拍**仍在 25 分钟内未完成（`RV32GC_TIMEOUT=30000000 bash scripts/run_sim.sh I-add-00` → `TB: TIMEOUT`）。本核无 Cache，arch-test 全量签名比较规模大，但 30M 拍仍不够说明还有停滞。
2. **仿真在特定阶段极慢 + 出现陷阱**：用增强的调试 TB（`sim/tb/tb_debug_min.v`，本次新增每 500 拍 STATE 打印与 `CSRID`/`CSRW` 观测）得到：
   - `STATE cyc=1000/1500: pc=8000652c | IDpc=80006528 | EXpc=80006524 | MEMpc=80006520 memst=2(M_WAIT) | WBpc=8000651c`，`front_hold=1`
     → **PC 落在 0x8000_65xx（rvtest 陷阱处理程序区），说明测试确实在反复进陷阱**；MEM 处于 `M_WAIT` 等 AXI 响应；同时 `front_hold=1`（CSR/系统指令顺序化停顿）持续多拍。
   - `STATE cyc=2000: pc=80046840` → 已回到测试主体，说明陷阱能正确返回。
   - 240 秒挂钟只推进到约 2000 拍（≈20 拍/秒），远慢于 `hello`（353 拍秒级完成）与 `memtest`（约 10^5~10^6 拍数分钟）→ **强烈怀疑存在组合环/零时间振荡**（在 `front_hold` 或 `M_WAIT` 期间每拍产生大量 delta 周期），或某个访问路径反复重试。
   - 提交轨迹最后停在 `C1991 pc=80046824 / C1993 pc=8004682c`（0x8004_682x 附近的签名计算循环）。

**下一轮的第一步（已备好工具与命令）**：
```bash
# 1) 先确认是否组合环：把 STATE 打印改为每 1 拍（临时），看 cyc 是否推进
#    或对 cyc=1990~2010 区间 dump VCD 观察；同时用 verilator --lint-only 检查组合环告警
# 2) 拉长锁步：debug TB 的周期上限已放宽，用
bash scripts/lockstep.sh sim/arch_test/out/I-add-00.elf 20000   # 需要 0x8000_0000 布局的 ELF
#    或直接用现有 mem_hi 镜像跑 tb_debug_min 并把 RTL 轨迹扩大到 ≥5000 条提交
# 3) 定位到具体指令后用 Spike 的 --log-commits 对照该 PC 附近的期望行为
```

### 阶段 2A 进展（第 5 轮，2026-09-13）：arch-test 打通 79/80，锁步 5994 条

**本轮结论（推翻上一轮的"组合环"猜测）**：`verilator --lint-only` 无组合环告警；实测 iverilog 仿真
速度正常（约 10⁴ 拍/秒，I-add-00 全程 28206 拍）。上一轮"20 拍/秒"的观测不可复现（那是调试 TB 的
硬编码 2000 拍出口 + Spike 执行时间被计入）。真实原因是 6 个具体 RTL 缺陷，全部用"提交轨迹 + 参考
模型/失败用例定位"逐一查清并修复：

| # | 缺陷（位置） | 现象与根因 | 证据 |
|---|---|---|---|
| 1 | 前端跨行 32 位取指（`rv32gc_core.v`） | 32 位指令落在 32 B 行末半字时 `need_cross=1` → `if_ready=0` → `advance_all=0`，而 `cross_q` 置位又被 `advance_all` 门控 → 永久死锁（I-add-00 在 `pc=0x8000207e` 冻结，100 万拍零推进）。修：`fetch_stall=!line_valid`；PC 推进与 cross 状态拆分门控 | `tb_prof` 现场：`need_cross=1 if_ready=0 cross=0` |
| 2 | JALR 非对齐误判 | 用 `ex_addr[1]`（4 B 对齐）报 cause=0；实现 Zca 后 IALIGN=16，规范 `zca.adoc` norm:Zcanomisaligned 明确"任何指令都不会产生该异常" | 旧 TRAP 行 `cause=0 tval=80005132` |
| 3 | 分支重定向未门控（`ex_br_redirect`） | WB→EX 旁路挂在 `wb_retire`(含 `advance`) 上，流水线冻结拍旁路失效，EX 中分支却仍用**过期操作数**判定并重定向（`c.lw/c.lw/bne` 序列跳错方向） | 对照 Spike 的 x23（签名指针）写入序列定位 |
| 4 | 状态机漏发请求（`d_req_valid`） | 非对齐拆分第二次访问（`M_REQ2`）未拉高 `d_req_valid` → 等不到 `d_req_ready`，FSM 卡死（Zifencei/Zca 用例停摆） | `tb_prof`：`memst=4`（M_REQ2）长期不动 |
| 5 | MDU 集成（`mdu_hold`）+ WB 旁路 | `mdu_hold` 在 start 拍不保持 → 结果未算出就流出 EX（M 组 8/8 全错）；且 start 拍锁存操作数时流水线被冻结、`wb_fwd_en` 被 `wb_wen`(含 advance) 门控 → 采到 load 旧值。修：`mdu_hold = … && !mdu_done`；转发只看"WB 有有效值" | M-mul-00 首用例 `mul` 结果 0 → 0x59012226 → 正确 |
| 6 | 压缩跳转链接值 + FENCE.I 保留字段 | 链接值恒 `pc+4`，压缩 `c.jal/c.jalr` 应为 `pc+2`（新增 ilen 流水寄存器）；译码器把 `fence.i` 的 rs1/rd 非零判非法，规范 `zifencei.adoc` 要求"shall ignore these fields" | Zca-c.jal-00（x1=0x8000302c 应为 0x8000302a）、trap `cause=2 tval=0001100f` |

**同时修正的验证环境问题（非 RTL）**：① 桩 `arch_stub.S` 未铺满一整条 32 B 取指行，镜像空洞读到 `x`
会经 `ilen` 把 PC 污染成 `x`（真实内存不会）；② 仿真内存模型把未初始化字节按 0 读出；
③ `scripts/arch_test_build.sh` 生成参考签名时错误地把 `_zicntr/_zifencei` 从 Spike 的 ISA 串剥掉，
使参考把 `csrrs instret`/`fence.i` 当非法指令（Zicsr 组曾 4/6 FAIL、Zifencei 陷阱计数不符）。

**本轮验收证据（全部实测）**

| 项 | 结果 |
|---|---|
| arch-test `I` / `M` / `Zicsr` / `Zca` | **39/39、8/8、6/6、26/26 PASS**（共 79 例，0 失败） |
| arch-test `Zifencei` | **1/1 PASS**（需 `-DMISALIGNED_TRAP`，见下） |
| 单元测试 | AXI 79 / EXEC 2461 / DECODER 255（向量随 fence.i 语义修正更新）全通过 |
| 端到端 | `SIM: PASS hello`、`SIM: PASS memtest` |
| 锁步 | `scripts/lockstep.sh sim/tests/out/lockstep_bench_hi.elf 6000` → **5994 条提交与 Spike 完全一致**（新增纯计算基准 `sim/tests/lockstep_bench.c`，避免 MMIO 让 Spike 提前退出） |

**新增工具**：`sim/tb/tb_prof.v`（停滞直方图 + 窗口 PC 哈希 + 死锁现场 dump）、
`scripts/run_arch_test_suite.sh`（整组批量跑+汇总）、`scripts/arch_fail_locate.py`（从提交轨迹定位
首个失败用例及其 instptr/描述串）、`sim/tests/lockstep_bench.c`；`scripts/lockstep.sh` 修好三处工具
缺陷（`32'h…` 未加引号、Spike 提交日志在 stderr、RESET_PC 改取 ELF 入口）。

**Zifencei 的收尾（已解决）**：失败点是 ACT4 框架的 trap 签名比对——参考模型 Spike（本版本无
`--misaligned`）对非自然对齐访存一律报 cause 4/6，而本核按规格默认"硬件拆分"（Linux/uboot 需要），
于是框架特意制造的两条 misaligned store 陷阱在核上根本没发生。解法：实现规格里本就预留的
`` `MISALIGNED_TRAP ``（`rtl/top/rv32gc_core.v`：非对齐访问不拆分、直接报 cause 4/6 且 `tval`=原始 VA），
并在 `run_arch_test.sh` 里默认加 `-DMISALIGNED_TRAP`（可用 `RV32GC_NO_MISALIGNED_TRAP=1` 关掉）；
`run_sim.sh` 新增 `RV32GC_DEFS` 传额外宏。默认（拆分）配置下 hello/memtest 不受影响，仍 PASS。

**A 扩展执行通路（本轮新增）**：在 `rtl/top/rv32gc_core.v` 的 MEM FSM 中实现：
`M_REQ_W/M_WAIT_W` 写回阶段（`d_req_valid/d_req_we` 覆盖该阶段）、AMO 读-改-写（9 种 funct5：
ADD/SWAP/XOR/OR/AND/MIN/MAX/MINU/MAXU，`rd`=旧值、内存=新值）、LR 写保留集、SC 按保留集
成败写/不写并回 0/1、原子地址非自然对齐一律报 cause=6（原子不可拆分）、store/AMO/陷阱清保留集；
`wb_mem_data_q` 对 LR/SC/AMO 也取内存侧数据。回归：hello/memtest 与 8 例跨组抽检全过。

**待办（阶段 2A 剩余）**：① ~~`Zaamo`/`Zalrsc` 两组仍失败~~ 见下节结论 → ② 补 CSR/异常/PMP 细节 →
③ Sv32 MMU + L1I/L1D/L2 Cache → ④ FPGA tcl 与上板 B1~B3。
已全绿：`I`/`M`/`Zicsr`/`Zifencei`/`Zca`/`Zaamo` 六组（89 例 0 失败）。

### 阶段 2A 进展（第 7 轮，2026-09-13）：A 扩展全绿（含 Zalrsc），修复 3 个 RTL 缺陷

**结论**：**arch-test 7 组全绿** —— `I` 39/39、`M` 8/8、`Zicsr` 6/6、`Zifencei` 1/1、`Zca` 26/26、
**`Zaamo` 9/9**、**`Zalrsc` 2/2**（共 **91 例 0 失败**）。上一轮记录的"`Zaamo`/`Zalrsc` 失败是
trap 签名 / 存储未落盘"**全部由本轮修复的核内缺陷解释**，与 ACT4 框架无关（见下方"更正"）。

#### 本轮修复的 3 个真实 RTL 缺陷（全部在 `rtl/top/rv32gc_core.v`）

| # | 缺陷 | 根因与后果 | 修法 | 归因证据 |
|---|---|---|---|---|
| 1 | **MEM 级转发漏掉访存结果** | `mem_fwd_en` 曾要求 `mem_mem_op_q == MEM_NONE`，即 LOAD/LR/SC/AMO 的结果在 MEM 级一律不转发、只能等 WB。于是 `LR → SC → 依赖 rd 的指令` 链路里，紧跟访存的那条指令会读到**上一拍旧值**（`sc.w` 成功、rd 应为 0，但消费者看到旧的 x2=签名指针值） | `mem_fwd_en` 改为"ALU 结果随时可转发；访存结果在 FSM 到 `M_DONE` 那拍（数据已在 `mem_load_data`）即可转发"；`mem_fwd_val` 增加 `WB_MEM → mem_load_data` | **决定性**：`4f0ad1e`(旧 RTL) + 旧 slave → `Zalrsc-sc.w-00` FAIL；`7040098`(仅含本轮 RTL 修复) + 旧 slave → **PASS** |
| 2 | **保留集不清** | 规范要求"any store 使保留集失效"，但 RTL 只在 trap / WB 写响应出错时清 → `LR → sw → SC` 会错误地成功；成功/失败的 SC 也没有消费保留集 | ①普通 store 在 M_IDLE 发起拍清；②SC 成功在写响应完成（`M_WAIT_W`）清；③SC 失败/非对齐清；④AMO 写完成清 | 定向自测 `lrsc.S` 的"store 清保留集""SC 消费保留集"两组用例由 FAIL 转 PASS |
| 3 | **`M_DONE` 无条件回 `M_IDLE` → 前端停顿时重放同一条指令** | 本核允许 MEM 指令在 FSM 完成后仍被前端停顿（`fetch_stall`/`front_hold` → `advance_all=0`）占住 MEM 数拍；直接回 IDLE 会让 FSM **再次执行**该指令。对 SC 致命：第一次已消费保留集，重入即 `resv=0` → 走失败分支把 rd 改成 1，并再发一次写 | `M_DONE: if (!mem_valid_q \|\| advance_all) memst_q <= M_IDLE;`（linger 到指令真正离开 MEM） | 修前 trace 可见同一 SC 在 `mempc=0x…96` 反复重入 M_IDLE 十余拍、同一地址被写两次 |

#### ⚠️ 更正：上一轮"Zalrsc 失败 = ACT4 生成器缺陷"的结论**是错的**

上一轮曾据"生成器发出的 `mv xNew,xOld # switch signature pointer register`，而 xOld 已被测试
自身的 `LA(xOld,scratch)` 改写"断言这是 upstream 框架缺陷（并列出 33 个同族文件）。
**该判断错误，实际根因是本核的 MEM 级转发缺陷（上表 #1）**：

* `LA(x2, scratch)` 在 x2 上的写回，被**紧跟其后**读 x2 的指令（`mv x17, x2` → 实际是 `lw`/ALU
  消费者）读到旧值，使 x17 拿到签名指针而不是 scratch 地址 → 后续 `LREG` 读错地址。
* 核修好后，**同一份生成的汇编、同一个参考签名**即可通过（旧 slave 亦通过，见 #1 归因证据），
  说明生成器没有缺陷。
* 扫描脚本 `scripts/tests/arch_scan_sigreg_clobber.py` 的"值模型"补丁也因此作废：它把
  `LA` 之后的寄存器一律标记为已覆盖，属于**对核行为的错误假设**。保留该脚本仅作参考，
  **不要再据它判定生成器缺陷**；`scripts/tests/arch_sigreg_clobber_report.md` 顶部已加更正说明。

**教训（已写入工作方式）**：定位"参考模型一致、DUT 不一致"的失败时，"框架/生成器有缺陷"是
低概率假设，应先假设自己的转发/冒险处理有洞，并用**旧版本 RTL 复现**来判定是否为本轮修复所致
（本例正是靠 `git archive <tag> rtl` 对比才纠正了上一轮的误判）。

#### 逐项必要性验证（本轮实测，避免留下无用改动）

用 `git archive <commit> rtl` 取旧版本、或打补丁只回退**单个**修复，再跑定向自测与 arch-test：

| 变体 | Zalrsc-sc.w-00 | Zaamo-amoadd.w-00 | `lrsc.S` 定向自测 | 结论 |
|---|---|---|---|---|
| 全部修复（当前 HEAD） | PASS | PASS | **PASS** | 基线 |
| 回退 #1（MEM 转发） | **FAIL** | FAIL | FAIL | #1 必需 |
| 回退 #2（保留集清位） | PASS | PASS | **FAIL**（停在 store/SC 组） | #2 必需 |
| 回退 #3（`M_DONE` linger） | PASS | PASS | **FAIL** | #3 必需 |
| 回退测试模型寄存读（#4） | PASS | PASS | **FAIL** | #4 必需 |

即 4 项修复**各自都不可省**，且 #1 是 `Zalrsc`/`Zaamo` 组转绿的直接原因。

#### Zicbom 落地（本轮追加，含 CSR 与陷阱语义）

* **menvcfg/senvcfg**：`rtl/csr/rv32_csr.v` 新增两个 CSR（0x30A/0x10A），实现 Zicbom/Zicboz
  的许可位 CBCFE[6]/CBZE[7]/CBIE[5:4]（CBIE=0b10 为保留编码，按 WARL 归 0），其余字段读 0；
  复位为 0。位域依据：machine.adoc menvcfg、supervisor.adoc senvcfg 的 wavedrom 定义。
* **CBO 低特权级许可检查**（`rv32gc_core.v` ID 级）：priv<M 时 CBO.CLEAN/CBO.FLUSH 需
  `menvcfg.CBCFE=1`、CBO.ZERO 需 `menvcfg.CBZE=1`、CBO.INVAL 需 `menvcfg.CBIE∈{01,11}`；
  priv=U 还需 `senvcfg` 同名位为 1，否则报非法指令（cause=2）。
  规范条文：machine.adoc `norm:menvcfgcbcfeop`、`norm:menvcfgcbiecbo-invaloplead-in`；
  supervisor.adoc「senvcfg 的 CBCFE/CBIE 控制 U 模式」。
* **`uop_ctrl_t` 73 → 74 bit**：新增 `is_cbo`（位 73）。原因：`cbo_op` 的 0 值与 ECALL 的
  `sys_op` 无法区分（两者都是 `op_class=SYS` + `is_serial=1`），模式检查必须能判别"这是不是
  CBO 指令"。同步更新 `rtl/pkg/rv32gc_defs.vh`、`docs/design/spec/02-uop-and-decode.md` §2、
  `docs/design/spec/03-pipeline-regs.md`（两处表）；RTL 里原先**硬编码的 `[72:0]` / `73'd0`
  已全部改为 `` `UOP_CTRL_W `` 宏**（否则 `dec_ctrl[73]` 读出 X，会污染 PC/CSR 通路，实测表现为
  仿真卡死在取指 X 地址）。
* **用例 ISA 串自动合成**：`scripts/arch_test_build.sh` 改为「DUT 基座 rv32imac_zicsr_zifencei_zicntr
  ∪ 用例 `START_TEST_CONFIG` 头声明的扩展」。写死基座会让 Zicbom/Zihintpause 因缺扩展而整组 0/N；
  直接用头部串又缺 `_zicntr`（Zicsr 组把 `csrrs instret` 当非法，实测 4/6 FAIL）。故取并集。

#### 验证（本轮实测）

| 项 | 结果 |
|---|---|
| arch-test **12 组**：`I`/`M`/`Zicsr`/`Zifencei`/`Zca`/`Zaamo`/`Zalrsc`/`Misalign`/`MisalignZca`/`Zicntr`/`Zicbom`/`Zihintpause` | **39/8/6/1/26/9/2/5/4/2/3/1 全 PASS**（共 **106 例 0 失败**） |
| 端到端 | `SIM: PASS hello`、`SIM: PASS memtest` |
| 单元测试 | AXI 79 / EXEC 2461 / DECODER 254 全通过 |
| A 扩展定向自测 | `sim/tests/lrsc.S`（28 项检查）→ `LRSC_DIRECTED: PASS` |

复现命令：`bash scripts/run_lrsc_test.sh`；整组：`bash scripts/run_arch_test_suite.sh <I|M|Zicsr|Zifencei|Zca|Zaamo|Zalrsc>`。

#### 测试模型加固（`sim/tb/sim_axi_slave.v`）

`assign s_rdata = beat_read_data(...)` 是**纯组合读**内存数组，仿真器在"同一地址写后读"的时序下
会稳定返回**上一版**数据（实测：数组已是新值、函数在 TB 里单独求值也是新值，但该组合赋值输出
仍旧值），会让"store 后立刻读回同址"的定向测试假失败。改为**寄存一拍**：AR 握手拍锁存
`s_araddr/s_arsize` 对应的 beat 数据，R 拍保持，beat 被接收后预取下一个 beat。AXI 握手时序不变，
`AXI_SLAVE_UNIT` 仍 79 checks PASS。注意：此项**不是** Zalrsc 通过的原因（见上表 #1 归因证据）。

#### 新增工具/资产

`sim/tb/tb_trace_mem.v`（提交轨迹 + D 侧请求/响应 + AXI 通道追踪，本轮定位三个缺陷的关键工具）、
`sim/tb/tb_axi_slave_rw.v`（从设备写后读可见性的独立复现台，不接核）、
`sim/tests/lrsc.S` + `scripts/run_lrsc_test.sh`（A 扩展定向自测：LR/SC 同址/异址/二次 LR/
rd=rs2/rd=rs1=rs2、store 清保留集、SC 消费保留集、AMO 读-改-写、原子与 SC 非对齐陷阱，共 28 项）。

---

## 7. 当前状态与下一阶段计划

**当前状态（2026-09-13，阶段 2A 进行中）**：已执行 5 个 goal round。
- ✅ 仿真/回归环境（iverilog + Verilator + Spike 参考模型 + 自研 TB + 锁步工具链）已建成
- ✅ 顺序 5 级基线核跑通 `hello`、`memtest`；单元测试全绿（AXI 79 / EXEC 2461 / DECODER 255）
- ✅ **arch-test 5 组全绿**：`I` 39/39、`M` 8/8、`Zicsr` 6/6、`Zifencei` 1/1、`Zca` 26/26（共 80 例 0 失败）
- ✅ **锁步 5994 条提交与 Spike 完全一致**（`sim/tests/out/lockstep_bench_hi.elf`）
- ✅ A 扩展（LR/SC/AMO）执行通路已实现（写回阶段 + 读-改-写 + 保留集 + 原子对齐检查）
- ⏭ 下一步：Zaamo/Zalrsc 的 trap 签名记录一致性 → CSR/异常/PMP 完善 → Sv32 MMU + Cache → FPGA 上板
- 📌 **平台适配结论（D15）**：不需要改 chiplab 的 AXI 编址（编址与 ISA 无关，DDR 是 AXI 默认从设备在 `0x0`）；需要的是复位向量 `0x1C00_0000`、镜像按 `0x0` 链接、以及把核内 CLINT/PLIC（`0x1F00_0000/0x1F10_0000`）写进 DTS/SBI —— 已作为任务 2A-7 列入
- 📄 **下一会话请直接使用 `NEXT_SESSION.md` 中的提示词**（自包含：环境、命令、当前卡点、下一步）


> **阶段 2A 的实施依据**：`docs/design/spec/`（实现级规格书）已全部就绪，RTL 开发按 `spec/00-conventions.md` §8 的顺序自底向上推进；每写一个模块，先按 `spec/09-verification-interface.md` §4 建对应单元测试。

**下一阶段（阶段 2A）任务与计划**

| 步骤 | 任务 | 产出 | 完成判据 |
|---|---|---|---|
| 2A-1 | 仿真工具链落地：确认 verilator/iverilog 可用；编译 Spike；建立 `sim/` 目录与回归脚本 | `sim/tb/*`、`scripts/regress.sh` | 一个 LED 闪烁/计数器 RTL 能在 iverilog 与 verilator 下跑通 |
| 2A-2 | 平台壳与总线：`core_top`（AXI4 主设备 + 调试端口 + 时钟复位同步）、`axi_mem_model`、`soc_sim_top` | `rtl/top/`、`rtl/bus/`、`sim/tb/soc_sim_top.v` | 裸机程序能通过 AXI 读写内存与 CONFREG |
| 2A-3 | 5 级顺序流水：RV32IMAFDC 译码/执行（含 RVC）、冒险处理、CSR/异常、PMP | `rtl/frontend|decode|exec|csr/` | 通过自研指令级单元测试 |
| 2A-4 | MMU（Sv32 TLB+PTW）与 L1I/L1D、L2 | `rtl/mmu/`、`rtl/mem/` | Cache/TLB 单元测试通过 |
| 2A-5 | arch-test 接入（Spike 生成签名）+ 自研裸机测试框架 | `sw/tests/`、`sim/log` | I/M/A/F/D/C/Zicsr/Zifencei 子集全绿 |
| 2A-6 | FPGA 工程脚本与上板 | `fpga/build_chiplab.tcl`、bit 流 | 串口输出 + 数码管正确 + 60 MHz 收敛 |
| 2A-7 | **平台适配（复位向量/镜像布局/RISC-V 内存映射）**：`RESET_PC=0x1C00_0000` 上板取值、平台 DDR `0x0` 链接脚本、DTS/OpenSBI 的 DRAM 基址与核内 CLINT/PLIC 地址声明、地址映射自检 | `docs/porting/00-overview.md` §平台适配、`sim/tests/link.ld`（0x0 已就绪）、`platform_override`/DTS 片段 | 上板从 `0x1C00_0000` 启动→跳 DDR；软件（OpenSBI/U-Boot/内核）按 `0x0` DRAM 与 `0x1F00_0000/0x1F10_0000` 的 CLINT/PLIC 跑通 |

**阶段二开工前需要用户确认/配合的事项**
1. ~~在沙箱外执行 `sudo apt install verilator iverilog gtkwave`~~ → **已完成**（Verilator 5.020 / Icarus Verilog 12.0 已就绪，`xvlog/xelab/xsim` 亦可用）；
2. ~~确认阶段一设计参数~~ → **已审阅通过**；
3. ~~提供实验箱 NAND 芯片型号/丝印~~ → **已由原理图确认**（K9F1G08U0C-PCB0，见阶段一补充更新）；
4. 仅剩一项待用户指令：**"开始阶段 2A"**。收到后按 §7 的 2A-1 → 2A-6 顺序执行。
