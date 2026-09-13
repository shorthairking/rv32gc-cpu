# 实验箱 A7 原理图关键信息提取

> 来源：`/home/shorthair/dsh/rv32-cpu/实验箱A7-原理图.pdf`（10 页，标题栏 FPGA `XC7A200T-FBG676`），2026-09-13 提取。
> 提取方式：`pypdf` 文本抽取 + 按网络标号/位号检索；下文所有结论均给出原理图中的位号或网络名以便复核。

---

## 1. NAND Flash（关键，决定驱动与 ECC 方案）

| 项目 | 值 | 依据 |
|---|---|---|
| 位号 / 型号 | **U8 / `K9F1G08U0C-PCB0`** | 第 5 页 NANDFLASH 区块元件标注 |
| 类型 | Samsung 1 Gbit SLC NAND，3.3 V（2.7–3.6 V），x8 | 型号 + Samsung 特性表 |
| 容量 | 1 Gbit = **128 MiB**，1024 块 | 特性表；与 RTL `nand_type=2'h2` 一致 |
| 页 | **2048 + 64 B**（Data Register (2K+64)×8） | 特性表；与参考驱动 gate 一致 |
| 块 | **128 KiB + 4 KiB**（64 页/块） | 特性表；与参考驱动 gate（`1<<17`）一致 |
| 速度 | Random Read 25 µs (max)；Serial Access 25 ns (min)；Page Program 200 µs (typ)；Block Erase 1.5 ms (typ) | 特性表 |
| **ECC 要求** | **1 bit / 512 Byte**（片内 Copy-Back EDC：1 bit/528 Byte） | 特性表 |
| 器件 ID | 厂商 `0xEC` + 器件 `0xF1`（Linux `nand_ids.c:107`：`0xF1` → "NAND 128MiB 3,3V 8-bit"） | Linux ID 表 |
| 连接 | 单 **CE#**（→ `nand_ce[0]`）；**RDY/B** → `FPGA_NAND_RDY`（RTL 只用 `nand_rdy[0]`）；**WP#**、**CLE**、**ALE**、**RE#**、**WE#**、**IO0–IO7** | 原理图引脚表（IO0/29、IO1/30、…、CLE/16、ALE/17、WE#/18、WP#/19、CE#/9、RE#/8、RDY-B/7）+ 4.7 K 上拉 |

**对项目的直接影响**

1. 参考驱动 `ls1a_nand_detect()` 的几何 gate（128 KiB / 2048 / 64）**与实际芯片完全吻合**，无需放宽；
2. ECC 只需 1 bit/512 B 能力 → 软件 BCH-4（7 B/512 B）或软件 Hamming（3 B/512 B）都能满足，64 B spare 空间充裕；
3. 单 CE + 单 R/B 与平台 RTL（`NAND_CE = nand_ce[0]`、`nand_rdy = {3'd0, NAND_RDY}`）一致，无需改 RTL；
4. 时序超时按上面 tR/tPROG/tBERS 设置（参考实现的 60×1 µs / 400×2 µs / udelay(2000)+100×50 µs 均有余量）。

## 2. 其它存储与时钟

| 项目 | 值 | 依据 |
|---|---|---|
| DDR3 | **K4B1G1646G-BCK0**（Samsung 1 Gbit ×16 DDR3）= **128 MiB** | 第 3 页 DDR3 区块 |
| SPI NOR Flash | **S25FL128SAGMFI001**（128 Mbit = 16 MiB），**DIP 插座（U14）** | SPI_FLASH 区块（含提示："U14 Flash 插拔时，需要将芯片座同时取下"） |
| 板级输入时钟 | **100 MHz**（→ PLL/MIG） | 时钟输入区块（与 `soc_up.xdc` 的 `create_clock -period 10.000` 一致） |
| FPGA | XC7A200T-FBG676 | 首页标题栏/框图 |

## 3. 与平台文档/DTS 的一致性核对

| 项目 | 原理图 | 平台 RTL / DTS | 结论 |
|---|---|---|---|
| DDR3 容量 | 128 MiB | DTS `/memory = <0x0 0x08000000>`（128 MiB） | ✅ 一致 |
| NAND 容量 | 128 MiB | `soc_top` 中 `nand_type = 2'h2`（1 Gbit） | ✅ 一致 |
| NAND 页/块 | 2048+64 B / 128 KiB | 参考驱动 gate 128 KiB/2048/64 | ✅ 一致 |
| 板级时钟 | 100 MHz | `soc_up.xdc` 10 ns 约束 | ✅ 一致 |

## 4. 仍未由原理图解答的问题（需上板实测）

| 问题 | 说明 |
|---|---|
| 坏块标记字节位置 | 按 Samsung 大页 SLC 惯例为块内第 1 页 spare 首字节（可能还有第 2 字节），实测确认 |
| NAND 控制器 `TIMING`（`0x0C`）取值 | 参考实现用 `0x205`（读写）/`0x412`（初始化），需按 APB 33 MHz 与器件 25 ns 串行访问时间实测核对 |
| 控制器硬件 ECC 的字节布局与纠错能力 | 需置 `CMD[11]/[12]` 实测，才能决定是否启用硬件 ECC 提速 |
| `PARAM`（`0x18`）寄存器语义 | 参考实现的 RMW 会清除 bit27，需实测确认安全值 |
