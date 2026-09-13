# RV32-GC 上板测试计划（B1~B3）—— **v1.0（待用户审阅）**

> 状态：**v1.0 定稿待审**（④ Cache 已完成，L1I+L1D 实测见 §11）。本文件是 AGENT.md §7 的 ⑥「上板测试计划（2A-7d）」交付物；
> **用户审阅通过前不做任何上板动作**。
> 已核实的事实来源：`chiplab/fpga/loongson/soc_up.xdc`（引脚/时钟）、
> `chiplab/chip/soc_demo/loongson/soc_top.v`（时钟 50/33 MHz、CPU 例化点）、
> `chiplab/docs/Quick-Start.md`、`chiplab/docs/FPGA_run_linux/{flash,linux_run}.md`、
> 本仓库 `sw/board/*` 与 `rtl/pkg/rv32gc_defs.vh`。

---

## 0. 范围与目标

| 阶段 | 目标 | 通过判据（硬） |
|---|---|---|
| **B1** 最小可跑 | bitstream 下载后，核按 `RESET_PC=0x1C00_0000` 从 SPI-XIP 取指，跑通"打印 + 数码管/LED 心跳"的最小镜像 | 串口（UART0，115200）连续打印心跳与版本串；数码管/LED 有周期变化；复位可重复触发；**连续跑 30 分钟不复位、不挂死** |
| **B2** 启动链 | SPI 小引导 → DDR 主镜像（0x0）→ U-Boot 提示符 | 串口依次出现：SPI 桩横幅 → DDR 镜像横幅 → U-Boot 版本与 `=> ` 提示符；可执行 `md`/`mw`/`mtd list` 等基本命令；从 NAND 读内核镜像到 DDR 成功（`mtd` 校验和一致） |
| **B3** 启动 Linux | U-Boot 引导 Linux（NAND 根文件系统或 initramfs）到用户态 | 串口出现内核启动日志（DRAM/CLINT/PLIC/mtd 信息与 DTS 一致）→ 挂载 rootfs → 出现 login/`#`；**连续重启 5 次可复现** |

**明确不做**（本轮范围外）：千兆网/PCIe/USB 外设驱动验证；DDR3 之外的内存扩展；SMP；H 扩展；硬件性能调优（Cache 完成后的压力测试另开）。

---

## 1. 硬件与工具链

| 项 | 事实（已核实） |
|---|---|
| FPGA | Xilinx `xc7a200tfbg676-2`（Artix-7 200T） |
| 板级时钟 | `clk` = **100 MHz**（`soc_up.xdc`：`create_clock -period 10.000`，引脚 **AC19**） |
| 复位 | `resetn` 引脚 **Y3** |
| 片上时钟 | `clk_pll_33`（MMCM）：`clk_out1 = cpu_clk = 50 MHz`、`clk_out2 = uncore_clk = 33 MHz`（`soc_top.v:1463`） |
| 内存 | DDR3 K4B1G1646G-BCK0，**128 MiB**，AXI 默认从设备在 `0x0` |
| 配置存储 | SPI NOR `S25FL128SAGMFI001`（16 MiB，XIP 窗口 1 MiB @`0x1C00_0000`）；NAND `K9F1G08U0C`（128 MiB） |
| 观测 | UART0 @`0x1FE0_01E0`（115200 8N1，uncore 33 MHz）；数码管/键盘/开关走 CONFREG；LED ×16 |
| 工具 | Vivado **2025.2**（`/home/shorthair/fpga/2025.2/Vivado`，自带 `dtc 1.6.1`）；`riscv32-unknown-linux-gnu-gcc`（`/opt/riscv/bin`）；Vivado 工程基线 `chiplab/fpga/loongson/2023.2/system_run.xpr` |
| 烧写 | 串口 xmodem：先下 `programmer_by_uart.bit`（工具链提供的烧写 bit），再用 ECOM/SecureCRT 以 **230400** 传 `.bin`（见 `docs/FPGA_run_linux/flash.md`） |
| bitstream 下载 | Vivado Hardware Manager（下载线） |

---

## 2. 集成步骤（把 `rtl/top/core_top.v` 接进 chiplab SoC）

`core_top` 的端口**就是** chiplab SoC 需要的形状（`aclk/aresetn/intrpt[7:0]` + AXI4 全通道），移植步骤：

1. **时钟/复位**：`aclk ← cpu_clk`、`aresetn ← resetn`。50 MHz 相比仿真已留有余量：
   当前 iverilog 门级估算的等价路径不是时序依据，**B1 必须先在 Vivado 里看 WNS**（见 §6 风险 R1）。
2. **AXI**：`core_top` 的 AR/R/AW/W/B 直接接 `soc_top.v` 里原 LA32R 核的位置（同名字段：
   `arid/araddr/arlen/arsize/arburst/arlock/arcache/arprot/arvalid/arready` + R/AW/W/B 对称）。
   `arid/awid` 固定为 4'b0（单主设备，无需 ID 扩展）。
3. **中断**：`intrpt[7:0]` 接平台的 `{3'b0, dma_int, nand_int, spi_inta_o, uart0_int, mac_int}`
   ⇒ 核内 PLIC 的源号映射固定为 **1=UART0、2=SPI、3=NAND、4=MAC、5=DMA**（与 `sw/board/rv32gc-chiplab.dts` 一致）。
4. **地址映射**：不改互连（决策 D15）。核内 CLINT `0x1F00_0000` / PLIC `0x1F10_0000`（决策 D5），
   DDR `0x0`+128 MiB，SPI-XIP `0x1C00_0000`（含别名 `0x1FE8_0000`）。
5. **复位向量**：`RESET_PC = 32'h1C00_0000`（决策 D16；**无片上 boot ROM**）。
   ⚠ 编译期宏必须写成 Verilog 字面量 `32'h1C000000`（写成 `0x1C000000` 会让 iverilog 报无关语法错误；
   本轮已在仿真里踩过）。
6. **软件频率一致性**：`chip/soc_demo/loongson/config.h` 的 `FREQ` 宏必须与实际 `cpu_clk` 一致
   （改 `clk_pll_33` 输出后同步改），否则 U-Boot/Linux 的 `timebase-frequency` 与实际不符。
7. **DTS**：使用 `sw/board/rv32gc-chiplab.dts`（`bash scripts/check_dts.sh` 已与 RTL 常量交叉校验 17/17），
   编译出的 dtb 放 NAND `dtb` 分区（`0x0324_0000`，1 MiB）。
8. **镜像**：`bash scripts/pack_boot_image.sh` 产出
   `spi_flash.img`（1 MiB，未用区 0xFF）+ `ddr_main.bin`；
   真机的 DDR 主镜像 = OpenSBI + U-Boot（本仓库提供入口桩 `sw/board/ddr_main.S` 与链接脚本，
   把 OpenSBI/U-Boot 目标文件追加到 `ddr_main.ld` 即可）。

---

## 3. 分阶段上板步骤与判据

### B1：最小可跑（0.5~1 天）

| 步 | 操作 | 观测 | 通过判据 | 失败首选排查 |
|---|---|---|---|---|
| B1-1 | Vivado 打开 `fpga/loongson/2023.2/system_run.xpr`，加入本核 RTL + `core_top` 包装，综合/实现/生成 bitstream | `report_timing_summary` | **WNS ≥ 0**（含 MMCM 输出时钟约束） | R1 时序；先降 `cpu_clk` 到 33 MHz 复测 |
| B1-2 | 下载 bitstream；串口 115200 打开 | — | — | 无输出 → 检查 UART 引脚/波特率/地线 |
| B1-3 | 用**最小镜像**（仅 SPI 桩 + 心跳循环）烧到 SPI flash | 串口 | 复位后出现 SPI 桩横幅；心跳串持续 | XIP 取指不对 → 查 `RESET_PC`、`araddr[31:20]==0x1C0` 的互连通路、SPI 控制器初始化 |
| B1-4 | 数码管/LED 观测 | CONFREG 写入 | 数码管按预期计数（证明核在跑且访存通路 OK） | CONFREG 地址/字节序 |
| B1-5 | 长稳测试 | 串口 | 30 分钟不复位/不挂死 | R6 |

### B2：启动链（1~2 天）

| 步 | 操作 | 通过判据 |
|---|---|---|
| B2-1 | 烧 `spi_flash.img`（≤1 MiB）+ DDR 主镜像（含 U-Boot）经 JTAG/串口放入 DDR（**NAND 路径可选**） | 串口出现 SPI 桩横幅 **→** DDR 镜像横幅（顺序与 `BOOT_CHAIN` 仿真一致） |
| B2-2 | U-Boot 起来后设 `mtdparts`（`nand-flash:256K(env),50M(kernel)ro,1M(dtb),-(rootfs)`）、`loadaddr`、`fdt_addr` | `=> ` 提示符；`mtd list` 分区表与 DTS 一致 |
| B2-3 | `mtd read kernel ${loadaddr}` + `md` 校验 | 读回数据与原镜像一致（先跑 CRC） |
| B2-4 | 串口命令行基本操作（`mw`/`md`/`sf`/`nand`） | 全部命令可用；无 data abort |

### B3：启动 Linux（2~5 天）

| 步 | 操作 | 通过判据 |
|---|---|---|
| B3-1 | U-Boot 引导内核（NAND 或 TFTP）+ dtb | 内核打印 `Memory: 128MB`、`riscv_timer`、`sifive-plic`、`mtd` 分区信息，与 DTS 完全一致 |
| B3-2 | 挂载 rootfs（initramfs 优先；NAND/UBIFS 为**可选**，本阶段不验） | 出现 `login`/`#` |
| B3-3 | 稳定性 | 连续重启 5 次全通过；`dmesg` 无 illegal instruction/page fault |

---

## 4. 观测手段约定

| 手段 | 用法 |
|---|---|
| **UART0** | 115200 8N1；`earlycon=ns16550a,mmio32,0x1fe001e0`。**B1 起就用它作为唯一可信的"活着"指示** |
| **数码管** | 通过 CONFREG 写：B1 阶段写心跳计数，便于无串口时判断核在跑 |
| **LED ×16** | 可映射当前特权级/中断/PC 高位，用于死机现场保留（**上板后可加，不进 bitstream 基线**） |
| **ILA/VIO（可选）** | B1 若串口无输出，对 `core_top` 的 AXI AR/R 与 `debug_pc` 打 ILA；VIO 改 `RESET_PC` 做二分 |
| **串口烧写** | 230400 + xmodem（`programmer_by_uart.bit`） |

---

## 5. 与仿真侧的对应关系（为什么可以先仿真再上板）

| 仿真证据（已完成） | 对应上板阶段 |
|---|---|
| `SPI_BOOT: PASS`（`run_spi_boot_test.sh`） | B1-3 的复位向量/跨窗口跳转 |
| `BOOT_CHAIN: PASS`（`run_boot_chain_test.sh`，用**要烧写的真产物**） | B2-1 的 SPI→DDR 顺序 |
| `CHECK_DTS: PASS (17/17)`（DTS ↔ RTL 常量交叉校验） | B3-1 的 DTS/内核打印一致性 |
| arch-test 验收（非特权 18 组 124 例 + priv 47/64） | B3-3 的"无 illegal instruction" |
| `SIM: PASS hello/memtest`、`LRSC_DIRECTED` | B1/B2 的基本访存与原子语义 |

---

## 6. 风险与回退

| # | 风险 | 影响 | 缓解/回退 |
|---|---|---|---|
| **R1** | **时序**：50 MHz 下 WNS<0（当前实现未做时序优化，PMP 匹配树、MDU、AXI 仲裁都是长组合路径） | bitstream 不可用或间歇错 | 先降 `cpu_clk` 到 33/25 MHz 复测（`clk_pll_33` 输出 + `config.h` 的 `FREQ` 同步改）；仍不收敛则对 PMP/ALU 加流水寄存器（需改 RTL，回到仿真验证） |
| **R2** | DDR3 校准/MIG 配置不匹配（MIG IP 由参考工程提供） | B2 起不来 | 先用参考 LA32R 工程验证板子/DDR 完好，再换核复测；不改 MIG 配置 |
| **R3** | SPI-XIP 读通路（`araddr[31:20]==0x1C0` → SPI）在 100 MHz/33 MHz 下时序或初始化问题 | B1 无输出 | 用 ILA 抓 AR 通道；必要时把 B1 的复位向量临时改到 DDR（仅调试用，镜像预先由 JTAG 下载） |
| **R4** | **无 Cache 的性能**：当前核无 L1I/L1D/L2（④ 未完成），取指/访存全走 AXI，Linux 启动会很慢甚至超时 | B3 难度大增 | 见 §8 决策点 D-2：要么先完成 ④，要么 B3 只做"到 initramfs/#"，把 Cache 留到 2B |
| **R5** | NAND 控制器（APB 设备）由参考 RTL 提供，与核内中断源号约定不符 | B2-2 无中断/无 NAND | 源号映射写死为 1=UART/2=SPI/3=NAND/4=MAC/5=DMA；如参考设备不同则改 DTS 与核内 PLIC 的 `NSRC` 映射 |
| **R6** | 长稳挂死（无 Cache 时的边缘时序/中断竞态） | B1-5 失败 | 保留串口日志；用 VIO 读核内 `dbg_*`（PC/priv）定位；必要时降低时钟 |
| **R7** | 烧写误写 SPI 引导区导致"变砖" | 需重新烧 flash | 保留一份已知可用的 `spi_flash.img` 与 `programmer_by_uart.bit`；先备份 flash 内容 |
| **R8** | 用户/实验室环境限制（无 USB-Blaster、无串口线） | 无法推进 | 提前确认线材与上板窗口（见 §8 D-3） |

---

## 7. 时间与资源预算（估算）

| 阶段 | 人日 | 依赖 |
|---|---|---|
| 综合/实现/时序收敛（含 1~2 次 RTL 调整） | 1~2 | R1 |
| B1 最小可跑 | 0.5~1 | bitstream |
| B2 启动链 | 1~2 | U-Boot 移植（LA32R 参考 uboot 需换 RISC-V 工具链/移植，工作量另计） |
| B3 Linux | 2~5 | ④ Cache（见 D-2）、内核 dts/驱动（NAND/UART/PLIC/CLINT 都已通用） |
| 风险缓冲 | 2 | — |

---

## 8. 用户已拍板的决策（2026-09-13，本计划按此执行）

1. **D-1 时钟：定为 33 MHz**（不用 50 MHz）。⇒ **cpu_clk 取 `clk_pll_33` 的 `clk_out2`（33 MHz）**，
   原 `clk_out1`（50 MHz）不再给核；`chip/soc_demo/loongson/config.h` 的 `FREQ` 同步改 33，
   DTS 的 `/cpus/timebase-frequency` 与 CPU `clock-frequency` 均为 `33000000`（已落实，`check_dts.sh` 已断言）。
   综合/实现的时序目标 = 33 MHz（周期 30.303 ns），WNS ≥ 0。
2. **D-2 顺序：先把 ④ 的 Cache 做出来，再上板测试**。⇒ 上板动作推迟到 L1I/L1D 完成并回归全绿之后；
   Cache 的最小可用规格（L1I 16 KB/4 路 + L1D 写直达不写分配 + XIP 绕 Cache + `fence.i`）见 `AGENT.md` §7。
3. **D-3 线材/环境**：已具备（按 chiplab 上板教程准备）⇒ 无需额外采购；B1 可直接用串口 + 下载线开工。
4. **D-4 镜像来源**：用**上游 RISC-V 主线 U-Boot/Linux**（仓库由用户自行拉取；本计划 §10 给出链接与配置起点）。
5. **D-5 验收口径（本阶段）**：**主线是"CPU 能正常执行指令"**——B1/B2 的通过判据以"取指/执行/访存/中断
   在 33 MHz 实板上稳定正确"为准；**NAND 与 rootfs 暂不验证**（§0 的 B3 中 NAND 相关条目降级为可选）。

---

## 9. 附：本次上板要带回的证据清单

1. Vivado `report_timing_summary`（WNS/TNS/WHS）+ 资源占用（LUT/FF/BRAM/DSP）；
2. B1：串口日志（含心跳时间戳）+ 数码管照片；
3. B2：串口完整日志（SPI 桩 → DDR → U-Boot `=>`）+ `mtd list` 输出 + `md` 校验片段；
4. B3：内核启动日志（含 `Memory:`/`riscv_timer`/`sifive-plic`/`mtd` 行）+ `#` 提示符；
5. 每次失败现场（串口最后 50 行 + VIO 抓的 PC/priv）。


---

## 10. 上游仓库清单（D-4：由用户拉取后建立知识库）

| 仓库 | 链接 | 建议克隆 | 用途/配置起点 |
|---|---|---|---|
| Linux 主线 | `https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git`（镜像 `https://github.com/torvalds/linux`） | `git clone --depth=1 https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git linux` | RV32 内核；`arch/riscv/configs/` 下若有 `rv32_defconfig` 直接用，否则 `defconfig` + `CONFIG_32BIT=y`；DTS 用本仓库 `sw/board/rv32gc-chiplab.dts` |
| U-Boot | `https://source.denx.de/u-boot/u-boot.git`（镜像 `https://github.com/u-boot/u-boot`） | `git clone --depth=1 https://source.denx.de/u-boot/u-boot.git u-boot` | 引导器；起点 `qemu-riscv32_defconfig`（RV32），按本平台改 DRAM/串口/CLINT/PLIC 地址 |
| OpenSBI（RV32 Linux 必需 SBI） | `https://github.com/riscv-software-src/opensbi` | `git clone --depth=1 https://github.com/riscv-software-src/opensbi.git opensbi` | `PLATFORM=generic`（支持 RV32）+ `FW_PAYLOAD`（带 U-Boot）或 `FW_DYNAMIC` |
| （可选）Buildroot 造 rootfs | `https://gitlab.com/buildroot.org/buildroot.git` | 同上 | initramfs 优先；NAND/UBIFS 本阶段不验 |

### 10.1 DDR 布局与链接地址（依据 08 知识文档 §3/§4 的实测事实）

| 镜像 | 链接/加载地址 | 依据 |
|---|---|---|
| OpenSBI（M 模式固件） | `0x0000_0000`（`FW_TEXT_START=0`，RV32 generic 默认 0） | `opensbi/firmware/objects.mk:16-19` |
| U-Boot（S 模式 payload） | **`0x0040_0000`**（`CONFIG_TEXT_BASE=0x00400000`） | OpenSBI RV32 默认 `FW_PAYLOAD_ALIGN=0x400000`；也可改成 `FW_PAYLOAD_OFFSET=0x200000` + `TEXT_BASE=0x00200000`，**二者必须一致** |
| Linux 内核 | 由 U-Boot `loadaddr` 决定（建议 `0x0200_0000` 起，避免与 OpenSBI/U-Boot 重叠） | — |
| DTB | NAND `dtb` 分区（可选）或 U-Boot 内嵌；地址由 U-Boot `fdt_addr` 决定 | — |
| SPI 小引导 | `0x1C00_0000`（XIP，≤1 MiB） | D16②；`scripts/pack_boot_image.sh` 已硬校验 |

命令口径（供实现时照抄，来自 08 知识文档）：
```
# U-Boot（RV32 + S 模式，需要 SBI）
make CROSS_COMPILE=riscv32-unknown-linux-gnu- qemu-riscv32smodedefconfig   # 或 qemu-riscv32_defconfig（M 模式）
# OpenSBI（RV32，generic 平台），把 U-Boot 当 payload
make PLATFORM=generic PLATFORM_RISCV_XLEN=32 CROSS_COMPILE=riscv32-unknown-linux-gnu- \
     FW_PAYLOAD_PATH=<u-boot>/u-boot.bin
# Linux（主线没有 rv32_defconfig 文件；同名 make 目标 ≡ defconfig + 32-bit.config 片段）
make ARCH=riscv CROSS_COMPILE=riscv32-unknown-linux-gnu- rv32_defconfig
make ARCH=riscv CROSS_COMPILE=riscv32-unknown-linux-gnu- -j$(nproc)
```
串口口径：DTS 按参考 `loongson32_ls.dts` 的字节步进写法（`reg = <0x1fe001e0 0x10>`，**不写** `reg-io-width`），
故内核命令行用 **`earlycon=uart8250,mmio,0x1fe001e0`**（不是 `mmio32`）。

**知识库接入方式**（用户拉取后告诉我即可，我来做）：
把三个仓库放在 `/home/shorthair/dsh/rv32-cpu/` 下（与 `rv32gc-cpu/`、`riscv-arch-test/` 同级），
我在 `/home/shorthair/dsh/rv32-cpu/.dsh-kb/sources.json` 里加三条源，**root 精确到文档/配置子目录**
（避免把整个源码树塞进索引，例如 `linux/Documentation`、`linux/arch/riscv`、`linux/arch/riscv/configs`、
`u-boot/doc`、`u-boot/arch/riscv`、`u-boot/configs`、`opensbi/docs`），再 `kb_manage action=reindex`。


---

## 11. 定稿时的实测状态与复现入口（**审阅用**）

### 11.1 一条命令复现全部验证
```bash
cd rv32gc-cpu && bash scripts/run_full_regression.sh     # 汇总写 sim/log/full_regression_summary.txt
```
**最近一次实测（主 Agent 亲跑，第 21 轮）**：
```
FULL_REGRESSION: PASS （PASS 计数=281  FAIL 计数=7）
偏离基线清单：空（与基线逐项一致）
```
7 个 FAIL **全部是已知基线例外**：`PMPZca` 3 例（ISA 不可达：本核无 Zcb/F/D）、
`PMPSm_cfg_A_tor_zero-00`（平台 PA-0 口径，与参考对物理地址 0 的假设不同）、
`Sv` 3 例（**参考模型 Spike 自身 FAIL**，312 个参考日志里只有这 3 个）。

| 类别 | 实测 |
|---|---|
| 非特权 arch-test | **18 组 124 例 0 失败**（I39/M8/Zicsr6/Zifencei1/Zca26/Zaamo9/Zalrsc2/Misalign5/MisalignZca4/Zicntr2/Zicbom3/Zicboz1/Zicbop3/Zihintpause1/Zihintntl4/ZihintntlZca4/Zmmul4/Zicond2） |
| PMP 私权 | PMPS 11/11、PMPU 11/11、PMPZaamo 1/1、PMPZalrsc 1/1、PMPZca 12/15、PMPSm 37/38 |
| MMU 验收（RV32 子集） | Svbare 3/3、**Sv 28/31**、Svade 2/2、SvPMP 4/4、ExceptionsSv 4/4、Zaamo 3/3、Zalrsc 3/3、SvZicbo 6/6、SvPMPZicbo 8/8、PMPZicbo 4/4 |
| 单元 | PMP 443、CLINT_PLIC 184、TLB_PTW 155、**ICACHE 36**、**DCACHE 59 + DWRITE_THRU 14**、AXI 79、EXEC 2461、DECODER 255 |
| 定向 | PRIV_TRAP 46、FETCH_ERR 21、LRSC、FENCEI_SMC 9、**DCACHE_DIRECTED 28**、SPI_BOOT(+XIP_NOALLOC 142)、BOOT_CHAIN(+XIP_NOALLOC 5059) |
| DTS/打包 | CHECK_DTS 17/17、PACK_BOOT PASS |
| **性能** | `hello` **308 拍**；`memtest` **1,021,800 拍**（相对无 Cache 的 2,026,669 拍 **−49.6%**；L1I 先降 45%、L1D 再降 8.5%） |

### 11.2 上板前仍需在 Vivado 里确认的（软件仿真覆盖不到）
1. **时序收敛**：目标 33 MHz（周期 30.303 ns），WNS ≥ 0；重点路径 = PMP 组合匹配树、MDU、AXI 仲裁、
   **L1I/L1D 的 4 路/8 路标记比较与阵列读**（L1D 32 KB 需按 BRAM 推断复核）。
2. **BRAM 推断**：L1I `4 路×128 组×32 B`、L1D `8 路×128 组×32 B` 的数据阵列能否正确推断成
   Block RAM（若被推断成分布式 RAM，LUT 会爆）。必要时把阵列改成 `(* ram_style = "block" *)`。
3. **复位/跨时钟**：`clk_pll_33` 的 `locked` 是否参与复位门控；100 MHz 板级时钟到 50/33 MHz 的 MMCM 配置沿用参考工程。
4. **平台端口**：`core_top` 的 AXI 端口与 `chip/soc_demo/loongson/soc_top.v` 的 CPU 例化位置逐字段核对
   （本核新增了 L1D 的 d 通道行填充客户端，但**对外端口形状未变**，`core_top.v` 已透传）。

### 11.3 本阶段明确不做（避免误解）
L2 Cache（规格 256 KB/8 路）、预取、多 MSHR、伪 LRU、Store Buffer、核心级乱序/超标量；
NAND 与 rootfs 验证（用户拍板本阶段不验，B3 的 NAND 相关条目为可选）；
千兆网/USB/PCIe 驱动；SMP；H 扩展。
