# 08 · 上游仓库移植知识提炼（Linux / U-Boot / OpenSBI + LA32R 参考）

> 只写本工作区那几个仓库里**实际读到**的内容，括号给仓库内相对路径（必要时给行号）；读不到就写「未确认」。
> 版本：Linux `7.3.0-rc2`（`linux/Makefile:2-6`，HEAD `2f0c1cf7`）；U-Boot `2026.10-rc4`（`u-boot/Makefile:3-6`）；
> OpenSBI `1.9`（`opensbi/include/sbi/sbi_version.h:13-14`）；参考移植 `la32r-uboot/`（U-Boot 2019.07，`configs/la32rsoc_defconfig:3`）、
> `la32r-Linux/`（Linux 5.14-rc2，`la32r-Linux/Makefile:2-5`）。

---

## 1. RV32 内核构建链

### 1.1 `arch/riscv/configs/` 里到底有什么

实测只有 7 个文件：`32-bit.config`、`64-bit.config`、`defconfig`、`hardening.config`、`nommu_k210_defconfig`、
`nommu_k210_sdcard_defconfig`、`nommu_virt_defconfig`（`linux/arch/riscv/configs/` 目录列表）——**没有 `rv32_defconfig` 文件**。
`32-bit.config` 全文 5 行，本质就是要合并的片段（`linux/arch/riscv/configs/32-bit.config:1-5`）：

```
CONFIG_ARCH_RV32I=y   CONFIG_32BIT=y   # CONFIG_PORTABLE is not set   CONFIG_NONPORTABLE=y
```

`64-bit.config` 对称地给 `CONFIG_ARCH_RV64I=y` / `CONFIG_64BIT=y`（`linux/arch/riscv/configs/64-bit.config:1-4`）。

### 1.2 RV32 的正确构建命令（主线 = defconfig + 片段合并）

- `make ARCH=riscv CROSS_COMPILE=riscv32-unknown-linux-gnu- rv32_defconfig`
  —— 目标定义在 `linux/arch/riscv/Makefile:195-197`，配方就是
  `$(MAKE) -f $(srctree)/Makefile defconfig 32-bit.config`（同文件 `:197`）。
- 等价写法（建议在脚本里写死，不依赖 arch 目标）：
  `make ARCH=riscv CROSS_COMPILE=riscv32-unknown-linux-gnu- defconfig 32-bit.config`
- 变体：`make ARCH=riscv rv32_randconfig`（`linux/arch/riscv/Makefile:185-188`，内部 `KCONFIG_ALLCONFIG=.../32-bit.config`）；
  无 MMU 版 `rv32_nommu_virt_defconfig`（`:199-201`）。
- 出镜像：`make ARCH=riscv CROSS_COMPILE=... Image`（`BOOT_TARGETS := Image Image.gz ...`，`linux/arch/riscv/Makefile:169-171`；
  `KBUILD_IMAGE := $(boot)/$(boot-image-y)`，`:147`）。
- **坑**：`opensbi/docs/platform/qemu_virt.md:132-133` 建议用 `arch/riscv/configs/rv32_defconfig`，该文件已不存在，照抄会失败。

### 1.3 ARCH / CROSS_COMPILE / 交叉编译器

- `ARCH` = `arch/` 下的目录名；`CROSS_COMPILE` = binutils 文件名前缀（可含路径）（`linux/Documentation/kbuild/kbuild.rst:186-204`）。内核这边 `ARCH=riscv`。
- RV32 必须交叉编译：位宽由 `CONFIG_ARCH_RV64I` 反推，非 64 即 `BITS := 32`，强制 `-mabi=ilp32` / `-melf32lriscv`
  （`linux/arch/riscv/Makefile:28-47`）。
- 工具链：要同一套工具链产 32/64 位 Linux 运行时库需 `--enable-multilib`（只对 newlib 与 Linux/glibc 工具链有效）
  （`riscv-gnu-toolchain/README.md:90-116`，经 kb 检索）。

### 1.4 最小可用配置要注意的选项

| 关注点 | 结论 | 依据 |
|---|---|---|
| 32 位配得出来吗 | `ARCH_RV32I` 的 `depends on NONPORTABLE` → 片段必须同时给 `CONFIG_NONPORTABLE=y` | `linux/arch/riscv/Kconfig:401-420`、`configs/32-bit.config:5` |
| 默认位宽 | 不合并片段时 `default ARCH_RV64I`，`make defconfig` 得到 RV64 | `linux/arch/riscv/Kconfig:401-406` |
| MMU / Sv32 | `config MMU` 默认 y（32 位也有 MMU）；非 64BIT 时 `PGTABLE_LEVELS default 2` | `linux/arch/riscv/Kconfig:295-300`、`:351-354` |
| 运行模式 | 有 OpenSBI 即 S 模式：`RISCV_SBI` 在 `!RISCV_M_MODE` 时 `default y`；`RISCV_M_MODE` 只在 `!MMU` 可选（无 MMU 的 M 模式内核） | `linux/arch/riscv/Kconfig:281-294` |
| 压缩指令 | `RISCV_ISA_C` 默认 y，要求核支持 C；核没有 C 必须关 | `linux/arch/riscv/Kconfig:556-566` |
| 串口 | 可跑的 config 同开 `SERIAL_8250`+`8250_CONSOLE`+`SERIAL_OF_PLATFORM`+`SERIAL_EARLYCON_RISCV_SBI` | `linux/arch/riscv/configs/defconfig:150-155` |
| earlycon | 文档化写法 `uart[8250],mmio32,<addr>[,options[,uartclk]]`；无参时按 `/chosen` 的 `stdout-path` | `linux/Documentation/admin-guide/kernel-parameters.txt:1403-1436` |
| initramfs | `CONFIG_BLK_DEV_INITRD=y` 官方 defconfig 已开；`CONFIG_INITRAMFS_SOURCE` 用法 | `configs/defconfig:23`、`linux/Documentation/filesystems/ramfs-rootfs-initramfs.rst:140` |
| 无 NAND 时的根 | 内树现成选项：NFS（`NFS_FS`/`ROOT_NFS`）、9P（`9P_FS`）、initramfs；首阶段用 initramfs 最稳 | `configs/defconfig:23,295-300` |
| MTD | defconfig 只开 `MTD`+`MTD_BLOCK`+`MTD_CFI`+`MTD_SPI_NOR`，NAND/UBIFS 不在其中 | `configs/defconfig:114-118` |

入口契约：`a0`=hartid、`a1`=DTB（`linux/Documentation/arch/riscv/boot.rst:26-27`），`satp=0`（`:34`），
**RV32 内核必须 4 MiB 对齐放置**（PMD 边界，`:45-47`）。

---

## 2. DT 绑定要求（对照 `rv32gc-cpu/sw/board/rv32gc-chiplab.dts`）

### 2.1 PLIC — `sifive,plic-1.0.0` / `riscv,plic0`

- 必需 7 项：`compatible`、`#address-cells`（**必须 = 0**）、`#interrupt-cells`、`interrupt-controller`、`reg`、
  `interrupts-extended`、`riscv,ndev`（`.../interrupt-controller/sifive,plic-1.0.0.yaml:124-131`；`#address-cells` 见 `:96-97`）。
- `#interrupt-cells`：除 `andestech,nceplic100` / `thead,c900-plic` 外**恒为 1**（`:133-150`）。
- 允许的 `compatible`：`"<vendor>,<chip>-plic", "sifive,plic-1.0.0"`（10 个 SoC，`:59-71`）；
  `"sifive,plic-1.0.0", "riscv,plic0"` 是 **deprecated，注明 "For the QEMU virt machine only"**（`:87-91`）。
- `interrupts-extended` 每 context 一项，不存在的 context 写 `-1`（`:103-109`）；`riscv,ndev` 的有效源号是 1..ndev（`:111-116`）。
- 内树范例：`linux/arch/riscv/boot/dts/sifive/fu540-c000.dtsi:181-193`。

### 2.2 CLINT — `sifive,clint0` / `riscv,clint0`

- 必需仅 3 项：`compatible`、`reg`、`interrupts-extended`（`.../timer/sifive,clint.yaml:80-83`）。
- 允许值：`"<vendor>,<chip>-clint", "sifive,clint0"`（`:30-43`）；新 IP 为 `sifive,clint2`（与 clint0 不兼容，`:44-49`）；
  `"sifive,clint0", "riscv,clint0"` 同为 deprecated 的 QEMU 专用写法（`:60-64`）。
- **节点里不写频率**：时钟频率写在 `/cpus` 的 `timebase-frequency`（`:19-21`）。

### 2.3 CPU / cpus

- `compatible` **不能只写 `"riscv"`**（原文注释 "Simulator only"，`.../riscv/cpus.yaml:78`）；合法形态是
  `<vendor>,<chip>`（或再加 `sifive,rocket0`）后跟 `"riscv"`（`:44-77`）。
- `anyOf`：`riscv,isa` 或 `riscv,isa-base` 必须有一个；`riscv,isa-base` 与 `riscv,isa-extensions` 互为依赖（`:147-156`）；
  扩展名取值表在 `.../riscv/extensions.yaml`。
- 必需 `interrupt-controller` 子节点（`:157-158`），该子节点要求 `compatible`/`#interrupt-cells(=1)`/`interrupt-controller`，
  源号 1/5/9 = S 软件/S 定时器/S 外部（`.../interrupt-controller/riscv,cpu-intc.yaml:37-63`）。
- `mmu-type` 枚举含 `riscv,sv32`（`cpus.yaml:83-95`）。
- **`timebase-frequency` 只在 `/cpus`，CPU 节点里禁止**（`cpus.yaml:126-127`，范例 `:168`）；
  `riscv,timer` 节点只要求 `compatible` + `interrupts-extended`（`.../timer/riscv,timer.yaml:22-41`）。

### 2.4 UART — `ns16550a`

- 必需只有 `reg` + `interrupts`（`.../serial/8250.yaml:317-319`）。
- `clock-frequency` / `clocks` 二选一的要求**只对非 ns8250/ns16450/ns16550/ns16550a 生效**（`:38-51`）——
  `ns16550a` 在 schema 上不强制时钟，但驱动要用它算波特率，给了最省事。
- `current-speed` `:237-239`；`reg-offset` `:241-244`；`reg-shift`（0=逐字节，1=16bit…）`:246-247`；
  `reg-io-width`（每次访问字节数，4 = 32 位访问）`:249-254`。

### 2.5 MTD / SPI-NOR / NAND

- `jedec,spi-nor` 是 **SPI 外设**模型：`compatible` 为 `"<型号>", "jedec,spi-nor"` 或单独 `jedec,spi-nor`，
  节点必须在 SPI 控制器下（文件头 `$ref: /schemas/spi/spi-peripheral-props.yaml`），`reg` 是片选/单元
  （`.../mtd/jedec,spi-nor.yaml:14,17-49,51-53`）→ 我们把 `flash@1c000000` 直接挂 `soc` 下、`reg` 写两段 MMIO 窗口，**不合模型**。
- 内存映射 flash 应写 `cfi-flash`/`jedec-flash`/`mtd-ram`/`mtd-rom`（`.../mtd/mtd-physmap.yaml:60-64`），必需
  `compatible`+`reg`（`:81-83`），要求 `#address-cells`/`#size-cells` = 1（`:70-75`）。
- 分区子节点：`compatible = "fixed-partitions"` 必须带 `#address-cells`/`#size-cells`
  （`.../mtd/partitions/fixed-partitions.yaml:38-41`）。
- NAND：内树**没有** `chiplab,nand-k9f1g08` 这类绑定，得自写 binding + 驱动；参考现成 compatible 是
  `"ls1a-nand"`（`la32r-Linux/drivers/mtd/nand/raw/ls1a_nand.c:1130-1133`）；我们的双 `reg`（基址 + 数据口 `+0x40`）
  在 `nand-controller.yaml`/`nand-chip.yaml` 里没有对应写法（未确认可否套用）。

### 2.6 会被 `dtbs_check` / 内核拒绝的常见错误

1. PLIC 少 `riscv,ndev`、少 `#address-cells`（都是 required，`sifive,plic-1.0.0.yaml:124-131`）。
2. PLIC/CLINT 少 `interrupts-extended`（`sifive,plic-1.0.0.yaml:130`、`timer/sifive,clint.yaml:83`）。
3. `sifive,plic-1.0.0` 上写 `#interrupt-cells = <2>`（const 检查失败，`:147-150`）。
4. CPU 节点只写 `compatible = "riscv"`（`riscv/cpus.yaml:78`）；`/cpus` 缺 `timebase-frequency`（`:126`）。
5. 在 `additionalProperties: false` 的节点里塞自定义属性
   （`sifive,plic-1.0.0.yaml:174`、`timer/sifive,clint.yaml:78`、`riscv,cpu-intc.yaml:65`）。
6. 内存映射 flash 用 `jedec,spi-nor`（见 2.5）。

---

## 3. U-Boot 侧

### 3.1 RV32 起点与关键选项

- `configs/qemu-riscv32_defconfig`（24 行）只给 `CONFIG_RISCV=y`、`TARGET_QEMU_VIRT=y`、
  `DEFAULT_DEVICE_TREE="qemu-virt32"`、`SYS_MALLOC_LEN`、`SYS_LOAD_ADDR=0x80200000`、FIT/DISTRO_DEFAULTS 等；
  **没有 TEXT_BASE、也没有 SDRAM 基址**（`u-boot/configs/qemu-riscv32_defconfig:1-24`）。
- 三个 RV32 起点：`qemu-riscv32_defconfig`（M 模式）、`qemu-riscv32_smode_defconfig`（+`CONFIG_RISCV_SMODE=y`，`:10`）、
  `qemu-riscv32_spl_defconfig`（`SPL=y`、`RISCV_SMODE=y`、`SPL_LOAD_FIT_ADDRESS=0x80200000`、`SPL_BSS_START_ADDR=0x84000000`，`:8-15`）。
- RV64 defconfig 显式 `CONFIG_ARCH_RV64I=y`（`configs/qemu-riscv64_defconfig:9`）；RV32 不需要——
  `choice "Base ISA"` 的 `default ARCH_RV32I`（`u-boot/arch/riscv/Kconfig:146-164`）。
- **地址宏**：文本基址是 `config TEXT_BASE`（`u-boot/Kconfig:703-726`），板级默认在 board Kconfig：
  `SPL→0x81200000`、M 模式 `0x80000000`、S 模式 RV64 `0x80200000`、S 模式 **RV32 `0x80400000`**
  （`u-boot/board/emulation/qemu-riscv/Kconfig:15-26`，同处 `SPL_OPENSBI_LOAD_ADDR` 默认 `0x80100000`）。
  DRAM 基址是 **`CFG_SYS_SDRAM_BASE`**，由 board header `#define`（`u-boot/include/configs/qemu-riscv.h:11` = `0x80000000`），
  供 `env_get_bootm_low()` 使用（`u-boot/boot/image-board.c:111-119`）。
  新版 U-Boot 已**没有** `CONFIG_SYS_TEXT_BASE`/`CONFIG_SYS_SDRAM_BASE`（参考仓库用的是 2019.07 老名，
  `la32r-uboot/configs/la32rsoc_defconfig:22`）。
- 运行模式：`RISCV_MMODE`/`RISCV_SMODE` 二选一，默认 M（`u-boot/arch/riscv/Kconfig:205-220`）；S 模式必须有 SBI
  （`u-boot/doc/board/emulation/qemu-riscv.rst:40-43`、`u-boot/doc/arch/riscv.rst:19-31`）。
  SBI 版本 `SBI_V01`/`SBI_V02`，默认 V02，帮助文本要求 OpenSBI ≥ v0.7（`u-boot/arch/riscv/Kconfig:449-476`）。
- SPL + OpenSBI：`SPL_OPENSBI` 依赖 `RISCV && SPL_RISCV_MMODE && RISCV_SMODE && SPL_LOAD_FIT`，**只支持 FW_DYNAMIC**
  （`u-boot/common/spl/Kconfig:1712-1718`）；`generic` RISC-V CPU 自动 imply（`u-boot/arch/riscv/cpu/generic/Kconfig:5-18`）；
  Falcon 模式 `SPL_LOAD_FIT_OPENSBI_OS_BOOT`（`u-boot/arch/riscv/Kconfig:622-628`，说明 `u-boot/doc/develop/falcon.rst:455-495`）。
- DT 来源：`OF_SEPARATE` / `OF_EMBED`（上游注明不推荐生产用）/ `OF_BOARD`（+`OF_HAS_PRIOR_STAGE`）（`u-boot/dts/Kconfig:152-186`）。
  qemu-riscv 走 `OF_BOARD`+`OF_HAS_PRIOR_STAGE`，所以 `u-boot/arch/riscv/dts/qemu-virt32.dts:1-11` 只是个 binman 空壳
  （打包见 `u-boot/arch/riscv/dts/Makefile:10`）——我们要有自己的 `arch/riscv/dts/<board>.dts`。
- 串口：`SYS_NS16550`（`u-boot/drivers/serial/Kconfig:814-822`）；DM 路径从 DT 读
  `reg-offset`/`reg-shift`/`reg-io-width`/`clock-frequency`，都没有才回落 `CFG_SYS_NS16550_CLK`
  （`u-boot/drivers/serial/ns16550.c:548-566`）。参考移植：`CONFIG_SYS_NS16550_COM1 0x9fe001e0` + `CLK 33000000` +
  `MEM32`（`la32r-uboot/include/configs/la32rsoc_demo.h:47-50`；`la32r-uboot/configs/la32rsoc_defconfig:795,819`）。
- M 模式定时器用 ACLINT：`RISCV_ACLINT` 依赖 `RISCV_MMODE`（`u-boot/arch/riscv/Kconfig:384-391`），
  `RISCV_MMODE_TIMERBASE 0x2000000`/`TIMEROFF 0xbff8`/`TIMER_FREQ 1000000`（`u-boot/include/configs/qemu-riscv.h:13-16`）；
  S 模式走 `RISCV_TIMER`（generic S-mode timer，`u-boot/drivers/timer/Kconfig:226-231`）。

### 3.2 RV32 上启动 Linux

- `booti` 支持 RISC-V：`depends on ARM64 || RISCV || SANDBOX` 且 `default y`（`u-boot/cmd/Kconfig:396-406`）；
  参数语义（`booti [<addr> [<initrd>[:<size>]] [<fdt>]]`，裸 initrd 必须给 size，压缩 Image 要
  `kernel_comp_addr_r`/`kernel_comp_size`）见 `u-boot/doc/usage/cmd/booti.rst`。
- QEMU 的地址约定（**全在 0x8000_0000 以上，不能照抄**）：`initrd_high=0xffffffffffffffff`、
  `kernel_addr_r=0x84000000`、`kernel_comp_addr_r=0x88000000`、`fdt_addr_r=0x8c000000`、
  `scriptaddr=0x8c100000`、`ramdisk_addr_r=0x8c300000`（`u-boot/include/configs/qemu-riscv.h:33-43`）。
- 两种链路：M 模式 U-Boot 自己加载 `fw_payload` 的 uImage 并 `bootm`（`u-boot/doc/arch/riscv.rst:33-51`）；
  S 模式 U-Boot 由 OpenSBI 拉起，之后 `booti` 启内核（`u-boot/doc/board/emulation/qemu-riscv.rst:93-100`）。

### 3.3 自建板卡官方指引

- `u-boot/doc/develop/board_best_practices.rst:1-26`：defconfig 必须 `make savedefconfig` 生成；Kconfig 片段放**板目录**，不放顶层 `configs/`。
- `u-boot/doc/develop/directories.rst`：各目录职责。`u-boot/doc/board/emulation/qemu-riscv.rst`：RV32/RV64 × M/S 完整构建与运行命令。
- `u-boot/doc/arch/riscv.rst:16-73`：两种启动流程与 a0/a1 约定。`u-boot/doc/develop/devicetree/dt_qemu.rst`：看 QEMU 生成的 DTB 作对照。

---

## 4. OpenSBI 侧

### 4.1 `PLATFORM=generic` 支持 RV32 的证据与命令

- `opensbi/platform/generic/objects.mk` 有 RV32 一等分支：`ifeq ($(PLATFORM_RISCV_XLEN), 32)` →
  `FW_JUMP_OFFSET=0x400000`、`FW_PAYLOAD_ALIGN=0x400000`（64 位是 `0x200000`），注释写 "This needs to be 4MB aligned for 32-bit system"（`:27-43`）。
- XLEN 来源：`ifndef PLATFORM_RISCV_XLEN` 时按工具链猜（`opensbi/Makefile:168-175`），也可显式给 `PLATFORM_RISCV_XLEN=32`；
  据此定 ABI=`ilp32`、ISA=`rv32imafdc`（`opensbi/Makefile:306-330`）；前缀用 `CROSS_COMPILE`（`:118-122`）。
- 官方 32 位 U-Boot payload 命令：`make PLATFORM=generic PLATFORM_RISCV_XLEN=32 CROSS_COMPILE=riscv32-... FW_PAYLOAD_PATH=<uboot>/u-boot.bin`
  （`opensbi/docs/platform/qemu_virt.md:108-122`；`PLATFORM=generic` 见 `opensbi/docs/platform/generic.md:32-33`）；
  产物 `build/platform/generic/firmware/fw_payload.bin` / `.elf`（`opensbi/docs/firmware/fw_payload.md:26-29`）。

### 4.2 三种固件形态怎么选

| 形态 | 前提 / 代价 | 关键参数 | 依据 |
|---|---|---|---|
| `FW_DYNAMIC` | 前一阶段要能**同时**加载固件与下一阶段，并在内存里放 `struct fw_dynamic_info` | 入口由运行时信息决定 | `docs/firmware/fw.md:21-29`、`fw_dynamic.md:9,36` |
| `FW_JUMP` | 下一阶段固定在某个地址，不内嵌 | `FW_JUMP_ADDR` 或 `FW_JUMP_OFFSET`（至少一个）+ `FW_JUMP_FDT_ADDR`/`_OFFSET` | `docs/firmware/fw_jump.md:32-69` |
| `FW_PAYLOAD` | 把下一阶段**连进**固件镜像，还能内嵌 FDT | `FW_PAYLOAD=y`、`FW_PAYLOAD_PATH`、`FW_PAYLOAD_OFFSET` **或** `FW_PAYLOAD_ALIGN`（必须给一个） | `docs/firmware/fw_payload.md:20-68` |

我们的取舍：SPI 小引导只能加载一段镜像，做不出 `fw_dynamic_info` → 选 **`FW_PAYLOAD` + U-Boot 作 payload**
（官方支持 U-Boot 当 payload：`opensbi/docs/firmware/payload_uboot.md:1-14`；32 位命令 `qemu_virt.md:108-122`）。

### 4.3 `FW_TEXT_START` 与 DDR 基址 `0x0`

- `FW_TEXT_START` 可选，**不给默认 `0x0`**（`opensbi/firmware/objects.mk:16-19`；文档 `docs/firmware/fw.md:64-66`），
  链接脚本 `. = FW_TEXT_START;`（`opensbi/firmware/fw_base.ldS:10-11`）。我们 DDR 从 `0x0` 起 128 MiB
  （`rv32gc-cpu/sw/board/rv32gc-chiplab.dts:57-60`），所以 `FW_TEXT_START=0x0` 天然吻合。
- payload 链接地址 = `FW_TEXT_START + FW_PAYLOAD_OFFSET/ALIGN`（`opensbi/firmware/fw_payload.elf.ldS:18`）；
  RV32 默认 `ALIGN=0x400000` → U-Boot 落在 `0x0040_0000`，与规划里的 `TEXT_BASE=0x0020_0000` 冲突（见第 6 节坑 10）。

### 4.4 SBI 需要的最小设备（对应文件）

- 定时器：`lib/utils/timer/fdt_timer_mtimer.c`，compatible `"riscv,clint0"`/`"sifive,clint0"`（`:161-162`），
  SiFive CLINT 带 `CLINT_MTIMER_OFFSET` quirk（`:143-146`）；频率必须来自 `/cpus/timebase-frequency`，否则
  `fdt_parse_timebase_frequency()` 返回 `SBI_ENOENT`（`lib/utils/fdt/fdt_helper.c:308-327`，调用点 `fdt_timer_mtimer.c:59`）。
- 外部中断：`lib/utils/irqchip/fdt_irqchip_plic.c`，compatible `"riscv,plic0"`/`"sifive,plic-1.0.0"`（`:101-110`）；
  代码里 **`reg` 硬必需**（`lib/utils/fdt/fdt_helper.c:849-861` 里 `reg` 为空即 `SBI_ENODEV`），`riscv,ndev` 可缺省；
  context 映射取自 PLIC 的 `interrupts-extended`（`fdt_irqchip_plic.c:32-60`），启动后把 M 模式外部中断项改写成
  `0xffffffff`（`lib/utils/fdt/fdt_fixup.c:215-241`）。
- 控制台：`lib/utils/serial/fdt_serial_uart8250.c` 匹配 `"ns16550"`/`"ns16550a"`/`"snps,dw-apb-uart"`（`:30-37`），
  从 DT 读 `clock-frequency`/`current-speed`/`reg-shift`/`reg-io-width`/`reg-offset`（`lib/utils/fdt/fdt_helper.c:479-556`）。
- 平台钩子：`platform/generic/platform.c:344-349`（`.irqchip_init = fdt_irqchip_init`、`.timer_init = fdt_timer_init`）。
- FDT 平台要求：`/chosen` 有 `stdout-path`（多串口时必备）、有 timer 节点、多 hart 时有 IPI 节点（`docs/platform/generic.md:19-30`）。
- 平台最低要求：≥ `rv32ima_zicsr`（或 rv64 版）、至少一个 HART 有 S 模式、**mtvec 必须支持 direct 模式**；
  PMP 可选；**TIME CSR 可选**（缺失时需 64 位 MMIO 计数器）（`opensbi/docs/platform_requirements.md:19-42`）。

---

## 5. 本平台对照（chiplab / LA32R 参考移植）

| 项 | 参考值 | 路径 |
|---|---|---|
| DRAM | 物理 `0x0` + 128 MiB（`reg = <0x0 0x08000000>`） | `la32r-Linux/arch/loongarch/boot/dts/loongson/loongson32_ls.dts:31-35`；`la32r-uboot/arch/la32r/dts/la32rsoc_demo.dts:30-34` |
| U-Boot 眼里的 SDRAM | `0xa000_0000` + `0x0800_0000`（LoongArch 缓存窗口别名；注释写 "256 Mbytes"，与 reg 不符，以 reg 为准） | `la32r-uboot/include/configs/la32rsoc_demo.h:21-24` |
| UART0 | `0x1FE0_01E0`，ns16550a，33 MHz，115200，`no-loopback-test` | `la32r-Linux/.../loongson32_ls.dts:49-56`；`la32r-uboot/include/configs/la32rsoc_demo.h:47-50`；`la32r-uboot/arch/la32r/dts/la32rsoc_demo.dts:44-52`（写非缓存别名 `0x9fe001e0`） |
| NAND | 控制器 `0x1FE7_8000`+`0x4000`，命令/中断寄存器 `0x1FD0_1160`，DMA 数据口 `0x1FE7_8040` | `la32r-Linux/.../loongson32_ls.dts:79-99`（原文被 `#if 0` 包住，见 `:70`/`:100`）；`la32r-Linux/drivers/mtd/nand/raw/ls1a_nand.c:18-19` |
| GMAC | `0x1FF0_0000`，`dmfe` | `la32r-Linux/.../loongson32_ls.dts:58-69` |
| 定时器频率 | 33 MHz（`CONFIG_SYS_LOONGARCH_TIMER_FREQ 33`） | `la32r-uboot/include/configs/la32rsoc_demo.h:11` |
| 环境变量 | `CONFIG_ENV_IS_NOWHERE` + `ENV_SIZE 0x4000`（**参考没有持久化 env 偏移**） | `la32rsoc_demo.h:57,60`；`la32r-uboot/configs/la32rsoc_defconfig:448` |
| mtdparts | `CMD_MTDPARTS` 关闭、`MTDIDS_DEFAULT`/`MTDPARTS_DEFAULT` 为空串（要自己补） | `la32r-uboot/configs/la32rsoc_defconfig:402-404` |
| 内核分区解析 | 开了 `MTD_CMDLINE_PARTS` + `MTD_OF_PARTS` | `la32r-Linux/arch/loongarch/configs/la32_defconfig:833-834` |
| 内核构建 | `ARCH=loongarch`、`CROSS_COMPILE=loongarch32-linux-gnu-`、`make la32_defconfig`、产物 `vmlinux`(ELF) | `la32r-Linux/la_build.sh:3-4,9,15` |
| 引导内核 | `bootelf` + 重定位表 `LA32R_RELOCATION_TABLE_SIZE=0x4000`；`$a0=-2`/`$a1=FDT` | `la32r-uboot/BUILD_NOTE.md`（bootelf 段）；`configs/la32rsoc_defconfig:44-45,220`；`la32r-uboot/arch/la32r/Kconfig:37-43` |

**可直接沿用**：物理内存映射（DDR@0、UART `0x1fe001e0`、NAND `0x1fe78000`、GMAC `0x1ff00000`）、16550 寄存器语义与
33 MHz/115200 时钟、NAND 控制器寄存器语义（`ls1a_nand.c` 的 `DMA_ACCESS_ADDR 0x1fe78040`/`ORDER_REG_ADDR 0x9fd01160`
与我们的数据口 `+0x40`、`0x1fd01160` 对得上）、分区划分思路。

**必须改**：
1. `0xa000_0000` / `0x9fe0_01e0` 是 LoongArch 缓存/非缓存窗口别名，RISC-V 没有这套窗口 → 一律写物理地址
   （`0x0`、`0x1fe001e0`）；`CFG_SYS_SDRAM_BASE` 不能抄成 `0xa0000000`。
2. 中断模型：LA 用 CPU 局部中断控制器 + EXTIOI（`0x1FE11600`）级联（`loongson32_ls.dts:19-41`）→ RISC-V 换成
   `riscv,cpu-intc` + PLIC（核内 `0x1F10_0000`）+ CLINT（`0x1F00_0000`）。
3. 引导协议：LA 是 `bootelf`+重定位表；RISC-V 是 `booti`/`bootm`，`a0`=hartid、`a1`=DTB（`linux/.../arch/riscv/boot.rst:26-27`）。
4. U-Boot 代际差异：`CONFIG_SYS_TEXT_BASE`→`CONFIG_TEXT_BASE`、`CONFIG_SYS_SDRAM_BASE`→`CFG_SYS_SDRAM_BASE`。
5. UART 访问宽度：参考 DTS **不给** `reg-io-width`（默认 1 字节步进/8 位访问；U-Boot 侧另用 `CONFIG_SYS_NS16550_MEM32`），
   我们 DTS 写的是 `reg-io-width = <4>`（`rv32gc-cpu/sw/board/rv32gc-chiplab.dts:114-123`）——必须与 RTL 的 UART 窗口位宽一致，否则早期控制台乱码。
6. 我们的 PLIC 3 MiB（`.../rv32gc-chiplab.dts:79`）覆盖标准布局（context 区从 `0x20_0000` 量级起）应当够用，
   但 SiFive PLIC 的寄存器偏移本仓库查不到（binding 只引用外部手册，`sifive,plic-1.0.0.yaml:38-41`）→ 未确认。

---

## 6. 坑与检查清单

1. `make ARCH=riscv defconfig` 得到的是 **RV64**（`ARCH_RV64I` 是默认，`linux/arch/riscv/Kconfig:401-406`）；RV32 必须合并 `32-bit.config`（`Makefile:195-197`）。
2. 不要引用 `arch/riscv/configs/rv32_defconfig`（文件不存在，只有同名 make 目标）；`opensbi/docs/platform/qemu_virt.md:132-133` 这句已过时。
3. `/cpus/timebase-frequency` 必须存在（`riscv/cpus.yaml:126-127`、`timer/sifive,clint.yaml:19-21`），OpenSBI 缺它即 `SBI_ENOENT`（`fdt_helper.c:308-327` + `fdt_timer_mtimer.c:59`）。
4. PLIC 的 `riscv,ndev`、`#address-cells=<0>`、`interrupts-extended` 缺一即 schema 失败（`sifive,plic-1.0.0.yaml:124-131`）；`#interrupt-cells` 必须 1（`:147-150`）。
5. `"sifive,clint0","riscv,clint0"` 与 `"sifive,plic-1.0.0","riscv,plic0"` 都是 QEMU 专用 deprecated 组合（`timer/sifive,clint.yaml:60-64`、`sifive,plic-1.0.0.yaml:87-91`）→ 建议加自家 vendor 前缀。
6. CPU 节点不能只写 `compatible = "riscv"`（`riscv/cpus.yaml:78`）；每个 cpu 必须有 `interrupt-controller` 子节点（`:157-158`），其 `#interrupt-cells` 恒为 1（`riscv,cpu-intc.yaml:47-63`）。
7. RV32 内核要 **4 MiB 对齐**（`boot.rst:45-47`）→ `kernel_addr_r` 不能照抄 QEMU 的 `0x84000000`（`u-boot/include/configs/qemu-riscv.h:36`），且必须落进我们 128 MiB DDR。
8. U-Boot 地址宏改名：`CONFIG_TEXT_BASE`（`u-boot/Kconfig:703-726`）、`CFG_SYS_SDRAM_BASE`（`include/configs/qemu-riscv.h:11`）。
9. S 模式 U-Boot 必须有 SBI：`SBI_V02` 默认且要求 OpenSBI ≥ v0.7（`u-boot/arch/riscv/Kconfig:449-476`）；SPL 路径只支持 `fw_dynamic`（`common/spl/Kconfig:1712-1718`）。
10. OpenSBI payload 对齐 vs U-Boot TEXT_BASE：RV32 `FW_PAYLOAD_ALIGN=0x400000`（`platform/generic/objects.mk:36-42`），DDR 从 0 起 → payload 落 `0x0040_0000`；要保住 `TEXT_BASE=0x0020_0000` 就得显式 `FW_TEXT_START=0x0 FW_PAYLOAD_OFFSET=0x200000`（`docs/firmware/fw_payload.md:39-51`、`firmware/objects.mk:16-19`）。
11. earlycon 文档写法是 `uart[8250],mmio32,<addr>`（`kernel-parameters.txt:1403-1436`）；我们的 `ns16550a,mmio32,...` 是否被接受 → 未确认，建议先用文档形式。
12. 内存映射 flash 别用 `jedec,spi-nor`（SPI 外设模型，`jedec,spi-nor.yaml:14-53`）→ 用 `cfi-flash`（`mtd-physmap.yaml:60-64,81-83`）+ `fixed-partitions`（`fixed-partitions.yaml:38-41`）；`chiplab,nand-k9f1g08` 内树无绑定，须自写（可参考 `ls1a-nand`）。

---

## 7. 未确认项

1. `earlycon=ns16550a,mmio32,...` 是否被 7.3-rc2 的 8250 earlycon 表接受（只能确认文档写 `uart[8250],mmio32`）。
2. U-Boot / OpenSBI 的精确 git 版本（U-Boot 只到 `2026.10-rc4`；OpenSBI 仓库无 tag，只有 `sbi_version.h` 的 1.9）。
3. SiFive PLIC 寄存器偏移与「3 MiB 够不够」（binding 只引用外部手册，仓库内无布局表）。
4. 我们的 `timebase-frequency = <50000000>`（`.../rv32gc-chiplab.dts:37`）只能由 RTL 证明；上游没有对应事实（LA 参考是 33 MHz，`la32rsoc_demo.h:11`）。
5. 我们的 NAND 控制器寄存器是否与 `ls1a_nand.c` 逐位一致（只核对了 compatible、`0x1fe78040`、`0x1fd01160` 别名关系）。
6. 内树**没有 RV32 DTS 范例**（`grep -r "rv32i" linux/arch/riscv/boot/dts/` 无命中）→ RV32 DTS 只能逐条对着 bindings 的 required 核。
7. PLIC 的 `interrupts-extended` 里是否**必须**保留 M 模式上下文项（OpenSBI 只做「改写为 0xffffffff」，未见强制要求；`fdt_fixup.c:215-241`）。
