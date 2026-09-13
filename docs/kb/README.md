# 移植知识库（Porting Knowledge Base）

本目录是 **RV32-GC CPU 上移植 U-Boot / Linux / 驱动**过程中沉淀的知识点与操作方法，供后续阶段随时查阅。

## 使用方式

1. **在会话中检索**：本目录已注册进工作区常驻知识库（`.dsh-kb/sources.json` 的 `porting-kb` 源），可直接：
   ```
   kb_search "NAND DMA 门铃 描述符"
   kb_search "CONFREG 地址 仿真 FPGA 差异"
   kb_search "u-boot bootcmd mtdparts"
   ```
2. **直接阅读**：文件清单见下表；
3. **写入新知识**：移植过程中遇到的新发现（寄存器语义、实测几何、踩坑与解法）追加到对应文件，并运行 `node dsh-extension/bin/riscv-kb.js build`（或 `kb_manage action=reindex`）使检索生效。
   > 注意：索引在会话启动时载入，重建后**当前会话的 `kb_search` 仍是旧索引**，新文档在下一个会话生效；本阶段结束时已重建过索引（417 文档 / 4587 段落）。

## 文件清单

| 文件 | 内容 |
|---|---|
| `01-chiplab-platform.md` | 平台硬事实：CPU 接口契约、AXI、时钟、内存映射、CONFREG、仿真/综合流程 |
| `02-riscv-boot-flow.md` | RISC-V 启动链：OpenSBI / U-Boot / Linux 的职责、模式、SBI、镜像与设备树约定 |
| `03-nand-controller.md` | NAND 控制器与 DMA 引擎寄存器速查、命令序列、ECC、分区 |
| `04-uboot-notes.md` | U-Boot 移植知识：Kconfig 符号、环境变量、MTD/NAND 命令、常见坑 |
| `05-linux-notes.md` | Linux 移植知识：arch/riscv RV32、DTS 绑定、配置项、调试手段 |
| `06-toolchain-build.md` | 工具链与第三方组件构建（GCC/Spike/OpenSBI/busybox/mtd-utils） |
| `07-sim-debug.md` | 仿真与调试：iverilog/verilator/XSim、TB 约定、波形、上板调试 |

## 事实来源与可信度

| 来源 | 说明 |
|---|---|
| **实测/读 RTL 得到** | 标 `[RTL]`，可信度最高（如寄存器偏移、地址译码） |
| **读平台文档得到** | 标 `[DOC]`（`chiplab/docs/**`） |
| **读实验箱原理图得到** | 标 `[SCH]`（`实验箱A7-原理图.pdf`，提取结果见 `../reports/schematic-facts.md`） |
| **从 LA32R 参考实现推断** | 标 `[LA32R]`，**可能不适用于 RISC-V**（KSEG 别名、cache 操作、中断编号等） |
| **待实测确认** | 标 `[TODO]`，移植时必须验证 |

> 约定：凡标 `[LA32R]` 的结论在 RV32 上使用前必须重新验证。
