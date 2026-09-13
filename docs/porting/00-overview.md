# 软件移植方案总览（U-Boot / Linux / 驱动 / 根文件系统）

> 依据：`../../../../linux-porting-report.md`（la32r-Linux 详查）、`../../../../uboot-porting-report.md`（la32r-uboot 详查）、`../../../../chiplab-integration-report.md`（平台集成详查）。知识要点沉淀在 `../kb/`。

---

## 1. 结论先行：移植工作量比预想小得多

| 关键发现 | 影响 |
|---|---|
| `la32r-Linux`（Linux 5.14.0-rc2）中 **`arch/riscv` 是基本上游代码且已支持 RV32/Sv32**（`ARCH_RV32I` → `select MMU`、`arch/riscv/configs/rv32_defconfig` 现成） | Linux 侧**不需要**做架构移植，只需新增 SoC（`SOC_CHIPLAB`）、设备树、defconfig 和平台驱动 |
| `la32r-uboot`（自称 2019.07，实为混合快照）中 **`arch/riscv` 同样完整支持 RV32**（`qemu-riscv32(_smode)_defconfig` 可作种子） | U-Boot 侧同样只新增 board/defconfig/DTS/驱动 |
| `arch/loongarch`/`arch/la32r` 与 RISC-V 的 CSR/异常/MMU 模型完全不同 | **明确不移植**这两套架构代码，只把其中的**平台驱动**当作参考实现 |
| 平台已有 RTL 级 NAND 控制器（`chiplab/IP/APB_DEV/NAND/`，基址 `0x1FE7_8000`），内核侧有参考驱动 `ls1a_nand.c`（1173 行） | NAND 驱动是**唯一必须新写**的驱动（内核 + U-Boot 两份） |
| U-Boot 当前**完全没有 NAND/MTD 支持**（`# CONFIG_NAND is not set` 等） | 需要新增驱动 + 使能 `CONFIG_NAND/CMD_NAND/CMD_MTDPARTS/ENV_IS_IN_NAND` + 改写 `bootcmd` |
| 内核 `RISCV_M_MODE` 是隐藏符号且 `default !MMU` → RV32+MMU 必须走 **S 模式 + SBI** | 软件栈采用 **OpenSBI（M 模式） + U-Boot（S 模式） + Linux（S 模式）** 的标准三段式 |

## 2. 启动链

```
 上电
  │
  ├─(1) FPGA 配置 bit 流（Vivado / SPI flash）
  │
  ├─(2) U-Boot（S 模式）  ← OpenSBI 以 FW_PAYLOAD/FW_DYNAMIC 形式先运行于 M 模式
  │        · 初始化 DDR/UART/CLINT/PLIC
  │        · 从 NAND 读取内核 Image 与 DTB 到 DDR
  │        · `booti <kernel_addr> - <dtb_addr>` 或 `bootm`
  │
  ├─(3) Linux 内核（S 模式，Sv32）
  │        · 解析内建 DTB（`CONFIG_BUILTIN_DTB`）或 U-Boot 传入的 DTB
  │        · 挂载 initramfs（第一阶段）或 UBIFS on NAND（第二阶段）
  │
  └─(4) 用户态：busybox `/sbin/init`
```

**内存布局（物理地址，DDR 128 MiB @ 0）**：

| 区域 | 地址范围 | 用途 |
|---|---|---|
| OpenSBI | `0x0000_0000`–`0x000F_FFFF` | M 模式固件（1 MiB 内） |
| U-Boot | `0x0020_0000`–`0x002F_FFFF` | S 模式 U-Boot（`CONFIG_SYS_TEXT_BASE=0x0020_0000`） |
| U-Boot 堆/栈/全局数据 | `0x0030_0000`–`0x003F_FFFF` | 由 `board_init_f_alloc_reserve` 分配 |
| 内核加载地址 | `0x0100_0000`（2 MiB 对齐） | `kernel_addr_r`；RV32 内核要求 4 MiB 对齐偏移（`head.S` 约定） |
| DTB | `0x00F0_0000` | `fdt_addr_r` |
| initramfs | `0x0200_0000` | `ramdisk_addr_r`（若与内核分离） |
| 内核运行/页表/堆 | `0x0100_0000` 起 | 视内核大小而定 |

> U-Boot 在 S 模式下运行、由 OpenSBI 提供 SBI 服务，因此 U-Boot 的 `timer`/`serial`/`ipi` 走 SBI 调用（`CONFIG_SBI`、`RISCV_SBI`），需要 OpenSBI 正常工作。

## 3. 工具链

| 用途 | 工具链 | 说明 |
|---|---|---|
| 内核（RV32，ilp32 软浮点 ABI） | `/opt/riscv/bin/riscv32-unknown-linux-gnu-gcc` | 内核强制 `-mabi=ilp32`（`arch/riscv/Makefile:23-40`），`-march=rv32imafdc_zicsr_zifencei_zicntr_zicbom` |
| U-Boot（RV32，ilp32） | 同上 | U-Boot 为 freestanding，用 glibc 工具链可编译；若遇头文件问题则改用自建 `riscv32-unknown-elf`（工作区已有 `riscv-gnu-toolchain` 源码） |
| OpenSBI（RV32） | 同上 | `PLATFORM=generic CROSS_COMPILE=riscv32-unknown-linux-gnu- FW_PAYLOAD=y` |
| 用户态 / busybox（ilp32d） | 同上 | 工具链默认 `-mabi=ilp32d`（硬浮点），与内核 ilp32 混用是 RISC-V Linux 的标准做法 |
| 裸机测试程序 | 同上（`-nostdlib -nostartfiles`） | 见 `08-verification.md` |

## 4. 交付物与仓库组织

上游源码树（`la32r-Linux`、`la32r-uboot`）体量大且已有独立 git 仓库，因此本项目**不复制整树**，而是：

```
rv32gc-cpu/sw/
├── uboot/
│   ├── patches/            # 对 la32r-uboot 的补丁序列（0001-*.patch ...）
│   ├── files/              # 新增文件全文（board/configs/include/dts/driver）
│   └── build_uboot.sh      # 复制上游树 → 打补丁 → 编译
├── linux/
│   ├── patches/            # 对 la32r-Linux 的补丁序列
│   ├── files/              # arch/riscv 新增的 SoC/DTS/defconfig/驱动
│   └── build_linux.sh
├── opensbi/
│   ├── patches/  files/  build_opensbi.sh
├── rootfs/
│   ├── busybox.config      # busybox 配置
│   ├── gen_initramfs.sh    # 生成 initramfs cpio
│   └── overlay/            # /init、/etc/inittab 等
└── tools/
    ├── mkimage_nand.sh     # 生成 NAND 烧写镜像（含 layout 描述）
    └── nand_flash.py       # 通过 U-Boot 串口把镜像写入 NAND 的辅助脚本
```

**版本固定**：所有上游提交号记录在 `sw/*/UPSTREAM.md`，构建脚本按提交号检出，保证可复现。

## 5. 工作分解（与 AGENT.md 的阶段对应）

| 阶段 | 软件工作 | 依赖 |
|---|---|---|
| 阶段三（顺序核跑 Linux） | 先用 **QEMU/Spike** 验证软件栈（DTS/驱动编译/启动脚本）；准备 OpenSBI+U-Boot+内核构建脚本 | 工具链、网络 |
| 阶段五 A | 移植 U-Boot（board/defconfig/DTS/串口/定时器/NAND 驱动），在 CPU 上启动到命令行 | CPU 上板可用 |
| 阶段五 B | 移植 Linux（SoC/DTS/defconfig/中断/定时器/NAND 驱动），从 NAND 启动内核 | U-Boot 可用 |
| 阶段五 C | initramfs + busybox；NAND 读写与环境变量保存；UBIFS 根文件系统（可选） | 内核可用 |
| 阶段五 D | 稳定性与性能测试（内核编译、md5 校验、unixbench） | 全部就绪 |

## 6. 关键风险（软件侧）

| 风险 | 说明 | 对策 |
|---|---|---|
| NAND 硬件 ECC 语义未知 | 参考驱动把 ECC 全关，页/OOB 布局只有 24 B @ spare 40..63 一种线索 | 先用软件 BCH ECC（内核已支持）；ECC 布局用实测确定 |
| NAND 数据必须走平台 DMA 引擎 | CPU 有 Cache，DMA 不具一致性 | CPU 实现 Zicbom；驱动统一用 `dma_sync_*`；U-Boot 侧实现 dcache flush/inval |
| 分区定义三处冲突（驱动 21M/35M、DTS 20M、文档 50M） | 影响启动与工具链 | 统一定义为本方案 §7 的布局，全部通过 `mtdparts`/DT 传递 |
| CONFREG 地址在仿真与 FPGA 不同 | 软硬件地址不一致 | 用设备树区分（FPGA/仿真两份 DTS），驱动不硬编码 |
| RV32 的 F/D 上下文切换在 5.14 上验证不足 | 可能导致用户态浮点崩溃 | 先以 `CONFIG_FPU=n` 跑通；再开 FPU 回归 |
| OpenSBI 需要 CLINT/PLIC 且对 PMP 有要求 | CPU 必须实现 | CPU 设计已包含（见 `04-csr-mmu.md`） |

## 7. NAND 分区与布局（本项目统一定义）

| 分区 | 偏移 | 大小 | 说明 |
|---|---|---|---|
| `env` | `0x0000_0000` | 256 KiB | U-Boot 环境变量（`CONFIG_ENV_IS_IN_NAND`，`ENV_OFFSET=0`，`ENV_SIZE=0x40000`） |
| `kernel` | `0x0004_0000` | 50 MiB | Linux 内核 Image（只读） |
| `dtb` | `0x0324_0000` | 1 MiB | 设备树 blob |
| `rootfs` | `0x0334_0000` | 余下（≈76.75 MiB） | UBIFS（第二阶段）或留空 |

对应的 `mtdparts`：`nand-flash:256K(env),50M(kernel)ro,1M(dtb),-(rootfs)`
（与 chiplab 文档的 `50M@0(kernel)ro,-(rootfs)` 相比，把 env 显式划出并增加 dtb 分区，避免与 U-Boot 环境变量冲突。）
