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
