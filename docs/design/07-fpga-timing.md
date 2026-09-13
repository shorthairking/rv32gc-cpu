# FPGA 集成、时序与上板计划

> 上游文档：`00-overview.md`、`06-bus-axi.md`。目标器件：`xc7a200tfbg676-2`（Artix-7，134 600 LUT / 269 200 FF / 13 140 Kb BRAM / 740 DSP48E1）。工具：Vivado 2025.2（CLI）。

---

## 1. 平台资源与时钟现状

| 项目 | 现状 | 本项目动作 |
|---|---|---|
| 板级输入时钟 | 100 MHz（`soc_up.xdc`：`create_clock -period 10.000`，引脚 AC19） | 不改 |
| `clk_pll_33/clk_out1` → `cpu_clk` | **50 MHz**（CPU 与 CPU 侧 AXI） | 改为 **100 MHz** 作为目标；保留 60/75 MHz 作为回退档 |
| `clk_pll_33/clk_out2` → `uncore_clk` = `aclk` | 33 MHz（平台 AXI：DDR/UART/NAND/MAC/CONFREG） | 不改 |
| `clk_wiz_0/clk_out1` | 200 MHz（DDR MIG 参考） | 不改 |
| MIG `ui_clk` | 100 MHz | 不改 |
| 跨时钟域 | 平台已有 `axi_clock_converter_0`（cpu_clk→aclk） | 不改，直接复用 |
| 约束文件 | `fpga/loongson/soc_up.xdc` | 复用；本项目另外补充 CPU 内部时序例外（如需要） |
| 工程 | `fpga/loongson/{2019.2,2023.2}/system_run.xpr`，part/top 正确，但**不含 CPU 源文件** | 用 tcl 在本项目目录生成可复现工程并加入 `rtl/**`、`IP/myCPU/**` |

> 注意：`chip/soc_demo/loongson/config.h` 的 `` `define FREQ 32'd33000000 `` 与实际 `cpu_clk`（50 MHz）不一致（平台遗留）。升频时必须把它改成真实频率，否则 CONFREG 的计时/仿真退出行为会错。

---

## 2. 频率目标与降级策略

| 档位 | `cpu_clk` | 说明 |
|---|---|---|
| 目标 | **100 MHz** | 任务目标；4 发射乱序核按 10 ns 关键路径设计 |
| 保底 | **60 MHz** | 任务硬性下限；若 100 MHz 时序不收敛则先交付此档 |
| 回退 | 75 MHz | 中间档，用于定位是"局部路径"还是"结构性问题" |

**降级顺序**（每步保持功能正确，仅影响 IPC）：
1. 发射队列选择器改为两周期分级选择；
2. L2 访问增加一级流水；
3. `CORE_WIDTH` 由 4 降为 2（双发射）；
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
create_generated_clock -name cpu_clk -source [get_pins clk_pll_33/inst/clk_in1] \
    -divide_by 1 -multiply_by 10 [get_pins clk_pll_33/inst/clk_out1]
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
