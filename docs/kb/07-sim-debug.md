# KB-07 仿真与调试

## 1. 仿真环境三条路径

| 路径 | 工具 | 适用 | 说明 |
|---|---|---|---|
| A | **iverilog** | 单元测试、快速回归 | 编译快；不支持 SystemVerilog 断言的部分语法；波形用 VCD |
| B | **Verilator** | 全核/全 SoC、Linux 启动 | 速度快；纯 Verilog 子集；C++ TB 可直接载入 ELF、监视 `tohost` |
| C | **XSim** | 综合后时序仿真 | Vivado 自带，无需安装；速度慢 |

**平台自带流程不可直接用于 RV32**：`sims/verilator/**` 的 difftest 依赖 LA32R NEMU（`toolchains/nemu/la32r-nemu-interpreter-so`，且 `toolchains/` 目录为空），其 `END_PC` 退出机制与 `syscall 0x11` 约定也是 LA32R 专有。

## 2. 本项目自建 TB

```
sim/tb/
├── soc_sim_top.v     # 本核 + AXI 互连 + 内存模型 + CONFREG + UART + NAND 模型
├── axi_mem_model.v   # 行为级内存（支持 INCR 突发，可 load/dump hex）
├── uart_model.v      # 打印到 stdout 与文件
├── nand_model.v      # 行为级 NAND（2048+64 页、128 KiB 块、DMA 引擎模型）
├── tb_iverilog.v     # $readmemh 载入、超时退出、波形
└── tb_verilator.cpp  # ELF 载入、tohost 监视、提交轨迹输出
```

**关键约定**：

| 约定 | 地址/行为 |
|---|---|
| 内存（DDR） | `0x0000_0000`–`0x07FF_FFFF` |
| SRAM | `0x1C00_0000`–`0x1C0F_FFFF` |
| CONFREG（与 FPGA 一致） | `0x1FD0_0000`（LED `+0xF000`、NUM `+0xF010`、TIMER `+0xE000`、DMA 门铃 `+0x1160`） |
| CONFREG（仿真便捷功能） | `0x1FAF_0000`（IO_SIMU `+0xFF00`、VIRTUAL_UART `+0xFF10`） |
| UART | `0x1FE0_01E0`（16550 模型，输出到 stdout） |
| NAND | `0x1FE7_8000` + DMA 门铃 `0x1FD0_1160` |
| **arch-test 内存** | `0x8000_0000` 起 16 MiB 行为级 RAM（`TEST_BASE`） |
| **`tohost`** | `0x8000_1000`：写 1 = 通过、写 3 = 失败 → TB 结束仿真并返回退出码 |
| 退出/打印（裸机） | 写 `0x1FAF_FF00`（退出，值 = 返回码）/ `0x1FAF_FF10`（打印字节） |

## 3. 调试手段

| 手段 | 说明 |
|---|---|
| 提交轨迹（`debug0_wb_*`） | 输出 `pc / wen / wnum / wdata`，与 Spike `--log-commits` 逐条比对 |
| VCD/FST 波形 | iverilog `$dumpfile/$dumpvars`；verilator `--trace`；建议只 dump 出错窗口 |
| 断言 | AXI 协议、ROB/发射队列一致性、Cache 一致性断言（iverilog 支持 `assert` 子集，verilator 支持 `--assert`） |
| 性能计数 | RTL 内建 `mcycle/minstret` + 自定义计数器（分支误预测数、Cache 缺失数、IPC） |
| 上板调试 | 平台 UART 调试单元（`break_point/reg_num/rf_rdata/ws_valid`）+ CONFREG 数码管 + ILA |
| 串口烧写 | 平台 `programmer_by_uart.bit` + xmodem（230400 波特率），见 `chiplab/docs/FPGA_run_linux/flash.md` |

## 4. 波形/日志文件的组织

```
sim/log/<test_name>/
├── sim.log          # 打印输出
├── rtl_trace.log    # 提交轨迹
├── spike.log        # 参考轨迹
├── diff.log         # 比对结果（首个不一致点）
└── wave.fst         # 波形（可选）
```

## 5. 常见问题

| 问题 | 处理 |
|---|---|
| iverilog 报 `Unknown module` | 检查 `-y` 搜索路径与 `` `include `` 顺序；`config.h` 宏需先定义 |
| Verilator 报 unsupported | 改用 `--language 1800-2017`、避免 `initial` 中的复杂语句、检查 Xilinx 原语（本核不使用） |
| 仿真"跑飞" | 先看是否进入 trap 循环（未实现异常处理时会死循环）；检查 `mepc/mcause` |
| 仿真挂起无输出 | UART 模型未连接/波特率分频系数错；或 `tohost` 地址不符 |
| 与上板行为不一致 | 优先检查 CONFREG 地址差异、时钟频率、`FREQ` 宏、非缓存窗口划分 |
