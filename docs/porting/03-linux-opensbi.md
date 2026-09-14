# Linux + OpenSBI 移植方案

> **文档定位**：RV32-GC 项目的 Linux 内核移植（S 模式 + SBI、Sv32）与 OpenSBI 集成方案。
> **基线树**：
> - Linux 移植基线：`la32r-Linux/`（**5.14.0**）[RTL 实测] `la32r-Linux/Makefile:2-4`
> - OpenSBI：本机 `opensbi/`（上游，generic 平台）
> - **参考**上游：`linux/`（**7.3.0-rc2**）[RTL 实测] `linux/Makefile:2-5`
> **纪律**：上游源码树**不复制**进本项目；用"新增文件 + 补丁序列 + 构建脚本"管理，版本号记录在 `sw/*/UPSTREAM.md`。

---

## 1. 为什么 Linux 必须走 S 模式 + SBI

### 1.1 Kconfig 事实链

在 `la32r-Linux/arch/riscv/Kconfig` 中：[RTL 实测] `la32r-Linux/arch/riscv/Kconfig:126-133`

```kconfig
# set if we run in machine mode, cleared if we run in supervisor mode
config RISCV_M_MODE
	bool
	default !MMU                                    # ← 126-128 行

# set if we are running in S-mode and can use SBI calls
config RISCV_SBI
	bool
	depends on !RISCV_M_MODE                        # ← 131-133 行
	default y
```

同时，`MMU` 的 `default y`：[RTL 实测] `la32r-Linux/arch/riscv/Kconfig:135-137`

```kconfig
config MMU
	bool "MMU-based Paged Memory Management Support"
	default y
```

**推导链**：

1. `MMU` 默认 `y` ⇒ `!MMU` = 假；
2. `RISCV_M_MODE` 的 `default !MMU` = 假 ⇒ **M 模式自动关闭**；
3. `RISCV_SBI` 的 `depends on !RISCV_M_MODE` = 真，且 `default y` ⇒ **SBI 自动开启**；
4. ⇒ **S 模式 + SBI 路线成立**。

### 1.2 结论

- 软件栈固定为 **OpenSBI(M) + U-Boot(S) + Linux(S, Sv32)**（见 `docs/porting/01-overview.md` §1.2），**不重议**。
- Linux 运行于 **S 模式**，使用 **Sv32** 两级页表；所有 M 模式服务（定时器、IPI、关机、重启）通过 **SBI 调用**获得。
- **注意与 U-Boot 的符号名差异**：U-Boot 2019.07 树用的是 `RISCV_MMODE`/`RISCV_SMODE`（见 `docs/porting/02-uboot.md` §2）；**Linux 树用的是 `RISCV_M_MODE`**。两棵树符号名不同，**不可互串**。

---

## 2. Linux 移植工作项

### 2.1 新增 `SOC_CHIPLAB`

- 本树的 SoC 符号集中在 **`arch/riscv/Kconfig.socs`**。[RTL 实测] `ls la32r-Linux/arch/riscv/` → 含 `Kconfig.socs`
- 新增：

  ```kconfig
  config SOC_CHIPLAB
  	bool "chiplab (Loongson Artix-7 lab board)"
  	depends on !MMU || MMU        # 按实际
  	help
  	  Support for the chiplab SoC on the Loongson Artix-7 experiment board.
  ```

- 连带需要：`arch/riscv/configs/<board>_defconfig`、`arch/riscv/boot/dts/<vendor>/<board>.dts`（+ Makefile 追加）。

### 2.2 新增 DTS

必须描述的节点 [工程约定]：

| 节点 | 内容 | 来源 |
|---|---|---|
| `/cpus` | hart 数、`riscv,isa`（`i m a f d c` + `zicsr`/`zifencei`）、`mmu-type = "riscv,sv32"` | 本项目 ISA 目标 |
| `/memory` | DDR3 `0x0` / `0x08000000`（128 MiB） | `docs/kb/platform-facts.md` §2.1 |
| `chosen` | `bootargs`、`stdout-path` | — |
| `timebase-frequency` | **33000000** | `config.h:33`（`docs/kb/platform-facts.md` §5） |
| 串口 | 平台 UART 地址 | `docs/kb/platform-facts.md` §2.5 |
| NAND 控制器 | `nand@1FE78000` + `partitions` 子节点 | `docs/kb/platform-facts.md` §4 |
| `interrupt-controller` | PLIC/CLINT 口径 | **不确定项**，见 `docs/kb/platform-facts.md` §9 U5/U8 |

- **分区定义必须与 U-Boot `mtdparts` 同源**（`01-overview.md` §3.1），避免两侧分叉。

### 2.3 NAND MTD 驱动框架

- **落点**：`drivers/mtd/nand/raw/` 下新增平台驱动（参考 `la32r-Linux/drivers/mtd/nand/raw/ls1a_nand.c` 的**命令序列**，但**地址/cache/DMA 部分必须重写**）。[旧项目转述]
- **分层口径**（详见 `docs/porting/04-nand-driver.md`）：
  - **mtd 层**：MTD 抽象（读写/擦除/坏块）；
  - **nand 层**：通用 NAND 命令与 ECC 框架；
  - **controller 层**：平台 APB NAND 控制器寄存器操作 + **DMA 引擎搬运**。
- **必须开启的 Kconfig** [工程约定]：`CONFIG_MTD`、`CONFIG_MTD_RAW_NAND`、`CONFIG_MTD_NAND_<PLATFORM>`，以及坏块表与 ECC 相关项。
- **ECC 策略**：芯片要求 **1 bit/512 B** ⇒ 软件 BCH-4（或 Hamming）。**U-Boot 与内核必须使用相同 ECC 布局**（见 `04-nand-driver.md` §4）。

---

## 3. 参照上游 `linux/` 的 rv32 配置

### 3.1 上游 `linux/` 树可用的 rv32 素材

本机 `linux/`（**7.3.0-rc2**）[RTL 实测] `linux/Makefile:2-5`，其 `arch/riscv/configs/` 含：[RTL 实测] `ls linux/arch/riscv/configs/`

| 文件 | 用途 |
|---|---|
| `32-bit.config` | **RV32 开关片段**（最关键） |
| `64-bit.config` | RV64 开关片段 |
| `defconfig` | 通用默认 |
| `nommu_*_defconfig` | 无 MMU 变体 |
| `hardening.config` | 加固选项 |

- `32-bit.config` 全文很短，是 RV32 的**最小开关集**：[RTL 实测] `linux/arch/riscv/configs/32-bit.config`

  ```
  # Help: Build a 32-bit image
  CONFIG_ARCH_RV32I=y
  CONFIG_32BIT=y
  # CONFIG_PORTABLE is not set
  CONFIG_NONPORTABLE=y
  ```

- **用法**：以 `32-bit.config` 为 **fragment**，叠加在板级 defconfig 之上。`CONFIG_NONPORTABLE=y` 表示允许非可移植的 RV32 构建（RV32 上这是**必须**的，因为多数平台依赖不可移植假设）。

- `nommu_virt_defconfig` 展示了 RV32 平台的完整选项风格（`CONFIG_ARCH_VIRT=y`、`CONFIG_NONPORTABLE=y`、`CONFIG_SMP=y`、`CONFIG_CMDLINE="... earlycon=... console=ttyS0"`）。[RTL 实测] `linux/arch/riscv/configs/nommu_virt_defconfig:24-30`
  → **本项目参照其结构**（不用其 `CONFIG_ARCH_VIRT`，改用本项目 `SOC_CHIPLAB`）。

### 3.2 版本差异警示

| 项 | 移植基线 `la32r-Linux` | 参考上游 `linux/` |
|---|---|---|
| 版本 | **5.14.0** | **7.3.0-rc2** |
| SoC 符号位置 | `arch/riscv/Kconfig.socs` | 同名，但内容差异大 |
| `RISCV_M_MODE` | **存在**（`:126-128`） | 需重新确认（上游已重构） |
| 驱动 API | 5.14 风格 | 7.x 风格 |

- **纪律**：**以移植基线的 API 为准**；上游只用于**取配置思路与 DTS 结构**，**不得**把 7.x 的 C 代码/API 直接套到 5.14 树上。

---

## 4. OpenSBI 集成

### 4.1 使用本机 `opensbi/` 上游 + generic 平台

- 本机 `opensbi/` 为上游树，含 `platform/generic/`。[RTL 实测] `ls opensbi/platform/generic/`
- **generic 平台**通过 FDT 发现硬件，无需为 chiplab 写专用 platform 代码（**首选路线**）；若 generic 无法表达平台差异，再考虑新增平台目录。

### 4.2 FW_JUMP vs FW_PAYLOAD 的选择

| 固件类型 | 语义 | 出处 |
|---|---|---|
| **FW_JUMP** | 只处理**下一级入口地址**，**不包含**下一级的二进制代码 | `opensbi/docs/firmware/fw_jump.md`（kb chunk 7687，lines 1-79） |
| **FW_PAYLOAD** | **直接内嵌**下一级（通常是 bootloader 或 OS 内核）的二进制 | `opensbi/docs/firmware/fw_payload.md`（kb chunk 7689，lines 1-78） |

- **FW_JUMP 的适用条件**：先于 OpenSBI 执行的引导阶段**有能力**把 OpenSBI 固件**和**其后的阶段都加载进内存。
  → `opensbi/docs/firmware/fw_jump.md`（kb chunk 7687）
- **FW_PAYLOAD 的适用条件**：先于 OpenSBI 的引导阶段**无法**同时加载两者，**或**它**不传递 FDT** —— 此时 FW_PAYLOAD **允许内嵌一个扁平设备树**。
  → `opensbi/docs/firmware/fw_payload.md`（kb chunk 7689）；`opensbi/docs/firmware/fw.md`（kb chunk 7684，lines 1-120）

### 4.3 本项目推荐路线

**推荐：`FW_JUMP` + `FW_JUMP_FDT_ADDR`** [工程约定]

理由：本项目的早期引导（SPI XIP 阶段）**有能力**把 OpenSBI 与 U-Boot 都拷进 DDR，且 U-Boot 的 DTS 是**外部提供**的 ⇒ 满足 FW_JUMP 的适用条件。

**FDT 传递口径**：

- FW_JUMP 的 `FW_JUMP_FDT_ADDR` 用于指定**由上一阶段传入的 FDT 被搬到内存的位置**，该位置在**执行 OpenSBI 之后的阶段之前**。
- **若不提供该选项**，OpenSBI 会把**上一阶段传入的 FDT 地址**原样传给下一阶段。
  → `opensbi/docs/firmware/fw_jump.md`（kb chunk 7688，lines 1-79）
- **⚠️ 溢出风险**：使用 `PLATFORM=generic` 的**默认** `FW_JUMP_FDT_ADDR` 时，**必须确认该地址足够高，避免覆盖内核**。文档给出的检查方式是在 shell 里用 `${CROSS_COMPILE}objdump` 等工具核算。
  → `opensbi/docs/firmware/fw_jump.md`（kb chunk 7688）
  → **本项目处置**：FDT 地址必须放在**内核镜像之后**，且必须与 `01-overview.md` §2.3 的 DDR 布局表联动核算。

### 4.4 OpenSBI 构建要点 [工程约定]

```sh
make -C opensbi PLATFORM=generic \
  CROSS_COMPILE=<toolchain-prefix> \
  FW_JUMP=y \
  FW_JUMP_ADDR=<U-Boot 入口物理地址> \
  FW_JUMP_FDT_ADDR=<DTB 搬运目标物理地址>
```

- **`FW_JUMP_ADDR` = 下一阶段（U-Boot）的入口物理地址**，必须与 `02-uboot.md` 的 `CONFIG_SYS_TEXT_BASE` **逐字一致**。
- **平台初始化**：generic 平台依赖 FDT 发现；因此 **`a1`（DTB 地址）必须正确传入**（见 `01-overview.md` §2.4）。
- **时钟口径**：OpenSBI 的平台时钟必须与 `config.h:33` 的 33 MHz 一致，否则 `mtime`/`mtimecmp` 定时器频率错误。

---

## 5. 验收判据

| # | 判据 | 判定方式 |
|---|---|---|
| L1 | `CONFIG_RISCV_M_MODE` 自动关闭、`CONFIG_RISCV_SBI=y` | 内核 `.config` 中 grep 确认 |
| L2 | 内核以 **S 模式**启动 | 启动日志 `Privilege : Supervisor` 或等效行 |
| L3 | **Sv32** 生效 | `satp.MODE = 1`；日志显示 MMU 开启 |
| L4 | `timebase-frequency` 与 33 MHz 一致 | DTS grep + 内核时钟源日志 |
| L5 | NAND MTD 分区被识别 | `/proc/mtd` 出现 4 个分区且与 `mtdparts` 一致 |
| L6 | 根文件系统挂载成功 | 日志 `VFS: Mounted root` |
| L7 | OpenSBI 传递 FDT 成功 | 内核能解析 DTS 且内存大小为 128 MiB |
| L8 | FDT 地址不与内核重叠 | 构建期核算（§4.3） |

- **回归纪律**：脚本**"未捕获即失败"**，兜底文案**不得含 `PASS`**（`docs/kb/tools-and-flow.md` §5）。

---

## 6. 不确定项与风险

| # | 项 | 处置 |
|---|---|---|
| K1 | `la32r-Linux` 为 **5.14**，需确认 RV32 在 5.14 树的 `ARCH_RV32I` 支持完整度 | 构建期验证；必要时补丁 |
| K2 | PLIC/CLINT 的 DTS 口径（平台 RTL 无显式常量） | 见 `docs/kb/platform-facts.md` §9 U5/U8 |
| K3 | 5.14 与 GCC 16.1.0 的兼容性 | 独立风险记录，不擅自改编译器旗标 |
| K4 | generic 平台能否正确发现本项目所有外设 | 先用最小 FDT 引导，再逐步补全节点 |
| K5 | `CONFIG_NONPORTABLE` 的连带影响 | 参照上游 `32-bit.config`，逐项确认 |
| K6 | `FW_JUMP_FDT_ADDR` 最终取值 | 必须与 DDR 布局、内核大小联动核算（§4.3） |

---

## 7. 交付要求

[工程约定]

1. **新增文件清单**（`Kconfig.socs` 条目、defconfig、DTS、NAND 驱动）+ **补丁序列**；
2. **`sw/linux/UPSTREAM.md`** 与 **`sw/opensbi/UPSTREAM.md`**：基线版本、补丁列表、构建命令、FW_JUMP 参数；
3. **构建与验收脚本**（可复现命令 + 判定输出，fail-closed）；
4. **自证报告**：按 §5 表格逐项给出证据；
5. **登记不确定项**到 §6 与 `docs/kb/platform-facts.md` §9。
