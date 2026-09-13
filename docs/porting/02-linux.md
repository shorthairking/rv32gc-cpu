# Linux 内核移植方案（RV32-GC + chiplab）

> 基线：`la32r-Linux`（Linux 5.14.0-rc2，`arch/loongarch` 为 LA32R 板、`arch/riscv` 为**上游 RV32 可用**代码）。
> 依据：`../../../../linux-porting-report.md`（含逐文件移植面表格与 NAND 深挖）。

---

## 1. 核心决策

| 决策 | 选择 | 理由 |
|---|---|---|
| 架构基线 | **`arch/riscv`**（该树中已有，支持 `ARCH_RV32I` → `select MMU`（Sv32）+ `-mabi=ilp32`） | 无需做架构移植；`arch/loongarch` 的 CSR/异常/MMU 模型与 RISC-V 完全不同，改造成本极高 |
| 内核版本 | 沿用该树的 **5.14.0-rc2**（可与工作区源码一一对应，便于对照） | 若后续需要新特性，可整体升级到 6.x（`arch/riscv` 的 RV32 支持在新版本中更成熟），但需重做 DTS/驱动适配 |
| 运行模式 | **S 模式 + Sv32**（`RISCV_M_MODE` 在 5.14 中隐藏且 `default !MMU`，故 MMU 内核必须走 SBI） | 与 OpenSBI + S 模式 U-Boot 的标准三段式一致 |
| 设备树 | 新增 `arch/riscv/boot/dts/chiplab/chiplab.dts`；**建议 `CONFIG_BUILTIN_DTB=y`**（与 LA32R 板一致，避免 DTB 传递问题） | 减少启动链依赖 |
| 根文件系统 | 第一阶段 **initramfs**（busybox），第二阶段 UBIFS on NAND | 先保证能启动，再追求"像硬盘一样用 NAND" |

## 2. 新增/修改文件清单

| 文件 | 动作 | 内容 |
|---|---|---|
| `arch/riscv/Kconfig.socs` | 新增 | `config SOC_CHIPLAB`：`select BUILTIN_DTB`、`select SIFIVE_PLIC`、`select CLINT_TIMER`、`select POWER_RESET`、`select ZICBOM`（若内核版本支持） |
| `arch/riscv/boot/dts/chiplab/chiplab.dts` | 新增 | 见 §3 |
| `arch/riscv/boot/dts/chiplab/Makefile` | 新增 | `dtb-$(CONFIG_SOC_CHIPLAB) += chiplab.dtb` |
| `arch/riscv/boot/dts/Makefile` | 修改 | 加入 `chiplab/` 子目录 |
| `arch/riscv/configs/rv32_chiplab_defconfig` | 新增 | 以 `rv32_defconfig` 为种子（见 §4） |
| `drivers/mtd/nand/raw/chiplab_nand.c` | 新增 | 由 `ls1a_nand.c` 改写（见 `04-nand.md`） |
| `drivers/mtd/nand/raw/Kconfig` / `Makefile` | 修改 | `config MTD_NAND_CHIPLAB` + `obj-$(CONFIG_MTD_NAND_CHIPLAB) += chiplab_nand.o` |
| `drivers/power/reset/chiplab-reboot.c`（可选） | 新增 | 通过 CONFREG 实现 `reboot`/`poweroff`（当前 LA32R 树只有死循环） |
| `arch/riscv/mm/` | 不改 | Sv32 页表、TLB flush（`sfence.vma`）已具备 |
| `arch/riscv/kernel/head.S` | 不改 | 已支持 RV32 的 satp 设置与 4 MiB 加载偏移约定 |

## 3. 设备树要点（`chiplab.dts`）

```dts
/ {
    #address-cells = <1>; #size-cells = <1>;
    model = "chiplab,rv32gc";
    compatible = "chiplab,rv32gc";

    chosen { stdout-path = "serial0:115200n8"; bootargs = "console=ttyS0,115200 earlycon"; };

    cpus {
        #address-cells = <1>; #size-cells = <0>;
        timebase-frequency = <100000000>;      /* = cpu_clk，升频后同步修改 */
        cpu@0 {
            device_type = "cpu";
            reg = <0>;
            status = "okay";
            compatible = "riscv";
            riscv,isa = "rv32imafdc_zicsr_zifencei_zicntr_zicbom";
            mmu-type = "riscv,sv32";
            clock-frequency = <100000000>;
            cpu0_intc: interrupt-controller {
                compatible = "riscv,cpu-intc";
                interrupt-controller; #interrupt-cells = <1>;
            };
        };
    };

    memory@0 { device_type = "memory"; reg = <0x00000000 0x08000000>; };  /* 128 MiB */

    clint@1f000000 { compatible = "riscv,clint0";
        reg = <0x1f000000 0x00010000>; reg-names = "control";
        interrupts-extended = <&cpu0_intc 3 &cpu0_intc 7>; };

    plic: interrupt-controller@1f100000 { compatible = "sifive,plic-1.0.0";
        reg = <0x1f100000 0x00100000>; #interrupt-cells = <1>;
        interrupt-controller; riscv,ndev = <8>;
        interrupts-extended = <&cpu0_intc 11 &cpu0_intc 9>; };

    soc {
        compatible = "simple-bus"; #address-cells = <1>; #size-cells = <1>;
        ranges;
        uart0: serial@1fe001e0 { compatible = "ns16550a"; reg = <0x1fe001e0 0x10>;
            clock-frequency = <33000000>; interrupt-parent = <&plic>; interrupts = <2>; };
        nand: nand@1fe78000 { compatible = "chiplab,nand";
            reg = <0x1fe78000 0x4000>, <0x1fd01160 0x4>;      /* 控制器 + DMA 门铃 */
            reg-names = "nand", "dma-order";
            interrupt-parent = <&plic>; interrupts = <4>;
            dma-noncoherent;                                   /* 关键：非一致性 DMA */
            nand-ecc-engine = "soft_bch";
            partitions { compatible = "fixed-partitions"; #address-cells=<1>; #size-cells=<1>;
                partition@0     { label = "env";    reg = <0x00000000 0x00040000>; };
                partition@40000 { label = "kernel"; reg = <0x00040000 0x03200000>; read-only; };
                partition@3240000 { label = "dtb";  reg = <0x03240000 0x00100000>; };
                partition@3340000 { label = "rootfs"; reg = <0x03340000 0x04cc0000>; };
            };
        };
    };
};
```

**注意**：
1. 所有地址均为**物理地址**（RISC-V 无 KSEG）；
2. `timebase-frequency` 必须等于 CPU 实际时钟（100 MHz 目标），否则时钟中断频率错误；
3. `dma-noncoherent` + 内核的非一致性 DMA 支持（`Zicbom` 或自定义 `arch_sync_dma_*`）是 NAND 正确性的前提；
4. CONFREG 不作为 Linux 必需设备（仅 reboot/仿真退出），可后续补充。

## 4. defconfig 关键项

```
CONFIG_ARCH_RV32I=y
CONFIG_SOC_CHIPLAB=y
CONFIG_SMP=n                    # 单核
CONFIG_BUILTIN_DTB=y
CONFIG_CMDLINE="console=ttyS0,115200 earlycon rdinit=/sbin/init"
CONFIG_HZ=100
CONFIG_SERIAL_8250=y
CONFIG_SERIAL_8250_CONSOLE=y
CONFIG_SERIAL_OF_PLATFORM=y
CONFIG_SERIAL_EARLYCON=y
CONFIG_SIFIVE_PLIC=y
CONFIG_CLINT_TIMER=y            # 若 5.14 无此符号，则用 CONFIG_RISCV_TIMER/内建 riscv,timer
CONFIG_MTD=y
CONFIG_MTD_BLOCK=y
CONFIG_MTD_CMDLINE_PARTS=y
CONFIG_MTD_OF_PARTS=y
CONFIG_MTD_NAND_CORE=y
CONFIG_MTD_NAND_CHIPLAB=y
CONFIG_MTD_NAND_ECC_SW_BCH=y    # 先软件 ECC
CONFIG_MTD_UBI=y                # 第二阶段
CONFIG_UBIFS_FS=y
CONFIG_BLK_DEV_INITRD=y
CONFIG_INITRAMFS_SOURCE="../../sw/rootfs/initramfs"   # 或由脚本注入
CONFIG_DEVTMPFS=y
CONFIG_DEVTMPFS_MOUNT=y
CONFIG_TMPFS=y
CONFIG_PROC_FS=y
CONFIG_SYSVIPC=y
CONFIG_FPU=y                    # 第一阶段可先 =n 以降低风险
CONFIG_RISCV_ISA_C=y
```

## 5. 启动流程与加载方式

```
# U-Boot（S 模式）
mtd read kernel ${kernel_addr_r}     # Image（原始二进制内核）
mtd read dtb    ${fdt_addr_r}
booti ${kernel_addr_r} - ${fdt_addr_r}
```
- 内核镜像使用 `arch/riscv/boot/Image`（`objcopy -O binary vmlinux`）；RV32 内核要求加载地址 2 MiB 对齐（`head.S` 约定 4 MiB 偏移上限），`kernel_addr_r = 0x0100_0000` 满足；
- OpenSBI 以 `FW_PAYLOAD` 或 `FW_DYNAMIC` 形式提供 SBI；若使用 `FW_DYNAMIC`，则由 U-Boot 通过 `booti` 的 SBI 参数传递（更灵活，推荐 OpenSBI `fw_dynamic` + U-Boot 的 `CONFIG_SBI_V0_2`/`RISCV_SBI` 支持）。

## 6. 调试手段

| 手段 | 说明 |
|---|---|
| `earlycon=uart8250,mmio,0x1fe001e0` | 内核最早期的串口输出（在 8250 驱动 probe 之前） |
| `CONFIG_DEBUG_LL` / `CONFIG_EARLY_PRINTK` | 更早的输出（不依赖 DT） |
| 静态链接 + `rdinit=/bin/sh` | 跳过 init 脚本，直接进 shell 定位用户态问题 |
| `CONFIG_DEBUG_VM`/`CONFIG_DEBUG_ATOMIC_SLEEP` | 定位 MMU/中断问题 |
| QEMU/Spike 先行 | 用 `qemu-system-riscv32 -M virt` 或 Spike + OpenSBI 验证内核配置与驱动框架，再上真实 CPU |
| 对比 LA32R 实现 | LA32R 的 `loongson32/setup.c`、`time.c`、`irq.c` 是**参考实现**，说明平台初始化需要做什么（而不是移植对象） |

## 7. 已知问题（来自详查报告，移植时必须处理）

1. `arch/loongarch/loongson32/serial.c` 是**坏的**（先填 port 再 `memset` 清零），不做参考；串口直接用 DTS + 8250_of。
2. LA32R 的 cache flush 函数因 `#ifdef BX_SOC` 拼写错误**全部为空操作**——不能据此认为平台无需 cache 维护。
3. 定时器频率在 LA32R 中硬编码 200 MHz；本项目必须由设备树 `timebase-frequency` 提供真实频率。
4. 该树 `arch/riscv` 是否与上游 5.14-rc2 完全一致无法用 git 验证（浅克隆单提交），移植前建议与上游 v5.14-rc2 做一次 `diff -r` 确认差异。
5. RV32 的 F/D 上下文切换（`arch/riscv/kernel/fpu.S`）在该版本验证不足；开启 `CONFIG_FPU` 后必须做浮点压力测试。
