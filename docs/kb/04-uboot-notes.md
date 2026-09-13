# KB-04 U-Boot 移植知识

## 1. 基线事实

| 项目 | 值 |
|---|---|
| 上游树 | `la32r-uboot`（工作区），`git describe` = `baixinsoc-v0.1.0`，HEAD `1b96e814`（2024-04-16），11 个提交 |
| 声明版本 | 2019.07（但含 ~v2020.10 子系统：BLOBLIST、binman、`arch/riscv` 的 ICICLE/SBI_IPI）→ **cherry-pick 上游补丁时不要相信版本号** |
| 架构目录 | `arch/la32r`（LA32R 板）+ **`arch/riscv`（完整，RV32I 默认，rv32imac/ilp32，M/S 模式、CLINT/PLIC/PLMT、SBI 客户端、PIE 自重定位）** |
| 可参考的 RV32 板 | `qemu-riscv32_defconfig`、`qemu-riscv32_smode_defconfig`、`ae350_rv32(_xip)` |
| LA32R 板 | `board/nscscc/`、`configs/la32rsoc_defconfig`、`include/configs/la32rsoc_demo.h`、`arch/la32r/dts/la32rsoc_demo.dts` |

## 2. 移植要点（RV32）

1. **不改 `arch/`**：直接复用 `arch/riscv`，新增 `board/loongson/chiplab/`、`configs/chiplab_rv32_defconfig`、`include/configs/chiplab_rv32.h`、`arch/riscv/dts/chiplab_rv32.dts`。
2. **全部使用物理地址**（RISC-V 无 KSEG；LA32R 的 `0x9fe001e0`/`0xa0000000|` 全部无效）。
3. **S 模式**（`CONFIG_RISCV_SMODE=y`），运行在 OpenSBI 之上；串口/定时器走 SBI。
4. **`CONFIG_SYS_TEXT_BASE=0x0020_0000`**（DDR 内）；`SYS_SDRAM_BASE=0`、`SYS_SDRAM_SIZE=0x0800_0000`。
5. **NAND**：新增驱动 + `CONFIG_NAND/CMD_NAND/CMD_MTD/CMD_MTDPARTS/MTD_DEVICE/ENV_IS_IN_NAND`。
6. **Cache 维护**：`arch/riscv/lib/cache.c` 的 `flush_dcache_range`/`invalidate_dcache_range` 是 weak 空实现 → 必须实现（`cbo.flush`/`cbo.inval`），NAND DMA 依赖它。
7. **环境变量存 NAND**：`CONFIG_ENV_IS_IN_NAND=y`、`ENV_OFFSET=0x0`、`ENV_SIZE=0x40000`、`ENV_SECT_SIZE=0x20000`。

## 3. 已知坑（来自详查报告）

| 坑 | 说明 | 处理 |
|---|---|---|
| `EXTRA_ENV_SETTINGS` 里重复定义 `bootcmd` | `include/env_default.h` 中 `EXTRA_ENV_SETTINGS` 在 `CONFIG_BOOTCOMMAND` **之后**发出，重复键会覆盖（`lib/hashtable.c`），LA32R 板的实际 bootcmd 就是被这个"野生"定义覆盖的 | 头文件里**不要**再写 `bootcmd` |
| `board/nscscc/2019/` 实际未参与编译 | `CONFIG_SYS_BOARD/SYS_VENDOR` 未设置 → `BOARDDIR` 为空 | 新板务必正确设置 `SYS_VENDOR/SYS_BOARD/SYS_CONFIG_NAME` |
| `CONFIG_PRE_CON_BUF_ADDR` 指向串口地址（`0x9fe001e0`） | 会踩坏 UART | 改到 DDR 保留区 |
| RAM 大小描述不一致（头文件 128 MB，注释 256 MB） | 以平台实际 128 MiB 为准 | 统一 128 MiB |
| LA32R 的 `start.S` 从 SPI XIP 复制自身再重定位 | RISC-V 用标准 PIE 自重定位流程 | 用 `qemu-riscv32_smode` 的流程 |
| LA32R 工具链未安装 | 该树无法直接构建 | 用 `riscv32-unknown-linux-gnu-`（RV32）或自建 `riscv32-unknown-elf` |

## 4. 常用命令与配置符号

```bash
# 配置与编译
make ARCH=riscv CROSS_COMPILE=riscv32-unknown-linux-gnu- chiplab_rv32_defconfig
make ARCH=riscv CROSS_COMPILE=riscv32-unknown-linux-gnu- -j$(nproc)
# 产出：u-boot（ELF）、u-boot.bin（二进制）、u-boot.dtb
```

| 符号 | 用途 |
|---|---|
| `CONFIG_SYS_TEXT_BASE` | U-Boot 链接/重定位基址 |
| `CONFIG_SYS_SDRAM_BASE`/`_SIZE` | DDR 基址与容量 |
| `CONFIG_SYS_NS16550_CLK`/`_COM1` | 串口时钟与寄存器基址 |
| `CONFIG_RISCV_TIMER` / `CONFIG_SBI` | 定时器（RV32 下经 SBI） |
| `CONFIG_SYS_NAND_SELF_INIT` / `CONFIG_SYS_NAND_BASE` | 自初始化 NAND（`board_nand_init`） |
| `CONFIG_MTDPARTS_DEFAULT` | 默认分区表 |
| `CONFIG_ENV_IS_IN_NAND` + `ENV_OFFSET/ENV_SIZE/ENV_SECT_SIZE` | 环境变量存 NAND |
| `CONFIG_BOOTCOMMAND` | 自动启动命令 |

## 5. MTD/NAND 命令速查

```
mtd list                                  # 列出 MTD 设备与分区
mtd read <part> <addr> [off] [len]        # 从分区读到内存
mtd write <part> <addr> [off] [len]       # 从内存写入分区
mtd erase <part> [off] [len]              # 擦除
nand info / nand device / nand bad        # NAND 信息
nand read/write/erase ...                 # 原生 NAND 命令
ubi part <part>; ubi info; ubifsmount ubi0:rootfs; ubifsload <addr> <file>
saveenv                                   # 保存环境变量到 NAND
```

## 6. 启动命令模板

```
setenv kernel_addr_r 0x01000000
setenv fdt_addr_r    0x00f00000
setenv bootargs "console=ttyS0,115200 earlycon rdinit=/sbin/init"
setenv bootcmd 'mtd read kernel ${kernel_addr_r}; mtd read dtb ${fdt_addr_r}; booti ${kernel_addr_r} - ${fdt_addr_r}'
saveenv
```

## 7. 验证顺序

1. 在 QEMU（`qemu-system-riscv32 -M virt` 或 `sifive_u`）上先跑通 board/DTS/驱动框架；
2. 上板：串口输出 → `mtd list` → `mtd read/write` 校验 → `saveenv` 持久化 → `bootcmd` 自动启动内核。
