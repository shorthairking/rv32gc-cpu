# PROMPT.md — 指导 AI 完成"RV32-GC CPU 及配套软硬件"项目的提示词

> 用法：把本文件全文作为新会话（或新阶段）的起始提示词交给 AI。它与 `AGENT.md`（阶段计划与进度台账）、`docs/`（设计/移植/知识库）配合使用。
> 设计原则：自包含（不依赖前序会话上下文）、可执行（每步有明确产出与验收）、可交接（每阶段强制停下等待用户）。

---

## 一、任务背景

当前工作区（`/home/shorthair/dsh/rv32-cpu`）是一个 RISC-V CPU 开发工作区，包含：

- **`chiplab/`**：龙芯为 FPGA 实验箱做的敏捷开发平台（SoC 顶层、AXI/DDR/UART/NAND/MAC/CONFREG IP、verilator 仿真流程、Vivado 工程与约束、文档）。原为 LA32R 指令集设计，**本项目要接入自研的 RV32-GC 处理器核**。
- **`la32r-Linux/`**：龙芯提供的 Linux 5.14.0-rc2 源码树（LA32R 板用 `arch/loongarch`，**同时自带可用的 `arch/riscv`（已支持 RV32/Sv32）**）。
- **`la32r-uboot/`**：龙芯提供的 U-Boot 源码树（LA32R 板用 `arch/la32r`，**同时自带完整的 `arch/riscv`（RV32 支持）**）。
- **`riscv-isa-manual/`、`riscv-arch-test/`、`riscv-gnu-toolchain/`、`docs-dev-guide/`**：规范、架构测试套件、工具链源码、文档工程指南。
- **`.dsh-kb/` + `dsh-extension/`**：常驻知识库与 skill（`riscv-kb`）。**获取 RISC-V 领域知识必须用 `kb_search`，不要直接读大文件**。
- **`rv32gc-cpu/`**：本项目的独立 git 仓库（设计文档、RTL、仿真、软件移植、脚本）。

环境事实：

| 项 | 值 |
|---|---|
| FPGA 器件 | `xc7a200tfbg676-2`（Artix-7，龙芯实验箱） |
| Vivado | 2025.2，已在 PATH（`vivado`），**要求用 CLI（batch/tcl），不要用 GUI** |
| 工具链 | `/opt/riscv/bin/riscv32-unknown-linux-gnu-`（GCC 16.1.0，默认 `-mabi=ilp32d`） |
| 平台时钟 | 板级 100 MHz；`cpu_clk`（CPU）默认 50 MHz，uncore（DDR/UART/NAND/MAC/CONFREG）33 MHz |
| 网络 | 可用（可 clone OpenSBI/Spike/busybox 等） |
| `sudo` | **不可用**（沙箱 no-new-privileges）；系统包安装需请用户在沙箱外执行 |
| 语言 | **与用户交流、提问一律使用中文** |

---

## 二、任务目标

设计基于 **RV32-GC** 指令集的 CPU，在 chiplab 平台上完成软硬件协同，**最终从 NAND 启动 Linux 内核、驱动与根文件系统**。

硬性要求：

1. 支持 RV32-GC（RV32IMAFDC + Zicsr/Zifencei），支持**完整特权级**（M/S/U、Sv32 MMU、PMP），能运行 Linux 与驱动；
2. **4 发射超标量**（"4 个标量及以上"的确认含义），≥4 个标量执行部件；
3. **必须有分支预测，且为锦标赛预测器**（全局 + 局部 + 选择器）；
4. Cache 容量自定（本设计：L1I 16 KB / L1D 32 KB / L2 256 KB）；
5. 流水级 ≥5（本设计 11 级）；
6. **乱序执行**（本设计：ROB 128 + 物理寄存器重命名 + 分布式发射队列 + LSQ）；
7. 主频 **≥60 MHz，目标 100 MHz**；
8. U-Boot 移植：支持从平台 NAND 启动、能写入 NAND（保存环境变量与数据）；
9. Linux 内核 + 驱动移植，并配置可用的根文件系统（busybox/initramfs，进阶 UBIFS on NAND）。

交付物：CPU RTL（含顶层与子模块）、测试平台与测试用例、U-Boot 移植代码与配置、Linux 内核/驱动移植代码与配置、可上板执行的镜像、综合脚本（约束复用平台 `soc_up.xdc`）。

---

## 三、任务注意事项与补充信息

### 3.1 CPU 设计

- 可以（并且应该）复用平台已提供的、经过验证的资源：**AXI 互连、时钟 IP、DDR MIG、UART、NAND 控制器、CONFREG、DMA 引擎**；CPU 只需对外提供 AXI4 主设备接口。
- 乘法器、移位器等适合 FPGA 原语的部件**优先用 Vivado 推断的 DSP48E1/BRAM**（用 `*` 与 `ram_style` 推断，而不是手写原语）；但除法器/浮点单元建议自研（`div_gen`/`floating_point` IP 会引入 .xci 依赖，Verilator 无法仿真）。
- 推荐两级 Cache（本设计已采用）。
- **平台 CPU 接口契约固定**：模块名 `core_top`，端口见 `docs/design/06-bus-axi.md`；AXI 为 32 位数据、4 bit len（突发 ≤16 beat）、4 bit ID；数据宽度可用 `` `AXI64 ``/`` `AXI128 `` 宏参数化。
- **CLINT 与 PLIC 放在核内**（地址 `0x1F00_0000` / `0x1F10_0000`，核内截获不下总线），这样不改 SoC 顶层即可让标准 RISC-V 内核驱动工作。
- 必须实现 **Zicbom**（`cbo.clean/flush/inval`）：平台 NAND/MAC 走 DMA 且**没有硬件 Cache 一致性**。

### 3.2 平台使用

- **复位取指窗口 = SPI Flash XIP `0x1C00_0000`（1 MiB）**：chiplab 的地址判决
  （`IP/AMBA/axi_mux_syn.v`）把 `[31:20]==0x1c0` 接到 SPI 控制器，DDR3 是 AXI 默认从设备位于
  **`0x0`**，**没有硬件 boot ROM**。因此：① 上板/启动验证必须 `-DRESET_PC=32'h1C000000`；
  ② RISC-V 习惯的 `0x8000_0000` 复位**不适用**（那是 DDR3 段，上电内容未定义）；
  ③ 取指命中 SPI 窗口必须**绕过 I-Cache**；④ 引导软件在 SPI 窗口内**只能用 PC 相对寻址**
  （`0x1C00_0000` 与 DDR `0x0` 相距 ~448 MiB，超出 `auipc` 立即数范围，须用完整 32 位地址运算
  再 `jalr`）；⑤ 引导早期**不得开 MMU**。详见 `AGENT.md` §2 D16。
- chiplab 原为 LA32R 设计：**不要**沿用 LA32R 的任何虚拟地址（KSEG 别名 `0x9fe0_xxxx`/`0xa000_0000|`）与 LA32R 的 IRQ 编号约定。
- 仿真与 FPGA 的 **CONFREG 地址/偏移不同**（见 `docs/kb/01-chiplab-platform.md` §4）；仿真用 `confreg_sim.v`（`0x1FAF_0000`，含 VIRTUAL_UART/IO_SIMU），FPGA 用 `confreg_syn.v`（`0x1FD0_0000`）。
- 平台的 verilator difftest 依赖 **LA32R NEMU**，RV32 **不能**使用；请自建 TB，并用 **Spike**（自行编译）作为参考模型与 arch-test 签名来源。
- FPGA 工程（`fpga/loongson/2023.2/system_run.xpr`）**不含 CPU 源文件**且无 tcl 脚本 → 需要自建 `fpga/build_chiplab.tcl`，并**在本项目目录内**生成工程（不要修改 chiplab 源树）。
- `IP/myCPU/` 是空的子模块，处理器核源码放这里（或用脚本安装）。

### 3.3 软件移植

- `la32r-Linux` 与 `la32r-uboot` 里**都有现成可用的 `arch/riscv`（RV32）**：移植 = 新增 SoC/board + 设备树 + defconfig + 驱动；**不要**尝试把 `arch/loongarch`/`arch/la32r` 改造成 RISC-V。
- Linux 必须走 **S 模式 + SBI**（该内核树 `RISCV_M_MODE` 隐藏且 `default !MMU`）→ 软件栈 = **OpenSBI(M) + U-Boot(S) + Linux(S)**。
- **NAND 驱动是唯一必须新写的驱动**（U-Boot 现在完全没有 NAND/MTD 支持）；参考实现 `la32r-Linux/drivers/mtd/nand/raw/ls1a_nand.c` 的**命令序列可用**，但地址/cache/DMA 部分必须重写；数据搬运必须走平台 DMA 引擎（门铃 `0x1FD0_1160`）。
- **板上 NAND 已确认**（原理图 `实验箱A7-原理图.pdf`，位号 U8）：**K9F1G08U0C-PCB0**（Samsung 1 Gbit SLC，3.3 V）——128 MiB / 页 2048+64 B / 块 128 KiB / 1024 块 / **ECC 要求 1 bit/512 B** / tR 25 µs、tPROG 200 µs、tBERS 1.5 ms / ID `EC F1`。与平台 RTL `nand_type=2'h2`、参考驱动几何 gate **完全吻合**；ECC 用软件 BCH-4（或 Hamming）即可，U-Boot 与内核必须使用相同 ECC 布局。
- 其他板级事实：DDR3 = K4B1G1646G-BCK0（128 MiB，与 DTS 一致）；SPI NOR = S25FL128SAGMFI001（16 MiB，DIP 插座，存放 PMON/u-boot）；板级时钟 100 MHz。
- 分区统一定义：`nand-flash:256K(env),50M(kernel)ro,1M(dtb),-(rootfs)`。
- 上游源码树不复制进本项目：用"新增文件 + 补丁序列 + 构建脚本"管理，版本号记录在 `sw/*/UPSTREAM.md`。

### 3.4 工作方式

- **子 Agent 并行优先（强制倾向）**：项目任务高度可并行（arch-test 各组、RTL 子模块、
  移植子任务、日志/代码核查、缺陷定位）。默认"先拆分、再并行"：
  - 彼此独立的子任务（≥2 个）**必须**用 `subagent` / `subagent_fork` 在同一条消息里并行发起；
  - 读大量文件只回一个结论的活（日志分析、搜索、核查）交给子 Agent，以保护主 Agent 上下文；
  - 长时仿真/构建（arch-test 整组、Vivado、锁步）用**后台 job** 与其它工作并行，不要空等；
  - 子 Agent 不得同时改同一文件；RTL 位域改动必须串行（先改 `rtl/pkg/rv32gc_defs.vh` 真源）；
  - **子 Agent 不提交 git**，其结论必须由主 Agent 复跑命令确认后才算验收。
  详细纪律见 `AGENT.md` §4.5。
- **知识检索优先**：RISC-V 规范/测试/工具链知识用 `kb_search`（不要读大文件）；本项目自己的知识库在 `rv32gc-cpu/docs/kb/`。
- **每阶段结束**：更新 `AGENT.md` 的阶段总结与下一阶段计划 → git 提交 → **停下等待用户明确指令**（不要自动进入下一阶段）。
- **需要权限或遇到冲突**：用中文提问，给出选项与推荐项。
- **长上下文管理**：把结论沉淀到文件（设计→`docs/design/`、移植→`docs/porting/`、新知识→`docs/kb/`），关键决策写 `memory_write`。

---

## 四、任务流程和要求

### 第 0 步：进入项目（每次会话必做）

1. 读 `rv32gc-cpu/PROMPT.md`（本文件，任务背景/硬性指标/平台约束/强制流程）；
2. 读 `rv32gc-cpu/AGENT.md`：§2 关键决策、**§4.5 工作方式（子 Agent 并行）**、§6 阶段总结、§7 当前状态与下一阶段计划；
3. 读 `rv32gc-cpu/NEXT_SESSION.md`：上一轮交接的当前卡点与下一步；
4. 按需 `kb_search` 检索 `docs/kb/`、ISA 手册、arch-test 覆盖点；
5. 检查 git 状态与上一阶段提交，确认工作区干净。

### 第 1 步：设计方案（已完成，见 `docs/design/`）

要求包含：流水线级数与各级功能、分支预测器方案（锦标赛）、Cache 方案、CSR/特权方案、乱序执行方案、整体架构，并绘制**结构图与数据通路图**（`docs/design/diagrams/*.dot|svg`）。

### 第 2 步：CPU 设计与实现（阶段二）

- 先实现**顺序 5 级基线核**（打通 ISA/特权/Cache/总线/工具链/上板），再升级为 **4 发射乱序核**；
- 模块化实现，每个模块有单元测试；集成后有 arch-test（ACT4，用 Spike 生成签名）与自研测试；
- 顺序核与乱序核做**提交级锁步比对**（`debug0_wb_*` 轨迹 vs Spike `--log-commits`）；
- 完成后综合上板（`fpga/build_chiplab.tcl`，Vivado CLI），记录时序报告。

### 第 3 步：U-Boot 移植（阶段三）

按 `docs/porting/01-uboot.md`：新增 board/defconfig/DTS/NAND 驱动 → QEMU 先验证 → 上板 → `mtd` 读写校验 → `saveenv` → `bootcmd` 从 NAND 自动启动。

### 第 4 步：Linux 内核与驱动移植（阶段四）

按 `docs/porting/02-linux.md` 与 `03-drivers.md`：新增 `SOC_CHIPLAB`/DTS/defconfig/NAND 驱动 → OpenSBI 集成 → 从 NAND 启动到 shell → 驱动与稳定性验证。

### 第 5 步：根文件系统与验收（阶段五）

按 `docs/porting/05-rootfs.md`：initramfs（busybox）→ 可选 UBIFS on NAND → 掉电/压力/性能测试 → 整理交付物与复现脚本。

### 每一步的强制规则

1. 每完成一个步骤，**为该阶段做总结**（写入 `AGENT.md` §6），并给出下一阶段任务与计划（§7）；
2. git 提交（`<阶段>: <摘要>`），确保可追溯；
3. **停下**，等待用户审阅并发出"开始下一阶段"的明确指令后再继续；
4. 若发现需求冲突或不可行项，立即用中文向用户报告并给出方案选项。

---

## 五、当前状态快照（随阶段更新）

> **阶段 2A 已完成**（2026-09-13，第 8 轮）：顺序 5 级 RV32GC 基线核跑通
> **arch-test 17 组 123 例 0 失败** + hello/memtest + 单元测试 + A 扩展定向自测全绿；
> 下一步是 **PMP → Sv32 MMU + L1/L2 Cache → 平台适配（SPI 启动）→ FPGA 上板**。
> 最新事实以 `AGENT.md` §6/§7 与 `NEXT_SESSION.md` §4 为准。

- **阶段一已完成并获用户审阅通过**：设计文档 9 篇、移植方案 6 篇、知识库 7 篇、结构图/数据通路图 5 张、`AGENT.md`、本提示词；已提交 git。
- **环境就绪**：Verilator 5.020 + Icarus Verilog 12.0 已安装（用户完成）；Vivado 2025.2 可用；`/opt/riscv` GCC 16.1.0 可用；网络可用。
- **硬件事实已确认**（原理图）：NAND = K9F1G08U0C-PCB0（128 MiB / 2048+64 B 页 / 128 KiB 块 / ECC 1 bit/512 B）、DDR3 = 128 MiB、SPI NOR = S25FL128SAGMFI001（16 MiB）、板级时钟 100 MHz。
- **下一阶段（2A）首三件事**：① 仿真环境落地（iverilog + verilator 回归脚本 + 编译 Spike 作参考模型）；② `core_top` 平台壳 + AXI/内存/CONFREG 仿真环境跑通；③ 5 级顺序流水 + CSR/特权 + 最小系统上板（B1~B3）。
