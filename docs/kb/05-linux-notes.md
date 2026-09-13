# KB-05 Linux 移植知识

## 1. 基线事实

| 项目 | 值 |
|---|---|
| 上游树 | `la32r-Linux`，Linux **5.14.0-rc2**（浅克隆、单次压缩提交 `4ed7b98e08e8`，分支 `la32r-new-world`，无 tag） |
| LA32R 板架构 | `arch/loongarch`（`MACH_LOONGSON32` + `LS_SOC`），`la32_defconfig`，`loongson32_ls.dts` |
| **RISC-V 支持** | `arch/riscv` 为**基本上游 5.14-rc2**，已支持 `ARCH_RV32I`（`select MMU` = Sv32）、`-mabi=ilp32`、`rv32_defconfig` |
| RV32 关键 Kconfig | `ARCH_RV32I`（`Kconfig:224`）、`VA_BITS=32`、`PA_BITS=34`、`PAGE_OFFSET=0xC0000000`、`RISCV_M_MODE` 隐藏且 `default !MMU` |
| 参考驱动 | `drivers/mtd/nand/raw/ls1a_nand.c`（NAND，1173 行）、`drivers/irqchip/irq-ls1x.c`（可选参考） |

## 2. 移植要点

1. **不改架构**：保留 `arch/riscv`，新增 `SOC_CHIPLAB` + DTS + defconfig + 驱动。
2. **`arch/loongarch` 只作为参考**：其 CSR/异常/MMU（`ECODE/ERA/BADV/TCFG/DMWIN`）与 RISC-V（`scause/sepc/stval/satp`）完全不同，不要尝试转换。
3. **不要移植** `arch/loongarch/loongson32/serial.c`（有 `memset` 清零 port 的 bug）、`reset.c`（死循环）。
4. **定时器**：LA32R 用 CSR 常量定时器且**频率硬编码 200 MHz**；RV32 用 CLINT + 设备树 `timebase-frequency`。
5. **中断**：LA32R 用 `cpuic`（virq = 16 + hwirq，UART=19、GMAC=18、TIMER=27）；RV32 用 PLIC 标准驱动，DTS 中写 PLIC 源号。
6. **内核命令行**：LA32R 走 MIPS 风格 `a0=argc,a1=argv,a2=envp`（`a0==-2` 时 `a1`=DTB）；RISC-V 走标准的 `a0=hartid, a1=dtb`。
7. **根文件系统**：LA32R 是内建 initramfs（`CONFIG_INITRAMFS_SOURCE` 默认为空，必须设置）。

## 3. 重要配置符号（RV32）

| 符号 | 说明 |
|---|---|
| `CONFIG_ARCH_RV32I` | 32 位 + Sv32 |
| `CONFIG_SOC_CHIPLAB` | 新增的 SoC 符号（`select BUILTIN_DTB`、`SIFIVE_PLIC`、`CLINT_TIMER` 等） |
| `CONFIG_SIFIVE_PLIC` | PLIC 标准驱动 |
| `CONFIG_CLINT_TIMER` / `CONFIG_RISCV_TIMER` | CLINT 时钟源/事件 |
| `CONFIG_SERIAL_8250(_CONSOLE)` + `CONFIG_SERIAL_OF_PLATFORM` | 串口（零代码） |
| `CONFIG_MTD_NAND_CHIPLAB` + `CONFIG_MTD_NAND_ECC_SW_BCH` | NAND + 软件 ECC |
| `CONFIG_MTD_CMDLINE_PARTS` / `CONFIG_MTD_OF_PARTS` | 分区来源（弃用硬编码分区表） |
| `CONFIG_MTD_UBI` + `CONFIG_UBIFS_FS` | NAND 根文件系统（第二阶段） |
| `CONFIG_BUILTIN_DTB` | 内建设备树（先用这个减少变量） |
| `CONFIG_FPU` | RV32 下可用；**验证不足，建议第一阶段关闭** |

## 4. 调试手段

| 手段 | 用法 |
|---|---|
| earlycon | 命令行加 `earlycon=uart8250,mmio,0x1fe001e0` |
| 直接进 shell | `rdinit=/bin/sh` |
| 跳过 init 脚本 | `init=/bin/sh` |
| 内核日志级别 | `loglevel=8 ignore_loglevel` |
| 卡死定位 | `CONFIG_DEBUG_VM`、`CONFIG_DEBUG_ATOMIC_SLEEP`、`CONFIG_MAGIC_SYSRQ` |
| 用户态崩溃 | `CONFIG_DEBUG_INFO` + 静态 busybox + `dmesg` |
| 内存/MMU | `CONFIG_DEBUG_VM`、`CONFIG_PAGE_TABLE_CHECK`（新版本） |

## 5. 常见问题定位

| 现象 | 可能原因 |
|---|---|
| `Unable to handle kernel paging request` 随机出现 | Cache 与 DMA 一致性；Sv32 A/D 位更新实现；TLB 失效不彻底（`sfence.vma`） |
| 时钟中断过快/过慢 | `timebase-frequency` 与实际频率不符 |
| `sbi_console` 相关报错 | OpenSBI 未正确提供 console（SBI 版本/扩展缺失） |
| 用户态浮点崩溃 | RV32 FPU 上下文切换（`arch/riscv/kernel/fpu.S`）在该版本验证不足 |
| NAND probe 失败 | 几何 gate（128 KiB/2048/64）；分区定义冲突 |
| 挂载 UBIFS 失败 | ECC 布局或几何参数（`-m/-p/-e/-s`）与实测不符 |
