# M5 上板运行手册（RV32-GC × chiplab 龙芯 Artix-7 实验箱）

> **适用对象**：操作实验箱的用户（无需读 RTL）。本文只讲"烧什么、按什么顺序看什么、看到什么算对、不对时报什么"。
> **本文口径真源**：`docs/kb/platform-facts.md`（平台地址/时钟/约束）、`docs/design/08-baseline-5stage.md` §8.6（M5 五步序列）、
> `rv32gc-cpu/rtl/pkg/core_params.vh`（核侧地址宏）、`chiplab/IP/CONFREG/confreg_syn.v:34-42`（CONFREG 寄存器偏移）、
> `chiplab/IP/APB_DEV/URT/uart_regs.v`（UART 分频口径）、`chiplab/fpga/loongson/soc_up.xdc`（引脚）。
> **状态**：RTL 冻结（commit `ae906cd`，全核 60 MHz 布线 WNS +0.031 / 0 失败端点）；上板时钟 **33 MHz 同域**（平台 `clk_pll_33.clk_out2` 同驱 `cpu_clk` 与 `uncore_clk`）。

---

## 0. 一分钟速览

| # | 你要做的事 | 用什么 | 期望看到 |
|---|---|---|---|
| 1 | 上电 + 连接 | 电源、Xilinx 下载线（JTAG）、串口线（板载 UART） | 电源灯亮；串口能打开 |
| 2 | 下载 bitstream | Vivado Hardware Manager（**Windows 侧**）或 SPI Flash 固化 | 无报错 |
| 3 | 打开串口 | **115200 8N1**，无流控 | 上电/复位后打印启动横幅 |
| 4 | 看 LED / 数码管 | 板载 16 个 LED、8 位数码管 | LED 心跳 → 显示开关值 → 显示数字 |
| 5 | 读结论行 | 串口 | `RESULT: RV32GC-M5-OK` |

**核心判据（一句话）**：串口出现 `RESULT: RV32GC-M5-OK`，且 LED 能跟随拨码开关变化。
**失败判据（一句话）**：串口无任何输出，或输出乱码，或出现 `RESULT: RV32GC-M5-BAD`。

---

## 1. 需要的东西（交付物清单）

| 文件 | 路径（本仓库内） | 用途 |
|---|---|---|
| **bitstream** | `chiplab/fpga/loongson/2023.2/rv32gc_out/rv32gc_chiplab_soc.bit` | JTAG 直接下载（掉电丢失） |
| bitstream（同源副本） | 同上目录 `system_run.bit`（Vivado 原始文件名） | 同上 |
| **Flash 镜像（bin）** | `rv32gc-cpu/sw/m5_board/out/m5_board.bin`（约 1.5 KB） | 烧进 SPI Flash（掉电保持，复位即自动运行） |
| 程序 ELF / 反汇编 | `rv32gc-cpu/sw/m5_board/out/m5_board.elf` / `.dis` | 排障时核对 |
| 构建日志 | `chiplab/fpga/loongson/2023.2/rv32gc_out/rv32gc_build.vivado.log` | 构建证据 |
| 时序/利用率报告 | 同目录 `impl_timing_summary.rpt` / `impl_utilization.rpt` | 时序与资源证据 |

外部工具（**均在 Windows 侧**，本项目禁止在 WSL 里调用 Windows 命令）：

- **Vivado 2023.2 GUI** → Open Hardware Manager（下载 bitstream / 操作 JTAG）。
- **串口终端**：MobaXterm / SecureCRT / PuTTY / minicom 任选（115200 8N1）。
- 若要固化到 SPI Flash：chiplab 官方 **`programmer_by_uart.bit`**（[下载地址](https://gitee.com/chenzes/chiplab-tools/releases/download/chiplab-tools/programmer_by_uart.bit)）+ 一个支持 **xmodem** 的串口软件（`minicom -s` / ECOM / SecureCRT，见 `chiplab/docs/FPGA_run_linux/flash.md`）。

---

## 2. 硬件连接与跳线（先做这一步，否则后面全部白干）

1. **电源**：实验箱电源接好、开关打到 ON。板上电源指示灯亮。
2. **JTAG 下载线**：Xilinx Platform Cable / Digilent 线 → 板上 JTAG 口（`EJTAG_*` 一组引脚，见 `soc_up.xdc`）。
   在 Windows 的 Vivado Hardware Manager 里 `Open Target → Auto Connect`，应能识别到 `xc7a200t`。
3. **串口线**：板上 **UART（主串口，不是 debug 串口）** 接到 PC。
   - 引脚口径（`chiplab/fpga/loongson/soc_up.xdc`）：`UART_RX = F23`、`UART_TX = H19`（UART0，16550，基址 `0x1FE0_01E0`）。
   - 板上另有 debug 串口 `UART_RX2 = M25` / `UART_TX2 = P25`（`debug_top` 专用）——**本手册不用它**，别插错。
4. **SPI Flash**：板上 SPI NOR（S25FL128S，16 MiB）应插好。**它保存我们的程序**。
5. **拨码开关**：实验箱上的 8 位拨码开关（`switch[7:0]`）——步③ 要拨它。
6. **LED / 数码管**：板上 16 个 LED（`led[15:0]`）与 8 位数码管（`num_csn[7:0]`/`num_a_g[6:0]`）。

> **复位**：`resetn = Y3`（低有效）。板上复位按键按下即复位；**复位后核从 `0x1C00_0000`（SPI Flash 偏移 0）取第一条指令**。

---

## 3. 步骤一：下载 bitstream（两种方式，二选一）

### 方式 A（推荐先用）：JTAG 直接下载 —— 验证设计本身

1. Windows 打开 Vivado 2023.2 → `Open Hardware Manager` → `Open Target` → `Auto Connect`。
2. `Program Device` → 选 `chiplab/fpga/loongson/2023.2/rv32gc_out/rv32gc_chiplab_soc.bit` → `Program`。
3. **期望**：进度条到 100%，无 ERROR。
   - 掉电即丢；重新上电后 FPGA 回到出厂配置（不会有我们的程序输出）。
4. 下载完成后**按一下板上复位键**（或重新上电前先做完第 4 节）。

### 方式 B：固化到 SPI Flash —— 掉电保持，上电自动跑

> 目的：把 `m5_board.bin` 写进 SPI Flash 偏移 0，使**每次上电/复位都自动从 `0x1C00_0000` 跑我们的程序**。
> 这一步用的是 chiplab 官方"串口烧写 Flash"流程（`chiplab/docs/FPGA_run_linux/flash.md`）。

1. 用 Vivado Hardware Manager 下载 **`programmer_by_uart.bit`**（不是我们的 bitstream）。
2. 打开串口软件：**230400 8N1**（这是**烧写器**的波特率，不是我们程序的 115200）。
3. 串口终端里按提示输入 **`x`**（开始接收 xmodem 传输）。
4. 用串口软件的 **xmodem 发送**功能，发送 `rv32gc-cpu/sw/m5_board/out/m5_board.bin`。
5. **期望**：传输进度到 100%，提示完成。
6. 重新下载**我们的 bitstream**（方式 A 的第 2 步），或直接断电重上电（若已把我们的 bitstream 也固化）。
7. **回到 115200** 重开串口，按复位键。

> ⚠️ **注意**：`programmer_by_uart.bit` 会把收到的二进制**从 Flash 地址 0 开始**写入 —— 这正是我们要的位置（Flash 地址 0 = 核的 `0x1C00_0000`）。**不要把别的镜像和它混烧**，否则会覆盖本程序。

---

## 4. 步骤二：打开串口并观察（M5 五步序列）

**串口参数：115200 bps，8 数据位，无校验，1 停止位，无流控（8N1）。**

> 为什么是这个数：程序把 16550 的除数寄存器设成 **18**，平台 `PCLK = 33 MHz`，
> 波特率 = 33 MHz / (18 × 16) = **114583 Bd**（与 115200 相差 0.54%，在 UART 容差内）。
> 若你的终端只有 115200 档位，直接用 115200 即可。**若看到乱码，先按 §5 的"串口乱码"排查。**

按复位后，按顺序观察以下现象（程序是**循环执行**的，所以你会反复看到同一套输出）：

### 步① LED 心跳

- **现象**：16 个 LED 中**只有一个**亮，并且每约 2 ms 向高位移动一格（`0x0001 → 0x0002 → … → 0x8000 → 1`），共 8 拍。
- **同时**：数码管显示 `1` + 心跳数据（最高位那一位显示 `1`，即进度码 1）。
- **串口**：打印 `step1 LED heartbeat, pattern=<十进制>` 若干行。
- ✅ **期望**：LED 明显在"跑马灯"，不是全灭也不是全亮。
- ❌ **若无心跳**：核没有在提交任何写 LED 的指令 ⇒ 见 §5 失败定位表。

### 步② UART 输出

- **现象（上电/复位后立即）**：
  ```
  RV32GC-M5 board test (chiplab / xc7a200tfbg676-2) @ 33MHz
  UART 115200 8N1 (divisor=18, PCLK=33MHz -> 114583 Bd)
  RESET_PC=0x1C000000 (SPI XIP), MMU off, PC-relative only
  ```
- 以及循环里的：
  ```
  step2 UART output alive; sequence = LED -> UART -> switch -> timer -> FREQ
  ```
- ✅ **期望**：文字**完整、无乱码**。
- ❌ **若完全无输出**：见 §5 表第 1、2 行。
- ❌ **若乱码**：见 §5 "串口乱码"。

### 步③ 开关回读

- **现象**：把板上 8 位拨码开关拨成任意值 → **LED 低 8 位立即跟着变**；数码管高位显示 `3`。
- **串口**：打印 `step3 switch readback = <十进制>`（值 = 开关的二进制值，拨到全 0 就是 0）。
- ✅ **期望**：拨开关，LED 跟随；串口数值与开关一致。
- ❌ **若 LED 不跟随**：读 MMIO（`0x1FD0_F020`）通路有问题 ⇒ 记录串口打印的数值（可能是固定值/0）。

### 步④ 定时器对照（**这是主频判据**）

- **现象**：串口打印
  ```
  step4 timer ticks = 118043, cycles/iter = 59, expected ticks = 118000
  ```
  （上板实测 `ticks` 以实际为准；`cycles/iter` 为 `ticks/2000` 的整数商，标定值 59。）
- **口径**：程序把 CONFREG 的自由运行计数器 `TIMER`（`0x1FD0_E000`）清零，跑固定 **2000** 次 `delay_loop` 迭代，再读 `TIMER`：
  - `ticks` = 两次读数之差（TIMER 一拍 = 核一个周期）；
  - `cycles/iter` = `ticks / 2000` = 每次迭代消耗的核周期数（由程序内自写的移位除法算出，**不用 M 扩展**，故该判据不依赖乘法/除法 IP）；
  - `expected ticks` = 程序内写死的**标定值** 118000 = `2000 × XIP_CPI(59)`。
- **为什么"每迭代 59 拍"而不是 9 拍**：本程序在 **SPI Flash XIP 窗口**里执行，且核的取指**绕过 I-Cache**（平台口径：XIP 无 cache 一致性）⇒ 每条指令都要走 AXI + SPI 时序从 Flash 读字，实测约 **6.5 拍/指令**。延时循环体是固定的 9 条指令（7×`nop` + `addi` + `bne`），故 ≈59 拍/迭代。这个数字可以在 `sw/m5_board/out/m5_board.dis` 的 `dl_loop` 段核对（`build.sh` 判据⑧ 会机器核对循环体结构；`XIP_CPI` 常量必须在 `m5_board.S` 里同步）。
- ✅ **期望（33 MHz 同域）**：
  - `cycles/iter`（程序内 `ticks / 2000` 的整数商）= **59** 为标定值；**判据窗口 35 ~ 82**（±40%，
    上限放宽是为了容纳上板 SPI Flash 读延迟与仿真模型的差异）；
  - `ticks` ≈ **118000**（窗口 **70800 ~ 165200**）。
  - ★ 若核实际跑在另一个时钟域（例如误接 50 MHz），`ticks` 会按频率比 **≈50/33 = 1.5 倍**整体变化
    （≈177000）⇒ **跳出窗口** ⇒ 步④ 判 BAD、LED 显示 0，串口行里 `ticks` 会明显偏大。
  - ★ **注意**：标定常量 59 来自核级仿真（TB 的 AXI 从设备是零延迟模型），**上板**每笔 Flash 读会多几十拍，
    所以实测 `cycles/iter` 高于 59 属正常。若它落在 60 ~ 90 而 `ticks` 超窗口，
    请把这一行**原文抄回来**，我们按实测重标定后重新出镜像——**不要**据此判断板子坏了。
- **★ 主频的最终确认靠"心跳节奏目视核对"**（本步是量化自洽性/诊断判据）：
  步① 每拍等 `8 000 000` 拍 = **0.24 s**（33 MHz 下），8 拍一轮 ≈ **1.9 s**。
  用手机秒表量"从一次 LED0 亮到下一次 LED0 亮"的间隔：
  - **≈1.9 s** ⇒ 主频口径正确（33 MHz）；
  - **≈1.3 s** ⇒ 实际是 50 MHz 域（比例 1.5 倍）⇒ 把现象报回来；
  - 其他数值 ⇒ 连同 `cycles/iter`、`ticks` 一起报回来。
- ❌ **若 `cycles/iter` ≈ 88（= 59×1.5）**：说明实际主频是 50 MHz ⇒ **把这一行原文抄回来**。

### 步⑤ FREQ 回读

- **现象**：串口打印
  ```
  step5 FREQ = 0x01F78A40 (div1e6 = 33 MHz)
  ```
- **口径**：`0x01F78A40 = 33 000 000`（`config.h` 的 `` `FREQ `` 宏，已同步为 33 MHz）。
  这是**平台侧常量寄存器**的读回，验证"核能读到平台寄存器"这一条通路。
  `div1e6` 列 = `FREQ / 1 000 000` 的整数部分（由程序内自写的移位除法算出，不用 M 扩展）。
- ✅ **期望**：十六进制值 = **`0x01F78A40`**，`div1e6` = **33**。
  （程序内的**判定条件**是 `FREQ >> 20 == 0x1F = 31`；`div1e6` 打印出来供人工核对，
    两者都应符合上值。最终 `RESULT: ...-OK` 要求"步④ 通过 **且** `FREQ>>20 == 31`"。）

### 结论行

- **现象**：
  ```
  RESULT: RV32GC-M5-OK
  ```
- ✅ **期望**：出现 `OK`（步④ 与步⑤ 同时满足才打印 OK；任一不满足打印 `BAD`）。
- 之后程序**回到主循环继续跑**（LED 心跳/打印循环往复），这是正常的，不是死机。

---

## 5. 失败时怎么办：请把这些信息回报给母 Agent

> **定位纪律（先假设自己的缺陷）**：先怀疑核/接线/约束，最后才怀疑平台。以下信息**逐条照抄**回报，
> 不要只写"没输出"。

### 5.1 必报信息清单（无论什么现象都报）

| 项 | 具体内容 |
|---|---|
| ① bitstream 来源 | 用的哪个文件（路径 + 文件大小 + `md5sum` 或 Windows 侧哈希） |
| ② 下载方式 | JTAG 直下 / SPI Flash 固化；Vivado 有无 WARNING/ERROR 原文 |
| ③ 串口设置 | 端口号、波特率（115200？）、数据位/校验/停止位/流控 |
| ④ 串口**原始输出全文** | 直接**复制粘贴**（含乱码原样粘贴），不要转述；注明是否有输出、多少个字符 |
| ⑤ LED 状态 | 复位后：全灭 / 全亮 / 跑马灯 / 固定某几位亮（用 16 位二进制的哪几位亮描述） |
| ⑥ 数码管状态 | 亮几位、显示什么字符（若有） |
| ⑦ 拨码开关状态 | 8 位当前值（拨上=1 还是 0 请注明板上丝印方向） |
| ⑧ 复位操作 | 按了几次复位键、每次现象是否一致 |
| ⑨ 板子型号/丝印 | 实验箱型号、FPGA 丝印（应为 `xc7a200t`）、板号 |
| ⑩ 电源与跳线 | 电源电压档位、JTAG/串口接线位置（拍照更好）、有无跳线帽被改动 |

### 5.2 按现象定位

| 现象 | 最可能的原因 | 立刻可做的对照实验 |
|---|---|---|
| **串口完全无输出**，LED 也不动 | 核没有跑起来：取指失败（Flash 里没有程序 / Flash 未插好）或时钟没起 | ① 确认已按 §3 方式 B 把 `m5_board.bin` 烧进 Flash；② 确认下载的是**我们的** bitstream；③ 用示波器/逻辑分析仪看 `SPI_CLK`（引脚 P20）在复位后是否有活动 |
| **串口无输出，但 LED 在跑马灯** | UART 通路问题：程序在跑，但串口参数/接线不对 | ① 换 57600/230400 试；② 确认插的是 UART0（F23/H19）而不是 debug 串口（M25/P25）；③ 交换 RX/TX |
| **串口乱码**（能看出字符轮廓但错位） | 波特率不匹配 | ① 终端设 115200 8N1 无流控；② 关掉终端的"软件流控/硬件流控"；③ 若你的终端有 114583 自定义档位就填它 |
| **打印在 `step1` 反复出现，之后没有 `step3/4/5`** | 程序卡在 LED 心跳段（不太可能死循环，但可能被反复复位） | 检查复位键是否卡住 / 电源是否不稳（`timer` 数值若每次都很小说明被反复复位） |
| **`RESULT: RV32GC-M5-BAD`（只在最后一行）** | 步④ 时序判据或步⑤ FREQ 判据不满足 | **把 `step4`/`step5` 那两行的完整原文抄回来**（`ticks`、`cycles/iter`、`expected ticks`、`FREQ`），这决定了是 XIP 取指延迟标定偏差、主频不对、还是平台寄存器读回问题 |
| **LED 全亮或全灭且串口正常** | LED 段接线/极性，或程序在写 `0xFFFF/0x0000` | 抄回 `step1 LED heartbeat, pattern=` 的数值 |
| **拨开关 LED 不跟随** | MMIO 读通路（`0x1FD0F020`）问题 | 抄回 `step3 switch readback =` 的数值（拨到 0x55 和 0xAA 各试一次） |
| **Vivado 下载报 DRC/IDCODE 错** | JTAG 线/驱动/供电 | 换线、换 USB 口、Auto Connect 重新识别；回报 Vivado 报错原文 |

### 5.3 排障时可用的"离线核对"（不需要板子）

```bash
# 反汇编（核对程序内容；本机可跑）
less rv32gc-cpu/sw/m5_board/out/m5_board.dis
# 镜像前 64 字节（应为非 0 的指令字）
xxd -l 64 rv32gc-cpu/sw/m5_board/out/m5_board.bin
# 构建证据（时序/利用率/综合日志）
ls chiplab/fpga/loongson/2023.2/rv32gc_out/
grep -E "WNS|Timing constraints are not met|All user specified timing constraints are met" \
     chiplab/fpga/loongson/2023.2/rv32gc_out/impl_timing_summary.rpt
```

---

## 6. 交付记录（由构建方填写，用户对照）

| 项 | 值 |
|---|---|
| 核 RTL 冻结版本 | `rv32gc-cpu` commit `ae906cd`（全 `rtl/**` 的 md5 汇总 = `f41d1f253d5e0e5baa8030e118af87c1`） |
| 上板时钟口径 | 33 MHz 同域（`clk_pll_33.clk_out1` 留空，`assign cpu_clk = uncore_clk`）；`config.h` `FREQ = 32'd33000000` |
| 器件 / 约束 | `xc7a200tfbg676-2` / `chiplab/fpga/loongson/soc_up.xdc`（板级 100 MHz 输入时钟约束，PLL 派生 33 MHz） |
| **bitstream** | `chiplab/fpga/loongson/2023.2/rv32gc_out/rv32gc_chiplab_soc.bit`（**9 730 756 B**，md5 `5e3bd4f138d6e408728db3590726bfd1`） |
| FPGA 配置 bin（同源） | 同目录 `soc_top.bin`（9 730 652 B，md5 `6748db8c9119f60080da5d8324c60a7d`） |
| **Flash 镜像** | `rv32gc-cpu/sw/m5_board/out/m5_board.bin`（**1621 B**，md5 `3b60ccac3b227e367eb8497fd66ff024`） |
| 程序波特率 | 115200 8N1（核内设分频 = 18，实际 114583 Bd） |
| 烧写器波特率 | 230400（`programmer_by_uart.bit`，仅固化 Flash 时用） |
| 时序（33 MHz 约束，布线后） | WNS **+0.978 ns** / TNS 0 / 失败端点 **0**；WHS **+0.050 ns** / THS 0 / 失败端点 **0**；`All user specified timing constraints are met` |
| 资源（整片 SoC，含平台） | Slice LUT 70 226 / 134 600（52.2%）、FF 41 515（15.4%）、BRAM 15.5/365、DSP 34/740（核本身 `core_top` ≈ 52 646 LUT） |

> **构建方补充**：以上数字取自 `chiplab/fpga/loongson/2023.2/rv32gc_out/{impl_timing_summary,impl_utilization}.rpt`（2026-09-20 构建）。
> 步④ 的 `cycles/iter` 期望值（59）来自核级仿真实测（`rv32gc-cpu/sw/m5_board/tb/`）；若上板实测与 59 偏差 >25%，
> 请按 §4 步④ 的说明把原文抄回来重标定，**不要**据此判定板子故障。
