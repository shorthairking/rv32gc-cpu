# U-Boot 移植方案（RV32-GC + chiplab）

> 基线：`la32r-uboot`（工作区已有；宣称 U-Boot 2019.07，实为含 ~v2020.10 子系统的厂商快照，HEAD `1b96e814`，tag `baixinsoc-v0.1.0`）。
> 依据：`../../../../uboot-porting-report.md`。详细文件清单与行号见该报告。

---

## 1. 基本判断

- 该树**同时包含** `arch/la32r`（LA32R，用于 nscscc 板）和 **完整的 `arch/riscv`**（RV32I 为默认、`rv32imac/ilp32`、M/S 模式、CLINT/PLIC/PLMT、`RISCV_RDTIME`、SBI 客户端、`cpu/generic`、PIE 自重定位）。原生 RV32 板：`qemu-riscv32_defconfig`、`qemu-riscv32_smode_defconfig`、`ae350_rv32(_xip)`。
- 因此**移植 = 新增一个 board + defconfig + DTS + NAND 驱动**，不动 `arch/`。
- 现有 `board/nscscc/` 与 `la32rsoc_defconfig` 只作为**平台信息参考**（内存映射、串口地址、时钟），其代码不可直接复用（LA32R 汇编 + 虚拟地址窗口）。

**启动模式选择**：Linux（RV32+MMU）需要 SBI，因此 U-Boot 采用 **S 模式**（以 `qemu-riscv32_smode_defconfig` 为种子），运行在 OpenSBI 之上；OpenSBI 负责 M 模式（见 `../porting/00-overview.md` §2）。

## 2. 新增文件清单

| 文件 | 内容 |
|---|---|
| `arch/riscv/dts/chiplab_rv32.dts` | 设备树：`/memory`（128 MiB @0）、`/cpus`（`riscv,isa = "rv32imafdc_zicsr_zifencei_zicntr_zicbom"`）、`cpu-intc`、CLINT、PLIC、8250 串口、NAND 控制器（含分区）、`/chosen`（`stdout-path`、`bootargs`） |
| `arch/riscv/dts/Makefile` | 追加 `dtb-$(CONFIG_TARGET_CHIPLAB_RV32) += chiplab_rv32.dtb` |
| `board/loongson/chiplab/Kconfig` | `SYS_VENDOR=loongson`、`SYS_BOARD=chiplab`、`SYS_CONFIG_NAME="chiplab_rv32"` |
| `board/loongson/chiplab/Makefile` | `obj-y += chiplab.o` |
| `board/loongson/chiplab/chiplab.c` | `board_init_f` 内存初始化（`gd->ram_size = 128 MiB`）、`dram_init`、板级初始化（LED/confreg 可选） |
| `board/loongson/chiplab/MAINTAINERS` | 维护者条目 |
| `configs/chiplab_rv32_defconfig` | 见 §3 |
| `include/configs/chiplab_rv32.h` | 内存布局、环境变量、`CONFIG_BOOTCOMMAND`（**注意**：不要在 `EXTRA_ENV_SETTINGS` 里再定义 `bootcmd`，它会覆盖 `CONFIG_BOOTCOMMAND`，这是 la32r 树的既有坑） |
| `drivers/mtd/nand/raw/chiplab_nand.c` | NAND 控制器驱动（见 `04-nand.md`） |
| `drivers/mtd/nand/raw/Kconfig` / `Makefile` | 增加 `CONFIG_NAND_CHIPLAB` 与 `obj-$(CONFIG_NAND_CHIPLAB) += chiplab_nand.o` |
| `arch/riscv/lib/cache.c` | 实现 `flush_dcache_range`/`invalidate_dcache_range`（当前为 weak 空实现，NAND DMA 必须） |

## 3. defconfig 关键项（种子：`qemu-riscv32_smode_defconfig`）

```
CONFIG_TARGET_CHIPLAB_RV32=y
CONFIG_ARCH_RISCV=y
CONFIG_RISCV_SMODE=y            # S 模式（由 OpenSBI 提供 SBI）
CONFIG_SYS_TEXT_BASE=0x00200000 # DDR 物理地址（RISC-V 无 KSEG，全部用物理地址）
CONFIG_SYS_SDRAM_BASE=0x00000000
CONFIG_SYS_SDRAM_SIZE=0x08000000
CONFIG_SYS_RELOC_GD_ENV_ADDR=y
CONFIG_SPL=n
CONFIG_DEFAULT_DEVICE_TREE="chiplab_rv32"
CONFIG_OF_EMBED=y               # 或 OF_SEPARATE + 由 OpenSBI 传递
# 串口
CONFIG_SYS_NS16550=y
CONFIG_SYS_NS16550_SERIAL=y
CONFIG_SYS_NS16550_REG_SIZE=1
CONFIG_SYS_NS16550_CLK=33000000 # 平台 UART 时钟（33 MHz，见平台 DTS）
CONFIG_SYS_NS16550_COM1=0x1fe001e0
CONFIG_BAUDRATE=115200
# 定时器
CONFIG_RISCV_TIMER=y            # mtime 来自核内 CLINT
CONFIG_SYS_MALLOC_LEN=0x00800000
# MTD / NAND
CONFIG_MTD=y
CONFIG_DM_MTD=y
CONFIG_MTD_DEVICE=y
CONFIG_MTD_PARTITIONS=y
CONFIG_NAND=y
CONFIG_SYS_NAND_SELF_INIT=y
CONFIG_NAND_CHIPLAB=y
CONFIG_SYS_NAND_BASE=0x1fe78000
CONFIG_SYS_MAX_NAND_DEVICE=1
CONFIG_CMD_MTD=y
CONFIG_CMD_NAND=y
CONFIG_CMD_MTDPARTS=y
CONFIG_MTDPARTS_DEFAULT="nand-flash:256K(env),50M(kernel)ro,1M(dtb),-(rootfs)"
CONFIG_CMD_UBI=y                # 第二阶段（UBIFS 根文件系统）
CONFIG_ENV_IS_IN_NAND=y
CONFIG_ENV_OFFSET=0x0
CONFIG_ENV_SIZE=0x40000
CONFIG_ENV_SECT_SIZE=0x20000    # NAND 擦除块 128 KiB
# 启动
CONFIG_BOOTCOMMAND="mtd read kernel ${kernel_addr_r}; mtd read dtb ${fdt_addr_r}; booti ${kernel_addr_r} - ${fdt_addr_r}"
CONFIG_CMD_BOOTI=y
CONFIG_CMD_FDT=y
# 网络（可选，便于 tftp 更新镜像）
CONFIG_CMD_NET=y
CONFIG_CMD_TFTPBOOT=y
CONFIG_CMD_PING=y
```

## 4. 板级初始化要点

1. **全部使用物理地址**：LA32R 树使用的 `0xa0000000`/`0x9fxxxxxx` KSEG 别名在 RISC-V 上不存在（这是移植中最容易踩的坑，参考驱动 `ls1a_nand.c` 中的 `0x9fe78xxx`、`0xa0000000 |` 必须全部删除）。
2. **`CONFIG_PRE_CON_BUF_ADDR` 必须改**：la32r 树里它等于 `0x9fe001e0`（串口地址），会踩坏 UART；改为 DDR 中一段保留地址。
3. **`dram_init`**：`gd->ram_size = 0x0800_0000`（128 MiB，与内核 DTS 一致；la32r 树中头文件写 128 MB、注释写 256 MB，不一致，以 DTS 为准）。
4. **时钟**：`get_timer` 基于 CLINT `mtime`，由核内实现（频率 = CPU 时钟，100 MHz 目标）；U-Boot 通过 DT 的 `timebase-frequency` 获取。
5. **`fence.i`/cache 维护**：U-Boot 的 `flush_dcache_range` 在 `arch/riscv/lib/cache.c` 中是 weak 空函数；本核有 Cache，必须实现为 `cbo.flush`（Zicbom）循环，并在 NAND DMA 前后调用，否则镜像校验必然失败。
6. **OpenSBI 交互**：S 模式下 U-Boot 依赖 SBI 的 console/timer/IPI；调试阶段若遇到 "SBI call failed"，先用 OpenSBI 的 `fw_payload` 直接把 U-Boot 作为 payload 打包，排除 SBI 问题。

## 5. 从 NAND 启动与写 NAND（任务硬性要求）

```
# 首次烧写（通过串口/tftp 把镜像放到 DDR，再写入 NAND）
tftpboot ${kernel_addr_r} Image
mtd erase kernel
mtd write kernel ${kernel_addr_r} ${filesize}
tftpboot ${fdt_addr_r} chiplab_rv32.dtb
mtd erase dtb
mtd write dtb ${fdt_addr_r} ${filesize}
# 环境变量保存（写入 NAND env 分区）
setenv bootargs "console=ttyS0,115200 earlycon rdinit=/sbin/init"
saveenv
# 自动启动（bootcmd 见 §3）
reset        # 复位后应自动从 NAND 读取并启动 Linux
```

**验收判据**：
- `mtd list` 能列出 4 个分区且偏移/大小与 §7 一致；
- `mtd read/write/erase` 后数据 `md5sum`/`cmp` 一致（覆盖 DMA 与 cache 维护路径）；
- `saveenv` 后断电重启，`printenv` 保留；
- 复位后无需人工干预即可启动内核。

## 6. 构建与验证步骤

```bash
# 1) 准备源码树（在 build/ 下，不污染上游仓库）
sw/uboot/build_uboot.sh prepare      # 复制 la32r-uboot → build/u-boot，应用 patches/
# 2) 配置与编译
cd build/u-boot
make ARCH=riscv CROSS_COMPILE=riscv32-unknown-linux-gnu- chiplab_rv32_defconfig
make ARCH=riscv CROSS_COMPILE=riscv32-unknown-linux-gnu- -j$(nproc)
# 3) 产出
ls u-boot u-boot.bin u-boot.dtb
# 4) 先在 QEMU 上验证移植的正确性（qemu-system-riscv32 或自建 Spike+OpenSBI 流程）
```

> **先在 QEMU/Spike 上跑通**：QEMU 的 `sifive_u`/`virt` 机器可以验证 U-Boot 的 board/DTS/驱动框架是否正确（把 NAND 换成 MTD RAM 设备或用 `virtio`），再上真实 CPU，可显著减少联调时间。

## 7. 常见问题与对策

| 现象 | 原因 | 对策 |
|---|---|---|
| 串口无输出 | `PRE_CON_BUF_ADDR` 踩坏 UART / 波特率时钟不对 | 改 `PRE_CON_BUF_ADDR`；确认 `SYS_NS16550_CLK=33000000` |
| 启动即挂 | U-Boot 被链接到非 DDR 地址 / 未重定位 | `SYS_TEXT_BASE=0x00200000` 且在 DDR 内 |
| `bootcmd` 不是预期的 `mtd read ...` | `include/configs/*.h` 的 `EXTRA_ENV_SETTINGS` 里重复定义了 `bootcmd`（la32r 树的既有 bug） | 删除头文件中的 `bootcmd` 定义，只保留 `CONFIG_BOOTCOMMAND` |
| NAND 读写校验失败 | Cache 未 flush/inval（DMA 不具一致性） | 实现 `arch/riscv/lib/cache.c` 的 cache 维护（Zicbom）并在 DMA 前后调用 |
| NAND probe 失败 | 实际芯片几何与驱动 gate 不符（128 KiB/2048/64） | 放宽 `ls1a_nand_detect` 的几何限制，或确认板上芯片型号 |
