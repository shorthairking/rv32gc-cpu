# M5 上板运行手册（RV32-GC × chiplab 龙芯 Artix-7 实验箱）

> **适用对象**：操作实验箱的用户（无需读 RTL）。本文只讲"烧什么、按什么顺序看什么、看到什么算对、不对时报什么"。
> **本文口径真源**：`docs/kb/platform-facts.md`（平台地址/时钟/约束）、`docs/design/08-baseline-5stage.md` §8.6（M5 五步序列）、
> `rv32gc-cpu/rtl/pkg/core_params.vh`（核侧地址宏）、`chiplab/IP/CONFREG/confreg_syn.v:34-42`（CONFREG 寄存器偏移）、
> `chiplab/IP/APB_DEV/URT/uart_regs.v`（UART 分频口径）、`chiplab/fpga/loongson/soc_up.xdc`（引脚）。
> **状态**：RTL 冻结（R2 修复 commit `7a06825`；全 `rtl/**`（`*.v`+`*.vh`）md5 汇总 = **`c558e750441afc0b13c3dbb3776bcbd3`**）；上板时钟 **33 MHz 同域**（平台 `clk_pll_33.clk_out2` 同驱 `cpu_clk` 与 `uncore_clk`）。
> **★ 2026-09-21 诊断版（本轮）**：上板程序新增 **步2.5 DDR3 回环判别**（`R2FIX: yes/no`），
> 用来**一眼判定 FPGA 里跑的是新 bitstream 还是旧 bitstream**；同时把十进制/十六进制打印
> 全部改成**纯寄存器路径**（不再用 DDR3 栈缓冲）⇒ 即使旧 bitstream 在位，数字也不会乱码，
> 而是明确打印 `R2FIX: no`。**先读 §7 诊断节**，再按 §3/§4 烧写观察。

---

## 0. 一分钟速览

| # | 你要做的事 | 用什么 | 期望看到 |
|---|---|---|---|
| 1 | 上电 + 连接 | 电源、Xilinx 下载线（JTAG）、串口线（板载 UART） | 电源灯亮；串口能打开 |
| 2 | 下载 bitstream | Vivado Hardware Manager（**Windows 侧**）或 SPI Flash 固化 | **Program Device 成功、无 ERROR**（见 §7 两步走） |
| 3 | 烧诊断镜像 | `programmer_by_uart.bit` + xmodem 烧 `m5_diag.bin` | 烧写器提示完成 |
| 4 | 打开串口 | **115200 8N1**，无流控 | 横幅含 `BUILD=m5_board-diag-2026-09-21d` |
| 5 | **看步2.5/2.6/2.7 三行** | 串口 | **`R2FIX: yes` + `MEXT: OK` + `STACKBF: OK`** ⇒ 新 bitstream 生效；`MEXT: BAD` ⇒ 板子里还是旧 bitstream（§7） |
| 6 | 看 LED / 数码管 | 板载 16 个 LED、8 位数码管 | LED 心跳 → 显示开关值 → 显示数字 |
| 7 | 读结论行 | 串口 | `RESULT: RV32GC-M5-OK`（**含** R2 回环判据，见 §7） |

**核心判据（一句话）**：串口出现 `R2FIX: yes` **且** `RESULT: RV32GC-M5-OK`，LED 能跟随拨码开关变化。
**失败判据（一句话）**：串口无任何输出；或 `step2.5 … R2FIX: no`（= 旧 bitstream 仍被加载，见 §7）；或 `RESULT: RV32GC-M5-BAD`。

---

## 1. 需要的东西（交付物清单）

| 文件 | 路径（本仓库内） | 用途 |
|---|---|---|
| **bitstream** | `chiplab/fpga/loongson/2023.2/rv32gc_out/rv32gc_chiplab_soc.bit` | JTAG 直接下载（掉电丢失） |
| bitstream（同源副本，**内容完全相同**） | 同目录 `soc_top.bit`（Vivado 原始文件名）与 `../system_run.runs/impl_1/soc_top.bit` | 同上；三份 md5 均为 `167dc9dfd487a9d6148ddee02d407726`（2026-09-21 12:36 构建） |
| **Flash 镜像（bin，诊断版）** | `rv32gc-cpu/sw/m5_board/out/m5_diag.bin`（2774 B） | 烧进 SPI Flash（掉电保持，复位即自动运行） |
| Flash 镜像（同一份内容） | 同目录 `m5_board.bin`（与 `m5_diag.bin` **逐字节相同**，`build.sh` 判据⑪g 用 `cmp` 核对） | 同上 |
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
4. 用串口软件的 **xmodem 发送**功能，发送 `rv32gc-cpu/sw/m5_board/out/m5_diag.bin`
   （= 诊断版镜像；与 `m5_board.bin` 内容完全相同，2199 B，md5 见 §6）。
5. **期望**：传输进度到 100%，提示完成。
6. 重新下载**我们的 bitstream**（方式 A 的第 2 步），或直接断电重上电（若已把我们的 bitstream 也固化）。
7. **回到 115200** 重开串口，按复位键。
8. **按 §7 的两步走核对**：先确认 Vivado `Program Device` 成功（新 bitstream 真的进去了），
   再看串口步2.5 的 `R2FIX: yes/no`。**只烧程序不换 bitstream 是最容易踩的坑**
   （现象：横幅是新的、`step2.5 … R2FIX: no`）—— 这正是本轮诊断版要暴露的事。

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
  BUILD=m5_board-diag-2026-09-21d (stack-free prints; R2+MEXT+stack probes; CPI window informational)
  UART 115200 8N1 (divisor=18, PCLK=33MHz -> 114583 Bd)
  RESET_PC=0x1C000000 (SPI XIP), MMU off, PC-relative only
  ```
  > `BUILD=` 这一行是**诊断版标志**：看到 `BUILD=m5_board-diag-2026-09-21d` 就说明
  > **Flash 镜像确实是本轮的新镜像**（它只证明"程序是新烧的"，**不**证明 FPGA 里是新
  > bitstream —— 后者由步2.5/2.6/2.7 判定）。
- 以及循环里的：
  ```
  step2 UART output alive; sequence = LED -> UART -> DDR3-R2-probe -> switch -> timer -> FREQ
  ```
- ✅ **期望**：文字**完整、无乱码**。
- ❌ **若完全无输出**：见 §5 表第 1、2 行。
- ❌ **若乱码**：见 §5 "串口乱码"。

### 步2.5 ★ DDR3 回环判别（新 bitstream / 旧 bitstream 的**一眼判据**）

- **现象**：紧跟 `step2` 行之后打印**一行**（数值为上板实测；下面是新 bitstream 的期望值）
  ```
  step2.5 DDR3 loopback: word=0x12345678 re-read=0x12345678 byte=0x5A (expect 12345678/5A) -> R2FIX: yes
  ```
- **这一步在测什么**：程序把 `0x12345678` 写进 **DDR3 地址 `0x0000_8000`**（避开程序区与栈），
  用 `lw` 读回；再把 `0x5A` 写进 `0x0000_8003`，用 `lbu` 按字节读回。DDR3 数据访问在核内走
  **MDTA（uncached 单 beat AXI）** —— 正是 R2 缺陷（R 握手后第 2 拍才采样读数据）所在的那条通路。
- **判别表（照这个表下结论）**：

  | `step2.5` 读到什么 | 含义 | 你要做什么 |
  |---|---|---|
  | `word=0x12345678 re-read=0x12345678 byte=0x5A … R2FIX: yes` | ✅ FPGA 里跑的是**新 bitstream**（含 R2 修复） | 继续看步③④⑤ 与 `RESULT` |
  | word/byte 是**别的值**（如 `0x00000000`、`0x1C0xxxxx`、两次读还不一致）⇒ `R2FIX: no` | ❌ FPGA 里**仍是旧 bitstream**（R2 缺陷在位） | 按 §7 重做 `Program Device`，**确认下载成功**（§7 有核对清单） |
  | 一行都没有（或 step2 之后卡住） | 程序没跑到这里 | 回报 §5.1 的必报信息（尤其串口原文与 LED 状态） |

- ✅ **期望**：`word=0x12345678`、`re-read=0x12345678`、`byte=0x5A`、**`R2FIX: yes`**。
- ★ **`R2FIX: no` 会直接把最终结论钉成 `RESULT: RV32GC-M5-BAD`**（判定链 = 步④ ∧ FREQ ∧ 步2.5/2.6/2.7），
  所以"看到 BAD"时**先看步2.5/2.6/2.7 这三行**再谈其它。
- ★ 本轮**数字不会再乱码**：十进制/十六进制打印全部改成**纯寄存器路径**（不再用 DDR3 栈缓冲），
  所以 `step1/step4/step5` 的数字在任何 bitstream 下都是可信的 —— 唯一会"读到垃圾"的是下面这些
  **故意**读出来的探针值。

### 步2.6 ★ M 扩展探针（`MEXT: ok / BAD`）—— 本轮根因的**板上判据**

- **现象**：紧跟步2.5 之后打印三行（一行值、一行结论）：
  ```
  step2.6 MEXT=00000005 00000009 0000003B 00000031 00000000 00000000 0000002A 40000000 FFFFFFFE -> MEXT: ok
  ```
- **数值顺序**（9 个向量，与程序注释/`sw/m5_board/build.sh` 判据⑪f2 一致）：

  | # | 向量 | 期望值 |
  |---|---|---|
  | ① | `divu(59,10)` | `0x00000005` |
  | ② | `remu(59,10)` | `0x00000009` |
  | ③ | `divu(118049,2000)` | `0x0000003B` |
  | ④ | `remu(118049,2000)` | `0x00000031` |
  | ⑤ | `divu(0,10)` | `0x00000000` |
  | ⑥ | `divu(1,10)` | `0x00000000` |
  | ⑦ | `mul(6,7)` | `0x0000002A` |
  | ⑧ | `mulh(0x80000000,0x80000000)` | `0x40000000` |
  | ⑨ | `mulhu(0xFFFFFFFF,0xFFFFFFFF)` | `0xFFFFFFFE` |

- **判别表**：

  | `step2.6` 读到什么 | 含义 | 结论 |
  |---|---|---|
  | 9 个值与上表**逐字相同** ⇒ `MEXT: OK` | ✅ FPGA 里的 M 扩展（div_gen/mult_gen IP 通路）正常 | 继续看步③④⑤ |
  | 商/余数**互换**（如 `divu(59,10)` 回读 `9`、`remu(59,10)` 回读 `5`） | ❌ 跑的是**修复前**的 bitstream（`mdu.v` 把 div_gen 的 tdata 字段序写反：商在**高**半、余数在**低**半） | 重新下载**本轮新 bitstream**（§6/§7） |
  | 其它乱值 | ❌ M 扩展通路仍不正常 | 把整行原文抄回来（§5.1） |

- ✅ **期望**：`MEXT: OK`（大写，与程序内的 `OK` 字面量一致）。
- ★ 为什么必须单列这一步：**RTL 的 IP 分支（综合走 div_gen/mult_gen）在 iverilog 里跑不了**
  （Vivado 生成的 IP 网表是 `pragma protect` 加密的）⇒ 历次仿真回归只覆盖**行为分支**，
  板上才是 IP 分支的第一次功能验证。本轮用 **xsim + 真实 IP** 复现并修掉了这个缺陷
  （见 §8 根因与证据）。

### 步2.7 ★ 栈字节通路探针（`STACKBF: ok / BAD`）

- **现象**：
  ```
  step2.7 stack[16B]=30 31 32 33 34 35 36 37 38 39 41 42 43 44 45 46 -> STACKBF: ok
  ```
- **这一步在测什么**：把 16 字节模式 `"0123456789ABCDEF"` 写进**栈缓冲**（`sp-64`，DDR3 空间），
  再逐字节 `lbu` 读回并按两位 hex 打印 ⇒ 直接暴露"DDR3 字节路径错位 / lane 串位 / 读回垃圾"。
  期望的 16 个字节就是 `"0123456789ABCDEF"` 的 ASCII：`30 31 … 39 41 … 46`。
- **判别表**：

  | `step2.7` 读到什么 | 含义 |
  |---|---|
  | `30 31 32 … 46` ⇒ `STACKBF: OK` | ✅ DDR3 字节读路径正常 |
  | 全 `00`、错位、重复/乱字节 ⇒ `STACKBF: BAD` | ❌ DDR3 读通路有问题（R2 缺陷在位：跑的是旧 bitstream；或该通路另有缺陷） |

- ✅ **期望**：`STACKBF: OK`。

### 步③ 开关回读

- **现象**：把板上 8 位拨码开关拨成任意值 → **LED 低 8 位立即跟着变**；数码管高位显示 `3`。
- **串口**：打印 `step3 switch readback = <十进制>`（值 = 开关的二进制值，拨到全 0 就是 0）。
- ✅ **期望**：拨开关，LED 跟随；串口数值与开关一致。
- ❌ **若 LED 不跟随**：读 MMIO（`0x1FD0_F020`）通路有问题 ⇒ 记录串口打印的数值（可能是固定值/0）。

### 步④ TIMER ↔ 核周期一致性（**对 Flash 取指延迟不敏感**）

- **现象**：串口打印一行。示例为核级仿真（零延迟内存模型）实测值：
  ```
  step4 timer delta = 118055, cycle delta = 118049, cycles/iter = 59 (informational only; window 20..20000; board-calib=4120, sim-calib=59 cycles/iter)
  ```
  > **上板实测**的同一行（`timer delta` / `cycle delta` / `cycles/iter` 随 Flash 时序浮动）例如：
  > `step4 timer delta = 8241325, cycle delta = 8240913, cycles/iter = 4120 (informational only; window 20..20000; board-calib=4120, sim-calib=59 cycles/iter)`。
  > **两种口径并存**：板级 `board-calib=4120`（真机 SPI Flash XIP，每取指 ≈458 拍）/ 仿真 `sim-calib=59`（每指令 ≈6.5 拍）。
  > ★ 本节第一处 `cycles/iter = N` 的 **N（= 仿真标定值 59）** 是 `build.sh` 判据⑨d 抽取的
  > "标定值"（用于核对 `m5_board.S` 的 `.equ XIP_CPI`）⇒ 改动本节时**必须保留一行
  > `cycles/iter = 59`**，且它要出现在任何里含数字的 `cycles/iter` 之前。
- **口径**（2026-09-21 鲁棒化后的判据）：程序把 CONFREG 的自由运行计数器 `TIMER`
  （`0x1FD0_E000`，`confreg_syn.v:346` 每 clk `+1`）清零，然后：
  1. 读 `rdcycle`（核内 `cycle` CSR = `cycle_cnt_r`，`core_top.v:3555` **每拍 +1**）与 `TIMER` 起点；
  2. 跑固定 **2000** 次 `delay_loop` 迭代；
  3. 再读 `rdcycle` 与 `TIMER` 终点。
  - `timer delta` = `TIMER` 增量；`cycle delta` = **核周期**增量（`rdcycle` 差值）；
  - `cycles/iter` = `cycle delta / 2000`（由程序内自写的移位除法算出，**不用 M 扩展**）；
  - **判据 A（唯一被判的步④ 判据）**：`|timer delta − cycle delta| ≤ max(256, cycle delta/128)`（≈1%）。
    两个计数器都在**核时钟域**每拍 +1 ⇒ 同一窗口内增量必须相等。这条**不看任何绝对拍数**，
    因此对 SPI Flash 的取指延迟完全免疫（真机每笔 Flash 读多几十拍也不影响）。
    上板实测：`|8241325 − 8240913| = 412` ≤ `8240913/128 = 64382` ⇒ **通过**。
  - **健全性窗口（信息性：只打印，不参与判定）**：`cycles/iter ∈ [20, 20000]`。
    ★ 2026-09-21 上板实测把它**降级为信息性**：真机 `cycles/iter ≈ 4120`（SPI Flash XIP 无缓存、
    每取指走平台 Flash 桥 ≈458 拍/指令），而窗口上界原按**仿真标定值 59** 的量级定为 300
    ⇒ **真实标定值反而被误判 BAD**。现在窗口**只打印**（便于换平台/换 Flash 时一眼看出差异），
    **不参与 BAD 判定** —— BAD 只由下面两条真判据决定：
    **① 判据 A**（TIMER ↔ rdcycle 增量一致）**∧ ② 步⑤ FREQ 锚定**（`div1e6 == 33` ∧ `FREQ>>20 == 31`）。
    ★ 这不是"放水"：窗口负责的"计数器/时钟域差一个量级"这一类异常，已被判据 A（两个独立计数器
    增量必须同步）与步⑤（主频锚定）**完全覆盖**；被降级的只是"绝对拍数窗口"这个**不可移植**的量。
- **为什么不用绝对拍数判据**：旧口径是 `|ticks − 2000×59| ≤ ±40%`，其中 **59 是零延迟仿真
  内存模型**下 `delay_loop` 的标定拍数；真机 SPI Flash XIP 每笔读要几十拍，实测 `cycles/iter ≈ 4120`
  （是仿真值的 ≈70 倍）⇒ 绝对窗口在板上不可移植（放宽窗口又会退化成"看着像过"）。
  新判据只用**两个独立计数器的一致性**，不需要任何绝对拍数常量。
  `board-calib=4120` / `sim-calib=59` 都只是把标定值打印出来作参考（**不参与判定**）。
- ✅ **期望（33 MHz 同域、核与 TIMER 同源）**：
  - `timer delta` 与 `cycle delta` **两列之差 ≤ 1%**（上板实测差 412 拍，判据上限 64382）；
    若两者差得离谱 ⇒ 步④ 判 BAD、LED 显示 0 ⇒ 说明 `TIMER` 不在核时钟域（例如被分频），
    请把该行**原文抄回来**；
  - `cycles/iter` **只在板上做记录**（典型 3000 ~ 6000）：它 = 每迭代 9 条指令 × SPI XIP 每指令拍数，
    **越大只说明 Flash 读越慢**，不是故障；延时正确性由"心跳节奏"目视核对。
  - ★ **`cycles/iter` 超出窗口不再判 BAD**（信息性），但若它**明显异常**（例如 < 100 或 > 100000）
    仍请把这一行原文抄回来 —— 那是"平台/Flash 通路变了"的强信号。
- **★ 主频的最终确认靠"心跳节奏目视核对"**：
  步① 每拍等 `8 000 000` 拍 = **0.24 s**（33 MHz 下），8 拍一轮 ≈ **1.9 s**。
  用手机秒表量"从一次 LED0 亮到下一次 LED0 亮"的间隔：
  - **≈1.9 s** ⇒ 主频口径正确（33 MHz）；
  - **≈1.3 s** ⇒ 实际是 50 MHz 域（比例 1.5 倍）⇒ 把现象报回来；
  - 其他数值 ⇒ 连同 `cycles/iter`、`timer delta` 一起报回来。

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
- ✅ **期望**：出现 `OK`（**五个**子判据同时满足才打印 OK：步④ 通过 ∧ `FREQ>>20 == 31`
  ∧ 步2.5 R2 回环 ∧ 步2.6 M 扩展向量 ∧ 步2.7 栈字节探针；任一不满足打印 `BAD`）。
- ★ **BAD 的定位顺序**：`step2.6 … MEXT:` → `step2.5 … R2FIX:` → `step2.7 … STACKBF:` → `step4`/`step5`。
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
| **串口完全无输出**，LED 也不动 | 核没有跑起来：取指失败（Flash 里没有程序 / Flash 未插好）或时钟没起 | ① 确认已按 §3 方式 B 把 `m5_diag.bin` 烧进 Flash；② 确认下载的是**我们的** bitstream；③ 用示波器/逻辑分析仪看 `SPI_CLK`（引脚 P20）在复位后是否有活动 |
| **串口无输出，但 LED 在跑马灯** | UART 通路问题：程序在跑，但串口参数/接线不对 | ① 换 57600/230400 试；② 确认插的是 UART0（F23/H19）而不是 debug 串口（M25/P25）；③ 交换 RX/TX |
| **串口乱码**（能看出字符轮廓但错位） | 波特率不匹配 | ① 终端设 115200 8N1 无流控；② 关掉终端的"软件流控/硬件流控"；③ 若你的终端有 114583 自定义档位就填它 |
| **`step2.5 … R2FIX: no`（word/byte 是垃圾值或 0）但十进制数字正常** | ★ FPGA 里跑的还是**旧 bitstream**（R2 缺陷在位）—— 新程序已生效，但配置没换成新的 | 按 §7 重做两步走：`Program Device` → **确认成功**（看 Vivado 的 `Program Device` 完成提示与 `Device properties`）→ 复位；仍为 `no` 则回报 bitstream 文件 md5（§5.1 第①项） |
| **`step2.5 … R2FIX: no` 且数字也乱** | 新程序没烧进去（Flash 里还是老镜像：横幅里没有 `BOARD-PROG:` 行）或程序没跑完 | 抄回横幅原文；重烧 `m5_diag.bin`（§3 方式 B） |
| **打印在 `step1` 反复出现，之后没有 `step3/4/5`** | 程序卡在 LED 心跳段（不太可能死循环，但可能被反复复位） | 检查复位键是否卡住 / 电源是否不稳（`timer` 数值若每次都很小说明被反复复位） |
| **`RESULT: RV32GC-M5-BAD`（只在最后一行）** | ① `step2.5` 判 R2 回环失败（= 旧 bitstream）② 步④ `TIMER`/`rdcycle` 增量不一致（判据 A）③ 步⑤ FREQ 锚定不满足 | **先看 `step2.5` 行**（§4 步2.5 判别表）；若 `R2FIX: yes` 再把 `step4`/`step5` 两行完整原文抄回来（`timer delta`、`cycle delta`、`cycles/iter`、`FREQ`）。★ 注意：`cycles/iter` 超出 `[20,20000]` **不会**导致 BAD（该窗口本轮起只是信息性打印） |
| **LED 全亮或全灭且串口正常** | LED 段接线/极性，或程序在写 `0xFFFF/0x0000` | 抄回 `step1 LED heartbeat, pattern=` 的数值 |
| **拨开关 LED 不跟随** | MMIO 读通路（`0x1FD0F020`）问题 | 抄回 `step3 switch readback =` 的数值（拨到 0x55 和 0xAA 各试一次） |
| **Vivado 下载报 DRC/IDCODE 错** | JTAG 线/驱动/供电 | 换线、换 USB 口、Auto Connect 重新识别；回报 Vivado 报错原文 |

### 5.3 排障时可用的"离线核对"（不需要板子）

```bash
# 反汇编（核对程序内容；本机可跑）
less rv32gc-cpu/sw/m5_board/out/m5_board.dis
# 镜像前 64 字节（应为非 0 的指令字）
xxd -l 64 rv32gc-cpu/sw/m5_board/out/m5_diag.bin
# ★ "打印路径不依赖内存"的机器证据（本机可跑，不需要板子）：
#   全程序不得有任何以 sp(x2) 为基址的访存（诊断版把数字打印改成纯寄存器路径）
grep -nE '\b(lw|sw|sb|lbu)\b.*\(x2\)' rv32gc-cpu/sw/m5_board/out/m5_board.text.dis || echo "OK：零栈访存"
#   全程序唯一的 DDR3 访问 = 步2.5 探针（地址 0x8000）：把访存按基址寄存器归类
grep -oE '\b(lw|sw|sb|lbu)\s+x[0-9]+,-?[0-9]+\(x[0-9]+\)' rv32gc-cpu/sw/m5_board/out/m5_board.text.dis \
  | sed -E 's/.*\((x[0-9]+)\)/\1/' | sort | uniq -c
#   （期望：x2 一个都没有；x4 = 只读串（.rodata）；x5 = DDR3 探针 5 条；x8 = UART；x31 = CONFREG）
# 构建证据（时序/利用率/综合日志）
ls chiplab/fpga/loongson/2023.2/rv32gc_out/
grep -E "WNS|Timing constraints are not met|All user specified timing constraints are met" \
     chiplab/fpga/loongson/2023.2/rv32gc_out/impl_timing_summary.rpt
# ★ bitstream 里"到底是不是修复后 RTL"的本地证据（不需要板子；见 §7.3）
grep -a -o 'cpu_mid/u_axi_master_ctrl/rdata_hold_q' \
     chiplab/fpga/loongson/2023.2/system_run.runs/impl_1/soc_top_power_routed.rpx | sort -u
```

---

## 6. 交付记录（由构建方填写，用户对照）

> ★ **2026-09-21 第四轮交付（M 扩展根因修复 + 四步诊断探针）**：RTL 只改 **`rtl/exec/mdu.v`**
> 一处（div_gen 输出字段序：`{余数,商}` → `{商,余数}`，见 §8 —— 这是"上板十进制乱码"的真正根因）；
> 上板程序加了 BUILD 标记 + 步2.5/2.6/2.7 三个探针。**bitstream 已重建 ⇒ md5 变了，必须重下**。
>
> ★ **2026-09-21 第五轮交付（步④ 窗口修正；★★ RTL / bitstream 一律不动 ★★）**：
> 上板实测已确认硬件全部正常（`R2FIX: yes` / `MEXT: OK` / `STACKBF: OK` / `FREQ = 0x01F78A40`，
> 步④ 判据 A：`|8241325 − 8240913| = 412 ≤ 64382` 通过），唯一 BAD 来源是
> **`cycles/iter = 4120` 落在为仿真标定值 59 而设的旧窗口 `[20,300]` 之外** —— 4120 是**真实标定值**
> （真机 SPI Flash XIP 无缓存，每取指走平台 Flash 桥 ≈458 拍/指令）。本轮只改**上板程序**：
> ① 窗口 `[20,300]` → **`[20,20000]`**；② 窗口**降级为信息性**（只打印，不参与 BAD 判定；
> BAD 只由 判据 A + 步⑤ FREQ 锚定 + 三个探针 决定）；③ 步④ 打印文案同步（一行给出两种标定口径）。
> **bitstream 保持 `167dc9dfd487a9d6148ddee02d407726` 不变 ⇒ 本轮只需重烧程序镜像（§6.1）。**

| 项 | 值 |
|---|---|
| 核 RTL 版本 | `rv32gc-cpu`：R2 修复（`rtl/axi/axi_master_ctrl.v` + `rtl/top/core_top.v`）+ **本轮 M 扩展字段序修复**（`rtl/exec/mdu.v`，md5 **`30a1ab7f7ac2432d605baad24d91c504`**）；全 `rtl/**`（`*.v`+`*.vh`）md5 汇总 = **`66e3225645b6f29375c786fe166448d6`**（仅 `*.v` 时 = `ce31b3c8c51fd813c6437ba9af29e54a`） |
| 上板程序源码 | `rv32gc-cpu/sw/m5_board/m5_board.S`（md5 **`ac51c14a823b6dbaf665aae13acc59f0`**） |
| 程序内 BUILD 标记 | **`BUILD=m5_board-diag-2026-09-21d`**（横幅第 2 行；看到它就说明 Flash 里是本轮镜像） |
| 上板时钟口径 | 33 MHz 同域（`clk_pll_33.clk_out1` 留空，`assign cpu_clk = uncore_clk`）；`config.h` `FREQ = 32'd33000000` |
| 器件 / 约束 | `xc7a200tfbg676-2` / `chiplab/fpga/loongson/soc_up.xdc`（板级 100 MHz 输入时钟约束，PLL 派生 33 MHz） |
| **bitstream（本轮，必烧）** | `chiplab/fpga/loongson/2023.2/rv32gc_out/rv32gc_chiplab_soc.bit`（**9 730 756 B**，md5 **`167dc9dfd487a9d6148ddee02d407726`**，2026-09-21 12:36 构建） |
| FPGA 配置 bin（同源） | 同目录 `soc_top.bin`（md5 **`6e57443600cacbfedabf038dda58cc5a`**） |
| **Flash 镜像（诊断版）** | `rv32gc-cpu/sw/m5_board/out/m5_diag.bin`（**2772 B**，md5 **`a91f6f64630237cb1e0f76f2a32c40a9`**；与 `m5_board.bin` 逐字节相同） |
| 仿真加载 hex（同源） | `rv32gc-cpu/sw/m5_board/out/m5_board.hex`（md5 **`26b38763b7e02d8efe638817a04ab911`**） |
| 程序波特率 | 115200 8N1（核内设分频 = 18，实际 114583 Bd） |
| 烧写器波特率 | 230400（`programmer_by_uart.bit`，仅固化 Flash 时用） |
| 时序（33 MHz 约束，布线后，2026-09-21 12:36 重建） | WNS **+0.978 ns** / WHS +0.058 ns / TNS 0 / 失败端点 **0**；`All user specified timing constraints are met` |
| 核级时序（60 MHz = 16.667 ns，核单独综合+布线；**含 mdu 修复后复跑**） | 综合 WNS **+0.556 ns** / TNS 0 / 失败端点 0；布线后 WNS **+0.110 ns**、WHS **+0.066 ns**、失败端点 **0**，`All user specified timing constraints are met`（`fpga/out/{synth,impl}_16.667ns_timing_summary.rpt`） |
| 资源（整片 SoC，含平台，2026-09-21 报告） | Slice LUT 70 232 / 134 600（52.18%）、FF 41 500 / 269 200（15.42%）、BRAM 15.5/365（4.25%）、DSP 34/740（4.59%）；其中核本身 `cpu_mid`(core_top) = **52 643 LUT** / 23 230 FF / 12 BRAM / 34 DSP |
| 本轮可见变化 | ① 横幅第 2 行 = `BUILD=m5_board-diag-2026-09-21d …`；② 新增 `step2.5 DDR3 loopback … R2FIX: …`、`step2.6 MEXT=…`、`step2.7 stack[16B]=…` 三个探针行；③ 十进制/十六进制打印不再依赖 DDR3（纯寄存器路径）；④ 步④ 的 `cycles/iter` 窗口 `[20,300]` → `[20,20000]` 并**降级为信息性**（只打印、不参与 BAD 判定，见 §4 步④）；⑤ 最终判定 = 步④（判据 A：TIMER↔rdcycle 增量一致） ∧ 步⑤ FREQ ∧ 三个探针 |

**历史产物（前三轮，已被上面替换，勿再烧写）**：bitstream md5 `f375baa04d8e495cfbb8c5df2042adf4`（R2 修复版，**没有** M 扩展字段序修复 ⇒ 板子仍会打印 `MEXT: BAD`/乱码）；Flash 镜像 2199 B / md5 `84314223b0c1343ec972e5a1b238cbfe`（第三轮诊断版）；1773 B / md5 `b82be1fc4f67d029232a6409f6941b33`（R2 修复后、无探针的那版程序）；
更早：bitstream md5 `5e3bd4f138d6e408728db3590726bfd1`、`soc_top.bin` md5 `6748db8c9119f60080da5d8324c60a7d`、Flash 镜像 1621 B / md5 `3b60ccac3b227e367eb8497fd66ff024`
（那一版在真实 MIG 下 `.data/.bss` 读回垃圾 ⇒ 十进制打印全乱，见 §5.8 的 R2 说明）。

### 6.1 本轮重烧步骤（★ 本轮**只需换程序镜像**，bitstream 不动）

1. **bitstream（本轮不用动）**：`chiplab/fpga/loongson/2023.2/rv32gc_out/rv32gc_chiplab_soc.bit`
   （md5 `167dc9dfd487a9d6148ddee02d407726`，与上一轮**同一份**）。若板子里已经是在跑的那份
   新 bitstream（步2.5/2.6/2.7 三行都判过），**本轮不要再烧 bitstream**，只做第 2 步。
   （若不确定 FPGA 里是哪份，按 §7.1 核对：Program Device → 确认成功 → 复位。）
2. **程序镜像（本轮唯一要烧的东西）**：按 §3 方式 B（`programmer_by_uart.bit` + xmodem）把 **新的**
   `rv32gc-cpu/sw/m5_board/out/m5_diag.bin`（**2772 B**，md5 **`a91f6f64630237cb1e0f76f2a32c40a9`**）
   写进 Flash 地址 0。**看到 xmodem 完成提示后才算烧成功**。
3. 断电重上电（或按复位键），按 §4 观察；**第一眼看横幅有没有 `BUILD=m5_board-diag-2026-09-21d`，
   第二眼看步2.6 的 `MEXT:`、再看步2.5/2.7 的 `R2FIX:`/`STACKBF:`**。
   本轮**可见变化**：
   - 横幅第 2 行变为 `BUILD=m5_board-diag-2026-09-21d (stack-free prints; R2+MEXT+stack probes; CPI window informational)`；
   - 新增 `step2.5 DDR3 loopback: word=0x12345678 re-read=0x12345678 byte=0x5A (expect 12345678/5A) -> R2FIX: yes`；
   - 新增 `step2.6 MEXT=00000005 00000009 0000003B 00000031 00000000 00000000 0000002A 40000000 FFFFFFFE -> MEXT: OK`；
   - 新增 `step2.7 stack[16B]=30 31 32 33 34 35 36 37 38 39 41 42 43 44 45 46 -> STACKBF: OK`；
   - ★ **步④ 行文案变了**（本轮核心修复）：`cycles/iter` 的健全性窗口从 `[20,300]` 放宽到
     `[20,20000]` 并**降级为信息性**（只打印、不参与 BAD 判定）——
     上板行形如
     `step4 timer delta = 8241325, cycle delta = 8240913, cycles/iter = 4120 (informational only; window 20..20000; board-calib=4120, sim-calib=59 cycles/iter)`；
   - ★ **BAD 判定口径**（本轮起）= **判据 A**（`|Δtimer − Δcycle| ≤ max(256, Δcycle/128)`）
     **∧ 步⑤ FREQ 锚定**（`div1e6 == 33` ∧ `FREQ>>20 == 31`）**∧ 步2.5/2.6/2.7 三个探针**；
     `cycles/iter` 落在窗口外**不再**导致 BAD（只作为"平台差异"信息打印）。

---

## 7. ★ 诊断节：判定 FPGA 里跑的 bitstream 是新还是旧（2026-09-21 诊断版）

> **为什么需要这一节**：上一轮"重烧后现象与修复前逐字相同"的观测，最终由本轮定位为
> **RTL 的 IP 分支缺陷**（`mdu.v` 把 div_gen 的 tdata 字段序写反 ⇒ divu/remu 商余数互换
> ⇒ 十进制打印全乱，见 §8），**与 bitstream 新旧无关**。但"板子里跑的到底是哪份配置"
> 仍必须能被**独立判定**（否则无法排除"配置没换成新的"这一可能）。本节 + 步2.5/2.6/2.7
> 三行探针就是为此设计的：程序自己说出"我读到的 M 扩展 / DDR3 是好的还是垃圾"。

### 7.1 两步走（顺序很重要：先 bitstream，再程序）

| 步 | 动作 | **必须确认的"成功"证据** | 失败长什么样 |
|---|---|---|---|
| ① | Vivado → `Open Hardware Manager` → `Open Target` → `Auto Connect` → `Program Device` → 选 `rv32gc_chiplab_soc.bit` → `Program` | Vivado 的 Tcl Console / 提示框出现 `Programming device ... done` / 进度 100% 且**无 ERROR**；`Hardware` 面板显示 `xc7a200t`；下载后按板载复位键 | 出现 `ERROR`/`IDCODE mismatch`/进度中断 ⇒ JTAG 线/供电问题（§5.2 末行） |
| ①′ | **核对你要下载的 .bit 文件本身**（Windows 侧，可选但推荐）<br>`certutil -hashfile rv32gc_chiplab_soc.bit MD5` | 输出 `167dc9dfd487a9d6148ddee02d407726` | 不是这个值 ⇒ **你手里的文件不是本轮交付的 bitstream**（重新从本仓库拷一份） |
| ② | 烧 `m5_diag.bin`（§3 方式 B：`programmer_by_uart.bit` + xmodem，230400） | 烧写器提示传输完成；之后**回到 115200** 打开串口、按复位 | 传输中断/进度卡住 ⇒ 重来一次；注意"烧写器波特率 230400 ≠ 程序波特率 115200" |
| ③ | 观察串口 | 横幅有 `BUILD=m5_board-diag-2026-09-21d …`；步2.5/2.6/2.7 三行的结论分别是 `R2FIX: yes` / `MEXT: OK` / `STACKBF: OK`；末尾 `RESULT: RV32GC-M5-OK` | 见下表 |

> ⚠️ **顺序建议**：先做 ①（bitstream），确认成功后再做 ②（程序）；反过来也物理可行，但
> 若 ① 失败你会把"旧 bitstream + 新程序"的现象（`R2FIX: no`）误当成"程序的问题"。
> **判据与 bitstream 无关的部分**（`RESULT` 之外的 LED 心跳、文字输出）在两种顺序下都能看。
>
> ⚠️ **"下载成功"不等于"已生效"**：Vivado 里 `Program Device` 必须选**当前**的
> `rv32gc_chiplab_soc.bit`（三份同源副本 md5 都是 `167dc9dfd487a9d6148ddee02d407726`）；
> 下载完成后再**按一次板载复位键**（`resetn = Y3`）；若现象仍如旧，**Ctrl+Shift+P 重新
> `Program Device` 并观察 Tcl Console 的完整输出**，把该输出原文回报。

### 7.2 判别表（把这三行抄回来即可定位）

| 横幅里有 `BUILD=m5_board-diag-2026-09-21d` | 步2.6 的 `MEXT:` | 步2.5 的 `R2FIX:` | 结论 | 下一步 |
|---|---|---|---|---|
| 有 | `ok` | `yes` | ✅ 新程序 + **新 bitstream**（M 扩展字段序修复 + R2 修复都在位） | 看 `RESULT`；若还是 BAD，抄回 step4/step5 原文 |
| 有 | `BAD`（商/余数互换） | 视 bitstream 而定 | ⚠️ 新程序 + **修复前 bitstream** ⇒ FPGA 配置没换成新的（这正是本轮"现象逐字不变"的原因） | 重做 §7.1 ①，**确认 Program Device 成功**；仍为 `BAD` 则把 bitstream 文件 md5 报回来 |
| 有 | `ok` | `no` | ⚠️ 新程序 + **R2 修复前 bitstream**（同一份旧 bitstream 的另一种表现） | 同上：重新下载新 bitstream |
| 没有（横幅是老格式） | 无此行 | 无此行 | ⚠️ Flash 里还是**旧程序** | 重做 §7.1 ② |
| 有 | 无此行 / 卡在 step2 | — | ⚠️ 程序没跑到探针 | 回报 §5.1 必报信息（串口原文 + LED 状态） |

### 7.3 本地（不需要板子）核对"bitstream 是否含修复"

```bash
cd /home/shorthair/dsh/rv32-cpu
# ① bitstream 文件 md5 必须是 167dc9dfd487a9d6148ddee02d407726（本轮，含 M 扩展字段序修复）
#    （上一轮 R2 版 = f375baa04d8e495cfbb8c5df2042adf4 —— 那个版本**没有**本轮修复，别烧错）
md5sum chiplab/fpga/loongson/2023.2/rv32gc_out/rv32gc_chiplab_soc.bit
# ② 构建产物里必须能查到**修复后才有的寄存器** rdata_hold_q（在 axi_master_ctrl 里）：
grep -a -o 'cpu_mid/u_axi_master_ctrl/rdata_hold_q' \
     chiplab/fpga/loongson/2023.2/system_run.runs/impl_1/soc_top_power_routed.rpx | sort -u
#   ⇒ 期望输出：cpu_mid/u_axi_master_ctrl/rdata_hold_q
#     （该寄存器只在 R2 修复后的 axi_master_ctrl.v 里存在 ⇒ 这是"这份实现确实含修复"的内容级证据）
# ③ 构建时间晚于 R2 修复（源码 mtime < 构建日志 mtime）：
stat -c '%y %n' rv32gc-cpu/rtl/axi/axi_master_ctrl.v \
                chiplab/fpga/loongson/2023.2/rv32gc_out/rv32gc_build.vivado.log
# ④ 构建脚本每次都会把 rtl/** 全部读入（不是旧快照）：
grep -n 'add_files' chiplab/fpga/loongson/2023.2/rv32gc_build.tcl     # 逐文件 add_files（路径引用，非拷贝）
grep -n 'reset_run synth_1' chiplab/fpga/loongson/2023.2/rv32gc_build.tcl   # 每次重置综合 ⇒ 重读源文件
grep -a '加入核源文件' chiplab/fpga/loongson/2023.2/rv32gc_out/rv32gc_build.vivado.log
```

> 本节的**本地核查结论**（2026-09-21 实测，证据见交付报告）：
> bit md5 = `f375baa04d8e495cfbb8c5df2042adf4` ✅（**这是上一轮的 R2 版；本轮 M 扩展修复后已重建，
> 新 md5 见 §6 交付表**）；
> `soc_top_power_routed.rpx`（布线后报告，11:12:11）含 `cpu_mid/u_axi_master_ctrl/rdata_hold_q[31]_i_1` ✅；
> RTL 源 mtime 10:19/10:20 < 构建日志 mtime 11:14 ✅；
> `rv32gc_build.tcl` 用 `add_files`（**路径引用**，不拷贝内容）+ `reset_run synth_1`（每次重读源）✅。
> ⇒ 盘上的 bitstream 确实由当时的 RTL 构建而来。
>
> **本轮（含 `mdu.v` 字段序修复）的本地复核**：
> * `rtl/exec/mdu.v` mtime = 2026-09-21 12:06:25 **早于**本轮综合启动时间 12:07:17（`rv32gc_build.vivado.log`）；
> * 构建日志里没有**任何** rtl 源文件晚于综合启动（`find rtl -newermt '2026-09-21 12:07' ` 为空）；
> * 布线后报告仍含 R2 修复的寄存器 `cpu_mid/u_axi_master_ctrl/rdata_hold_q`（12:33 生成）；
> * 新 bitstream md5 = `167dc9dfd487a9d6148ddee02d407726`；时序结论见 §6。
> * 字段序修复本身的功能证据在 **xsim**（真实 IP）：`sw/m5_board/tb/ip/run_mdu_ip_xsim.sh`
>   （修复前 15 条 FAIL、修复后 25/25 PASS），见 §8。

---

## 8. 本轮根因与修复（2026-09-21 · M 扩展 IP 分支：div_gen 字段序）

> **症状回顾**：上板串口"字符串/FREQ 十六进制/LED/开关全部正常，**只有十进制数字乱码**"，
> 且换用含 R2 修复的 bitstream 后**逐字节相同**。

### 8.1 根因（一句话）

`rtl/exec/mdu.v` 的 **IP 分支**（综合用，即板上跑的那一支）把 `div_gen` 的输出
`m_axis_dout_tdata[63:0]` 当成了 `{余数[63:32], 商[31:0]}`；**实测真实 IP 的字段序是
`{商[63:32], 余数[31:0]}`** ⇒ `divu` 返回余数、`remu` 返回商（**商余数互换**）。

* 十进制打印当时靠 `remu/divu` 逐位取数字（`puts_dec`）⇒ 每一位都错 ⇒ 乱码（确定性、可复现）；
* 字符串、`FREQ` 十六进制、LED、开关**都不碰除法** ⇒ 全部正常；
* 本缺陷与 R2（AXI R 数据采样点）**无关** ⇒ 换 R2 版 bitstream 现象不变。

### 8.2 证据链（**仿真闭环，不是推断**）

| # | 证据 | 命令 / 位置 |
|---|---|---|
| ① | 真实 `div_gen` 的输出字段序实测：59/10 ⇒ `tdata=0x00000005_00000009`（高半 = 商 5、低半 = 余数 9）；118049/2000 ⇒ `0x0000003b_00000031` | `bash sw/m5_board/tb/ip/run_ip_div_xsim.sh`（xsim + Vivado 加密 IP 网表） |
| ② | **修复前**：`mdu` 的 IP 分支 25 个向量 **15 条 FAIL**，全部呈"商余数互换"形态（`DIVU 59/10` 读回 `9`、`REMU 59%10` 读回 `5`） | `bash sw/m5_board/tb/ip/run_mdu_ip_xsim.sh --expect-fail` |
| ③ | **修复后**：同一 TB **25/25 PASS** | `bash sw/m5_board/tb/ip/run_mdu_ip_xsim.sh` |
| ④ | 板上可判定：诊断版步2.6 `MEXT:` 行（9 个向量）—— 修复前会打印互换值 | §4 步2.6 |
| ⑤ | 行为分支回归不受影响：`regress.sh` 23/23、arch-test I/F/D/PMP*/Sv 全过 | 见交付报告 |

> 为什么此前没发现：iverilog/Verilator **不能编译 Vivado 加密 IP 网表**（`pragma protect`），
> 历次回归只覆盖 `mdu.v` 的**行为分支**（function 实现，商余数本来是对的）；板子上才是
> **IP 分支**的第一次功能验证。本轮用 **xsim（自带解密密钥）+ 预编译 `unisims_ver` 原语库 +
> `glbl`** 把它拉进了仿真闭环。

### 8.3 修复（`rtl/exec/mdu.v`，**唯一** RTL 改动）

```verilog
// 修复前（错）：按 {余数[63:32], 商[31:0]} 取
wire [32:0] div_rem_next  = {1'b0, ip_div_dout[63:32]};
wire [31:0] div_quot_next = ip_div_dout[31:0];
// 修复后（对）：div_gen 实测字段序 = {商[63:32], 余数[31:0]}
wire [32:0] div_rem_next  = {1'b0, ip_div_dout[31:0]};
wire [31:0] div_quot_next = ip_div_dout[63:32];
```

* 只改**取值方向**与相应注释；握手时序（`ip_div_launch_q` 单拍脉冲发 `tvalid`、FSM 在
  `m_axis_dout_tvalid` 那一拍采 `tdata`）经 xsim 实测**本来是对的**（`start`→`done` 实测 37 拍，
  与 `C_LATENCY=34` + 状态机 2 拍一致）⇒ 没有 off-by-one；
* 行为分支（`ifndef` 区间）**一字未动** ⇒ iverilog 回归语义不变；
* 新 bitstream 的 md5 见 §6 交付表（本轮重建，含该修复）。

### 8.4 用户重烧指引（本轮）

1. **先看步2.6**：`MEXT:` 行 9 个值若与 §4 步2.6 表**逐字相同** ⇒ 板子里已是修复后配置；
   若商/余数互换（`divu(59,10)` 打印 `9`）⇒ 仍是修复前的 bitstream，按 §7.1 重下。
2. **再看步2.5/2.7**：`R2FIX: yes` + `STACKBF: OK` ⇒ DDR3 读通路也正常。
3. 三行都 ok 后，`RESULT: RV32GC-M5-OK` 才算**本轮完整通过**。
3. 三行都 ok 后，`RESULT: RV32GC-M5-OK` 才算**本轮完整通过**。

---

## 9. ★ 引导链（B-3.5）：SPI Flash 引导镜像烧写与上电期望

> **本章适用**：把"复位 → 引导桩 → OpenSBI → U-Boot"这条链跑上板。
> **与 §3/§4 的关系**：§3/§4 用的 `m5_diag.bin`（2.7 KB）是**自检程序**（验证核本身）；
> 本章用的 `spi_flash.img`（≈1 MB）是**真正的引导链镜像**（boot 到 U-Boot）。
> 两者都从 Flash 偏移 0 起烧 ⇒ **同一时刻只能烧一个**。
> **真源**：`sw/boot/README.md`（布局/构建/反证）、`docs/porting/01-overview.md` §2。

### 9.1 镜像布局（`spi_flash.img`，从 Flash 偏移 0 起写）

```
 Flash 偏移        内容                 大小          核看到什么
 0x000000  引导桩 boot_stub.bin          128 B     ← 复位 PC = 0x1C00_0000（XIP 主窗口就地执行）
 0x004000  OpenSBI fw_jump.bin       272 080 B     读出 → 拷到 DDR3 0x0100_0000（M 模式入口）
 0x080000  U-Boot u-boot.bin         398 332 B     读出 → 拷到 DDR3 0x0200_0000（S 模式）
 0x0E8000  U-Boot DTB u-boot.dtb       6 004 B     读出 → 拷到 DDR3 0x0300_0000（= a1）
 0x0E9774  —— 镜像末尾（共 956 276 B）——
```

桩跳转前设置：`a0 = 0`（hartid）、`a1 = 0x0300_0000`（DTB 物理地址）、`a2 = 0`，然后跳到 `0x0100_0000`。
镜像 ≤ 1 MiB 是**硬约束**（核的 XIP 主窗口只有 1 MiB；超出部分会静默落到 DDR3 默认从设备）。

### 9.2 本机构建（WSL；详细命令见 `sw/boot/README.md` §3）

```sh
cd <仓库>/rv32gc-cpu
./sw/boot/build_opensbi_rv32.sh          # ① OpenSBI RV32 FW_JUMP ⇒ OPENSBI_BUILD: OK
./sw/boot/build_spi_image.sh             # ② ⇒ SPI_IMAGE: OK（打印布局表与逐段 md5）
./sw/boot/check_stub_layout.sh           # ③ ⇒ STUB_LAYOUT: OK（桩常量 ⇄ 布局 ⇄ 镜像三方对账）
md5sum sw/boot/out/spi_flash.img         # ④ 记下镜像 md5，烧写后与 §9.5 回报项一致
```

### 9.3 烧写步骤（顺序不能换）

1. **JTAG 下载我们的 bitstream**（按 §3 方式 A）。★ 本章口径：**bitstream 走 JTAG，不固化** ——
   核的 XIP 窗口只映射 Flash 偏移 0 起的 1 MiB，而引导桩必须落在偏移 0；把 FPGA 位流也固化到偏移 0 会与引导镜像**互相覆盖**。
2. 用 Vivado Hardware Manager 下载 **`programmer_by_uart.bit`**（chiplab 官方串口烧写器，不是我们的 bitstream）。
3. 串口改为 **230400 8N1**（烧写器波特率），按提示输入 **`x`** 开始接收 xmodem。
4. 用串口软件的 **xmodem 发送** `sw/boot/out/spi_flash.img`（956 276 B ≈ 1 MB；比 §3 的 2.7 KB 慢，耐心等）。
5. 传输完成后**断电重上电**（或按复位键），把串口改回 **115200 8N1**。
6. 若上电后**没有任何输出** ⇒ 按 §9.5 的 10 项清单回报；**不要**反复乱烧。

### 9.4 上电期望（115200 8N1）

按顺序应看到（时间从复位算起约 1 s 内）：

| # | 期望 | 说明 |
|---|---|---|
| ① | **OpenSBI 横幅**：`OpenSBI v1.9` 与平台名 `Generic`、`Platform Name`、`Firmware Base : 0x1000000` | 说明桩把 OpenSBI 拷到 0x0100_0000 并跳进去了（`fw_jump.bin` 由本机 opensbi 3593a5f 构建） |
| ② | OpenSBI 的域/内存区间打印（`Domain0 Region…`） | generic 平台从 a1 传入的 DTB 发现硬件 |
| ③ | **U-Boot 横幅**：`U-Boot 2026.10-…` + `Model: loongson,chiplab-rv32` + `DRAM:  128 MiB` | M→S 切换成功、U-Boot 在 0x0200_0000 跑起来了 |
| ④ | **U-Boot 提示符 `=>`**（或 `U-Boot>`）出现，可敲 `help` | ★ **本阶段成功的判定行** |
| ⑤ | 可选：`bdinfo`/`version`/`md` 能正常回显 | 串口/SBI 定时器/内存通路正常 |

> **本阶段（B-3.5）验收口径**：看到 **U-Boot 提示符**即可（NAND 读、`saveenv`、`bootcmd` 属 B-4/B-5）。
> OpenSBI 横幅里若报 `Domain0 Next Address`/`Next Arg1` 与本文不符，或卡在 OpenSBI 之后无 U-Boot 输出，按 §9.5 回报。
> **已知前提（务必一起回报）**：33 MHz 同域（`cpu_clk = uncore_clk`）、UART `0x1FE0_01E0` 115200、DDR3 128 MiB、
> SPI XIP 主窗口 `0x1C00_0000`；OpenSBI 平台时钟与 `mtime` 口径按 33 MHz 编译（未在板上实测频率）。

### 9.5 失败时必报的 10 项信息

1. **镜像 md5 与大小**：`md5sum sw/boot/out/spi_flash.img`（应 = 本次交付说明里那个 md5）与烧写器实际发送的文件名/字节数。
2. **bitstream 来源**：`Program Device` 用的 `.bit` 文件路径 + 其 md5（§7.3 的本地核对命令），以及是否最近一次构建。
3. **串口参数与连接**：115200 8N1（含流控设置）、接的是主 UART（`UART_RX=F23`/`UART_TX=H19`）还是 debug UART（`M25`/`P25`）。
4. **完整串口抓包**：从复位（或上电）开始**到现象出现后至少 30 秒**的原始文本（含乱码也要原样贴）。若完全无输出，明确写"0 字节"。
5. **是否见过 OpenSBI 横幅**：见到/未见到；见到的话贴出 `Firmware Base`、`Domain0 Next Address`、`Domain0 Next Arg1` 三行。
6. **是否见过 U-Boot 横幅**：见到/未见到；见到的话贴出第一行（含版本与 Model）。
7. **板级状态**：LED/数码管是否有动静（心跳？常亮？全灭？）；拨码开关位置。
8. **复位方式**：按复位键 / 断电重上电 / 仅 JTAG 重新 Program（三者行为可能不同，务必注明）。
9. **是否重新烧过 Flash**：烧写器版本与波特率、xmodem 是否报错、烧写耗时；有没有在同一片 Flash 上烧过别的镜像（如 §3 的 `m5_diag.bin`）。
10. **本机侧复核结果**（不需要板子，30 秒可跑完，请贴输出）：
    ```sh
    cd <仓库>/rv32gc-cpu
    ./sw/boot/check_stub_layout.sh                 # 期望 STUB_LAYOUT: OK
    md5sum sw/boot/out/spi_flash.img sw/boot/out/boot_stub.bin
    riscv32-unknown-linux-gnu-objdump -d sw/boot/out/boot_stub.elf | head -20   # 入口应为 0x1c000000
    ```

> **回报纪律**：把上述 10 项**一次性**贴给母 Agent（缺项会让定位变成猜谜）。禁止只看"没输出"就去改 RTL/改桩——
> 先分清是"镜像没烧对/没进 FPGA"（第 1/2/9 项）还是"桩跑了但 payload 不对"（第 4/5/6 项）。

