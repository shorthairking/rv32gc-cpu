# U-Boot 移植方案（基于 `la32r-uboot` 自带 `arch/riscv`）

> **文档定位**：RV32-GC 项目 U-Boot 层的移植方案 —— 新增 board/SOC + defconfig + DTS，NAND/MTD 支持、`saveenv`、`bootcmd` 自动启动。
> **基线树**：`la32r-uboot/`（U-Boot **2019.07** 基线）。[RTL 实测] `la32r-uboot/Makefile:3-4`（`VERSION = 2019` / `PATCHLEVEL = 07`）
> **参考上游**：`u-boot/`（2026.10 基线）——**仅作参考**，不复制代码。[RTL 实测] `u-boot/Makefile:3-4`

---

## 1. 移植路线与边界

### 1.1 为什么基于 `la32r-uboot` 的 `arch/riscv`

- `la32r-uboot/` **自带完整的 `arch/riscv` 目录树**：`Kconfig`、`Makefile`、`config.mk`、`cpu/`、`dts/`、`include/`、`lib/`。[RTL 实测] `ls la32r-uboot/arch/riscv/`
- 该树已具备 RV32I 支持所需的 Kconfig 骨架（含 `ARCH_RV32I`、`RISCV_ISA_C`、`SIFIVE_CLINT`、`XIP` 等）。[RTL 实测] `la32r-uboot/arch/riscv/Kconfig:67, 116, 133, 195`
- 因此**移植方式 = 新增文件 + 补丁序列**，**不改造** `arch/la32r` / `arch/loongarch`。

### 1.2 边界（硬约束）

| 允许 | 禁止 |
|---|---|
| **新增** `board/<vendor>/<board>/` 目录与文件 | 修改 `arch/la32r/`、`arch/loongarch/` 任何文件 |
| **新增** `configs/<board>_defconfig` | 修改 `la32r-uboot/` 既有文件（须走补丁序列并登记） |
| **新增** `arch/riscv/dts/<board>.dts` + Makefile 追加条目 | 修改 `chiplab/`、`la32r-Linux/`、`linux/`、`opensbi/`、`u-boot/` |
| **新增** NAND 驱动于 `drivers/mtd/nand/` | 复制上游 `u-boot/` 的 C 代码正文 |

> **纪律**：上游源码树不复制进本项目；用"新增文件 + 补丁序列 + 构建脚本"管理，版本号记录在 `sw/*/UPSTREAM.md`。

---

## 2. ⚠️ 关键陷阱：`RISCV_M_MODE` 符号在本树**不存在**

### 2.1 事实

- **本树的 arch/riscv Kconfig 中没有任何 `RISCV_M_MODE` 符号。**[RTL 实测]

  ```sh
  grep -rn "RISCV_M_MODE" la32r-uboot/arch/riscv/Kconfig
  # → 无输出
  ```
- 本树用的是**另一组符号名**：`RISCV_MMODE` / `RISCV_SMODE`，由 `choice` + `prompt "Run Mode"` 选择，**默认 `RISCV_MMODE`**。[RTL 实测] `la32r-uboot/arch/riscv/Kconfig:100-114`

  ```
  choice
      prompt "Run Mode"
      default RISCV_MMODE

  config RISCV_MMODE
      bool "Machine"

  config RISCV_SMODE
      bool "Supervisor"
  endchoice
  ```

### 2.2 后果与纪律

> ❌ **禁止**在本树的 defconfig、DTS、C 代码或补丁中引用 `RISCV_M_MODE`。
> 该宏**不存在**，引用它会导致：
> - defconfig 中：符号被静默忽略（或 `savedefconfig` 报未知符号），**配置不生效且无报错**；
> - C 代码中：`#ifdef CONFIG_RISCV_M_MODE` 恒假，**分支被静默编译掉**，产生难以定位的功能缺失。
>
> ✅ 本树**必须**使用 `RISCV_MMODE` / `RISCV_SMODE`。

### 2.3 本项目取 `RISCV_SMODE`

- 软件栈为 OpenSBI(M) + U-Boot(S) + Linux(S)，**U-Boot 运行在 S 模式**（见 `docs/porting/01-overview.md` §1.2）。
- 因此 defconfig 中应选 **`CONFIG_RISCV_SMODE=y`**（并确保 `CONFIG_RISCV_MMODE` 未置）。
- **连带影响**：`RISCV_MMODE` 为真的配置项会被关闭，例如 `SIFIVE_CLINT` **`depends on RISCV_MMODE`**。[RTL 实测] `la32r-uboot/arch/riscv/Kconfig:133-134`
  → 即 **S 模式 U-Boot 不能直接驱动 CLINT**，定时器/复位等服务**必须走 SBI 调用**。这与栈设计一致。

### 2.4 参考 `la32rsoc_defconfig` 的 `CONFIG_RISCV` 设置

`la32r-uboot/configs/la32rsoc_defconfig` 是本树**唯一的自研板**示例，其 `CONFIG_RISCV` 相关设置为：[RTL 实测] `la32r-uboot/configs/la32rsoc_defconfig:14, 17`

```
# CONFIG_RISCV is not set      ← 第 14 行（la32r 板，不是 RISC-V 架构）
CONFIG_SYS_ARCH="la32r"        ← 第 17 行
```

- **关键解读**：`la32rsoc_defconfig` 是 **la32r 架构**的板子，它把 `CONFIG_RISCV` **显式关掉**（`# CONFIG_RISCV is not set`）。
- **对本项目的意义**：
  - 我们要**反过来** —— 新建的 defconfig 必须 **`CONFIG_RISCV=y`**，并 `# CONFIG_LA32R is not set`；
  - 但 `la32rsoc_defconfig` 仍是**结构模板**：它示范了本树中 `SYS_ARCH`、`SYS_CONFIG_NAME`、`SYS_TEXT_BASE`、`DEBUG_UART_*`、`NR_DRAM_BANKS` 等板级符号的**书写方式**。
- 可借鉴的板级符号（**值须按本项目重算，不可照抄**）：[RTL 实测] `la32r-uboot/configs/la32rsoc_defconfig:20-30`

  | 符号 | la32rsoc 的值 | 本项目处置 |
  |---|---|---|
  | `CONFIG_SYS_TEXT_BASE` | `0xa0200000` | **必须改**（la32r 地址口径，与 RV32 平台无关） |
  | `CONFIG_SYS_MALLOC_F_LEN` | `0x600` | 可沿用 |
  | `CONFIG_NR_DRAM_BANKS` | `4` | 按平台 DDR3 单 bank 重定 |
  | `CONFIG_DEBUG_UART_BASE` | `0x9fe001e0` | **改**为平台 UART 地址（见 `docs/kb/platform-facts.md` §2.5） |
  | `CONFIG_DEBUG_UART_CLOCK` | `33000000` | **沿用**（平台口径 FREQ = 33 MHz，见 `docs/porting/01-overview.md` §4） |
  | `CONFIG_SYS_CONFIG_NAME` | `"la32rsoc_demo"` | **改**为本项目板名 |

- **注意**：`DEBUG_UART_BASE = 0x9fe001e0` 与本项目平台 UART 地址 `0x1FE0_01E0` 的**低 24 位一致**（`0x9f` 是 la32r 的高位段）。这提示本树的板级地址写法带有**窗口高位偏移**习惯，新 defconfig 的地址必须**逐条对照平台事实**确认，不可由 la32r 值平移推算。

---

## 3. 移植工作项

### 3.1 新增 board/SOC 目录

```
board/<vendor>/rv32gc/         # 新增目录
├── Kconfig                    # 板级 Kconfig：TARGET_<BOARD> 符号
├── Makefile                   # obj-y 列表
├── rv32gc.c                   # 板级初始化：UART 时钟、内存 bank、环境变量位置
├── MAINTAINERS                # 板维护信息
└── Kconfig                    # 追加到 board/<vendor>/Kconfig
```

- **根 `board/Kconfig` 与 `board/<vendor>/Kconfig` 需追加**板符号 —— 这属于**必要条件的最小侵入修改**，必须登记为补丁。
- `rv32gc.c` 的职责 [工程约定]：
  1. `dram_init` / `dram_init_banksize`：声明 DDR3 bank（`0x0000_0000–0x07FF_FFFF`，128 MiB，见 `docs/kb/platform-facts.md` §2.1）；
  2. `board_early_init_f`：初始化调试 UART 时钟口径（33 MHz）；
  3. 环境变量存储位置（NAND，见 §3.4）；
  4. **不**做 CLINT 初始化（S 模式不可用，见 §2.3）。

### 3.2 新增 defconfig

`la32r-uboot/configs/rv32gc_defconfig`，核心条目 [工程约定]：

```
CONFIG_RISCV=y
# CONFIG_LA32R is not set
CONFIG_SYS_ARCH="riscv"
CONFIG_SYS_CONFIG_NAME="rv32gc"
CONFIG_TARGET_<BOARD>=y

# 运行模式：必须用本树符号名（§2）
CONFIG_RISCV_SMODE=y
# CONFIG_RISCV_MMODE is not set

# RV32
CONFIG_ARCH_RV32I=y
CONFIG_32BIT=y
CONFIG_SBI=y                     # 走 SBI 调用

# 地址/时钟（值须按平台事实重算）
CONFIG_SYS_TEXT_BASE=<SPI窗口或DDR内决定>
CONFIG_DEBUG_UART_BASE=<平台 UART 地址>
CONFIG_DEBUG_UART_CLOCK=33000000

# NAND / MTD
CONFIG_MTD=y
CONFIG_NAND=y
CONFIG_SYS_NAND_SELF_INIT=y
CONFIG_MTD_RAW_NAND=y
CONFIG_CMD_MTD=y
CONFIG_CMD_NAND=y
CONFIG_ENV_IS_IN_NAND=y
```

- **验证方式**：`make <board>_defconfig` 后必须 `make savedefconfig` 并 **diff 回写**，确认**无符号被静默丢弃**（这是发现 §2.2 那类"静默忽略"陷阱的唯一手段）。

### 3.3 新增 DTS

`la32r-uboot/arch/riscv/dts/rv32gc.dts`（+ 在 `arch/riscv/dts/Makefile` 追加条目）：

必须描述的节点 [工程约定]：
1. `/cpus`：hart 数、`riscv,isa`（含 `i m a f d c` 与 `zicsr`/`zifencei`）、`mmu-type = "riscv,sv32"`；
2. `/memory`：DDR3 `0x0` / `0x08000000`（128 MiB）；
3. `chosen`：`bootargs`、`stdout-path`；
4. 串口节点：平台 UART 地址（`docs/kb/platform-facts.md` §2.5）；
5. **NAND 控制器节点**：`nand@1FE78000` + `partitions` 子节点（**与 `mtdparts` 同源**，见 §3.5）；
6. `timebase-frequency`：**33000000**（与 `config.h:33`、`docs/porting/01-overview.md` §4 一致）。

- **注意**：U-Boot 的 DTS 与 Linux 的 DTS **应共用同一份分区定义**，避免两侧分叉。

### 3.4 NAND MTD 支持与 `saveenv`

- **驱动落点**：`drivers/mtd/nand/raw/` 下新增平台 NAND 驱动（对接 APB NAND 控制器，见 `docs/porting/04-nand-driver.md` 的控制器分析）。
- **必须开启的 Kconfig**（2019.07 命名口径）[工程约定]：
  - `CONFIG_MTD`、`CONFIG_NAND`、`CONFIG_MTD_RAW_NAND`、`CONFIG_SYS_NAND_SELF_INIT`、`CONFIG_SYS_NAND_ONFI_DETECTION`（视芯片而定）；
  - `CONFIG_CMD_MTD`、`CONFIG_CMD_NAND`。
- **`saveenv`（环境变量持久化）**：
  - `CONFIG_ENV_IS_IN_NAND=y`，并定义环境变量区 **偏移与大小**，**必须与分区表的 `nand-env` 段（256 K）逐字一致**；
  - 环境变量区必须**块对齐**：256 K = 262144 B，`262144 % 131072 = 0` ⇒ **恰好 2 个 NAND 块**（核算见 `docs/porting/01-overview.md` §3.2）；
  - U-Boot 标准 `ENV_IS_IN_NAND` 布局含 **CRC + 冗余份**，本项目按 **2 块** 放主/备环境变量；
  - **验收**：`saveenv` 后**断电重启**，`printenv` 必须能读回刚写入的变量（这是 `saveenv` 真的落盘的唯一证据）。

### 3.5 `bootcmd`：从 NAND 自动启动

- **分区表的单一来源**：`mtdparts` 字符串必须与 DTS `partitions` 节点、`01-overview.md` §3.1 的口径**完全一致**：

  ```
  nand-flash:256K(env),50M(kernel)ro,1M(dtb),-(rootfs)
  ```

- **`bootcmd` 设计** [工程约定]（按顺序尝试，失败即退回交互）：

  ```
  # 伪代码口径，不是最终脚本
  bootcmd = nand read <loadaddr> kernel ;      # 读内核分区
            nand read <fdtaddr>  dtb ;         # 读 DTB
            bootm <loadaddr> - <fdtaddr>       # 或 booti / bootz，取决于镜像格式
  ```

- **要点**：
  1. **`bootcmd` 必须能在无人工干预下完成启动**（这是本项验收目标："从 NAND 自动启动"）；
  2. 分区名（`kernel`/`dtb`）必须与 §3.5 的 `mtdparts` 同名；
  3. **镜像加载地址**必须落在 DDR3 窗口（`0x0000_0000–0x07FF_FFFF`）内，且不与 U-Boot 自身、DTB 重叠（地址表见 `docs/porting/01-overview.md` §2.3）；
  4. **失败路径**必须**落回 U-Boot 命令行**，而不是死循环 —— 否则无法诊断。

---

## 4. 构建与验收

### 4.1 构建命令（可复现）

```sh
# 在 la32r-uboot 工作副本上（本项目以「补丁序列 + 新增文件」方式管理，不改原树）
make ARCH=riscv CROSS_COMPILE=<toolchain-prefix> rv32gc_defconfig
make ARCH=riscv CROSS_COMPILE=<toolchain-prefix> -j$(nproc)
```

- 工具链：`/opt/riscv/bin/riscv32-unknown-linux-gnu-`（GCC 16.1.0）。[环境实测] `docs/kb/tools-and-flow.md` §1
- **2019.07 基线 + GCC 16.1.0 的兼容性风险**：老树遇到新编译器常见 `-Werror` 类失败。**处置**：作为**独立的已知风险**记录，不擅自修改编译器旗标；若触发，报告母 Agent/用户决策。[工程约定]

### 4.2 验收判据

| # | 判据 | 判定方式 |
|---|---|---|
| U1 | defconfig 生效且无符号被丢弃 | `make savedefconfig` diff 为空 |
| U2 | `CONFIG_RISCV_SMODE=y` 且**无** `RISCV_M_MODE` 引用 | `grep -rn "RISCV_M_MODE" <本项目新增文件>` 无输出 |
| U3 | 构建产出 `u-boot.bin` | 文件存在且非空 |
| U4 | NAND 可识别 | U-Boot 启动日志 `nand: ... ` 命中芯片探测行 |
| U5 | `mtdparts` 与 DTS 一致 | 两侧字符串 diff 为空 |
| U6 | `saveenv` 掉电保持 | 重启后 `printenv` 读回写入值 |
| U7 | `bootcmd` 自动启动 | 上电后无人工干预进入内核 |

- **回归纪律**：脚本必须**"未捕获即失败"**，兜底文案**不得含 `PASS`**（见 `docs/kb/tools-and-flow.md` §5）。

---

## 5. 与 la32r 旧板级代码的边界

| 项 | 处置 |
|---|---|
| `arch/la32r/` | **只读**，不修改、不引用其板级实现 |
| `arch/loongarch/` | **同上** |
| `configs/la32rsoc_defconfig` | **只读参考结构**，不修改；新 defconfig 独立新建 |
| `board/loongson/`（若存在） | **只读参考**，新 board 独立新建 |
| `arch/riscv/` | **可以新增**（DTS、必要时最小 Kconfig/Makefile 追加），改动**全部登记为补丁** |

- **核心原则**：**新增优先，修改最小化**。任何对既有文件的修改都必须：(a) 是编译/链接的必要条件；(b) 记录在补丁序列中；(c) 可独立审查。

---

## 6. 不确定项与风险

| # | 项 | 处置 |
|---|---|---|
| R1 | 本树 **NAND/MTD 是否已具备可用骨架** | `drivers/mtd/nand/` 下已有 `Kconfig`/`Makefile`/`bbt.c`/`core.c`/`raw/`/`spi/`（[RTL 实测] `ls la32r-uboot/drivers/mtd/nand/`），但**平台驱动必须新写** |
| R2 | **NAND 控制器寄存器全表**未逆向完 | 见 `docs/kb/platform-facts.md` §9 U1/U2；写驱动前必须先关闭 |
| R3 | `CONFIG_SYS_TEXT_BASE` 取值 | 取决于从 SPI XIP 运行还是拷到 DDR 运行；与 `01-overview.md` §2.2/§2.3 联动决策 |
| R4 | 2019.07 + GCC 16.1.0 兼容性 | 见 §4.1；不擅自改编译器旗标 |
| R5 | 环境变量区主/备布局细节 | 按 U-Boot 标准 `ENV_IS_IN_NAND` 定；**2 块**（§3.4） |
| R6 | S 模式下 U-Boot 的定时器来源 | `SIFIVE_CLINT` 依赖 `RISCV_MMODE`（§2.3）⇒ 必须走 SBI；需确认本树 SBI 调用路径可用 |

---

## 7. 交付要求

[工程约定] 本层交付物：

1. **新增文件清单**（board/defconfig/DTS/驱动）+ **补丁序列**（对既有文件的必要修改）；
2. **`sw/uboot/UPSTREAM.md`**：记录基线版本、补丁列表、构建命令；
3. **构建与验收脚本**（可复现命令 + 判定输出，fail-closed）；
4. **自证报告**：按 §4.2 表格逐项给出证据；
5. **登记不确定项**到本文件 §6 与 `docs/kb/platform-facts.md` §9。
