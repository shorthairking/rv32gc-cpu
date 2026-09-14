# 平台硬事实清单（chiplab / 龙芯 Artix-7 实验箱）

> **本文性质**：RV32-GC 新项目（重启版）的**平台事实唯一台账**。
> **引用强度标注约定**（全文强制）：
> - **[RTL 实测]** —— 已直接读取平台源码/约束/脚本并给出行号，可复现核验。
> - **[旧项目转述]** —— 仅来自旧项目 `PROMPT.md` / `AGENT.md` 的口径转述，**未做独立核实**，使用前必须自行核实。
> - **[环境实测]** —— 本次会话内由命令直接观测到的环境事实。
>
> 维护纪律：任何一条事实若从 [旧项目转述] 升级为 [RTL 实测]，必须补 `path:line`；核验失败的条目不删除，改为标注"**已证伪**"并附反证出处。

---

## 1. 核实例化与端口契约

### 1.1 顶层核模块名与例化点

- 平台 SoC 顶层为 `chiplab/chip/soc_demo/loongson/soc_top.v`，其例化的 CPU 核模块名就是 **`core_top`**，实例名 `cpu_mid`。[RTL 实测] `chiplab/chip/soc_demo/loongson/soc_top.v:723`
- 端口连接区间为 `:724-775`，共约 48 个端口，分为四组。[RTL 实测] `chiplab/chip/soc_demo/loongson/soc_top.v:723-775`

  | 组 | 端口 | 出处 |
  |---|---|---|
  | 时钟/复位 | `aclk`、`aresetn` | `soc_top.v:724-727` |
  | 中断 | `intrpt` —— **仅 5 位有效** | `soc_top.v:726` |
  | AXI4 主口（m0_*） | AR/R/AW/W/B 五通道，各带 `id/addr/len/size/burst/lock/cache/prot/valid/ready`（写通道另有 `wstrb`、读通道另有 `resp/last`） | `soc_top.v:729-772` |
  | 调试/提交观测 | `ws_valid`、`break_point`、`infor_flag`、`reg_num`、`rf_rdata`、`debug0_wb_pc`、`debug0_wb_rf_wen`、`debug0_wb_rf_wnum`、`debug0_wb_rf_wdata` | `soc_top.v:774-775` 区间 |
  | 内存图接口 | `infor_flag`/`mem_flag` 一族经 `debug_top` 使用 | `soc_top.v:664-684` |

### 1.2 intrpt 位宽陷阱

- `soc_top.v` 把中断接到核上时是 **`{3'b0, int_out[4:0]}` 共 8 位**，源码注释写死 `//232 only 5bit`，即**平台只提供 5 位中断**。[RTL 实测] `chiplab/chip/soc_demo/loongson/soc_top.v:726`
- 结论：核的 `intrpt` 端口按 8 位声明以对齐平台例化，但**有效中断源只有 `intrpt[4:0]`**；`[7:5]` 恒 0。PMP/PLIC 外部中断的映射只能落在低 5 位内。

### 1.3 端口位宽契约（唯一真源）

- 位宽在 `chiplab/chip/soc_demo/loongson/config.h:46-100` 集中定义。[RTL 实测] `chiplab/chip/soc_demo/loongson/config.h:46-100`

  | 信号 | 位宽 | config.h 行 | 备注 |
  |---|---|---|---|
  | `awaddr`/`araddr` | 32 | `:52`（`Lawaddr 32`）/`:80`（`Laraddr 32`） | 全 32 位地址 |
  | `awid`/`arid`/`bid`/`rid`/`wid` | 4 | `:50`/`:78`/`:72`/`:89` | ID 4 位 |
  | `awlen`/`arlen` | 4 | `:53`/`:81` | **突发 ≤ 16 beat** |
  | `awsize`/`arsize` | 3 | `:54`/`:82` | |
  | `awburst`/`arburst` | 2 | `:55`/`:83` | |
  | `awlock`/`arlock` | 2 | `:56`/`:84` | **核侧只接 `[0:0]`**，见 §1.1 |
  | `awcache`/`arcache` | 4 | `:57`/`:85` | |
  | `awprot`/`arprot` | 3 | `:58`/`:86` | |
  | `wdata`/`rdata` | **32**（默认分支） | `:64-70`/`:92-98` | `AXI128`/`AXI64` 未定义时走 32 位 |
  | `wstrb` | 4 | `:71-77` | 与 `wdata` 联动 |
  | `bresp`/`rresp` | 2 | `:75`/`:99` | |

- **注意**：`lock` 声明为 2 位，但 `soc_top.v` 例化处写作 `m0_awlock[3:0]` / `m0_arlock[3:0]`——这是**平台侧的位选写法**。[RTL 实测] `chiplab/chip/soc_demo/loongson/soc_top.v:735`、`soc_top.v:750`
- 记录口径：`lock` 只接 `[0:0]`（以 config.h 的 2 位定义为准，平台例化取其低位）。**此项曾被旧项目记为"lock 2 位只接 [0:0]"，与 RTL 实测一致，可升级为 [RTL 实测]。**

---

## 2. 地址映射

### 2.1 综合（FPGA）侧 AXI 从设备命中表

`chiplab/IP/AMBA/axi_mux_syn.v` 按 **地址高 16 位** 做译码。[RTL 实测]

| 窗口 | 命中条件 | 行号 |
|---|---|---|
| DDR3（默认从设备） | `wr_addr_hit[0] = ~|wr_addr_hit[4:1]` | `axi_mux_syn.v:860`（写）、`:951`（读） |
| SPI | `awaddr[31:16]==16'h1fe8` | `axi_mux_syn.v:857`（写）/`:948`（读） |
| APB（UART + NAND） | `awaddr[31:16]==16'h1fe0` 或 `16'h1fe7` | `axi_mux_syn.v:858-859` |
| CONF（confreg_syn） | `awaddr[31:16]==16'h1fd0` | `axi_mux_syn.v:860` |
| MAC | `awaddr[31:16]==16'h1ff0` | `axi_mux_syn.v:861` |

- **DDR3 是默认从设备**：`addr_hit[0]` 由其余位的与非生成，故 **`0x0000_0000–0x07FF_FFFF`（128 MiB）落在 DDR3**。[RTL 实测] `chiplab/IP/AMBA/axi_mux_syn.v:860, 951`
- **关键后果**：任何不在上表显式窗口内的地址，都会**静默落到 DDR3**。这包括 `CLINT`/`PLIC` 的候选地址（见 §2.4）。

### 2.2 仿真侧差异

- 仿真 mux `axi_mux_sim.v`：UART 窗口 `16'h1fe0`（`:856`），CONF 窗口同时命中 **`0x1FAF`** 和 `0x1FD0`（`:857-858`）。[RTL 实测] `chiplab/IP/AMBA/axi_mux_sim.v:856-858`
- 结论：**CONFREG 仿真/FPGA 地址不同** —— 仿真 `0x1FAF_0000`，FPGA `0x1FD0_0000`。[RTL 实测] `axi_mux_sim.v:858`、`axi_mux_syn.v:860`

### 2.3 SPI XIP 窗口与别名

- SPI 控制器 `godson_sbridge_spi` 内部对 `buf_addr` 做别名归一：[RTL 实测] `chiplab/IP/SPI/godson_sbridge_spi.v:192-194`

  ```
  buf_addr_t = (buf_addr[31:20]==12'h1fc) ? {12'h0, buf_addr[19:0]}
                                          : { 8'h0, buf_addr[23:0]};
  ```
  → `0x1FCx_xxxx` 与 `0x00Cx_xxxx` 是**同一片窗口的两个别名**。

- `soc_top.v` 例化时传入 `spi_addr = 16'h1fe8`。[RTL 实测] `chiplab/chip/soc_demo/loongson/soc_top.v:1227`
- 因此：**XIP 主窗口 `0x1C00_0000`，别名 `0x1FE8_0000`**，两者指向同一 SPI 存储体。[RTL 实测]（`godson_sbridge_spi.v:192-194` + `soc_top.v:1227`）

### 2.4 核内私有地址（未占用平台通路）

| 设备 | 地址 | 强度 |
|---|---|---|
| CLINT | `0x1F00_0000` | **[旧项目转述]**（用户拍板：不改 SoC 顶层，由核内截获） |
| PLIC | `0x1F10_0000` | **[旧项目转述]**（同上） |
- 这两个地址**不在 §2.1 任何显式窗口内** ⇒ 若无核内截获，AXI 请求会**静默落到 DDR3**。[RTL 实测]（由 `axi_mux_syn.v:860, 951` 的默认分支推出）
- **不确定项**：CLINT/PLIC 的最终基址是否维持该口径，需在实现核内译码时二次确认；平台侧不提供任何 RTL 常量佐证。

### 2.5 外设地址汇总

| 外设 | 地址 | 强度 |
|---|---|---|
| UART | `0x1FE0_01E0` | **[RTL 实测]** `axi_mux_syn.v:858`（`0x1FE0` 窗口）+ [旧项目转述] 窗口内偏移 |
| NAND | `0x1FE7_8000` | **软件侧 [RTL 实测]**：`la32r-Linux/drivers/mtd/nand/raw/ls1a_nand.c:86` `#define _NAND_BASE 0x9fe78000`；`ls1a_nand.c:18` `DMA_ACCESS_ADDR 0x1fe78040` |
| NAND 门铃 / DMA | `0x1FE7_8040` | **[RTL 实测]** `chiplab/IP/APB_DEV/NAND/nand.v:128-129`（`ADDR[10:0]==11'h40`，且 `assign nand_dma_ack_i = ...`） |
| CONFIG 寄存器组 | 仿真 `0x1FAF_0000` / FPGA `0x1FD0_0000` | **[RTL 实测]** `axi_mux_sim.v:858` / `axi_mux_syn.v:860` |
| SPI XIP | `0x1C00_0000`（别名 `0x1FE8_0000`） | **[RTL 实测]** §2.3 |

- **不确定项**：UART/NAND 的**窗口内精确偏移**在平台 RTL 中**不是显式常量**——`axi_mux_syn.v` 只到高 16 位译码，窗口内偏移由 APB 子模块自行截取（`nand.v` 只看 `ADDR[10:0]`，见 §4）。故 UART `0x1FE0_01E0` 的偏移部分依赖软件/旧项目口径，标注为转述成分。

---

## 3. 存储与外设芯片

| 芯片 | 型号 | 容量 | 强度 |
|---|---|---|---|
| NAND Flash | **K9F1G08U0C-PCB0**（Samsung，1 Gbit SLC，3.3 V） | 128 MiB，页 2048+64 B，块 128 KiB，1024 块，**ECC 1 bit/512 B**，ID `EC F1` | **[旧项目转述]**（未独立核实） |
| DDR3 | K4B1G1646G-BCK0 | 128 MiB | **[旧项目转述]**（未独立核实） |
| SPI NOR | S25FL128SAGMFI001 | 16 MiB（DIP 插座，存放 PMON/u-boot） | **[旧项目转述]**（未独立核实） |

- **平台侧佐证**：`soc_top.v` 例化 APB 外设时传入 `nand_type = 2'h2`，注释 `//1Gbit`。[RTL 实测] `chiplab/chip/soc_demo/loongson/soc_top.v:1873`
  → `nand_type=2'h2` 与"1 Gbit 器件"在**容量量级**上自洽，但**不能**证实具体型号、页/块几何或 ECC 要求。
- **不确定项**：`nand_type` 编码与几何（页大小/块大小/地址周期数）的对应表在平台 RTL 中未找到显式文档；`nand_size` 是一个 4 位内部信号（`nand.v:106`），其取值来源需在写驱动前从 `nand.v` 逆向确认。

---

## 4. NAND 控制器（只读分析）

### 4.1 模块与 APB 拓扑

- NAND 控制器：`chiplab/IP/APB_DEV/NAND/nand.v`，模块名 `NAND_top`，1430 行。[RTL 实测] `chiplab/IP/APB_DEV/NAND/nand.v:38`、`wc -l = 1430`
- APB 顶层汇聚：`chiplab/IP/APB_DEV/apb_dev_top_with_nand.v`，模块含 UART0/UART1/NAND 三个 APB 从口；NAND 经 `apb1_*` 一组信号接入。[RTL 实测] `chiplab/IP/APB_DEV/apb_dev_top_with_nand.v:242-249`、`:344-351`、`:383-397`
- `ADDR_APB` 参数默认 **20 位**。[RTL 实测] `apb_dev_top_with_nand.v:119`

### 4.2 寄存器命中（窗口内偏移）

`nand.v` 用 `ADDR[10:0]` 逐 4 字节译码 12 个寄存器 + 1 个门铃。[RTL 实测] `chiplab/IP/APB_DEV/NAND/nand.v:116-129`

| 偏移 | 命中信号 | 行号 |
|---|---|---|
| `0x00` | `HIT0` | `nand.v:116` |
| `0x04` | `HIT1` | `nand.v:117` |
| `0x08` | `HIT2` | `nand.v:118` |
| `0x0C` | `HIT3` | `nand.v:119` |
| `0x10` | `HIT4` | `nand.v:120` |
| `0x14` | `HIT5` | `nand.v:121` |
| `0x18` | `HIT6` | `nand.v:122` |
| `0x1C` | `HIT7` | `nand.v:123` |
| `0x20` | `HIT8` | `nand.v:124` |
| `0x24` | `HIT9` | `nand.v:125` |
| `0x28` | `HIT10` | `nand.v:126` |
| `0x2C` | `HIT11` | `nand.v:127` |
| **`0x40`** | **`NAND_HIT` / DMA 门铃**（`nand_dma_ack_i` 同拍生效） | `nand.v:128-129` |

- 若基址取 `0x1FE7_8000`，则门铃绝对地址 = `0x1FE7_8040`，与软件 `ls1a_nand.c:18` 的 `DMA_ACCESS_ADDR 0x1fe78040` **完全吻合**。[RTL 实测]（`nand.v:128-129` + `ls1a_nand.c:18`）

### 4.3 控制器内部状态（写驱动前必须逆向确认）

- `ADDR_pointer[1:0]`（`nand.v:365`）、`NAND_ADDR_COUNT[2:0]`（`nand.v:367`）、`NAND_ADDR[37:0]`（`nand.v:374`）。
- 命令序列状态：`ADDR_4_RD_WR = 5'b00010`、`ADDR_4_ERASE_ID = 5'b01010`。[RTL 实测] `nand.v:395-396`
- 页/备份区访问由 `main_op` / `spare_op` / `now_up_half` 门控，并按 `NAND_ADDR[8]` 区分半页。[RTL 实测] `nand.v:467-508`
- **不确定项**：HIT0–HIT11 的**逐个寄存器语义**（命令/地址高/地址低/操作数/命令码等）在本次只读分析中未逐条展开；`la32r-Linux/.../ls1a_nand.c` 中有软件侧命名（如 `ls1a_nand.c:60-61` 的 `NAND_ADDRL 0x2`、`NAND_ADDRH 0x4`），但**寄存器全表需专门一轮逆向**后再写入驱动方案。

---

## 5. 时钟与复位

- 板级输入时钟 **100 MHz**，经 `clk_pll_33` 产生两路输出。[RTL 实测] `chiplab/chip/soc_demo/loongson/soc_top.v:1460-1467`
- `clk_out1 = 50 MHz`、`clk_out2 = 33 MHz`。[RTL 实测] `chiplab/IP/xilinx_ip/2023.2/clk_pll_33/clk_pll_33_clk_wiz.v:56-57`（注释 `clk_out1__50.00000`、`clk_out2__33.00000`）
- **本项目实际接线（33 MHz 同域方案）**：
  - `.clk_out1()` **留空**，注释 `// 50MHz 不再使用（33MHz 方案）`；`.clk_out2(uncore_clk)`。[RTL 实测] `soc_top.v:1463-1464`
  - `assign cpu_clk = uncore_clk;` —— CPU 与 uncore **同域，AXI 无 CDC**。[RTL 实测] `soc_top.v:1470-1471`
  - `assign aclk = uncore_clk;`。[RTL 实测] `soc_top.v:1480`
- 软件侧对应：`config.h` 定义 **`FREQ = 32'd33000000`**。[RTL 实测] `chiplab/chip/soc_demo/loongson/config.h:33`
- **说明**：`:1463`/`:1470` 的注释含 `【RV32-GC 33MHz 方案】` 字样，表明**平台 `soc_top.v` 已被本项目改过**——见 §8 的 dirty 快照。
- `clk_pll_1`（`clk_wiz_0`）另出 `clk_out1 = 200 MHz` 供 MIG 参考。[RTL 实测] `soc_top.v:1473-1477`

---

## 6. 约束文件

- 约束文件为 `chiplab/fpga/loongson/soc_up.xdc`。[RTL 实测] `ls chiplab/fpga/loongson/`
- 引脚时钟约束：`set_property PACKAGE_PIN AC19 [get_ports clk]`；`create_clock -period 10.000 -name clk -waveform {0.000 5.000} [get_ports clk]`。[RTL 实测] `chiplab/fpga/loongson/soc_up.xdc:4-6`
  → **主时钟周期 10 ns（100 MHz）**，即约束的是**板级输入时钟**，而非 PLL 后的 33 MHz uncore 域。**派生时钟（33 MHz）是否另有约束需在跑实现时确认**（不确定项）。
- 复位端口 `resetn` 在 `Y3`。[RTL 实测] `soc_up.xdc:9`
- 同目录另有 `2019.2/`、`2023.2/` 两个版本目录与 `Makefile`、`configure.sh`、`testbench/`。[RTL 实测]

---

## 7. 平台不提供的设施

- **平台没有硬件 boot ROM**：`soc_top.v` 全文（`:664-1885` 区段）未见 ROM 例化；DDR3 是默认从设备（§2.1），复位后内容不确定。[RTL 实测] `chiplab/chip/soc_demo/loongson/soc_top.v:664-1885`
- **后果**：上板复位取指必须落在有确定内容的存储体上 ⇒ **`RESET_PC = 0x1C00_0000`（SPI XIP 窗口）**。[旧项目转述]（由 §2.3 + 本节"无 boot ROM"推出）
- **chiplab 仓库不含参考 CPU 核**：`core_top` 只有例化点、无实现体。[RTL 实测]（全树未见 `module core_top`）
- **verilator difftest 依赖 LA32R NEMU** ⇒ 做 RV32 核**必须自建 TB**。[旧项目转述]

---

## 8. chiplab 工作树 dirty 状态快照

采集命令：`git -C chiplab status --porcelain`。[环境实测]

**当前分支**：`chiplab_diff`。[环境实测] `git -C chiplab branch` → `* chiplab_diff`

**已跟踪文件的修改（`M`，共 4 项）**：

| 文件 | 处置 |
|---|---|
| `chip/soc_demo/loongson/soc_top.v` | **modified** —— 含 §5 的 33 MHz 方案改动；**处置：用户已定（2026-09-14），已回退干净基线（见下）** |
| `IP/xilinx_ip/2023.2/axi_clock_converter_0/axi_clock_converter_0.xcix` | modified |
| `IP/xilinx_ip/2023.2/mig_axi_32_loongson/mig_axi_32.xci` | modified |
| `fpga/loongson/2023.2/system_run.xpr` | modified（Vivado 工程文件，工具回写） |

**未跟踪文件（`??`）**：`IP/xilinx_ip/2023.2/axi_2x1_mux/` 下的一批 IP 产物（`.dcp`/`.veo`/`.vho`/`.xml`/`*_clocks.xdc`/`*_ooc.xdc`/`*_sim_netlist.v[hdl]`/`*_stub.v[hdl]`/`doc/`/`hdl/`/`sim/`/`simulation/`/`synth/`）。

**处置口径**：

1. **用户已定（2026-09-14）：chiplab 工作树已回退干净基线** —— HEAD `a2e11b3`，`git status --porcelain` 为 **0 dirty**；原接线 `clk_out1=cpu_clk`(50 MHz)/`clk_out2=uncore_clk`(33 MHz) 已恢复。不采用旧项目任何修改。
   - **沿用提示**：上述「§8 快照」按其采集时点记录，回退后**已不反映当前状态**；当前状态以本条为准。
2. **用户许可**：**本项目可不受限制地按需修改 chiplab**（含 `soc_top.v` 与 `intrpt` 扩展）——原先「不动 chiplab 任何文件」的红线**已由用户裁决解除**。
3. `soc_top.v` 的 33 MHz 改动若后续仍需要，按第 2 条就地修改即可并记录为"平台补丁"。
4. **本节只做快照与登记，不做任何写操作。**

---

## 9. 不确定项清单（写实现前必须关闭）

| # | 不确定项 | 现状 | 关闭方式 |
|---|---|---|---|
| U1 | NAND 窗口内 **HIT0–HIT11 的逐寄存器语义** | 仅知偏移与部分软件命名（`ls1a_nand.c:60-61`） | 专门一轮 `nand.v` 逆向 + 对照 `ls1a_nand.c` 寄存器宏 |
| U2 | `nand_type=2'h2` 对应的**几何参数表**（nand_size 编码） | `nand_size` 为 4 位内部信号（`nand.v:106`），来源未定位 | 逆向 `nand.v` 中 `nand_size` 的赋值链 |
| U3 | **UART 基址偏移** `0x1FE0_01E0` 的平台侧常量出处 | mux 只译到高 16 位；偏移无 RTL 显式常量 | 查 APB 顶层与 UART 模块的 `PADDR` 截取（`apb_dev_top_with_nand.v:364` 用了 `apb_uart0_addr[7:0]`） |
| U4 | **NAND 基址偏移** `0x1FE7_8000` 的平台侧常量出处 | 同上；`nand.v` 只看 `ADDR[10:0]` | 查 APB 顶层的从口译码逻辑 |
| U5 | `intrpt` **仅 [4:0] 有效**时，外部中断如何映射到 mip | 平台 `{3'b0, int_out[4:0]}`（`soc_top.v:726`） | 核内 mip/PLIC 设计时确定映射表 |
| U6 | **Spike 参考模型缺失** | 工作区内无 Spike 源码/二进制 | 重新取源码并编译（见 `docs/kb/tools-and-flow.md`） |
| U7 | `fpga/run_vivado_batch.sh` **尚未创建** | `rv32gc-cpu/fpga/` 目录不存在 | 建统一 Vivado 批处理入口（三坑封装） |
| U8 | CLINT/PLIC 基址（`0x1F00_0000`/`0x1F10_0000`）无平台 RTL 佐证 | 仅有旧项目口径 | 核内译码实现时拍板并写入 `rtl/pkg/*defs.vh` |
| U9 | 33 MHz 派生时钟是否需额外 `create_generated_clock` | `soc_up.xdc` 只有板级 10 ns 约束 | 跑实现后看时序报告/时钟交互报告 |

---

## 10. 使用本清单的纪律

1. 本文任何一条**在写进设计文档前**，若为 [旧项目转述]，必须先尝试升级为 [RTL 实测]；无法升级的，在引用处**保留 [旧项目转述] 标注**。
2. 平台源码**只读**：不得修改 `chiplab/` 下任何文件（含本节提到的 dirty 文件）。
3. 位域/端口契约的唯一真源是 `config.h:46-100`（平台侧）与本项目 `rtl/pkg/*defs.vh`（本项目侧）；两侧改动必须同步。
4. 新增事实一律追加到本文对应小节，**不新建平行清单**，避免口径分叉。
