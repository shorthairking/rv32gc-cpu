# FPGA 集成、时序与上板计划

> 上游文档：`00-overview.md`、`06-bus-axi.md`。目标器件：`xc7a200tfbg676-2`（Artix-7，134 600 LUT / 269 200 FF / 13 140 Kb BRAM / 740 DSP48E1）。工具：Vivado 2025.2（CLI）。

---

## 1. 平台资源与时钟现状

| 项目 | 现状 | 本项目动作 |
|---|---|---|
| 板级输入时钟 | 100 MHz（`soc_up.xdc`：`create_clock -period 10.000`，引脚 AC19） | 不改 |
| `clk_pll_33/clk_out1` → `cpu_clk` | 50 MHz（平台现状，CPU 与 CPU 侧 AXI） | **改用新增的 Clocking Wizard IP `clk_wiz_cpu`（MMCM）产生**：默认 100 MHz，可按 `CPU_CLK_MHZ` 配置为 50/60/75/100；平台 `clk_pll_33` 仅保留 `clk_out2` 供给 uncore（见 §1.1） |
| `clk_pll_33/clk_out2` → `uncore_clk` = `aclk` | 33 MHz（平台 AXI：DDR/UART/NAND/MAC/CONFREG） | 不改 |
| `clk_wiz_0/clk_out1` | 200 MHz（DDR MIG 参考） | 不改 |
| MIG `ui_clk` | 100 MHz | 不改 |
| 跨时钟域 | 平台已有 `axi_clock_converter_0`（cpu_clk→aclk） | 不改，直接复用 |
| 约束文件 | `fpga/loongson/soc_up.xdc` | 复用；本项目另外补充 CPU 内部时序例外（如需要） |
| 工程 | `fpga/loongson/{2019.2,2023.2}/system_run.xpr`，part/top 正确，但**不含 CPU 源文件** | 用 tcl 在本项目目录生成可复现工程并加入 `rtl/**`、`IP/myCPU/**` |

> 注意：`chip/soc_demo/loongson/config.h` 的 `` `define FREQ 32'd33000000 `` 与实际 `cpu_clk`（50 MHz）不一致（平台遗留）。升频时必须把它改成真实频率，否则 CONFREG 的计时/仿真退出行为会错。

---

### 1.1 CPU 时钟产生方案（2026-09-13 依用户要求确定）

> **要求**：`cpu_clk` **不得**直接使用晶振输入，必须经 Vivado **Clocking Wizard（MMCM/PLL）**产生，以获得稳定、可控、带锁定指示的时钟。

**主方案（采用）**

| 项 | 取值 |
|---|---|
| 新 IP | `clk_wiz_cpu`（Clocking Wizard，**MMCM** 原语；由 tcl `create_ip -name clk_wiz` 生成，参数可由脚本写入） |
| 输入 | 板级 `clk` = 100 MHz（引脚 AC19，`soc_up.xdc` 已 `create_clock -period 10.000`） |
| 输出 1 | `clk_out1` = **`cpu_clk`**，默认 **100.000 MHz**（`CPU_CLK_MHZ` 可配 50/60/75/100，用于 §2 降级） |
| 输出 2 | `clk_out2` = 50.000 MHz（可选，用于与平台原 50 MHz 基线做 A/B 对比） |
| MMCM 参数 | 由 Wizard **自动求解**（`PRIM_IN_FREQ=100` + `CLKOUT1_REQUESTED_OUT_FREQ=<CPU_CLK_MHZ>`），实测解如下表；VCO 均落在 Artix-7 **-2** 允许的 600~1440 MHz 内 |
| 生成脚本 | `fpga/tcl/create_clk_wiz_cpu.tcl`（`vivado -mode batch -source … -tclargs <100\|75\|60\|50>`；已在本机 Vivado 2025.2 + `xc7a200tfbg676-2` 实测通过） |
| 锁定 | `locked` 输出与外部 `resetn` 相与，作为 SoC 内部复位（**时钟锁定后才释放复位**） |
| 未改动的部分 | `uncore_clk`（33 MHz）继续由平台 `clk_pll_33/clk_out2` 提供（该 33 MHz 已被 DDR/UART/SPI/MAC 验证）；`clk_pll_33/clk_out1` 不再使用 |
**实测时钟解（Vivado 2025.2 + xc7a200tfbg676-2，`fpga/tcl/create_clk_wiz_cpu.tcl` 生成）**

| 请求 | VCO | DIVCLK | MULT | CLKOUT0_DIV | 实际输出 | 是否在 -2 允许范围 |
|---|---|---|---|---|---|---|
| **100 MHz（默认）** | 1000.0 MHz | 1 | 10.000 | 10.000 | **100.0000 MHz** | ✅ |
| 75 MHz（降级档） | 1003.1 MHz | 4 | 40.125 | 13.375 | 75.0000 MHz | ✅ |
| 60 MHz（保底档） | 997.5 MHz | 5 | 49.875 | 16.625 | 60.0000 MHz | ✅ |
| 50 MHz（基线对比档） | 1000.0 MHz | 1 | 10.000 | 20.000 | 50.0000 MHz | ✅ |

> 说明：Wizard 在自动求解模式下会把 `MMCM_CLKFBOUT_MULT_F`/`MMCM_CLKOUT0_DIVIDE_F` 置为 disabled，**不要**显式写入这两个参数（会被忽略并产生 `IP_Flow 19-3374` 警告）；只需给出输入频率与目标输出频率，然后读回实际解核对（脚本已内建 VCO 范围检查）。

| CDC | `cpu_clk`（新 MMCM）与 `uncore_clk`（平台 PLL）为**异步时钟**，两域之间已有平台 `axi_clock_converter_0`（异步 FIFO），无需核内处理 |

**SoC 顶层处理**：平台 `chip/soc_demo/loongson/soc_top.v` 的时钟块把 `cpu_clk` 硬连到 `clk_pll_33/clk_out1`，因此本项目保留一份**最小差异副本** `fpga/rtl/soc_top_rv32gc.v`：**仅**替换时钟块（例化 `clk_wiz_cpu` + `locked` 复位门控）、**仅**把 CPU 例化替换为本项目 `core_top`（端口契约不变），其余与平台文件逐行一致，并在 `fpga/README.md` 中给出与平台原文件的 `diff` 说明以便复核与同步。

**备选方案**（若希望零 RTL 改动）：把平台 `clk_pll_33.xci` 复制到本项目并改为 MMCM、同时输出 100 MHz 与 uncore 时钟，**模块名与端口名保持不变**（`clk_out1`/`clk_out2`/`clk_in1`），这样平台 `soc_top.v` 无需任何修改。代价：一个 MMCM 同时产生 100 MHz 与 33 MHz 时，33 MHz 只能取 `VCO/36.375 = 32.99 MHz`（偏差 0.03%，UART 波特率误差 0.03%，无功能影响）。

**平台既有疑点**：现 `clk_pll_33` 为 PLLE2_ADV，`DIVCLK_DIVIDE=2`、`CLKFBOUT_MULT_F=33` → **VCO = 1650 MHz**，可能超过 Artix-7 **-2** 的 PLLE2 VCO 上限（约 1600 MHz）。本项目不改动它（仅用其 33 MHz 输出），但**在阶段五首次综合时用 `report_clocks` / DRC 报告核实**；若报错则按备选方案重新生成。

## 2. 频率目标与降级策略

| 档位 | `cpu_clk` | 说明 |
|---|---|---|
| 目标 | **100 MHz** | 任务目标；4 发射乱序核按 10 ns 关键路径设计 |
| 保底 | **60 MHz** | 任务硬性下限；若 100 MHz 时序不收敛则先交付此档 |
| 回退 | 75 MHz | 中间档，用于定位是"局部路径"还是"结构性问题" |

**降级顺序**（每步保持功能正确，仅影响 IPC；**交付目标始终是 4 发射**，第 3 步改变需求指标，须先报告用户并获得同意）：
1. 发射队列选择器改为两周期分级选择；
2. L2 访问增加一级流水；
3. `CORE_WIDTH` 由 4 降为 2（双发射）——**最后手段，需用户批准**；
4. 降低 `cpu_clk` 到 75/60 MHz。

---

## 3. 关键路径与收敛措施

见 `01-pipeline.md` §7 的时序预算表。补充 FPGA 层面的具体措施：

| 路径 | 措施 |
|---|---|
| PC → BTB → PC 选择 | BTB 用分布式 RAM（LUTRAM）实现，读地址寄存器化；预测结果打一拍供 IF1 使用 |
| I-Cache Tag 比较 | Tag BRAM 输出直接进比较器，比较结果与 way 选择在同一级完成；避免 4 路 × 22 bit 的大扇出 |
| 重命名 RAT 读写 | RAT 用 FF 实现（32 项），读用 8 个并行 32:1 MUX（LUT6 树），写为 4 路译码写；避免用 BRAM（读改写冲突） |
| 发射选择 | 每队列独立的 age matrix + 优先编码器；`ready` 位先做"就绪压缩"再进矩阵，缩短关键路径 |
| PRF 读 | 按 Bank 拆分（2 Bank × 4 读口），发射级读、EX 级用；写口 ≥2 Bank |
| ALU/旁路 | 旁路 MUX 用 4:1 一级实现；加法器交给综合映射到 Carry4 |
| DTLB + D-Cache | TLB 与 Cache 并行查询（VIPT），比较树两级；物理地址选择在 MEM 级完成 |
| FPU | FMA 的"对齐移位 + 尾数加 + 前导零预测 + 规格化 + 舍入"分成 2~3 级流水；FDIV 迭代路径寄存器化 |
| L2 → AXI | L2 仲裁与 AXI 桥各自独立状态机，接口全部打拍 |
| 全局 | 综合选项 `-flatten_hierarchy rebuilt`、`-retiming on`；对高扇出网（flush/wakeup/clock enable）用 `max_fanout` 约束 + 手工复制 |

**综合脚本中的约束建议**：
```tcl
# 主时钟（来自平台 xdc，已存在）
create_clock -period 10.000 -name clk [get_ports clk]
# CPU 时钟域由 PLL 产生，MMCM/PLL 自动推导；如需显式约束：
# cpu_clk 由 clk_wiz_cpu（MMCM）产生，Vivado 会自动推导生成时钟；
# 如必须手工约束（例如 IP 被 black-box 化）：
# create_generated_clock -name cpu_clk -source [get_pins clk_wiz_cpu/inst/mmcm_adv_inst/CLKIN1] \
#     -divide_by 12 -multiply_by 12 [get_pins clk_wiz_cpu/inst/mmcm_adv_inst/CLKOUT0]
set_clock_groups -asynchronous -group [get_clocks cpu_clk] -group [get_clocks uncore_clk]
set_max_fanout 64 [current_design]
```

---

## 4. 资源预算（4 发射配置）

| 资源 | 预算 | 器件容量 | 占比 |
|---|---|---|---|
| LUT | ~39 K | 134 600 | 29% |
| FF | ~47 K | 269 200 | 18% |
| BRAM (36 Kb) | ~90 | 365 | 25% |
| DSP48E1 | 8~12（乘法/浮点尾数乘） | 740 | 2% |

余量充足；若综合后 LUT 超过 60%，优先削减 L2 容量（256 KB → 128 KB）与发射队列深度。

---

## 5. 上板 bring-up 顺序（逐级验证，每级都有明确通过标准）

| 步骤 | 内容 | 通过标准 |
|---|---|---|
| B0 | 复现平台原始工程：用平台 LA32R 参考核（可选，若能取得 `open-la500`）综合出 bit，上板跑通 UART | 证明工程/工具链/板卡正常 |
| B1 | 综合本项目 CPU（无 Cache 简化配置）+ CONFREG 测试程序 | 串口打印 "RV32GC boot"，数码管显示预期值 |
| B2 | 完整核 + UART 打印 + 内存测试（DDR 读写校验） | 128 MiB DDR 校验通过（含非对齐/字/半字） |
| B3 | 裸机功能测试集（`sw/tests/`）+ arch-test 子集 | 全部用例通过（通过标志写 CONFREG + 串口打印） |
| B4 | NAND 读写测试（裸机，使用平台 DMA 引擎） | 擦/写/读回校验通过（含 cache 维护验证） |
| B5 | U-Boot 启动 | 串口出现 U-Boot 提示符，`nand info` 能识别 128 MiB NAND |
| B6 | U-Boot 从 NAND 读取内核并启动 | Linux 内核打印到 shell（initramfs） |
| B7 | U-Boot 写 NAND（`nand write`/`mtd`）与环境变量保存 | 断电重启后配置保留，内核可再次从 NAND 启动 |
| B8 | 性能测试：CoreMark/Dhrystone/unixbench | 记录分数，作为频率/IPC 优化基线 |

**上板工具链**：
- 综合：`vivado -mode batch -source fpga/build_chiplab.tcl`
- 下载：`vivado -mode batch -source fpga/program_fpga.tcl`（`open_hw_manager` + `program_hw_devices`）
- 串口：`minicom`/`picocom`，115200 8N1（U-Boot/Linux），平台串口烧写 bit 时为 230400
- SPI Flash 烧写（PMON/uboot 备份路径）：平台自带的 `programmer_by_uart.bit` + xmodem（见 `chiplab/docs/FPGA_run_linux/flash.md`）

---

## 6. 已知风险与检查项

| 风险 | 检查方式 | 应对 |
|---|---|---|
| Vivado 2025.2 无法直接打开 2023.2 工程 | 先在本项目目录复制工程再打开 | 或用 `create_project` 全新生成（更可控，推荐） |
| 许可限制（`Tool Version Limit: 2025.11`） | `vivado -version` 与综合日志 | 若受限，改用平台 2023.2 工程 + 对应版本 Vivado |
| 50→100 MHz 升频后 CPU 侧 AXI 时序不收敛 | 综合报告 WNS | 按 §2 降级 |
| NAND 控制器在 bit 流中是否使能 | 检查 `soc_top` 中 `apb_dev_top_with_nand` 的选择与 `nand_type` | 仿真阶段先用 `apb_dev_top_no_nand` 验证其余功能 |
| CONFREG 地址/偏移仿真与 FPGA 不一致 | 分别读取 `confreg_sim.v`/`confreg_syn.v` 的 `define` | 软硬件地址由设备树/配置宏区分（见 `../kb/01-platform.md`） |
| 硬件 ECC 语义未知 | NAND 读写校验测试 | 先用软件 BCH ECC |
