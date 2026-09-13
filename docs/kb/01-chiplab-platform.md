# KB-01 平台硬事实（chiplab / 龙芯实验箱）

## 0. 板级硬件清单（由 `实验箱A7-原理图.pdf` 确认，2026-09-13 更新）

| 位号 | 器件 | 型号 | 说明 |
|---|---|---|---|
| — | FPGA | **XC7A200T-FBG676**（`xc7a200tfbg676-2`，Artix-7） | 板级输入时钟 **100 MHz** |
| U8 | **NAND Flash** | **K9F1G08U0C-PCB0**（Samsung 1 Gbit SLC，3.3 V，x8） | 页 2048+64 B、块 128 KiB、1024 块 = **128 MiB**；单 CE#；R/B# → `FPGA_NAND_RDY`；4.7 K 上拉；详见 `03-nand-controller.md` §0 |
| U14 | **SPI NOR Flash** | **S25FL128SAGMFI001**（128 Mbit = 16 MiB，DIP 插座） | 信号 `FPGA_SPI_{SCK,CS#,SDI,SDO,WP#,HOLD#}`；平台 PMON/u-boot 的存放介质 |
| — | DDR3 | **K4B1G1646G-BCK0**（Samsung 1 Gbit x16 DDR3） | **128 MiB**，与内核 DTS `/memory` 的 `0x0800_0000` 一致 |
| — | 其他 | MAC PHY ×2、USB PHY、UART、LCD/VGA、SRAM、数码管/键盘/开关、AD/DA | 与平台 SoC 顶层一一对应 |

> 结论：**NAND 与 DDR3 的容量、页/块几何都与平台 RTL 和 LA32R 内核 DTS 完全一致**（128 MiB / 2048+64 B 页 / 128 KiB 块），无需修改参考驱动的几何 gate。

## 1. CPU 接口契约（不可更改）

- 顶层模块名必须是 **`core_top`**，源文件放入 `$CHIPLAB_HOME/IP/myCPU/`（该目录当前是**未初始化的空子模块**，指向 `gitee.com/loongson-edu/open-la500`）。
- 例化位置：`chip/soc_demo/loongson/soc_top.v:723`（FPGA）、`chip/soc_demo/sim/soc_top.v:340`（仿真）。
- 端口（默认 AXI32）：`aclk, aresetn, intrpt[7:0]` + 单路 AXI4 主设备 + 调试信号
  （`ws_valid`/`rf_rdata` 输出，`break_point`/`infor_flag`/`reg_num` 输入，`debug0_wb_*` 输出）。`[RTL][DOC]`
- **`arlen/awlen` 实际为 4 bit**（`config.h` 的 `Larlen/Lawlen=4`），突发不得超过 16 beat。`[RTL]`
- `debug1_wb_*` 仅在 `` `CPU_2CMT `` 定义时存在（双发射参考核用），本项目不需要。`[RTL]`

## 2. 时钟与复位

| 时钟 | 来源 | 频率 | 域内设备 |
|---|---|---|---|
| 板级 `clk` | 晶振（AC19） | 100 MHz | PLL/MIG 参考 |
| `cpu_clk` | `clk_pll_33/clk_out1` | **50 MHz**（本项目目标 100 MHz） | CPU + CPU 侧 AXI |
| `uncore_clk` = `aclk` | `clk_pll_33/clk_out2` | 33 MHz | DDR/UART/NAND/SPI/MAC/CONFREG |
| `clk_wiz_0/clk_out1` | PLL | 200 MHz | DDR MIG 参考 |
| MIG `ui_clk` | MIG | 100 MHz | DDR 控制器 |

- CPU 侧与 uncore 侧的跨时钟域由平台 `axi_clock_converter_0` 完成，**核内不需要处理**。`[RTL]`
- `` `define FREQ 32'd33000000 ``（`chip/soc_demo/loongson/config.h`）与实际 `cpu_clk`（50 MHz）**不一致**，属平台遗留；升频时必须一并修正。`[RTL]`
- `soc_up.xdc` 的 `create_clock -period 10.000` 约束的是板级 100 MHz 输入，不是 CPU 时钟。`[RTL]`

## 3. 内存映射（物理地址）

| 区间 | 大小 | 设备 | 译码依据 |
|---|---|---|---|
| `0x0000_0000`–`0x07FF_FFFF` | 128 MiB | DDR3（默认通路） | `axi_mux_syn.v` 默认 slave |
| `0x1C00_0000`–`0x1C0F_FFFF` | 1 MiB | SPI XIP（FPGA）/ SRAM（仿真） | FPGA XIP 窗口 |
| `0x1FD0_0000` | 64 KiB | **CONFREG（FPGA）** | `axi_mux_syn.v` 译码 `0x1fd0` |
| `0x1FAF_0000` | 64 KiB | **CONFREG（仿真）** | `axi_mux_sim.v` 译码 `0x1faf` |
| `0x1FE0_0000`–`0x1FE0_3FFF` | 16 KiB | UART0（寄存器 `0x1FE0_01E0`） | APB `addr[19:14]==0` |
| `0x1FE7_8000` | 16 KiB | NAND 控制器（数据口 `+0x40`） | APB `addr[19:14]!=0` |
| `0x1FE8_0000` | — | SPI 控制器 | `axi_mux_syn.v` 译码 `0x1fe8` |
| `0x1FF0_0000` | 64 KiB | MAC (dmfe) | `axi_mux_syn.v` 译码 `0x1ff0` |

> RISC-V **没有** KSEG 段：LA32R 代码里的 `0x9fe001e0`（= `0x80000000|0x1fe001e0`）、`0xbfaf_xxxx`、`0xa0000000|phys` 在 RISC-V 上全部无效，必须换成物理地址。`[LA32R]`

## 4. CONFREG 寄存器（两套！）

**FPGA：`confreg_syn.v`，基址 `0x1FD0_0000`** `[RTL]`

| 偏移 | 名称 |
|---|---|
| `+0x0000`+4n | CR0..CR7 |
| `+0xF000` | LED |
| `+0xF004` / `+0xF008` | LED_RG0 / LED_RG1 |
| `+0xF010` | NUM（数码管） |
| `+0xF020` | SWITCH |
| `+0xF024` / `+0xF028` | BTN_KEY / BTN_STEP |
| `+0xF030` | FREQ（读回频率） |
| `+0xE000` | TIMER |
| `+0x1160` | **DMA 门铃（ORDER_REG）** |

**仿真：`confreg_sim.v`，基址 `0x1FAF_0000`** `[RTL]`

| 偏移 | 名称 |
|---|---|
| `+0x8000`+0x10n | CR0..CR7 |
| `+0xF020` | LED |
| `+0xF030` / `+0xF040` | LED_RG0 / LED_RG1 |
| `+0xF050` | NUM |
| `+0xF060` | SWITCH |
| `+0xE000` | TIMER |
| `+0xFF00` | **IO_SIMU（仿真退出/IO）** |
| `+0xFF10` | **VIRTUAL_UART（写字节 → 仿真打印）** |
| `+0xFF20` | SIMU_FLAG（只读，仿真中为 `0xFFFF_FFFF`） |
| `+0xFF40` | NUM_MONITOR（写 1 关闭数码管监视） |

> **同一个"CONFREG"在仿真与 FPGA 下基址与偏移都不同**：软件不要硬编码，用设备树/配置宏区分。
> 平台的仿真退出机制是"PC 命中 `END_PC` + 写 VIRTUAL_UART/IO_SIMU"，RV32 上我们自定义退出约定（见 `07-sim-debug.md`）。

## 5. 中断线

`assign int_out = {1'b0, dma_int, nand_int, spi_inta_o, uart0_int, mac_int};`
CPU 收到 `intrpt[7:0] = {3'b0, int_out[4:0]}`，即：`[0]`=MAC、`[1]`=UART、`[2]`=SPI、`[3]`=NAND、`[4]`=DMA。`[RTL]`

（LA32R 内核里的 IRQ 号 2/3/4 是 LoongArch `cpuic` 的编号约定，与 RISC-V PLIC 源号无关，不要照搬。）`[LA32R]`

## 6. 平台流程速查

```bash
export CHIPLAB_HOME=/home/shorthair/dsh/rv32-cpu/chiplab
# 仿真（平台自带，LA32R 用；RV32 需自建 TB，见 07-sim-debug.md）
cd $CHIPLAB_HOME/sims/verilator/run_prog && ./configure.sh --run func/func_lab19 && make
# 综合：平台未提供 tcl（只有 GUI 工程），本项目自建 fpga/build_chiplab.tcl
#   fpga/loongson/{2019.2,2023.2}/system_run.xpr  part=xc7a200tfbg676-2  top=soc_top（不含 CPU 源文件）
```

## 7. 平台"坑"清单

| 坑 | 说明 |
|---|---|
| `IP/myCPU` 为空子模块 | 需要把自己的 RTL 放进去（或改 `MYCPU_SRC`） |
| 仿真 SoC 是 128 bit AXI、FPGA SoC 是 32 bit | 用 `` `AXI64 ``/`` `AXI128 `` 宏参数化数据宽度 |
| 仿真与 FPGA 的 CONFREG 地址不同 | 见 §4 |
| `FREQ` 宏与实际频率不符 | 升频时同步修改 |
| FPGA 工程不含 CPU 源文件，且无 tcl | 自建 tcl 生成工程 |
| `fpga/*/testbench/*.v` 是过期副本 | 不可用 |
| 平台 difftest 依赖 LA32R NEMU | RV32 不能用，改用 Spike 轨迹比对 |
| NAND 只在 FPGA 存在（仿真用 `apb_dev_top_no_nand.v`） | 仿真 NAND 需自建行为模型 |
| `toolchains/` 目录为空 | 需要自己准备工具链（LA32R 工具链本项目用不到） |
