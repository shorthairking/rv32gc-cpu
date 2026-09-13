# RV32-GC CPU 及其配套软硬件（chiplab / 龙芯实验箱）

本仓库是"基于 RV32-GC 指令集的 CPU + U-Boot/Linux 移植"项目的**唯一交付仓库**：设计文档、RTL、仿真环境、软件移植与构建脚本都在这里，独立于工作区中的上游源码树（`chiplab`、`la32r-uboot`、`la32r-Linux` 等）。

## 目标（一句话）

在 chiplab（龙芯 FPGA 实验箱，`xc7a200tfbg676-2`）上实现一颗 **4 发射乱序 RV32-GC 处理器**，并完成 **OpenSBI + U-Boot + Linux + 根文件系统**的移植，最终**从 NAND 自动启动 Linux**。

## 当前状态

| 阶段 | 内容 | 状态 |
|---|---|---|
| 一 | 设计方案 + 移植方案 + 知识库 + AGENT/PROMPT | ✅ 已完成，等待用户审阅 |
| 2A | 顺序 5 级基线核（RV32GC + CSR + Cache + AXI + 上板） | ⏳ 待启动 |
| 2B | 4 发射乱序后端（ROB/重命名/发射队列/LSQ/锦标赛预测器） | ⏳ |
| 2C | 存储与特权完善 + Linux 启动 | ⏳ |
| 三 | U-Boot 移植（含 NAND 驱动，从 NAND 启动） | ⏳ |
| 四 | Linux 内核与驱动移植 | ⏳ |
| 五 | 根文件系统（initramfs/UBIFS）与验收 | ⏳ |

## 目录结构

```
rv32gc-cpu/
├── AGENT.md              # 总纲：阶段计划、决策记录、进度台账、阶段交接规则
├── PROMPT.md             # 指导 AI 完成整个项目的提示词（新会话入口）
├── README.md             # 本文件
├── docs/
│   ├── design/           # 微架构设计（9 篇）+ diagrams/*.dot|svg（结构图/数据通路图）
│   ├── porting/          # U-Boot/Linux/驱动/NAND/根文件系统 移植方案（6 篇）
│   ├── kb/               # 移植知识库（7 篇，已注册进常驻知识库供 kb_search 检索）
│   └── reports/          # 平台/上游源码详查报告（4 份，供追溯细节）
├── rtl/                  # (阶段二) CPU RTL：top/frontend/decode/rename/issue/exec/mem/mmu/csr/bus
├── sim/                  # (阶段二) 测试平台：tb/、tests/、log/
├── sw/                   # (阶段三~五) uboot/ linux/ opensbi/ rootfs/ 的补丁、新增文件与构建脚本
├── fpga/                 # (阶段二/五) Vivado tcl 脚本与 bit 流
└── scripts/              # 回归、安装 CPU 到平台、辅助脚本
```

## 快速开始

```bash
# 1) 阅读总纲与提示词
less AGENT.md          # 阶段计划、决策、当前状态与下一阶段任务
less PROMPT.md         # 交给 AI 的项目提示词

# 2) 阅读设计（先看总体架构）
less docs/design/00-overview.md

# 3) 环境准备（阶段二前）
sudo apt install verilator iverilog gtkwave     # 需在沙箱外执行

# 4) 检索知识（会话内）
kb_search "NAND DMA 门铃 描述符"
kb_search "CONFREG 地址 仿真 FPGA 差异"
```

## 关键设计参数

| 项 | 取值 |
|---|---|
| ISA | RV32IMAFDC + Zicsr/Zifencei/Zicntr/Zicbom，M/S/U，Sv32，PMP 16 项 |
| 发射/提交宽度 | 4 / 4 |
| 流水级 | IF0/IF1/IF2/ID/RN/DP/IS/EX/MEM/WB/RT（11 级，浮点更深） |
| 乱序结构 | ROB 128 + RAT/空闲表/4 checkpoint + 发射队列(32/24/16) + LSQ(32+32) + PRF(128×32/128×64) |
| 分支预测 | 锦标赛：Gshare 4096 + 局部(1024 历史 + 4096 计数) + 选择器 4096；BTB 512×4；RAS 32 |
| Cache | L1I 16 KB 4 路 / L1D 32 KB 8 路 / L2 256 KB 8 路，行 32 B，VIPT 别名安全 |
| 总线 | AXI4 主设备，32 bit 数据（可参数化 64/128）、4 bit ID、突发 ≤16 beat |
| 中断/定时器 | 核内 CLINT（`0x1F00_0000`）+ PLIC（`0x1F10_0000`，源 = `intrpt[7:0]`） |
| 目标频率 | ≥60 MHz，目标 100 MHz |
| 软件栈 | OpenSBI(M) + U-Boot(S) + Linux 5.14(S, Sv32) + busybox/UBIFS |

## 与工作区其他部分的关系

- 复用（只读）：`chiplab/`（IP 与平台工程）、`la32r-uboot/`、`la32r-Linux/`（`arch/riscv` 作为移植基线）、`riscv-arch-test/`（验证）、`/opt/riscv`（工具链）。
- 知识库：本仓库 `docs/` 已注册为常驻知识库的 `rv32gc-project` 源（配置在**工作区** `.dsh-kb/sources.json`，不属于本仓库）；新增文档后需重建索引：
  ```bash
  cd .. && node dsh-extension/bin/riscv-kb.js build
  ```

## 约束与注意事项

1. 与用户交流一律使用**中文**；
2. Vivado 一律用 **CLI**（`vivado -mode batch -source <tcl>`），不用 GUI；
3. 每完成一个阶段：更新 `AGENT.md` → git 提交 → **停下等待用户明确指令**；
4. 不修改上游源码树（`chiplab`/`la32r-*`）：移植以"新增文件 + 补丁 + 构建脚本"的方式管理。
