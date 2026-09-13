# RV32-GC 上板测试计划（B1~B3）—— 草案 v0.9（待用户审阅）

> 状态：**草案**。本文件是 AGENT.md §7 的 ⑥「上板测试计划（2A-7d）」交付物；
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
| B2-1 | 烧 `spi_flash.img`（≤1 MiB）+ 把 DDR 主镜像（含 U-Boot）放到 NAND `kernel` 分区（0x0004_0000） | 串口出现 SPI 桩横幅 **→** DDR 镜像横幅（顺序与 `BOOT_CHAIN` 仿真一致） |
| B2-2 | U-Boot 起来后设 `mtdparts`（`nand-flash:256K(env),50M(kernel)ro,1M(dtb),-(rootfs)`）、`loadaddr`、`fdt_addr` | `=> ` 提示符；`mtd list` 分区表与 DTS 一致 |
| B2-3 | `mtd read kernel ${loadaddr}` + `md` 校验 | 读回数据与原镜像一致（先跑 CRC） |
| B2-4 | 串口命令行基本操作（`mw`/`md`/`sf`/`nand`） | 全部命令可用；无 data abort |

### B3：启动 Linux（2~5 天）

| 步 | 操作 | 通过判据 |
|---|---|---|
| B3-1 | U-Boot 引导内核（NAND 或 TFTP）+ dtb | 内核打印 `Memory: 128MB`、`riscv_timer`、`sifive-plic`、`mtd` 分区信息，与 DTS 完全一致 |
| B3-2 | 挂载 rootfs（UBIFS/initramfs） | 出现 `login`/`#` |
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

## 8. 待用户确认的决策点（**上板前必须拍板**）

1. **D-1 时钟**：B1 先用 **50 MHz**（与仿真一致）还是直接 **33 MHz**（更保守、与参考工程默认一致）？
   建议：**先用 50 MHz**，WNS<0 时自动退到 33 MHz。
2. **D-2 Cache 与 B3 的顺序**：④（L1I/L1D/L2 + CBO）尚未完成。选项：
   (a) **先完成 ④ 再上板**（B3 更有把握，但要多花 2~4 人日）；
   (b) **先做 B1/B2**（不依赖 Cache），B3 是否用无 Cache 版本先"跑到 `#`"再补 Cache；
   (c) ④ 只做**最小可用 Cache**（L1I 16 KB/4 路 + L1D 写直达，不做 MSHR/预取/L2）。
   建议：**(b) + (c)**——先上 B1/B2 拿到"板子+工具链+烧写"全流程信心，同时并行做最小 Cache，B3 用带 Cache 的版本。
3. **D-3 线材/环境**：确认有下载线、串口线、可用的 SPI flash 与 NAND（板载），以及可否把板子接到常用工作机。
4. **D-4 镜像来源**：U-Boot/Linux 用 chiplab 参考仓库（LA32R 版，需要移植）还是用上游 RISC-V U-Boot/Linux
   （自建 `rv32` 配置）？建议：**上游 RISC-V 主线**（`qemu-riscv32`/`sifive_u` 之外的 minimalist 配置更省事），
   DTS 用本仓库的 `rv32gc-chiplab.dts`。
5. **D-5 验收口径**：B3 是否必须"从 NAND 根文件系统启动到 login"，还是"initramfs 到 `#`"即可作为本阶段通过？

---

## 9. 附：本次上板要带回的证据清单

1. Vivado `report_timing_summary`（WNS/TNS/WHS）+ 资源占用（LUT/FF/BRAM/DSP）；
2. B1：串口日志（含心跳时间戳）+ 数码管照片；
3. B2：串口完整日志（SPI 桩 → DDR → U-Boot `=>`）+ `mtd list` 输出 + `md` 校验片段；
4. B3：内核启动日志（含 `Memory:`/`riscv_timer`/`sifive-plic`/`mtd` 行）+ `#` 提示符；
5. 每次失败现场（串口最后 50 行 + VIO 抓的 PC/priv）。
