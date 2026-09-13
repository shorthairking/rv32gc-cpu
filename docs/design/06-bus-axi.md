# 总线接口与平台集成设计（AXI4 主设备）

> 上游文档：`00-overview.md`、`03-cache.md`。本文档定义 `core_top` 的对外契约、AXI4 主设备实现、地址解码、跨时钟域与平台集成步骤。
> 平台契约来源：`chiplab/docs/Quick-Start.md`（CPU 接口定义）、`chiplab/chip/soc_demo/loongson/soc_top.v`（FPGA SoC 例化）、`chiplab/IP/AMBA/axi_mux_syn.v`（地址译码）。

---

## 1. `core_top` 对外端口（与平台严格一致）

| 端口 | 方向 | 位宽 | 说明 |
|---|---|---|---|
| `aclk` | I | 1 | CPU 时钟（平台 `clk_pll_33/clk_out1`，默认 50 MHz，本项目改为 100 MHz） |
| `aresetn` | I | 1 | 低有效复位（异步置位、同步释放） |
| `intrpt` | I | 8 | 外部中断线：`[0]`=MAC `[1]`=UART0 `[2]`=SPI `[3]`=NAND `[4]`=DMA，`[7:5]` 未用 |
| `arid/araddr/arlen/arsize/arburst/arlock/arcache/arprot/arvalid/arready` | O/I | 4/32/4/3/2/2/4/3/1/1 | 读地址通道（`arlen` 平台实际为 4 bit，突发 ≤16 beat） |
| `rid/rdata/rresp/rlast/rvalid/rready` | I/I/I/I/I/O | 4/32/2/1/1/1 | 读数据通道 |
| `awid/awaddr/awlen/awsize/awburst/awlock/awcache/awprot/awvalid/awready` | O/I | 4/32/4/3/2/2/4/3/1/1 | 写地址通道 |
| `wid/wdata/wstrb/wlast/wvalid/wready` | O/O/O/O/O/I | 4/32/4/1/1/1 | 写数据通道 |
| `bid/bresp/bvalid/bready` | I/I/I/O | 4/2/1/1 | 写响应通道 |
| `debug0_wb_pc` | O | 32 | 提交指令 PC（difftest） |
| `debug0_wb_rf_wen` | O | 4 | 寄存器写使能（测试平台用 4 bit，本核填 `{3'b0, wen}`） |
| `debug0_wb_rf_wnum` | O | 5 | 目标寄存器号 |
| `debug0_wb_rf_wdata` | O | 32 | 写回数据 |
| `ws_valid` | O | 1 | 写回有效（平台串口调试单元用） |
| `rf_rdata` | O | 32 | 调试读寄存器数据（`reg_num` 指定） |
| `break_point` | I | 1 | 调试断点请求 |
| `infor_flag` | I | 1 | 调试信息标志 |
| `reg_num` | I | 5 | 调试读寄存器号 |

> 与文档的细微差异：`docs/Quick-Start.md` 中的 `arlen/awlen` 写作 `[7:0]`，但所有 SoC 顶层的连线均为 4 bit（`chip/soc_demo/loongson/config.h` 的 `Larlen/Lawlen = 4`）。本设计**声明为 4 bit** 并限制突发 ≤16 beat，两种情形都可正常工作（Verilog 端口位宽不匹配时会自动零扩展/截断，但为避免综合告警，统一按 4 bit 实现）。
> 数据宽度通过 `` `AXI64 ``/`` `AXI128 `` 宏参数化为 64/128 bit，用于兼容平台 `chip/soc_demo/sim` 的 128 bit 仿真 SoC。

## 2. AXI4 主设备实现

### 2.1 总体结构

```
 L1I ──┐
 L1D ──┼──► L2 Cache ──► AXI 桥（读引擎 / 写引擎）
 设备 ──┘        │              │
（非缓存）        │              ├── 读地址 FIFO(8) → AR 通道
                 │              ├── 读数据 FIFO    ← R 通道（按 RID 分发）
                 │              ├── 写地址/数据 FIFO(4) → AW/W 通道
                 └── 写回引擎    └── 写响应         ← B 通道
```

- **读引擎**：把 L2 的行填充请求（32 B = 8 beat）转换为 AXI 突发读；支持最多 8 个未完成突发；按 `RID` 把返回数据分发到对应 MSHR。
- **写引擎**：把脏行写回（8 beat 突发）发送到 AXI；支持最多 4 个未完成写；`B` 响应只做完成记账（错误响应记录到 `mstatus` 无关的错误状态寄存器，并触发可屏蔽的机器级访问错误中断/异常由总线错误路径处理）。
- **设备通道**：非缓存单拍读写，`len=0`、`size` 按访问宽度、`cache=4'b0000`（AXI Device Non-bufferable；平台不解释该位，见 `spec/08-bus-axi.md` §9.5 R1）、`prot` 按特权级/访存类型编码；同一地址保序（简单 in-order 队列）。

### 2.2 AXI ID 分配

| ID | 用途 | 说明 |
|---|---|---|
| `4'd0` | L1I refill | 只读 |
| `4'd1` | L1D refill | 只读 |
| `4'd2` | L1D/L2 写回 | 只写 |
| `4'd3` | 非缓存设备访问 | 读写 |

平台互连（`axi_2x1_mux`/`axi_clock_converter_0`/`axi_slave_mux`）**不解释 cache/prot 位**，全部从设备返回 `resp=2'b00`。为兼容可能的重排，本核不假设响应顺序，一律按 ID 匹配。

### 2.3 突发参数

| 访问类型 | `len` | `size` | `burst` |
|---|---|---|---|
| 32 B 行填充/写回（32 bit 数据宽度） | `4'd7`（8 beat） | `3'b010`（4 B） | `2'b01`（INCR） |
| 32 B 行填充（64 bit 数据宽度） | `4'd3`（4 beat） | `3'b011` | `2'b01` |
| 32 B 行填充（128 bit 数据宽度） | `4'd1`（2 beat） | `3'b100` | `2'b01` |
| 非缓存单拍 | `4'd0` | 按宽度 | `2'b01` |

**约束**：`arlen/awlen ≤ 15`（4 bit 上限），突发不能跨 4 KB 边界（AXI 规定）；32 B 行天然对齐，满足要求。

## 3. 地址解码（核内）

```
               ┌────────────────────────────────────────────┐
  物理地址 ──► │ 1. 核内设备窗口？                            │
               │    0x1F00_0000-0x1F00_FFFF → CLINT（不下总线）│
               │    0x1F10_0000-0x1F1F_FFFF → PLIC（不下总线） │
               ├────────────────────────────────────────────┤
               │ 2. 非缓存设备窗口？                          │
               │    0x1FD0_0000 / 0x1FAF_0000（CONFREG）      │
               │    0x1FE0_0000（UART）/ 0x1FE7_8000（NAND）  │
               │    0x1FE8_0000（SPI）/ 0x1FF0_0000（MAC）    │
               │    → 非缓存通道（单拍、强序、不分配 Cache 行）│
               ├────────────────────────────────────────────┤
               │ 3. 其它 → 可缓存（DDR 0x0000_0000-0x07FF_FFFF│
               │    / SRAM 0x1C00_0000-0x1C0F_FFFF）           │
               └────────────────────────────────────────────┘
```

> `0x1FAF_0000` 与 `0x1FD0_0000` 两个 CONFREG 窗口都按非缓存处理：前者是平台**仿真** SoC（`confreg_sim.v`）的地址，后者是平台 **FPGA** SoC（`confreg_syn.v`）的地址，硬件地址与寄存器偏移都不相同（详见 `../kb/01-platform.md`）。

## 4. 时钟与复位

- **时钟**：CPU 与 CPU 侧 AXI 使用 `cpu_clk`；平台 uncore（DDR/UART/NAND/MAC/CONFREG）使用 33 MHz `aclk`。两者之间已有平台 `axi_clock_converter_0` 完成异步跨时钟域，**本核不需要额外处理 CDC**。
- **升频方法（2026-09-13 依实际 `.xci` 参数修正）**：
  `clk_pll_33` 实为 **PLLE2_ADV**，实测参数为 `PRIM_IN_FREQ=100 MHz`、`DIVCLK_DIVIDE=2`、`CLKFBOUT_MULT_F=33`（→ **VCO = 1650 MHz**）、`CLKOUT0_DIVIDE_F=33`（→ `cpu_clk` = **50 MHz**）、`CLKOUT1_DIVIDE=50`（→ `uncore_clk` = 33 MHz）。因此"CLKOUT2..7 已是 100 MHz"的说法**不成立**（那是未使用输出的默认请求值）。
  可选方案（按推荐度排序）：
  1. **直接用板级 100 MHz 作为 `cpu_clk`**（`clk` 引脚，`soc_up.xdc` 的 `create_clock -period 10.000`）：无需改动时钟 IP，零 IP 风险；代价是 SoC 顶层一行改动（本项目在自有工程中保留该改动，或在本项目副本中实现）；
  2. 把 `CLKOUT0_DIVIDE_F` 由 33 改为 **16.5** → 100 MHz（VCO 不变），需确认 PLLE2 的分数分频被 Vivado 接受；
  3. 用 tcl 重新生成 `clk_pll_33`（`CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {100.000}` + `generate_target`），由向导重算分频比；
  4. 新建一个 `clk_wiz` IP（tcl `create_ip`）专门产生 100 MHz。
  **注意（平台既有风险）**：VCO = 1650 MHz 可能超过 Artix-7 **-2** 的 PLLE2 VCO 上限（约 1600 MHz）；重新生成/校验 IP 时若报 DRC，需按方案 3/4 重算 VCO。
  同时必须把 `chip/soc_demo/loongson/config.h` 的 `` `define FREQ 32'd33000000 `` 与 SoC 中 `CORE_CLOCKS_PER_SEC` 改为**实际频率**（当前值 33 MHz 与 50 MHz 的 `cpu_clk` 已不一致，属平台遗留问题）。
- **复位**：`aresetn` 在 SoC 中由 Xilinx 互连的 `S00_AXI_ARESET_OUT_N` 驱动；核内做 2 级同步后作为内部同步复位。

## 5. 平台集成步骤（Vivado CLI）

平台没有提供 FPGA 工程的 tcl 生成脚本（只有 `fpga/nscscc-team/run_vivado/create_project.tcl` 可作模板），且要求使用 CLI 而非 GUI。因此在阶段五需要新建脚本 `fpga/build_chiplab.tcl`：

1. 复制平台工程（不修改 chiplab 源树）：以 `fpga/loongson/2023.2/system_run.xpr` 为模板，在**本项目目录**下生成 `fpga/vivado/system_run.xpr`（Vivado 2025.2 会就地升级工程格式）；
2. `add_files` 加入本项目 `rtl/**/*.v`（CPU RTL）与 `rtl/pkg/*.svh`；
3. 确认 `top = soc_top`、part = `xc7a200tfbg676-2`、包含 `soc_up.xdc`；
4. `synth_design` → `opt_design` → `place_design` → `route_design` → `write_bitstream`；
5. `report_timing_summary` 检查 WNS（目标 ≥ 0 @ 100 MHz，若不满足按 `01-pipeline.md` §7 降级或降频到 60~75 MHz）；
6. `write_bitstream` 产物复制到 `fpga/bit/` 供上板。

> 由于 `IP/myCPU` 是平台约定的处理器核目录（当前为空子模块），本项目提供 `scripts/install_cpu.sh` 把 `rtl/**` 软链接/复制到 `$CHIPLAB_HOME/IP/myCPU/`，以便复用平台的 verilator 流程。

## 6. 调试接口

| 接口 | 用途 | 实现 |
|---|---|---|
| `break_point` / `reg_num` / `rf_rdata` / `infor_flag` / `ws_valid` | 平台 UART 调试单元（读写寄存器、单步） | 在 RT 级实现：`ws_valid` 在提交一条写寄存器指令时置起；`rf_rdata` 按 `reg_num` 读架构寄存器堆的提交值 |
| `debug0_wb_pc` 等 | 平台 difftest（NEMU 锁步） | 本核直接驱动；但平台 NEMU 仅支持 LA32R，**RV32 不使用平台的 difftest**，改用本项目自建参考模型（见 `08-verification.md`） |
| 内部 trace | 性能分析与调错 | 提交级输出 `{pc, rd, wdata, priv, excp}` 到文件（仿真）/ILA（上板） |

## 7. 与平台 SoC 的边界确认清单（阶段五核对）

- [ ] `core_top` 名字与端口名完全匹配 `chip/soc_demo/loongson/soc_top.v:723` 的例化（含 `ws_valid/break_point/infor_flag/reg_num/rf_rdata`）；
- [ ] AXI 位宽与 `config.h` 的 `Larlen/Lawlen/Lwdata/Lrdata` 一致（默认 4/4/32/32）；
- [ ] 复位极性（低有效）与时序（异步置位/同步释放）；
- [ ] 中断线映射与设备树一致（MAC=1、UART=2、SPI=3、NAND=4、DMA=5 作为 PLIC 源号）；
- [ ] 时序收敛且 `FREQ` 宏与 `cpu_clk` 实际频率一致；
- [ ] 上板后串口有输出、LED/数码管由 CONFREG 正常驱动。
