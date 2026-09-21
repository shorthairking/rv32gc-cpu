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

---

## 8. 基线变更（2026-09-21 起生效）：改用上游 u-boot fork 的 `dev` 分支

> **本章是补充说明，效力高于本文 §1–§7**：§1–§7 写的是 `la32r-uboot`（U-Boot **2019.07**）口径，
> 现**已被取代**，仅作为"移植经验与陷阱清单"保留。实际交付物在上游树里，
> 板级说明见 `u-boot/board/loongson/chiplab/README`。

### 8.1 新基线

| 项 | 旧口径（§1–§7） | 新口径（本章） |
|---|---|---|
| 基线树 | `la32r-uboot/`（U-Boot 2019.07） | `/home/shorthair/dsh/rv32-cpu/u-boot/`（用户 fork；`VERSION=2026` / `PATCHLEVEL=10`） |
| 分支 | — | 工作分支 **`dev`**（main @ `211de43d0f9`）；全程不切 main |
| 移植方式 | 新增 board/defconfig/DTS + 补丁序列 | 同上：**新增文件为主**，对上游既有文件只做 2 处必要登记改动（见 8.4） |
| 板名/目标 | `rv32gc_defconfig`（规划名） | `configs/chiplab_rv32_defconfig` + `CONFIG_TARGET_CHIPLAB_RV32` + `board/loongson/chiplab/` |
| DTS | `arch/riscv/dts/rv32gc.dts`（规划名） | `arch/riscv/dts/chiplab-rv32.dts`（`CONFIG_DEFAULT_DEVICE_TREE="chiplab-rv32"`） |
| 板级配置头 | `SYS_CONFIG_NAME` 旧写法 | `CONFIG_SYS_CONFIG_NAME="chiplab-rv32"` → `include/configs/chiplab-rv32.h` |

### 8.2 符号/机制口径变化（新树必须按新名写）

| 旧口径 | 新口径（本树实测） | 出处 |
|---|---|---|
| `CONFIG_SYS_TEXT_BASE`（defconfig 里写） | **`CONFIG_TEXT_BASE`**；板级默认值写在 `board/<vendor>/<board>/Kconfig` 的 `config TEXT_BASE default ...` | 本树 `board/emulation/qemu-riscv/Kconfig`、`board/sifive/unleashed/Kconfig` |
| 运行模式符号 | 仍是 `RISCV_MMODE`/`RISCV_SMODE`（**没有** `RISCV_M_MODE`） | `arch/riscv/Kconfig:213,218`；`CONFIG_RISCV_M_MODE` 仅剩 `arch/riscv/include/asm/hwcap.h:97` 一个恒假的 `#ifdef` 死分支 |
| `CONFIG_SIFIVE_CLINT`（§2.3 提到的 S 模式依赖项） | **本树已无该符号**；M 模式改用 `RISCV_ACLINT` / `SPL_RISCV_ACLINT`（`depends on RISCV_MMODE`） | `arch/riscv/Kconfig:388,397`；`grep -rn "config SIFIVE_CLINT" --include=Kconfig` 无输出 |
| env 偏移写在板级头文件 | 走 Kconfig：`CONFIG_ENV_OFFSET` / `ENV_SIZE` / `ENV_RANGE`（defconfig 里写十六进制） | `env/Kconfig:337,644,675` |
| `CONFIG_SYS_NAND_SELF_INIT`（可写进 defconfig 的假设） | **隐藏符号**（`depends on MTD_RAW_NAND`，无 prompt）：写进 defconfig 会被**静默丢弃**，必须由板级 `select` | 本树 `drivers/mtd/nand/raw/Kconfig:6`；本轮实测见 8.5 |
| NAND 子系统符号 | `MTD` + `MTD_RAW_NAND`（menuconfig）+ `CMD_NAND`/`CMD_MTD`/`CMD_MTDPARTS` | `drivers/mtd/Kconfig:7`、`drivers/mtd/nand/raw/Kconfig:1`、`cmd/Kconfig:1619,3024` |
| S 模式服务 | `CONFIG_SBI`（`RISCV_SMODE` 隐含）+ `SBI_V02` + `SYSRESET_SBI`（`default y`，复位/关机走 SBI） | `arch/riscv/Kconfig:449-451`；`drivers/sysreset/Kconfig:184-187` |

> **§2 的结论是否仍然有效？** —— 有效，且方向相反也要防：新树同样**没有** `RISCV_M_MODE`，
> defconfig 里写 `CONFIG_RISCV_M_MODE=y` 依旧被静默忽略；本项目的纪律不变：
> **只允许** `RISCV_MMODE` / `RISCV_SMODE`（本项目取 `CONFIG_RISCV_SMODE=y`）。

### 8.3 阶段三 B-1：RV32 交叉构建打样（结果）

- 工具链（本机实测）：`/opt/riscv/bin/riscv32-unknown-linux-gnu-gcc`，**GCC 16.1.0**。
- 口径：`ARCH=riscv`、`CROSS_COMPILE=riscv32-unknown-linux-gnu-`；`*_defconfig` 与 `make` **都必须带**这两个变量。
- 打样板：`qemu-riscv32_smode_defconfig`（本树现成，S 模式 + RV32，最贴近本项目）。
- 命令与结果：

  ```sh
  make ARCH=riscv CROSS_COMPILE=riscv32-unknown-linux-gnu- qemu-riscv32_smode_defconfig
  make ARCH=riscv CROSS_COMPILE=riscv32-unknown-linux-gnu- -j16
  # 末行：  OFCHK   .config ; rc=0
  # 产物：  u-boot.bin = 1 033 368 B
  # size：  text 944165  data 89180  bss 60440  dec 1093785
  # 编译器告警：0 warning / 0 error（GCC 16.1.0）
  ```

- **唯一拦路问题（宿主机，不是 GCC16 兼容性）**：`make tools` 编译 `tools/mkeficapsule.o` 失败：
  `fatal error: gnutls/gnutls.h: No such file or directory`（缺 `libgnutls28-dev`，本项目不装系统包/不提权）。
  处置：`./scripts/config --file .config --disable TOOLS_MKEFICAPSULE` 后 `make olddefconfig` 再编，rc=0。
- **GCC16 兼容性问题清单：无**（目标代码 0 error / 0 warning）。§6 的 R4 风险由此关闭：
  **2019.07 + GCC16 的"老树遇新编译器"风险在新基线上不存在**。

### 8.4 阶段三 B-2：板级骨架（结果）

新增文件（全部在 `u-boot/` 内）：

| 文件 | 作用 |
|---|---|
| `configs/chiplab_rv32_defconfig` | 板级 defconfig（S 模式 / 16550 / NAND-MTD 预留 / env 区） |
| `include/configs/chiplab-rv32.h` | `CFG_SYS_SDRAM_BASE`、33 MHz 定时器口径、DDR 内地址划分与 env 地址 |
| `arch/riscv/dts/chiplab-rv32.dts` | DDR3/UART/CLINT/PLIC/SPI XIP + NAND(disabled) 节点 |
| `board/loongson/chiplab/{Kconfig,Makefile,chiplab.c,MAINTAINERS,README}` | 板级代码与文档 |
| `board/loongson/chiplab/check-addresses.sh` | 地址口径机器核对脚本（fail-closed，带反证方法） |

对上游既有文件的最小改动（2 处，属"目录挂接"的必要条件）：

1. `arch/riscv/Kconfig`：`target choice` 内新增 `config TARGET_CHIPLAB_RV32`；`# board-specific options below` 段新增 `source "board/loongson/chiplab/Kconfig"`。
2. `arch/riscv/dts/Makefile`：新增 `dtb-$(CONFIG_TARGET_CHIPLAB_RV32) += chiplab-rv32.dtb`。

构建与验收证据：

```sh
make ARCH=riscv CROSS_COMPILE=riscv32-unknown-linux-gnu- chiplab_rv32_defconfig
make ARCH=riscv CROSS_COMPILE=riscv32-unknown-linux-gnu- -j16
# 末行：  OFCHK   .config ; rc=0
# 产物：  u-boot.bin = 341 066 B ; u-boot.dtb = 6 002 B
# size：  text 317857  data 17184  bss 39088  dec 374129 ; 0 warning
# DTS：   dtc 编译 0 error；板级构建内联 DTC 同一份
# 核对：  board/loongson/chiplab/check-addresses.sh → rc=0（全部命中）
```

- 地址口径逐条对齐 `docs/kb/platform-facts.md`（DDR3 `0x0/128 MiB`、UART `0x1FE0_01E0`@33 MHz/115200、
  CLINT `0x1F00_0000`、PLIC `0x1F10_0000`、SPI XIP `0x1C00_0000`、NAND `0x1FE7_8000`），
  并交叉核对 `defconfig`（`DEBUG_UART_BASE/CLOCK`、`BAUDRATE`、`ENV_RANGE`）与 DTS 两侧不许分叉。
- UART 取 `reg-shift = 0` / `reg-io-width = 1`：依据是平台 `URT/uart_top.v:86`（`PADDR[2:0]` 即寄存器号）、
  `IP/AMBA/axi2apb.v:168,216`（AXI 字节地址原样进 APB）与旧树 `la32rsoc_defconfig:805`（`DEBUG_UART_SHIFT=0`）。
- 反证（构建级）：把 DTS 的 UART `reg` 改成 `0x1fe00000`（注释与 node 名不动）→ `dtc` 仍然 rc=0，
  但 `check-addresses.sh` rc=1（节点级核对 + 两侧交叉核对同时报红）；只改 defconfig 的
  `DEBUG_UART_BASE` 同样 rc=1；`cp` 恢复后 sha256 一致、脚本回到 rc=0。

### 8.5 与本文旧章节的逐条映射

| 旧章节 | 新口径下的状态 |
|---|---|
| §2.1/§2.2（不存在 `RISCV_M_MODE`；用 `RISCV_MMODE/RISCV_SMODE`） | **沿用**（新树同名符号）；`CONFIG_RISCV_M_MODE` 只有一处恒假 `#ifdef` 残留 |
| §2.3（S 模式不能直接驱动 CLINT ⇒ 定时器/复位走 SBI） | **沿用**（符号换成 `RISCV_ACLINT` 且仍 `depends on RISCV_MMODE`）；新树 S 模式定时器由 CPU 驱动用 `/cpus/timebase-frequency` 绑定通用 `riscv,timer` 驱动 |
| §2.4（`la32rsoc_defconfig` 作结构模板） | **不再适用**（新树没有 `la32rsoc_*`）；结构模板改为 `board/emulation/qemu-riscv/` + `board/sifive/unleashed/` |
| §3.1 board 目录 `board/<vendor>/rv32gc/` | 实际落点 **`board/loongson/chiplab/`**；`dram_init` 不自己写，用 `arch/riscv/cpu/generic/dram.c` 从自带 DTS `/memory` 取，板级只做 bank 与平台事实的对账（`chiplab.c:board_init`） |
| §3.2 defconfig 名 `rv32gc_defconfig` 与其中条目 | 实际 **`chiplab_rv32_defconfig`**；`CONFIG_RISCV_SMODE=y` ✔、`RISCV_M_MODE` 未出现 ✔；**`CONFIG_SYS_NAND_SELF_INIT=y` 写进 defconfig 会被静默丢弃**（隐藏符号），改由板级 `select` |
| §3.3 DTS 节点清单（cpus/memory/chosen/UART/NAND） | **已落地**（另加 CLINT/PLIC/SPI XIP）；`timebase-frequency` 放在 `/cpus`（CPU 驱动先查 hart 节点、再回退父节点） |
| §3.4/§3.5 NAND 驱动、`saveenv`、`bootcmd` 自动启动 | **未完成**：defconfig/DTS 只做编译期预留（`MTD`/`MTD_RAW_NAND`/`CMD_NAND`/`ENV_IS_IN_NAND`，NAND 节点 `status="disabled"`，板级提供弱 `board_nand_init()` 空桩）；驱动与寄存器语义见 `docs/porting/04-nand-driver.md` 与 PF §4/§9(U1,U2) |
| §4.1 构建命令与 GCC 兼容风险 | 命令更新为 `make ARCH=riscv CROSS_COMPILE=riscv32-unknown-linux-gnu- chiplab_rv32_defconfig && make ...`；GCC16 风险 **无**（8.3） |
| §4.2 验收 U1–U7 | U1（defconfig 无符号丢失）：**已按"逐条在 `.config` 里回查"完成**（`savedefconfig` 只省默认值，不能当丢符号判据）；U2（无 `RISCV_M_MODE`）：✔（脚本 §4）；U3（产出 `u-boot.bin`）：✔；U4–U7（NAND 识别/`mtdparts` 一致/`saveenv` 掉电保持/自动启动）：**待 NAND 驱动与上板** |
| §5 与 `arch/la32r`、`la32rsoc_defconfig` 的边界 | **不再适用**（新树无这些对象）；新边界＝只新增文件 + 2 处挂接改动（8.4），改上游文件须写清理由 |
| §6 风险 R1–R6 | R4（GCC16 兼容）**关闭**；R2（NAND 控制器寄存器全表）**仍在**（PF §9 U1/U2）；R3（`TEXT_BASE` 取值）按下述约定定：`0x0200_0000`（S 模式运行在 DDR3，由 OpenSBI 装载，**不走 SPI XIP**） |

### 8.6 新基线上的地址/时钟约定（与 `01-overview.md` §2.3 对齐）

| 用途 | 地址 | 依据 |
|---|---|---|
| OpenSBI (M) | `0x0100_0000`（≤1 MiB） | `01-overview.md` §2.3 [工程约定] |
| U-Boot (S) 代码 | `0x0200_0000`（`CONFIG_TEXT_BASE`） | 同上 |
| U-Boot 重定位前栈 | `0x01E0_0000`（`CUSTOM_SYS_INIT_SP_ADDR`） | 同上（本项目细分） |
| Linux kernel | `0x0400_0000`（`kernel_addr_r`，≤50 MiB） | 同上 + NAND `50M(kernel)` 分区 |
| DTB / ramdisk / script | `0x0740_0000` / `0x0750_0000` / `0x0730_0000` | 本项目细分，全部落在 DDR3 内 |
| U-Boot 重定位区 | DDR 顶端（`SYS_MALLOC_LEN=4 MiB`） | U-Boot 通用行为 |

### 8.7 遗留 / 风险（本次新增）

1. **无 qemu 冒烟**：本机 `qemu-system-riscv32` 缺失（`which` 实测），B-1/B-2 只到构建级；
   且本板 DTS 是真实平台地址，`-M virt` 无法等价验证（详见 `u-boot/board/loongson/chiplab/README` §遗留）。
2. **宿主机缺 `libgnutls28-dev`**：影响 `make tools`（`mkeficapsule`）。本项目**不装系统包、不提权**，
   在 defconfig 中 `# CONFIG_TOOLS_MKEFICAPSULE is not set` 以保持 `defconfig && make` 两条命令可复现。
3. **CLINT/PLIC 地址无平台 RTL 佐证**（PF §9 U8）：DTS 已按 `0x1F00_0000`/`0x1F10_0000` 登记，
   核内译码实现时须写进 `rtl/pkg/*defs.vh` 并回写 PF。
4. **`riscv,isa` 用传统字符串**（`rv32imafdc_zicsr_zifencei_zicntr_zicbom`）；Linux 阶段如需
   `riscv,isa-base` + `riscv,isa-extensions` 再补，须与核实际实现逐条对齐。
5. **UART 窗口内偏移 `+0x1E0` 含转述成分**（PF §2.5/§9 U3）；上板首轮若串口无声，按 U3 反查 APB 从口译码。
6. **NAND 路径未通**：`saveenv`/`nand`/`mtdparts` 目前不可用（§3.4/§3.5 待做）。
