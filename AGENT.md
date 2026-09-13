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
| D16 | **SPI-Flash XIP 启动（`0x1C00_0000`）是平台硬约束，必须由核 + 引导软件适配；禁止改平台**。核侧三件事：① `RESET_PC` 取 `0x1C00_0000`；② 取指命中 **SPI 窗口时绕过 I-Cache**（XIP 无 cache 一致性语义）；③ 引导软件第一条指令必须落在 SPI 窗口内、且**只用 PC 相对寻址**（`0x1C00_0000` 超出 `auipc`+12 位立即数的 ±2 MiB 覆盖范围，跨窗口跳转必须靠完整 32 位 `auipc+jalr`/`jal`，链接时按窗口分段）。早期**不得开 MMU**（SPI 窗口在 MMU 下需显式映射；RV32 Linux `PAGE_OFFSET=0xC0000000` 与平台 DDR `0x0` 天然吻合，故内核阶段不再依赖 SPI 窗口） | **源码级依据**（2026-09-13 核对 chiplab）：<br>· `chiplab/IP/AMBA/axi_mux_syn.v:946` `rd_addr_hit[1] = (araddr[31:16]==16'h1fe8) \|\| (araddr[31:20]==12'h1c0); //SPI`；`:854` 同式写命中；`:860` `wr_addr_hit[0] = ~\|wr_addr_hit[4:1]` → **DDR3 = AXI 默认从设备，位于 `0x0–0x07FF_FFFF`**<br>· `chip/soc_demo/loongson/soc_top.v:992` `axi_slave_mux .spi_boot(1'b1)`（常量 1）、`:1223` `spi_flash_ctrl .spi_addr(16'h1fe8)`<br>· `IP/SPI/godson_sbridge_spi.v:189` `io_hit=(buf_addr[31:4]=={spi_addr,12'b0})`、`:194` `buf_addr_t[31:20]==12'h1fc ? {12'h0,addr[19:0]} : {8'h0,addr[23:0]}`<br>· `docs/FPGA_run_linux/linux_run.md`：先把 PMON/u-boot 烧到可插拔 SPI flash，上电即从 SPI 运行<br>· `fpga/nscscc-team/uart_debug/uart_debug.v:41` `SRAM_START_ADDR=32'h1c000000` | ① 改平台 AXI 编址/把 DDR 挪到 `0x8000_0000`：要改 SoC 顶层 + vivado 工程 + 约束，失去平台复用，且与 LA32R 参考实现冲突（与 D15 同一理由）；② 复位 PC 留在 `0x8000_0000`：该地址落在 **DDR3**（上电内容未定义）→ 上板必然跑飞；③ 开 Cache 后再从 SPI XIP：XIP 读被缓存且无一致性维护 → 取指错乱 |

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

## 4.5 工作方式（强制）：子 Agent 并行 + 启动读取清单

### 4.5.1 每次会话开工必读（按顺序）

1. **`PROMPT.md`** —— 项目总提示词（任务背景、硬性指标、平台与移植约束、强制流程）。
   **每个新会话/新阶段的第一件事就是读它**，不要凭记忆假设其内容。
2. 本文件 `AGENT.md`：§2 关键决策、**§6 阶段总结（含各轮进展）**、§7 当前状态与下一阶段计划。
3. `NEXT_SESSION.md`：上一轮交接的"当前卡点 + 下一步"（最新一轮的事实以它为准）。
4. `git log --oneline | head` + `git status --short`：确认工作区干净、知道从哪个提交接手。
5. 需要 ISA/arch-test/工具链知识时用 `kb_search`（**不要直接读大文件**）；本项目自己的
   知识库在 `docs/kb/`。

### 4.5.2 **默认用子 Agent 并行推进**（强制倾向）

本项目任务高度可并行（RTL 子模块、每个 arch-test 组、移植子任务、文档核查、缺陷定位）。
**默认行为是"先拆分、再并行"**，而不是单线程一步步做：

| 场景 | 要求 |
|---|---|
| ≥2 个彼此独立的子任务（如"跑 N 个 arch-test 组"、"查 3 个模块的同一个问题"、"同时验证 2 个假设"） | **必须**用 `subagent` / `subagent_fork` 并行发起（在同一条消息里发多个调用），不要在一条链上串行做 |
| 需要读取大量文件后只回一个结论（日志分析、代码搜索、报告核查） | 交给子 Agent，**只要结论不要中间过程**，以保护主上下文 |
| 单个任务超过 ~10 次工具调用且与主线独立 | 交给子 Agent |
| 长时仿真/构建（arch-test 整组、Vivado 综合、锁步） | 用**后台 bash job**（`run_in_background`）与其它工作并行；不要空等 |
| 多个互不依赖的归档/总结/报告 | 用 `workflow` 工具扇出（仅在任务规模确实需要多 Agent 编排时） |
| 真正串行、强依赖前一步结果的工作（例如"先修 RTL 再跑回归"） | 由主 Agent 自己做，不要为了并行而并行 |

**并行时的硬性纪律**：

1. **一个任务只做一件事**，且能自证完成（给出可复现的命令与判定输出）。
2. 子 Agent **必须**收到自包含的提示词：环境路径、要改/要读的文件、验收命令、禁止事项
   （不要改上游 `riscv-arch-test`/`chiplab`/内核树、不要动 `docs/design/spec/` 的位域真源等）。
3. **避免写冲突**：并行的子 Agent 不得同时改同一个文件；RTL 相关改动建议串行或按模块切分。
4. 主 Agent 负责：**汇总证据 → 更新 `AGENT.md`/`NEXT_SESSION.md` → git 提交**（子 Agent 不提交）。
5. 子 Agent 的结论**不等于**验收：关键结论（尤其是"某功能已通过"）必须由主 Agent 用
   命令复跑一次确认（本项目的教训：曾把 DUT 缺陷误判为框架缺陷，见 §6 第 7 轮"更正"）。

### 4.5.3 并行典型拆分（本项目常用）

* **arch-test 组**：每组一个子 Agent/后台 job，最后汇总 PASS/FAIL 计数。
* **缺陷定位**：一个子 Agent 收集证据（轨迹/波形/参考模型），另一个设计对照实验（旧版本
  RTL、单点回退），主 Agent 合并结论。
* **RTL 子模块**：译码/CSR/前端/访存互不相同的文件，可并行；**接口位域改动必须串行**
  （先改 `rtl/pkg/rv32gc_defs.vh` 真源，再同步 `docs/design/spec/02-*`、`03-*`）。
* **文档核查**：把"核对 X 与 Y 是否一致"的机械性检查交给子 Agent。

---

## 5. 阶段交接规则（强制）

1. **每阶段结束**：必须在本文件 §6（阶段总结）追加该阶段总结，并在 §7 更新"下一阶段任务与计划"，然后**停止执行**，等待用户明确指令（例如"开始阶段 2A"）后再继续。
2. **每阶段开始**：先读 `PROMPT.md`、本文件 §2（决策）、§6/§7（上一阶段总结与计划），并按需用 `kb_search` 检索 `docs/kb/` 与 ISA 手册，避免重复推导。
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
* **Zicond（`czero.eqz`/`czero.nez`）**：`rtl/decode/rv32_decoder.v` 在 `OP_OP` 里按
  `funct7=0000111` 的 `funct3` 分流（eqz→funct3=101、nez→funct3=111，注意 eqz 与 SRL、
  nez 与 AND 共用 funct3，必须先判 funct7）；`rtl/exec/rv32_alu.v` 新增
  `ALU_CZERO_EQZ(5'd10)`/`ALU_CZERO_NEZ(5'd11)`：`rd = (rs2 条件) ? 0 : rs1`。
  结果 `Zicond` 2/2 全绿。
* **Zicboz/Zicbop 顺带全绿**：`Zicboz` 1/1、`Zicbop` 3/3。CBO.ZERO 的 CBZE 许可位与 menvcfg/
  senvcfg 一起在本轮实现，`prefetch.{i,r,w}` 本核按提示指令（NOP）处理，两边一致即通过。
* **用例 ISA 串自动合成**：`scripts/arch_test_build.sh` 改为「DUT 基座 rv32imac_zicsr_zifencei_zicntr
  ∪ 用例 `START_TEST_CONFIG` 头声明的扩展」。写死基座会让 Zicbom/Zihintpause 因缺扩展而整组 0/N；
  直接用头部串又缺 `_zicntr`（Zicsr 组把 `csrrs instret` 当非法，实测 4/6 FAIL）。故取并集。

#### 验证（本轮实测）

| 项 | 结果 |
|---|---|
| arch-test **17 组**：`I`/`M`/`Zicsr`/`Zifencei`/`Zca`/`Zaamo`/`Zalrsc`/`Misalign`/`MisalignZca`/`Zicntr`/`Zicbom`/`Zicboz`/`Zicbop`/`Zihintpause`/`Zihintntl`/`ZihintntlZca`/`Zmmul`/**`Zicond`** | **39/8/6/1/26/9/2/5/4/2/3/1/3/1/4/4/4/2 全 PASS**（共 **123 例 0 失败**） |
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

### 阶段 2A 进展（第 9 轮，2026-09-13）：SPI-XIP 启动链路打通（2A-7a）

**结论**：`bash scripts/run_spi_boot_test.sh` → **`SPI_BOOT: PASS`**（441 拍，rc=0）。核能在平台的真实
复位取指窗口 **`0x1C00_0000`（SPI Flash XIP，平台没有硬件 boot ROM）** 取到并执行首条指令，在 SPI
窗口内完成自检后以 `auipc+addi+jalr` **跨约 448 MiB** 跳到 DDR `0x0` 继续执行，最终写退出码 0。

#### 交付物

| 文件 | 说明 |
|---|---|
| `scripts/run_spi_boot_test.sh`（新增，229 行） | 编译测试 → 切双镜像 → 用 `-DRESET_PC=32'h1C000000` 重编全部 RTL（top=`tb_spi_boot`）→ 跑 → 判定 `SPI_BOOT: PASS` |
| `sim/tb/tb_spi_boot.v`（新增，335 行） | 专用 TB：复用 `sim_axi_slave` 与同一退出约定，新增 5 条启动链路断言 |
| `sim/tests/spi_link.ld`（新增） | `.text.spi`→`0x1C00_0000`、`.text.ddr`→`0x0` 两个地址区 |
| `sim/tests/spi_boot.S`（改写，245 行） | 入口 PC 落窗自检 + SPI 段 ALU 自检 + **XIP 数据读**（`lw` 读回魔数 `0xC0DEF00D`）+ 跨窗口 `jalr` + DDR 段 ALU/写读回（含窄写与同址连续换值回读） |
| `rtl/pkg/rv32gc_defs.vh`、`rtl/frontend/rv32_ifetch.v`、`rtl/top/rv32gc_core.v` | **D16② 判定点**（见下）：`SPI_XIP_BASE/MASK` + `` `IS_SPI_XIP `` → `if_spi_xip` → `rv32_ifetch.xip_bypass`（请求侧组合判定）/`line_xip_q`（填充侧记录本行窗口归属） |
| `docs/design/spec/08-bus-axi.md` | §2.1 订正"SRAM/SPI-XIP 可缓存"的一刀切说法 + 写明 D16② 的判定点与 2A-4 必须做的两件事；留下"数据侧是否也绕 L1D"的待决项 |

**镜像切分（关键设计）**：一个 ELF 两个地址区（跨区 `%pcrel_hi/lo` 必须由链接器在同一 ELF 内解析），再用
`objcopy -O verilog --verilog-data-width=1` 切两份字节宽度 hex：SPI 段用 `--only-section=.text.spi
--change-section-address .text.spi=0` 重定位到 0 基（`$readmemh` 的目标 `mem_spi[]` 是 1 MiB 0 基数组，
带 `@1C000000` 的记录会越界），DDR 段保持 `@0`；分别经 `+SPI_INIT=` 与 `+MEM_LO_INIT=` 载入。
踩坑：objcopy 的 verilog 输出按 **LMA** 写地址（只改 `--change-section-vma` 无效）；输出为 CRLF。

**"退出码 0 = PASS" 的确定性判定**：程序把退出码写 `0x1FAF_FF00`（CONFREG 仿真 IO_SIMU）；`sim_axi_slave`
在写 beat 落地那拍置 1 拍 `exit_we` 并锁存 `exit_wdata`；`tb_spi_boot.v` **在 `exit_we` 那一拍按退出值
本身**判定（0 → `$finish`/PASS，非 0 → FAIL/`$fatal`），因此"写 0"不会被误当成"没结束"而判超时。

#### 验证（本轮实测；主 Agent 全部复跑）

| 项 | 命令 | 结果 |
|---|---|---|
| 启动链路（主 Agent 复跑） | `bash scripts/run_spi_boot_test.sh` | **`SPI_BOOT: PASS`**，rc=0，5 条 TB 断言全 OK，441 拍 |
| 日志观测量 | 同上日志 | 首笔取指 `@0x1c000000`；SPI 窗口提交 PC `0x1c000000`；DDR 提交 PC `0x00000000`；取指请求 15 笔；退出码 0 |
| 反汇编核对 | `sim/tests/out/spi_boot.dump` | 跨窗口跳转为原样三连 `auipc t0,0xe4000; addi t0,t0,-140; jalr t0`（`0x1C00008C + 0xE4000000(sign) − 0x8C = 0x0`） |
| **负对照 1**（SPI 镜像缺失） | `vvp … +SPI_INIT=/tmp/不存在.hex` | **FAIL**（CHECK-2/5 FAIL，退出码 `0x21`，rc=1） |
| **负对照 2**（破坏 XIP 魔数 `0x0D→0x0E`） | `vvp … +SPI_INIT=/tmp/bad.spi.hex` | **FAIL**（CHECK-3/4/5 FAIL，退出码 **`0x13`=E_SPI_LOAD**，rc=1）——证明 XIP **数据读**真的在读 SPI 内存 |
| 无回归（本项） | `run_sim.sh hello` / `memtest`、`run_unit_axi.sh` | PASS（hello 352 拍、AXI 79 checks；主 Agent 独立复跑 hello 亦 PASS） |
| **全量回归（P1-c 证据）** | `scripts/run_arch_test_suite.sh <组>` × **18 组**（JOBS=4，串行跑完） | **39/8/6/1/26/9/2/5/4/2/3/1/3/1/4/4/4/2 全 PASS = 124 例 0 失败**；`run_arch_test.sh I/I-add-00` 亦 PASS（脚本改动向后兼容） |

#### D16② 落实情况（"命中 SPI 窗口时绕过 I-Cache"）

当前基线核**无 I-Cache**（`rv32_ifetch` 是单行取指缓冲：去掉就取不到指令，不是 Cache），所以"绕过"在本阶段
**没有行为差异**。为避免该约束在 2A-4 被遗忘，判定点已**物理连好**：`` `IS_SPI_XIP(fetch_pc) `` →
`xip_bypass`（请求侧）+ `line_xip_q`/`req_xip_q`（填充侧记录该行的窗口归属）。`rv32_ifetch.v` 顶部与
`docs/design/spec/08-bus-axi.md` §2.1 写明 2A-4 必须两处都用上：① 填充侧禁止 `line_xip_q=1` 的行进入
Cache 阵列（不能只看请求侧判定——命中的是*之前取过的行*）；② 请求侧 `xip_bypass=1` 时不得从阵列命中。
否则 XIP 读被缓存且平台无一致性维护 → 取指错乱（D16 否决原因③）。本项改动**行为中性**（对现有 123 例
arch-test 与 hello/memtest 无影响，已复跑）。

#### 已知限制（不要当成已验过）

* 真实 SPI 控制器的**读写命令序列**（`0x03` 读 / `0x02` 页编程 / WREN / WIP 轮询、上电延迟、时钟分频）不在
  仿真模型内：`sim_axi_slave.v` 的 `mem_spi[]` 是行为级 XIP 窗口（命中即按字节返回，**写忽略**）。本测试
  **不对 SPI 写做任何断言**，程序也从不写 SPI 窗口。
* 只验证"取指与数据读经 AXI 命中 `0x1C00_0000` 窗口"这条链路；平台实机首次访问前是否需要命令播种未覆盖。
* 取指命中但 X 权限被 PMP 拒绝时"不发未检查地址"（`spec/09-verification-interface.md` AXI-15）在当前取指单元
  上尚未做请求抑制；随 P1-b 的 PMP 一并评估（见 §7）。

---

### 阶段 2A 进展（第 10 轮，2026-09-13）：PMP 落地（2A-3 收尾，P1-b）

**结论**：实现 PMP（16 项，G=0 / 4 字节粒度，TOR/NA4/NAPOT + 锁定语义 + S/U 访问检查），
`tests/priv` 的 PMP 组由「0 通过」提升到 **69 / 73 可达用例通过**。详见下表与失败清单。

#### 交付物

| 文件 | 说明 |
|---|---|
| `rtl/csr/rv32_pmp.v`（新增，197 行） | **纯组合**检查器：16 项匹配（TOR/NA4/NAPOT，无循环 NAPOT 掩码）+ **最低编号匹配项决定** + 全字节匹配要求 + `L=0&&M` 通过 / 无匹配 M 通过、S/U 拒绝；一个匹配引擎带**两组权限需求**（`permit` 读 / `permit2` 写） |
| `sim/tests/unit/tb_unit_pmp.v` + `scripts/run_unit_pmp.sh`（新增） | **`PMP_UNIT: PASS (443 checks)`**（定向 + A 模式/L/RWX 暴扫 + 随机对照），模块可独立编译零告警 |
| `rtl/csr/rv32_csr.v` | `pmpcfg0-3`@0x3A0-0x3A3 / `pmpaddr0-15`@0x3B0-0x3BF（`0x3A4-0x3AF` 不存在⇒非法指令）；**逐项锁定合并**（L=1⇒整字节忽略；L=1&&A=TOR⇒`pmpaddr[i-1]` 也忽略）；**写归一**（保留位 [6:5] 忽略、`R=0⇒W 丢弃`，对齐 Spike）；**WB→ID 读旁通返回合并后的有效值**；输出 `pmpcfg_o/pmpaddr_o` |
| `rtl/pkg/rv32gc_defs.vh` | `CSR_PMPADDR1-15`、`` `IS_PMPCFG_ADDR ``/`` `IS_PMPADDR_ADDR `` |
| `rtl/top/rv32gc_core.v` | PMP 接入：取指侧**按 2 字节 parcel 分别查**（`u_pmp_if_a/b`，tval=被拒 parcel 地址）；访存侧在 MEM `M_IDLE` **发起请求前**检查（不通过⇒不拉请求、直接 `M_DONE`，WB 报 cause 5/7）；`mstatus.MPRV` 接出并只作用于数据访问；**非对齐优先于 PMP** |
| `docs/design/spec/07-priv-csr-mmu.md` §7 | 按实际实现重写（结构/端口/性能约束） |
| `docs/design/spec/09-verification-interface.md` §3.4 | MMU-10..15 指向新实现；订正"G=0 时 `pmpaddr` 低 2 位恒 0"的旧表述；记录判定规则/检查点/性能约束 |
| `sim/arch_test/config/rvtest_config.h` 等 | （第 9 轮已提交）特权组运行支持 + PMP 宏 |

#### 本轮修复的 4 个真实缺陷（全部有 Spike 侧依据 + 对照实验）

| # | 缺陷 | 根因 | 修法 |
|---|---|---|---|
| 1 | **访存 PMP 拒绝会死锁**（设计风险，实现时已规避） | M_IDLE 不拉请求又不回 `M_DONE` ⇒ `mem_stall` 恒 1 ⇒ `advance_all` 恒 0 | 复用 misaligned 的"免请求 + 直接进 `M_DONE`"写法，由 WB 级精确报 trap |
| 2 | **非法指令 `mtval` 用了 RVC 展开值** | `id_excp_tval` 用 `dec_instr`；保留编码 `c.addi4spn`(nzuimm=0) 被展开成 `addi x8,x2,0`=0x00010413，而 Spike 记 `insn.bits()`=0x0000 | 改用**原始指令位**（16 位指令取低 16 位、高半字补 0）⇒ 修复 9 例 TOR + 3 例 NA4 |
| 3 | **取指 PMP 检查粒度过粗** | 本核按"整条指令"一次查并要求同一项覆盖全部扇区；Spike `fetch_slow_path` 按 **2 字节 parcel** 各查一次（`translate(…,sizeof(insn_parcel_t))`），parcel 只折到其所在 4 字节扇区 | 改为 `u_pmp_if_a`(pc) + `u_pmp_if_b`(pc+2) 两次 `acc_size=1` 检查，tval=被拒 parcel 地址 ⇒ 修复 6 例 XWR_all/杂项 + 3 例 misaligned |
| 5 | **`csr_legal` 从未被核使用** | `rv32_csr` 已算出「特权级不足/地址不存在/写只读 CSR」，但核的 ID 级异常只看 `!dec_legal`/CBO/PMP ⇒ S 模式读写 `pmpcfg/pmpaddr` **静默提交**、零陷阱 | ID 级新增 `id_csr_ill = (c_csr_op != CSR_NONE) && !csr_legal` 并入 `id_excp_valid/cause/tval` ⇒ 修复 `PMPS/PMPU_csr_access`（陷阱计数 0xa00 与参考一致） |
| 6 | **数据侧 PMP 用了尚未提交的 `mstatus.MPRV/MPP`** | `csrs mstatus`(MPRV+MPP=S) 紧跟 `sw` 时，前一条 csrs 仍在 WB 且因 `mem_stall` 未提交（`wb_csr_wen=0`）⇒ 有效特权级误判为 M ⇒ 漏报 SMPU 违例 | 按「WB 待提交的 mstatus 写」取有效 MPRV/MPP（用 `wb_csr_op_q` 判类型，**不能用 `wb_csr_wen`** —— 停摆拍为 0）⇒ 修复 `PMPS/PMPU_mprv_check-01` |
| 4 | **AMO 的 PMP 违例报错 cause 错** | 按"读相位先判"报 cause 5；Spike 的 `amo()` 走 store 检查且被 `convert_load_traps_to_store_traps` 包住 ⇒ **AMO 被拒恒 cause 7** | `mem_pmp_cause = (amo || store/sc) ? 7 : 5` ⇒ 修复 `PMPZaamo_cfg_wr-00` |

另修：**非对齐优先于 PMP**（Spike `load_slow_path` 先抛 cause 4/6，PMP 在 `translate()` 内）——
`mem_pmp_deny = !mem_pmp_ok && !mem_misaligned`（仅 `-DMISALIGNED_TRAP`）⇒ 修复 `PMPSm_cfg_tor_all-00`。

#### 验证（本轮实测；主 Agent 复跑）

| 项 | 命令 | 结果 |
|---|---|---|
| 单元测试（PMP） | `bash scripts/run_unit_pmp.sh` | **`PMP_UNIT: PASS (443 checks)`** |
| 特权组（PMP） | `bash scripts/run_arch_test_suite.sh <组>` | PMPSm **37/38**、PMPS **11/11**、PMPU **11/11**、PMPZaamo **1/1**、PMPZalrsc **1/1**、PMPZca **12/15**（3 例为无 Zcb/F/D 的 ISA 不可达）⇒ **73 / 73 可达用例全通过** |
| **回归（P1-c 不可退）** | 18 组 `run_arch_test_suite.sh` ×（JOBS=4） | **18 组 124 例全 PASS**（39/8/6/1/26/9/2/5/4/2/3/1/3/1/4/4/4/2） |
| 其它回归 | `hello` / `memtest` / `run_unit_axi|exec|decoder` / `run_lrsc_test.sh` | 全 PASS（memtest 2,026,669 拍与基线一致；EXEC 2461 / DECODER 254 / AXI 79；`LRSC_DIRECTED: PASS`） |
| **性能** | 50k 拍 `tb_debug_min` | PMP 接入后 **1.07s**（含 PMP 前的基线 2.85s）—— 关键：NAPOT 掩码**无循环**、访存侧**只实例化一个匹配引擎**（复制匹配树会慢 3 倍以上） |

#### 仍失败 / 不可达（**未完成项，下一轮继续**）

| 用例 | 状态 | 说明 |
|---|---|---|
> **上一版列出的 4 例已全部修复**（见上表缺陷 #5/#6）：`PMPS/PMPU_csr_access-00`（`csr_legal` 未接入）、
> `PMPS/PMPU_mprv_check-01-00`（MPRV 未旁路）；`mprv_check-02` 由取指 parcel 修复一并转绿。
| `PMPSm/PMPSm_cfg_A_tor_zero-00` | **平台口径差异** | 探针地址=**物理 0**：Spike 默认内存映射在 0 无存储 ⇒ 参考记 3 个 access fault；本仿真平台把 0..16 MiB 铺成 DDR（与真实平台一致：DDR3 在 `0x0`）且复位桩在 0 ⇒ 访问成功。另发现 `rv32_ifetch.v` 的 `if_rsp_err` **从未使用**（取指总线错误无法转 cause 1），属真实缺口，随 2A-7 平台收尾一起做 |
| `PMPF`(1)、`PMPZca` 的 zcb/zcf/zcd(3) | **ISA 不可达** | 需要 F/D 或 Zcb/Zcf/Zcd；已与用户确认按 74/78 口径验收 |

#### 旁证：`priv_trap.S` 定向自测（本轮新增，未提交缺陷修复）

`sim/tests/priv_trap.S`（718 行，46 检查点）+ `scripts/run_priv_trap_test.sh` 首次系统性地覆盖了
**M/S/U 三态 + 陷阱进出**这条 arch-test 非特权组从未走过的路径：40 项通过、1 项失败、5 项 SKIP。
失败项是**核的真实缺陷**：**中断永不投递** —— `rv32gc_core.v` 的 `.trap_is_int(1'b0)` 恒 0、陷阱决策链
没有任何 `mip/mie` 项，而 `rv32_csr.v` 的 `mip` 软件可写并可读回（`mip_q <= csr_wdata & 32'h0888`），
`core_top.v` 的 `intrpt[7:0]` 只接进 dummy。即"能置挂起位但硬件永不响应"，两头都不合规范
（`machine.adoc norm:intrmipmie_op` / `norm:intrmipmieboundedtime`）。**对 PMP 组不阻塞**（PMP 用例
不依赖中断），但 CLINT/PLIC/Linux 之前必须补 —— 已列入 §7。

---

### 阶段 2A 进展（第 11 轮，2026-09-13）：中断投递 + 核内 CLINT/PLIC（D5 落地）

**结论**：核从「`mip` 可写但无人消费、中断永不投递」变为**完整可投递**：`sim/tests/priv_trap.S`
由 `passed=40/41 + 5 SKIP` 变为 **`PRIV_TRAP: PASS (46 checks)`**（含中断向量入口、`mcause=0x80000003`、
`mepc`=被打断指令、`mstatus.MIE→MPIE`、`mret` 后重执行）。全量回归无回退。

#### 交付物

| 文件 | 说明 |
|---|---|
| `rtl/csr/rv32_clint.v`（新增） | 核内 CLINT：`msip`@+0（只 bit0）、`mtimecmp`@+0x4000 低/高、`mtime`@+0xBFF8 低/高；`mtip=(mtime>=mtimecmp)&~suppress`（64 位无符号）；wstrb 逐字节合并；**mtime 按核时钟每拍 +1**（仿真近似，FPGA 上需分频驱动 `tick`） |
| `rtl/csr/rv32_plic.v`（新增） | 核内 PLIC（NSRC=8，SiFive PLIC 1.0.0 布局）：priority / pending / enable / threshold / claim-complete，**M 与 S 两个 context**；gateway（pending+in-service）、claim=返回最高优先级并置 in-service、complete 后源仍高则重挂；同级取最小编号；`priority>threshold` 严格大于 |
| `rtl/csr/rv32_csr.v` | **中断评审**：`mip` 组合（MSIP/MTIP/MEIP/SEIP 只读、由 CLINT/PLIC 驱动；SSIP/STIP 软件可写、`sip` 写只作用于 SSIP）；取中断资格按 `norm:intrmipmie_op`（M 级需 `mstatus.MIE` / S 级需 `SIE`、`mideleg` 委托、priv=M 不取 S 级）；优先级 MEI>MSI>MTI>SEI>SSI>STI；输出 `intr_valid`/`intr_cause` |
| `rtl/top/rv32gc_core.v` | 核内设备**访存截获**（CLINT `0x1F00_0000`、PLIC `0x1F10_0000–0x1F3F_FFFF`，单拍完成、**不产生 AXI 请求**；设备访问要求自然对齐，非对齐报 cause 4/6）；`intrpt[7:0]` 接入 PLIC（source 1..5）；**中断在"WB 提交之后"的边界取**：`mepc`=最老的未提交指令，且**不在 MEM 级副作用已落地的指令上取**（否则 mret 后重放、副作用翻倍） |
| `sim/tests/unit/tb_clint_plic.v` + `scripts/run_unit_clint_plic.sh`（新增） | **`CLINT_PLIC_UNIT: PASS (184 checks)`**（CLINT 56 / PLIC 128；5 个 RTL 变异体全部被捕获，防假 PASS） |
| `sim/tests/priv_trap.S` | 中断阶段改用 **CLINT.msip**（`mip.MSIP` 已按规范做成只读）；开头铺 **PMP 背景项**（entry15 = L=1/NAPOT/全空间/RWX）——PMP 生效后 S/U 阶段必须有背景项才可执行 |

#### 实现中定的 3 条口径（都有规范/参考依据，勿再踩）

1. **`mip.MSIP/MTIP/MEIP/SEIP` 只读**（`machine.adoc norm:mipmsiprdonly`：MSIP 由 memory-mapped 寄存器写）；
   软件置挂起必须写 CLINT/PLIC，`mip` 只留 SSIP/STIP 可写（`norm:mipbitswr_op` 允许的另一种做法）。
2. **中断在指令边界取、且不在"副作用已落地"的指令上取**：本核 store 在 MEM 即发出写（MMIO 写更是在
   MEM 拍生效），若把该 store 当作 `mepc` 指向的被打断指令，`mret` 后重放会翻倍副作用 ⇒ 用
   `mem_sideeff` 抑制一拍，等它进 WB 后取（`mepc` 精确指向下一条待执行指令）。
3. **`trap_take` 必须用门控后的 `intr_take`**（不能直接用 `intr_valid`）——否则在"被抑制但挂起"的拍会
   产生一条 `trap_is_int=0` 的伪同步陷阱（实测表现为 `mcause=3`、向量走 base 而非 base+4*3）。

#### 验证（本轮实测）

| 项 | 命令 | 结果 |
|---|---|---|
| 特权/陷阱定向自测 | `bash scripts/run_priv_trap_test.sh` | **`PRIV_TRAP: PASS (46 checks)`**（此前 40/41 + 5 SKIP） |
| CLINT/PLIC 单元 | `bash scripts/run_unit_clint_plic.sh` | **`CLINT_PLIC_UNIT: PASS (184 checks)`** |
| PMP 单元 | `bash scripts/run_unit_pmp.sh` | `PMP_UNIT: PASS (443 checks)` |
| 回归 | 18 组 + PMP 6 组 + hello/memtest + lrsc | **18 组 124 例全 PASS**；PMPS 11/11、PMPU 11/11、PMPZaamo 1/1、PMPZalrsc 1/1、PMPZca 12/15、PMPSm 37/38（例外见上轮）；`LRSC_DIRECTED: PASS`、`SIM: PASS hello/memtest` |

#### 已知限制（下一轮处理）

* **复位即 `mtip=1`**（`mtime=mtimecmp=0`，与真实 CLINT 一致）⇒ 软件启用 MTIE 前必须先写 `mtimecmp`；
  当前 arch-test 用例不启用 MTIE，故不受影响（已在 `rv32_clint.v` 头注明）。
* PLIC 只有 8 源、2 context（够当前平台 `intrpt[4:0]` 与 Linux 基本驱动）；**未经端到端 Linux 驱动验证**。
* 设备上的 LR/SC/AMO 未实现原子语义（按普通访问处理，已在 core 注释说明）。
* `PLIC` 文档窗口（spec/07 §8.2 与 spec/08）已按实际截获范围更正为 `0x1F10_0000–0x1F3F_FFFF`。

---

### 阶段 2A 进展（第 12 轮，2026-09-13）：平台收尾①（总线错误通道）+ 未接入组 Zimop/Zcmop

**结论**：① 取指/访存**总线错误通道**打通（此前未映射地址的读会返回全 0 并被当指令执行）；
② `Zimop`(40) 与 `Zcmop`(8) 两组**全绿**。全量回归无回退。

#### 交付物

| 文件 | 说明 |
|---|---|
| `rtl/bus/rv32_axi_master.v` | **缺陷修复（生产者侧）**：`if_rsp_err` 原先有两处硬写 0（复位 + `RD_FILL`），取指分支从不看 `rresp` ⇒ 核内新通道是死代码。改为逐 beat 锁存 `rd_err <= (rresp != 2'b00)`、新事务清零、`RD_FILL: if_rsp_err <= rd_err` |
| `rtl/frontend/rv32_ifetch.v` | 新增 `fetch_err`：出错行**不填充**、错误 sticky 保持到 `flush`、错误期间不再发请求 |
| `rtl/top/rv32gc_core.v` | **排空后取陷阱**：`fetch_stall = !line_valid && !fetch_err_pending`（错误期间不冻结流水线，靠 IF/ID 自动注入气泡让更老指令排空）；`if_err_take = fetch_err_pending && front_empty` → cause 1、`mepc=mtval=pc_q`；并强制 `flush` 清错误（否则 trap_vector 与出错 PC 同行时清不掉） |
| `sim/tests/fetch_err.S` + `scripts/run_fetch_err_test.sh`（新增） | **`FETCH_ERR: PASS (21 checks)`**：取指 0x9000_0000 / 0x8010_0000 → cause 1 + mepc=mtval=该地址；load→5、store→7 且 tval=VA；三处陷阱后恢复继续执行、故障点后指令**未提交**、MEM_HI 边界内侧访存对照 |
| `rtl/decode/rv32_decoder.v` | Zimop/Zcmop：`MOP.R.N`/`MOP.RR.N`（SYSTEM funct3=100）→ 合法 OP_ALU(ADD, A=ZERO/B=ZERO)、`rd_wen=(rd!=0)` ⇒ **写 0 到 x[rd]**（`zimop.adoc:26-41`）；`c.mop.N`（`c.lui` rd 奇且 nzimm=0 空间）→ 展开 NOP（不写寄存器，`zcmop.adoc:32-49`）；其余保留编码仍非法 |
| `sim/tests/unit/gen_decoder_vectors.py` + `decoder_vectors.vh` | 向量 254→**255**（合法 167/非法 88）：`0x6581` 由"非法 c.lui imm=0"更正为合法 **C.MOP.11**（`zcmop.adoc:44`），另补 `0x6601`（rd 偶，真保留）作非法向量；其余 252 条逐位不变 |

#### 验证（本轮实测；主 Agent 复跑）

| 项 | 结果 |
|---|---|
| 总线错误定向自测 | **`FETCH_ERR: PASS (21 checks)`**（24099 拍；修复前 21 项中取指 4 项失败：mcause=2、mtval=0 —— 证实"全 0 行被当指令执行"） |
| 未接入组 | **`Zimop 40/40`**、**`Zcmop 8/8`** |
| 译码器单元 | **`DECODER_UNIT_TESTS: PASS (255 vectors)`**（155→167 合法、88 非法） |
| 全量回归 | 非特权 **18 组 124 例** + PMPS 11/11 + PMPU 11/11 + PMPZaamo/Zalrsc 1/1 + PMPZca 12/15 + PMPSm 37/38（例外同前）+ `PRIV_TRAP: PASS (46)` + `LRSC_DIRECTED: PASS` + `hello`/`memtest` 全绿 |

#### 关键经验（写入工作方式）

* **"通道实现了"不等于"通路接通了"**：本次核内 drain-then-trap 写得再对，生产者（`rv32_axi_master`）不置错误位就全是死代码。判据必须来自**端到端定向测试**（本测试修复前 21 项中恰好只有取指 4 项失败）。
* **改 RTL 时实例端口连接也要核对**：本轮曾因一处 `.fetch_err()` 连接漏加，导致核内 `fetch_err` 悬空为 X → `advance_all` 变 X → 全核冻结（`hello` 超时）。批量改 RTL 后必须 `grep` 核对新增端口两端都存在。
* **规范定义的保留编码会随扩展实现变合法**：`0x6581` 在 Zcmop 未实现时非法、实现后就是 C.MOP.11；向量表属于**生成器产物**，应改生成器再重生成（本轮已按此处理并逐条比对未受影响项）。

---

### 第 13 轮：阶段 2A-③ Sv32 MMU（S0 基线 + S1 模块层 + TVM/TSR 强制）

**本项范围**：`🧭 Sv32 MMU 实施计划` 的 **S0（基线）与 S1（TLB/PTW 模块层）**，以及 MMU 前置的
`mstatus.TVM/TSR` 与 `mret/sret` 特权级强制（`sv_mstatus_tvm` 是 S0 实测的 FAIL 项）。核内集成
（S2 数据侧 / S3 取指侧 / S4 sfence.vma / S5 63 例验收）留待下一轮。

| 项 | 结果 |
|---|---|
| **S0 基线（MMU 前，实测）** | `priv/Svbare` **3/3 PASS**；`priv/Sv '^sv32_satp_access'` **1/1 PASS**；`priv/Sv '^sv_mstatus_tvm'` **FAIL**（`Trap count mismatch`：期望 4 个陷阱签名，实测 **0**）⇒ 证实 TVM 只存不判、`sfence.vma` 是空操作 |
| **TVM/TSR 强制（新增）** | `rtl/csr/rv32_csr.v`：新增输出 `mstatus_tvm`/`mstatus_tsr`；`csr_legal` 加 `tvm_satp_ill`（`priv==S && TVM && csr_raddr==SATP` ⇒ 非法，读-改-写全覆盖）。`rtl/top/rv32gc_core.v`：`id_sfence_ill`（U 模式**恒**非法；S 模式且 `TVM=1` 非法；M 模式恒合法）、`id_xret_ill`（`MRET` 仅 M 可执行；`SRET` 在 U 非法、在 S 且 `TSR=1` 非法）。`WFI` **故意不检查**：`norm:mstatustwumode_op` 允许"在实现特定的有界时间内完成"的实现，本核 WFI 立即完成 ⇒ S/U（含 `TW=1`）均合法 |
| **TVM 实测** | **`priv/Sv '^sv_mstatus_tvm' 1/1 PASS`**（修复前 FAIL）；`^sv32_satp_access` 1/1 PASS 无回退 |
| **MMU 模块层（S1，子 Agent 实现 + 主 Agent 复跑核实）** | `rtl/mmu/rv32_tlb.v`（150 行，参数化全相联 CAM，`hit=VALID&(G\|ASID==satp_asid)&(IS_4M?tag[19:10]==va[31:22]:tag[19:0]==va[31:12])`，多命中取最小项，rr 替换，`flush_all` 同拍优先）、`rtl/mmu/rv32_ptw.v`（252 行，`IDLE→L1→L2→RES`，每次 4B 读、`bus_req` hold-until-ack、`req` **上升沿**有效、`abort` 立即丢弃）、`sim/tests/unit/tb_unit_tlb_ptw.v`（767 行）、`scripts/run_unit_tlb_ptw.sh` |
| **S1 实测** | **`TLB_PTW_UNIT: PASS (155 checks)`**（主 Agent 独立复跑一致）；两个模块各自 `iverilog -g2005 -Wall -s <模块>` **零告警**；全量 RTL 编译告警无新增 |
| **S1 变异测试（子 Agent）** | **10/10 被捕获**：非叶 `D\|A\|U`、4M `ppn[0]!=0`、TLB ASID 匹配、基址 `ppn<<10`（任务书原文错误）、L2 非叶当叶子、4M 标签比整 20 位、`V=0`、`R=0&&W=1`、`is_4m` 漏报、结果态忽略 `req` 边沿；首轮 M1/M8 曾**假阴性**（漏判时另一条规则照样 fault 掩盖缺陷），已改成"漏判即 `done=1`"的构造 |
| **⚠ 任务书公式订正（重要）** | 我给子 Agent 的 PTW 基址公式 `{ppn,10'b0}`（= `ppn<<10`）**错 4 倍**；正确为 `ppn<<12`：`tools/spike/riscv/mmu.cc:732,787` `pte_paddr = base + idx*ptesize`（`base = ppn<<PGSHIFT`，`ptesize=4`，`PGSHIFT=12`）、`supervisor.adoc:1727-1730`。子 Agent 按规范实现并在 `rv32_ptw.v` 文件头留证；本核已按 `ppn<<12` 落地 |
| **规格文档订正（Sv39+ 口径泄漏）** | `07-priv-csr-mmu.md` §5.1 步骤 3「`pte[31:10]` 保留位非零 ⇒ 页错误」**错**（Sv32 的 `pte[31:10]` 全是 PPN；Spike `PTE_RSVD=0x07C0_0000_0000_0000` 是 64 位专用，`encoding.h:521`）；步骤 4「非叶不检查 A/D/U」**反了**（Spike `mmu.cc:751-753`：非叶带 `D\|A\|U` ⇒ 页错误，`G` 不非法）。两处已按 Sv32/Spike 更正，并同步 §5.2 表、勘误表第 11 条、`09-verification-interface.md` 的 MMU-08 / `ptw_illegal_pte` / `tlb_ad`（后者改为 **Svade** 口径：A/D=0 ⇒ 页错误且不改写 PTE） |
| **回归（不可退，全绿）** | 非特权 **18 组 124 例**（39/8/6/1/26/9/2/5/4/2/3/1/3/1/4/4/4/2）；`Svbare 3/3`；PMPS 11/11、PMPU 11/11、PMPZaamo 1/1、PMPZalrsc 1/1、PMPZca 12/15（3 例 ISA 不可达）、PMPSm 37/38（1 例平台口径）；`PMP_UNIT 443`、`CLINT_PLIC_UNIT 184`、`AXI_SLAVE_UNIT 79`、`EXEC_UNIT 2461`、`DECODER_UNIT_TESTS PASS`、`PRIV_TRAP 46`、`FETCH_ERR 21`、`LRSC_DIRECTED PASS`、`SPI_BOOT PASS`、`SIM: PASS hello`、`SIM: PASS memtest` |

#### 关键经验（本轮）

* **任务书里的公式也要按参考模型核**：`{ppn,10'b0}` 与 `ppn<<12` 差 2 位，若照抄会让所有页表基址落在错误地址；
  子 Agent 因读 Spike 源码而纠偏 —— **"以 Spike 为准"这条纪律对主 Agent 的指令同样适用**。
* **测试用例必须"漏判即失败"**：变异测试首轮 2 个假阴性说明，若用例在缺陷下仍因**另一条规则**报同样的错，
  就等于没测该规则。非法 PTE 的每条规则都要构造"去掉该规则后必然成功翻译"的场景。
* **回归期间不得改 RTL**：本轮中途改 RTL（TVM→TSR/MRET/SRET）导致上一轮回归不可归因，只能杀掉重跑；
  改完 RTL 再跑一次干净全量是唯一正确的做法。

---

### 第 14 轮：阶段 2A-③ Sv32 MMU 核内集成（S2~S5）+ 两个集成缺陷修复

**本项范围**：把上一轮的 `rv32_tlb`/`rv32_ptw` 接进核（取指侧 + 访存侧）、`sfence.vma`、取指页错误、
`priv/Sv` 等验收组。**结果：`Svbare 3/3` + `Sv ^sv32_ 28/31`（其余 3 例参考模型自己 FAIL）**。

| 项 | 结果 |
|---|---|
| 新增 `rtl/mmu/rv32mmu_top.v` | ITLB(8) + DTLB(16) + 单个 `rv32_ptw`；两个翻译口（取指组合口 / 访存请求口）；**D 优先**仲裁、只在 PTW 空闲时起遍历（保证 `req` 干净上升沿）；权限（U/SUM/MXR/R/W/X）与 **Svade** 的 A/D 在内部**逐次 live 判定**（TLB 只存 PTE 原值）；PA 拼装 4K=`{ppn[19:0],va[11:0]}`、4M=`{ppn[19:10],va[21:12],va[11:0]}` |
| 访存侧集成（`rv32gc_core.v`） | `M_IDLE` 内联等翻译（`!mem_addr_ready` 分支：页错误→复用"免请求+M_DONE+记 cause 13/15"范式；就绪→`m_addr_q<=mmu_d_pa`、`m_xlated_q<=1`）；保留 `M_XLATE` 作兜底态（8 个状态码已用完 ⇒ `memst_q` 扩到 4 位）；`mem_chk_addr` 统一供 PMP/CLINT/PLIC/总线使用（**全按 PA**），`tval` 仍为 VA |
| 数据总线通道与 PTW 复用 | MEM 优先、**同一时刻只允许一笔在途事务**（`d_busy_q` + `d_owner_ptw_q`），响应按归属分派（`ptw_bus_ack = d_rsp_valid && d_owner_ptw_q`）；FSM 推进改用 `d_req_take = d_req_valid && d_req_ready`（裸 `d_req_ready` 在 valid 被门控时会造成"不发请求也推进"） |
| 取指侧集成（`rv32_ifetch.v`） | 新增 `pa_valid/pa/xlate_fault` 输入与 `fetch_pf` 输出；**`hit`/`line_valid`/发请求三处全部门控**，行标签改存 **PA**（同一 PA 可多 VA 映射）；跨行指令补 `cross_pa_q`/`id_pa_q`（取指 PMP 必须查 PA，`tval` 仍 VA） |
| `sfence.vma` | WB 提交拍 `sfence_take` ⇒ TLB 全清 + PTW `abort` + **强制 `flush_front`**（按行号比对的 flush 覆盖不到同 PA 不同 VA）；S 模式且 `TVM=1` 时已在 ID 级报非法 |
| 取指页错误 | 与总线错误共用"停止取指 + 流水线排空后取陷阱"通道；`fetch_fault_cause = fetch_pf ? 12 : 1`，epc/tval = 出错取指 VA |
| CSR 补齐（验收必需） | `mcountinhibit`(0x320) 与 `mhpmevent3-31`(0x323-0x33F) 改为**存在**（WARL：读回所存位/0、写忽略）：参考模型认为它们合法，缺失会让 `sv32_mstatus_sbe_*` 多报 **31 个**非法指令陷阱；`mcountinhibit` 的 CY/IR 已真正停表（`mcycle`/`minstret`） |
| **缺陷 1（集成期，实测定位）** | `i_walk_done` 归属判反（写成 `!ptw_owner_q`，而 owner=1 才是取指侧）⇒ 取指遍历永不收货、**无限重走 L1**：实测同一页表地址 `0x8000c300` 被反复读、pc 冻结 60k 拍无提交。靠 MMU 内部临时打印（`satp_mode/owner/start`）一屏定位 |
| **缺陷 2（集成期，实测定位）** | 翻译完成后 `m_addr_q <= mem_addr_q` 把 **PA 覆盖回 VA** ⇒ 总线发 VA（实测 `0x30002280` 未翻译、AXI `err=1`、误报 cause 5）。修法：所有路径统一 `m_addr_q <= mem_chk_addr`，CLINT/PLIC 的 `.addr()` 同步改 PA |
| **缺陷 3（子 Agent 定位，我复核依据）** | **陷阱进入时错误清零 `mstatus.MPRV`**（`csr/rv32_csr.v`）⇒ `sv32_upage_mprv_set_sum_unset_Smode` FAIL：ACT 陷阱处理器靠 MPRV 判断 xEPC 是否需要重定位，签名 word2 差 `0x1f0`（=epc−代码段基址）。规范 `machine.adoc:413 norm:mstatusmprvclrmretsretlesspriv`：**只有 xRET 到 <M 才清 MPRV**；Spike `processor.cc` 全文不写 `mprv`（我复核 ✓）。删除该清零后该例 PASS |
| 验收（RV32 可跑子集，全部实测） | `Svbare 3/3`；**`Sv '^sv32_' 28/31**；`Svade '^sv32_Svade' 0/2`；`SvPMP '^sv32_pmp' 2/4`；`ExceptionsSv '^sv32_' 0/4`；`ExceptionsSvZaamo/Zalrsc '^sv32_' 0/3+0/3`；`SvZicbo '^sv32_' 2/6`；`SvPMPZicbo '^sv32_pmp' 0/8`（合计 35/64） |
| **3 例判为参考模型自身失败（有证据）** | `sv32_VA_all_ones_Smode`、`sv32_mstatus_sbe_set_Smode`、`sv32_mstatus_sbe_and_sum_set_Smode`：`sim/arch_test/out/*.spike.log` 里 `*** FAILED *** (tohost = 1)`，签名只剩起始标记 + `0xdeadbeef` 填充。**312 个参考日志里只有这 3 个失败**（`grep -l FAILED sim/arch_test/out/*.spike.log`），故不可作为判据 |
| 回归（不可退，全绿） | 非特权 **18 组 124 例全 PASS**；PMPS 11/11、PMPU 11/11、PMPZaamo/PMPZalrsc 1/1、PMPZca 12/15、PMPSm 37/38（例外同前）；`PMP_UNIT 443`、`CLINT_PLIC_UNIT 184`、**`TLB_PTW_UNIT 155`**、`AXI 79`、`EXEC 2461`、`DECODER PASS`、`PRIV_TRAP 46`、`FETCH_ERR 21`、`LRSC_DIRECTED PASS`、`SPI_BOOT PASS`、`hello`/`memtest` PASS |

#### 关键经验（本轮）

* **"冻结"类故障先看总线层**：实测"同一页表地址被反复读 + pc 冻结"直接指向遍历归属判定写反，比逐级打印流水线快一个数量级。
* **总线口仲裁三件套**：单笔在途（`busy`）、归属寄存器（`owner`）、FSM 推进用 `valid && ready`。少任何一件都会在"两个主设备抢一个口"时出现丢响应/假推进。
* **VA/PA 混用的代价是静默错**：`m_addr_q <= mem_addr_q` 这一行在 MMU off 时完全正确、on 时把 PA 覆盖回 VA；这类"同一寄存器两种语义"的写法必须**只有一个赋值点**（本轮统一成 `mem_chk_addr`）。
* **改共享 TB 后必须立刻编译自检**：本轮清理调试代码时把 `tb_trace_mem.v` 改坏（漏删一个块尾），随后整组 I 报 28 例"iverilog 编译失败"，一度被误读为功能回退 —— 已 `git checkout` 恢复并重跑，回归全绿。
* **参考模型失败必须先用证据排除**：`grep -l FAILED` 一次就能把 3 例"永远不可能通过"的用例识别出来，避免在错误目标上耗时间。

---

### 第 15 轮：阶段 2A-③ Sv32 MMU 收尾（一）：死锁 + 委托语义 + CSR 存在性 + LR/SC/SUM/MXR

**本轮把 `Sv`/`Svade`/`ExceptionsSv` 三个家族的验收从 35/64 推到 47/64**，其中 10 例（ExceptionsSv 家族）
由子 Agent 定位并修复、我已逐项复核。

| 项 | 结果 |
|---|---|
| **死锁修复（我，含证据）** | `mem_addr_ready` 补 `|| mem_misaligned`：翻译模式下遇到非对齐访问时，`mem_xlate_req` 因 `!mem_misaligned` 不发遍历，而 `mem_addr_ready` 仍为 0 ⇒ `M_IDLE` 死等 ⇒ **整核冻结**（探针实测：`memst=IDLE`、PTW 空闲、零总线流量、PC 冻结在 `0x300023a6`，VA=`0x9040d012` 正是非对齐访存）。依据 Spike `load_slow_path/store_slow_path` 中"非对齐判定先于 `translate()`"（`tools/spike/riscv/mmu.cc:293-294`）。修前 `ExceptionsSv*` 10 例全是 300k 拍 TIMEOUT，修后 ~70k 拍出结果 |
| **RV32 高半 CSR 存在性（我）** | 新增 `CSR_SENVCFGH 12'h11A`（defs）并把 `CSR_MENVCFGH(0x31A)`/`CSR_SENVCFGH(0x11A)` 加进 `csr_exists`（RO 0）。证据：`sv32_Svade_{S,U}mode` 的第一条陷阱是 **M 模式下 `csrc 0x31a`**（反汇编 `0x80002158: 31a2b073`），参考模型认为合法、我们报非法指令 ⇒ 整条陷阱序错位（表观症状"陷阱在 M 模式处理而参考在 S 模式"）。修后 **`Svade '^sv32_Svade' 2/2 PASS`** |
| **委托语义（子 Agent，我复核）** | 陷阱**不得**从高特权级委托到低特权级：`cause_priv` 加 `deleg_en=(priv != PRV_M)`。依据 machine.adoc「Traps never transition from a more-privileged mode to a less-privileged mode」+ Spike `processor.cc:438-443`（`hsdeleg=(prv<=S)?medeleg:0`）。修复 `*_mprv_{S,U}_Mmode`/`Zaamo_Mmode` 的 M 模式陷阱被错误交给 S 模式 |
| **`RVMODEL_ACCESS_FAULT_ADDRESS`（子 Agent，我复核）** | 本 DUT 声明从 `0x0` 改为 `0x4000_0000`：`0x0` 在本平台是 **DDR3 + 复位桩**（`docs/kb/01-chiplab-platform.md:45`），对 `0x0` 的 store/load/fetch **根本不 fault**（实测 Case 3 的 `jalr` 直接执行了 PA 0 的桩代码并跳回）。新地址在仿真从设备是 `R_NONE→SLVERR`、Spike 默认内存映射同样未映射 ⇒ 参考与 DUT 都必 fault。**注**：该宏变更会让相关用例的参考签名由 Spike 重新生成（`arch_test_build.sh` 自动做） |
| **LR/SC 三处（子 Agent，我复核）** | ① 保留集比较改用 **PA**（`mem_chk_addr`，Spike 存/比 paddr，`mmu.cc:259`/`mmu.h:285`）——原来用 VA，开翻译后 `sc.w` 恒失败；② 保留集无效时失败 SC **也要上总线**（`wstrb=0` 抑制写），让互连给出 store access fault（`mmu.h:274-292`）；③ 非对齐 **LR 报 cause 4**（load 侧），SC/AMO 才是 6（`mmu.h:124`） |
| **mstatus.SUM/MXR 同拍旁路（子 Agent，我复核）** | `csrs sstatus,(SUM\|MXR)` 后紧跟的访存同拍读到的还是旧值（CSR 要到时钟沿才更新），而 MMU 权限判定是 **MEM 级组合判定** ⇒ 3 个 `*_Umode` 用例误报页错误。新增 `sum_eff/mxr_eff` 旁路并接到 `rv32mmu_top` |
| **验收（RV32 可跑子集，实测）** | `Svbare 3/3`、`Sv '^sv32_' 28/31`（3 例参考自失败）、**`Svade 2/2`**、`SvPMP 2/4`、**`ExceptionsSv 4/4`**、**`ExceptionsSvZaamo 3/3`**、**`ExceptionsSvZalrsc 3/3`**、`SvZicbo 2/6`、`SvPMPZicbo 0/8` ⇒ **47/64** |
| 回归（不可退，全绿） | 非特权 **18 组 124 例全 PASS**；PMPS 11/11、PMPU 11/11、PMPZaamo/PMPZalrsc 1/1、PMPZca 12/15、PMPSm 37/38（例外同前）；`PMP_UNIT 443`、`CLINT_PLIC_UNIT 184`、`TLB_PTW_UNIT 155`、`AXI 79`、`EXEC 2461`、`DECODER PASS`、`PRIV_TRAP 46`、`FETCH_ERR 21`、`LRSC_DIRECTED PASS`、`SPI_BOOT PASS`、`hello`/`memtest` PASS。`run_sim.sh hello` 墙钟 **0.96 s**（未新增 PMP 实例，仿真未变慢） |
| 剩余（下一轮） | ① `SvPMP on_pte_{S,U}mode` 2 例（EPC 落在 `failedtest_saveresults_common`，是二次效应，真因在前）；② `SvZicbo 4` + `SvPMPZicbo 8` 依赖 **④ CBO 真正生效**；③ `PMPSm_cfg_A_tor_zero-00`（PA 0 平台口径，已记录）；④ 3 例参考自失败（不可作为判据） |

#### 关键经验（本轮）

* **"陷阱在 M 模式处理、参考在 S 模式"这类表观症状几乎都源于"多了一条参考没有的陷阱"**：先用 `XEPC` **反汇编那条指令**（`/opt/riscv/bin/riscv32-unknown-linux-gnu-objdump -d --start-address=<epc> --stop-address=<epc+8>`），
  本轮两例都是这样一眼定位（`csrc 0x31a` = menvcfgh 不存在、PA 0 桩代码不 fault）。
* **CSR "存在性"是验收的隐形前提**：参考模型实现了而我们没实现的 CSR（menvcfgh、mhpmevent3-31）会让
  M 模式前导码/清理代码报非法指令，症状却是"完全无关的用例失败"。补"存在但 RO/WARL"比补功能便宜得多。
* **委托方向**：`medeleg` 只在"当前特权级 ≤ S"时才生效（`priv != M`）；忘了这条会让 M 模式下的陷阱
  被错误交给 S 模式，整个陷阱序错位。
* **平台地址属性属于 DUT 声明**：`RVMODEL_ACCESS_FAULT_ADDRESS` 必须指向**本平台真的会 fault** 的地址
  （本项目 0x0 是 DDR+复位桩）；这是"把平台事实写对"，不是放宽用例。

---

---

### 第 16 轮：阶段 2A-⑤（2A-7b 启动镜像三件套 + 2A-7c DTS/内存映射声明）

| 项 | 结果 |
|---|---|
| **2A-7c DTS（交付物）** | 新增 `sw/board/rv32gc-chiplab.dts`（RV32-GC + chiplab SoC 设备树）。地址**逐项与 RTL 常量对齐**：DDR `0x0`+128 MiB、SPI-XIP `0x1C00_0000`（1 MiB）+ 别名 `0x1FE8_0000`、核内 CLINT `0x1F00_0000`、核内 PLIC `0x1F10_0000`（`riscv,ndev=8`）、UART0 寄存器块 `0x1FE0_01E0`、NAND `0x1FE7_8000`（数据口 `+0x40`）+ 四分区（env/kernel/dtb/rootfs = 128 MiB） |
| **2A-7c 可验证检查（新增）** | `scripts/check_dts.sh`：① `dtc` 编译 + 反编译；② **DTS ↔ `rtl/pkg/rv32gc_defs.vh` 交叉校验**（DDR_BASE/SIZE、SPI_XIP_BASE/ALIAS、CLINT_BASE、PLIC_BASE 直接比对）；③ 平台事实与硬判据（UART/NAND 偏移、`mmu-type=sv32`、`ndev=8`、`interrupts-extended` 3/7 与 11/9、SPI boot 分区 ≤1 MiB、NAND 分区总长=128 MiB、env=256 KiB@0）。实测 **`CHECK_DTS: PASS (17 ok / 0 fail)`** |
| **2A-7c 文档** | `docs/porting/00-overview.md` 新增 §8：内存映射表 + OpenSBI 适配五条（`FW_TEXT_START=0x0`、**早期启动不得开 MMU**（D16）、CLINT/PLIC/UART 驱动选择、`timebase-frequency=50 MHz`、无需 `platform_override`、DTB 从 NAND `dtb` 分区读） |
| **2A-7b 启动镜像三件套** | 新增 `sw/board/spi_stub.S`（**真实引导桩**：全 PC 相对取址、UART0 初始化(8N1/115200)、打印横幅、跳 DDR `0x0`、panic 码）、`sw/board/ddr_main.S`（**DDR 主镜像入口桩**，按 `0x0` 链接，打印横幅后交棒 `__opensbi_entry`；仿真下写 IO_SIMU=0 正常退出）、`sw/board/spi_stub.ld`、`sw/board/ddr_main.ld`、`scripts/pack_boot_image.sh` |
| **打包硬判据（全部实测）** | **`PACK_BOOT: PASS (SPI 333B/1MiB, 重定位 0, DDR entry 0x0)`**：SPI 镜像 ≤1 MiB（本桩仅 333 B）、SPI 桩**重定位表为空**（⇒ 全 PC 相对）、DDR 镜像 `_start=0x0`、`spi_flash.img` = 1 MiB（未用区 0xFF）、`boot_layout.txt` 输出 SPI/DDR/NAND 布局与 `mtdparts` |
| **2A-7b 端到端仿真验收（新增）** | `scripts/run_boot_chain_test.sh`：用**真正要烧写的产物**（`spi_stub.sim.hex` + `ddr_main.sim.hex`）跑 `tb_spi_boot`，断言 ① 复位取指在 SPI-XIP 窗口；② SPI 桩横幅出现、且早于 DDR 横幅；③ TB 的 CHECK-1..4（SPI 提交/DDR 提交/跨窗口取指）；④ 退出码 0。实测 **`BOOT_CHAIN: PASS`**（cycles=9123） |
| **本轮踩的坑（两条，写进经验）** | ① `iverilog -DRESET_PC=0x1C000000`（C 风格 `0x`）会**破坏 `rv32gc_core.v` 的解析**，报出一个和真实原因毫无关系的 `syntax error`（+ 满屏 "implicit definition" 警告）；必须写 Verilog 字面量 `32'h1C000000`（`run_spi_boot_test.sh` 一直是对的）。② 桩里第二处 `auipc t0,0` 取到的是**该指令**的 PC 而非桩首址 ⇒ 二次跳转落到 `0x5C`（DDR 镜像中间）；改为在入口处记录"实际基址偏移 s0"再抵消 |

#### 关键经验（本轮）

* **配置/声明的"可验证化"**：DTS 这种"写了不跑"的交付物，价值全在**交叉校验**——把 DTS 地址与 RTL 常量逐项比对后，"文档与实现漂移"这类隐性缺陷变成了一条命令的红/绿。
* **引导链必须用"真产物"验**：单元级链路自测（`sim/tests/spi_boot.S`）证明通路存在；`sw/board/*` + 打包脚本 + `run_boot_chain_test.sh` 证明**要烧写的那两个镜像**能串起来。
* **命令行长选项也会"看起来无关"地炸掉编译**：`-D` 的值必须与语言字面量一致（Verilog 用 `32'h…`），否则报错位置在别处、复现命令又恰好和回归不同 ⇒ 排查成本极高。看到"某文件语法错误 + 满屏 implicit definition"先怀疑**预处理宏**而不是文件内容。

---

---

### 第 17 轮：阶段 2A-④ 第一步（CBO 真正生效）+ ③ 收尾（页表读 PMP）—— **③ 完成**

**结果：MMU 验收 47/64 → 61/64（可判定项 61/61 全过；余 3 例为参考模型自身 FAIL）；CBO 相关 18 例全绿。**

| 项 | 结果 |
|---|---|
| **根因 A：CBO 被当成 ECALL** | CBO 原译码 `op_class=OP_SYS` 且 `sys_op` 缺省 0 ⇒ 核内 `id_ecall` 把它当 **ECALL**（S=9/M=11），T-SBI 框架打印 `tsbi_instr_table` 查不到 ⇒ `SvZicbo` 全挂的直接原因 |
| **根因 B：CBO 没有访存通路** | 不翻译、不查 PMP、无副作用。改为 `OP_LSU + mem_op=MEM_CBO`（新宏 `MEM_CBO 3'd6`），在 `M_IDLE` 复用既有 `翻译→PMP→总线` 通路 |
| CBO 语义（照 Spike `mmu.h:237-266`） | ZERO：`d_is_store=1`（W 权限）、PMP 只查**操作数 1 字节**、对 `PA & ~31` **真写 8 个 4 字节 0**；CLEAN/FLUSH/INVAL：`d_is_store=0`（LOAD 权限）、不写内存、只发一笔块基址读做可访问性判定；两类 cause 一律 **store 变体 15/7**（`convert_load_traps_to_store_traps`，与 AMO 同机制）；CBO 无对齐要求；`menvcfg/senvcfg` 许可检查保持原样 |
| **③ 收尾：页表读的 PMP 检查** | PTW 的每次 PTE 读按 Spike `pmp_ok(pte_paddr,4,LOAD,**PRV_S**)`（`mmu.h:490`）检查：拒绝/总线错误 ⇒ **访问错误**（cause 按原访问类型 1/5/7，tval=原 VA，`mmu.cc:596`）；结构性非法 PTE 才是页错误。**PMP 引擎未新增实例**（与 MEM 分时复用 `u_pmp_d`，仿真无变慢）⇒ 一并修好 `SvPMP on_pte_{S,U}mode` |
| 回归中发现并修掉的两个真问题 | ① `mem_needs_fsm` 加 `&& !mem_excp_valid_q`：带 ID 级精确异常（非法指令）的指令**不得有访存副作用**，否则 `cbo.zero` 在许可不足判非法后仍会写 32 字节（非特权 `Zicboz-cbo.zero-00` 由 PASS 变 FAIL）；② CBO 块内写循环标志残留会让紧随 `cbo.clean` 的 SC/AMO 误续写 7 个 0 |
| **验收（RV32 可跑子集，我本轮亲自复核全量回归）** | **`Svbare 3/3`、`Sv '^sv32_' 28/31`（3 例参考自失败）、`Svade 2/2`、`SvPMP 4/4`、`ExceptionsSv 4/4`、`ExceptionsSvZaamo 3/3`、`ExceptionsSvZalrsc 3/3`、`SvZicbo 6/6`、`SvPMPZicbo 8/8` = 61/64**；另非 Sv 的 `PMPZicbo 4/4`（此前 0/4） |
| 回归（不可退，全绿） | 非特权 **18 组 124 例**；PMPS 11/11、PMPU 11/11、PMPZaamo/PMPZalrsc 1/1、PMPZca 12/15、PMPSm 37/38（例外同前）；`PMP_UNIT 443`、`CLINT_PLIC_UNIT 184`、`TLB_PTW_UNIT 155`、`AXI 79`、`EXEC 2461`、`DECODER PASS`、`PRIV_TRAP 46`、`FETCH_ERR 21`、`LRSC_DIRECTED PASS`、`SPI_BOOT PASS`、`hello`/`memtest` PASS（墙钟无显著变慢） |
| 测试侧同步 | `sim/tests/unit/gen_decoder_vectors.py` + `decoder_vectors.vh`（CBO 译码期望改 OP_LSU/MEM_CBO，否则 DECODER 单测挂）、`tb_unit_tlb_ptw.v`（PTW 新端口接线，仍 155 checks）、新增 `sim/tests/cbo_directed.S`（定向验证真清零/clean 无副作用/AMO 不被污染） |

#### 已知遗留（写入 §7，不隐瞒）

* CBO 落到**平台真实设备窗口**（UART/NAND…）会真的读写该设备（本核无静态 PMA）；若 B2/B3 有 MMIO 上的 CBO 语义要求，需加窗口白名单。
* `cbo.clean` 用"一笔块基址 4 字节读"代替 Spike 的 PMA `reservable` 检查：纯内存语义等价，MMIO 有细微差别。
* CBO 清零是无 Cache 下的 8 拍串行写：语义正确、性能非最优（④ Cache 完成后可自然改善）。

---

---

### 第 18 轮：④ L1I Cache 落地 + 上游仓库知识库（用户拍板后的第一批）

| 项 | 结果 |
|---|---|
| **L1I Cache（子 Agent 实现 + 主 Agent 复核）** | 新增 `rtl/frontend/rv32_icache.v`：**16 KB = 128 组 × 4 路 × 32 B**；**VIPT**（组索引 `pa[11:5]`（=页内位，无别名）、标记 `pa[31:12]` 物理地址）；轮转 RR 替换；单未完成缺失；插入点在 `rv32_ifetch` 与 `rv32_axi_master` 之间（前端本来就按 32 B 整行请求）。`parameter ENABLE`（0=直通基线） |
| **D16② XIP 绕 Cache（硬要求）** | 请求侧 `req_xip`（`rv32_ifetch.req_xip_q` 新输出）+ 模块内 `` `IS_SPI_XIP `` **双判** ⇒ 禁止命中；填充侧按**在途请求地址**再判 ⇒ 不写阵列、不置 valid；XIP 请求照常走总线 |
| **`fence.i`** | 提交拍 `fencei_take` ⇒ L1I 整表失效（1 拍清 512 valid 位）**并入 `flush_front`**；在途填充被打断则丢弃+同址重发。`sfence.vma` 不需失效 Cache（PA 标记 + 页内索引） |
| **性能（硬判据）** | **`memtest` 2,026,669 → 1,116,795 拍（−45.0%）**；L1I 访问 82005 / 命中 81976（99.96%）/ 缺失 29 ⇒ **AXI 取指 82005 → 29 笔**。`hello` 352 → 347（全程仅 4 次 Cache 访问，347 拍由数据通路 27 笔未缓存 AXI 事务主导，已用数据说明不属 L1I 可改善范围） |
| **新增验证** | `ICACHE_UNIT: PASS (36 checks)`（命中/缺失、XIP 别名窗口、`req_xip` 漏接凭地址也拦住、RR 顺序、**fence.i 打断在途填充**、ENABLE=0 直通）；`FENCEI_SMC: PASS (9 checks)`（自改码定向，附**反证实验**：把 `.invalidate(fencei_take)` 改 0 后该测试立即 FAIL ⇒ 测试确实有效）；`XIP_NOALLOC: PASS (142 checks)`（SPI_BOOT）/ `PASS (5059 checks)`（BOOT_CHAIN）——TB 逐拍断言 XIP 期间填充写使能与地址 |
| **回归（子 Agent 冻结版跑两次 + 主 Agent 独立复核 4 项）** | 非特权 **18 组 124 例 0 FAIL**；PMP `PMPS 11/11 PMPU 11/11 PMPZaamo/PMPZalrsc 1/1 PMPZca 12/15 PMPSm 37/38`；MMU `Svbare 3/3 Sv 28/31 Svade 2/2 SvPMP 4/4 ExceptionsSv 4/4 Zaamo 3/3 Zalrsc 3/3 SvZicbo 6/6 SvPMPZicbo 8/8`；单元 `PMP 443 / TLB_PTW 155 / EXEC 2461 / DECODER 255 / AXI 79`；定向 `PRIV_TRAP 46 / FETCH_ERR 21 / LRSC PASS / SPI_BOOT PASS / BOOT_CHAIN PASS / hello PASS / memtest PASS` |
| **与规格的裁剪（已记录）** | 未做 `03-cache.md` 的 IF0/IF1/IF2 流水前端、fetch_queue、16 B 块、MSHR 阵列、next-line 预取、伪 LRU（本核前端是"单行缓冲 + 整行请求"，按 `AGENT.md` §7 ④ 的最小可用裁剪）；`fence.i` 存在"提交拍前已进 ID 的至多 1 条更年轻指令不丢弃"的理论窗口（全部回归 + SMC 定向未暴露） |
| **知识库（用户拉取的上游仓库）** | `.dsh-kb/sources.json` 新增 5 条源：`upstream-linux`（7.3-rc2；`Documentation/arch/riscv`、DT bindings、`arch/riscv/configs`）、`upstream-uboot`、`upstream-opensbi`（含 `include/sbi/**` 接口头）、`chiplab-la32r-{uboot,linux}`（参考移植）。**reindex 实测 433→3736 文档、5158→15640 片段**（204 s）；检索验证命中 `u-boot/doc/board/emulation/qemu-riscv.rst`、`linux/.../sifive,plic-1.0.0.yaml` 等 |
| **知识提炼（子 Agent）** | `docs/porting/08-upstream-repos-knowledge.md`（291 行，每条事实带仓库内路径）。**它指出 4 处与本设计的冲突**：① DTS 的 `sifive,clint0/plic-1.0.0` 被 binding 标为 deprecated/QEMU 专用、CPU 节点 `compatible="riscv"` 属 simulator-only ⇒ 建议加 `chiplab,` 前缀；② `jedec,spi-nor` 直挂 soc 不符 SPI 外设模型 ⇒ 改 `cfi-flash`+`fixed-partitions`；③ OpenSBI RV32 默认 `FW_PAYLOAD_ALIGN=0x400000` ⇒ 与 07 文档 `TEXT_BASE=0x0020_0000` 冲突，需 `FW_PAYLOAD_OFFSET` 或改 TEXT_BASE；④ `timebase-frequency` 应为 33 MHz（用户已定）、UART `reg-io-width` 必须与 RTL 窗口位宽一致。**这些待用户审阅后统一修**（已列入 §7） |

#### 关键经验（本轮）

* **XIP 绕 Cache 需要"请求侧 + 填充侧"双判**：只看请求侧会漏掉"命中已被缓存过的 XIP 行"；填充侧必须按**在途请求地址**判，不能按当前请求判。
* **性能判据要选对基准程序**：`hello` 是数据通路/串口主导（−1.4% 无意义），`memtest` 才反映取指局部性（−45%）——报告里必须解释清楚，否则会被误读为"Cache 没生效"。
* **定向测试要配反证实验**：`fence.i` 测试通过后，把失效信号强制为 0 再跑一次能 FAIL，才证明测试真的在测这件事（本轮已做）。

---

---

### 第 19 轮：全量回归入口固化 + 终版回归证据（审阅用）

| 项 | 结果 |
|---|---|
| **固化单一回归入口** | 新增 `scripts/run_full_regression.sh`（支持 `nonpriv`/`pmp`/`mmu`/`units`/`progs` 子集），逐项打印 `PASS=x FAIL=y / 共 z`，并与**内置基线表**比对，末尾输出"偏离基线"清单；汇总写入 `sim/log/full_regression_summary.txt`。程序段按 **TB 日志**判定（`TB: TEST PASS`）并在汇总里带上 cycles |
| **终版回归（审阅证据）** | **`FULL_REGRESSION: PASS （PASS 计数=279 / FAIL 计数=7）`，偏离基线清单为空**（7 个 FAIL 全部是基线已知例外：`PMPZca` 3 例 ISA 不可达、`PMPSm_cfg_A_tor_zero-00` 平台 PA-0 口径、`Sv` 3 例参考模型自身 FAIL）。含 `hello` **347 拍**、`memtest` **1,116,795 拍**（L1I −45.0%） |
| 明细（同一份汇总） | 非特权 18 组 = `I 39 / M 8 / Zicsr 6 / Zifencei 1 / Zca 26 / Zaamo 9 / Zalrsc 2 / Misalign 5 / MisalignZca 4 / Zicntr 2 / Zicbom 3 / Zicboz 1 / Zicbop 3 / Zihintpause 1 / Zihintntl 4 / ZihintntlZca 4 / Zmmul 4 / Zicond 2` = **124 例 0 失败**；PMP `PMPS 11 / PMPU 11 / PMPZaamo 1 / PMPZalrsc 1 / PMPZca 12(3) / PMPSm 37(1)`；MMU `Svbare 3 / Sv 28(3) / Svade 2 / SvPMP 4 / ExceptionsSv 4 / Zaamo 3 / Zalrsc 3 / SvZicbo 6 / SvPMPZicbo 8 / PMPZicbo 4`；单元 `PMP 443 / CLINT_PLIC 184 / TLB_PTW 155 / ICACHE 36 / AXI 79 / EXEC 2461 / DECODER`；定向 `PRIV_TRAP 46 / FETCH_ERR 21 / LRSC / FENCEI_SMC / SPI_BOOT / BOOT_CHAIN`；DTS `CHECK_DTS 17`、打包 `PACK_BOOT` |

**状态小结（供用户审阅）**：① ② ③ ⑤ 完成；④ 的 CBO 与 **L1I** 完成、**L1D（+可选 L2）待做**（方案见 §7 ④）；
⑥ 计划草案已按用户 5 项拍板更新，另有 4 处 DTS/计划修正待用户审阅后统一处理（见 §7 📌）。
**上板（2A-7d）未开始**，等用户审阅。

---

---

### 第 20 轮：用户审阅通过后的 ① 步 —— DTS/计划 4 处修正（33 MHz 上板口径）

| 项 | 结果 |
|---|---|
| DTS compatible 厂商前缀 | CPU `chiplab,rv32gc", "riscv"`；CLINT `"chiplab,clint", "sifive,clint0"`；PLIC `"chiplab,plic", "sifive,plic-1.0.0"` —— 去掉 binding 标 deprecated 的 `riscv,clint0`/`riscv,plic0`，CPU 节点不再只有 simulator-only 的 `riscv` |
| SPI flash 节点口径 | 改**内存映射 flash**（`cfi-flash` + `fixed-partitions`），并注明"本阶段只做 XIP 读、SPI 控制器寄存器接口未建模"；不再用直挂 soc 的 `jedec,spi-nor` |
| UART 口径 | 去掉 `reg-io-width = <4>`：参考 `la32r-Linux/arch/loongarch/boot/dts/loongson/loongson32_ls.dts` 的 UART 节点只给 `reg = <0x1fe001e0 0x10>` + `clock-frequency = <33000000>`（**字节步进**）；`bootargs` 的 earlycon 相应改 `uart8250,mmio,0x1fe001e0`（不是 `mmio32`） |
| 时钟 33 MHz 落实 | DTS `timebase-frequency` 与 CPU `clock-frequency` 均 `33000000`；计划 §8 D-1 明确 **cpu_clk 取 `clk_pll_33` 的 `clk_out2`(33 MHz)**、`config.h` 的 `FREQ` 同步改、时序目标 33 MHz |
| OpenSBI/U-Boot 链接决策（计划 §10.1 新增） | OpenSBI `FW_TEXT_START=0x0`；**U-Boot `CONFIG_TEXT_BASE=0x0040_0000`**（与 OpenSBI RV32 默认 `FW_PAYLOAD_ALIGN=0x400000` 一致；备选 `FW_PAYLOAD_OFFSET=0x200000` + `TEXT_BASE=0x0020_0000`，二者必须一致）；内核建议 `0x0200_0000` 起；附构建命令口径（`qemu-riscv32smodedefconfig`、`PLATFORM=generic PLATFORM_RISCV_XLEN=32 FW_PAYLOAD_PATH=…`、`make ARCH=riscv rv32_defconfig` —— **主线没有 rv32_defconfig 文件**，只有同名 make 目标 ≡ defconfig + 32-bit.config 片段） |
| 验证 | `bash scripts/check_dts.sh` → **`CHECK_DTS: PASS (17 ok / 0 fail)`**（timebase 断言已改 33 MHz）；DTS 仍通过 `dtc` 编译/反编译 |

---

## 7. 当前状态与下一阶段计划

**当前状态（2026-09-13，阶段 2A 进行中）**：已完成第 1~9 轮。
- ✅ 仿真/回归环境（iverilog + Verilator + Spike 参考模型 + 自研 TB + 锁步工具链）已建成
- ✅ 顺序 5 级基线核跑通 `hello`、`memtest`；单元测试全绿（AXI 79 / EXEC 2461 / DECODER 254）
- ✅ **arch-test 18 组 124 例 0 失败**（I 39/M 8/Zicsr 6/Zifencei 1/Zca 26/Zaamo 9/Zalrsc 2/Misalign 5/
  MisalignZca 4/Zicntr 2/Zicbom 3/Zicboz 1/Zicbop 3/Zihintpause 1/Zihintntl 4/ZihintntlZca 4/Zmmul 4/Zicond 2；
  第 9 轮**全量复跑实测**——此前文档写的"17 组 123 例"是漏计一组/一例，以本行为准）
- ✅ **A 扩展定向自测**（`bash scripts/run_lrsc_test.sh` → `LRSC_DIRECTED: PASS`）
- ✅ **锁步 5994 条提交与 Spike 完全一致**（`sim/tests/out/lockstep_bench_hi.elf`）
- ✅ **SPI-XIP 启动链路（2A-7a，第 9 轮）**：`bash scripts/run_spi_boot_test.sh` → **`SPI_BOOT: PASS`**
  （`RESET_PC=0x1C00_0000` → SPI 窗口取首条指令 → 跨 ~448 MiB 跳 DDR `0x0` → 退出码 0）；D16② 的
  "取指命中 SPI 窗口绕过 I-Cache"判定点已落地（当前无 Cache，行为中性）
- ✅ **PMP（2A-3 收尾，第 10 轮）**：16 项 + 锁定语义 + S/U 访问检查；`run_unit_pmp.sh` → `PMP_UNIT: PASS (443)`；
  `tests/priv` PMP 组 **73 / 73 可达用例通过**（PMPSm 37/38、PMPS 11/11、PMPU 11/11、PMPZaamo 1/1、
  PMPZalrsc 1/1、PMPZca 12/15；1 例平台口径差异 + 3 例 ISA 不可达见 §6）；回归 18 组 124 例 + 单元测试 + hello/memtest + lrsc 全绿
- ✅ **中断投递 + 核内 CLINT/PLIC（第 11 轮）**：`priv_trap.S` → `PRIV_TRAP: PASS (46 checks)`；
  `CLINT_PLIC_UNIT: PASS (184)`；回归 18 组 124 例 + PMP 6 组无回退
- 🚧 **阶段 2A 上板前收尾（第 12 轮起；用户要求不做上板）**——进度：
  * ✅ ① 总线错误通道（取指 cause 1 + load/store 5/7，`FETCH_ERR: PASS (21)`）；物理 0 口径仍记为平台约定差异（详见上板计划）
  * ✅ ② `Zimop 40/40`、`Zcmop 8/8`
  * ✅ **③ Sv32 MMU 已完成（第 17 轮，验收 61/64 —— 可判定项全过）**：`Svbare 3/3`、`Sv '^sv32_' 28/31`
    （余 3 例为**参考模型自身 FAIL**）、`Svade 2/2`、`SvPMP 4/4`、`ExceptionsSv 4/4`、`ExceptionsSvZaamo 3/3`、
    `ExceptionsSvZalrsc 3/3`、`SvZicbo 6/6`、`SvPMPZicbo 8/8`（另非 Sv 的 `PMPZicbo 4/4`）。
  * ✅ **④ 的 L1I 部分已完成（第 18 轮）**：`rtl/frontend/rv32_icache.v`（16 KB/4 路/32 B、VIPT、RR、
    单未完成缺失、XIP 双判、`fence.i` 整表失效、`ENABLE` 安全阀）⇒ **`memtest` 2,026,669 → 1,116,795 拍
    （−45.0%）**、AXI 取指 82005 → 29 笔；新增 `ICACHE_UNIT 36`、`FENCEI_SMC 9`、`XIP_NOALLOC 142/5059`。
  * ⏭ **④ 剩余部分＝L1D（+ 可选 L2）**：按 §7 的最小正确版（**写直达 + 不写分配**、读分配、RR、
    SPI-XIP 窗口同样绕 Cache）+ 五条验证（回归不回退 / SPI_BOOT·BOOT_CHAIN / cycles 下降 /
    XIP 不分配断言 / fence.i）。**用户已拍板"先把 Cache 做出来再上板"**，故 L1D 是上板前的最后一项 RTL 工作。
  * 📌 **待用户审阅后统一修（来自 `docs/porting/08-upstream-repos-knowledge.md` 的 4 条冲突）**：
    ① DTS 加 `chiplab,` 前缀（`sifive,clint0`/`sifive,plic-1.0.0`/CPU 节点 `riscv` 均为 deprecated 或
    simulator-only）；② SPI flash 节点改 `cfi-flash` + `fixed-partitions`（`jedec,spi-nor` 直挂 soc 不符模型）；
    ③ OpenSBI RV32 `FW_PAYLOAD_ALIGN=0x400000` 与文档里的 U-Boot `TEXT_BASE=0x0020_0000` 冲突 ⇒ 定
    `FW_PAYLOAD_OFFSET`/`TEXT_BASE`；④ `timebase-frequency` 改 **33 MHz**（用户第 8 轮定）、UART
    `reg-io-width` 与 RTL 窗口位宽对齐。
  * 🔜 **③ 的剩余工作（下一轮优先级最高，按此顺序）**：
    1. **`ExceptionsSv` 系列 10 例**（`ExceptionsSv 0/4`、`ExceptionsSvZaamo 0/3`、`ExceptionsSvZalrsc 0/3`）：
       现在**不是签名不符而是"慢到超时"** —— 实测 `sv32_exceptions_Smode` 60k 拍只有 649 条提交
       （≈92 拍/指令），且内核一直在取指；先用 `tb_trace_mem` + 计数（每次翻译/每次 PTW 读/每次 sfence）
       确认是否"每拍重复翻译"或"每次陷阱后全清 TLB 导致反复重走"。**这是一条根因、10 例一起收**。
    2. `Svade 0/2`：A/D 页错误语义（Svade 不改写 PTE）与参考的差异逐字段比对。
    3. `SvPMP 2/4`：PMP 作用在 PA 之后的边界用例。
    4. `SvZicbo 2/6` + `SvPMPZicbo 0/8`：**依赖 ④ 的 CBO 真正生效**（CBO 现在只是走 MEM FSM 的空操作），
       与 ④ 同轮做。
    **第 15 轮已收掉 1~3 的大部分**：`ExceptionsSv 4/4`、`ExceptionsSvZaamo 3/3`、`ExceptionsSvZalrsc 3/3`、
    `Svade 2/2`（见 §6 第 15 轮）。**仍剩 `SvPMP on_pte_{S,U}mode` 2 例**（EPC 落在
    `failedtest_saveresults_common`，属二次效应；`on_pa` 两例已 PASS，差异集中在"PMP 作用在页表访问上"）。
  * 🔜 **④ 的实现方案（第 16 轮执行；方案已按 Spike 逐条核对，可直接照做）**：
    * **第一步：CBO 真正走内存通路**（收 `SvZicbo` 4 例 + `SvPMPZicbo` 8 例）。
      Spike 语义（`tools/spike/riscv/mmu.h:237-266`，以它为准）：
      - `cbo_zero`：按 **STORE** 类型生成访问（`generate_access_info(addr, STORE, {})`），
        `translate(access_info, **1**)`（仅对操作数那 1 字节做 PMP 检查），
        物理块基址 = `addr & ~(blocksz-1)`（blocksz=32），对整块 `memset(...,0,blocksz)`；
        若翻译后的 PA 不落在内存 ⇒ `trap_store_access_fault`（**cause 7**）。
      - `clean_inval`（cbo.clean/flush/inval 共用）：按 **LOAD** 类型生成访问
        （`generate_access_info(addr, LOAD, {.clean_inval=true})`）⇒ 权限按**读**检查（`R` 或 `MXR&&X`）、
        `U/SUM` 规则按 LOAD；但整个 translate 被 `convert_load_traps_to_store_traps` 包住 ⇒
        **陷阱 cause 取 STORE 变体（页错误 15 / 访问错误 7）**（与 AMO 同机制，本项目已实现 AMO 口径）。
      - 两者都只查**操作数那 1 字节**的 PMP（`len=1`），块对齐只影响内存副作用，不影响权限检查地址。
      本核实现要点：给 MEM FSM 增加 `MEM_CBO` 操作（`mem_mem_op_q` 加一个取值即可），
      ZERO 走"M_REQ_W ×8 个 4 字节写零"（块内 8 个字），INVAL/CLEAN/FLUSH 走"检查后空操作"；
      `menvcfg/senvcfg` 的 CBCFE/CBZE/CBIE 门控**已实现**（ID 级非法指令），不要动。
    * **第二步：L1I/L1D/L2（行 32 B）**：规格在 `docs/design/spec/04-frontend.md`（L1I 16 KB/4 路/32 B、
      VIPT 无别名证明：128 组×32 B=4 KB=页大小、ITLB 与 Tag 并行）、`03-pipeline-regs.md`（L1D/L2 握手）、
      `00-conventions.md`（`CACHE_LINE=32 B`）。**必须接上 D16② 的 XIP 绕 Cache 判定点**
      （`rv32_ifetch` 已预留 `xip_bypass`/`line_xip_q`：XIP 行既不入 Cache 也不从 Cache 命中）。
      验收：全量回归不回退 + `SvZicbo`/`SvPMPZicbo` 保持 PASS + `fence.i` 语义；性能类特性
      （MSHR 关键 half、预取、多路替换）可分批做，**正确性优先**。

  * 🔜 **④ Cache 的最小可用实施方案（第 17 轮执行；规格裁剪，理由写清楚）**：
    规格原文在 `docs/design/03-cache.md`（L1I 16 KB/4 路/32 B VIPT、L1D 32 KB/8 路 写回+写分配、
    L2 256 KB、MSHR/Store Buffer/DMA 一致性）。**全量照做超出本阶段可验证的余量**，故按"正确性优先、
    性能够 B3 起步"裁剪为：
    * **L1I（必做）**：16 KB = 128 组 × 4 路 × 32 B，**VIPT（VA[11:5] 索引、PA 全地址标记）**，
      只读，**轮转（RR）替换**（不做伪 LRU，效果差距有限、验证成本低），单未完成缺失（不建 MSHR 阵列、
      不做预取）。插入点：`rv32_ifetch` 现成的"整行 32 B 取指"（`if_req_addr` = PA 行地址 → 直接接入）。
      **必须接 D16② 的 XIP 绕 Cache 判定**：`xip_bypass=1` 时既不命中、也不填充（`line_xip_q` 已预留）；
      `fence.i` / 提交级 `sfence.vma` 触发整表失效（**注意**：本设计 VIPT 且索引位全在页内、
      PA 标记，故**不需要**在 `sfence.vma` 上失效 Cache，只需 `fence.i`）。
    * **L1D（次做，可选）**：若时间不够就**不做**，并在 §6 记录"数据侧暂不缓存 + D16② 数据侧待决项已确认"。
      要做就做**最小正确版**：32 KB/8 路，**写直达 + 不写分配**（store 直接落总线，命中则更新行；
      没有脏行 ⇒ 不需要写回、Store Buffer、以及 CBO 的 clean/flush 语义都退化为空操作，风险最低），
      读分配 + RR 替换；数据侧访问 SPI-XIP 窗口**同样绕 Cache**（与取指口径一致，见 §7 待用户确认项）。
    * **L2（本阶段不做）**：DDR 侧靠 AXI 往返，B3 起步够用；在 §6 记为已知性能项。
    * **验证（缺一不可）**：① 全量回归不回退（非特权 18 组 + PMP 6 组 + 单元 + 定向 + hello/memtest）；
      ② `SPI_BOOT` / `BOOT_CHAIN` 仍 PASS（证明 XIP 取指在开 Cache 后仍正确）；③ **性能对比**：
      `memtest` 与 `hello` 的 cycles 前后对比，必须显著下降（否则 Cache 没起作用，等于白做）；
      ④ **XIP 不分配的结构断言**：TB 观测 `xip_bypass` 期间 Cache 的 allocate/写使能**恒为 0**；
      ⑤ `fence.i` 定向：改代码后 `fence.i` 能取到新指令（可用 `sim/tests/` 里现成自修改代码风格新增）。
    * **安全阀**：模块加参数 `ENABLE`，便于 A/B 对比与"万一回归挂了立刻切回已验证基线"。

  * ✅ **③ 的 S2~S5 集成设计已落地**（见上一轮 §7 与本轮 §6）：`rv32mmu_top.v`（ITLB 8/DTLB 16/单 PTW、
    D 优先、权限与 Svade live 判）、访存侧 `M_IDLE` 内联翻译 + `M_XLATE` 兜底、`mem_chk_addr` 全按 PA、
    取指侧 `pa_valid` 门控三处 + 行标签存 PA + `cross_pa_q`/`id_pa_q`、数据总线与 PTW 复用单笔在途、`sfence.vma` 全清。
  * 🔜 **③ 的 S2~S5 集成设计（下一轮执行，已定稿）**：
    * 新增 `rtl/mmu/rv32mmu_top.v`（我实现）：例化 ITLB(8)/DTLB(16)/`rv32_ptw`，对外**两个翻译口**——
      取指 `if_va → if_pa/if_pa_valid/if_fault`，访存 `d_va/d_is_store/d_req → d_pa/d_pa_valid/d_fault`；
      **权限（U/SUM/MXR/RWX）与 Svade 的 A/D 判定在 mmu_top 内 live 做**（TLB 只存 `{R,W,X,U,G,A,D}`，
      不缓存权限结论），页错误 cause 由口上的访问类型决定（取指 12 / load 13 / store·AMO·SC 15）。
    * 访存侧在 `rv32gc_core` 的 **`M_IDLE` 加一个 `M_XLATE` 中间态**：非对齐（cause 4/6）判定**先于**翻译；
      `M_XLATE` 等 `d_pa_valid` ⇒ 把 PA 写回 `m_addr_q`（另存 `m_va_q` 供 tval）+ 置 `m_xlated_q` 回 `M_IDLE`；
      `d_fault` ⇒ 复用"不拉请求 + 进 `M_DONE` + 记 cause"范式（**严禁**留在 `M_IDLE` 死等）。
      `m_xlated_q` 之后 PMP 检查与 `d_req_addr` 全部用 **PA**，`tval` 仍用 VA。
    * 取指侧给 `rv32_ifetch` 加 `pa_valid` 输入，门控 **`hit`/`line_valid`/发请求**三处（缺一即取错行的老坑），
      `line_tag_q` 改存 **PA**；`xip_bypass` 改按 **PA** 判（复位后 MMU off 时两者相同）。
    * PTW 自驱 `d_req_*`（**不经 LSU 的 `M_REQ`/不被 `advance_all`、`fetch_stall`、`mem_stall` 门控**）；
      PTE 读的 PMP/PMA 检查把 `bus_err` 反馈给 PTW（页表读访问错误 ⇒ cause 1/5/7 口径待 Spike 对齐）。
    * `sfence.vma` 接入：任意 `sfence.vma` 先做**全清**（`flush_all` + `abort` 在途 PTW + 强制 `flush_front`，
      因为按行号比对的 `flush_front` 覆盖不到同 PA 不同 VA 的场景）。
    * 验收：63 例（Sv 30 + Svbare 3 + SvPMP 4 + Svade 2 + ExceptionsSv 4 + ExceptionsSvZaamo/Zalrsc 3+3 +
      SvZicbo 6 + SvPMPZicbo 8），组内用正则过滤（`Sv` 有 134 个文件但仅约 30 个 RV32 可跑）。
  原顺序与判据：
  ① **平台口径收尾**：`rv32_ifetch.if_rsp_err` 目前**悬空未用**（取指总线错误会被当指令执行）⇒ 加
     "取指总线错误 → cause 1" 通道；实现要点（已定，避免踩旧坑）：错误期间**不冻结流水线**（`fetch_stall`
     若恒 1 会让 `advance_all` 恒 0 → 死锁），改为向前端**注入气泡**让更老的指令排空，排空后取陷阱
     （epc=tval=出错 PC），flush 清零错误。**必须同时给 `sim_axi_slave.v` 加"错误区域"（如 `+ERR_ADDR=`）
     并写定向测试**，否则该路径不可验证（不写测试就不合入）。同批处理物理 0 口径（`PMPSm_cfg_A_tor_zero`：
     现平台把 0..16MiB 铺成 DDR 且复位桩在 0；方案见上板测试计划）。
  ② **未接入组 `Zimop`(40)/`Zcmop`(8)**：按规范"未实现的 MOP 必须无副作用执行"，译码器映射即可（子 Agent 在办）。
  ③ **Sv32 MMU（TLB+PTW）**：`satp` 生效、S/U 翻译、`sfence.vma`、`SUM/MXR/MPRV`、页错误 cause 12/13/15；
     **PMP 必须作用在物理地址**；跑 `tests/priv` 的 `Svbare`/`Sv`/`SvPMP`/`ExceptionsSv` 等（不做
     Svinval/Svnapot/Svpbmt/Svadu/Svade）。方案侦察已派子 Agent。
  ④ **L1I/L1D/L2 Cache**（行 32B）：接 **D16② 的 XIP 绕 Cache 判定点**（`xip_bypass`/`line_xip_q`）；
     CBO 真正生效后跑 `PMPZicbo`(4)。
  ⑤ **2A-7b/7c（仿真可验部分）**：✅ **第 16 轮已交付** —— `sw/board/{spi_stub.S,ddr_main.S,spi_stub.ld,ddr_main.ld}`
     + `scripts/{pack_boot_image.sh,run_boot_chain_test.sh}`（`PACK_BOOT: PASS`、`BOOT_CHAIN: PASS`）；
     `sw/board/rv32gc-chiplab.dts` + `scripts/check_dts.sh`（**`CHECK_DTS: PASS (17 ok)`**，DTS 与 RTL 常量交叉校验）
     + `docs/porting/00-overview.md` §8（内存映射与 OpenSBI 适配）。
     **剩余**：真机 OpenSBI/U-Boot 链接（把目标文件追加到 `sw/board/ddr_main.ld`）、dtb 编译产物入 NAND 分区。
  ⑥ **交付：上板测试计划（2A-7d）书面稿交用户审阅** —— ✅ 草案已写：`docs/porting/07-board-bringup-plan.md`
     （v0.9 草案：B1/B2/B3 判据、已核实的板级事实（100 MHz 时钟 AC19/复位 Y3/50-33 MHz/引脚）、集成步骤、
     观测手段、8 条风险（R1 时序/R4 无 Cache 性能…）、时间预算、**5 个待用户拍板的决策点**）。
     **待 ④ 落定后定稿提交审阅；用户审阅通过前不做上板（2A-7d）**。
- 📄 本阶段任务的详细清单与判据即上方 🚧 列表（旧编号列表已并入其中）。
- 🧭 **Sv32 MMU 实施计划（第 12 轮侦察定稿，下一轮执行；裁剪版：不实现 Svinval/Svnapot/Svpbmt/Svadu/Svade→按 Svade 即"不改写 PTE"）**：
  结构 `rtl/mmu/rv32_tlb.v`（ITLB 8/DTLB 16，全相联 CAM，项存 `{valid,G,IS_4M,ASID,VPN_TAG,PPN,PERM,AD}`）+
  `rtl/mmu/rv32_ptw.v`（IDLE→L1→L2→FAULT，**无 UPDATE_AD**）+ `rv32mmu_top.v` 内聚；取指翻译在 **IF**（须给
  `rv32_ifetch` 加 `pa_valid` 并门控 `hit/line_valid/发请求` 三处），访存翻译在 **MEM 的 M_IDLE**（复用"拒绝→
  M_DONE+记 cause"范式）；**PMP/CLINT-PLUI 窗口全部改按 PA**、`tval` 仍为 VA；非对齐判定必须先于翻译；
  PTW 自驱 `d_req_*`（**不得经 LSU M_REQ、不得被 stall 门控**）；页错误 12/13/15；SUM/MXR/priv **不缓存进 TLB**；
  PTE 合法性照抄 Spike（非叶 D/A/U、`V=0`、`R=0&&W=1`、4M 的 `ppn[9:0]!=0`）。验收 63 例（Sv 30 + Svbare 3 +
  SvPMP 4 + Svade 2 + ExceptionsSv 4 + ExceptionsSvZaamo/Zalrsc 3+3 + SvZicbo 6 + SvPMPZicbo 8），组内须用正则过滤。
- 📌 **平台适配结论（D15/D16）**：不需要改 chiplab 的 AXI 编址（编址与 ISA 无关，DDR 是 AXI 默认从设备在 `0x0`）；
  需要的是复位向量 `0x1C00_0000`、镜像按 `0x0` 链接、核内 CLINT/PLIC（`0x1F00_0000/0x1F10_0000`）写进 DTS/SBI
- 📌 **待用户确认（2A-4 前）**：数据侧访问 SPI-XIP 窗口（`0x1C00_0000`）是否也要绕过 L1D（见 `spec/08-bus-axi.md` §2.1 待决项）
- 📄 **下一会话请直接使用 `NEXT_SESSION.md` 中的提示词**（自包含：环境、命令、当前卡点、下一步）


> **阶段 2A 的实施依据**：`docs/design/spec/`（实现级规格书）已全部就绪，RTL 开发按 `spec/00-conventions.md` §8 的顺序自底向上推进；每写一个模块，先按 `spec/09-verification-interface.md` §4 建对应单元测试。

**常用命令（回归与验证入口）**

```bash
cd /home/shorthair/dsh/rv32-cpu/rv32gc-cpu
bash scripts/run_sim.sh hello            # SIM: PASS hello
bash scripts/run_sim.sh memtest          # SIM: PASS memtest
bash scripts/run_unit_axi.sh             # AXI_SLAVE_UNIT: PASS (79)
bash scripts/run_unit_exec.sh            # EXEC_UNIT_TESTS: PASS (2461)
bash scripts/run_unit_decoder.sh         # DECODER_UNIT_TESTS: PASS (254)
bash scripts/run_lrsc_test.sh            # LRSC_DIRECTED: PASS（A 扩展定向自测 28 项）
bash scripts/run_arch_test_suite.sh I    # 整组批量（JOBS=4 更快；MARCH 自动合成，勿写死）
bash scripts/run_spi_boot_test.sh        # SPI_BOOT: PASS（RESET_PC=0x1C00_0000 启动链路，2A-7a）
```
> `run_arch_test_suite.sh` 支持 `JOBS`/`RV32GC_TIMEOUT`/`SKIP_BUILD`；`run_spi_boot_test.sh`
> 用于 **D16 的 SPI-XIP 启动**（不传 `RESET_PC` 的普通回归仍用 `0x0`）。

**下一阶段（阶段 2A）任务与计划**

| 步骤 | 任务 | 产出 | 完成判据 |
|---|---|---|---|
| 2A-1 | 仿真工具链落地：确认 verilator/iverilog 可用；编译 Spike；建立 `sim/` 目录与回归脚本 | `sim/tb/*`、`scripts/regress.sh` | 一个 LED 闪烁/计数器 RTL 能在 iverilog 与 verilator 下跑通 |
| 2A-2 | 平台壳与总线：`core_top`（AXI4 主设备 + 调试端口 + 时钟复位同步）、`axi_mem_model`、`soc_sim_top` | `rtl/top/`、`rtl/bus/`、`sim/tb/soc_sim_top.v` | 裸机程序能通过 AXI 读写内存与 CONFREG |
| 2A-3 | 5 级顺序流水：RV32IMAFDC 译码/执行（含 RVC）、冒险处理、CSR/异常、PMP | `rtl/frontend|decode|exec|csr/` | 通过自研指令级单元测试 |
| 2A-4 | MMU（Sv32 TLB+PTW）与 L1I/L1D、L2 | `rtl/mmu/`、`rtl/mem/` | Cache/TLB 单元测试通过 |
| 2A-5 | arch-test 接入（Spike 生成签名）+ 自研裸机测试框架 | `sw/tests/`、`sim/log` | I/M/A/F/D/C/Zicsr/Zifencei 子集全绿 |
| 2A-6 | FPGA 工程脚本与上板 | `fpga/build_chiplab.tcl`、bit 流 | 串口输出 + 数码管正确 + 60 MHz 收敛 |
| 2A-7a | ✅ **已完成（第 9 轮）** SPI-XIP 启动链路：`run_spi_boot_test.sh` → `SPI_BOOT: PASS`；`spi_boot.S`+`spi_link.ld`+`tb_spi_boot.v`；D16② 的取指绕 I-Cache 判定点已落地 | `scripts/run_spi_boot_test.sh`、`sim/tb/tb_spi_boot.v`、`sim/tests/spi_link.{ld,S}`、`rtl` 三处判定点 | **已达成**：`RESET_PC=0x1C000000` → SPI 窗口取首条指令（`@0x1c000000`）→ SPI 段 ALU+XIP 数据读自检 → `auipc+addi+jalr` 跨 ~448 MiB → DDR `0x0` 段 ALU/写读回 → 退出码 0；两条负对照均正确 FAIL；arch-test 17 组/hello/memtest/单元测试无回归 |
| 2A-7b | **启动镜像三件套**：SPI 小引导（0x1C00_0000，PC 相对，能初始化 UART 并跳 DDR）→ DDR 主镜像（`0x0` 起，OpenSBI+U-Boot）→ NAND 分区（D14）；产出烧写/打包脚本 | `sw/` 下的 board 目录 + `scripts/` 打包脚本 | SPI 镜像 ≤1 MiB 且全部 PC 相对；DDR 镜像按 `0x0` 链接；三者能串起来跑到 U-Boot 提示符（先仿真后上板） |
| 2A-7c | **DTS/OpenSBI 内存映射声明**：DRAM 基址 `0x0`+128 MiB、核内 CLINT/PLIC `0x1F00_0000/0x1F10_0000`、UART `0x1FE0_01E0`、SPI `0x1C00_0000`、NAND 分区 | `docs/porting/00-overview.md` §平台适配、DTS/`platform_override` 片段 | `dtc` 编译通过；OpenSBI 启动打印的内存/中断信息与 DTS 一致 |
| 2A-7d | **FPGA tcl 与上板 B1~B3**：`fpga/tcl/build_chiplab.tcl`（工程内生成，不改 chiplab 源树）→ 约束复用 `soc_up.xdc` → 综合实现 → 60 MHz 收敛 → 上板串口输出 + 从 `0x1C00_0000` 启动 | `fpga/`、Vivado 报告 | 上板从 SPI 启动打印串口信息；时序报告 WNS≥0 @60 MHz；B1~B3 通过 |

**阶段二开工前需要用户确认/配合的事项**
1. ~~在沙箱外执行 `sudo apt install verilator iverilog gtkwave`~~ → **已完成**（Verilator 5.020 / Icarus Verilog 12.0 已就绪，`xvlog/xelab/xsim` 亦可用）；
2. ~~确认阶段一设计参数~~ → **已审阅通过**；
3. ~~提供实验箱 NAND 芯片型号/丝印~~ → **已由原理图确认**（K9F1G08U0C-PCB0，见阶段一补充更新）；
4. 仅剩一项待用户指令：**"开始阶段 2A"**。收到后按 §7 的 2A-1 → 2A-6 顺序执行。
