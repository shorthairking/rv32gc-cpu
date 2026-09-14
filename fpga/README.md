# FPGA 集成目录（Vivado CLI 流程）

> 设计依据：`../docs/design/07-fpga-timing.md`（时序与时钟）、`../docs/design/06-bus-axi.md`（平台集成）。
> 约束文件直接复用平台 `chiplab/fpga/loongson/soc_up.xdc`（任务允许）：`create_clock -period 10.000`，引脚与电平已由平台验证。

## 目录规划

```
fpga/
├── README.md                  # 本文件
├── tcl/
│   ├── create_clk_wiz_cpu.tcl # 【已完成并实测】CPU 时钟 Clocking Wizard（MMCM）
│   ├── build_chiplab.tcl      # (阶段五) 生成工程 + 综合 + 实现 + bitstream
│   └── program_fpga.tcl       # (阶段五) open_hw_manager + program_hw_devices
├── rtl/
│   └── soc_top_rv32gc.v       # (阶段五) 平台 soc_top 的"最小差异副本"
└── bit/                       # (阶段五) 生成的 .bit（不入库）
```

## 1. CPU 时钟（已实现，`tcl/create_clk_wiz_cpu.tcl`）

- **不使用晶振直连**：`cpu_clk` 由 Clocking Wizard IP `clk_wiz_cpu`（**MMCM**）从板级 100 MHz 产生。
- 频率可配：`vivado -mode batch -source tcl/create_clk_wiz_cpu.tcl -tclargs <100|75|60|50>`。
- 实测解（Vivado 2025.2 + `xc7a200tfbg676-2`）：

| 请求 | VCO | 分频 | 实际输出 |
|---|---|---|---|
| **100 MHz（默认）** | 1000.0 MHz | DIVCLK=1, MULT=10.000, CLKOUT0=10.000 | **100.0000 MHz** |
| 75 MHz | 1003.1 MHz | 4 / 40.125 / 13.375 | 75.0000 MHz |
| 60 MHz | 997.5 MHz | 5 / 49.875 / 16.625 | 60.0000 MHz |
| 50 MHz | 1000.0 MHz | 1 / 10.000 / 20.000 | 50.0000 MHz |

- `locked` 输出参与复位门控（锁定后才释放 SoC 复位）。
- 平台 `clk_pll_33` **不改动**：仍用其 `clk_out2` 提供 uncore 33 MHz（DDR/UART/SPI/MAC/CONFREG），`clk_out1` 弃用。

## 2. SoC 顶层（阶段五实现）

平台 `chip/soc_demo/loongson/soc_top.v` 把 `cpu_clk` 硬连到 `clk_pll_33/clk_out1`，因此本项目保留一份**最小差异副本** `rtl/soc_top_rv32gc.v`：**仅**替换时钟块（`clk_wiz_cpu` + `locked` 复位门控）、**仅**把 CPU 例化指向本项目 `core_top`（端口契约不变），其余与平台文件逐行一致。生成工程时用脚本输出与平台原文件的 `diff` 报告（`fpga/diff_vs_platform.txt`），便于复核与后续同步。

## 3. 运行方式（沙箱注意）

```bash
# 本沙箱内 Vivado 无法写 $HOME/.Xilinx，必须把 HOME 指到工作区内目录
export HOME=/home/shorthair/dsh/rv32-cpu/rv32gc-cpu/.vivado_home

# 生成 CPU 时钟 IP（独立验证过，可在任意工程上下文内 source）
vivado -mode batch -nojournal -nolog -source fpga/tcl/create_clk_wiz_cpu.tcl -tclargs 100
```

## 4. 待办（阶段五）

- [ ] `build_chiplab.tcl`：复制/升级平台工程或从零创建，加入 `rtl/**`、`rtl/pkg/*.vh`、`clk_wiz_cpu`、`soc_up.xdc`，设置 `top=soc_top`、`part=xc7a200tfbg676-2`
- [ ] 综合 → 实现 → `report_timing_summary`（WNS ≥ 0 @ 目标频率，否则按 `07-fpga-timing.md` §2 降级）
- [ ] `write_bitstream` + 上板 B1~B8（bring-up 顺序见 `07-fpga-timing.md` §5）
- [ ] `program_fpga.tcl` 下载脚本

---

## 2. 上板前准备清单（阶段 2A，2026-09-13 定稿；**上板动作本身等用户放行**）

### 2.1 CPU 时钟＝33 MHz：**直接取平台 `clk_pll_33` 的 `clk_out2`**（不再新建 IP）

用户第 8 轮拍板上板时钟 33 MHz。**实现方式不是**给核建独立 Clocking Wizard，而是：

```
clk_pll_33 (
  .clk_in1 (clk),          // 板级 100 MHz（soc_up.xdc: create_clock -period 10.000）
  .clk_out1(  ),           // 原 50 MHz（原给 cpu_clk）—— 现在**不用**
  .clk_out2(uncore_clk)    // 33 MHz：uncore（DDR/UART/NAND/SPI/MAC）**并且**给 cpu_clk
);
```

把 `chip/soc_demo/loongson/soc_top.v` 里 CPU 的时钟从 `clk_out1` 改为 `clk_out2`（或把两者接同一网络），
并同步 `chip/soc_demo/loongson/config.h` 的 `FREQ` → **33**。**为什么不用独立 MMCM 精确合成 33 MHz**：
100 MHz 到 33 MHz 没有整数/0.125 步进可精确表示的比（`100×M/DIVCLK = 33×CLKOUT0` 在 VCO 600~1440 内
无精确解，如 VCO=1087.5 → 32.95 MHz，偏差 0.15%）。用平台自己的 `clk_out2`（由平台 PLL 配置生成）
既精确又**让 CPU 与 uncore 同域 ⇒ AXI 全同步、无 CDC**（参考 LA32R 核是 50/33 双域，我们不需要）。
`tcl/create_clk_wiz_cpu.tcl` 保留，供将来要做独立时钟域时用（`-tclargs 33` 会由 Wizard 求解近似值）。

### 2.2 AXI 端口核对（`core_top` ↔ `soc_top` 的 CPU 例化位）

| 方向 | 本核 `rtl/top/core_top.v` | 平台 `soc_top.v` 里 CPU 例化的同名网络 | 备注 |
|---|---|---|---|
| 时钟/复位 | `aclk`, `aresetn` | `cpu_clk`(2.1 后 = clk_out2), `resetn` | 33 MHz 同域 |
| 中断 | `intrpt[7:0]` | `{3'b0, dma_int, nand_int, spi_inta_o, uart0_int, mac_int}` | PLIC 源号固定 1=UART0/2=SPI/3=NAND/4=MAC/5=DMA（与 DTS 一致） |
| 读通道 | `arid/araddr/arlen/arsize/arburst/arlock/arcache/arprot/arvalid/arready` + `rid/rdata/rresp/rlast/rvalid/rready` | 同名 | `arid` 恒 4'b0；取指 8 beat、数据单拍、**行填充 8 beat（ID=1）** |
| 写通道 | `awid/awaddr/awlen/awsize/awburst/awlock/awcache/awprot/awvalid/awready` + `wid/wdata/wstrb/wlast/wvalid/wready` + `bid/bresp/bvalid/bready` | 同名 | L1D 为写直达：每笔 store 一次单拍写 |
| 复位向量 | `-DRESET_PC=32'h1C00_0000`（编译期宏）| — | **必须写 Verilog 字面量**（写 `0x…` 会让 core 报无关语法错） |

核对方法：`grep -n "\.arid\|\.araddr\|\.intrpt\|\.clk" chip/soc_demo/loongson/soc_top.v | head`，
与本表逐行对照；本阶段**不改平台互连编址**（D15）。

### 2.3 BRAM 推断（本次已加属性）

`rtl/frontend/rv32_icache.v` 与 `rtl/mem/rv32_dcache.v` 的 `line_mem`/`tag_mem` 已加
`(* ram_style = "block" *)`（仿真行为不变；`hello`/`DCACHE_UNIT` 复跑仍 PASS）。
综合后请在报告里确认：
```tcl
open_run synth_1 ; report_utilization -hierarchical -file util.rpt
report_cdc -file cdc.rpt          # 33 MHz 同域后应无 CDC 违例
```
判据：`RAMB36/RAMB18` 有明显占用、**`LUTRAM` 里看不到 512×256 的大阵列**（若被推断成分布式 RAM，
LUT 会爆且时序会崩，此时再检查 `ram_style` 是否被综合属性覆盖）。

### 2.4 B1 上板步骤（等用户放行后执行）

1. `vivado -mode batch -source tcl/build_chiplab.tcl`（阶段五待补）→ 综合/实现/生成 bitstream，
   **先看 WNS ≥ 0（33 MHz / 30.303 ns）**；
2. JTAG 下载 bitstream；串口 **115200 8N1** 打开；
3. 烧 `sw/board/out/spi_flash.img`（≤1 MiB，`scripts/pack_boot_image.sh` 产物）到 SPI flash；
4. 复位后**期望**：串口出现 `[RV32-GC] SPI stub at 0x1C000000 … -> jump DDR 0x0`，
   随后 DDR 镜像横幅（B2 阶段才有 U-Boot）；
5. 判据与失败排查见 `../docs/porting/07-board-bringup-plan.md` §3（B1 表）与 §6（风险 R1~R8）。

### 2.5 平台侧改动的幂等脚本

```bash
bash fpga/patch_platform_33mhz.sh            # dry-run：只打印将要做的改动
bash fpga/patch_platform_33mhz.sh --apply    # 实际写入（自动 .bak 备份）
```
脚本做三件事（见 §2.1）：① `soc_top.v` 的 `clk_pll_33` 不再用 `clk_out1(50MHz)`；
② 加 `assign cpu_clk = uncore_clk;`（33 MHz 同域）；③ `config.h` 的 `FREQ` → 33。
**上板动作（综合/下载/烧写）按用户要求等审阅放行后执行**；脚本本身可随时 dry-run 自检。

### 2.6 仍待补的上板前准备（不需要板子，但需要跑 Vivado/改平台副本）

1. `fpga/rtl/soc_top_rv32gc.v`：平台 `soc_top.v`（1788 行）的**最小差异副本** —— 把 LA32R 核例化
   换成我们的 `core_top`（端口对照表见 §2.2），其余互连/时钟/DDR/UART/NAND/SPI 原样保留。
2. `fpga/tcl/build_chiplab.tcl`：`create_project`（part `xc7a200tfbg676-2`）→ 加平台 RTL + `soc_top_rv32gc.v`
   + 本仓库 `rtl/**` + `soc_up.xdc` → `synth_1`/`impl_1` → `report_utilization`/`report_timing_summary`/
   `report_cdc` → `write_bitstream`。
3. `fpga/tcl/program_fpga.tcl`：`open_hw_manager` + `program_hw_devices`（下载线）。
4. 综合后复核 §2.3 的两条判据（WNS ≥ 0 @33 MHz；BRAM 推断正确），把结果写回 `docs/porting/07-board-bringup-plan.md` §11.2。

### 2.7 Vivado 2023.2 在本机跑批处理（2026-09-14 实测，**必读**）

本机是 WSL2 + **Ubuntu 24.04**，Vivado 用 **2023.2**：`/home/shorthair/fpga/Vivado/2023.2`
（`~/.bashrc:149` 已 source 其 `settings64.sh`）。**必须用 2023.2**：平台工程是用 2023.2 建的，
含 `xilinx.com:ip:axi_interconnect:1.7`（`axi_2x1_mux`、`axi_interconnect_0`）；2025.2 的 IP 目录里
已无 1.7 版本 ⇒ IP 被锁、`No upgrade is available`、无 OOC run ⇒ 顶层综合报
`[Synth 8-439] module 'axi_2x1_mux' not found`（本项目第 21 轮实测）。

统一入口（下面三个绕过都封装好了）：

```bash
bash fpga/run_vivado_batch.sh <script.tcl> [tclargs...]
# 例：整板综合+实现+bitstream
bash fpga/run_vivado_batch.sh fpga/tcl/build_chiplab.tcl \
     /home/shorthair/dsh/rv32-cpu/chiplab /home/shorthair/dsh/rv32-cpu/rv32gc-cpu \
     /home/shorthair/dsh/rv32-cpu/chiplab/fpga/loongson/2023.2/system_run.xpr \
     /home/shorthair/dsh/rv32-cpu/rv32gc-cpu/fpga/out/board_2023 8
```

三个必做绕过（缺一个都跑不起来，均已固化进 `run_vivado_batch.sh` / 两个 tcl）：

| # | 现象（本机实测） | 绕过 |
|---|---|---|
| ① | `couldn't load file "librdi_commontasks.so": libtinfo.so.5: cannot open shared object file` —— Vivado 自带依赖目录只有 `Ubuntu/{18,20,22}`、`Rhel/{8,9}`、`SuSE`，加载器按发行版找不到 `Ubuntu/24` | `export LD_LIBRARY_PATH=$VIVADO_ROOT/lib/lnx64.o/Rhel/9:$LD_LIBRARY_PATH`（该目录**只有** libtinfo.so.5，不会覆盖其它系统库） |
| ② | `CRITICAL WARNING [filemgmt 20-730] Could not find a top module in the fileset sources_1`，随后 `ERROR [Common 17-53] Unable to launch Synthesis run. No Verilog or VHDL sources found in project`。**根因是工程模式的自动层次引擎在本机失效**：连 `module foo(input a, output b); …` 的平凡工程也报同样错，同一台机上**非工程模式**`read_verilog`+`synth_design` 完全正常（`xvlog` 单独跑也正常） | 打开/新建工程后立刻 `set_property source_mgmt_mode None [current_project]`（Manual Compile Order），并**显式**再设一次 `set_property top <top> [current_fileset]`；否则 top 会被判 "can not be validated" 并清空 |
| ③ | 沙箱下 `~/.Xilinx` 不可写 ⇒ `Failed to create directory to save app.xml` | `HOME=<工作区>/rv32gc-cpu/.vivado_home`（已 gitignore；包装脚本默认即此） |

平台被工具链改脏后的**回退到初始状态**（第 25 轮用户要求的口径）：

```bash
git -C ../chiplab checkout -- . && git -C ../chiplab clean -xdf   # 撤掉 2025.2 升级过的 .xci、生成产物、工程 runs
bash fpga/patch_platform_33mhz.sh --apply                        # 再打 33 MHz 补丁（只动 soc_top.v 4 行）
```

实测日志口径：`fpga/out/board_2023.log`（整板）、`fpga/out/core_only_2023.log`（核级）。

