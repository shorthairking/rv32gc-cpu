# UPSTREAM：Linux 移植基线与构建口径

> 依据 `rv32gc-cpu/docs/porting/03-linux-opensbi.md` §7.2 交付要求（基线版本 + 补丁清单 +
> 构建命令）。落档时间：2026-09-21（L-m1/L-m2 完成后）。
> 详细报告与运行期证据：`docs/linux-port/README.md`、`docs/linux-port/logs/`。

## 1. 基线

| 项 | 值 |
|---|---|
| 基线树 | `/home/shorthair/dsh/rv32-cpu/linux`（上游主线快照，分支 `dev`） |
| 版本 | **7.3.0-rc4**（`Makefile`: VERSION 7 / PATCHLEVEL 3 / SUBLEVEL 0 / EXTRAVERSION -rc4） |
| 工具链 | `/opt/riscv/bin/riscv32-unknown-linux-gnu-`，GCC 16.1.0，binutils 2.47.20260726 |
| ABI/ISA | RV32IMAFDC + Zicsr/Zifencei/Zicntr，Sv32，S 模式 + SBI（**ilp32d** 用户态，`CONFIG_FPU=y`） |

## 2. 新增/修改文件（相对上游 7.3-rc4；**无上游代码补丁**）

| 文件 | 变更 | 轮次 |
|---|---|---|
| `arch/riscv/Kconfig.socs` | +`config SOC_CHIPLAB`（select SIFIVE_PLIC / SERIAL_8250(+CONSOLE) / SERIAL_OF_PLATFORM） | L-m1 |
| `arch/riscv/boot/dts/Makefile` | +`subdir-y += loongson` | L-m1 |
| `arch/riscv/boot/dts/loongson/Makefile` | 新增（`dtb-$(CONFIG_SOC_CHIPLAB) += chiplab-rv32.dtb`） | L-m1 |
| `arch/riscv/boot/dts/loongson/chiplab-rv32.dts` | 新增板级 DTS（ISA 新接口 / Sv32 / CLINT / PLIC / 16550 / NAND + 四分区） | L-m1/L-m2 |
| `arch/riscv/configs/chiplab_rv32_defconfig` | 新增（`defconfig` + `32-bit.config` 片段 + 板级选项 + MTD/NAND，`savedefconfig` 收敛） | L-m1/L-m2 |
| `drivers/mtd/nand/raw/chiplab_nand.c` | 新增 NAND 控制器驱动（exec_op + 平台 DMA + 自包含 BCH-4 + 分区） | L-m2 |
| `drivers/mtd/nand/raw/chiplab_bch.h` | 新增：**u-boot `chiplab_nand.h` 的逐字摘录**（§2 几何 + §3 ECC 布局 + §6 BCH）；两棵树必须同步修改 | L-m2 |
| `drivers/mtd/nand/raw/Kconfig` | +`config MTD_NAND_CHIPLAB`（tristate，depends on OF） | L-m2 |
| `drivers/mtd/nand/raw/Makefile` | +`obj-$(CONFIG_MTD_NAND_CHIPLAB) += chiplab_nand.o` | L-m2 |

## 3. 构建命令（可复现）

```sh
cd /home/shorthair/dsh/rv32-cpu/linux
export ARCH=riscv CROSS_COMPILE=/opt/riscv/bin/riscv32-unknown-linux-gnu-
make chiplab_rv32_defconfig          # 回放校验：生成的 .config 与实构建 .config 逐行相同
make -j"$(nproc)" Image dtbs
# 产物：arch/riscv/boot/Image、arch/riscv/boot/dts/loongson/chiplab-rv32.dtb
```

**打包步骤（不属于内核源码修改）**：

1. `docs/linux-port/scripts/mk_boot_image.py`：改写 Image 头 `text_offset` 为装入地址
   `0x03400000`，并**强制 4 MiB 对齐**（RV32 Linux `setup_vm()` 的 `BUG_ON(phys % PMD_SIZE)`）；
2. `docs/linux-port/scripts/pack_initramfs.py`：目录树 → cpio `newc`（按规范做
   "header+name 一起 4 字节对齐"）；
3. `u-boot/tools/mkimage -A riscv -O linux -T ramdisk -C gzip`：initrd 打 legacy uImage
   （本板 U-Boot 未开 `CONFIG_SUPPORT_RAW_INITRD`）。

## 4. 运行期口径（与平台/引导链的联动，详见报告 §4.4/§8.6）

| 项 | 值 |
|---|---|
| 内核装入地址 | `0x03400000`（4 MiB 对齐；Linux 会忽略该地址以下的内存 ⇒ 可用 76 MiB / 128 MiB） |
| booti 用 dtb | `0x02F00000`（U-Boot 会再搬到 `~0x06A5E000`） |
| initrd | `0x06000000`（U-Boot 会再搬到 `~0x06A62000`） |
| boot 链自用（不可占用） | OpenSBI `0x01000000`、U-Boot text `0x02000000`、**boot_stub/OpenSBI 的 DTB `0x03000000`**、U-Boot 重定位区+malloc `~0x07B00000` 以上 |
| 启动命令 | `setenv filesize <initrd 长度>` + `booti 0x03400000 0x06000000 0x02f00000` |

## 5. 一致性核对（供交叉引用）

* 时钟：DTS `timebase-frequency = 33000000` ↔ 平台 `config.h:33 FREQ` ↔ 客体内 FDT 实测 `01 f7 8a 40`；
* 内存：DTS `reg = <0x0 0x08000000>` ↔ PF §2.1 ↔ 客体内 FDT 实测 `00 00 00 00 | 08 00 00 00`；
* UART：`0x1FE0_01E0`、`reg-shift=0`、115200、33 MHz（与 U-Boot DTS/defconfig 同口径），
  中断绑 PLIC 源 1（本项目平台侧拍板口径，PF §9 U5 未在真板验证）；
* NAND：`0x1FE78000` + 门铃 `+0x40` + confreg order `0x1FD01160`；ECC 布局/位序与 U-Boot **同一份头文件**；
* 分区：`env 256K / kernel 50M / dtb 1M / rootfs 剩余`（与 `01-overview.md` §3.1 同源，全部 128 KiB 块对齐）。
